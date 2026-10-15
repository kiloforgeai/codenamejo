import FactoryKit
import Foundation
import FoundationModels

/// What a tool says to the user straight away, before the model's own turn ends, and the signal
/// that the turn is over so nothing the model writes afterwards is spoken.
struct Voice: Sendable {
    let say: @Sendable (String) -> Void
    let done: @Sendable () -> Void
    static let silent = Voice(say: { _ in }, done: {})
}

/// The calendar for a local call's on-device engine: what is on a day, adding an event, and
/// cancelling one. Reads come from the phone's cache when it covers the window, else from
/// Google; writes are spoken at once and land on Google in the background.
enum LocalVoiceCalendar {
    static let read = "read_calendar"
    static let add = "add_calendar_event"
    static let cancel = "cancel_calendar_event"
    static let maxDays = 7

    /// All three tools. `transcript` is the user's own words, which alone can authorize a write;
    /// a write that fails in the background is told on `conversationId`'s next turn.
    static func tools(transcript: String, now: Date = Date(), conversationId: String? = nil,
                      voice: Voice = .silent) -> [any Tool] {
        [ReadCalendar(now: now, voice: voice),
         AddCalendarEvent(transcript: transcript, now: now, conversationId: conversationId, voice: voice),
         CancelCalendarEvent(transcript: transcript, now: now, conversationId: conversationId, voice: voice)]
    }

    /// "Wednesday, October 14, 2026, 3:12 PM", so the model can turn a weekday into a day offset.
    static func spokenNow(_ now: Date, calendar: Calendar = .current) -> String {
        formatter(calendar, "EEEE, MMMM d, yyyy").string(from: now) + ", " + clock(now, calendar: calendar)
    }

    /// Day 0 is the rest of today, as the Feed's calendar stage reads it; later days start at
    /// midnight. `days` is clamped to a week.
    static func window(dayOffset: Int, days: Int, now: Date,
                       calendar: Calendar = .current) -> (startMs: Int64, endMs: Int64) {
        let first = day(dayOffset, from: now, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: span(days), to: first) ?? first
        return (ms(dayOffset <= 0 ? now : first), ms(end))
    }

    /// The whole local day, for finding an event by name whether or not it has started.
    static func dayWindow(dayOffset: Int, now: Date, calendar: Calendar = .current) -> (startMs: Int64, endMs: Int64) {
        let first = day(dayOffset, from: now, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: 1, to: first) ?? first
        return (ms(first), ms(end))
    }

