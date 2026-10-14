import Foundation
import FactoryKit

/// The calendar sibling of `BackgroundMailRefresh`: every account with calendar scope, a rolling window
/// fetched wholesale with `singleEvents=true` (Calendar has no `history.list`; cancelled events just drop out).
enum BackgroundCalendarRefresh {
    enum Result {
        case newData
        case noData
        case failed
    }

    /// How far back the rolling window reaches.
    static let pastWindow: TimeInterval = 24 * 60 * 60
    /// How far forward it reaches. A judgement call, not measured.
    static let futureWindow: TimeInterval = 14 * 24 * 60 * 60

    /// Same floors as `BackgroundMailRefresh`: two minutes so app-switching is free, ten so a push burst costs one pass.
    static let launchThrottle: TimeInterval = 2 * 60
    static let pushThrottle: TimeInterval = 10 * 60

    /// How long a `.toolWrite` pass waits before pulling: the broker speaks a write's receipt before its deferred Google POST runs.
    static let toolWriteDelay: TimeInterval = 2

    /// Whether a completed tool mutated the calendar — the writes whose receipt makes the
    /// cache stale mid-call. Suffix-matched because an MCP name can carry a server prefix.
    static func isCalendarWrite(_ toolName: String) -> Bool {
        [
            "create_calendar_event", "update_calendar_event",
            "cancel_calendar_event", "respond_to_calendar_event",
        ].contains(where: toolName.hasSuffix)
    }

    /// Attendees kept per event; `Event.attendeeCount` carries the true total.
    static let attendeeCap = 50
    /// `CalendarStore.Event.description`'s cap, applied at ingest.
    static let descriptionCap = 500

    private static let lastPassKey = "calendarRefresh.lastPassAt"

    /// The last time a pass ran to completion, for the throttle to compare against.
    private static var lastPassAt: Date? {
        get { UserDefaults.standard.object(forKey: lastPassKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastPassKey) }
    }

    private static let staleKey = "calendarMayBeStale"

    /// Whether something has changed the calendar since the last completed pass. Separate from
    /// `mailboxMayBeStale` so one pass can't clear the other's override.
    static var calendarMayBeStale: Bool {
        UserDefaults.standard.bool(forKey: staleKey)
    }

    /// Called for every completed tool call, same as `noteMailboxMayBeStale`.
    static func noteCalendarMayBeStale() {
        UserDefaults.standard.set(true, forKey: staleKey)
    }

    /// Cleared only by a pass that actually reconciled, never at the start of one.
    private static func clearCalendarStale() {
        UserDefaults.standard.set(false, forKey: staleKey)
    }

    /// One pass at a time, on a separate `Gate` from mail's.
    private actor Gate {
        static let shared = Gate()
        private var running = false
        func enter() -> Bool {
            if running { return false }
            running = true
            return true
        }
        func leave() { running = false }
    }

    @discardableResult
    static func run(trigger: BackgroundRefreshLog.Trigger) async -> Result {
        let started = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

        if trigger == .launch || trigger == .silentPush {
            let signedIn = await MainActor.run { Container.shared.backend().isSignedIn }
            guard signedIn else {
                RealtimeLog.log("calendar: \(trigger.rawValue) skipped — signed out")
                return .noData
            }
        }

        let floor: TimeInterval? = switch trigger {
        case .silentPush: pushThrottle
        case .launch: calendarMayBeStale ? nil : launchThrottle
        case .manual, .signIn, .toolWrite, .staleRead: nil
        }
        if let floor, let last = lastPassAt, Date().timeIntervalSince(last) < floor {
            let ago = Int(Date().timeIntervalSince(last))
            RealtimeLog.log("calendar: \(trigger.rawValue) skipped — last pass \(ago)s ago")
            return .noData
        }

        guard await Gate.shared.enter() else {
            RealtimeLog.log("calendar: \(trigger.rawValue) skipped — a pass is already running")
            return .noData
        }
        defer { Task { await Gate.shared.leave() } }

        RealtimeLog.log("calendar: \(trigger.rawValue) pass starting")

        let accounts = GoogleAccountStore.emails()
        guard !accounts.isEmpty else {
            lastPassAt = Date()
            return .noData
        }

        let store = CalendarStore(database: Container.shared.localContext().dbPool)
        // Every pass hands its attendees to the correspondent directory. See `ContactStore.absorbCalendar`.
        let contacts = ContactStore(database: Container.shared.localContext().dbPool)

        let now = Date()
        let timeMin = now.addingTimeInterval(-pastWindow)
        let timeMax = now.addingTimeInterval(futureWindow)
        let windowMinMs = Int64(timeMin.timeIntervalSince1970 * 1000)
        let windowMaxMs = Int64(timeMax.timeIntervalSince1970 * 1000)

        var cachedTotal = 0
        var anySynced = false
        var lastFailure: GoogleCredential.Failure?
        var fetchError: Error?
        var withoutScope = 0

        // Sequential: one account's failure must not cancel another's in-flight write.
        for account in accounts {
            let token: GoogleCredential.Token
            switch await GoogleCredential.token(
                for: account, requiredScopes: GoogleCredential.calendarScopes
            ) {
            case .success(let value):
                token = value
            case .failure(.scopesMissing):
                // Granted mail but not calendar; the consent screen lets Calendar be unticked on its own.
                withoutScope += 1
                continue
            case .failure(let failure):
                RealtimeLog.log("calendar: \(account) skipped — \(failure.logLabel)")
                lastFailure = failure
                continue
            }
            do {
                let cached = try await sync(
                    token: token.accessToken, account: token.email ?? account,
                    timeMin: timeMin, timeMax: timeMax,
                    windowMinMs: windowMinMs, windowMaxMs: windowMaxMs, store: store,
                    contacts: contacts
                )
                cachedTotal += cached
                anySynced = true
            } catch is CancellationError {
                // The expired budget belongs to every account in the loop, so stop the whole pass.
                RealtimeLog.log("calendar: \(trigger.rawValue) pass expired after \(elapsed())ms")
                return .noData
            } catch {
                RealtimeLog.log("calendar: \(account) failed — \(error)")
                fetchError = error
            }
        }

        lastPassAt = Date()
        // Never cleared by a `.toolWrite` pass: it can race the deferred POST it was spawned for.
        if anySynced, fetchError == nil, lastFailure == nil, trigger != .toolWrite {
            clearCalendarStale()
        }

        guard anySynced else {
            if let fetchError {
                RealtimeLog.log(
                    "calendar: \(trigger.rawValue) → fetch failed — \(fetchError) in \(elapsed())ms")
                return .failed
            }
            RealtimeLog.log(
                "calendar: \(trigger.rawValue) → nothing to sync "
                + "(\(withoutScope) without calendar scope) in \(elapsed())ms")
            return .noData
        }

        RealtimeLog.log(
            "calendar: \(trigger.rawValue) → \(cachedTotal) event(s) cached in \(elapsed())ms")
        return cachedTotal == 0 ? .noData : .newData
    }

