import Foundation
import GRDB

/// Cached calendar events, in `context.sqlite` beside `MailStore`. This store answers only
/// "what's in the rows"; `CalendarSearch` decides whether a window was synced.
struct CalendarStore: Sendable {
    /// One cached event, flattened the way Google's Calendar API returns it.
    struct Event: Codable, FetchableRecord, PersistableRecord, Sendable {
        static let databaseTableName = "calendar_event"

        /// Google's event id. It can repeat across calendars, so the key adds `calendarId`.
        let id: String
        /// Only `"primary"` is populated today.
        let calendarId: String
        let account: String
        let summary: String?
        let location: String?
        /// Truncated to `descriptionCap`: a description can be a pasted agenda.
        let description: String?
        /// Google's string verbatim: RFC3339 for a timed event, bare `yyyy-MM-dd` for all-day.
        let startRaw: String?
        let endRaw: String?
        /// Resolved at ingest so range queries compare integers.
        let startEpochMs: Int64?
        let endEpochMs: Int64?
        let isAllDay: Bool
        let status: String?
        let recurringEventId: String?
        let htmlLink: String?
        /// Google's true attendee count, kept even when the `Attendee` rows are capped.
        let attendeeCount: Int?
        let cachedAt: Date
        /// Google's `transparency`: `"transparent"` for an event that doesn't block time. Nil blocks.
        var transparency: String? = nil
        var hangoutLink: String? = nil
    }

    /// An event's attendees, capped at `attendeeCap` (an all-hands can have hundreds) and
    /// cascade-deleted with the event.
    struct Attendee: Codable, FetchableRecord, PersistableRecord, Sendable {
        static let databaseTableName = "calendar_event_attendee"

        let eventId: String
        let calendarId: String
        let email: String
        let displayName: String?
        let responseStatus: String?
        let organizer: Bool
    }

    /// One calendar search page, with the attendee rows that belong to exactly those
    /// events. Read together so a background refresh cannot replace the event page
    /// between the event query and the roster query.
    struct SearchResult: Sendable {
        let events: [Event]
        let attendees: [Attendee]

        static let empty = SearchResult(events: [], attendees: [])
    }

    /// Where each account's calendar sync has got to — the window the *last successful
    /// pass* actually walked, not merely asked for.
    struct SyncState: Codable, FetchableRecord, PersistableRecord, Sendable {
        static let databaseTableName = "calendar_sync_state"

        let account: String
        var coveredMinMs: Int64?
        var coveredMaxMs: Int64?
        var lastSyncedAt: Date
    }

    private struct EventKey: Hashable {
        let eventId: String
        let calendarId: String
    }

    /// Nil if the database failed to open; every method then degrades to a no-op.
    private let dbPool: DatabasePool?

    init(database: DatabasePool?) {
        dbPool = database
    }

    /// Registered from `LocalContextStore.migrator` as `v10-calendar-cache`; defined here so
    /// the schema sits beside the code that reads it.
    static func createSchema(_ db: Database) throws {
        try db.create(table: Event.databaseTableName) { t in
            t.column("id", .text).notNull()
            t.column("calendarId", .text).notNull()
            t.column("account", .text).notNull()
            t.column("summary", .text)
            t.column("location", .text)
            t.column("description", .text)
            t.column("startRaw", .text)
            t.column("endRaw", .text)
            t.column("startEpochMs", .integer)
            t.column("endEpochMs", .integer)
            t.column("isAllDay", .boolean).notNull().defaults(to: false)
            t.column("status", .text)
            t.column("recurringEventId", .text)
            t.column("htmlLink", .text)
            t.column("attendeeCount", .integer)
            t.column("cachedAt", .datetime).notNull()
            t.primaryKey(["id", "calendarId"])
        }
        // For the range query: one account's events, soonest first.
        try db.create(
            index: "calendar_event_account_start_idx",
            on: Event.databaseTableName,
            columns: ["account", "startEpochMs"]
        )

        try db.create(table: Attendee.databaseTableName) { t in
            t.column("eventId", .text).notNull()
            t.column("calendarId", .text).notNull()
            t.column("email", .text).notNull()
            t.column("displayName", .text)
            t.column("responseStatus", .text)
            t.column("organizer", .boolean).notNull().defaults(to: false)
            t.primaryKey(["eventId", "calendarId", "email"])
            // Cascade in SQLite, so no delete path can leave attendees behind.
            t.foreignKey(
                ["eventId", "calendarId"], references: Event.databaseTableName, onDelete: .cascade)
        }

        try db.create(table: SyncState.databaseTableName) { t in
            t.primaryKey("account", .text)
            t.column("coveredMinMs", .integer)
            t.column("coveredMaxMs", .integer)
            t.column("lastSyncedAt", .datetime).notNull()
        }
    }

