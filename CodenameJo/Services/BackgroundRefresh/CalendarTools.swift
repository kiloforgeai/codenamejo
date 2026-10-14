import Foundation
import FactoryKit

/// Calendar list, create and update, declared by the phone and run on its own Google grant.
/// Results and refusals keep their wording: the queue and Feed parse them.
enum CalendarTools {
    static let list = "list_calendar_events"
    static let create = "create_calendar_event"
    static let update = "update_calendar_event"
    static let names: Set<String> = [list, create, update]

    static let writeScopes = ["https://www.googleapis.com/auth/calendar.events"]

    // MARK: - Declarations

    static func definitions(accounts: [String]) -> [[String: Any]] {
        guard !accounts.isEmpty else { return [] }
        let connected = accounts.joined(separator: ", ")
        let writeAccount: [String: Any] = ["type": "string", "description":
            "Omit unless the user named an account: the tool selects the active inbox calendar. Never ask which calendar. Connected: \(connected)."]
        let readAccount: [String: Any] = ["type": "string", "description":
            "Omit unless the user named an account: the tool reads every connected calendar, in the inbox feed too. Connected: \(connected)."]
        let eventId: [String: Any] = ["type": "string", "description": "From a search_calendar or list_calendar_events result."]
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "function", "name": name, "description": description, "strict": false,
             "parameters": ["type": "object", "properties": properties, "required": required]]
        }
        return [
            tool(list,
                "Read calendar events in a time window, soonest first. Use this for "
                + "'what's on my calendar', 'am I free Thursday', 'what's my next meeting'. "
                + "Recurring events are expanded into individual instances. Every connected "
                + "calendar is read unless `account` names one, and busy on any of them is a "
                + "conflict. Pass explicit times — resolve 'today' or 'tomorrow' yourself from "
                + "the current date given in your instructions.",
                ["time_min": ["type": "string", "description":
                    "Start of the window, RFC3339 (e.g. 2026-07-28T00:00:00-04:00). "
                    + "Include the offset for the user's timezone, also in your instructions."],
                 "time_max": ["type": "string", "description":
                    "End of the window, RFC3339. Keep windows tight — a week at most for a summary."],
                 "query": ["type": "string", "description": "Optional free-text filter on title, description, attendees."],
                 "max_results": ["type": "number", "description": "Default 25, max 50."],
                 "availability_check": ["type": "boolean", "description":
                    "Read complete free/busy intervals instead of a limited event list. Required before booking a suggested slot; use the exact proposed start/end."],
                 "account": readAccount],
                ["time_min", "time_max"]),
            tool(create,
                "Create or block calendar time. THIS IS WHAT \"block time\", \"hold time\", \"put it "
                + "on my calendar\", \"schedule time\" and \"create an event\" MEAN, even with an email "
                + "current. Use that email only as event context; never draft to its sender. Google "
                + "Calendar sends invitations, so Gmail draft-only mode does not apply. No attendees: "
                + "call now. Attendees: say each address, wait for a yes, then call."
                + " It cannot read, list, search or check anything already scheduled — use "
                + "list_calendar_events for that — and never call it with placeholder titles or times.",
                ["summary": ["type": "string", "description": "The event title."],
                 "start": ["type": "string", "description": "RFC3339 start, e.g. 2026-07-31T14:00:00-04:00."],
                 "end": ["type": "string", "description": "RFC3339 end. If the user gave no duration, use one hour."],
                 "description": ["type": "string", "description": "Optional notes on the event."],
                 "location": ["type": "string", "description": "Optional location."],
                 "attendees": ["type": "array", "items": ["type": "string"], "description":
                    "Email addresses to invite — an address, never a person's name: call "
                    + "find_person for one. They are notified immediately and it can't be undone."],
                 "private": ["type": "boolean", "description": "True if they asked for a private event."],
                 "online": ["type": "boolean", "description":
                    "Off for a video call — the default, and it adds a Google Meet link. False, "
                    + "or a location, for in person; true puts a Meet link on one with a location."],
                 "account": writeAccount],
                ["summary", "start", "end"]),
            tool(update,
                "Change an event that already exists: its time, its title, where it is, "
                + "its notes, or who is on it. Use this for 'push my 3pm to 4', 'rename "
                + "that to X', 'add Sarah to the standup', 'move it to Zoom'. Pass the id "
                + "of an event from search_calendar or list_calendar_events and only the fields "
                + "that change — anything you leave out is left alone. Guests are emailed about "
                + "the change."
                + " It cannot read, list, search or check the calendar, and cannot create or cancel; "
                + "never guess an id. \"\" clears a field rather than leaving it alone. No confirmation "
                + "is needed — say what moved afterwards.",
                ["event_id": eventId,
                 "start": ["type": "string", "description":
                    "New RFC3339 start, e.g. 2026-07-31T16:00:00-04:00. Give this alone "
                    + "to move the event and keep its current length. Never end a time with \"Z\"."],
                 "end": ["type": "string", "description": "New RFC3339 end. Only needed when the event's length changes too."],
                 "summary": ["type": "string", "description": "New title."],
                 "location": ["type": "string", "description": "New location. Pass \"\" to clear it."],
                 "description": ["type": "string", "description": "New notes. Pass \"\" to clear them."],
                 "add_attendees": ["type": "array", "items": ["type": "string"], "description":
                    "Email addresses to invite to the existing event — an address, never a "
                    + "person's name: call find_person for one. They are notified immediately. "
                    + "Everyone already on it stays on it."],
                 "remove_attendees": ["type": "array", "items": ["type": "string"], "description":
                    "Email addresses to take off the event. They are told it was "
                    + "cancelled for them. To take the user themselves off, decline it "
                    + "with respond_to_calendar_event instead."],
                 "account": writeAccount],
                ["event_id"]),
        ]
    }

    /// The active profile's Google accounts that granted calendar, primary first.
    @MainActor static func accounts() -> [String] {
        let granted = GoogleAccountStore.all()
            .filter { GoogleCredential.calendarScopes.allSatisfy($0.scopes.contains) }
            .sorted { $0.isPrimary && !$1.isPrimary }
            .map(\.email)
        return ProfileRuntime.allowedMailAccounts(granted)
    }

    // MARK: - Running

    struct Refusal: Error { let text: String }

    static func run(name: String, argumentsJSON: String) async -> (output: String, failed: Bool, effects: [GmailWriteEffect]?) {
        var args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        var connected = await accounts()
        guard !connected.isEmpty else {
            return ("No Google Calendar is connected. The user may need to reconnect their "
                + "Google account to grant calendar access.", true, nil)
        }
        if let bad = attendeeRefusal(name, args, canResolve: !GoogleAccountStore.mailAccounts().isEmpty) {
            return (bad, true, nil)
        }
        // The feed's current mailbox owns calendar writes; reads span every connected calendar.
        switch bind(name, args, mailbox: await Container.shared.localTriage().currentMailbox, accounts: connected) {
        case .failure(let refusal): return (refusal.text, false, nil)
        case .success(let bound):
            args = bound
            if let named = args["account"] as? String {
                connected = connected.filter { $0.caseInsensitiveCompare(named) == .orderedSame }
            }
        }
        let started = Date()
        do {
            let output: String
            switch name {
            case list: output = try await runList(args, accounts: connected)
            case create: output = try await runCreate(args, accounts: connected)
            default: output = try await runUpdate(args, accounts: connected)
            }
            RealtimeLog.log("calendarTool: \(name) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
            return (output, false, nil)
        } catch let refusal as Refusal {
            return (refusal.text, false, nil)
        } catch {
            RealtimeLog.log("calendarTool: \(name) failed — \(error)")
            return ("Google Calendar couldn't be reached (\(String(describing: error).prefix(120))). "
                + "Nothing was changed. Do not guess; say so plainly.", true, nil)
        }
    }

    /// A running feed binds a write to its mailbox. A read goes where it was pointed, else to every
    /// connected calendar: one person's clash on any of them is a clash, whichever inbox the feed is in.
    static func bind(_ name: String, _ args: [String: Any], mailbox: String?, accounts: [String]) -> Result<[String: Any], Refusal> {
        let requested = (args["account"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selected = (name == list ? nil : mailbox) ?? requested
        var out = args
        guard !selected.isEmpty else {
            out.removeValue(forKey: "account")
            return .success(out)
        }
        guard let match = accounts.first(where: { $0.caseInsensitiveCompare(selected) == .orderedSame }) else {
            return .failure(Refusal(text: name == list
                ? "No calendar was read: \(selected) has no connected calendar. Ask which connected calendar "
                    + "the user meant, or omit `account` to read every one; do not substitute another account."
                : "No calendar action was performed: \(selected) has no connected calendar. "
                    + "Ask the user to leave the inbox feed and choose a connected calendar; do not substitute another account."))
        }
        out["account"] = match
        return .success(out)
    }

    static func accessToken(_ account: String, write: Bool, capability: String) async throws -> String {
        let scopes = write ? writeScopes : await GoogleCredential.calendarScopes
        switch await GoogleCredential.token(for: account, requiredScopes: scopes) {
        case .success(let token): return token.accessToken
        case .failure(.noStoredGrant), .failure(.grantRevoked), .failure(.scopesMissing):
            throw Refusal(text: reconnect(account, capability))
        case .failure:
            throw Refusal(text: "Couldn't reach Google for \(account) just now. Say so and offer to try again.")
        }
    }

    private static func reconnect(_ account: String, _ capability: String) -> String {
        "\(account) needs reconnecting before it can \(capability) — its access predates that permission. "
            + "Remove and re-add the account in Settings, then try again."
    }

    private static func string(_ value: Any?) -> String? { value as? String }

    private static func strings(_ value: Any?) -> [String]? {
        let out = (value as? [Any] ?? []).compactMap { $0 as? String }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return out.isEmpty ? nil : out
    }

    static func singleTarget(_ args: [String: Any], _ accounts: [String], creating: Bool = false) throws -> String {
        if let named = args["account"] as? String {
            guard let match = accounts.first(where: { $0.caseInsensitiveCompare(named) == .orderedSame }) else {
                throw Refusal(text: "No connected calendar matches \"\(named)\".")
            }
            return match
        }
        if accounts.count == 1 || (creating && !accounts.isEmpty) { return accounts[0] }
        throw Refusal(text: "Several calendars are connected (\(accounts.joined(separator: ", "))). "
            + "Ask the user which one, then pass `account`.")
    }

    // MARK: - list_calendar_events

    private static let listFields = "items(id,summary,start,end,location,transparency,"
        + "attendees(email,displayName,self,responseStatus),organizer(email,displayName,self),hangoutLink)"
    static let attendeeCap = 12

    /// A cached answer older than this still answers; it also starts the pass that freshens the next one.
    static let cacheFreshness = BackgroundCalendarRefresh.pushThrottle

    private static func runList(_ args: [String: Any], accounts: [String]) async throws -> String {
        let timeMin = string(args["time_min"]) ?? "", timeMax = string(args["time_max"]) ?? ""
        guard !timeMin.isEmpty, !timeMax.isEmpty else {
            throw Refusal(text: "Need both time_min and time_max as RFC3339 timestamps.")
        }
        let asked = (args["max_results"] as? NSNumber)?.intValue ?? 25
        let max = Swift.min(Swift.max(1, asked), 50)
        let availability = args["availability_check"] as? Bool == true
        let query = string(args["query"]) ?? ""
        // The phone's own copy answers first: `BackgroundCalendarRefresh` keeps every account's
        // rolling window, so a covered lookup costs no Google round trip. The rest go live.
        let store = CalendarStore(database: Container.shared.localContext().dbPool)
        let window: (Int64, Int64)? = instant(timeMin).flatMap { from in instant(timeMax).map { (Int64(from), Int64($0)) } }
        let zone = offset(of: timeMin).isEmpty ? offsetString() : offset(of: timeMin)
        let rows = await withTaskGroup(of: (Int, [String: Any], Date?).self) { group in
            for (index, account) in accounts.enumerated() {
                group.addTask {
                    if let window, let state = await store.syncState(account: account), covers(state, window) {
                        let cached = await store.search(account: account, timeMinMs: window.0, timeMaxMs: window.1, limit: 500)
                        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        let events = cached.events.filter {
                            $0.status != "cancelled" && (availability || mentions($0, cached.attendees, term))
                        }
                        if availability {
                            let intervals = busy(events, attendees: cached.attendees, account: account, window: window, offset: zone)
                            return (index, ["account": account, "availability":
                                ["timeMin": timeMin, "timeMax": timeMax, "busy": intervals]], state.lastSyncedAt)
                        }
                        let listed = events.prefix(max).map { row(account: account, $0, cached.attendees) }
                        return (index, ["account": account, "events": listed, "count": listed.count], state.lastSyncedAt)
                    }
                    do {
                        let token = try await accessToken(account, write: false, capability: "read the calendar")
                        if availability {
                            let busy = try await freeBusy(token: token, timeMin: timeMin, timeMax: timeMax)
                            return (index, ["account": account, "availability":
                                ["timeMin": timeMin, "timeMax": timeMax, "busy": busy]], nil)
                        }
                        var params = ["timeMin": timeMin, "timeMax": timeMax, "singleEvents": "true",
                                      "orderBy": "startTime", "maxResults": String(max), "fields": listFields]
                        if !query.isEmpty { params["q"] = query }
                        let data = try await CalendarAPI.json("GET", path: "calendars/primary/events", query: params, token: token)
                        let events = (data["items"] as? [[String: Any]] ?? []).map { summary(account: account, $0) }
                        return (index, ["account": account, "events": events, "count": events.count], nil)
                    } catch let refusal as Refusal {
                        return (index, ["account": account, "error": refusal.text], nil)
                    } catch {
                        return (index, ["account": account, "error": String(describing: error)], nil)
                    }
                }
            }
            var out: [(Int, [String: Any], Date?)] = []
            for await entry in group { out.append(entry) }
            return out.sorted { $0.0 < $1.0 }
        }
        let synced = rows.compactMap { $0.2 }
        RealtimeLog.log("calendarTool: \(availability ? "availability" : "list") answered \(synced.count) of \(rows.count) "
            + "account(s) from the cache")
        if let oldest = synced.min(), Date().timeIntervalSince(oldest) > cacheFreshness {
            Task { await BackgroundCalendarRefresh.run(trigger: .staleRead) }
        }
        return GmailReadTools.json(rows.map { $0.1 })
    }

    /// Whether the last full pass walked the whole window.
    static func covers(_ state: CalendarStore.SyncState, _ window: (Int64, Int64)) -> Bool {
        guard let min = state.coveredMinMs, let max = state.coveredMaxMs else { return false }
        return window.0 >= min && window.1 <= max
    }

    /// Google's `q` over cached rows: title, notes, place, and who is on it.
    static func mentions(_ event: CalendarStore.Event, _ attendees: [CalendarStore.Attendee], _ term: String) -> Bool {
        guard !term.isEmpty else { return true }
        let roster = attendees.filter { $0.eventId == event.id && $0.calendarId == event.calendarId }
        let fields = [event.summary, event.location, event.description] + roster.flatMap { [$0.email, $0.displayName] }
        return fields.contains { $0?.lowercased().contains(term) == true }
    }

    /// A cached event in the shape `summary` gives a live one.
    static func row(account: String, _ event: CalendarStore.Event, _ attendees: [CalendarStore.Attendee]) -> [String: Any] {
        let roster = attendees.filter { $0.eventId == event.id && $0.calendarId == event.calendarId }
        let everyone = roster.map(\.email)
        let own = roster.first { $0.email.caseInsensitiveCompare(account) == .orderedSame }
        var out: [String: Any] = [
            "account": account, "id": event.id,
            "summary": event.summary ?? "(no title)",
            "start": event.startRaw ?? "", "end": event.endRaw ?? "",
            "allDay": event.isAllDay, "location": event.location ?? "",
            "attendees": Array(everyone.prefix(attendeeCap)),
            "responseStatus": own?.responseStatus ?? "accepted",
            "organizer": roster.first { $0.organizer }?.email ?? "",
            "hangoutLink": event.hangoutLink ?? "",
        ]
        if let transparency = event.transparency { out["transparency"] = transparency }
        let total = event.attendeeCount ?? everyone.count
        if total > attendeeCap { out["moreAttendees"] = total - attendeeCap }
        return out
    }

    /// Google's free/busy rule over cached rows: an event blocks time unless it is cancelled,
    /// marked free, or one the user declined. Clipped to the window and merged, soonest first.
    static func busy(_ events: [CalendarStore.Event], attendees: [CalendarStore.Attendee], account: String,
                     window: (Int64, Int64), offset: String, zone: TimeZone = .current) -> [[String: String]] {
        var spans: [(Int64, Int64)] = []
        for event in events where event.status != "cancelled" && event.transparency != "transparent" {
            let own = attendees.first {
                $0.eventId == event.id && $0.calendarId == event.calendarId
                    && $0.email.caseInsensitiveCompare(account) == .orderedSame
            }
            if own?.responseStatus == "declined" { continue }
            guard let span = span(of: event, zone: zone) else { continue }
            let from = Swift.max(span.0, window.0), to = Swift.min(span.1, window.1)
            if to > from { spans.append((from, to)) }
        }
        spans.sort { $0.0 < $1.0 }
        var merged: [(Int64, Int64)] = []
        for span in spans {
            if let last = merged.last, span.0 <= last.1 {
                merged[merged.count - 1].1 = Swift.max(last.1, span.1)
            } else {
                merged.append(span)
            }
        }
        return merged.map { ["start": atOffset(Double($0.0), offset), "end": atOffset(Double($0.1), offset)] }
    }

    /// An event's epoch-ms span. All-day dates are cached at UTC midnight for sorting; here they
    /// cover the user's own day, the way Google's free/busy reads them.
    static func span(of event: CalendarStore.Event, zone: TimeZone) -> (Int64, Int64)? {
        if event.isAllDay, let start = event.startRaw, let end = event.endRaw {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = zone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let from = formatter.date(from: start), let to = formatter.date(from: end) {
                return (Int64(from.timeIntervalSince1970 * 1000), Int64(to.timeIntervalSince1970 * 1000))
            }
        }
        guard let from = event.startEpochMs, let to = event.endEpochMs else { return nil }
        return (from, to)
    }

    /// The phone's own UTC offset as RFC3339 writes it, for a lookup whose times carried none.
    static func offsetString(_ zone: TimeZone = .current, at date: Date = Date()) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        return (seconds < 0 ? "-" : "+") + String(format: "%02d:%02d", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
    }

    private static func freeBusy(token: String, timeMin: String, timeMax: String) async throws -> [[String: String]] {
        let data = try await CalendarAPI.json("POST", path: "freeBusy",
            body: ["timeMin": timeMin, "timeMax": timeMax, "items": [["id": "primary"]]], token: token)
        let primary = (data["calendars"] as? [String: Any])?["primary"] as? [String: Any]
        guard let primary, (primary["errors"] as? [Any])?.isEmpty ?? true,
              let busy = primary["busy"] as? [[String: Any]] else {
            throw Refusal(text: "calendar_availability_unavailable")
        }
        return try busy.map { interval in
            guard let start = interval["start"] as? String, let end = interval["end"] as? String,
                  let from = instant(start), let to = instant(end), to > from else {
                throw Refusal(text: "calendar_availability_unavailable")
            }
            return ["start": start, "end": end]
        }
    }

    /// The shape the Feed's calendar card parses.
    static func summary(account: String, _ event: [String: Any]) -> [String: Any] {
        let start = event["start"] as? [String: Any], end = event["end"] as? [String: Any]
        let people = event["attendees"] as? [[String: Any]] ?? []
        let everyone = people.compactMap { $0["email"] as? String }.filter { !$0.isEmpty }
        let organizer = event["organizer"] as? [String: Any]
        var out: [String: Any] = [
            "account": account, "id": event["id"] as? String ?? "",
            "summary": event["summary"] as? String ?? "(no title)",
            "start": start?["dateTime"] as? String ?? start?["date"] as? String ?? "",
            "end": end?["dateTime"] as? String ?? end?["date"] as? String ?? "",
            "allDay": start?["date"] != nil, "location": event["location"] as? String ?? "",
            "attendees": Array(everyone.prefix(attendeeCap)),
            "responseStatus": people.first { $0["self"] as? Bool == true }?["responseStatus"] as? String ?? "accepted",
            "organizer": organizer?["email"] as? String ?? organizer?["displayName"] as? String ?? "",
            "hangoutLink": event["hangoutLink"] as? String ?? "",
        ]
        if let transparency = event["transparency"] as? String { out["transparency"] = transparency }
        if everyone.count > attendeeCap { out["moreAttendees"] = everyone.count - attendeeCap }
        return out
    }

    // MARK: - create_calendar_event

    /// Titles that mean the model had nothing to put here.
    static let placeholderTitles: Set<String> = [
        "placeholder", "place holder", "untitled", "untitled event", "test", "test event",
        "ignore", "tbd", "n/a", "none",
    ]

    private static func runCreate(_ args: [String: Any], accounts: [String]) async throws -> String {
        let target = try singleTarget(args, accounts, creating: true)
        let trim = { (key: String) in (args[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let title = trim("summary"), start = trim("start"), end = trim("end")
        guard !title.isEmpty, !start.isEmpty, !end.isEmpty else {
            throw Refusal(text: "Need a title, a start and an end to create an event.")
        }
        if placeholderTitles.contains(title.lowercased()) {
            throw Refusal(text: "NOT CREATED — \"\(title)\" is not an event the user asked for. Never "
                + "invent a title to fill this tool in, to test that it works, or to recover "
                + "from another tool's refusal. Nothing was added to the calendar. If they "
                + "asked about the calendar, read it with list_calendar_events; otherwise go "
                + "back to what they actually asked for.")
        }
        if let utc = utcRefusal("NOT CREATED", [start, end]) { throw Refusal(text: utc) }
        let attendees = (args["attendees"] as? [Any])?.compactMap { $0 as? String }
        let isPrivate = args["private"] as? Bool == true
        let venue = trim("location")
        let conference = args["online"] as? Bool == true || (args["online"] as? Bool != false && venue.isEmpty)

        let zone = TimeZone.current.identifier
        var body: [String: Any] = ["summary": title,
            "start": ["dateTime": start, "timeZone": zone], "end": ["dateTime": end, "timeZone": zone]]
        if let description = args["description"] as? String, !description.isEmpty { body["description"] = description }
        if let location = args["location"] as? String, !location.isEmpty { body["location"] = location }
        if isPrivate { body["visibility"] = "private" }
        if let attendees, !attendees.isEmpty { body["attendees"] = attendees.map { ["email": $0] } }
        var query = ["sendUpdates": "all"]
        if conference {
            body["conferenceData"] = ["createRequest": [
                "requestId": UUID().uuidString, "conferenceSolutionKey": ["type": "hangoutsMeet"]]]
            query["conferenceDataVersion"] = "1"
        }
        let token = try await accessToken(target, write: true, capability: "create events")
        let created: [String: Any]
        do {
            created = try await CalendarAPI.json("POST", path: "calendars/primary/events", query: query, body: body, token: token)
        } catch CalendarAPI.Failure.unauthorized {
            throw Refusal(text: reconnect(target, "create events"))
        }
        await cacheWrite(created, account: target)
        let id = created["id"] as? String ?? ""
        let link = created["htmlLink"] as? String ?? ""
        let invited = (attendees ?? []).isEmpty ? "" : " Invited \((attendees ?? []).joined(separator: ", "))."
        let marked = isPrivate ? " Marked private." : ""
        let online = conference ? " Added a Google Meet link." : ""
        return "Created \"\(title)\" (\(id)) on \(target).\(invited)\(marked)\(online) \(link)"
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - update_calendar_event

    private static func runUpdate(_ args: [String: Any], accounts: [String]) async throws -> String {
        let target = try singleTarget(args, accounts)
        let eventId = (args["event_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !eventId.isEmpty else {
            throw Refusal(text: "No event id — search or list the calendar first, then change one of the results.")
        }
        let newStart = string(args["start"]), newEnd = string(args["end"])
        if let utc = utcRefusal("NOT CHANGED", [newStart, newEnd]) { throw Refusal(text: utc) }
        let newSummary = string(args["summary"]), newDescription = string(args["description"])
        let newLocation = string(args["location"])
        let add = strings(args["add_attendees"]), remove = strings(args["remove_attendees"])
        guard [newSummary, newStart, newEnd, newDescription, newLocation].contains(where: { $0 != nil })
            || add != nil || remove != nil else {
            throw Refusal(text: "Nothing to change — say what should move: the time, the title, the location, the notes, or who is on it.")
        }

        let token = try await accessToken(target, write: true, capability: "change events")
        let path = "calendars/primary/events/\(eventId)"
        do {
            let event = try await CalendarAPI.json("GET", path: path, token: token)
            let title = event["summary"] as? String ?? "(no title)"
            if event["status"] as? String == "cancelled" {
                return "\"\(title)\" has already been cancelled, so there is nothing to change."
            }
            var body: [String: Any] = [:]
            var changed: [String] = []
            if let newSummary, newSummary != (event["summary"] as? String ?? "") {
                body["summary"] = newSummary
                changed.append("renamed from \"\(title)\" to \"\(newSummary)\"")
            }
            if let newLocation, newLocation != (event["location"] as? String ?? "") {
                body["location"] = newLocation
                changed.append(newLocation.isEmpty ? "location cleared" : "location set to \"\(newLocation)\"")
            }
            if let newDescription, newDescription != (event["description"] as? String ?? "") {
                body["description"] = newDescription
                changed.append(newDescription.isEmpty ? "notes cleared" : "notes updated")
            }
            let start = event["start"] as? [String: Any], end = event["end"] as? [String: Any]
            let current = (start: start?["dateTime"] as? String ?? start?["date"] as? String ?? "",
                           end: end?["dateTime"] as? String ?? end?["date"] as? String ?? "",
                           allDay: start?["date"] != nil)
            let timing: Retimed
            switch retime(current, newStart: newStart, newEnd: newEnd) {
            case .failure(let problem): return problem.text
            case .success(let value): timing = value
            }
            if let phrase = timing.phrase {
                let zone = TimeZone.current.identifier
                body["start"] = isDateOnly(timing.start) ? ["date": timing.start] : ["dateTime": timing.start, "timeZone": zone]
                body["end"] = isDateOnly(timing.end) ? ["date": timing.end] : ["dateTime": timing.end, "timeZone": zone]
                changed.append(phrase)
            }
            let merge = mergeAttendees(event["attendees"] as? [[String: Any]] ?? [], add: add ?? [], remove: remove ?? [])
            if !merge.added.isEmpty || !merge.removed.isEmpty {
                body["attendees"] = merge.attendees
                if !merge.added.isEmpty { changed.append("invited \(merge.added.joined(separator: ", "))") }
                if !merge.removed.isEmpty { changed.append("removed \(merge.removed.joined(separator: ", "))") }
            }
            let reported = body["summary"] as? String ?? title
            let scope = isInstanceId(eventId) ? " This was that one occurrence, not the whole recurring series." : ""
            let selfNote = merge.refusedSelfRemoval
                ? " You can't take yourself off an event this way — decline it instead, which tells the organizer." : ""
            if changed.isEmpty {
                return "\"\(reported)\" is already like that on \(target). Nothing changed and no one was notified.\(selfNote)\(scope)"
            }
            let patched = try await CalendarAPI.json("PATCH", path: path, query: ["sendUpdates": "all"], body: body, token: token)
            await cacheWrite(patched, account: target)
            let guests = merge.attendees.filter { $0["self"] as? Bool != true }.count
            let told = guests > 0 ? " The \(guests == 1 ? "guest was" : "\(guests) guests were") notified." : ""
            return "Updated \"\(reported)\" on \(target) — \(changed.joined(separator: "; ")).\(told)\(selfNote)\(scope)"
        } catch CalendarAPI.Failure.unauthorized {
            throw Refusal(text: reconnect(target, "change events"))
        } catch CalendarAPI.Failure.http(404) {
            throw Refusal(text: "NOT CHANGED — that event id doesn't resolve on \(target)'s calendar. "
                + "List the calendar again and use an id from those results. "
                + "Tell the user you couldn't find the event; never say you changed it.")
        }
    }

    // MARK: - Write-through

    /// The phone's copy is true the moment Google confirms a create or update, the way an RSVP or a
    /// cancel already is: a lookup answered from the cache a second later must see it, whether the
    /// write ran in the call or in a dispatched task (which `RealtimeService`'s post-write pass never sees).
    static func cacheWrite(_ event: [String: Any], account: String) async {
        guard let (row, attendees) = ingest(event, account: account) else { return }
        await CalendarStore(database: Container.shared.localContext().dbPool).cache(events: [row], attendees: attendees)
    }

    /// Google's returned event, decoded the way the background pass decodes a listed one.
    static func ingest(_ event: [String: Any], account: String) -> (CalendarStore.Event, [CalendarStore.Attendee])? {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let decoded = try? JSONDecoder().decode(CalendarAPI.Event.self, from: data) else { return nil }
        return BackgroundCalendarRefresh.ingest(decoded, account: account)
    }

    // MARK: - Pure helpers

    static func isInstanceId(_ id: String) -> Bool {
        id.range(of: #"_\d{8}(T\d{6}Z)?$"#, options: .regularExpression) != nil
    }

    static func isDateOnly(_ stamp: String) -> Bool {
        stamp.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    static func offset(of stamp: String) -> String {
        guard let range = stamp.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) else { return "" }
        return String(stamp[range])
    }

    /// Epoch ms of an RFC3339 time, or of a bare date at UTC midnight.
    static func instant(_ stamp: String) -> Double? {
        let formatter = ISO8601DateFormatter()
        if isDateOnly(stamp) {
            formatter.formatOptions = [.withFullDate]
        } else if stamp.contains(".") {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        }
        return formatter.date(from: stamp).map { $0.timeIntervalSince1970 * 1000 }
    }

    static func atOffset(_ ms: Double, _ offset: String) -> String {
        let sign: Double = offset.hasPrefix("-") ? -1 : 1
        let parts = offset.dropFirst().split(separator: ":").compactMap { Double($0) }
        let minutes = (parts.first ?? 0) * 60 + (parts.dropFirst().first ?? 0)
        let shifted = Date(timeIntervalSince1970: (ms + sign * minutes * 60_000) / 1000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: shifted)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0) + offset
    }

    struct Retimed: Equatable { let start: String, end: String, phrase: String? }

    /// A lone new start keeps the event's length; mixed forms are refused.
    static func retime(_ current: (start: String, end: String, allDay: Bool),
                       newStart: String?, newEnd: String?) -> Result<Retimed, Refusal> {
        if newStart == nil && newEnd == nil { return .success(Retimed(start: current.start, end: current.end, phrase: nil)) }
        let shapeError = Refusal(text: current.allDay
            ? "That's an all-day event. Pass start and end as plain dates (YYYY-MM-DD), or pass both to give it a clock time instead."
            : "That event has a start and end time. Pass RFC3339 timestamps, or pass both start and end as dates (YYYY-MM-DD) to make it all-day.")
        let start = newStart ?? current.start
        var end = newEnd ?? current.end
        if let newStart, let newEnd {
            if isDateOnly(newStart) != isDateOnly(newEnd) {
                return .failure(Refusal(text: "Pass start and end in the same form — both plain dates for an all-day event, or both with a time."))
            }
        } else if let newStart {
            if isDateOnly(newStart) != current.allDay { return .failure(shapeError) }
            if current.allDay {
                guard let to = instant(newStart), let from = instant(current.start), let oldEnd = instant(current.end) else {
                    return .failure(shapeError)
                }
                end = String(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: (oldEnd + to - from) / 1000)).prefix(10))
            } else {
                let zone = offset(of: newStart).isEmpty ? offset(of: current.start) : offset(of: newStart)
                guard !zone.isEmpty else {
                    return .failure(Refusal(text: "Pass both a start and an end — \"\(current.start)\" carries no UTC "
                        + "offset, so there is no safe way to work out where the new end lands."))
                }
                guard let at = instant(offset(of: newStart).isEmpty ? newStart + zone : newStart),
                      let from = instant(current.start), let to = instant(current.end) else {
                    return .failure(Refusal(text: "\"\(newStart)\" isn't a time I can read. Use RFC3339, e.g. 2026-08-07T15:00:00-07:00."))
                }
                end = atOffset(at + (to - from), zone)
            }
        } else if isDateOnly(end) != current.allDay {
            return .failure(shapeError)
        }
        let zone = [offset(of: start), offset(of: end), offset(of: current.start)].first { !$0.isEmpty } ?? "+00:00"
        let resolve = { (stamp: String) in instant(isDateOnly(stamp) || !offset(of: stamp).isEmpty ? stamp : stamp + zone) }
        if let from = resolve(start), let to = resolve(end), to <= from {
            return .failure(Refusal(text: "That would end the event (\(end)) at or before it starts (\(start)). Say the new time again."))
        }
        let movedStart = start != current.start, movedEnd = end != current.end
        let phrase: String? = movedStart && movedEnd ? "moved from \(current.start) to \(start), now ending \(end)"
            : movedStart ? "moved from \(current.start) to \(start)"
            : movedEnd ? "now ends \(end) instead of \(current.end)" : nil
        return .success(Retimed(start: start, end: end, phrase: phrase))
    }

    /// Add and remove against Google's full attendee list; the user is never removed this way.
    static func mergeAttendees(_ current: [[String: Any]], add: [String], remove: [String])
        -> (attendees: [[String: Any]], added: [String], removed: [String], refusedSelfRemoval: Bool) {
        let key = { (email: String) in email.trimmingCharacters(in: .whitespaces).lowercased() }
        var addKeys = Set(add.map(key).filter { !$0.isEmpty })
        var removeKeys = Set(remove.map(key).filter { !$0.isEmpty })
        let both = addKeys.intersection(removeKeys)
        addKeys.subtract(both)
        removeKeys.subtract(both)
        var removed: [String] = []
        var refusedSelfRemoval = false
        var attendees = current.filter { attendee in
            let email = attendee["email"] as? String ?? ""
            guard removeKeys.contains(key(email)) else { return true }
            if attendee["self"] as? Bool == true { refusedSelfRemoval = true; return true }
            removed.append(email)
            return false
        }
        var present = Set(attendees.map { key($0["email"] as? String ?? "") })
        var added: [String] = []
        for email in add where addKeys.contains(key(email)) && !present.contains(key(email)) {
            present.insert(key(email))
            let trimmed = email.trimmingCharacters(in: .whitespaces)
            added.append(trimmed)
            attendees.append(["email": trimmed])
        }
        return (attendees, added, removed, refusedSelfRemoval)
    }

    static func utcRefusal(_ prefix: String, _ times: [String?]) -> String? {
        let stamped = times.compactMap { $0 }.filter { $0.lowercased().hasSuffix("z") }
        guard !stamped.isEmpty else { return nil }
        return "\(prefix) — \(stamped.joined(separator: " and ")) \(stamped.count > 1 ? "end" : "ends") in \"Z\", "
            + "which is read as UTC and puts the event at the wrong hour. Use the offset given in "
            + "your instructions, e.g. 2026-08-04T14:00:00-07:00, or leave the "
            + "offset off entirely to mean the user's own local time."
    }

    /// An invitation is a send: refuse a guest that isn't an address before anyone is emailed.
    static func attendeeRefusal(_ name: String, _ args: [String: Any], canResolve: Bool) -> String? {
        let field = name == create ? "attendees" : name == update ? "add_attendees" : nil
        guard let field else { return nil }
        let bad = (args[field] as? [Any] ?? []).filter { !looksLikeAddress($0) }
        guard !bad.isEmpty else { return nil }
        let quoted = bad.map { "\"\($0)\"" }.joined(separator: ", ")
        return "\(name == create ? "NOT CREATED" : "NOT CHANGED") — \(quoted) "
            + "\(bad.count > 1 ? "are not email addresses" : "is not an email address"). "
            + "\(canResolve ? "Use find_person to resolve it, or ask the user." : "Ask the user for it.") "
            + "Nothing has gone yet."
    }

    static func looksLikeAddress(_ raw: Any) -> Bool {
        guard let raw = raw as? String else { return false }
        var bare = raw
        if let open = raw.firstIndex(of: "<"), let close = raw[open...].firstIndex(of: ">") {
            bare = String(raw[raw.index(after: open)..<close])
        }
        return bare.trimmingCharacters(in: .whitespaces)
            .range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }
}
