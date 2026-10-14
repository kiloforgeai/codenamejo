import XCTest
@testable import CodenameJo

/// The phone's own Gmail search and body reads: what is declared, and the pure halves of running them.
final class GmailReadToolsTests: XCTestCase {
    private func names(_ tools: [[String: Any]]) -> [String] { tools.compactMap { $0["name"] as? String } }

    func testHeadersOnlyKeepsSearchAndWithholdsTheBodyReads() {
        XCTAssertEqual(names(GmailReadTools.definitions(accounts: ["owner@example.test"], bodies: true)),
                       ["gmail_search_messages", "gmail_get_message", "gmail_get_thread", "gmail_read_attachment"])
        let locked = GmailReadTools.definitions(accounts: ["owner@example.test"], bodies: false)
        XCTAssertEqual(names(locked), ["gmail_search_messages"])
        XCTAssertTrue((locked[0]["description"] as? String ?? "").contains("headers only"))
        XCTAssertTrue(GmailReadTools.definitions(accounts: [], bodies: true).isEmpty)
    }

    func testANamedAccountOutsideTheProfileIsRefused() throws {
        let connected = ["owner@example.test", "work@example.test"]
        XCTAssertEqual(try GmailReadTools.targets([:], connected: connected), connected)
        XCTAssertEqual(try GmailReadTools.targets(["account": "WORK@example.test"], connected: connected), ["work@example.test"])
        XCTAssertThrowsError(try GmailReadTools.targets(["account": "other@example.test"], connected: connected))
    }

    func testAnInventedCursorIsRefusedAndAStalledPageStops() throws {
        XCTAssertNil(try GmailReadTools.cursor(nil))
        XCTAssertEqual(try GmailReadTools.cursor(1_757_000_000, now: Date(timeIntervalSince1970: 1_760_000_000)), 1_757_000_000)
        XCTAssertThrowsError(try GmailReadTools.cursor(20_260_812))
        XCTAssertEqual(GmailReadTools.pageSize(0), 10)
        XCTAssertEqual(GmailReadTools.pageSize(100), 25)
        XCTAssertEqual(GmailReadTools.nextCursor(floors: [1_757_000_000_500], before: nil).before, 1_757_000_002)
        XCTAssertTrue(GmailReadTools.nextCursor(floors: [1_757_000_000_500], before: 1_757_000_002).stalled)
        XCTAssertNil(GmailReadTools.nextCursor(floors: [], before: nil).before)
    }

    func testAttachmentsAreFoundAndPickedByLooseName() throws {
        let file = { (name: String, id: String?) in
            GmailAPI.FullPart(mimeType: "application/pdf", filename: name, headers: nil,
                              body: GmailAPI.PartBody(size: 2_000, data: id == nil ? "aGk" : nil, attachmentId: id), parts: nil)
        }
        let tree = GmailAPI.FullPart(mimeType: "multipart/mixed", filename: "", headers: nil, body: nil,
                                     parts: [file("Contract-v3.pdf", "a1"), file("notes.pdf", nil)])
        let files = GmailReadTools.attachments(in: tree)
        XCTAssertEqual(files.map(\.filename), ["Contract-v3.pdf", "notes.pdf"])
        XCTAssertEqual(try GmailReadTools.pick(files, wanted: "the contract").get().attachmentId, "a1")
        XCTAssertThrowsError(try GmailReadTools.pick(files, wanted: nil).get())
        XCTAssertThrowsError(try GmailReadTools.pick([], wanted: nil).get())
    }

    func testAReplyCarriesTheThreadNote() {
        let message = GmailAPI.FullMessage(id: "m1", threadId: "t1", labelIds: nil, internalDate: nil,
            payload: GmailAPI.FullPart(mimeType: "text/plain", filename: "", headers: [
                .init(name: "From", value: "Dana <dana@example.test>"), .init(name: "In-Reply-To", value: "<x@example.test>"),
            ], body: GmailAPI.PartBody(size: 5, data: "aGVsbG8"), parts: nil))
        let envelope = GmailReadTools.envelope(message)
        XCTAssertEqual(envelope["body"] as? String, "hello")
        XCTAssertEqual(envelope["isReply"] as? Bool, true)
        XCTAssertEqual(envelope["note"] as? String, GmailReadTools.replyNote)
    }

    func testTextIsReadLocallyAndLongTextIsDigested() async {
        XCTAssertEqual(AttachmentText.classify(filename: "a.csv", mimeType: "application/octet-stream"), .text)
        XCTAssertEqual(AttachmentText.classify(filename: "scan.HEIC", mimeType: "image/heic"), .unsupported)
        XCTAssertEqual(AttachmentText.classify(filename: "deck.pptx", mimeType: ""), .office)
        let unused: AttachmentText.Reader = { _ in XCTFail("no model for a short text"); return "" }
        let short = await AttachmentText.read(Data("a,b\n1,2".utf8), filename: "a.csv", mimeType: "text/csv", model: unused)
        XCTAssertTrue(short.contains("read in full"))
        let long = await AttachmentText.localRead(String(repeating: "word ", count: 3_000), filename: "a.txt", size: 15_000,
                                                  model: { _ in "digest" })
        XCTAssertTrue(long.hasSuffix("digest"))
    }
}
