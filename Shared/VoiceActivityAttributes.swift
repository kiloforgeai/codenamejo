import ActivityKit
import Foundation

/// What the Live Activity draws; compiled into both targets, so it imports only ActivityKit and
/// Foundation. No transcript: the Lock Screen is a public surface.
struct VoiceActivityAttributes: ActivityAttributes {
    /// Which of the four things a live call can be doing; coarser than `SessionState` because a
    /// glance surface needs only states the user can act on.
    enum Phase: String, Codable, Hashable {
        /// The call is being dialled, or has dropped and is being redialled.
        case connecting
        /// The call is up and the microphone is open: the resting state of a hands-free call.
        case listening
        /// The model is working — reasoning, or running a tool.
        case thinking
        /// The reply is being spoken, in the model's own voice over the call.
        case speaking
    }


    /// The display-only card under the status row; nil when there is nothing to show. The whole
    /// `ContentState` has 4 KB, so strings are cut with `short(_:)` where they are built.
    /// Mail queue only; the meeting, receipt and inbox cards were deleted for #82.
    enum Card: Codable, Hashable {
        /// How far into the mail queue the user is. `total` is the mailbox's full unread count, so
        /// it doesn't move with paging.
        case triage(position: Int, total: Int)

        /// One place for the 4 KB budget. 48 is about what the card's width fits anyway.
        static func short(_ text: String, _ limit: Int = 48) -> String {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count > limit else { return clean }
            return clean.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "\u{2026}"
        }
    }

    struct ContentState: Codable, Hashable {
        var phase: Phase
        /// True when the user has muted themselves; a muted call still shows `.speaking` while the
        /// assistant finishes.
        var isMuted: Bool
        /// The tool now running, e.g. "Searching Gmail". Nil when nothing is.
        var detail: String?
        /// What the visual card draws, or nil for the bare status row.
        var card: Card?

        /// The one-word status the Lock Screen leads with. Muted wins over the
        /// phase, because it is the thing that changes what the user should do.
        var statusLabel: String {
            if isMuted { return "Muted" }
            switch phase {
            case .connecting: return "Connecting"
            case .listening: return "Listening"
            case .thinking: return detail ?? "Thinking"
            case .speaking: return "Speaking"
            }
        }

        /// What the mute button will do — the action, not the state.
        var muteLabel: String { isMuted ? "Unmute" : "Mute" }

        var muteSymbol: String { isMuted ? "mic.slash.fill" : "mic.fill" }
    }

    /// When the call was dialled; static for the life of the activity. What `ElapsedTime` counts
    /// from.
    var startedAt: Date
}
