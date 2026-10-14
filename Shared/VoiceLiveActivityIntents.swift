import AppIntents

/// The Lock Screen / Dynamic Island mute button. A `LiveActivityIntent` runs in the app's process,
/// next to the call. `isDiscoverable = false`: meaningless without a running call.
struct ToggleBackgroundMuteIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Mute Codename Jo"
    static var description = IntentDescription(
        "Mute or unmute your microphone without leaving the call."
    )
    /// The whole point is that this never leaves the Lock Screen.
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        // Awaited: the system stops this process once `perform` returns, and the card's async
        // ActivityKit write would otherwise be lost, leaving "Mute" over a muted mic.
        await VoiceRemoteControl.shared.toggleMute()
        return .result()
    }
}

/// Hang up: end the call and dismiss the Live Activity.
struct EndBackgroundVoiceSessionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "End Codename Jo Call"
    static var description = IntentDescription(
        "Hang up the Codename Jo call and dismiss its Live Activity."
    )
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        // Awaited: ending tears down the audio session that keeps this process alive, and the
        // system keeps it running only while `perform` awaits.
        await VoiceRemoteControl.shared.endSession()
        return .result()
    }
}
