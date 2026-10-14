import AppIntents
import Foundation

/// Single-press entry point for an offline note (Action Button, Shortcuts, Siri, controls). In both
/// targets for the reason on `StartVoiceSessionIntent`; the voice-notes gate is applied in the app.
struct StartMemoIntent: AppIntent {
    static var title: LocalizedStringResource = "Leave a Note"
    static var description = IntentDescription(
        "Open Codename Jo and start recording a note — transcribed on your phone and sent as a task when there's a connection."
    )

    // The recording readout lives in the foreground app; a silent background recording would be an
    // open mic nobody can see.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        VoiceSessionLauncher.shared.requestMemo()
        return .result()
    }
}

/// The Home Screen widget's route: WidgetKit runs `Button(intent:)` in the extension without
/// opening the app, so the widget opens `aurex://memo` via `widgetURL` instead.
enum MemoDeepLink {
    /// On the `aurex` scheme the app already registers; the host distinguishes it.
    static let url = URL(string: "aurex://memo")!

    static func matches(_ url: URL) -> Bool {
        url.scheme == "aurex" && url.host == "memo"
    }
}
