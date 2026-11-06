import Combine
import FactoryKit
import Foundation

enum FeedbackSource: String, Sendable { case voice, button }
enum FeedbackPersistence: String, Sendable { case draft, saved, cancelled }

struct FeedbackContext: Sendable {
    var sessionID: UUID?
    var conversationID: UUID?
    var profileID: String?
    var engine = "idle"
    var state = "ready"
    var renderRevision: Int? = nil
    var turnID: String? = nil
    var fragmentTurnIDs: [String]? = nil
    var renderContextReason: String? = nil
}

/// Retain the last observed in-call render, not the idle screen's unrelated revision.
struct RecentFeedbackContext {
    let context: FeedbackContext
    let userID: String?
    let observedAt: Date

    func afterSession(userID: String?, profileID: String?, now: Date = Date()) -> FeedbackContext? {
        guard let userID, userID == self.userID, context.profileID == profileID,
              context.conversationID != nil, context.sessionID != nil, context.renderRevision != nil,
              now.timeIntervalSince(observedAt) >= 0, now.timeIntervalSince(observedAt) <= 15 * 60 else { return nil }
        var recent = context
        recent.renderContextReason = "recent_conversation_render"
        return recent
    }
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
    static let savedAcknowledgment = "Feedback saved locally."

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
        var noteID: UUID? = nil
        var revision = 0
        var persistence: FeedbackPersistence = .saved
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
        var revision = 0
        var prompted = false
        var completionTurnID: String?
        var text: String { turns.map(\.text).joined(separator: "\n") }
    }
    private var voiceDraft: VoiceDraft?
    private var voiceSaveTask: Task<Void, Never>?
    private var handledVoiceTurns: [String] = []
    private var savedVoiceNote: (id: UUID, draft: VoiceDraft)?
    private var savingVoiceNote: VoiceDraft?

    var pendingVoiceText: String? {
        guard let draft = voiceDraft, sameOwner(draft.submission, capture()) else { return nil }
        return draft.text
    }

    func takeVoiceDraft() -> String? {
        takeVoiceDraftSubmission()?.text
    }

    func takeVoiceDraftSubmission() -> (text: String, submission: Submission)? {
        guard var draft = voiceDraft, sameOwner(draft.submission, capture()) else { return nil }
        voiceSaveTask?.cancel()
        voiceDraft = nil
        draft.revision += 1
        handledVoiceTurns = Array((handledVoiceTurns + [draft.requestTurnID] + draft.turns.map(\.id)).suffix(128))
        return (draft.text, draftSubmission(draft, persistence: .saved))
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
        if VoiceFeedbackText.retry(text), voiceDraft == nil {
            if let savingVoiceNote, sameOwner(savingVoiceNote.submission, submission) {
                reply("Your feedback is still being saved. I don't have a save receipt yet.")
                return true
            }
            if let savedVoiceNote, sameOwner(savedVoiceNote.draft.submission, submission) {
                settled([turnID], savedVoiceNote.id, .success)
                transition("already_saved")
                reply(FeedbackText.savedAcknowledgment)
                return true
            }
            reply("I don't have a saved feedback receipt or a retained note for this profile. Please tell me the feedback again.")
            transition("missing_draft")
            return true
        }
        var amendment = false
        if handledVoiceTurns.contains(turnID) {
            // A later final ASR transcript may replace a fragment after explicit completion.
            // Amend the same durable note instead of silently discarding it or creating a duplicate.
            guard voiceDraft == nil, let saved = savedVoiceNote,
                  sameOwner(saved.draft.submission, submission),
                  let previous = saved.draft.turns.first(where: { $0.id == turnID }),
                  previous.text != (request ?? text), !VoiceFeedbackText.resume(text) else { return true }
            voiceDraft = saved.draft
            amendment = true
        }
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
            var draft = voiceDraft!
            draft.revision += 1
            voiceDraft = nil
            handledVoiceTurns = Array((handledVoiceTurns + [draft.requestTurnID] + draft.turns.map(\.id)).suffix(128))
            transition("cancelled")
            settled(Array(Set([draft.requestTurnID, turnID] + draft.turns.map(\.id))).sorted(), nil, .cancelled)
            if !draft.text.isEmpty {
                Task { [weak self] in
                    guard let self else { return }
                    do { _ = try await save(draft.text, source: .voice, submission: draftSubmission(draft, persistence: .cancelled)) }
                    catch {
                        if voiceDraft == nil { voiceDraft = draft }
                        guard sameOwner(draft.submission, capture()) else { return }
                        reply("The feedback draft could not be cancelled. It is kept; use the Feedback button to review it.")
                        return
                    }
                    if sameOwner(draft.submission, capture()) { reply("Feedback cancelled.") }
                }
            } else { reply("Feedback cancelled.") }
            return true
        }
        let note = request ?? text
        if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            transition("pending")
            reply("What would you like the feedback to say?")
            return true
        }
        let resume = VoiceFeedbackText.resume(text) || amendment
        if (!resume || amendment) && !LiveRequestRecovery.isBackchannel(note) {
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
        voiceDraft?.revision += 1
        if resume, !amendment { voiceDraft?.completionTurnID = turnID }
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
            savingVoiceNote = draft
            do {
                let record = draftSubmission(draft, persistence: resume ? .saved : .draft)
                let id = try await save(draft.text, source: .voice, submission: record)
                if savingVoiceNote?.revision == draft.revision { savingVoiceNote = nil }
                // A slow write cannot acknowledge an obsolete fragment or clear a newer note.
                guard voiceDraft?.id == draft.id, voiceDraft?.revision == draft.revision else { return }
                guard sameOwner(draft.submission, capture()) else { return }
                if resume {
                    voiceDraft = nil
                    savedVoiceNote = (id, draft)
                    let ids = record.context.fragmentTurnIDs ?? []
                    handledVoiceTurns = Array((handledVoiceTurns + ids).suffix(128))
                    settled(ids, id, .success)
                    transition(amendment ? "amended" : "saved")
                    voiceReceipt = "Feedback saved"
                    if !amendment { reply(FeedbackText.savedAcknowledgment) }
                } else {
                    transition("draft_saved")
                    voiceReceipt = "Feedback draft saved · say “save it” when finished"
                    if !draft.prompted {
                        voiceDraft?.prompted = true
                        reply("Your feedback draft is saved. Keep going, or say save it when you're done.")
                    }
                }
            } catch {
                if savingVoiceNote?.revision == draft.revision { savingVoiceNote = nil }
                guard voiceDraft?.id == draft.id, voiceDraft?.revision == draft.revision else { return }
                settled(Array(Set([draft.requestTurnID, turnID] + draft.turns.map(\.id))).sorted(), nil, .failed)
                transition("failed")
                guard sameOwner(draft.submission, capture()) else { return }
                reply("Feedback was not saved. Your draft is kept; use the Feedback button or ask to try again.")
            }
        }
        return true
    }

    private func draftSubmission(_ draft: VoiceDraft, persistence: FeedbackPersistence) -> Submission {
        var context = draft.submission.context
        context.turnID = draft.turns.first?.id
        context.fragmentTurnIDs = Array(Set([draft.requestTurnID] + draft.turns.map(\.id)
            + [draft.completionTurnID].compactMap { $0 })).sorted()
        return .init(userID: draft.submission.userID, context: context, noteID: draft.id,
                     revision: draft.revision, persistence: persistence)
    }

    func capture() -> Submission { Submission(userID: backend.userId, context: realtime.feedbackContext) }

    func save(_ message: String, source: FeedbackSource, submission: Submission) async throws -> UUID {
        guard let userID = submission.userID else { throw FeedbackError.signedOut }
        guard userID == backend.userId else { throw FeedbackError.accountChanged }
        guard submission.context.profileID == realtime.feedbackContext.profileID else { throw FeedbackError.accountChanged }
        return try await diagnostics.saveFeedback(message, source: source, userID: userID, context: submission.context,
            id: submission.noteID ?? UUID(), revision: submission.revision, persistence: submission.persistence)
    }
}

