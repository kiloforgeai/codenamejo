import XCTest
@testable import CodenameJo

final class SplitInboxTests: XCTestCase {
    func testDispatchArchiveBetweenCallsOverridesUnchangedLatestMessage() throws {
        func state(_ labels: [[String]]) throws -> GmailAPI.ThreadInboxState {
            let data = try JSONSerialization.data(withJSONObject: [
                "id": "thread", "messages": labels.map { ["labelIds": $0] },
            ])
            return try JSONDecoder().decode(GmailAPI.ThreadInboxState.self, from: data)
        }
        // The section's latest message is sent/read; an earlier inbox message keeps it eligible.
        XCTAssertTrue(try state([["INBOX", "UNREAD"], ["SENT"]]).isInInbox)
        XCTAssertFalse(try state([["UNREAD"], ["SENT"]]).isInInbox)
        // Restoring the inbox label or receiving new inbox mail must make the thread return.
        XCTAssertTrue(try state([["UNREAD"], ["SENT"], ["INBOX"]]).isInInbox)
        XCTAssertFalse(try state([["TRASH"], ["SENT"]]).isInInbox)
    }
}
