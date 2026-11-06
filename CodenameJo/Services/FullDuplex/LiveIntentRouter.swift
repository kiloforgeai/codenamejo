import Foundation
import FoundationModels

/// Experiment: Apple's on-device model as a fallback for `LiveFastAction.parse`, so phrasings
/// the fixed list misses ("get rid of this", "toss it") can still take the fast path.
@Generable
enum LiveSpokenIntent: String {
    case archive, spam, trash, next, other
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
    archive: they want the current email archived, filed away, gotten rid of, tossed, or cleared.
    spam: they say the current email is spam or junk.
    trash: they explicitly say delete or trash. "Get rid of" and "toss" mean archive, not trash.
    next: they want to skip the current email or move on to the next one without acting on it.
    other: anything else. That includes replies, drafts, questions, small talk, thanks, statements, a negated instruction ("don't archive it"), \
    a question about something already done, and any instruction about a meeting, a different email, a person, a calendar, or the call itself.
    When unsure, choose other.
    """

    private static var prewarmed = false
    private static var availability = ModelAvailabilityCache()

    private static var diagnostics: VoiceDiagnostics.Session?

    static func beginSession(diagnostics: VoiceDiagnostics.Session? = nil) {
        self.diagnostics = diagnostics
        availability.invalidate()
        prewarmed = false
    }

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
            return has(["get rid", "toss", "archive"]) ? .archive : nil
        case .archive:
            return has(["archive", "get rid", "toss", "file it", "file this", "file that", "clear it", "clear this"]) ? .archive : nil
        case .spam:
            return has(["spam", "junk"]) ? .spam : nil
        case .next:
            return has(["skip", "next", "move on", "move along", "pass"]) ? .next : nil
        }
    }

    static var isAvailable: Bool {
        availability.read(now: ProcessInfo.processInfo.systemUptime, onChange: { available in
            diagnostics?.record(.modelAvailability, ["available": String(available), "engine": "foundation_models",
                "reason": available ? "local_router_ready" : "local_router_unavailable"])
        }) {
            let available: Bool
            if case .available = SystemLanguageModel.default.availability { available = true }
            else { available = false }
            if !available { prewarmed = false }
            return available
        }
    }

    static func prewarm() {
        guard isAvailable, !prewarmed else { return }
        prewarmed = true
        LanguageModelSession(instructions: instructions).prewarm()
    }

    static func classify(_ text: String) async -> LiveFastAction? {
        guard isAvailable, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        let start = ContinuousClock.now
        let intent: LiveSpokenIntent
        do {
            intent = try await session.respond(to: text, generating: LiveSpokenRoute.self,
                options: GenerationOptions(sampling: .greedy)).content.intent
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return nil }
            prewarmed = false
            if availability.suppress(now: ProcessInfo.processInfo.systemUptime) {
                diagnostics?.record(.modelAvailability, VoiceDiagnostics.failure(error).merging([
                    "available": "false", "engine": "foundation_models", "reason": "routing_failed_retry_after_cooldown"
                ]) { _, new in new })
            }
            return nil
        }
        let elapsed = start.duration(to: .now).components
        let ms = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
        RealtimeLog.log("fmRouter: \(intent.rawValue) in \(ms) ms")
        switch intent {
        case .archive: return .archive
        case .spam: return .spam
        case .trash: return .trash
        case .next: return .next
        case .other: return nil
        }
    }
}
