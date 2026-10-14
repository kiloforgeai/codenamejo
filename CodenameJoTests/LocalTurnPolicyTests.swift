import XCTest
@testable import CodenameJo

final class LocalTurnPolicyTests: XCTestCase {
    private let start = ContinuousClock.now

    func testATurnEndsAfterTheSilenceWindowAndNotBefore() {
        var policy = LocalTurnPolicy()
        policy.observe("archive this", at: start)
        XCTAssertFalse(policy.isComplete(at: start + .milliseconds(500)))
        XCTAssertTrue(policy.isComplete(at: start + LocalTurnPolicy.silence))
        XCTAssertEqual(policy.text, "archive this")
    }

    func testARevisionRestartsTheWindowAndTheSameWordsDoNot() {
        var policy = LocalTurnPolicy()
        policy.observe("archive", at: start)
        policy.observe("archive this", at: start + .milliseconds(600))
        XCTAssertFalse(policy.isComplete(at: start + .milliseconds(1000)))
        policy.observe("archive this ", at: start + .milliseconds(1200))
        XCTAssertTrue(policy.isComplete(at: start + .milliseconds(1500)))
    }

    func testNothingHeardNeverCompletes() {
        var policy = LocalTurnPolicy()
        policy.observe("   ", at: start)
        XCTAssertFalse(policy.isComplete(at: start + .seconds(10)))
        policy.observe("hello", at: start)
        policy.reset()
        XCTAssertFalse(policy.isComplete(at: start + .seconds(10)))
        XCTAssertEqual(policy.text, "")
    }
}
