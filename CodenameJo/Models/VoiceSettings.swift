import Foundation

/// What the user is allowed to decide about the voice call. Read from `UserDefaults` at the
/// point of use; views bind to the same keys with `@AppStorage`.
enum VoiceSettings {
    enum Key {
        static let voiceNotes = "voiceNotesEnabled"
    }

    /// Whether voice notes are enabled; off (the default) stops the whole path. Local to this
    /// phone, so deliberately absent from `UserProfile.capturingLocalSettings()`.
    static var voiceNotes: Bool {
        VoiceNotesDefault.effective(
            UserDefaults.standard.object(forKey: Key.voiceNotes) as? Bool,
            owner: UserDefaults.standard.string(forKey: VoiceNotesDefault.ownerKey))
    }
}
