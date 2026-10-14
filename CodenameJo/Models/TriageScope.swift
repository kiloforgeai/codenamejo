import Foundation

/// Where a mail queue starts when the user hasn't said; no stored choice means `unread`. Raw values
/// are the server's `QueueScope` strings, so renaming a case rewrites a stored answer.
enum TriageScope: String, CaseIterable, Identifiable {
    case important
    case unread
    case all

    static let storageKey = "triageScope"

    var id: String { rawValue }

    /// Said the way the user would say it, because it is also what they hear back.
    var label: String {
        switch self {
        case .important: return "Important, then unread"
        case .unread: return "All my unread"
        case .all: return "Everything in my inbox"
        }
    }

    var detail: String {
        switch self {
        case .important: return "Start with what matters most this week, then keep going"
        case .unread: return "Every message in your inbox you haven't read"
        case .all: return "Read mail included — a full pass, top to bottom"
        }
    }

    var symbol: String {
        switch self {
        case .important: return "flag"
        case .unread: return "envelope.badge"
        case .all: return "tray.full"
        }
    }

    /// What they chose, or `nil` for the automatic start.
    static var preferred: TriageScope? {
        guard let raw = UserDefaults.standard.string(forKey: storageKey) else { return nil }
        return TriageScope(rawValue: raw)
    }

    static func store(_ scope: TriageScope) {
        UserDefaults.standard.set(scope.rawValue, forKey: storageKey)
    }

    /// Back to the automatic walk, represented by an absent profile key.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
