import Foundation

/// Ends a local turn after a window of silence once the words stop changing; the transcriber reports no end of utterance.
/// Transcript revisions restart the window; an empty transcript never completes.
struct LocalTurnPolicy {
    static let silence: Duration = .milliseconds(900)

    private(set) var text = ""
    private(set) var changedAt: ContinuousClock.Instant?

    mutating func observe(_ heard: String, at now: ContinuousClock.Instant) {
        let trimmed = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != text else { return }
        text = trimmed
        changedAt = trimmed.isEmpty ? nil : now
    }

    func isComplete(at now: ContinuousClock.Instant) -> Bool {
        guard !text.isEmpty, let changedAt else { return false }
        return now - changedAt >= Self.silence
    }

    mutating func reset() {
        text = ""
        changedAt = nil
    }
}
