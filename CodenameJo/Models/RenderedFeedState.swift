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

    func diagnosticFields(session: VoiceDiagnostics.Session, revision: Int) -> [String: String] {
        var fields = ["render_revision": String(revision), "queue_revision": String(queueRevision),
            "queue_scope": queueScope, "observation_phase": "layout_applied", "window_id": "workspace",
            "profile_hash": session.target(profileID ?? "default"), "response_hash": session.target(response),
            "response_role": previousResponse ? "previous" : "current", "focus_mode": String(focusMode),
            "visible_count": String(queueOrder.count), "mismatch": String(focus != queueCurrent),
            "selection_state": focus != queueCurrent ? "transitioning" : focus == nil ? "none" : "ready",
            "response_item_id": responseItemID ?? "unknown", "turn_id": responseTurnID ?? "unknown",
            "queue_order": queueOrder.map { session.target($0) }.joined(separator: ","),
            "job_states": jobStates.prefix(12).joined(separator: ",")]
        if let focus { fields["target_hash"] = session.target(focus.canonical) }
        if let queueCurrent { fields["queue_target_hash"] = session.target(queueCurrent.canonical) }
        if let position { fields["displayed_position"] = String(position) }
        if let total { fields["displayed_total"] = String(total) }
        return fields
    }

    func permits(_ selection: MailSelection, profileID: String?) -> Bool {
        self.profileID == profileID && focus?.matches(account: selection.account, messageID: selection.messageID) == true
            && queueCurrent?.matches(account: selection.account, messageID: selection.messageID) == true
    }
}

/// Captured by the button's rendered view, before a session or queue can change.
struct FeedActionContext: Equatable, Sendable {
    let selection: MailSelection
    let profileID: String?
    let conversationID: UUID
    let queueRevision: Int
    let queueScope: String

    init?(_ rendered: RenderedFeedState) {
        guard let selection = rendered.focus, let conversationID = rendered.conversationID,
              rendered.permits(selection, profileID: rendered.profileID) else { return nil }
        self.selection = selection
        self.profileID = rendered.profileID
        self.conversationID = conversationID
        queueRevision = rendered.queueRevision
        queueScope = rendered.queueScope
    }
}
