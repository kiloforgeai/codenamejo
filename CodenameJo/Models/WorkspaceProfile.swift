import Foundation

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
