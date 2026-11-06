import Foundation

struct FeedSection: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case important, remaining, calendar, slack }
    var kind: Kind
    var account: String? = nil
    var enabled = true
    var id: String { kind.rawValue + ":" + (account?.lowercased() ?? "") }
    var isMail: Bool { kind == .important || kind == .remaining }
    var title: String {
        switch kind {
        case .important: "Important emails"
        case .remaining: "Other emails"
        case .calendar: "Calendar"
        case .slack: "Slack"
        }
    }
    var subtitle: String { account ?? (kind == .calendar ? "The rest of today" : "Unread conversations") }
    var symbol: String {
        switch kind {
        case .important: "star"
        case .remaining: "tray"
        case .calendar: "calendar"
        case .slack: "number"
        }
    }

    static func isImportant(band: String?, received: Int64, now: Date = Date()) -> Bool {
        band == "high" && received >= Int64(now.addingTimeInterval(-7 * 86400).timeIntervalSince1970 * 1000)
    }

    static func resolved(_ saved: [Self]?, accounts: [String]) -> [Self] {
        var seenAccounts = Set<String>()
        let accounts = accounts.map { $0.lowercased() }.filter { seenAccounts.insert($0).inserted }
        let defaults = accounts.flatMap { [Self(kind: .important, account: $0), Self(kind: .remaining, account: $0)] }
            + [Self(kind: .calendar), Self(kind: .slack)]
        let valid = Set(defaults.map(\.id))
        var seen = Set<String>()
        return ((saved ?? []) + defaults).filter { valid.contains($0.id) && seen.insert($0.id).inserted }
    }
}

struct WorkspaceProfile: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let isDefault: Bool
    let createdAt: String
    var revision: Int? = nil
}

struct WorkspaceProfileConnection: Identifiable, Equatable {
    let id: String
    let email: String
    let profileId: String
    let needsReauth: Bool
}

struct WorkspaceProfileCapabilities: Equatable {
    let management: Bool
    /// A switch can happen inside a live call. Gates the picker.
    let liveSwitch: Bool
    let deletion: Bool

    static let unavailable = Self(management: false, liveSwitch: false, deletion: false)
}

enum WorkspaceProfileError: LocalizedError {
    case unavailable
    case invalidName
    case nameTaken
    case notFound
    case cannotDeleteDefault
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Profiles are not available yet."
        case .invalidName: return "Use a profile name between 1 and 80 characters without control characters."
        case .nameTaken: return "You already have a profile with that name."
        case .notFound: return "This profile is no longer available."
        case .cannotDeleteDefault: return "The Personal profile can’t be deleted."
        case .requestFailed: return "Couldn’t update profiles. Please try again."
        }
    }
}
