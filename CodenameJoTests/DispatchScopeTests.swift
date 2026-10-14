import XCTest
@testable import CodenameJo

final class DispatchScopeTests: XCTestCase {
    func testIndependentAnswerKeepsTheLatestEmailReferentWithoutPresentingIt() {
        let note = DispatchScope.independentReport(task: "Weather", result: "Sunny, 67 degrees.",
            ok: true, standingStep: #"{"item":{"id":"email-after-user-advanced"}}"#)
        XCTAssertTrue(note.contains("Sunny, 67 degrees."))
        XCTAssertTrue(note.contains("email-after-user-advanced"))
        XCTAssertTrue(note.contains("this is NOT what the result is about"))
        XCTAssertTrue(note.contains("Do not advance, re-present an email"))
        XCTAssertFalse(note.contains("handoff dealt with it"))
        XCTAssertFalse(note.contains("What would you like to do with it?"))
    }

    func testIndependentFailureIsStillReportedWithoutAnEmailReturn() {
        let note = DispatchScope.independentReport(task: "Weather", result: "Search unavailable.",
            ok: false, standingStep: nil)
        XCTAssertTrue(note.contains("work did not complete"))
        XCTAssertTrue(note.contains("Search unavailable."))
        XCTAssertFalse(note.contains("Current email context"))
    }
}
