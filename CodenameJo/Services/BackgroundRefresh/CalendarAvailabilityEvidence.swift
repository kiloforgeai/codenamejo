import CryptoKit
import Foundation

/// A bounded availability receipt, distinct from a list of event titles or an assistant's claim.
struct CalendarAvailabilityEvidence: Codable, Hashable {
    struct Span: Codable, Hashable { let start: Date; let end: Date }
    struct Coverage: Codable, Hashable {
        let accountHash: String
        let source: String
        let complete: Bool
        let age: TimeInterval
    }
    struct Assessment: Codable, Hashable {
        let receiptID: String
        let start: String
        let end: String
        let status: String
        let spoken: String
    }
    let id: String
    let checkedAt: Date
    let start: Date?
    let end: Date?
    let timeZone: String
    let coverage: [Coverage]
    let complete: Bool
    let busy: [Span]

    init(id: String, arguments: String, output: String, expectedAccounts: [String], now: Date, zone: TimeZone) {
        self.id = id; checkedAt = now
        let args = ToolArguments(arguments)
        start = args.string("time_min").flatMap(Self.date)
        end = args.string("time_max").flatMap(Self.date)
        timeZone = args.string("time_zone") ?? zone.identifier
        let rows = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [[String: Any]] ?? []
        let expected = Set((args.string("account").map { [$0] } ?? expectedAccounts).map { $0.lowercased() })
        let found = Set(rows.compactMap { ($0["account"] as? String)?.lowercased() })
        var spans: [Span] = [], covered: [Coverage] = []
        for row in rows {
            let availability = row["availability"] as? [String: Any]
            var valid = row["error"] == nil && row["complete"] as? Bool != false && row["coverage"] as? String != "partial"
                && availability?["timeMin"].flatMap { $0 as? String }.flatMap(Self.date) == start
                && availability?["timeMax"].flatMap { $0 as? String }.flatMap(Self.date) == end
            if let intervals = availability?["busy"] as? [[String: String]] {
                for interval in intervals {
                    if let from = interval["start"].flatMap(Self.date), let to = interval["end"].flatMap(Self.date), to > from {
                        spans.append(.init(start: from, end: to))
                    } else { valid = false }
                }
            } else { valid = false }
            let account = row["account"] as? String ?? "missing"
            let hash = SHA256.hash(data: Data((id + account.lowercased()).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            covered.append(.init(accountHash: hash, source: row["source"] as? String ?? "provider",
                complete: valid, age: max(0, row["result_age_seconds"] as? Double ?? 0)))
        }
        coverage = covered
        complete = start != nil && end != nil && start! < end! && !expected.isEmpty && found == expected
            && rows.count == expected.count && covered.allSatisfy(\.complete)
        busy = Array(Set(spans)).sorted { $0.start < $1.start }
    }

    static func date(_ value: String) -> Date? { CalendarTools.instant(value).map { Date(timeIntervalSince1970: $0 / 1000) } }
    func fresh(at now: Date) -> Bool {
        complete && coverage.allSatisfy { max(0, now.timeIntervalSince(checkedAt)) + $0.age <= CalendarTools.cacheFreshness }
    }
    var context: [String: Any] {
        let format = ISO8601DateFormatter()
        return ["receipt_id": id, "checked_at": format.string(from: checkedAt), "time_zone": timeZone,
            "start": start.map(format.string) ?? "", "end": end.map(format.string) ?? "", "complete": complete,
            "coverage": coverage.map { ["account_hash": $0.accountHash, "source": $0.source, "calendar": "primary", "complete": $0.complete, "age_seconds": $0.age] as [String: Any] },
            "busy": busy.map { ["start": format.string(from: $0.start), "end": format.string(from: $0.end)] },
            "rule": "Only these checked busy intervals establish conflicts. Transparent/cancelled/declined events do not block. Before stating that a particular slot is free or conflicting, call check_calendar_slot with this receipt ID and exact timestamps. Partial or stale evidence means unverified, never a fabricated conflict."]
    }
    func assess(receiptID: String, start rawStart: String, end rawEnd: String, now: Date) -> Assessment {
        func result(_ status: String, _ text: String) -> Assessment { .init(receiptID: id, start: rawStart, end: rawEnd, status: status, spoken: text) }
        guard receiptID == id, fresh(at: now), let from = Self.date(rawStart), let to = Self.date(rawEnd),
              let start, let end, from >= start, to <= end, to > from else {
            return result("unverified", "Availability for that slot is unverified. I need a fresh, complete check of the requested calendars and time window.")
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZone) ?? .current; formatter.dateFormat = "MMM d, h:mm a z"
        let slot = formatter.string(from: from) + " to " + formatter.string(from: to)
        let overlaps = busy.filter { $0.start < to && $0.end > from }
        if overlaps.isEmpty { return result("free", "The latest calendar check shows \(slot) is free across the checked calendars.") }
        let intervals = overlaps.map { formatter.string(from: max(from, $0.start)) + " to " + formatter.string(from: min(to, $0.end)) }.joined(separator: "; ")
        return result("busy", "The latest calendar check shows a conflict for \(slot). The overlapping busy time is \(intervals).")
    }
    static let toolName = "check_calendar_slot"
    static var definition: [String: Any] { ["type": "function", "name": toolName,
        "description": "Check each exact proposed slot against the retained availability receipt before saying it is free or has a conflict. Call once per slot when proposing several options. Read list_calendar_events with availability_check first. This local check never creates an event.",
        "parameters": ["type": "object", "properties": ["receipt_id": ["type": "string"], "start": ["type": "string"], "end": ["type": "string"]], "required": ["receipt_id", "start", "end"], "additionalProperties": false]] }
    static func claimsAvailability(_ text: String) -> Bool {
        text.range(of: #"\b(?:conflicts?|busy|available|availability|free|overlaps?|double.booked)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