    static func start(dayOffset: Int, hour: Int, minute: Int, now: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day(dayOffset, from: now, calendar: calendar))
    }

    /// RFC3339 in the phone's zone, as `CalendarTools` writes it.
    static func stamp(_ date: Date, zone: TimeZone = .current) -> String {
        CalendarTools.atOffset(date.timeIntervalSince1970 * 1000, CalendarTools.offsetString(zone, at: date))
    }

    /// The window's events as one spoken sentence, soonest first, without cancellations.
    static func spoken(_ events: [CalendarStore.Event], dayOffset: Int, days: Int, now: Date,
                       calendar: Calendar = .current) -> String {
        let when = dayPhrase(dayOffset: dayOffset, days: days, now: now, calendar: calendar)
        let kept = events.filter { $0.status != "cancelled" }
            .sorted { ($0.startEpochMs ?? 0) < ($1.startEpochMs ?? 0) }
        guard !kept.isEmpty else { return "Nothing on your calendar \(when)." }
        let lines = kept.map { line($0, multiDay: span(days) > 1, calendar: calendar) }
        let count = kept.count == 1 ? "one thing" : "\(kept.count) things"
        return "\(when.prefix(1).uppercased() + when.dropFirst()) you have \(count): \(joined(lines))."
    }

    /// The untuned models misfire on a confirmation or on Jo's own leaked speech, so for them the
    /// user's own words must ask for the event; the tuned model is trusted to read the request.
    nonisolated static func allowsCreate(_ transcript: String) -> Bool {
        LocalModel.usesTuned || said(transcript, any: ["add", "put", "schedule", "create", "block", "book", "set up", "hold"])
    }

    nonisolated static func allowsCancel(_ transcript: String) -> Bool {
        LocalModel.usesTuned
            || said(transcript, any: ["cancel", "delete", "remove", "scrap", "take off", "get rid", "decline"])
    }

    /// "Decline" on someone else's invitation answers no, which tells the organizer; a cancel
    /// would only take it off this calendar.
    nonisolated static func saysDecline(_ transcript: String) -> Bool {
        said(transcript, any: ["decline", "declined", "declining"])
    }

    /// The events whose title carries every content word the user said ("12 to 1 lunch" is
    /// "lunch") and, when they gave an hour, start in it; an hour alone finds the event at it.
    static func matches(_ events: [CalendarStore.Event], title: String, hour: Int = -1,
                        calendar: Calendar = .current) -> [CalendarStore.Event] {
        let wanted = words(title).filter { !filler.contains($0) && Int($0) == nil }
        guard !wanted.isEmpty || hour >= 0 else { return [] }
        return events.filter { $0.status != "cancelled" }
            .filter { event in
                // "stand up" is "Standup": the words joined must appear too.
                let have = words(event.summary ?? "")
                let named = wanted.allSatisfy(Set(have).contains) || have.joined().contains(wanted.joined())
                guard named else { return false }
                guard hour >= 0, let start = event.startEpochMs else { return true }
                return calendar.component(.hour, from: Date(timeIntervalSince1970: Double(start) / 1000)) == hour
            }
            .sorted { ($0.startEpochMs ?? 0) < ($1.startEpochMs ?? 0) }
    }

    /// Words that name a time or a kind of thing rather than the event.
    private static let filler: Set<String> = [
        "the", "a", "an", "my", "to", "at", "from", "on", "am", "pm", "o", "clock", "oclock", "today", "tomorrow",
        "this", "that", "event", "meeting", "appointment", "call", "block", "thing",
    ]

    /// What to say when a name fits no event on the day, or more than one. Nil for exactly one.
    static func ambiguity(_ found: [CalendarStore.Event], title: String, dayOffset: Int, now: Date,
                          calendar: Calendar = .current) -> String? {
        let day = dayPhrase(dayOffset: dayOffset, days: 1, now: now, calendar: calendar)
        switch found.count {
        case 1: return nil
        case 0: return "Nothing called \(title) \(day). Nothing was cancelled."
        default:
            let lines = found.map { line($0, multiDay: false, calendar: calendar) }
            return "\(found.count) things \(day) match \(title): \(joined(lines)). Ask which one; nothing was cancelled."
        }
    }

    /// "Added Dentist, tomorrow at 3 PM for an hour."
    static func added(title: String, start: Date, minutes: Int, now: Date, calendar: Calendar = .current) -> String {
        "Added \(title), \(when(start, allDay: false, now: now, calendar: calendar)) for \(duration(minutes))."
    }

    /// "Cancelled Dentist, tomorrow at 3 PM.", or "Declined" when answering an invitation.
    static func cancelled(_ event: CalendarStore.Event, declining: Bool = false, now: Date,
                          calendar: Calendar = .current) -> String {
        let name = event.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = name.isEmpty ? "the event" : name
        let start = event.startEpochMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        let at = start.map { ", " + when($0, allDay: event.isAllDay, now: now, calendar: calendar) } ?? ""
        return "\(declining ? "Declined" : "Cancelled") \(title)\(at)."
    }

    // MARK: - Wording

    private static func span(_ days: Int) -> Int { min(max(days, 1), maxDays) }

    private static func day(_ offset: Int, from now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: max(offset, 0), to: today) ?? today
    }

    private static func dayPhrase(dayOffset: Int, days: Int, now: Date, calendar: Calendar) -> String {
        let name = dayName(dayOffset, now: now, calendar: calendar)
        if span(days) > 1 {
            return dayOffset <= 0 ? "over the next \(span(days)) days" : "over the \(span(days)) days from \(name)"
        }
        return dayOffset <= 1 ? name : "on \(name)"
    }

    private static func dayName(_ offset: Int, now: Date, calendar: Calendar) -> String {
        switch offset {
        case ...0: return "today"
        case 1: return "tomorrow"
        case 2...6: return formatter(calendar, "EEEE").string(from: day(offset, from: now, calendar: calendar))
        default: return formatter(calendar, "MMMM d").string(from: day(offset, from: now, calendar: calendar))
        }
    }

    /// "tomorrow at 3 PM", or just the day for an all-day event.
    private static func when(_ start: Date, allDay: Bool, now: Date, calendar: Calendar) -> String {
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                             to: calendar.startOfDay(for: start)).day ?? 0
        let day = dayPhrase(dayOffset: offset, days: 1, now: now, calendar: calendar)
        return allDay ? day : "\(day) at \(clock(start, calendar: calendar))"
    }

    private static func line(_ event: CalendarStore.Event, multiDay: Bool, calendar: Calendar) -> String {
        let title = event.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var line = title.isEmpty ? "an untitled event" : title
        let start = event.startEpochMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        if event.isAllDay {
            line += " all day"
        } else if let start {
            line += " at \(clock(start, calendar: calendar))"
        }
        if multiDay, let start { line += " on \(formatter(calendar, "EEEE").string(from: start))" }
        if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            line += " at \(location)"
        }
        return line
    }

    private static func joined(_ lines: [String]) -> String {
        guard lines.count > 1 else { return lines.joined() }
        return lines.dropLast().joined(separator: ", ") + ", and " + lines[lines.count - 1]
    }

    /// "3 PM" or "9:30 AM", assembled by hand so no locale puts a narrow space before the AM.
    private static func clock(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        let suffix = hour < 12 ? "AM" : "PM"
        return minute == 0 ? "\(twelve) \(suffix)" : "\(twelve):\(String(format: "%02d", minute)) \(suffix)"
    }

    private static func duration(_ minutes: Int) -> String {
        switch minutes {
        case 60: return "an hour"
        case 90: return "an hour and a half"
        case let whole where whole % 60 == 0: return "\(whole / 60) hours"
        default: return "\(minutes) minutes"
        }
    }

    /// Whether the user's own words carry one of `verbs` and no negation.
    private nonisolated static func said(_ transcript: String, any verbs: [String]) -> Bool {
        let words = transcript.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
        let said = " " + words.joined(separator: " ") + " "
        func has(_ phrases: [String]) -> Bool { phrases.contains { said.contains(" \($0) ") } }
        return !has(["don't", "dont", "do not", "never"]) && has(verbs)
    }

    private nonisolated static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func formatter(_ calendar: Calendar, _ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    private static func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    fileprivate static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Every connected calendar's events in the window, merged. `unreachable` when one could not be read.
    fileprivate static func events(_ window: (startMs: Int64, endMs: Int64),
                               accounts: [String]) async -> (events: [CalendarStore.Event], unreachable: Bool) {
        let store = CalendarStore(database: Container.shared.localContext().dbPool)
        var events: [CalendarStore.Event] = []
        var unreachable = false
        for account in accounts {
            let result = await CalendarSearch.run(timeMinMs: window.startMs, timeMaxMs: window.endMs, query: "",
                                                  account: account, store: store)
            events += result.events
            unreachable = unreachable || !result.successful
        }
        return (events, unreachable)
    }
}

