import Foundation

/// One call as a row: when it started, when it ended, and why. Stored in `app_records` with
/// `record_type = "conversation"`, keyed by the conversation's id, with camel-case keys.
struct ConversationRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    /// Nil while the call is live, and forever if the app was killed, so absence alone isn't
    /// evidence of a live call.
    var endedAt: Date?
    /// Why it stopped, in the vocabulary below. Nil while live.
    var endedReason: String?

    /// The build and OS that took the call, read from `AppInfo` at write time. Optional so older
    /// rows still decode.
    var appVersion: String? = AppInfo.shortVersion
    var build: String? = AppInfo.buildNumber
    var osVersion: String? = AppInfo.osVersion

    /// The ways a call can stop. `endedReason` is a raw `String`, like `DispatchJob.state`, so a
    /// reason a newer build wrote survives a rewrite.
    enum Reason {
        /// The End button, the Live Activity's End, or a spoken "end session".
        static let userEnded = "user_ended"
        /// The ten-minute off-screen idle timeout.
        static let backgroundTimeout = "background_timeout"
        /// The transport died under us — a dropped network, a failed renegotiation.
        static let transportFailure = "transport_failure"
        /// The far end hung up, which means OpenAI's 60-minute session cap; the End button never
        /// sees it.
        static let closedByServer = "closed_by_server"
        /// The staff reasoning-effort switch moved mid-call. The switch was retired; older
        /// records still carry this.
        static let promptSwitchChanged = "prompt_switch_changed"
        /// The car went away and there was nowhere else to hold the call; see
        /// `RealtimeService.carPlayDisconnected()`.
        static let carPlayDisconnected = "carplay_disconnected"
        /// The handshake finished but the call never opened: ICE stuck in `.checking`, unlike
        /// `transportFailure`'s `.failed`. See `FullDuplexVoiceClient.armConnectWatchdog`.
        static let dialTimedOut = "dial_timed_out"
    }
}
