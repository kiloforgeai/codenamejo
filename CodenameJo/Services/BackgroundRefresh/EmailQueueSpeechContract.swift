import Foundation

/// Model-facing queue payloads never expose mailbox counts unless the user asks for one.
enum EmailQueueSpeechContract {
    private static let hiddenCountKeys: Set<String> = ["left", "leftAtLeast", "unreadLeft"]

    static func sanitize(_ payload: [String: Any]) -> [String: Any] {
        payload.reduce(into: [:]) { clean, entry in
            guard !hiddenCountKeys.contains(entry.key) else { return }
            clean[entry.key] = sanitizeValue(entry.value)
        }
    }

    private static func sanitizeValue(_ value: Any) -> Any {
        if let object = value as? [String: Any] { return sanitize(object) }
        if let array = value as? [Any] { return array.map(sanitizeValue) }
        return value
    }
}
