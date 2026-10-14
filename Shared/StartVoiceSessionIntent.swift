import AppIntents

/// Single-press entry point (Action Button, Shortcuts, Siri, controls). Must be in both targets: a
/// control only opens its app then, and `perform()` runs in the app. A custom URL scheme can't.
struct StartVoiceSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Voice Command"
    static var description = IntentDescription(
        "Open Codename Jo and immediately start listening for a voice command."
    )

    // The Realtime session needs the mic and the foreground app process, so we
    // always launch the app rather than running silently in the background.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        VoiceSessionLauncher.shared.requestLaunch(source: "control")
        return .result()
    }
}