/// Once per spoken turn, so a repeated tool call cannot write twice.
private actor Once {
    private var used = false
    func claim() -> Bool {
        defer { used = true }
        return !used
    }
}

private struct ReadCalendar: Tool {
    let name = LocalVoiceCalendar.read
    let description = "What is on the user's calendar on a day, or over the next few days."
    @Generable struct Arguments {
        @Guide(description: "Days from today: 0 is today, 1 is tomorrow.", .range(0...13))
        var dayOffset: Int
        @Guide(description: "How many days to include from that day: 1 for that day only, 7 for a week.", .range(1...7))
        var days: Int
    }
    let now: Date
    let voice: Voice

    func call(arguments: Arguments) async throws -> String {
        let accounts = await CalendarTools.accounts()
        var line = "No Google Calendar is connected."
        if !accounts.isEmpty {
            let window = LocalVoiceCalendar.window(dayOffset: arguments.dayOffset, days: arguments.days, now: now)
            let (events, unreachable) = await LocalVoiceCalendar.events(window, accounts: accounts)
            RealtimeLog.log("local-calendar: read day \(arguments.dayOffset) for \(arguments.days) day(s): "
                + "\(events.count) event(s)\(unreachable ? ", a calendar unreachable" : "")")
            line = LocalVoiceCalendar.spoken(events, dayOffset: arguments.dayOffset, days: arguments.days, now: now)
            if unreachable { line += " I couldn't reach one of your calendars." }
        }
        voice.say(line)
        voice.done()
        return line
    }
}

