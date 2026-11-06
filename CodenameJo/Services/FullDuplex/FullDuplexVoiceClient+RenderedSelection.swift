import FactoryKit
import Foundation

extension FullDuplexVoiceClient {
    func renderedSelectionRefusal() -> String? {
        #if targetEnvironment(macCatalyst)
        let realtime = Container.shared.realtimeService()
        guard let step = liveQueueActionAnchor?.step ?? standingStep,
              let key = LiveEmailPresentation.Key.step(step) else {
            return realtime.isConversing ? "Not executed: no current email is selected. Select the intended email before acting; do not infer a target from an earlier response." : nil
        }
        if let anchor = liveQueueActionAnchor, anchor.profileId != ProfileRuntime.snapshot?.profileId {
            return "Not executed: this request belongs to a different profile. Select the intended email in the current profile before acting."
        }
        guard let rendered = realtime.renderedWorkspace else {
            return realtime.isConversing ? "Not executed: the workspace has not displayed this selection yet. Wait for the current email to appear before acting." : nil
        }
        guard rendered.conversationID == realtime.activeConversationId,
              rendered.permits(.init(account: key.account, messageID: key.messageId), profileID: ProfileRuntime.snapshot?.profileId) else {
            return "Not executed: the displayed email and conversation selection are not synchronized. "
                + "Select the original email from its returned work card before retrying. Confirming a sender or subject alone cannot restore a selection. Do not retry this write unchanged or advance the feed."
        }
        #endif
        return nil
    }
}
