import AVFoundation
import Foundation

/// The full-duplex call's fixed audio settings.
///
/// These were Settings controls while the barge-in gate was being measured — duck gain,
/// turn detection, noise reduction, the voice and more, persisted and synced to the
/// account. The measurement settled the defaults, so what the call still reads is a
/// constant here and the rest is gone (#86).
enum FullDuplexTuning {

    /// `.voiceChat` vs `.videoChat`: both route through Apple's Voice-Processing
    /// I/O unit and so both get hardware echo cancellation.
    ///
    /// **`.voiceChat`, always.** Automatic proximity routing needs a receiver-capable
    /// default route. Apple's `.videoChat` mode automatically adds `.defaultToSpeaker`,
    /// which means releasing a temporary speaker override still leaves the call on the
    /// loudspeaker. `.voiceChat` stays active for the whole call; the route override
    /// supplies far-field speakerphone output without changing modes and rebuilding the
    /// audio unit every time the phone moves. The other case stays so a measurement can
    /// still flip it in code.
    enum VoiceMode: String {
        case voiceChat, videoChat
        var avMode: AVAudioSession.Mode {
            switch self {
            case .voiceChat: return .voiceChat
            case .videoChat: return .videoChat
            }
        }
    }

    static let voiceMode: VoiceMode = .voiceChat
}

enum FullDuplexConfig {
    /// One-shot flag armed by onboarding's `finish()`: the next hands-free call
    /// asks the session setup for the greeting addendum and opens with the assistant
    /// speaking (a short calendar/inbox brief). Read-and-cleared by
    /// `FullDuplexVoiceClient` at connect — cleared even if that call drops, so
    /// a reconnect never re-greets. Deliberately device-shaped (excluded from
    /// the account profile): it describes a moment on this install, not a
    /// preference.
    static let pendingGreetingKey = "pendingFirstConversationGreeting"
}
