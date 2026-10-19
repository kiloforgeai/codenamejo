import Foundation
import FoundationModels

/// Experiment: Apple's on-device model as a fallback for `LiveFastAction.parse`, so phrasings
/// the fixed list misses ("get rid of this", "toss it") can still take the fast path.
@Generable
enum LiveSpokenIntent: String {
    case spam, trash, next, other
}

@Generable
struct LiveSpokenRoute {
    @Guide(description: "The action the user is telling the app to perform on the current email right now, or other.")
    var intent: LiveSpokenIntent
}

@MainActor
enum LiveIntentRouter {
    private static let instructions = """
    You classify one spoken utterance from someone going through their email inbox by voice, one email at a time.
    spam: they say the current email is spam or junk.
    trash: they explicitly say delete or trash. Archive, file away, get rid of, toss and clear mean other.
    next: they want to skip the current email or move on to the next one without acting on it.
    other: anything else. That includes replies, drafts, questions, small talk, thanks, statements, a negated instruction ("don't archive it"), \
    a question about something already done, and any instruction about a meeting, a different email, a person, a calendar, or the call itself.
    When unsure, choose other.
    """

    private static var prewarmed = false

    /// The model only proposes. The user's own words must name the action, so an answer to
    /// Jo's question ("yeah, go ahead", "same thing") or a stray fragment never acts on mail.
    nonisolated static func permitted(_ action: LiveFastAction, for text: String) -> LiveFastAction? {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" })
            .map { $0.replacingOccurrences(of: "’", with: "'") }
        // One word is a piece of a longer sentence; the exact list already takes "next" and "skip".
        guard words.count >= 2 else { return nil }
        let said = " " + words.joined(separator: " ") + " "
        func has(_ phrases: [String]) -> Bool { phrases.contains { said.contains(" \($0) ") } }
        // Negations, and sender-wide asks a single-email action would get wrong, belong to the brain.
        if has(["don't", "dont", "do not", "never", "all", "every", "everything", "them", "those", "rest", "unsubscribe"]) {
            return nil
        }
        switch action {
        case .trash:
            if has(["delete", "trash"]) { return .trash }
            return nil
        case .spam:
            return has(["spam", "junk"]) ? .spam : nil
        case .next:
            return has(["skip", "next", "move on", "move along", "pass"]) ? .next : nil
        }
    }

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func prewarm() {
        guard !prewarmed, isAvailable else { return }
        prewarmed = true
        LanguageModelSession(instructions: instructions).prewarm()
    }

    static func classify(_ text: String) async -> LiveFastAction? {
        guard isAvailable, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        let start = ContinuousClock.now
        let intent = try? await session.respond(to: text, generating: LiveSpokenRoute.self,
                                                options: GenerationOptions(sampling: .greedy)).content.intent
        let elapsed = start.duration(to: .now).components
        let ms = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
        RealtimeLog.log("fmRouter: '\(text)' → \(intent?.rawValue ?? "error") in \(ms) ms")
        switch intent {
        case .spam: return .spam
        case .trash: return .trash
        case .next: return .next
        case .other?, nil: return nil
        }
    }
}
