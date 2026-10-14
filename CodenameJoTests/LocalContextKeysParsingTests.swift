import Foundation
import XCTest
@testable import CodenameJo

/// What the phone stores off a tool result is decided by these parsers: is this data or a
/// sentence, which messages are in it, and which message did a write act on. A miss here is
/// either a refusal stored as an answer or a message the user can no longer ask about once
/// it has left the inbox.
final class LocalContextKeysParsingTests: XCTestCase {
    private func json(_ object: Any) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    func testProseIsNeverMistakenForDataEvenWithJSONAppendedToIt() {
        XCTAssertTrue(LocalContextKeys.isData("{\"id\":\"1\"}"))
        XCTAssertTrue(LocalContextKeys.isData("\n  [{\"id\":\"1\"}]"))
        // `gmail_archive_message` answers with a sentence and then some JSON; a parser that
        // accepted partial JSON would store that receipt as a message.
        XCTAssertFalse(LocalContextKeys.isData("Archived. {\"ok\":true}"))
        XCTAssertFalse(LocalContextKeys.isData("I can't do that."))
        XCTAssertFalse(LocalContextKeys.isData(""))
        XCTAssertFalse(LocalContextKeys.isData("   "))
    }

    func testEveryMessageInAnOutputGetsFoundHoweverDeeplyItIsNested() {
        let output = json([
            "queue": ["position": 1],
            "message": ["id": "a1", "from": "sam@x.test", "subject": "Invoice"],
            "thread": ["messages": [["id": "b2", "subject": "Re: Invoice"],
                                    ["id": "c3", "from": "pat@x.test"]]]])
        let found = LocalContextKeys.emails(in: output)
        XCTAssertEqual(Set(found.compactMap { $0["id"] as? String }), ["a1", "b2", "c3"])
    }

    func testAMessageWithNoIdIsNotARowAndTheSameIdIsNeverTwo() {
        let output = json([
            ["id": "a1", "from": "sam@x.test", "subject": "Invoice"],
            // `triage_next`'s `next` carries no id — you can say it, not act on it — so it
            // must not become a row; nor does an object with an id but nothing mail-shaped.
            ["from": "pat@x.test", "subject": "Next up"],
            ["id": "", "from": "blank@x.test"],
            ["id": "z9", "position": 4],
            ["id": "a1", "from": "sam@x.test", "subject": "Invoice"]])
        let found = LocalContextKeys.emails(in: output)
        XCTAssertEqual(found.compactMap { $0["id"] as? String }, ["a1"])
    }

    func testOutputThatIsNotJSONYieldsNoMessagesRatherThanThrowing() {
        XCTAssertTrue(LocalContextKeys.emails(in: "Archived.").isEmpty)
        XCTAssertTrue(LocalContextKeys.emails(in: "").isEmpty)
        XCTAssertTrue(LocalContextKeys.emails(in: "[{\"id\":").isEmpty)
        XCTAssertNil(LocalContextKeys.parsed("nope"))
        XCTAssertTrue(LocalContextKeys.object(from: "[1,2]").isEmpty)
    }

    func testTheIdsAWriteActedOnAreReadFromItsArgumentsInEveryShapeTheyArriveIn() {
        let ids = { LocalContextKeys.actedMessageIds(in: self.json($0)) }
        XCTAssertEqual(ids(["message_id": "0000000000000002"]), ["0000000000000002"])
        XCTAssertEqual(ids(["messageId": "a1", "thread_id": "t1"]), ["a1", "t1"])
        XCTAssertEqual(ids(["message_id": ["a1", "", "b2"]]), ["a1", "b2"])
        // A query-shaped write names no message, and nothing is annotated.
        XCTAssertTrue(LocalContextKeys.actedMessageIds(in: json(["query": "from:sam"])).isEmpty)
        XCTAssertTrue(LocalContextKeys.actedMessageIds(in: "not json").isEmpty)
        XCTAssertTrue(LocalContextKeys.actedMessageIds(in: json(["message_id": ""])).isEmpty)
    }

