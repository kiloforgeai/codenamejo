import XCTest
@testable import CodenameJo

final class LocalEmailPresentationTests: XCTestCase {
    private typealias P = LocalEmailPresentation

    private func b64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    private func part(_ mime: String, _ text: String, filename: String? = nil) -> GmailAPI.FullPart {
        GmailAPI.FullPart(mimeType: mime, filename: filename, headers: nil,
                          body: GmailAPI.PartBody(size: text.utf8.count, data: b64(text)), parts: nil)
    }

    private func message(id: String = "m1", thread: String = "t1", parts: [GmailAPI.FullPart],
                         from: String = "Dana <dana@halden.example>", date: String = "Tue, 22 Sep 2026 10:00:00 -0700",
                         labels: [String] = ["INBOX"], snippet: String? = nil) -> GmailAPI.FullMessage {
        let headers = [("From", from), ("To", "owner@example.test"), ("Subject", "Plan"), ("Date", date)]
            .map { GmailAPI.MessageDetail.Header(name: $0.0, value: $0.1) }
        return GmailAPI.FullMessage(snippet: snippet, id: id, threadId: thread, labelIds: labels, internalDate: nil,
            payload: GmailAPI.FullPart(mimeType: "multipart/alternative", filename: nil, headers: headers, body: nil, parts: parts))
    }

    // MARK: - Envelope

    func testNestedPlainTextWinsOverHTML() {
        let envelope = P.envelope(message(parts: [part("text/html", "<p>From HTML</p>"), part("text/plain", "From plain")]),
                                  authorship: true)
        XCTAssertEqual(envelope.body, "From plain")
    }

    func testHTMLDropsHiddenAndScriptContentAndKeepsBlocks() {
        let html = "<html><head><title>T</title><style>p{color:red}</style></head><body><p>Hello&nbsp;there</p>"
            + "<div style=\"display: none\">secret <b>bold</b></div><div hidden>gone</div>"
            + "<p aria-hidden=\"true\">nope</p><script>if (a<b) {}</script>Line<br>Two &amp; more</body></html>"
        XCTAssertEqual(P.htmlToText(html), "Hello there\nLine\nTwo & more")
    }

    func testAuthorshipSplitsQuotedHistory() {
        let body = "Sounds good, Tuesday works.\n\nOn Mon, Sep 21, 2026 at 9:00 AM Ana <ana@example.test>\nwrote:\n> Can we meet?"
        let envelope = P.envelope(message(parts: [part("text/plain", body)]), authorship: true)
        XCTAssertEqual(envelope.body, "Sounds good, Tuesday works.")
        XCTAssertEqual(envelope.quotedHistory, "On Mon, Sep 21, 2026 at 9:00 AM Ana <ana@example.test>\nwrote:\n> Can we meet?")
        XCTAssertEqual(P.splitQuoted("Hi\n-----Original Message-----\nold").own, "Hi")
    }

    func testMarkupBodyFallsBackToSnippetAndAttachmentsAreNamed() {
        let css = "a{color:red;} b{margin:0;} c{padding:0;}"
        let markup = P.envelope(message(parts: [part("text/plain", css)], snippet: " Your order shipped "), authorship: true)
        XCTAssertEqual(markup.body, "Your order shipped\n\n[Message body was mostly markup; Gmail's preview follows.]")

        let file = GmailAPI.FullPart(mimeType: "application/pdf", filename: "contract.pdf", headers: nil,
                                     body: GmailAPI.PartBody(size: 2_400, data: nil, attachmentId: "a1"), parts: nil)
        let attached = P.envelope(message(parts: [part("text/plain", "See attached."), file], labels: ["SENT"]), authorship: true)
        XCTAssertEqual(attached.body, "See attached.\n\n[Attachments: contract.pdf (2 KB). Use read_attachment to read one.]")
        XCTAssertTrue(attached.fromMe)
    }

    func testSummaryKeepsWholeWordsWithinSpeechBudget() throws {
        XCTAssertEqual(try P.spokenSummary("  Short.  "), "Short.")
        XCTAssertLessThanOrEqual(try P.spokenSummary(String(repeating: "Résumé ", count: 100)).utf8.count, 250)
        XCTAssertThrowsError(try P.spokenSummary("   "))
    }

    func testPreparationRequestsOnlyASummary() async throws {
        let fetched = message(parts: [part("text/plain", "Your receipt for $12.")])
        let requests = RequestLog()
        let deps = P.Dependencies(read: { _, _ in fetched }, respond: { body, _ in
            await requests.add(body)
            return #"{"summary":"Dana sent a receipt for twelve dollars."}"#
        }, timeZone: { _ in "America/Los_Angeles" })
        let key = LiveEmailPresentation.Key(account: "owner@example.test", threadId: "t1", messageId: "m1",
                                            exchangeId: "", messageIDs: ["m1"], selectedIDs: ["m1"])
        let prepared = try await P.prepare(key, scope: .init(profileId: "p", isDefault: true), deps: deps)
        XCTAssertEqual(prepared.summary, "Dana sent a receipt for twelve dollars.")
        let bodies = await requests.bodies
        XCTAssertEqual(bodies.count, 1)
        let text = try XCTUnwrap(bodies.first?["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["summary"])
        XCTAssertEqual(Set((schema["properties"] as? [String: Any] ?? [:]).keys), ["summary"])
        XCTAssertTrue(try XCTUnwrap(prepared.speakerLine(for: #"{"done":false,"item":{"account":"owner@example.test","id":"m1","threadId":"t1"}}"#))
            .contains("What would you like to do with it?"))
    }

    func testPrepareRejectsAMessageFromAnotherThread() async throws {
        let deps = P.Dependencies(
            read: { _, _ in self.message(thread: "elsewhere", parts: [self.part("text/plain", "Hi")]) },
            respond: { _, _ in XCTFail("no summary for a rejected chain"); return "" },
            timeZone: { _ in nil })
        let key = LiveEmailPresentation.Key(account: "owner@example.test", threadId: "t1", messageId: "m1",
                                            exchangeId: "", messageIDs: ["m1"], selectedIDs: ["m1"])
        do {
            _ = try await P.prepare(key, scope: .init(profileId: "p", isDefault: true, emails: ["owner@example.test"]), deps: deps)
            XCTFail("expected a rejection")
        } catch let failure as P.Failure {
            XCTAssertEqual(failure.reason, "incomplete_email_context")
        }
    }
}

private actor RequestLog {
    var bodies: [[String: Any]] = []
    func add(_ body: [String: Any]) { bodies.append(body) }
}