    /// `v47-calendar-busy-fields`: what `list_calendar_events` needs to answer from here instead of Google.
    static func addBusyFields(_ db: Database) throws {
        try db.alter(table: Event.databaseTableName) { t in
            t.add(column: "transparency", .text)
            t.add(column: "hangoutLink", .text)
        }
    }

    // MARK: - Writing

    /// A full background pass: replace one account's window and move the coverage watermark
    /// in one transaction, so a kill mid-write never claims a window it has not filled.
    func apply(
        events: [Event], attendees: [Attendee], account: String,
        windowMinMs: Int64, windowMaxMs: Int64
    ) async {
        guard let dbPool else { return }
        do {
            try await dbPool.write { db in
                // Only `"primary"`: this pass never fetches any other calendar.
                try Event
                    .filter(Column("account") == account)
                    .filter(Column("calendarId") == "primary")
                    .deleteAll(db)
                try Self.write(events: events, attendees: attendees, db)
                try SyncState(
                    account: account,
                    coveredMinMs: windowMinMs,
                    coveredMaxMs: windowMaxMs,
                    lastSyncedAt: Date()
                ).save(db)
            }
        } catch {
            print("[calendar] write failed: \(error)")
        }
    }

    /// Upsert by id, never touching the coverage watermark: a search miss only saw the page
    /// it asked for, not the whole window.
    func cache(events: [Event], attendees: [Attendee]) async {
        guard let dbPool, !events.isEmpty else { return }
        do {
            try await dbPool.write { db in
                try Self.write(events: events, attendees: attendees, db)
            }
        } catch {
            print("[calendar] cache write failed: \(error)")
        }
    }

    /// One batch of events and their attendees, inside a caller's transaction. Attendees are
    /// replaced per event, not merged: Google returns the complete list.
    private static func write(events: [Event], attendees: [Attendee], _ db: Database) throws {
        let grouped = Dictionary(grouping: attendees) {
            EventKey(eventId: $0.eventId, calendarId: $0.calendarId)
        }
        for event in events {
            try event.save(db)
            try Attendee
                .filter(Column("eventId") == event.id)
                .filter(Column("calendarId") == event.calendarId)
                .deleteAll(db)
            let key = EventKey(eventId: event.id, calendarId: event.calendarId)
            for attendee in grouped[key] ?? [] {
                try attendee.insert(db)
            }
        }
    }

    // MARK: - Reading

    /// The watermark for an account, or nil if it has never synced.
    func syncState(account: String) async -> SyncState? {
        guard let dbPool else { return nil }
        return try? await dbPool.read { db in
            try SyncState.fetchOne(db, key: account)
        }
    }

