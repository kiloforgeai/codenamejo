import XCTest
@testable import CodenameJo

/// The batched thread read a profile switch stopped waiting on, held to its contract.
@MainActor
final class ProfileSwitchLatencyTests: XCTestCase {
    // MARK: - Reading a batched thread state

    private func state(_ json: String) throws -> GmailAPI.ThreadInboxState {
        try JSONDecoder().decode(GmailAPI.ThreadInboxState.self, from: Data(json.utf8))
    }

    func testABatchedThreadNamesItselfSoItsAnswerCanBeMatchedBack() throws {
        let inbox = try state(#"{"id":"t1","messages":[{"labelIds":["INBOX","UNREAD"]}]}"#)
        XCTAssertEqual(inbox.id, "t1")
        XCTAssertTrue(inbox.isInInbox)
    }

    func testAThreadWithNoInboxMemberReadsAsArchived() throws {
        let archived = try state(#"{"id":"t2","messages":[{"labelIds":["UNREAD"]}]}"#)
        XCTAssertEqual(archived.id, "t2")
        XCTAssertFalse(archived.isInInbox)
    }

    func testARefusedSubRequestDoesNotDecodeAsAThread() {
        // A batch carries sub-request failures inside a 200, so this is the only thing
        // standing between a 429 and a thread being pruned from the queue as archived.
        let refusal = #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED"}}"#
        XCTAssertNil(try? state(refusal),
            "A refusal must drop out of the reply rather than read as an archived thread")
    }
}