    // MARK: - The pass

    /// Fetch the whole rolling window for one account and replace it wholesale.
    /// - Returns: how many events it cached.
    private static func sync(
        token: String, account: String, timeMin: Date, timeMax: Date,
        windowMinMs: Int64, windowMaxMs: Int64, store: CalendarStore, contacts: ContactStore
    ) async throws -> Int {
        let iso = ISO8601DateFormatter()
        var events: [CalendarStore.Event] = []
        var attendees: [CalendarStore.Attendee] = []
        var pageToken: String?
        repeat {
            await CalendarQuota.shared.spend()
            let page = try await CalendarAPI.events(
                token: token,
                timeMinISO: iso.string(from: timeMin),
                timeMaxISO: iso.string(from: timeMax),
                pageToken: pageToken
            )
            try Task.checkCancellation()
            for item in page.items ?? [] {
                let (event, eventAttendees) = ingest(item, account: account)
                events.append(event)
                attendees.append(contentsOf: eventAttendees)
            }
            pageToken = page.nextPageToken
        } while pageToken != nil

        await store.apply(
            events: events, attendees: attendees, account: account,
            windowMinMs: windowMinMs, windowMaxMs: windowMaxMs
        )

        // Feeds `find_person` attendees the mailbox may never have seen, with no extra request.
        let startByEvent = Dictionary(
            events.map { ($0.id, $0.startEpochMs ?? 0) }, uniquingKeysWith: max)
        let added = await contacts.absorbCalendar(
            account: account,
            people: attendees.map {
                (email: $0.email, name: $0.displayName ?? "", when: startByEvent[$0.eventId] ?? 0)
            }
        )
        if added > 0 {
            RealtimeLog.log("calendar: \(account) — \(added) attendee(s) new to the directory")
        }
        return events.count
    }

    // MARK: - Ingest

    /// Not `private`: `CalendarSearch`'s live fallback builds rows the same way.
    static func ingest(
        _ item: CalendarAPI.Event, account: String
    ) -> (CalendarStore.Event, [CalendarStore.Attendee]) {
        let allAttendees = item.attendees ?? []
        let event = CalendarStore.Event(
            id: item.id,
            calendarId: "primary",
            account: account,
            summary: item.summary,
            location: item.location,
            description: item.description.map { String($0.prefix(descriptionCap)) },
            startRaw: item.start?.dateTime ?? item.start?.date,
            endRaw: item.end?.dateTime ?? item.end?.date,
            startEpochMs: epochMs(from: item.start),
            endEpochMs: epochMs(from: item.end),
            isAllDay: item.start?.dateTime == nil,
            status: item.status,
            recurringEventId: item.recurringEventId,
            htmlLink: item.htmlLink,
            attendeeCount: allAttendees.isEmpty ? nil : allAttendees.count,
            cachedAt: Date(),
            transparency: item.transparency,
            hangoutLink: item.hangoutLink
        )
        let attendees = allAttendees.prefix(attendeeCap).compactMap { attendee -> CalendarStore.Attendee? in
            guard let email = attendee.email, !email.isEmpty else { return nil }
            return CalendarStore.Attendee(
                eventId: item.id,
                calendarId: "primary",
                email: email,
                displayName: attendee.displayName,
                responseStatus: attendee.responseStatus,
                organizer: attendee.organizer ?? false
            )
        }
        return (event, Array(attendees))
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain = ISO8601DateFormatter()
    /// Google's all-day date, `yyyy-MM-dd` with no zone, parsed at UTC midnight so it sorts against timed events.
    private static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func epochMs(from time: CalendarAPI.Event.EventTime?) -> Int64? {
        guard let time else { return nil }
        if let dateTime = time.dateTime {
            let date = isoFractional.date(from: dateTime) ?? isoPlain.date(from: dateTime)
            return date.map { Int64($0.timeIntervalSince1970 * 1000) }
        }
        if let date = time.date {
            return dateOnly.date(from: date).map { Int64($0.timeIntervalSince1970 * 1000) }
        }
        return nil
    }
}
