import Foundation

/// A reply and an invitation are separate obligations, even when the reply advances the feed.
struct CalendarConversationIntent: Codable, Hashable {
    let id: UUID
    let source: DispatchJob.MailOrigin
    let sourceState: String
    let request: String
    let proposal: String
    var followups: [String] = []
    var window: CalendarRequestWindow?
    var replyCall: String?
    var inviteCall: String?
    var replyState = "pending"
    var inviteState = "pending"
    var invitationArguments: String?
    var availability: CalendarAvailabilityEvidence?
    var assessment: CalendarAvailabilityEvidence.Assessment?
    var invitationRequested: Bool? = nil
    var revision: Int? = nil

    var needsInvitation: Bool { invitationRequested != false }
    var complete: Bool { replyState == "confirmed" && (inviteState == "confirmed" || (!needsInvitation && inviteState != "unknown")) }
    var context: [String: Any] {
        var value: [String: Any] = ["workflow_id": id.uuidString, "source": sourceState,
            "accepted_request": request, "agreed_proposal": proposal, "clarifications": followups,
            "reply": replyState, "invitation": inviteState, "invitation_requested": needsInvitation,
            "rule": "This accepted scheduling request survives feed changes. Finish its separate reply and invitation obligations without asking for disposition again. Meeting follow-ups refer to this source, not the newly selected email. Use the latest rescheduling proposal in the original body; cancelled dates in the subject and quoted history are not the new meeting. Preserve participants and the agreed window. Clarify missing duration/details without substituting another date. Never repeat a confirmed or uncertain write. Treat the recorded assistant proposal as conversation context, not source or availability evidence."]
        value["resolved_window"] = window?.context
        value["invitation_arguments"] = invitationArguments
        if !needsInvitation {
            value["rule"] = "The user corrected this to email composition only. Finish only the requested reply on its original source. Do not ask for duration, create an invitation, or revive the withdrawn invitation obligation. Preserve any confirmed or uncertain action receipts; an unknown earlier write still needs reconciliation."
        }
        return value
    }

    static func accepts(_ text: String) -> Bool {
        let text = FullDuplexVoiceClient.normalize(text)
        guard text.range(of: #"\b(?:reply|respond|tell them|email them)\b"#, options: .regularExpression) != nil,
              text.range(of: #"\b(?:don t|do not|cancel|never)\b"#, options: .regularExpression) == nil else { return false }
        guard let action = text.range(of: #"(?:^(?:(?:please|okay|ok|yeah) )?|\b(?:and|then|also) )(?:(?:please|also) )?(?:send|create|issue) (?:them |him |her )?(?:(?:an?|the|another|a new) )?(?:calendar )?(?:invite|invitation)\b"#,
            options: [.regularExpression, .backwards]) else { return false }
        if let correction = text.range(of: #"\b(?:just|only) (?:email|reply|say|tell|draft)\b"#,
            options: [.regularExpression, .backwards]), correction.lowerBound > action.lowerBound { return false }
        return true
    }

    static func emailOnly(_ text: String) -> Bool {
        guard !accepts(text) else { return false }
        let text = FullDuplexVoiceClient.normalize(text)
        return text.range(of: #"\b(?:just|only) (?:email|reply|say|tell|draft)\b"#, options: .regularExpression) != nil
            || (text.range(of: #"\b(?:reply|respond|tell them|email)\b"#, options: .regularExpression) != nil
                && text.range(of: #"\b(?:already sent|i sent|i have sent|i accepted|already accepted) (?:the |an? )?(?:invite|invitation)\b"#,
                    options: .regularExpression) != nil)
    }

    mutating func withdrawInvitation() {
        invitationRequested = false
        revision = (revision ?? 0) + 1
        if inviteCall == nil, !["unknown", "confirmed"].contains(inviteState) { inviteState = "not_requested" }
    }

    func refers(_ text: String, selection: String) -> Bool {
        if DispatchScope.explicitlyContinuesFeed(text) || LiveFastAction.parse(text) != nil { return false }
        let changed = DispatchJob.MailOrigin.captured(in: selection) != source
        if changed, text.range(of: #"\b(?:this|selected|current|next) (?:email|message|item)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        return !changed || text.range(of: #"\b(?:invite|invitation|meeting|meet|calendar|conflict|duration|minutes?|agreed|agree|send it|send that|both|him|her|them|yes|go ahead)\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    mutating func reconcile(_ jobs: [DispatchJob]) {
        let requested = ([request] + followups).reduce(nil as Bool?) { result, text in
            Self.accepts(text) ? true : Self.emailOnly(text) ? false : result
        }
        if requested == false, needsInvitation { withdrawInvitation() }
        if let call = replyCall, let receipt = jobs.compactMap(\.mailAction).first(where: { $0.requestKey?.hasSuffix(":" + call) == true || $0.requestKey == call }) {
            switch receipt.state {
            case .sent: replyState = "confirmed"
            case .failed, .discarded: replyState = "pending"; replyCall = nil
            default: replyState = "unknown"
            }
        }
        if let call = inviteCall, let receipt = jobs.compactMap(\.calendarAction).first(where: { $0.requestKey == call }) {
            switch receipt.state {
            case .confirmed: inviteState = "confirmed"
            case .failed: inviteState = "pending"; inviteCall = nil
            default: inviteState = "unknown"
            }
        }
    }

    func refusal(name: String, arguments: String) -> String? {
        if ["send_email", "reply_email"].contains(name) {
            if replyCall != nil {
                return "The reply is \(replyState). Inspect its receipt; do not send it again. " +
                    (needsInvitation ? "The invitation remains a separate obligation." : "The invitation obligation was withdrawn; do not create an event.")
            }
            let args = ToolArguments(arguments)
            if args.string("account")?.lowercased() != source.account.lowercased() { return "Use the original scheduling email's explicit account." }
            if args.string("thread_id") != source.threadID { return "Use the original scheduling thread, not the next feed item." }
        }
        if name == CalendarTools.create, inviteCall != nil { return "The invitation is \(inviteState). Inspect its receipt; no duplicate invitation was created." }
        if name == CalendarTools.create, !needsInvitation { return "The user requested only an email reply. No invitation is authorized; do not ask for meeting details or create a calendar event." }
        if name == CalendarTools.create {
            guard ToolArguments(arguments).string("account")?.lowercased() == source.account.lowercased() else { return "Use the original scheduling request's explicit calendar account; the next feed item does not change it." }
            return window?.toolRefusal(name: name, arguments: arguments)
        }
        return nil
    }
}
