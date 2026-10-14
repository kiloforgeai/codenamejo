import GRDB
import XCTest
@testable import CodenameJo

final class CalendarStoreWriteThroughTests: XCTestCase {
    func testFeedEligibilityRequiresAFutureTimedNonCancelledEvent() async throws {
        let (store, database, directory) = try makeStore()
        defer {
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let account = "one@example.com"
        await store.apply(
            events: [
                event(id: "ongoing", startMs: 1_000, endMs: 3_000),
                event(id: "all-day", startMs: 4_000, allDay: true),
                event(id: "cancelled", startMs: 5_000, status: "cancelled"),
            ],
            attendees: [], account: account, windowMinMs: 0, windowMaxMs: 10_000)

        let withoutReviewableEvent = await CalendarSearch.hasReviewableFeedEvents(
            timeMinMs: 2_000, timeMaxMs: 9_000, accounts: [account], store: store)
        XCTAssertFalse(withoutReviewableEvent)

        await store.apply(
            events: [event(id: "later", startMs: 6_000)],
            attendees: [], account: account, windowMinMs: 0, windowMaxMs: 10_000)

        let withReviewableEvent = await CalendarSearch.hasReviewableFeedEvents(
            timeMinMs: 2_000, timeMaxMs: 9_000, accounts: [account], store: store)
        XCTAssertTrue(withReviewableEvent)
    }

    func testFeedEligibilityFailsClosedWhenAnyCalendarCoverageIsIncomplete() async throws {
        let (store, database, directory) = try makeStore()
        defer {
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let account = "one@example.com"
        await store.apply(
            events: [event(id: "later", startMs: 6_000)],
            attendees: [], account: account, windowMinMs: 0, windowMaxMs: 7_000)

        let incomplete = await CalendarSearch.hasReviewableFeedEvents(
            timeMinMs: 2_000, timeMaxMs: 9_000, accounts: [account], store: store)
        let noAccounts = await CalendarSearch.hasReviewableFeedEvents(
            timeMinMs: 2_000, timeMaxMs: 9_000, accounts: [], store: store)
        XCTAssertFalse(incomplete)
        XCTAssertFalse(noAccounts)
    }

    func testCancellationEvictsOnlyTheConfirmedEvent() async throws {
        let (store, database, directory) = try makeStore()
        defer {
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
        }
        await store.cache(
            events: [event(id: "event-1"), event(id: "event-2")],
            attendees: [])

        let removed = await store.removeEvent(id: "event-1", account: "ONE@example.com")
        let result = await store.search(
            account: "one@example.com", timeMinMs: 0, timeMaxMs: 3_000)

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(result.events.map(\.id), ["event-2"])
    }

    func testRSVPUpdatesOnlyTheSelfAttendee() async throws {
        let (store, database, directory) = try makeStore()
        defer {
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let account = "me@example.com"
        await store.cache(
            events: [event(id: "event-1", account: account)],
            attendees: [
                attendee(email: account, response: "needsAction"),
                attendee(email: "guest@example.com", response: "accepted"),
            ])

        let changed = await store.setOwnResponse(
            "declined", eventId: "event-1", account: "ME@example.com")
        let result = await store.search(
            account: account, timeMinMs: 0, timeMaxMs: 3_000)

        XCTAssertEqual(changed, 1)
        XCTAssertEqual(
            result.attendees.first { $0.email == account }?.responseStatus,
            "declined")
        XCTAssertEqual(
            result.attendees.first { $0.email == "guest@example.com" }?.responseStatus,
            "accepted")
    }

    private func makeStore() throws -> (CalendarStore, DatabasePool, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try DatabasePool(path: directory.appendingPathComponent("test.sqlite").path)
        try database.write { db in
            try CalendarStore.createSchema(db)
            try CalendarStore.addBusyFields(db)
        }
        return (CalendarStore(database: database), database, directory)
    }

    private func event(
        id: String,
        account: String = "one@example.com",
        startMs: Int64 = 1_000,
        endMs: Int64 = 2_000,
        allDay: Bool = false,
        status: String? = "confirmed"
    ) -> CalendarStore.Event {
        CalendarStore.Event(
            id: id, calendarId: "primary", account: account,
            summary: "Test", location: nil, description: nil,
            startRaw: nil, endRaw: nil, startEpochMs: startMs, endEpochMs: endMs,
            isAllDay: allDay, status: status, recurringEventId: nil,
            htmlLink: nil, attendeeCount: 2, cachedAt: Date())
    }

    private func attendee(email: String, response: String) -> CalendarStore.Attendee {
        CalendarStore.Attendee(
            eventId: "event-1", calendarId: "primary", email: email,
            displayName: nil, responseStatus: response, organizer: false)
    }
}
