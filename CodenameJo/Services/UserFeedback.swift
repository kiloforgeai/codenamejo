import Combine
import FactoryKit
import Foundation

enum FeedbackSource: String, Sendable { case voice, button }

struct FeedbackContext: Sendable {
    var sessionID: UUID?
    var conversationID: UUID?
    var profileID: String?
    var engine = "idle"
    var state = "ready"
    var renderRevision: Int? = nil
    var turnID: String? = nil
    var fragmentTurnIDs: [String]? = nil
}

enum FeedbackError: LocalizedError {
    case empty, tooLong, signedOut, accountChanged, invalidArguments

    var errorDescription: String? {
        switch self {
        case .empty: return "Add a few words about what happened."
        case .tooLong: return "Keep feedback under \(FeedbackText.maximumCharacters + 1) characters."
        case .signedOut: return "Sign in before saving feedback."
        case .accountChanged: return "Your account changed. Close this note and open Feedback again."
        case .invalidArguments: return "Feedback needs a message containing the user's own feedback."
        }
    }
}

enum FeedbackText {
    static let maximumCharacters = 4_000

    static func validated(_ text: String) throws -> String {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw FeedbackError.empty }
        guard message.count <= maximumCharacters else { throw FeedbackError.tooLong }
        return message
    }
}

@MainActor
class UserFeedback: ObservableObject {
    struct Submission {
        let userID: String?
        let context: FeedbackContext
    }

    @Injected(\.backend) private var backend
    @Injected(\.realtimeService) private var realtime
    @Injected(\.voiceDiagnostics) private var diagnostics
    @Published var voiceReceipt: String?
    var voiceSaveDelay: Duration = .seconds(2)
    private struct VoiceDraft {
        let id = UUID()
        let submission: Submission
        let requestTurnID: String
        var turns: [(id: String, text: String)] = []
        var text: String { turns.map(\.text).joined(separator: "\n") }
    }
    private var voiceDraft: VoiceDraft?
    private var voiceSaveTask: Task<Void, Never>?
    private var handledVoiceTurns: [String] = []

    var pendingVoiceText: String? {
        guard let draft = voiceDraft, sameOwner(draft.submission, capture()) else { return nil }
        return draft.text
    }

    func takeVoiceDraft() -> String? {
        guard let text = pendingVoiceText else { return nil }
        voiceSaveTask?.cancel()
        voiceDraft = nil
        return text
    }

    private func sameOwner(_ a: Submission, _ b: Submission) -> Bool {
        a.userID == b.userID && a.context.profileID == b.context.profileID
    }

