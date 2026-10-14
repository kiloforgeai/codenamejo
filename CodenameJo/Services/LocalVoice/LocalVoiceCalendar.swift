import FactoryKit
import Foundation
import FoundationModels

/// The calendar for a local call's on-device engine: what is on a day, and adding an event. Reads
/// come from the phone's cache when it covers the window, else from Google; writes go to Google.
enum LocalVoiceCalendar {
    static let read = "read_calendar"
    static let add = "add_calendar_event"
    static let maxDays = 7

    /// Both tools. `transcript` is the user's own words, which alone can authorize the write.
    static func tools(transcript: String, now: Date = Date()) -> [any Tool] {
        [ReadCalendar(now: now), AddCalendarEvent(transcript: transcript, now: now)]
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

    /// The user's own words must ask for the event, as `LocalInbox.allowsSend` requires "send".
    nonisolated static func allowsCreate(_ transcript: String) -> Bool {
        let words = transcript.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
        let said = " " + words.joined(separator: " ") + " "
        func has(_ phrases: [String]) -> Bool { phrases.contains { said.contains(" \($0) ") } }
        guard !has(["don't", "dont", "do not", "never"]) else { return false }
        return has(["add", "put", "schedule", "create", "block", "book", "set up", "hold"])
    }

    /// "Added Dentist, tomorrow at 3 PM for an hour." from a `CalendarTools` create receipt; a
    /// refusal or failure is passed through for the model to relay.
    static func added(_ output: String, title: String, start: Date, minutes: Int, now: Date,
                      calendar: Calendar = .current) -> String {
        guard output.hasPrefix("Created \"") else { return output }
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                             to: calendar.startOfDay(for: start)).day ?? 0
        let when = dayPhrase(dayOffset: offset, days: 1, now: now, calendar: calendar)
        return "Added \(title), \(when) at \(clock(start, calendar: calendar)) for \(duration(minutes))."
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
}

/// Once per spoken turn, so a repeated tool call cannot add an event twice.
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

    func call(arguments: Arguments) async throws -> String {
        let accounts = await CalendarTools.accounts()
        guard !accounts.isEmpty else { return "No Google Calendar is connected." }
        let window = LocalVoiceCalendar.window(dayOffset: arguments.dayOffset, days: arguments.days, now: now)
        let store = CalendarStore(database: Container.shared.localContext().dbPool)
        var events: [CalendarStore.Event] = []
        var unreachable = false
        for account in accounts {
            let result = await CalendarSearch.run(timeMinMs: window.startMs, timeMaxMs: window.endMs, query: "",
                                                  account: account, store: store)
            events += result.events
            unreachable = unreachable || !result.successful
        }
        RealtimeLog.log("local-calendar: read day \(arguments.dayOffset) for \(arguments.days) day(s): "
            + "\(events.count) event(s)\(unreachable ? ", a calendar unreachable" : "")")
        let spoken = LocalVoiceCalendar.spoken(events, dayOffset: arguments.dayOffset, days: arguments.days, now: now)
        return unreachable ? spoken + " I couldn't reach one of your calendars." : spoken
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
    private let once = Once()

    func call(arguments: Arguments) async throws -> String {
        guard LocalVoiceCalendar.allowsCreate(transcript) else {
            return "Not added: the user did not ask to put anything on the calendar."
        }
        guard await once.claim() else { return "Already added this turn. Do not repeat it." }
        let title = arguments.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = LocalVoiceCalendar.start(dayOffset: arguments.dayOffset, hour: arguments.hour,
                                                   minute: arguments.minute, now: now) else {
            return "Not added: that time could not be placed on a day."
        }
        let end = start.addingTimeInterval(TimeInterval(arguments.durationMinutes * 60))
        let body: [String: Any] = ["summary": title, "start": LocalVoiceCalendar.stamp(start),
                                   "end": LocalVoiceCalendar.stamp(end), "online": false]
        let json = (try? JSONSerialization.data(withJSONObject: body)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let result = await CalendarTools.run(name: CalendarTools.create, argumentsJSON: json)
        RealtimeLog.log("local-calendar: add \(result.failed ? "failed" : "done") — \(result.output.prefix(80))")
        return LocalVoiceCalendar.added(result.output, title: title, start: start, minutes: arguments.durationMinutes,
                                        now: now)
    }
}
