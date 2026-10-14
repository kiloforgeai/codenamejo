import XCTest
@testable import CodenameJo

/// The phone's calendar list, create and update: what is declared, and the pure halves of running them.
final class CalendarToolsTests: XCTestCase {
    func testDeclaresTheThreeToolsOnlyWithACalendar() {
        let names = CalendarTools.definitions(accounts: ["owner@example.test"]).compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["list_calendar_events", "create_calendar_event", "update_calendar_event"])
        XCTAssertTrue(CalendarTools.definitions(accounts: []).isEmpty)
    }

    func testAFeedMailboxBindsAWriteAndAnUnknownOneIsRefused() throws {
        let accounts = ["owner@example.test", "work@example.test"]
        XCTAssertNil(try CalendarTools.bind(CalendarTools.create, ["account": " "], mailbox: nil, accounts: accounts).get()["account"])
        XCTAssertEqual(try CalendarTools.bind(CalendarTools.create, ["account": "owner@example.test"], mailbox: "WORK@example.test",
                                              accounts: accounts).get()["account"] as? String, "work@example.test")
        XCTAssertThrowsError(try CalendarTools.bind(CalendarTools.update, [:], mailbox: "other@example.test", accounts: accounts).get())
    }

    /// A conflict check from inside the inbox feed covers every connected calendar, not the feed's alone (#113).
    func testAReadInTheFeedSpansEveryCalendarUnlessOneIsNamed() throws {
        let accounts = ["owner@example.test", "work@example.test", "side@example.test"]
        XCTAssertNil(try CalendarTools.bind(CalendarTools.list, ["availability_check": true], mailbox: "work@example.test",
                                            accounts: accounts).get()["account"])
        XCTAssertEqual(try CalendarTools.bind(CalendarTools.list, ["account": "SIDE@example.test"], mailbox: "work@example.test",
                                              accounts: accounts).get()["account"] as? String, "side@example.test")
        XCTAssertThrowsError(try CalendarTools.bind(CalendarTools.list, ["account": "other@example.test"], mailbox: "work@example.test",
                                                    accounts: accounts).get())
    }

    func testAStartAloneKeepsTheLengthInTheStartsOffset() throws {
        let moved = try CalendarTools.retime(
            ("2026-08-07T15:00:00-07:00", "2026-08-07T16:30:00-07:00", false),
            newStart: "2026-08-07T23:00:00-07:00", newEnd: nil).get()
        XCTAssertEqual(moved.end, "2026-08-08T00:30:00-07:00")
        XCTAssertEqual(moved.phrase,
                       "moved from 2026-08-07T15:00:00-07:00 to 2026-08-07T23:00:00-07:00, now ending 2026-08-08T00:30:00-07:00")
        let allDay = try CalendarTools.retime(("2026-08-07", "2026-08-08", true), newStart: "2026-08-10", newEnd: nil).get()
        XCTAssertEqual(allDay.end, "2026-08-11")
        XCTAssertThrowsError(try CalendarTools.retime(("2026-08-07", "2026-08-08", true),
                                                      newStart: "2026-08-10T09:00:00-07:00", newEnd: nil).get())
        XCTAssertThrowsError(try CalendarTools.retime(("2026-08-07T15:00:00-07:00", "2026-08-07T16:00:00-07:00", false),
                                                      newStart: "2026-08-07T17:00:00-07:00", newEnd: "2026-08-07T16:00:00-07:00").get())
    }

    func testAttendeeEditsKeepEveryoneElseAndNeverRemoveTheUser() {
        let current: [[String: Any]] = [["email": "me@example.test", "self": true], ["email": "a@example.test"]]
        let merge = CalendarTools.mergeAttendees(current, add: ["B@example.test", "a@example.test"],
                                                 remove: ["me@example.test"])
        XCTAssertEqual(merge.attendees.compactMap { $0["email"] as? String },
                       ["me@example.test", "a@example.test", "B@example.test"])
        XCTAssertEqual(merge.added, ["B@example.test"])
        XCTAssertTrue(merge.refusedSelfRemoval)
    }

    func testRefusalsKeepTheBrokerOpeners() {
        XCTAssertTrue(CalendarTools.utcRefusal("NOT CREATED", ["2026-08-04T14:00:00Z", nil])?.hasPrefix("NOT CREATED —") == true)
        XCTAssertNil(CalendarTools.utcRefusal("NOT CREATED", ["2026-08-04T14:00:00-07:00"]))
        XCTAssertTrue(CalendarTools.attendeeRefusal("create_calendar_event", ["attendees": ["Sarah"]], canResolve: true)?
            .contains("find_person") == true)
        XCTAssertNil(CalendarTools.attendeeRefusal("create_calendar_event",
                                                   ["attendees": ["Sarah <sarah@example.test>"]], canResolve: true))
        XCTAssertTrue(CalendarTools.isInstanceId("abc_20260807T150000Z"))
    }

    private func cached(_ id: String, start: Int64, end: Int64, allDay: Bool = false, status: String? = "confirmed",
                        transparency: String? = nil, startRaw: String? = nil, endRaw: String? = nil) -> CalendarStore.Event {
        CalendarStore.Event(id: id, calendarId: "primary", account: "me@example.test", summary: "Standup", location: nil,
                            description: nil, startRaw: startRaw, endRaw: endRaw, startEpochMs: start, endEpochMs: end,
                            isAllDay: allDay, status: status, recurringEventId: nil, htmlLink: nil, attendeeCount: nil,
                            cachedAt: Date(), transparency: transparency)
    }

    private func attendee(_ eventId: String, _ email: String, response: String? = nil, organizer: Bool = false)
        -> CalendarStore.Attendee {
        CalendarStore.Attendee(eventId: eventId, calendarId: "primary", email: email, displayName: nil,
                               responseStatus: response, organizer: organizer)
    }

    func testACachedEventKeepsTheLiveShape() {
        let live = CalendarTools.summary(account: "me@example.test", [
            "id": "e1", "summary": "Standup", "hangoutLink": "https://meet.example.test/x",
            "start": ["dateTime": "2026-10-14T09:00:00-04:00"], "end": ["dateTime": "2026-10-14T09:30:00-04:00"],
            "organizer": ["email": "a@example.test"],
            "attendees": [["email": "me@example.test", "self": true, "responseStatus": "tentative"],
                          ["email": "a@example.test", "organizer": true]]])
        var event = cached("e1", start: 0, end: 1, startRaw: "2026-10-14T09:00:00-04:00", endRaw: "2026-10-14T09:30:00-04:00")
        event.hangoutLink = "https://meet.example.test/x"
        let row = CalendarTools.row(account: "me@example.test", event,
                                    [attendee("e1", "me@example.test", response: "tentative"),
                                     attendee("e1", "a@example.test", organizer: true)])
        XCTAssertEqual(Set(row.keys), Set(live.keys))
        for key in ["summary", "start", "end", "responseStatus", "organizer", "hangoutLink"] {
            XCTAssertEqual(row[key] as? String, live[key] as? String, key)
        }
        XCTAssertEqual(row["attendees"] as? [String], live["attendees"] as? [String])
        XCTAssertTrue(CalendarTools.mentions(event, [attendee("e1", "a@example.test")], "a@example"))
        XCTAssertFalse(CalendarTools.mentions(event, [], "budget"))
    }

    /// A created event reaches the cache in the shape the background pass gives it, so the next lookup sees it.
    func testAConfirmedWriteIngestsLikeAListedEvent() throws {
        let created: [String: Any] = [
            "id": "new1", "summary": "Coffee", "status": "confirmed", "transparency": "transparent",
            "hangoutLink": "https://meet.example.test/y",
            "start": ["dateTime": "2026-10-14T09:00:00-04:00"], "end": ["dateTime": "2026-10-14T09:30:00-04:00"],
            "attendees": [["email": "a@example.test", "responseStatus": "needsAction"]]]
        let (event, attendees) = try XCTUnwrap(CalendarTools.ingest(created, account: "me@example.test"))
        XCTAssertEqual(event.id, "new1")
        XCTAssertEqual(event.account, "me@example.test")
        XCTAssertEqual(event.calendarId, "primary")
        XCTAssertEqual(event.transparency, "transparent")
        XCTAssertEqual(event.hangoutLink, "https://meet.example.test/y")
        XCTAssertEqual(event.startEpochMs, Int64(CalendarTools.instant("2026-10-14T09:00:00-04:00")!))
        XCTAssertEqual(attendees.map(\.email), ["a@example.test"])
        XCTAssertNil(CalendarTools.ingest(["summary": "no id"], account: "me@example.test"))
    }

    /// A conflict check from the cache must say what Google's free/busy would: busy unless free, declined or cancelled.
    func testBusyFollowsGooglesFreeBusyRule() {
        let minute: Int64 = 60_000
        let events = [
            cached("early", start: 0, end: 2 * minute),
            cached("overlap", start: minute + minute / 2, end: 3 * minute),
            cached("free", start: 4 * minute, end: 5 * minute, transparency: "transparent"),
            cached("declined", start: 5 * minute, end: 6 * minute),
            cached("gone", start: 6 * minute, end: 7 * minute, status: "cancelled"),
            cached("late", start: 8 * minute, end: 9 * minute),
        ]
        let busy = CalendarTools.busy(events, attendees: [attendee("declined", "ME@example.test", response: "declined")],
                                      account: "me@example.test", window: (minute, 8 * minute + minute / 2), offset: "+00:00")
        XCTAssertEqual(busy.map { "\($0["start"] ?? "")..\($0["end"] ?? "")" },
                       ["1970-01-01T00:01:00+00:00..1970-01-01T00:03:00+00:00",
                        "1970-01-01T00:08:00+00:00..1970-01-01T00:08:30+00:00"])

        let newYork = TimeZone(identifier: "America/New_York")!
        let holiday = cached("holiday", start: 0, end: 0, allDay: true, startRaw: "2026-10-14", endRaw: "2026-10-15")
        let day = (Int64(CalendarTools.instant("2026-10-13T12:00:00-04:00")!), Int64(CalendarTools.instant("2026-10-15T12:00:00-04:00")!))
        XCTAssertEqual(CalendarTools.busy([holiday], attendees: [], account: "me@example.test", window: day,
                                          offset: "-04:00", zone: newYork),
                       [["start": "2026-10-14T00:00:00-04:00", "end": "2026-10-15T00:00:00-04:00"]])
    }

    func testAListedEventKeepsTheBrokersShape() {
        let event: [String: Any] = ["id": "e1", "start": ["date": "2026-08-07"], "end": ["date": "2026-08-08"],
                                    "attendees": [["email": "me@example.test", "self": true, "responseStatus": "tentative"]]]
        let summary = CalendarTools.summary(account: "me@example.test", event)
        XCTAssertEqual(summary["allDay"] as? Bool, true)
        XCTAssertEqual(summary["summary"] as? String, "(no title)")
        XCTAssertEqual(summary["responseStatus"] as? String, "tentative")
        XCTAssertNil(summary["moreAttendees"])
    }
}
