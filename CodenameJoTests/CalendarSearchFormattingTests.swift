import XCTest
@testable import CodenameJo

/// A calendar lookup is the only thing standing between "Google was unreachable" and "your
/// afternoon is free". `formatted` has to keep those apart, and `singlePendingRSVP` has to
/// refuse to guess which invitation was meant.
final class CalendarSearchFormattingTests: XCTestCase {
    private func event(
        id: String, account: String, summary: String? = "Standup", location: String? = nil,
        attendeeCount: Int? = nil, startEpochMs: Int64? = 1_700_000_000_000,
        calendarId: String = "primary"
    ) -> CalendarStore.Event {
        CalendarStore.Event(
            id: id, calendarId: calendarId, account: account, summary: summary,
            location: location, description: nil, startRaw: nil, endRaw: nil,
            startEpochMs: startEpochMs, endEpochMs: startEpochMs.map { $0 + 1_800_000 },
            isAllDay: false, status: "confirmed", recurringEventId: nil, htmlLink: nil,
            attendeeCount: attendeeCount, cachedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func attendee(
        eventId: String, email: String, response: String?, organizer: Bool = false,
        displayName: String? = nil, calendarId: String = "primary"
    ) -> CalendarStore.Attendee {
        CalendarStore.Attendee(
            eventId: eventId, calendarId: calendarId, email: email,
            displayName: displayName, responseStatus: response, organizer: organizer)
    }

    private func result(
        events: [CalendarStore.Event], attendees: [CalendarStore.Attendee] = [],
        covered: Bool = true, servedLive: Bool = false, successful: Bool = true
    ) -> CalendarSearch.Result {
        CalendarSearch.Result(events: events, attendees: attendees, covered: covered,
                              servedLive: servedLive, successful: successful, ms: 3)
    }

    func testAnUnreachableLookupIsNeverRenderedAsAnEmptyCalendar() {
        let rendered = CalendarSearch.formatted(
            result(events: [], covered: false, servedLive: true, successful: false),
            query: "budget review")
        XCTAssertTrue(rendered.lowercased().contains("unavailable"))
        // Neither sentence the empty branches use may leak here, or a dead lookup reads as
        // a free window.
        XCTAssertFalse(rendered.contains("Nothing on the calendar"))
        XCTAssertFalse(rendered.contains("No calendar events matching"))
    }

    func testAnEmptyCoveredWindowIsStatedPlainlyAndAnEmptyLiveOneSaysGoogleWasAsked() {
        let cached = CalendarSearch.formatted(result(events: []), query: "  ")
        XCTAssertTrue(cached.contains("Nothing on the calendar"))
        XCTAssertFalse(cached.contains("checked directly"))
        let live = CalendarSearch.formatted(
            result(events: [], covered: false, servedLive: true), query: "  ")
        XCTAssertTrue(live.contains("Nothing on the calendar"))
        XCTAssertTrue(live.contains("checked directly"))
    }

    func testAWhitespaceOnlyQueryIsNotQuotedBackButARealOneIs() {
        let blank = CalendarSearch.formatted(result(events: []), query: "\n\t ")
        XCTAssertFalse(blank.contains("matching"))
        let asked = CalendarSearch.formatted(result(events: []), query: "1:1")
        XCTAssertTrue(asked.contains("matching \"1:1\""))
    }

    func testEveryEventLineCarriesTheRealGoogleIdInsideTheUntrustedFence() {
        let rendered = CalendarSearch.formatted(
            result(events: [event(id: "evt-a", account: "me@x.test"),
                            event(id: "evt-b", account: "me@x.test", location: "Room 2")]),
            query: "")
        let lines = rendered.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.firstIndex { $0.contains("untrusted calendar content") }, 1)
        XCTAssertEqual(lines.last?.contains("end untrusted"), true)
        XCTAssertTrue(lines.contains { $0.hasPrefix("- [evt-a]") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("- [evt-b]") && $0.contains("at Room 2") })
        XCTAssertTrue(lines[0].contains("2 event(s)"))
        // A cache hit says nothing about going live; the header is otherwise identical.
        XCTAssertFalse(lines[0].contains("checked directly"))
    }

    func testAnEventWithNoTitleOrStartStillRendersRatherThanVanishing() {
        let rendered = CalendarSearch.formatted(
            result(events: [event(id: "e1", account: "me@x.test", summary: nil, startEpochMs: nil)]),
            query: "")
        XCTAssertTrue(rendered.contains("(no title)"))
        XCTAssertTrue(rendered.contains("time unknown"))
        XCTAssertTrue(rendered.contains("1 event(s)"))
    }

    func testTheRosterNamesTheAccountItselfAndCountsWhatItDidNotShow() {
        let owner = "me@x.test"
        var roster = [
            attendee(eventId: "e1", email: owner, response: "accepted", displayName: "  "),
            attendee(eventId: "e1", email: "boss@x.test", response: "accepted",
                     organizer: true, displayName: "Boss"),
        ]
        roster += (0..<12).map { attendee(eventId: "e1", email: "p\($0)@x.test", response: nil) }
        let rendered = CalendarSearch.formatted(
            result(events: [event(id: "e1", account: owner, attendeeCount: 20)],
                   attendees: roster),
            query: "")
        XCTAssertTrue(rendered.contains("\(owner) [self; response: accepted]"))
        // The organizer sorts first, and a blank display name falls back to the address.
        XCTAssertTrue(rendered.contains("attendees: Boss <boss@x.test> [organizer;"))
        XCTAssertTrue(rendered.contains("response: unknown"))
        // Ten shown out of Google's own count of twenty, and the rest are counted.
        XCTAssertTrue(rendered.contains("10 more not shown"))
    }

    func testAttendeesOfAnotherEventOrCalendarAreNeverBorrowed() {
        let rendered = CalendarSearch.formatted(
            result(events: [event(id: "e1", account: "me@x.test")],
                   attendees: [
                    attendee(eventId: "e2", email: "other@x.test", response: "accepted"),
                    attendee(eventId: "e1", email: "wrong@x.test", response: "ok",
                             calendarId: "work")]),
            query: "")
        XCTAssertFalse(rendered.contains("other@x.test"))
        XCTAssertFalse(rendered.contains("wrong@x.test"))
        XCTAssertFalse(rendered.contains("attendees:"))
    }

    func testOnlyTheAccountsOwnNeedsActionRowMakesAnInvitationUnambiguous() {
        let owner = "me@x.test"
        let events = [event(id: "e1", account: owner), event(id: "e2", account: owner)]
        let one = result(events: events, attendees: [
            attendee(eventId: "e1", email: "ME@X.test", response: "NeedsAction"),
            // Somebody else not having replied is not this user's invitation.
            attendee(eventId: "e2", email: "them@x.test", response: "needsAction"),
            attendee(eventId: "e2", email: owner, response: "accepted")])
        XCTAssertEqual(CalendarSearch.singlePendingRSVP(one)?.id, "e1")
        let ambiguous = result(events: events, attendees: [
            attendee(eventId: "e1", email: owner, response: "needsAction"),
            attendee(eventId: "e2", email: owner, response: "needsAction")])
        XCTAssertNil(CalendarSearch.singlePendingRSVP(ambiguous))
        XCTAssertNil(CalendarSearch.singlePendingRSVP(result(events: [])))
    }
}
