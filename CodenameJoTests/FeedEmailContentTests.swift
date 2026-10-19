import XCTest
@testable import CodenameJo

final class FeedEmailContentTests: XCTestCase {
    private let key = LiveEmailPresentation.Key(account: "me@example.test", threadId: "t", messageId: "m",
                                               exchangeId: "", messageIDs: ["m"], selectedIDs: ["m"])
    private let step = #"{"done":false,"item":{"id":"m","threadId":"t","account":"me@example.test"}}"#

    private func source(_ text: String, id: String = "m", thread: String = "t", complete: Bool = true) -> FeedEmailContent.Message {
        .init(id: id, threadId: thread, from: "Ada <ada@example.test>", to: "me@example.test", cc: "",
              subject: "Invoice", date: "2026-10-15", text: text, textComplete: complete, attachments: [])
    }

    func testSourcePreservesExactTextHeadersAndAttachmentMetadata() throws {
        let text = "Hello,\n\nThe amount is €42.\nOn Tuesday, Ada wrote:\n> Original terms."
        let data = Data(text.utf8).base64EncodedString()
        let file = GmailAPI.FullPart(mimeType: "application/pdf", filename: "invoice.pdf", headers: nil,
                                    body: .init(size: 2400, data: nil, attachmentId: "a"), parts: nil)
        let message = GmailAPI.FullMessage(snippet: "preview", id: "m", threadId: "t", labelIds: ["INBOX"], internalDate: nil,
            payload: .init(mimeType: "multipart/mixed", filename: nil,
                           headers: [.init(name: "From", value: "Ada"), .init(name: "To", value: "Me"),
                                     .init(name: "Cc", value: "Pat"), .init(name: "Subject", value: "Invoice")], body: nil,
                           parts: [.init(mimeType: "text/plain", filename: nil, headers: nil,
                                         body: .init(size: data.count, data: data), parts: nil), file]))
        let envelope = LocalEmailPresentation.envelope(message, authorship: true)
        let content = try XCTUnwrap(envelope.source)
        XCTAssertEqual(content.text, text)
        XCTAssertTrue(content.textComplete)
        XCTAssertEqual(content.from, "Ada")
        XCTAssertEqual(content.cc, "Pat")
        XCTAssertEqual(content.attachments.map(\.name), ["invoice.pdf"])
        XCTAssertEqual(content.attachments.first?.size, 2400)
        XCTAssertFalse(content.text.contains("Use read_attachment"))
    }

    func testLongMultibyteMessagesAreBoundedAndNeverClaimComplete() {
        let text = String(repeating: "é🙂", count: 10_000)
        let content = FeedEmailContent(messages: [source(text)], key: key)
        XCTAssertLessThanOrEqual(content.messages[0].text.utf8.count, FeedEmailContent.perMessageBytes)
        XCTAssertFalse(content.messages[0].textComplete)
        XCTAssertTrue(text.hasPrefix(content.messages[0].text))
        XCTAssertFalse(content.messages[0].text.contains("�"))
    }

    func testSelectedLatestMessageGetsBudgetBeforeEarlierContext() {
        let grouped = LiveEmailPresentation.Key(account: key.account, threadId: "t", messageId: "m",
            exchangeId: "chain", messageIDs: ["old", "middle", "m"], selectedIDs: ["m"])
        let text = String(repeating: "x", count: 13_000)
        let content = FeedEmailContent(messages: [source(text, id: "old"), source(text, id: "middle"), source("Latest facts")], key: grouped)
        XCTAssertEqual(content.messages.last?.id, "m")
        XCTAssertTrue(content.messages.last!.textComplete)
        XCTAssertLessThanOrEqual(content.messages.reduce(0) { $0 + $1.text.utf8.count }, FeedEmailContent.totalTextBytes)
        XCTAssertFalse(content.messages.first!.textComplete)
        XCTAssertEqual(FeedEmailContent(messages: content.messages, key: grouped), content)
    }

    func testForeignMessagesAndThreadsAreExcluded() {
        let content = FeedEmailContent(messages: [source("foreign", id: "other"), source("wrong thread", thread: "other"),
                                                 source("right"), source("duplicate")], key: key)
        XCTAssertEqual(content.messages.count, 1)
        XCTAssertEqual(content.messages.first?.threadId, "t")
        XCTAssertFalse(content.messages.contains { $0.text == "foreign" || $0.text == "wrong thread" })
    }

    func testPreparedContentSurvivesCompactionOnlyForCurrentSelection() throws {
        let prepared = LiveEmailPresentation(key: key, summary: "Ada sent an invoice.", from: "Ada", to: "Me",
            sentAt: "2026-10-15", emailContent: FeedEmailContent(messages: [source("Pay €42 by Friday.")], key: key))
        let annotated = try XCTUnwrap(prepared.annotating(step))
        XCTAssertTrue(annotated.contains("Pay €42 by Friday."))
        let compact = LiveCompactContext.text(annotated)
        XCTAssertTrue(compact.contains("Pay €42 by Friday."))
        XCTAssertTrue(compact.contains("textComplete"))
        XCTAssertFalse(LiveCompactContext.text(annotated, includeEmailContent: false).contains("Pay €42 by Friday."))
        XCTAssertNil(prepared.annotating(step.replacingOccurrences(of: "me@example.test", with: "other@example.test")))
        XCTAssertNil(prepared.annotating(step.replacingOccurrences(of: "\"m\"", with: "\"other\"")))
    }

    func testHeadersOnlyNeverAnnotatesSourceText() throws {
        let prior = UserDefaults.standard.object(forKey: MailHeadersOnly.storageKey)
        defer { UserDefaults.standard.set(prior, forKey: MailHeadersOnly.storageKey) }
        UserDefaults.standard.set(true, forKey: MailHeadersOnly.storageKey)
        let prepared = LiveEmailPresentation(key: key, summary: "Summary", from: "Ada", to: "Me", sentAt: "today",
            emailContent: FeedEmailContent(messages: [source("private body")], key: key))
        XCTAssertFalse(try XCTUnwrap(prepared.annotating(step)).contains("private body"))
    }

    func testUnavailableSourceDoesNotPromotePreviewToCompleteBody() throws {
        let message = GmailAPI.FullMessage(snippet: "Just a preview", id: "m", threadId: "t", labelIds: [], internalDate: nil,
            payload: .init(mimeType: "text/html", filename: nil, headers: nil,
                           body: .init(size: 1, data: Data("<style>hidden</style>".utf8).base64EncodedString()), parts: nil))
        let source = try XCTUnwrap(LocalEmailPresentation.envelope(message, authorship: true).source)
        XCTAssertFalse(source.textComplete)
        XCTAssertTrue(source.text.isEmpty)
    }
}
