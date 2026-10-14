import XCTest
@testable import CodenameJo

/// The automatic calendar stage is offered once per mailbox per local day. Two things can
/// go wrong quietly: one mailbox's successful read suppressing another's, and the "day"
/// being a 24-hour add rather than the calendar's own day — which is an hour out on the
/// two days a year the clocks move.
final class CalendarFeedCadenceTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "CalendarFeedCadenceTests"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    /// A UTC instant, so every expectation below is written as a wall clock the reader can check.
    private func instant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return calendar("UTC").date(from: components)!
    }

    func testOwnersAreNormalisedDeduplicatedAndStrippedOfBlanks() {
        let owners = CalendarFeedCadence.owners(
            accounts: [" Josh@Example.test ", "josh@example.test", "  ", "other@example.test"],
            userId: "user-1")
        XCTAssertEqual(owners, ["account:josh@example.test", "account:other@example.test"])
    }

    func testTheUserIsOnlyTheOwnerWhenNoMailboxIsKnown() {
        XCTAssertEqual(CalendarFeedCadence.owners(accounts: [], userId: " user-1 "), ["user:user-1"])
        // A known mailbox always wins: falling back as well would give one account two cursors.
        XCTAssertEqual(
            CalendarFeedCadence.owners(accounts: ["a@example.test"], userId: "user-1"),
            ["account:a@example.test"])
        XCTAssertTrue(CalendarFeedCadence.owners(accounts: ["   "], userId: nil).isEmpty)
        XCTAssertTrue(CalendarFeedCadence.owners(accounts: [], userId: "  ").isEmpty)
    }

    func testNothingToOfferIsNeverDue() {
        XCTAssertFalse(CalendarFeedCadence.isDue(
            owners: [], date: instant(2026, 3, 10, 12, 0), calendar: calendar("UTC"),
            defaults: defaults))
    }

    func testCompletingOneMailboxLeavesTheOtherDue() {
        let utc = calendar("UTC")
        let now = instant(2026, 3, 10, 12, 0)
        let first = "account:a@example.test"
        let second = "account:b@example.test"

        CalendarFeedCadence.markComplete(owners: [first], date: now, calendar: utc, defaults: defaults)

        XCTAssertFalse(CalendarFeedCadence.isDue(
            owners: [first], date: now, calendar: utc, defaults: defaults))
        XCTAssertTrue(CalendarFeedCadence.isDue(
            owners: [second], date: now, calendar: utc, defaults: defaults))
        // Any outstanding owner keeps the pass due, so a second mailbox is not skipped.
        XCTAssertTrue(CalendarFeedCadence.isDue(
            owners: [first, second], date: now, calendar: utc, defaults: defaults))
    }

    func testCompletionLastsUntilTheLocalDayEndsAndNoLonger() {
        let utc = calendar("UTC")
        let owners = ["account:a@example.test"]
        CalendarFeedCadence.markComplete(
            owners: owners, date: instant(2026, 3, 10, 23, 59), calendar: utc, defaults: defaults)

        XCTAssertFalse(CalendarFeedCadence.isDue(
            owners: owners, date: instant(2026, 3, 10, 0, 0), calendar: utc, defaults: defaults))
        XCTAssertTrue(CalendarFeedCadence.isDue(
            owners: owners, date: instant(2026, 3, 11, 0, 0), calendar: utc, defaults: defaults))
    }

    /// The same instant belongs to different days in different zones, so the stamp has to be
    /// read back through the calendar that wrote it.
    func testTheDayIsTheCalendarsDayNotUTCs() {
        let newYork = calendar("America/New_York")
        let midnightUTC = instant(2026, 3, 10, 0, 30)
        XCTAssertEqual(CalendarFeedCadence.localDay(for: midnightUTC, calendar: calendar("UTC")), "2026-03-10")
        XCTAssertEqual(CalendarFeedCadence.localDay(for: midnightUTC, calendar: newYork), "2026-03-09")
    }

    func testTheReadWindowRunsFromNowToLocalMidnight() {
        let now = instant(2026, 3, 10, 12, 0)
        let window = CalendarFeedCadence.restOfLocalDay(now: now, calendar: calendar("UTC"))
        XCTAssertEqual(window.startMs, Int64(now.timeIntervalSince1970 * 1000))
        XCTAssertEqual(window.endMs, Int64(instant(2026, 3, 11, 0, 0).timeIntervalSince1970 * 1000))
        XCTAssertLessThan(window.startMs, window.endMs)
    }

    /// 8 March 2026 is 23 hours long in New York — US clocks go forward at 02:00 local. A
    /// `startOfDay + 24h` window would end an hour into the next day and pull tomorrow's
    /// first event into today's feed.
    func testTheReadWindowDoesNotOverrunTheDayTheClocksChange() {
        let newYork = calendar("America/New_York")
        let now = instant(2026, 3, 8, 12, 0)                       // 08:00 EDT
        let window = CalendarFeedCadence.restOfLocalDay(now: now, calendar: newYork)

        let localMidnight = instant(2026, 3, 9, 4, 0)              // 00:00 EDT on the 9th
        XCTAssertEqual(window.endMs, Int64(localMidnight.timeIntervalSince1970 * 1000))
        XCTAssertNotEqual(
            window.endMs,
            Int64(instant(2026, 3, 9, 5, 0).timeIntervalSince1970 * 1000),
            "A 24-hour add from local midnight would land here, an hour into the next day")
    }
}