    func testAWriteIsNotedInPastTenseAndOnlyWhereTheNoteAnswersAQuestion() {
        XCTAssertEqual(LocalContextKeys.actionNote(for: "archive_message"), "archived")
        // The advertised name carries its connector prefix and still resolves.
        XCTAssertEqual(LocalContextKeys.actionNote(for: "gmail_archive_message"), "archived")
        XCTAssertEqual(LocalContextKeys.actionNote(for: "gmail_archive_matching"), "archived")
        XCTAssertEqual(LocalContextKeys.actionNote(for: "gmail_trash_message"), "deleted")
        XCTAssertEqual(LocalContextKeys.actionNote(for: "gmail_label_message"), "labelled")
        XCTAssertEqual(LocalContextKeys.actionNote(for: "gmail_mark_spam"), "reported as spam")
        // Overwrites the "archived" note the row is almost certainly carrying.
        XCTAssertEqual(LocalContextKeys.actionNote(for: "gmail_unarchive_message"),
                       "put back in the inbox")
        // A send is not something done *to* a stored message.
        XCTAssertNil(LocalContextKeys.actionNote(for: "gmail_send_email"))
        XCTAssertNil(LocalContextKeys.actionNote(for: ""))
    }

    func testAReadIsKeyedByTheWordsSomebodyMightAskItBackWithAndTaggedByToolName() {
        XCTAssertEqual(
            LocalContextKeys.describe(tool: "gmail_search_messages",
                                      argumentsJSON: json(["query": "from:sam invoice"])),
            "mail matching from:sam invoice [gmail_search_messages]")
        XCTAssertEqual(
            LocalContextKeys.describe(tool: "gmail_get_thread",
                                      argumentsJSON: json(["thread_id": "t1"])),
            "the thread t1 [gmail_get_thread]")
        XCTAssertEqual(
            LocalContextKeys.describe(tool: "gmail_find_person",
                                      argumentsJSON: json(["name": "Sam Ross"])),
            "the email address for Sam Ross [gmail_find_person]")
        XCTAssertEqual(
            LocalContextKeys.describe(tool: "gmail_read_attachment",
                                      argumentsJSON: json(["message_id": "a1"])),
            "the attachment on message a1 [gmail_read_attachment]")
        // A missing argument leaves a gap rather than dropping the tag that makes the row
        // recognisable as an automatic one.
        XCTAssertEqual(LocalContextKeys.describe(tool: "gmail_get_message", argumentsJSON: "{}"),
                       "the message  [gmail_get_message]")
        // A tool with no entry is keyed by name alone, so its second call replaces the first.
        XCTAssertEqual(
            LocalContextKeys.describe(tool: "notion-fetch",
                                      argumentsJSON: json(["id": "page-1"])),
            "notion-fetch")
    }

    func testAMessagesKeyIsItsSenderAndSubjectAndSurvivesEitherBeingMissing() {
        XCTAssertEqual(
            LocalContextKeys.describe(email: ["from": "sam@x.test", "subject": "Invoice 4"],
                                      tool: "gmail_triage_next"),
            "the email from sam@x.test about \"Invoice 4\" [gmail_triage_next]")
        XCTAssertEqual(
            LocalContextKeys.describe(email: ["id": "a1"], tool: "gmail_triage_next"),
            "the email from  about \"\" [gmail_triage_next]")
    }

    func testAMessageIsReSerialisedWithWhateverKeysTheToolSent() throws {
        let email = ["id": "a1", "from": "sam@x.test", "snippet": "the invoice"]
        let text = try XCTUnwrap(LocalContextKeys.json(for: email))
        let round = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        XCTAssertEqual(round, email)
        // A message carrying no keys at all is still a row's worth of valid JSON.
        XCTAssertEqual(LocalContextKeys.json(for: [:]), "{}")
    }
}
