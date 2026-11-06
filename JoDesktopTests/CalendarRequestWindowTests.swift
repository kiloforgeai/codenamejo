import XCTest
@testable import CodenameJo

@MainActor
final class CalendarRequestWindowTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func window(_ stamp: String = "2026-10-29T10:00:00-07:00", zone: String = "America/Los_Angeles") -> CalendarRequestWindow {
        CalendarRequestWindow(request: "Check next week across all three calendars", reference: date(stamp), zone: TimeZone(identifier: zone)!)!
    }

    func testNextWeekUsesMondayBoundariesAndDateSpecificOffsets() {
        let cases = [
            ("2026-10-29T10:00:00-07:00", "America/Los_Angeles", "2026-11-02T00:00:00-08:00", "2026-11-09T00:00:00-08:00"),
            ("2026-11-01T12:00:00-08:00", "America/Los_Angeles", "2026-11-02T00:00:00-08:00", "2026-11-09T00:00:00-08:00"),
            ("2026-11-02T00:00:00-08:00", "America/Los_Angeles", "2026-11-09T00:00:00-08:00", "2026-11-16T00:00:00-08:00"),
            ("2026-10-22T12:00:00-07:00", "America/Los_Angeles", "2026-10-26T00:00:00-07:00", "2026-11-02T00:00:00-08:00"),
            ("2026-12-31T12:00:00-05:00", "America/New_York", "2027-01-04T00:00:00-05:00", "2027-01-11T00:00:00-05:00"),
            ("2026-10-25T23:30:00Z", "Asia/Tokyo", "2026-11-02T00:00:00+09:00", "2026-11-09T00:00:00+09:00"),
            ("2026-10-25T23:30:00Z", "America/Los_Angeles", "2026-10-26T00:00:00-07:00", "2026-11-02T00:00:00-08:00")]
        for (now, zone, start, end) in cases {
            let value = window(now, zone: zone)
            XCTAssertEqual(value.stamp(value.start), start)
            XCTAssertEqual(value.stamp(value.end), end)
            XCTAssertEqual((value.context["days"] as? [String])?.count, 7)
        }
        XCTAssertNil(CalendarRequestWindow(request: "Read the email from October 26", reference: date("2026-10-29T17:00:00Z"), zone: .current))
    }

    func testPastDatesWrongOffsetsAndSingleCalendarReadAreRefusedBeforeExecution() {
        let value = window()
        func refusal(_ args: [String: Any]) -> String? {
            value.toolRefusal(name: CalendarTools.list, arguments: GmailReadTools.json(args), now: value.reference)
        }
        let valid: [String: Any] = ["time_min": value.stamp(value.start), "time_max": value.stamp(value.end), "availability_check": true]
        XCTAssertNil(refusal(valid))
        let utc = window(zone: "UTC")
        XCTAssertNil(utc.toolRefusal(name: CalendarTools.list, arguments: GmailReadTools.json([
            "time_min": utc.stamp(utc.start), "time_max": utc.stamp(utc.end)]), now: utc.reference))
        XCTAssertNotNil(refusal(["time_min": "2026-10-26T09:00:00-07:00", "time_max": "2026-10-27T12:00:00-07:00"]))
        XCTAssertNotNil(refusal(["time_min": "2026-11-02T09:00:00-07:00", "time_max": "2026-11-02T10:00:00-07:00"]))
        var narrowed = valid; narrowed["account"] = "one@example.test"
        XCTAssertNotNil(refusal(narrowed))
        XCTAssertNotNil(value.toolRefusal(name: CalendarTools.list, arguments: GmailReadTools.json(valid), now: value.end))
        XCTAssertNotNil(value.toolRefusal(name: "send_email", arguments: #"{"body":"I am free Monday, October 26, and Tuesday, October 27."}"#, now: value.reference))
        XCTAssertNil(value.toolRefusal(name: "create_draft", arguments: #"{"body":"I can do Monday, November 2, or Tuesday, November 3."}"#, now: value.reference))
        XCTAssertTrue(value.containsOutsideDate("Available on 2026-10-26."))
        XCTAssertFalse(window("2026-12-31T12:00:00-05:00", zone: "America/New_York").containsOutsideDate("January 4"))
    }

    func testPartialFailedAndStaleCalendarReadsCannotEstablishAvailability() {
        let good: [String: Any] = ["availability": ["busy": []], "complete": true, "coverage": "complete", "result_age_seconds": 0]
        XCTAssertTrue(CalendarRequestWindow.completeRead(GmailReadTools.json([good, good, good])))
        XCTAssertFalse(CalendarRequestWindow.completeRead(GmailReadTools.json([good, good, ["error": "Calendar disconnected"]])))
        var stale = good; stale["result_age_seconds"] = CalendarTools.cacheFreshness + 1
        XCTAssertFalse(CalendarRequestWindow.completeRead(GmailReadTools.json([stale])))
        XCTAssertFalse(CalendarRequestWindow.completeRead(GmailReadTools.json([["events": [], "complete": false]])))
        XCTAssertFalse(CalendarRequestWindow.completeRead(GmailReadTools.json([good]), window: window()))
        var covered = good
        covered["availability"] = ["timeMin": window().stamp(window().start), "timeMax": window().stamp(window().end), "busy": []]
        XCTAssertTrue(CalendarRequestWindow.completeRead(GmailReadTools.json([covered]), window: window()))
    }

    func testClockAndResolvedWindowSurviveContextTrimmingAndRejectBadModelDates() async throws {
        var requests: [[String: Any]] = [], speech: [String] = [], failures: [String] = []
        let brain = LiveClientBrain(request: { body in
            requests.append(body)
            return ["output": [["type": "message", "content": [["type": "output_text", "text": "You are free Monday, October 26."]]]]]
        }, deliver: { _ in }, speak: { text, _ in speech.append(text) }, failed: { failures.append($0) })
        defer { brain.close() }
        brain.now = { self.date("2026-10-29T17:00:00Z") }
        brain.timeZone = { TimeZone(identifier: "America/Los_Angeles")! }
        brain.updateState(#"{"item":{"id":"A","account":"fixture@example.test","date":"2026-10-12"}}"#, scope: "fixture")
        brain.user("Check next week across all three calendars", turn: 1)
        for _ in 0..<10 { brain.observe(String(repeating: "Old source data. ", count: 1500) + UUID().uuidString) }
        brain.begin("calendar", live: true, turn: 1); brain.settle(turn: 1)
        for _ in 0..<100 { await Task.yield() }
        let context = try XCTUnwrap(requests.first?["context"] as? String)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: Any])
        XCTAssertTrue((json["clock"] as? String)?.contains("October 29, 2026") == true)
        XCTAssertEqual((json["calendarWindow"] as? [String: Any])?["start_inclusive"] as? String, "2026-11-02T00:00:00-08:00")
        XCTAssertEqual(failures.count, 1)
        XCTAssertFalse(speech.contains { $0.contains("October 26") })
    }

    func testWrongCalendarCallIsAnsweredLocallyAndNeverReachesProvider() async throws {
        var requests = 0, executed: [String] = [], failure: [String] = []
        let brain = LiveClientBrain(request: { _ in
            requests += 1
            if requests == 1 {
                return ["output": [["type": "function_call", "name": CalendarTools.list, "call_id": "wrong-week",
                    "arguments": #"{"time_min":"2026-10-26T00:00:00-07:00","time_max":"2026-11-02T00:00:00-08:00"}"#]]]
            }
            return ["output": [["type": "message", "content": [["type": "output_text", "text": "Next week starts November 2."]]]]]
        }, deliver: { event in
            if let nested = event["event"] as? [String: Any], let item = nested["item"] as? [String: Any], let id = item["call_id"] as? String { executed.append(id) }
        }, speak: { _, _ in }, failed: { failure.append($0) })
        defer { brain.close() }
        brain.now = { self.date("2026-10-29T17:00:00Z") }
        brain.timeZone = { TimeZone(identifier: "America/Los_Angeles")! }
        brain.user("Check next week", turn: 1)
        brain.begin("calendar", live: true, turn: 1); brain.settle(turn: 1)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(executed.isEmpty)
        XCTAssertTrue(failure.isEmpty)
    }

    func testCachedBusyIntervalsUseTheirOwnDSTOffsets() {
        let from = date("2026-11-01T01:30:00-07:00"), to = date("2026-11-01T02:30:00-08:00")
        let start = Int64(from.timeIntervalSince1970 * 1000), end = Int64(to.timeIntervalSince1970 * 1000)
        let event = CalendarStore.Event(id: "fixture", calendarId: "primary", account: "fixture@example.test", summary: nil,
            location: nil, description: nil, startRaw: nil, endRaw: nil, startEpochMs: start, endEpochMs: end,
            isAllDay: false, status: "confirmed", recurringEventId: nil, htmlLink: nil, attendeeCount: nil, cachedAt: Date(), transparency: nil)
        let result = CalendarTools.busy([event], attendees: [], account: "fixture@example.test", window: (start, end),
            offset: "-07:00", zone: TimeZone(identifier: "America/Los_Angeles")!)
        XCTAssertEqual(result.first?["start"], "2026-11-01T01:30:00-07:00")
        XCTAssertEqual(result.first?["end"], "2026-11-01T02:30:00-08:00")
    }
}
