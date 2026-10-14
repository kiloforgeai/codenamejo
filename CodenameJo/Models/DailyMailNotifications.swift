import Foundation

/// Whether the account receives the server's daily email-queue push. Missing means disabled;
/// the value is mirrored into `UserProfile`, which the broker reads before an APNs send.
enum DailyMailNotifications {
    static let storageKey = "dailyMailNotifications"
    /// The selected wall-clock time, independent of UTC and daylight saving.
    /// For example, 8:30 AM is stored as `510`.
    static let minuteOfDayStorageKey = "dailyMailNotificationMinuteOfDay"
    /// IANA identifier from the phone, such as `America/Los_Angeles`. The broker
    /// needs this alongside the wall clock to know which UTC cron tick is due.
    static let timeZoneStorageKey = "dailyMailNotificationTimeZone"
    static let defaultMinuteOfDay = 9 * 60

    static func resolvedMinuteOfDay(_ stored: Int?) -> Int {
        guard let stored, (0..<(24 * 60)).contains(stored) else {
            return defaultMinuteOfDay
        }
        return stored
    }

    static func resolvedTimeZoneIdentifier(
        _ stored: String?,
        current: TimeZone = .autoupdatingCurrent
    ) -> String {
        guard let stored, TimeZone(identifier: stored) != nil else {
            return current.identifier
        }
        return stored
    }

    /// A stable date used only to bridge the wall clock into SwiftUI's DatePicker.
    /// The date itself is not persisted; only its hour and minute are.
    static func pickerDate(
        minuteOfDay: Int,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Date {
        let resolved = resolvedMinuteOfDay(minuteOfDay)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: 2001,
            month: 1,
            day: 15,
            hour: resolved / 60,
            minute: resolved % 60
        )) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    static func minuteOfDay(
        from date: Date,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return resolvedMinuteOfDay(
            components.hour.flatMap { hour in
                components.minute.map { hour * 60 + $0 }
            }
        )
    }
}
