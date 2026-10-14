import Foundation

/// The seam between a Live Activity button and the running session: a closure installed from
/// `AppDelegate` at launch, since the extension can't see `RealtimeService`.
@MainActor
final class VoiceRemoteControl {
    static let shared = VoiceRemoteControl()
    private init() {}

    /// Toggle the microphone; the call stays up. Async so the card's ActivityKit write lands before
    /// the intent's `perform` returns.
    var onToggleMute: (@MainActor () async -> Void)?
    /// End the call and dismiss the Live Activity. Async so the End intent can await the dismissal
    /// before the process becomes suspendable.
    var onEndSession: (@MainActor () async -> Void)?

    func toggleMute() async { await onToggleMute?() }
    func endSession() async { await onEndSession?() }
}
