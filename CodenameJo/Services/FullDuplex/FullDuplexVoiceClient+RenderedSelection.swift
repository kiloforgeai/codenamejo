import FactoryKit
import Foundation

extension FullDuplexVoiceClient {
    func renderedSelectionRefusal() -> String? {
        renderedSelectionFailure()?.message
    }

    func renderedSelectionFailure() -> (reason: String, message: String, fields: [String: String])? {
        #if targetEnvironment(macCatalyst)
        let realtime = Container.shared.realtimeService()
        let step = liveQueueActionAnchor?.step ?? standingStep
        let key = step.flatMap(LiveEmailPresentation.Key.selection)
        let rendered = realtime.renderedWorkspace
        let profile = ProfileRuntime.snapshot?.profileId
        let reason = RenderedSelectionGuard.reason(step: step, rendered: rendered, profileID: profile,
            conversationID: realtime.activeConversationId, anchorProfileID: liveQueueActionAnchor?.profileId,
            hasAnchor: liveQueueActionAnchor != nil)
        guard let reason else { return nil }
        if !realtime.isConversing, ["missing_voice_selection", "invalid_voice_selection_key", "missing_render"].contains(reason) { return nil }
        var fields = ["source_present": String(step != nil), "source_key_valid": String(key != nil),
            "action_anchor_present": String(liveQueueActionAnchor != nil), "parse_reason": key == nil ? reason : "valid"]
        if let diagnostics {
            fields.merge(rendered?.diagnosticFields(session: diagnostics, revision: realtime.renderedRevision) ?? [:], uniquingKeysWith: { _, new in new })
            fields["profile_hash"] = diagnostics.target(profile ?? "default")
            fields["conversation_hash"] = diagnostics.target(realtime.activeConversationId?.uuidString ?? "none")
            if let key { fields["voice_target_hash"] = diagnostics.target(MailSelection(account: key.account, messageID: key.messageId).canonical) }
            if let step = liveQueueActionAnchor?.step, let anchor = LiveEmailPresentation.Key.selection(step) {
                fields["action_anchor_hash"] = diagnostics.target(MailSelection(account: anchor.account, messageID: anchor.messageId).canonical)
            }
        }
        return (reason, "Not executed: the current email selection is not ready or no longer matches this request. Select the intended email before retrying. Do not retry this write unchanged or advance the feed.", fields)
        #endif
        return nil
    }
}

enum RenderedSelectionGuard {
    static func reason(step: String?, rendered: RenderedFeedState?, profileID: String?, conversationID: UUID?,
                       anchorProfileID: String?, hasAnchor: Bool) -> String? {
        guard let step else { return "missing_voice_selection" }
        guard let key = LiveEmailPresentation.Key.selection(step) else { return "invalid_voice_selection_key" }
        if hasAnchor, anchorProfileID != profileID { return "profile_changed" }
        guard let rendered else { return "missing_render" }
        if rendered.conversationID != conversationID { return "conversation_changed" }
        if rendered.profileID != profileID { return "render_profile_changed" }
        if rendered.transitioning { return "selection_transitioning" }
        if rendered.focus == nil || rendered.queueCurrent == nil { return "missing_rendered_selection" }
        return rendered.permits(.init(account: key.account, messageID: key.messageId), profileID: profileID) ? nil : "target_mismatch"
    }
}