    /// Solicited notes stay local and survive pauses without depending on the mail brain.
    func voiceInput(_ text: String, turnID: String, reply: @escaping (String) -> Void,
                    transition: @escaping (String) -> Void,
                    settled: @escaping ([String], UUID?, CommandRecord.CommandStatus) -> Void = { _, _, _ in }) -> Bool {
        let captured = capture()
        var context = captured.context
        context.turnID = turnID
        let submission = Submission(userID: captured.userID, context: context)
        let request = VoiceFeedbackText.request(text)
        if handledVoiceTurns.contains(turnID) { return true }
        guard request != nil || voiceDraft != nil else { return false }
        if let draft = voiceDraft, !sameOwner(draft.submission, submission) {
            voiceSaveTask?.cancel()
            transition("scope_changed")
            if request != nil { reply("Your earlier feedback belongs to another profile. Switch back to finish it, or use the Feedback button for a new note.") }
            return request != nil
        }
        voiceSaveTask?.cancel()
        voiceReceipt = nil
        if voiceDraft == nil {
            voiceDraft = VoiceDraft(submission: submission, requestTurnID: turnID)
            transition("requested")
        }
        if VoiceFeedbackText.cancel(text) {
            let draft = voiceDraft!
            voiceDraft = nil
            handledVoiceTurns = Array((handledVoiceTurns + [draft.requestTurnID] + draft.turns.map(\.id)).suffix(128))
            transition("cancelled")
            settled(Array(Set([draft.requestTurnID, turnID] + draft.turns.map(\.id))).sorted(), nil, .cancelled)
            reply("Feedback cancelled. Nothing was saved.")
            return true
        }
        let note = request ?? text
        if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            transition("pending")
            reply("What would you like the feedback to say?")
            return true
        }
        let resume = VoiceFeedbackText.resume(text)
        if !resume && !LiveRequestRecovery.isBackchannel(note) {
            var draft = voiceDraft!
            if let index = draft.turns.firstIndex(where: { $0.id == turnID }) { draft.turns[index].text = note }
            else { draft.turns.append((turnID, note)) }
            guard draft.text.count <= FeedbackText.maximumCharacters else {
                transition("failed")
                reply("That feedback is too long. Your earlier draft is kept; use the Feedback button to shorten it.")
                return true
            }
            voiceDraft = draft
        }
        guard let draft = voiceDraft, !draft.text.isEmpty else {
            reply("I don't have a feedback note to save yet. Tell me what happened, or say cancel feedback.")
            return true
        }
        transition("pending")
        let delay: Duration = resume ? .zero : voiceSaveDelay
        voiceSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled, voiceDraft?.id == draft.id else { return }
            guard sameOwner(draft.submission, capture()) else { transition("scope_changed"); return }
            // Freeze this note before the asynchronous disk write; a later request is a new note.
            voiceDraft = nil
            handledVoiceTurns = Array((handledVoiceTurns + [draft.requestTurnID] + draft.turns.map(\.id)).suffix(128))
            do {
                let ids = Array(Set([draft.requestTurnID, turnID] + draft.turns.map(\.id))).sorted()
                var context = draft.submission.context
                context.fragmentTurnIDs = ids
                let id = try await save(draft.text, source: .voice, submission: .init(userID: draft.submission.userID, context: context))
                settled(ids, id, .success)
                transition("saved")
                guard sameOwner(draft.submission, capture()) else { return }
                voiceReceipt = "Feedback saved"
                reply("Feedback saved locally. Your current email is unchanged.")
            } catch {
                if voiceDraft == nil { voiceDraft = draft }
                settled(Array(Set([draft.requestTurnID, turnID] + draft.turns.map(\.id))).sorted(), nil, .failed)
                transition("failed")
                guard sameOwner(draft.submission, capture()) else { return }
                reply("Feedback was not saved. Your draft is kept; use the Feedback button or ask to try again.")
            }
        }
        return true
    }

    func capture() -> Submission { Submission(userID: backend.userId, context: realtime.feedbackContext) }

    func save(_ message: String, source: FeedbackSource, submission: Submission) async throws -> UUID {
        guard let userID = submission.userID else { throw FeedbackError.signedOut }
        guard userID == backend.userId else { throw FeedbackError.accountChanged }
        guard submission.context.profileID == realtime.feedbackContext.profileID else { throw FeedbackError.accountChanged }
        return try await diagnostics.saveFeedback(message, source: source, userID: userID, context: submission.context)
    }
}

enum VoiceFeedbackText {
    static func request(_ text: String) -> String? {
        let pattern = #"(?is)^\s*(?:(?:yeah|yes|okay|ok|please|just|uh|um)[\s,.]+)*(?:(?:can you|could you|i want to|i'd like to)\s+)?(?:file|log|record|save|submit|give)\s+(?:(?:some|this|my)\s+)?feedback\b[\s:,.!\-]*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func cancel(_ text: String) -> Bool {
        ["cancel feedback", "cancel the feedback", "never mind", "nevermind", "don't save that", "do not save that"]
            .contains(text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: .punctuationCharacters))
    }

    static func resume(_ text: String) -> Bool {
        let words = SpokenAnswerText.words(text).filter { !["yeah", "yes", "okay", "ok", "uh", "um"].contains($0) }.joined(separator: " ")
        return ["let s go through the feed", "go through the feed", "continue the feed", "resume the feed", "save it", "that s it", "try again"].contains(words)
    }
}

enum UserFeedbackTool {
    static let name = "log_feedback"

    @MainActor
    static func run(argumentsJSON: String, save: (String) async throws -> UUID) async -> (output: String, failed: Bool) {
        do {
            let object = try JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))
            guard let args = object as? [String: Any], let message = args["message"] as? String else {
                throw FeedbackError.invalidArguments
            }
            let id = try await save(FeedbackText.validated(message))
            return ("Feedback saved locally in Jo's logs. Reference: \(id.uuidString). "
                + "Acknowledge briefly; do not read the reference aloud. Nothing was uploaded and no issue was filed. "
                + "Keep the current task selected; this does not advance the feed.", false)
        } catch {
            return ("Feedback was NOT saved: \(error.localizedDescription)", true)
        }
    }
}