private struct AddCalendarEvent: Tool {
    let name = LocalVoiceCalendar.add
    let description = "Adds an event to the user's calendar. Use only when the user asked to add, schedule or "
        + "block something and gave a day and a time."
    @Generable struct Arguments {
        @Guide(description: "The event title, in the user's words.")
        var title: String
        @Guide(description: "Days from today: 0 is today, 1 is tomorrow.", .range(0...30))
        var dayOffset: Int
        @Guide(description: "Start hour, 0 to 23.", .range(0...23))
        var hour: Int
        @Guide(description: "Start minute.", .range(0...59))
        var minute: Int
        @Guide(description: "Length in minutes; 60 when the user gave none.", .range(5...480))
        var durationMinutes: Int
    }
    let transcript: String
    let now: Date
    let conversationId: String?
    let voice: Voice
    private let once = Once()

    func call(arguments: Arguments) async throws -> String {
        guard LocalVoiceCalendar.allowsCreate(transcript) else {
            RealtimeLog.log("local-calendar: add refused — no create verb in the user's words")
            voice.say("I didn't hear you ask to add anything, so nothing changed.")
            voice.done()
            return "Not added: the user did not ask to put anything on the calendar."
        }
        guard await once.claim() else { return "Already added this turn. Do not repeat it." }
        let title = arguments.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = LocalVoiceCalendar.start(dayOffset: arguments.dayOffset, hour: arguments.hour,
                                                   minute: arguments.minute, now: now) else {
            return "Not added: that time could not be placed on a day."
        }
        let end = start.addingTimeInterval(TimeInterval(arguments.durationMinutes * 60))
        let line = LocalVoiceCalendar.added(title: title, start: start, minutes: arguments.durationMinutes, now: now)
        voice.say(line)
        let body: [String: Any] = ["summary": title, "start": LocalVoiceCalendar.stamp(start),
                                   "end": LocalVoiceCalendar.stamp(end), "online": false]
        let json = LocalVoiceCalendar.json(body)
        let conversationId = conversationId
        // The write lands in the background; a failure is told on the next turn.
        Task.detached {
            let result = await CalendarTools.run(name: CalendarTools.create, argumentsJSON: json)
            let landed = result.output.hasPrefix("Created \"")
            RealtimeLog.log("local-calendar: add \(landed ? "landed" : "failed") — \(result.output.prefix(80))")
            if !landed {
                Container.shared.localWriteNotices().push("\(title) didn't make it onto the calendar after all.",
                                                          conversation: conversationId)
            }
        }
        voice.done()
        return line
    }
}

