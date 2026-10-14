import XCTest
@testable import CodenameJo

/// One row of the live step list: whether it is still running, whether it worked, and how
/// long it says it took.
///
/// Two of these have cost something real. A step drawn from the tool's name alone read
/// "sent it" with a tick beside a send that had been refused — the one moment a user could
/// have caught a write that did not happen. And a duration of zero means the broker did not
/// know, so printing `0.0s` would be a measurement nobody took.
final class TurnStepTests: XCTestCase {

    private let started = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Running

    func testAStepWithNoEndIsStillRunningAndClaimsNoDuration() {
        let step = TurnStep(tool: "gmail_search_messages", startedAt: started)

        XCTAssertTrue(step.isRunning)
        XCTAssertNil(step.elapsed)
        XCTAssertEqual(step.outcome.symbol, "circle.dotted")
        XCTAssertFalse(step.outcome.isFailure)
        XCTAssertEqual(step.label, ToolNarration.progressLabel(for: "gmail_search_messages"))
    }

    func testAStepThatHasEndedSwitchesToItsFinishedLabel() {
        var step = TurnStep(tool: "gmail_search_messages", startedAt: started)
        step.endedAt = started.addingTimeInterval(1)

        XCTAssertFalse(step.isRunning)
        XCTAssertEqual(step.label, ToolNarration.doneLabel(for: "gmail_search_messages"))
    }

    // MARK: - Outcome

    func testARefusedStepIsDrawnAsAFailureRatherThanATick() {
        var step = TurnStep(tool: "gmail_send_email", startedAt: started)
        step.endedAt = started.addingTimeInterval(0.4)
        step.failed = true

        XCTAssertEqual(step.outcome.symbol, "exclamationmark.triangle.fill")
        XCTAssertTrue(step.outcome.isFailure)
    }

    func testAStepStillInFlightIsNeverDrawnAsAFailure() {
        var step = TurnStep(tool: "gmail_send_email", startedAt: started)
        step.failed = true

        XCTAssertEqual(
            step.outcome.symbol, "circle.dotted",
            "running wins: there is no outcome to report yet")
        XCTAssertFalse(step.outcome.isFailure)
    }

    func testAFinishedStepThatDidNotFailIsATick() {
        var step = TurnStep(tool: "gmail_archive_message", startedAt: started)
        step.endedAt = started.addingTimeInterval(0.2)

        XCTAssertEqual(step.outcome.symbol, "checkmark")
        XCTAssertFalse(step.outcome.isFailure)
    }

    // MARK: - How long it took

    func testWallClockIsUsedOnlyWhenTheBrokerDidNotMeasure() {
        var step = TurnStep(tool: "gmail_search_messages", startedAt: started)
        step.endedAt = started.addingTimeInterval(1.5)

        XCTAssertEqual(try XCTUnwrap(step.elapsed), 1.5, accuracy: 0.0001)
    }

    func testTheBrokersOwnMeasurementOutranksTheGuessFromTheFrameTimes() {
        var step = TurnStep(tool: "gmail_search_messages", startedAt: started)
        step.endedAt = started.addingTimeInterval(1.5)
        step.serverMilliseconds = 250

        XCTAssertEqual(
            try XCTUnwrap(step.elapsed), 0.25, accuracy: 0.0001,
            "with tools called in parallel the frame-time guess is wrong for all but the last")
    }

    func testAZeroFromTheBrokerMeansUnknownRatherThanInstant() {
        var step = TurnStep(tool: "gmail_search_messages", startedAt: started)
        step.endedAt = started.addingTimeInterval(1.5)
        step.serverMilliseconds = 0

        XCTAssertNil(step.elapsed, "showing 0.0s would be a measurement nobody took")
    }

    // MARK: - Identity

    func testTwoCallsToTheSameToolAreTwoRows() {
        let first = TurnStep(tool: "gmail_archive_message", startedAt: started)
        let second = TurnStep(tool: "gmail_archive_message", startedAt: started)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first, second)
    }
}