enum VoiceFeedbackText {
    static func request(_ text: String) -> String? {
        if retry(text) { return nil }
        if text.range(of: #"(?is)^\s*(?:so[,\s]+)?(?:the|my) feedback is\b"#, options: .regularExpression) != nil { return text }
        let pattern = #"(?is)^\s*(?:(?:hey(?: jo)?|yeah|yes|okay|ok|please|just|uh|um)[\s,.!]+)*(?:(?:can you |could you )?stop for (?:one|a) second[\s,.!?]+)?(?:(?:can (?:you|i)|could (?:you|i)|may i|i want to|i wanna|i'd like to|i would like to)\s+)?(?:file|log|record|save|submit|give)\s+(?:you\s+)?(?:(?:some|this|my|the)\s+)?feedback\b[\s:,.!?\-]*(.*)$"#
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
        if retry(text) { return true }
        let words = SpokenAnswerText.words(text).filter { !["yeah", "yes", "okay", "ok", "uh", "um"].contains($0) }.joined(separator: " ")
        return ["let s go through the feed", "go through the feed", "continue the feed", "resume the feed", "save it", "that s it", "try again"].contains(words)
    }

    static func retry(_ text: String) -> Bool {
        text.range(of: #"(?is)^\s*(?:(?:okay|ok|yeah|please)[\s,.]+)*(?:(?:can|could|would) you\s+)?(?:try (?:to )?(?:save|log|record) (?:the |that |my |this )?feedback(?: again)?|(?:save|log|record) (?:the |that |my |this )?feedback again)[\s.!?]*$"#,
            options: .regularExpression) != nil
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
                + "Say exactly: \(FeedbackText.savedAcknowledgment) Do not paraphrase or interpret the feedback, infer a preference, or read the reference aloud. Nothing was uploaded and no issue was filed. "
                + "Keep the current task selected; this does not advance the feed.", false)
        } catch {
            return ("Feedback was NOT saved: \(error.localizedDescription)", true)
        }
    }
}
