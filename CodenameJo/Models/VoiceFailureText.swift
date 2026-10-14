import Foundation

/// What a failure is allowed to say on screen: a sentence the user can act on.
/// The raw error stays in `RealtimeLog` and the History row.
enum VoiceFailureText {
    /// A user-facing sentence for a raw transport/broker error. Matched on substrings because the
    /// text arrives from URLSession, the broker, OpenAI's REST bodies and our own throws.
    static func friendly(_ raw: String) -> String {
        let text = raw.lowercased()

        // A local call's failures already say what to do, and the generic line would hide it.
        if text.contains("on-device") || text.contains("fully local") || text.contains("phone's own model") {
            return raw
        }
        if text.contains("offline") || text.contains("internet connection")
            || text.contains("network connection was lost") || text.contains("timed out") {
            return "No connection — tap to try again"
        }
        if text.contains("rate limit") || text.contains("429") {
            return "Busy right now — try again in a moment"
        }
        if text.contains("401") || text.contains("unauthorized") || text.contains("token") {
            return "Couldn't start the call — tap to try again"
        }
        if text.contains("403") || text.contains("forbidden") {
            return "This account can't start a call — check your connections"
        }
        if text.contains("microphone") || text.contains("permission") {
            return "Microphone access is off — turn it on in Settings"
        }
        return "Something went wrong — tap to try again"
    }
}
