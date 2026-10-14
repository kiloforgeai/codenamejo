import XCTest
@testable import CodenameJo

/// How old a recalled row says it is.
///
/// Nothing in the local context store expires, so the age handed back with a hit is the only
/// signal that a stored answer is stale — and the broker's own formatter printed `4320m ago`
/// for a three-day-old row before it was fixed. Every assertion here pins a unit boundary,
/// because that is where a number like that comes from.
final class ContextRowAgeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(secondsOld: TimeInterval) -> LocalContextRow {
        LocalContextRow(
            id: nil,
            key: "m_1",
            kind: "message",
            request: "the email from Rob about Tuesday",
            result: "{}",
            summary: "",
            conversationId: "conversation-1",
            userId: "owner",
            embedding: nil,
            createdAt: now.addingTimeInterval(-secondsOld))
    }

    private func age(secondsOld: TimeInterval) -> String {
        row(secondsOld: secondsOld).age(now: now)
    }

    // MARK: - Minutes

    func testTheFirstMinuteIsNotCountedInMinutes() {
        XCTAssertEqual(age(secondsOld: 0), "just now")
        XCTAssertEqual(age(secondsOld: 59), "just now")
    }

    func testAMinuteOldIsTheFirstRowWithANumberOnIt() {
        XCTAssertEqual(age(secondsOld: 60), "1m ago")
        XCTAssertEqual(age(secondsOld: 119), "1m ago", "minutes truncate rather than round")
        XCTAssertEqual(age(secondsOld: 120), "2m ago")
    }

    // MARK: - Hours and days, which is where the broker's bug was

    func testMinutesStopAtTheHourInsteadOfRunningOn() {
        XCTAssertEqual(age(secondsOld: 3599), "59m ago")
        XCTAssertEqual(age(secondsOld: 3600), "1h ago")
    }

    func testHoursStopAtTheDay() {
        XCTAssertEqual(age(secondsOld: 86_399), "23h ago")
        XCTAssertEqual(age(secondsOld: 86_400), "1d ago")
    }

    /// The exact row the broker printed as `4320m ago`.
    func testAThreeDayOldRowIsReportedInDays() {
        XCTAssertEqual(age(secondsOld: 3 * 86_400), "3d ago")
    }

    // MARK: - A clock that disagrees with itself

    func testARowStampedInTheFutureIsNotAgedNegatively() {
        XCTAssertEqual(
            row(secondsOld: -600).age(now: now), "just now",
            "a clock change must not print a negative age")
    }
}
