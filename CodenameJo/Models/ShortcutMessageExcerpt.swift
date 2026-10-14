import Foundation

/// Bound recent-message delivery before it enters the live call's context.
enum ShortcutMessageExcerpt {
    static let maxCharacters = 12_000

    /// Lines are not counted: a body's own line breaks would read as extra messages.
    static func bound(_ text: String) -> String {
        // A body must not be able to forge the "---" fence around untrusted content.
        let defanged = text.replacingOccurrences(of: "---", with: "—")
        return String(defanged.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxCharacters))
    }
}
