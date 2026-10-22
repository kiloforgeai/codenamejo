import Foundation

/// A request captures this value before leaving the main actor; it never follows a later switch.
enum ProfileRuntime {
    struct Scope: Sendable {
        let profileId: String
        let isDefault: Bool
        /// The active profile's connected addresses, lowercased. `nil` means "not fetched
        /// yet" and filters nothing; `[]` means an empty profile and filters everything.
        var emails: [String]? = nil
        /// Whether a profile switch is offered here; `WorkspaceProfileStore` sets it.
        var canSwitch = false
        var mailHeadersOnly: Bool? = nil
        var membershipRevision: Int? = nil

        func containsMailbox(_ account: String) -> Bool {
            emails?.contains { $0.caseInsensitiveCompare(account) == .orderedSame } == true
        }
    }
    private static let lock = NSLock()
    private static var value: Scope?
    static var snapshot: Scope? { lock.lock(); defer { lock.unlock() }; return value }
    static func install(_ scope: Scope?) { lock.lock(); defer { lock.unlock() }; value = scope }
    /// The device's mail accounts narrowed to the active profile's connections. `nil` emails
    /// (connections not fetched yet) filters nothing; an empty profile filters everything.
    static func allowedMailAccounts(_ accounts: [String]) -> [String] {
        guard let emails = snapshot?.emails else { return accounts }
        return accounts.filter { emails.contains($0.lowercased()) }
    }
}