private struct CancelCalendarEvent: Tool {
    let name = LocalVoiceCalendar.cancel
    let description = "Cancels an event on the user's calendar. Use only when the user asked to cancel, delete or "
        + "remove one and named it."
    @Generable struct Arguments {
        @Guide(description: "Days from today: 0 is today, 1 is tomorrow.", .range(0...30))
        var dayOffset: Int
        @Guide(description: "The event's name as the user said it, without the time or words like the or my.")
        var title: String
        @Guide(description: "Start hour, 0 to 23, when the user said a time; -1 when they did not.", .range(-1...23))
        var hour: Int
    }
    let transcript: String
    let now: Date
    let conversationId: String?
    let voice: Voice
    private let once = Once()

    func call(arguments: Arguments) async throws -> String {
        guard LocalVoiceCalendar.allowsCancel(transcript) else {
            RealtimeLog.log("local-calendar: cancel refused — no cancel verb in the user's words")
            voice.say("I didn't hear you ask to cancel anything, so nothing changed.")
            voice.done()
            return "Not cancelled: the user did not ask to cancel anything."
        }
        guard await once.claim() else { return "Already cancelled this turn. Do not repeat it." }
        let accounts = await CalendarTools.accounts()
        guard !accounts.isEmpty else {
            voice.say("No Google Calendar is connected.")
            voice.done()
            return "No Google Calendar is connected."
        }
        let window = LocalVoiceCalendar.dayWindow(dayOffset: arguments.dayOffset, now: now)
        let (events, _) = await LocalVoiceCalendar.events(window, accounts: accounts)
        let found = LocalVoiceCalendar.matches(events, title: arguments.title, hour: arguments.hour)
        if let ambiguity = LocalVoiceCalendar.ambiguity(found, title: arguments.title, dayOffset: arguments.dayOffset,
                                                        now: now) {
            RealtimeLog.log("local-calendar: cancel \"\(arguments.title)\" hour \(arguments.hour) day \(arguments.dayOffset): "
                + "\(found.count) of \(events.count) match")
            voice.say(ambiguity)
            voice.done()
            return ambiguity
        }
        let event = found[0]
        let declining = LocalVoiceCalendar.saysDecline(transcript)
        let line = LocalVoiceCalendar.cancelled(event, declining: declining, now: now)
        voice.say(line)
        let conversationId = conversationId
        // The write lands in the background; a failure is told on the next turn. A decline goes
        // through the deferred path, which updates the cache and reports its own failure.
        Task.detached {
            if declining {
                let json = LocalVoiceCalendar.json(["event_id": event.id, "account": event.account, "response": "declined"])
                let result = await LocalCalendarWrites.run(name: LocalCalendarWrites.respond, argumentsJSON: json,
                                                           defer: true, conversationId: conversationId)
                RealtimeLog.log("local-calendar: decline \(result.ok == true ? "accepted" : "refused") — \(result.text.prefix(80))")
                if result.ok != true {
                    Container.shared.localWriteNotices().push("Declining \(event.summary ?? "that event") didn't go through.",
                                                              conversation: conversationId)
                }
                return
            }
            let json = LocalVoiceCalendar.json(["event_id": event.id, "account": event.account])
            let result = await LocalCalendarWrites.run(name: LocalCalendarWrites.cancel, argumentsJSON: json, defer: false)
            RealtimeLog.log("local-calendar: cancel \(result.ok == true ? "landed" : "refused") — \(result.text.prefix(80))")
            if result.ok == true {
                _ = await CalendarStore(database: Container.shared.localContext().dbPool)
                    .removeEvent(id: event.id, account: event.account)
            } else {
                Container.shared.localWriteNotices().push("Cancelling \(event.summary ?? "that event") didn't go through; "
                    + "it's still on the calendar.", conversation: conversationId)
            }
        }
        voice.done()
        return line
    }
}
