import XCTest
@testable import CodenameJo

/// The on-device model only picks a day offset and a clock time; everything the user hears
/// about the calendar is worded here.
final class LocalVoiceCalendarTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/New_York")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
    /// Wednesday, October 14, 2026, 3:12 PM in New York.
    private let now = Date(timeIntervalSince1970: 1_792_005_120)

    private func event(_ summary: String?, at seconds: TimeInterval, location: String? = nil,
                       allDay: Bool = false, status: String = "confirmed") -> CalendarStore.Event {
        CalendarStore.Event(
            id: UUID().uuidString, calendarId: "primary", account: "a@b.c", summary: summary, location: location,
            description: nil, startRaw: nil, endRaw: nil, startEpochMs: Int64(seconds * 1000),
            endEpochMs: Int64((seconds + 1800) * 1000), isAllDay: allDay, status: status,
            recurringEventId: nil, htmlLink: nil, attendeeCount: nil, cachedAt: now)
    }

    func testTheNowLineNamesTheWeekdayAndTheClock() {
        XCTAssertEqual(LocalVoiceCalendar.spokenNow(now, calendar: calendar), "Wednesday, October 14, 2026, 3:12 PM")
    }

    func testDayZeroRunsFromNowToMidnightAndLaterDaysAreWhole() {
        let today = LocalVoiceCalendar.window(dayOffset: 0, days: 1, now: now, calendar: calendar)
        XCTAssertEqual(today.startMs, 1_792_005_120_000)
        XCTAssertEqual(today.endMs, 1_792_036_800_000)
        let tomorrow = LocalVoiceCalendar.window(dayOffset: 1, days: 1, now: now, calendar: calendar)
        XCTAssertEqual(tomorrow.startMs, 1_792_036_800_000)
        XCTAssertEqual(tomorrow.endMs, 1_792_123_200_000)
        // A month clamps to a week: midnight on October 21.
        let week = LocalVoiceCalendar.window(dayOffset: 0, days: 30, now: now, calendar: calendar)
        XCTAssertEqual(week.endMs, 1_792_555_200_000)
    }

    func testAStartIsStampedWithThePhonesOffsetOnThatDay() {
        let tomorrow = LocalVoiceCalendar.start(dayOffset: 1, hour: 15, minute: 30, now: now, calendar: calendar)!
        XCTAssertEqual(LocalVoiceCalendar.stamp(tomorrow, zone: zone), "2026-10-15T15:30:00-04:00")
        // After the clocks change on November 1.
        let november = LocalVoiceCalendar.start(dayOffset: 20, hour: 15, minute: 30, now: now, calendar: calendar)!
        XCTAssertEqual(LocalVoiceCalendar.stamp(november, zone: zone), "2026-11-03T15:30:00-05:00")
    }

    func testADayIsSpokenInStartOrderWithoutCancellations() {
        let events = [
            event("Dentist", at: 1_792_090_800, location: "Main Street"),
            event("Standup", at: 1_792_071_000),
            event("Old plan", at: 1_792_071_000, status: "cancelled"),
        ]
        XCTAssertEqual(LocalVoiceCalendar.spoken(events, dayOffset: 1, days: 1, now: now, calendar: calendar),
                       "Tomorrow you have 2 things: Standup at 9:30 AM, and Dentist at 3 PM at Main Street.")
        XCTAssertEqual(LocalVoiceCalendar.spoken([], dayOffset: 1, days: 1, now: now, calendar: calendar),
                       "Nothing on your calendar tomorrow.")
        XCTAssertEqual(LocalVoiceCalendar.spoken([event(nil, at: 1_792_159_200, allDay: true)], dayOffset: 2, days: 1,
                                                 now: now, calendar: calendar),
                       "On Friday you have one thing: an untitled event all day.")
        XCTAssertEqual(LocalVoiceCalendar.spoken([event("Standup", at: 1_792_071_000)], dayOffset: 0, days: 3,
                                                 now: now, calendar: calendar),
                       "Over the next 3 days you have one thing: Standup at 9:30 AM on Thursday.")
    }

    func testOnlyTheUsersOwnWordsCanAddAnEvent() {
        for text in ["add a dentist appointment tomorrow at 3", "block 2 to 3 for focus", "put it on my calendar",
                     "can you schedule lunch with Sam Friday at noon", "set up a call with Raghav at 4"] {
            XCTAssertTrue(LocalVoiceCalendar.allowsCreate(text), text)
        }
        for text in ["am I free tomorrow at 3", "don't add anything", "what's on Thursday",
                     "never put that on my calendar"] {
            XCTAssertFalse(LocalVoiceCalendar.allowsCreate(text), text)
        }
    }

    func testAReceiptBecomesASpokenLineAndARefusalPassesThrough() {
        let start = Date(timeIntervalSince1970: 1_792_090_800)
        XCTAssertEqual(
            LocalVoiceCalendar.added("Created \"Dentist\" (abc123) on a@b.c. https://calendar.google.com/x",
                                     title: "Dentist", start: start, minutes: 60, now: now, calendar: calendar),
            "Added Dentist, tomorrow at 3 PM for an hour.")
        XCTAssertEqual(
            LocalVoiceCalendar.added("Created \"Focus\" (abc123) on a@b.c.", title: "Focus",
                                     start: Date(timeIntervalSince1970: 1_792_159_200), minutes: 90, now: now,
                                     calendar: calendar),
            "Added Focus, on Friday at 10 AM for an hour and a half.")
        let refusal = "Need a title, a start and an end to create an event."
        XCTAssertEqual(LocalVoiceCalendar.added(refusal, title: "x", start: start, minutes: 60, now: now,
                                                calendar: calendar), refusal)
    }
}
