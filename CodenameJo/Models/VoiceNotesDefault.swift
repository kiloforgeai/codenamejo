import Foundation

/// The account default for voice notes, left from builds whose broker answered it; absent reads as off.
/// The Voice notes switch overrides it.
enum VoiceNotesDefault {
    static let storageKey = "voiceNotesDefault"

    /// Read once per launch: the note pipeline starts at launch, so the button must not
    /// turn on mid-launch without it. A new answer applies at the next launch.
    private nonisolated(unsafe) static var launchValue: Bool?

    static var isOn: Bool {
        if let launchValue { return launchValue }
        let value = UserDefaults.standard.bool(forKey: storageKey)
        launchValue = value
        return value
    }

    /// Which account the Voice notes switch belongs to.
    static let ownerKey = "voiceNotesEnabledOwner"
    /// Owner of a flip made before this session's id was known; the next lookup adopts it.
    static let currentSession = "currentSession"

    /// Drops a switch left by any other account, so the next account starts from its own default.
    /// An unowned "off" stays: dropping it could switch notes on mid-launch.
    static func claim(for userId: String) {
        let defaults = UserDefaults.standard
        let owner = defaults.string(forKey: ownerKey)
        guard owner != userId, owner != currentSession else {
            defaults.set(userId, forKey: ownerKey)
            return
        }
        let choice = defaults.object(forKey: VoiceSettings.Key.voiceNotes) as? Bool
        if choice == true || owner != nil {
            defaults.removeObject(forKey: VoiceSettings.Key.voiceNotes)
        }
        defaults.set(userId, forKey: ownerKey)
    }

    /// The switch if it has an owner, else the account default: an unowned "on" is a leftover.
    static func effective(_ choice: Bool?, owner: String?) -> Bool {
        if choice == true, owner == nil { return isOn }
        return choice ?? isOn
    }

    /// Records the signed-in account as the switch's owner when the user flips it.
    static func stamp(_ userId: String?) {
        UserDefaults.standard.set(userId ?? currentSession, forKey: ownerKey)
    }

    /// Sign-out: off for the rest of this launch, so the next account inherits nothing.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        if UserDefaults.standard.string(forKey: ownerKey) == currentSession {
            UserDefaults.standard.removeObject(forKey: ownerKey)
        }
        launchValue = false
    }
}
