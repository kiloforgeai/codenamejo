import Foundation

/// Keeps dictated reply content separate from a question about its destination.
struct LiveReplyComposition {
    let id = UUID()
    let source: DispatchJob.MailOrigin
    let selection: String
    var request: String
    var turn: Int
    var revision = 1
    var clarification: String?
    var targetConfirmed = false
    var followups: [String] = []
    var writeCall: String?

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
        if Self.confirmsTarget(text) { targetConfirmed = DispatchJob.MailOrigin.captured(in: selection) == source }
        self.turn = turn
    }

    static func confirmsTarget(_ text: String) -> Bool {
        let words = FullDuplexVoiceClient.normalize(text)
        return words.range(of: #"\b(?:that s (?:the|this) one|that is (?:the|this) one|yes (?:that|this)|(?:this|that) (?:is correct|one)|the selected (?:email|message))\b"#,
                           options: .regularExpression) != nil || ["yes", "correct", "exactly"].contains(words)
    }

    var context: [String: Any] {
        ["composition_id": id.uuidString, "revision": revision, "original_request": request,
         "original_source": selection, "target_question": clarification ?? "", "target_confirmed": targetConfirmed,
         "clarifications": followups, "write_call": writeCall ?? "",
         "rule": "Preserve this complete dictated reply and its supplied details. A target clarification resolves only the destination; it does not discard the body or request another email summary/disposition. Continue the original reply under the existing send/draft policy after confirmation. Apply explicit content corrections without losing earlier details. Never substitute the newly selected email. A recorded write call may be pending or uncertain: inspect its receipt and never send again merely because the user clarified the target."]
    }

    func refusal(name: String, arguments: String, selection: String) -> String? {
        guard active, ["send_email", "reply_email", "create_draft", "forward_email"].contains(ToolNarration.canonical(name)) else { return nil }
        if writeCall != nil { return "This composition already has a write attempt. Inspect its receipt; do not send or draft it again." }
        guard targetConfirmed, DispatchJob.MailOrigin.captured(in: selection) == source else {
            return "The reply text is preserved, but its original email target still needs confirmation. Do not send to the newly selected email."
        }
        let args = ToolArguments(arguments)
        guard args.string("account")?.lowercased() == source.account.lowercased(),
              args.string("thread_id") == source.threadID || args.string("message_id") == source.messageID else {
            return "Use this preserved reply's original account and thread/message. The clarification did not authorize another destination."
        }
        if name == "forward_email" { return "The preserved request is a reply, not a forward." }
        return nil
    }
}
