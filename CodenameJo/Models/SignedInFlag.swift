import Foundation

/// The "you were signed in" note. iOS keeps Keychain items across a delete and reinstall, so a
/// Keychain token counts only when this flag (wiped with the container) is also set.
enum SignedInFlag {
    static let storageKey = "isLoggedIn"

    static var isSet: Bool {
        UserDefaults.standard.bool(forKey: storageKey)
    }

    static func set(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: storageKey)
    }

    /// Removed rather than set false, so a reinstall and a sign-out look the same to
    /// every reader.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
