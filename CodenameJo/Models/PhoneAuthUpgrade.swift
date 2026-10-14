import Foundation

/// Install-scoped, deliberately separate from account settings and ordinary sign-out.
enum PhoneAuthUpgrade {
    static let storageKey = "auth.phoneOnlyUpgrade.completed.v1"

    @discardableResult
    static func runIfNeeded(defaults: UserDefaults = .standard, reset: () -> Void) -> Bool {
        guard !defaults.bool(forKey: storageKey) else { return false }
        reset()
        defaults.set(true, forKey: storageKey)
        return true
    }
}