    /// Every account a full pass has completed a window for. `apply` sets both coverage
    /// bounds together, so filtering on one is enough.
    func syncedAccounts() async -> [String] {
        guard let dbPool else { return [] }
        return (try? await dbPool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT account FROM \(SyncState.databaseTableName)
                     WHERE coveredMinMs IS NOT NULL
                     ORDER BY account
                    """
            )
        }) ?? []
    }

    /// Events overlapping `[timeMinMs, timeMaxMs]`, soonest first. `query` is one substring
    /// matched with `LIKE` against summary, location and description; empty matches all.
    func search(
        account: String, timeMinMs: Int64, timeMaxMs: Int64, query: String = "", limit: Int = 20
    ) async -> SearchResult {
        guard let dbPool else { return .empty }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (try? await dbPool.read { db in
            let events = try Event.fetchAll(
                db,
                sql: """
                    SELECT * FROM \(Event.databaseTableName)
                     WHERE account = ? AND calendarId = 'primary'
                       AND startEpochMs < ? AND (endEpochMs IS NULL OR endEpochMs > ?)
                       AND (? = '' OR lower(summary) LIKE '%' || ? || '%'
                                  OR lower(location) LIKE '%' || ? || '%'
                                  OR lower(description) LIKE '%' || ? || '%')
                     ORDER BY startEpochMs ASC
                     LIMIT ?
                    """,
                arguments: [account, timeMaxMs, timeMinMs, term, term, term, term, limit]
            )
            guard !events.isEmpty else { return SearchResult.empty }

            // One query for the page; `eventId` alone is not unique, so filter on the full key.
            let eventIds = events.map(\.id)
            let keys = Set(events.map {
                EventKey(eventId: $0.id, calendarId: $0.calendarId)
            })
            let attendees = try Attendee
                .filter(eventIds.contains(Column("eventId")))
                .fetchAll(db)
                .filter {
                    keys.contains(EventKey(eventId: $0.eventId, calendarId: $0.calendarId))
                }
            return SearchResult(events: events, attendees: attendees)
        }) ?? .empty
    }

    /// Whether the cache contains a timed, non-cancelled event that has not started. An
    /// existence query, so all-day rows cannot crowd a bounded page.
    func hasReviewableFeedEvent(
        account: String, timeMinMs: Int64, timeMaxMs: Int64
    ) async -> Bool {
        guard let dbPool else { return false }
        return (try? await dbPool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM \(Event.databaseTableName)
                         WHERE account = ? AND calendarId = 'primary'
                           AND isAllDay = 0
                           AND (status IS NULL OR status != 'cancelled')
                           AND startEpochMs >= ? AND startEpochMs < ?
                    )
                    """,
                arguments: [account, timeMinMs, timeMaxMs]
            ) ?? false
        }) ?? false
    }

    /// Remove a broker-confirmed cancellation without weakening the synced-window watermark.
    @discardableResult
    func removeEvent(id: String, account: String?) async -> Int {
        guard let dbPool, !id.isEmpty else { return 0 }
        return (try? await dbPool.write { db in
            if let account, !account.isEmpty {
                try db.execute(
                    sql: "DELETE FROM \(Event.databaseTableName) WHERE id = ? AND lower(account) = lower(?)",
                    arguments: [id, account]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM \(Event.databaseTableName) WHERE id = ?",
                    arguments: [id]
                )
            }
            return db.changesCount
        }) ?? 0
    }

    /// Apply a broker-confirmed RSVP to the cached attendee row used by local search.
    @discardableResult
    func setOwnResponse(_ response: String, eventId: String, account: String?) async -> Int {
        guard let dbPool, !eventId.isEmpty, !response.isEmpty else { return 0 }
        return (try? await dbPool.write { db in
            let events: [Event]
            if let account, !account.isEmpty {
                events = try Event.fetchAll(
                    db,
                    sql: "SELECT * FROM \(Event.databaseTableName) WHERE id = ? AND lower(account) = lower(?)",
                    arguments: [eventId, account]
                )
            } else {
                events = try Event.filter(Column("id") == eventId).fetchAll(db)
            }

            for event in events {
                let existing = try Attendee
                    .filter(Column("eventId") == event.id)
                    .filter(Column("calendarId") == event.calendarId)
                    .fetchAll(db)
                    .first { $0.email.caseInsensitiveCompare(event.account) == .orderedSame }
                try Attendee(
                    eventId: event.id,
                    calendarId: event.calendarId,
                    email: existing?.email ?? event.account,
                    displayName: existing?.displayName,
                    responseStatus: response,
                    organizer: existing?.organizer ?? false
                ).save(db)
            }
            return events.count
        }) ?? 0
    }

    // MARK: - Deleting

    /// Drop everything, every account — the sign-out path. Attendees go with their
    /// events by the schema's cascade.
    func purgeAll() async {
        guard let dbPool else { return }
        try? await dbPool.write { db in
            try Event.deleteAll(db)
            try SyncState.deleteAll(db)
        }
    }

    /// Drop one account's events and sync state, the disconnect path.
    /// - Returns: how many events went, so a disconnect can say what it deleted.
    @discardableResult
    func purge(account: String) async -> Int {
        guard let dbPool else { return 0 }
        return (try? await dbPool.write { db in
            let gone = try Event.filter(Column("account") == account).deleteAll(db)
            try SyncState.filter(Column("account") == account).deleteAll(db)
            return gone
        }) ?? 0
    }
}
