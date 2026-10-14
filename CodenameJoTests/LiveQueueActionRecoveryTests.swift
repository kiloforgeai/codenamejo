import XCTest
@testable import CodenameJo

final class LiveQueueActionRecoveryTests: XCTestCase {
    func testMissingExecutionRetriesOnceThenFailsWithoutSpeech() {
        var request = LiveQueueActionRecovery(now: 10)
        XCTAssertNil(request.poll(now: 11.49))
        XCTAssertEqual(request.poll(now: 11.5), .retry)
        XCTAssertNil(request.poll(now: 11.51))
        XCTAssertEqual(request.poll(now: 16.5), .failed)
        XCTAssertNil(request.poll(now: 100))
    }

    func testStartingWorkDisarmsRecoveryBeforeOrAfterRetry() {
        for retry in [false, true] {
            var request = LiveQueueActionRecovery(now: 0)
            if retry { XCTAssertEqual(request.poll(now: 2), .retry) }
            request.started()
            XCTAssertNil(request.poll(now: 100))
        }
    }

    func testRecoveryAnchorIncludesGroupedSelectionProfileAndRevision() {
        let step = #"{"item":{"messages":[{"id":"a"},{"id":"b"}]}}"#
        let anchor = LiveQueueActionRecovery.Anchor(step: step, profileId: "personal", revision: 3)
        XCTAssertTrue(anchor.matches(step: step, profileId: "personal", revision: 3))
        XCTAssertFalse(anchor.matches(step: step, profileId: "work", revision: 3))
        XCTAssertFalse(anchor.matches(step: step, profileId: "personal", revision: 4))
        XCTAssertFalse(anchor.matches(step: step.replacingOccurrences(of: "b", with: "c"),
                                      profileId: "personal", revision: 3))
        XCTAssertFalse(anchor.matches(step: nil, profileId: "personal", revision: 3))
    }
}
