import XCTest
@testable import CodenameJo

final class DesktopResourceTests: XCTestCase {
    func testBundledOnboardingHasItsWelcomeStep() throws {
        let config = try XCTUnwrap(LocalOnboardingRun.config())
        XCTAssertEqual(config.steps.first?.kind, "welcome")
    }

    func testBundledWelcomeEmailHasCopy() throws {
        let copy = try XCTUnwrap(WelcomeEmail.copy)
        XCTAssertFalse(copy.subject.isEmpty)
        XCTAssertFalse(copy.body.isEmpty)
    }

    func testBundledCoachingStartsWithTheFeedLesson() {
        XCTAssertEqual(CoachingRotation.catalog.first?.capability, "feed")
    }
}
