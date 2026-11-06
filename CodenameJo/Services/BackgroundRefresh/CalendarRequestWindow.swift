import Foundation

/// A relative calendar range is resolved once from the user's request, never from an email's date.
struct CalendarRequestWindow: Codable, Hashable, Sendable {
    let reference: Date
    let zone: TimeZone
    let start: Date
    let end: Date
    let allCalendars: Bool

    init?(checkedArguments: String, reference: Date, zone: TimeZone) {
        let args = ToolArguments(checkedArguments)
        guard let from = args.string("time_min").flatMap(CalendarTools.instant),
              let to = args.string("time_max").flatMap(CalendarTools.instant), to > from else { return nil }
        self.reference = reference; self.zone = zone
        start = Date(timeIntervalSince1970: from / 1000); end = Date(timeIntervalSince1970: to / 1000)
        allCalendars = args.string("account") == nil
    }

    init?(request: String, reference: Date, zone: TimeZone) {
        guard request.range(of: #"\bnext\s+week\b"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = zone
        guard let week = calendar.dateInterval(of: .weekOfYear, for: reference),
              let end = calendar.date(byAdding: .weekOfYear, value: 1, to: week.end) else { return nil }
        self.reference = reference
        self.zone = zone
        start = week.end
        self.end = end
        allCalendars = request.range(of: #"\b(?:all|every|three|3)\b[^.!?]{0,45}\bcalendars?\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .iso8601)
        value.timeZone = zone
        return value
    }

    func stamp(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.timeZone = zone
        return format.string(from: date)
    }

    var context: [String: Any] {
        let label = DateFormatter()
        label.locale = Locale(identifier: "en_US_POSIX")
        label.timeZone = zone
        label.dateFormat = "EEEE yyyy-MM-dd"
        return ["phrase": "resolved calendar window", "reference": stamp(reference), "time_zone": zone.identifier,
            "start_inclusive": stamp(start), "end_exclusive": stamp(end),
            "all_calendars": allCalendars,
            "days": (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start).map { label.string(from: $0) } },
            "rule": "Use this resolved window for reads, proposed slots and speech. Compute each date's own time-zone offset. Old email dates and examples are not the clock. Availability requires complete fresh coverage across all requested calendars; partial or failed reads cannot establish that a slot is free."]
    }

    func contains(start from: Date, end to: Date) -> Bool {
        from >= start && from >= reference && to > from && to <= end
    }

    var rangeExplanation: String {
        "The requested calendar window is \(stamp(start)) through \(stamp(end)) exclusive, in \(zone.identifier)."
    }

    static func schedulingReply(name: String, arguments: String) -> Bool {
        guard ["send_email", "reply_email", "create_draft", "forward_email"].contains(name),
              let args = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else { return false }
        let text = ["body", "text", "html"].compactMap { args[$0] as? String }.joined(separator: " ")
        return text.range(of: #"\b(?:\d{4}-\d{2}-\d{2}|(?:Jan\w*|Feb\w*|Mar\w*|Apr\w*|May|Jun\w*|Jul\w*|Aug\w*|Sep\w*|Oct\w*|Nov\w*|Dec\w*)\s+\d{1,2}|available|free|slots?)\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    func toolRefusal(name: String, arguments: String, now: Date = Date()) -> String? {
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if CalendarTools.names.contains(name) {
            if name == CalendarTools.list, allCalendars, let account = args["account"] as? String, !account.isEmpty {
                return "Not executed: the user requested every calendar. Omit account to read all connected calendars in the same window. " + rangeExplanation
            }
            let first = args[name == CalendarTools.list ? "time_min" : "start"] as? String
            let last = args[name == CalendarTools.list ? "time_max" : "end"] as? String
            guard let first else { return nil }
            guard now < end, let from = CalendarTools.instant(first).map({ Date(timeIntervalSince1970: $0 / 1000) }),
                  let to = last.flatMap(CalendarTools.instant).map({ Date(timeIntervalSince1970: $0 / 1000) })
                    ?? calendar.date(byAdding: .second, value: 1, to: from),
                  contains(start: from, end: to) else {
                return "Not executed: the requested dates fall outside the user's resolved calendar window. " + rangeExplanation
            }
            do {
                try CalendarWriteTiming.validate(first.replacingOccurrences(of: "Z", with: "+00:00"), zone: zone)
                if let last { try CalendarWriteTiming.validate(last.replacingOccurrences(of: "Z", with: "+00:00"), zone: zone) }
            } catch { return "Not executed: use the offset for the requested date in \(zone.identifier). " + rangeExplanation }
        }
        if ["send_email", "reply_email", "create_draft", "forward_email"].contains(name),
           ["body", "text", "html"].compactMap({ args[$0] as? String }).contains(where: containsOutsideDate) {
            return "Not executed: the scheduling reply contains dates outside the requested week. " + rangeExplanation
        }
        return nil
    }

    func containsOutsideDate(_ text: String) -> Bool {
        func dayIsInRange(year: Int?, month: Int, day: Int) -> Bool {
            let years = year.map { [$0] } ?? Array(Set([calendar.component(.year, from: start), calendar.component(.year, from: end)]))
            return years.contains { year in
                guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                      calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day else { return false }
                return date >= start && date < end
            }
        }
        let full = NSRange(text.startIndex..., in: text)
        let patterns = [#"\b(\d{4})-(\d{2})-(\d{2})\b"#,
            #"\b(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b"#]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            for match in regex.matches(in: text, range: full) {
                func group(_ number: Int) -> String? { Range(match.range(at: number), in: text).map { String(text[$0]) } }
                if index == 0, let year = group(1).flatMap(Int.init), let month = group(2).flatMap(Int.init), let day = group(3).flatMap(Int.init),
                   !dayIsInRange(year: year, month: month, day: day) { return true }
                if index == 1, let name = group(1)?.lowercased().prefix(3),
                   let month = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(of: String(name)),
                   let day = group(2).flatMap(Int.init), !dayIsInRange(year: group(3).flatMap(Int.init), month: month + 1, day: day) { return true }
            }
        }
        return false
    }

    static func completeRead(_ output: String, window: Self? = nil) -> Bool {
        guard let rows = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]], !rows.isEmpty else { return false }
        return rows.allSatisfy { row in
            guard let availability = row["availability"] as? [String: Any] else { return false }
            if let window {
                guard let from = availability["timeMin"] as? String, let to = availability["timeMax"] as? String,
                      CalendarTools.instant(from) == window.start.timeIntervalSince1970 * 1000,
                      CalendarTools.instant(to) == window.end.timeIntervalSince1970 * 1000 else { return false }
            }
            return row["error"] == nil && row["coverage"] as? String != "partial" && row["complete"] as? Bool != false
                && (row["result_age_seconds"] as? Double ?? 0) <= CalendarTools.cacheFreshness
        }
    }
}
