import Foundation

/// Keeps dictated reply content separate from a question about its destination.
struct LiveReplyComposition {
    let id = UUID()
    var source: DispatchJob.MailOrigin
    var selection: String
    var request: String
    var turn: Int
    var revision = 1
    var clarification: String?
    var targetConfirmed = false
    var followups: [String] = []
    var writeCall: String?
    var recoveredBody: String?
    var recoveryJobID: UUID?
    var candidateSelections: [String] = []
    var needsSourceSelection = false

    static func sameSource(_ lhs: DispatchJob.MailOrigin?, _ rhs: DispatchJob.MailOrigin) -> Bool {
        lhs?.account.lowercased() == rhs.account.lowercased() && lhs?.threadID == rhs.threadID && lhs?.messageID == rhs.messageID
    }

    mutating func recover(_ job: DispatchJob) {
        guard job.mailAction?.replyPreflight == true, job.mailAction?.state == .failed,
              Self.sameSource(job.origin, source) else { return }
        recoveredBody = job.mailAction?.body
        recoveryJobID = job.id
        writeCall = nil
        targetConfirmed = false
        clarification = "The complete reply is saved. Open this Activity's original email with Work on this email, then explicitly retry the reply. Never substitute the current feed item."
        revision += 1
    }

    static func requestsRetry(_ text: String) -> Bool {
        let words = FullDuplexVoiceClient.normalize(text)
        return words.range(of: #"\b(?:retry|try again|send (?:it|that|the reply)|reply again)\b"#, options: .regularExpression) != nil
            && words.range(of: #"\b(?:don t|do not|not|never|cancel|whether|should|if)\b"#, options: .regularExpression) == nil
    }

    var active: Bool { clarification != nil }
    var holdsDecision: Bool { active && writeCall == nil }

    static func requestsReply(_ text: String) -> Bool {
        text.range(of: #"\b(?:reply|respond|write (?:back|a reply)|draft (?:a |the )?(?:reply|response))\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil && !LiveRequestRecovery.incompleteAction(text)
    }

    static func cancels(_ text: String) -> Bool {
        text.range(of: #"\b(?:cancel (?:that|this|the reply)|forget (?:it|that|the reply)|start over|don.t (?:send|reply)|do not (?:send|reply))\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func namesPriorSource(_ request: String) -> Bool {
        request.range(of: #"\breply to (?:the )?(?!(?:this|that|current|selected)\b).+? (?:email|message|thread)\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func namedSources(_ request: String, recent: [String]) -> [String] {
        let words = " " + FullDuplexVoiceClient.normalize(request) + " "
        return recent.filter { state in
            guard let source = DispatchJob.MailOrigin.captured(in: state) else { return false }
            let title = FullDuplexVoiceClient.normalize(source.subject)
                .replacingOccurrences(of: #"^(?:re|fwd|fw)\s+"#, with: "", options: .regularExpression)
            guard title.count >= 4, words.contains(" " + title + " ") else { return false }
            let namedAccounts = recent.compactMap { DispatchJob.MailOrigin.captured(in: $0)?.account }
                .filter { request.lowercased().contains($0.lowercased()) }
            return namedAccounts.isEmpty || namedAccounts.contains(source.account)
        }
    }

    mutating func question(_ text: String) {
        guard writeCall == nil, !targetConfirmed, text.contains("?"), text.range(
            of: #"\b(?:(?:which|what) (?:email|message|recipient|person)|(?:do you|did you) mean|(?:is|was) (?:this|that) (?:the|who)|who (?:did you|do you|should))\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil else { return }
        clarification = text
        targetConfirmed = false
    }

    mutating func user(_ text: String, turn: Int, selection: String) {
        if self.turn == turn, !active { request = text; revision += 1; return }
        guard active else { return }
        if followups.last != text { followups.append(text); revision += 1 }
        let words = FullDuplexVoiceClient.normalize(text)
        if words.range(of: #"\b(?:instead|different|other|not that|not this)\b"#, options: .regularExpression) != nil {
            targetConfirmed = false
            self.turn = turn
            return
        }
        if needsSourceSelection, Self.confirmsTarget(text) || Self.requestsRetry(text),
           let selected = DispatchJob.MailOrigin.captured(in: selection) {
            self.source = selected
            self.selection = selection
            needsSourceSelection = false
        }
        if candidateSelections.count > 1, Self.confirmsTarget(text) || Self.requestsRetry(text),
           let selected = DispatchJob.MailOrigin.captured(in: selection),
           candidateSelections.contains(where: { Self.sameSource(DispatchJob.MailOrigin.captured(in: $0), selected) }) {
            self.source = selected
            self.selection = selection
            candidateSelections = []
        }
        if Self.confirmsTarget(text) || ((recoveryJobID != nil || recoveredBody != nil) && Self.requestsRetry(text)) { targetConfirmed = Self.sameSource(DispatchJob.MailOrigin.captured(in: selection), source) }
        self.turn = turn
    }

    static func confirmsTarget(_ text: String) -> Bool {
        let words = FullDuplexVoiceClient.normalize(text)
        return words.range(of: #"\b(?:that s (?:the|this) one|that is (?:the|this) one|yes (?:that|this)|(?:this|that) (?:is correct|one)|the selected (?:email|message))\b"#,
                           options: .regularExpression) != nil || ["yes", "correct", "exactly"].contains(words)
    }

    var context: [String: Any] {
        ["composition_id": id.uuidString, "revision": revision, "original_request": request,
         "original_source": needsSourceSelection ? "" : selection, "source_unresolved": needsSourceSelection, "target_question": clarification ?? "", "target_confirmed": targetConfirmed,
         "clarifications": followups, "write_call": writeCall ?? "",
         "preserved_body": recoveredBody ?? "", "candidate_sources": candidateSelections, "recovery_activity_id": recoveryJobID?.uuidString ?? "",
         "rule": "Preserve this complete dictated reply and its supplied details. A target clarification resolves only the destination; it does not discard the body or request another email summary/disposition. Continue the original reply under the existing send/draft policy after confirmation. Apply explicit content corrections without losing earlier details. Never substitute the newly selected email. A recorded write call may be pending or uncertain: inspect its receipt and never send again merely because the user clarified the target."]
    }

    func refusal(name: String, arguments: String, selection: String) -> String? {
        guard active, ["send_email", "reply_email", "create_draft", "forward_email"].contains(ToolNarration.canonical(name)) else { return nil }
        if needsSourceSelection { return "Which exact email should receive the preserved reply? Select it and explicitly retry; the current feed item is not assumed to be its target." }
        if candidateSelections.count > 1 { return "Which account’s email should receive the preserved reply? Select that exact email and explicitly retry; do not choose by subject alone." }
        if writeCall != nil { return "This composition already has a write attempt. Inspect its receipt; do not send or draft it again." }
        guard targetConfirmed, Self.sameSource(DispatchJob.MailOrigin.captured(in: selection), source) else {
            return "The reply text is preserved, but its original email target still needs confirmation. Do not send to the newly selected email."
        }
        let args = ToolArguments(arguments)
        guard args.string("account")?.lowercased() == source.account.lowercased(),
              args.string("thread_id") == source.threadID || args.string("message_id") == source.messageID else {
            return "Use this preserved reply's original account and thread/message. The clarification did not authorize another destination."
        }
        if let message = args.string("reply_message_id"), message != source.messageID {
            return "Use the original reply message, not another member of its thread."
        }
        if name == "forward_email" { return "The preserved request is a reply, not a forward." }
        return nil
    }
}
