import XCTest
@testable import CodenameJo

final class GmailQueueExhaustionTests: XCTestCase {
    func testPageBudgetWithMoreMailIsNotTerminal() {
        XCTAssertEqual(
            LocalTriageQueue.gmailEmptyDisposition(hasMore: true, stalled: false),
            .continuePaging)
        XCTAssertNil(LocalTriageQueue.gmailEmptyDisposition(hasMore: false, stalled: false))
    }

    func testUnavailableGmailIsNotAnEmptyInbox() {
        XCTAssertEqual(
            LocalTriageQueue.gmailEmptyDisposition(hasMore: true, stalled: true),
            .retryUnavailable)
    }

    func testOnlyMessagesDealtWithInCurrentWalkAreSuppressed() {
        let old = item("handled-yesterday")
        let current = item("handled-this-walk")

        XCTAssertEqual(
            LocalTriageQueue.gmailEligible(
                [old, current], dealtWithThisWalk: [LocalTriageQueue.messageKey(account: current.account, id: current.id)]
            ).map(\.id),
            [old.id])
    }

    private func item(_ id: String) -> LocalTriageQueue.Item {
        .init(
            account: "me@example.test", id: id, threadId: id, from: "Sender",
            subject: id, date: "Sep 4", snippet: "", internalDate: 1)
    }
}
