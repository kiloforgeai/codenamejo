import Foundation

enum CalendarWriteTiming {
    static func zone(_ name: String?) throws -> TimeZone {
        guard let name else { return .current }
        guard let zone = TimeZone(identifier: name) else {
            throw CalendarTools.Refusal(text: "No calendar change: use a valid IANA time zone, such as America/Los_Angeles.")
        }
        return zone
    }

    static func validate(_ stamp: String, zone: TimeZone) throws {
        let offset = CalendarTools.offset(of: stamp)
        guard !offset.isEmpty, let instant = CalendarTools.instant(stamp) else {
            throw CalendarTools.Refusal(text: "No calendar change: provide a complete RFC3339 time with an explicit offset.")
        }
        let parts = offset.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { throw CalendarTools.Refusal(text: "No calendar change: invalid time offset.") }
        let supplied = (parts[0] * 60 + parts[1]) * 60 * (offset.hasPrefix("-") ? -1 : 1)
        let expected = zone.secondsFromGMT(for: Date(timeIntervalSince1970: instant / 1_000))
        guard supplied == expected else {
            throw CalendarTools.Refusal(text: "No calendar change: \(stamp) has an offset inconsistent with \(zone.identifier) on the event date. Resolve the intended wall-clock time using that date's daylight-saving rules and retry; do not shift the requested hour. Nonexistent local times need clarification.")
        }
    }

    static func validate(start: String, end: String, zone: TimeZone) throws {
        try validate(start, zone: zone)
        try validate(end, zone: zone)
        guard let from = CalendarTools.instant(start), let to = CalendarTools.instant(end), to > from else {
            throw CalendarTools.Refusal(text: "No calendar change: the end must be after the start.")
        }
    }

    static func metadata(request: [String: Any], event: [String: Any]) -> [String: String] {
        var fields: [String: String] = [:]
        fields["time_zone"] = request["time_zone"] as? String ?? TimeZone.current.identifier
        fields["requested_start"] = request["start"] as? String
        fields["requested_end"] = request["end"] as? String
        for key in ["start", "end"] {
            let value = event[key] as? [String: Any] ?? [:]
            fields["stored_" + key] = value["dateTime"] as? String ?? value["date"] as? String
        }
        return fields
    }

    static func receipt(_ event: [String: Any]) -> String {
        let start = event["start"] as? [String: Any] ?? [:]
        let end = event["end"] as? [String: Any] ?? [:]
        return "Stored time: \(start["dateTime"] as? String ?? start["date"] as? String ?? "unknown") to "
            + "\(end["dateTime"] as? String ?? end["date"] as? String ?? "unknown")."
    }
}
