import XCTest
@testable import CodenameJo

/// The on-device model only picks a day offset, a clock time or a name; everything the user
/// hears about the calendar is worded here, and only their own words can write to it.
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
        // Cancelling looks at the whole of today, started or not.
        let wholeDay = LocalVoiceCalendar.dayWindow(dayOffset: 0, now: now, calendar: calendar)
        XCTAssertEqual(wholeDay.startMs, 1_791_950_400_000)
        XCTAssertEqual(wholeDay.endMs, 1_792_036_800_000)
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

    func testOnlyTheUsersOwnWordsCanAddOrCancel() {
        for text in ["add a dentist appointment tomorrow at 3", "block 2 to 3 for focus", "put it on my calendar",
                     "can you schedule lunch with Sam Friday at noon", "set up a call with Raghav at 4"] {
            XCTAssertTrue(LocalVoiceCalendar.allowsCreate(text), text)
        }
        for text in ["am I free tomorrow at 3", "don't add anything", "what's on Thursday",
                     "never put that on my calendar"] {
            XCTAssertFalse(LocalVoiceCalendar.allowsCreate(text), text)
        }
        for text in ["cancel the dentist tomorrow", "delete my 3 o'clock", "take standup off my calendar",
                     "get rid of the Friday lunch"] {
            XCTAssertTrue(LocalVoiceCalendar.allowsCancel(text), text)
        }
        for text in ["is the dentist still on tomorrow", "don't cancel the dentist", "move the dentist to 4"] {
            XCTAssertFalse(LocalVoiceCalendar.allowsCancel(text), text)
        }
    }

    func testANameFindsOneEventOrSaysWhyNot() {
        let dentist = event("Dentist", at: 1_792_090_800)
        let lunch = event("Lunch", at: 1_792_080_000)
        let events = [
            event("Standup", at: 1_792_071_000),
            dentist,
            lunch,
            event("Dentist follow-up", at: 1_792_071_000, status: "cancelled"),
            event("Team standup", at: 1_792_092_600),
        ]
        XCTAssertEqual(LocalVoiceCalendar.matches(events, title: "the dentist").map(\.id), [dentist.id])
        XCTAssertEqual(LocalVoiceCalendar.matches(events, title: "DENTIST appointment").map(\.id), [dentist.id])
        XCTAssertEqual(LocalVoiceCalendar.matches(events, title: "12 to 1 lunch").map(\.id), [lunch.id])
        XCTAssertEqual(LocalVoiceCalendar.matches(events, title: "standup").count, 2)
        XCTAssertEqual(LocalVoiceCalendar.matches(events, title: "standup", hour: 9, calendar: calendar).count, 1)
        XCTAssertEqual(LocalVoiceCalendar.matches(events, title: "3 pm", hour: 15, calendar: calendar).map(\.id),
                       [dentist.id])
        XCTAssertTrue(LocalVoiceCalendar.matches(events, title: "coffee").isEmpty)
        XCTAssertTrue(LocalVoiceCalendar.matches(events, title: "the").isEmpty)

        XCTAssertNil(LocalVoiceCalendar.ambiguity([dentist], title: "dentist", dayOffset: 1, now: now, calendar: calendar))
        XCTAssertEqual(LocalVoiceCalendar.ambiguity([], title: "lunch", dayOffset: 1, now: now, calendar: calendar),
                       "Nothing called lunch tomorrow. Nothing was cancelled.")
        XCTAssertEqual(
            LocalVoiceCalendar.ambiguity(LocalVoiceCalendar.matches(events, title: "standup"), title: "standup",
                                         dayOffset: 1, now: now, calendar: calendar),
            "2 things tomorrow match standup: Standup at 9:30 AM, and Team standup at 3:30 PM. "
                + "Ask which one; nothing was cancelled.")
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

        let dentist = event("Dentist", at: 1_792_090_800)
        XCTAssertEqual(
            LocalVoiceCalendar.cancelled("Cancelled \"Dentist\" (Oct 15, 3:00 PM) on a@b.c.", event: dentist, now: now,
                                         calendar: calendar),
            "Cancelled Dentist, tomorrow at 3 PM.")
        XCTAssertEqual(
            LocalVoiceCalendar.cancelled("Cancelled \"Dentist\" on a@b.c. The 2 guests were emailed a cancellation.",
                                         event: dentist, now: now, calendar: calendar),
            "Cancelled Dentist, tomorrow at 3 PM. Your guests were told.")
        XCTAssertEqual(
            LocalVoiceCalendar.cancelled("Took \"Dentist\" off a@b.c's calendar. The user didn't organize it, so …",
                                         event: dentist, now: now, calendar: calendar),
            "Took Dentist, tomorrow at 3 PM off your calendar. You didn't organize it, so it's still on everyone else's.")
        let already = "\"Dentist\" was already cancelled. Nothing to do, and nobody was notified again."
        XCTAssertEqual(LocalVoiceCalendar.cancelled(already, event: dentist, now: now, calendar: calendar), already)
    }
}
