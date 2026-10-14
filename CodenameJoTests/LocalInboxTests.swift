import XCTest
@testable import CodenameJo

/// The on-device model proposes; the user's own words decide what can be sent or filed.
final class LocalInboxTests: XCTestCase {
    func testOnlyTheUsersOwnWordsCanSend() {
        XCTAssertTrue(LocalInbox.allowsSend("reply and send it"))
        XCTAssertTrue(LocalInbox.allowsSend("Send them a yes"))
        XCTAssertFalse(LocalInbox.allowsSend("draft a reply saying yes"))
        XCTAssertFalse(LocalInbox.allowsSend("don't send it, just draft it"))
        XCTAssertFalse(LocalInbox.allowsSend("reply but do not send"))
    }

    func testALabelMustComeFromTheUsersWords() {
        XCTAssertTrue(LocalInbox.allowsLabel("receipts", in: "file this under receipts"))
        XCTAssertTrue(LocalInbox.allowsLabel("Travel", in: "Label it travel, please"))
        XCTAssertFalse(LocalInbox.allowsLabel("Travel 2026", in: "label it travel"))
        XCTAssertFalse(LocalInbox.allowsLabel("Invoices", in: "file this under receipts"))
        XCTAssertFalse(LocalInbox.allowsLabel("", in: "label it"))
    }
}
