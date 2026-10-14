import Foundation

/// The automatic calendar stage's cadence, kept on the phone: a failed read stays due, and a
/// successful one suppresses only the accounts it represented for the rest of the local day.
enum CalendarFeedCadence {
    private static let keyPrefix = "sequentialCalendarFeed.completed."

    static func owners(accounts: [String], userId: String?) -> [String] {
        var seen = Set<String>()
        let normalized = accounts.compactMap { raw -> String? in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return "account:\(value)"
        }
        if !normalized.isEmpty { return normalized }
        let fallback = userId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fallback.isEmpty ? [] : ["user:\(fallback)"]
    }

    static func isDue(
        owners: [String], date: Date = Date(), calendar: Calendar = .current,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard !owners.isEmpty else { return false }
        let day = localDay(for: date, calendar: calendar)
        return owners.contains { defaults.string(forKey: key(for: $0)) != day }
    }

    static func markComplete(
        owners: [String], date: Date = Date(), calendar: Calendar = .current,
        defaults: UserDefaults = .standard
    ) {
        let day = localDay(for: date, calendar: calendar)
        for owner in owners { defaults.set(day, forKey: key(for: owner)) }
    }

    /// Now through the end of the local day, the window the calendar feed stage reads. `dateInterval`,
    /// not a 24-hour add: a day the clocks change is 23 or 25 hours long.
    static func restOfLocalDay(
        now: Date = Date(), calendar: Calendar = .current
    ) -> (startMs: Int64, endMs: Int64) {
        let end = calendar.dateInterval(of: .day, for: now)?.end
            ?? calendar.startOfDay(for: now).addingTimeInterval(24 * 60 * 60)
        return (
            Int64((now.timeIntervalSince1970 * 1000).rounded()),
            Int64((end.timeIntervalSince1970 * 1000).rounded())
        )
    }

    static func localDay(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func key(for owner: String) -> String {
        keyPrefix + Data(owner.utf8).base64EncodedString()
    }
}
