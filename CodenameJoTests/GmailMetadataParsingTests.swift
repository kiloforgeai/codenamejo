import XCTest
import GRDB
@testable import CodenameJo

/// Everything the phone knows about a message starts as Gmail's metadata JSON going
/// through `MailStore.Ingest`. Gmail echoes whatever the sender wrote, so header case and
/// duplicates are real, and `internalDate` is an int64 sent as a string — a value that
/// does not parse has to become nil rather than a plausible wrong date.
final class GmailMetadataParsingTests: XCTestCase {

    private func detail(_ json: String) throws -> GmailAPI.MessageDetail {
        try JSONDecoder().decode(GmailAPI.MessageDetail.self, from: Data(json.utf8))
    }

    private func headers(_ pairs: [(String, String)]) -> String {
        pairs.map { "{\"name\":\"\($0.0)\",\"value\":\"\($0.1)\"}" }.joined(separator: ",")
    }

    func testHeaderLookupIgnoresCaseAndTakesTheFirstOfADuplicate() throws {
        let message = try detail("""
            {"id":"m","threadId":"t","payload":{"headers":[\(headers([
                ("FROM", "Sarah <sarah@example.test>"),
                ("From", "Impostor <spoof@example.test>"),
                ("subject", "Invoice for March"),
                ("Message-Id", "<abc@mail.example.test>"),
            ]))]}}
            """)

        XCTAssertEqual(message.header("From"), "Sarah <sarah@example.test>")
        XCTAssertEqual(message.header("from"), "Sarah <sarah@example.test>")
        XCTAssertEqual(message.header("Subject"), "Invoice for March")
        XCTAssertEqual(message.header("MESSAGE-ID"), "<abc@mail.example.test>")
        XCTAssertNil(message.header("Bcc"), "a header that is not there is not invented")
    }

    func testAMessageWithNoPayloadParsesRatherThanFailing() throws {
        let message = try detail("""
            {"id":"m","threadId":"t","snippet":"hello","internalDate":"1767225600000"}
            """)

        XCTAssertNil(message.payload)
        XCTAssertNil(message.header("From"))
        XCTAssertNil(message.labelIds)
        XCTAssertEqual(message.snippet, "hello")

        let ingest = MailStore.Ingest(detail: message, account: "work@test")
        XCTAssertEqual(ingest.labels, [], "no labels is an empty set, never a crash")
        XCTAssertNil(ingest.message.sender)
        XCTAssertEqual(ingest.message.internalDate, 1_767_225_600_000)
    }

    /// The int64-as-string field. Anything that is not a whole number has to come through
    /// as nil: a message sorted under a fabricated date is worse than an undated one.
    func testOnlyAWholeNumberInternalDateSurvives() throws {
        func parsed(_ literal: String) throws -> Int64? {
            let json = literal.isEmpty
                ? "{\"id\":\"m\",\"threadId\":\"t\"}"
                : "{\"id\":\"m\",\"threadId\":\"t\",\"internalDate\":\(literal)}"
            return MailStore.Ingest(detail: try detail(json), account: "work@test")
                .message.internalDate
        }

        XCTAssertEqual(try parsed("\"1767225600000\""), 1_767_225_600_000)
        XCTAssertEqual(try parsed("\"0\""), 0)
        XCTAssertNil(try parsed(""), "an absent field stays absent")
        XCTAssertNil(try parsed("\"\""))
        XCTAssertNil(try parsed("\"not-a-number\""))
        XCTAssertNil(try parsed("\"1767225600000.5\""))
        XCTAssertNil(try parsed("\"99999999999999999999\""), "an overflow is not a date")
    }

    /// Thread grouping is mailbox plus thread id plus reply ancestry, so these three
    /// headers are the input to it — and they are the ones whose spelling varies most.
    func testReplyAncestryHeadersAreCarriedOntoTheStoredMessage() throws {
        let message = try detail("""
            {"id":"m","threadId":"t","labelIds":["INBOX","UNREAD"],"payload":{"headers":[\(headers([
                ("Message-ID", "<child@mail.example.test>"),
                ("in-reply-to", "<parent@mail.example.test>"),
                ("References", "<root@mail.example.test> <parent@mail.example.test>"),
                ("To", "me@work.test"),
            ]))]}}
            """)
        let ingest = MailStore.Ingest(detail: message, account: "work@test")

        XCTAssertEqual(ingest.message.rfcMessageID, "<child@mail.example.test>")
        XCTAssertEqual(ingest.message.inReplyTo, "<parent@mail.example.test>")
        XCTAssertEqual(ingest.message.referenceHeaders,
                       "<root@mail.example.test> <parent@mail.example.test>")
        XCTAssertEqual(ingest.message.recipient, "me@work.test")
        XCTAssertEqual(ingest.message.ancestryCached, true)
        XCTAssertEqual(ingest.labels, ["INBOX", "UNREAD"])
        XCTAssertEqual(ingest.message.account, "work@test",
                       "the mailbox comes from the caller, never from the mail")
    }

    /// The parse only counts if it survives the write, labels included.
    func testParsedFieldsAndLabelsSurviveTheWriteToTheCache() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = try DatabasePool(path: path.path)
        defer { try? db.close(); try? FileManager.default.removeItem(at: path) }
        try await db.write { try MailStore.createUserScopedSchema($0) }
        let store = MailStore(database: db, userId: "owner")

        let message = try detail("""
            {"id":"m","threadId":"t","labelIds":["INBOX","UNREAD"],"snippet":"the invoice",
             "internalDate":"1767225600000","payload":{"headers":[\(headers([
                ("FROM", "Sarah <sarah@example.test>"),
                ("Subject", "Invoice for March"),
            ]))]}}
            """)
        await store.cache([MailStore.Ingest(detail: message, account: "work@test")])

        let rows = await store.messages(ids: ["m"])
        let stored = try XCTUnwrap(rows.first)
        let unread = await store.unreadIds(among: ["m"])
        XCTAssertEqual(stored.sender, "Sarah <sarah@example.test>")
        XCTAssertEqual(stored.subject, "Invoice for March")
        XCTAssertEqual(stored.snippet, "the invoice")
        XCTAssertEqual(stored.internalDate, 1_767_225_600_000)
        XCTAssertEqual(stored.threadId, "t")
        XCTAssertEqual(unread, ["m"])

        // A re-fetch arrives precisely because the labels changed, so the interesting case
        // is a label that is now absent: the write replaces the set rather than merging it.
        let read = try detail("""
            {"id":"m","threadId":"t","labelIds":["INBOX"],"snippet":"the invoice",
             "internalDate":"1767225600000"}
            """)
        await store.cache([MailStore.Ingest(detail: read, account: "work@test")])

        let after = await store.unreadIds(among: ["m"])
        let remaining = await store.messages(ids: ["m"]).count
        XCTAssertEqual(after, [], "the label Gmail stopped sending is the one that has to go")
        XCTAssertEqual(remaining, 1, "and the message stays")
    }
}
