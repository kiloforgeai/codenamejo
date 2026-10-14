import Foundation

/// Live has no playback-completed event. Require the farewell words, audio, then a quiet tail.
struct LiveFarewellPlayback {
    static let instructions = "The application has accepted the request to end this call. "
        + "Say exactly: Goodbye, take care. Then stop speaking. Do not delegate, "
        + "summarize, ask a question, or continue the feed."

    private var transcript = ""
    private var wordsFinishedAt: TimeInterval?
    private var lastAudioAt: TimeInterval?
    private(set) var finished = false

    mutating func appendTranscript(_ delta: String, at now: TimeInterval) {
        guard !finished else { return }
        transcript += delta
        let words = transcript.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
        if wordsFinishedAt == nil, words.contains("goodbye take care") {
            wordsFinishedAt = now
        }
    }

    mutating func observePlayback(_ level: Double, at now: TimeInterval) -> Bool {
        guard !finished else { return false }
        if level > 0.003 { lastAudioAt = now }
        guard let wordsFinishedAt, let lastAudioAt,
              lastAudioAt >= wordsFinishedAt, now - lastAudioAt >= 1.2 else { return false }
        finished = true
        return true
    }
}
