import Foundation

struct MailSelection: Equatable, Hashable, Sendable {
    let account: String
    let messageID: String

    init(account: String, messageID: String) {
        self.account = account.lowercased()
        self.messageID = messageID
    }

    var canonical: String {
        GmailReadTools.json(["account": account.lowercased(), "message_id": messageID])
    }

    func matches(account: String, messageID: String) -> Bool {
        self.account.caseInsensitiveCompare(account) == .orderedSame && self.messageID == messageID
    }
}

struct RenderedFeedState: Equatable, Sendable {
    var profileID: String?
    var conversationID: UUID?
    var focus: MailSelection?
    var queueCurrent: MailSelection?
    var queueOrder: [String] = []
    var queueRevision = 0
    var queueScope = ""
    var response = ""
    var previousResponse = false
    var focusMode = false
    var responseItemID: String?
    var responseTurnID: String?
    var position: Int?
    var total: Int?
    var jobStates: [String] = []
    var rawFocus: MailSelection?
    var transitioning = false
    var displayBranch = "current"
    var feedActionError: String?
    var sidebarSource = "session"
    var sessionPhase = "active"
    var activityID: UUID?
    var readerSelection: MailSelection?
    var readerState = "unknown"

    func diagnosticFields(session: VoiceDiagnostics.Session, revision: Int) -> [String: String] {
        var fields = ["render_revision": String(revision), "queue_revision": String(queueRevision),
            "queue_scope": queueScope, "observation_phase": "layout_applied", "window_id": "workspace",
            "profile_hash": session.target(profileID ?? "default"), "response_hash": session.target(response),
            "response_role": previousResponse ? "previous" : "current", "focus_mode": String(focusMode),
            "visible_count": String(queueOrder.count), "mismatch": String(activityID == nil && (transitioning || focus != queueCurrent)),
            "selection_state": activityID != nil ? "activity" : transitioning || focus != queueCurrent ? "transitioning" : focus == nil ? "none" : "ready",
            "display_branch": displayBranch, "raw_focus_state": rawFocus == nil ? "none" : "selected",
            "response_item_id": responseItemID ?? "unknown", "turn_id": responseTurnID ?? "unknown",
            "queue_order": queueOrder.map { session.target($0) }.joined(separator: ","),
            "job_states": jobStates.prefix(12).joined(separator: ",")]
        fields["action_error_visible"] = String(feedActionError != nil)
        fields["reader_state"] = readerState
        fields["reader_target_hash"] = readerSelection.map { session.target($0.canonical) } ?? "none"
        fields["actions_available"] = String(focus.map { permits($0, profileID: profileID) } ?? false)
        fields["clear_reason"] = activityID != nil ? "activity_selected" : transitioning ? "selection_transition"
            : focus == nil ? "no_email_selection" : "none"
        if let activityID { fields["activity_id"] = activityID.uuidString }
        fields["sidebar_source"] = sidebarSource
        fields["session_phase"] = sessionPhase
        fields["handoff_reason"] = sessionPhase == "starting" ? "awaiting_coherent_selection" : "none"
        fields["action_error_hash"] = feedActionError.map { session.target($0) } ?? "none"
        if let focus { fields["target_hash"] = session.target(focus.canonical) }
        if let rawFocus { fields["raw_target_hash"] = session.target(rawFocus.canonical) }
        if let queueCurrent { fields["queue_target_hash"] = session.target(queueCurrent.canonical) }
        if let position { fields["displayed_position"] = String(position) }
        if let total { fields["displayed_total"] = String(total) }
        return fields
    }

    func permits(_ selection: MailSelection, profileID: String?) -> Bool {
        activityID == nil && !transitioning && self.profileID == profileID && focus?.matches(account: selection.account, messageID: selection.messageID) == true
            && queueCurrent?.matches(account: selection.account, messageID: selection.messageID) == true
    }
}

/// Captured by the button's rendered view, before a session or queue can change.
struct FeedActionContext: Equatable, Sendable {
    let selection: MailSelection
    let profileID: String?
    let conversationID: UUID?
    let queueRevision: Int
    let queueScope: String

    init?(_ rendered: RenderedFeedState) {
        guard let selection = rendered.focus,
              rendered.permits(selection, profileID: rendered.profileID) else { return nil }
        self.selection = selection
        self.profileID = rendered.profileID
        self.conversationID = rendered.conversationID
        queueRevision = rendered.queueRevision
        queueScope = rendered.queueScope
    }
}
