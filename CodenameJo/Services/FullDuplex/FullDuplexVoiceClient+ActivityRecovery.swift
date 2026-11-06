import FactoryKit
import Foundation

extension FullDuplexVoiceClient {
    func recoverActivitySource(_ call: LiveSessionAdapter.Call) -> Bool {
        #if targetEnvironment(macCatalyst)
        let realtime = Container.shared.realtimeService()
        guard LiveWriteTarget.mailWrites.contains(ToolNarration.canonical(call.name)),
              let activity = realtime.renderedWorkspace?.activityID else { return false }
        guard activityRecoveryCalls.insert(call.id).inserted else { return true }
        guard let profile = ProfileRuntime.snapshot?.profileId else {
            refuseLiveFunction(call, reason: "activity_profile_unavailable", output: "Not executed: select the original profile and email before retrying.")
            return true
        }
        let dial = dialGeneration, turn = liveUserTurn
        let owner = Container.shared.backend().userId, conversation = realtime.activeConversationId
        let original = (liveQueueActionAnchor?.step ?? standingStep).flatMap(LiveEmailPresentation.Key.selection)
            .map { MailSelection(account: $0.account, messageID: $0.messageId) }
        let beganOnActivity = liveActivitySourceID
        Task { [weak self] in
            guard let self else { return }
            let accounts = await localTriage.resultSelectionAccounts()
            guard let source = ActivitySourceRecovery.source(job: dispatchJobs.existing(activity), arguments: call.arguments,
                original: original, beganOnActivity: beganOnActivity, selectedActivity: activity, profile: profile, accounts: accounts) else {
                refuseLiveFunction(call, reason: "activity_source_unavailable", output:
                    "Not executed: this activity does not identify the email from your request in the current account. Select the intended email using Work on this email, then ask again.")
                return
            }
            let selection = MailSelection(account: source.account, messageID: source.messageID)
            let error = await activitySourceRecovery.run(callID: call.id, source: selection, profile: profile, conversation: conversation,
                current: {
                    self.isActive && self.dialGeneration == dial && self.liveUserTurn == turn
                        && ProfileRuntime.snapshot?.profileId == profile && Container.shared.backend().userId == owner
                        && self.transport?.liveAdapter?.canRestoreReturnedWork(call.id) == true
                        && (Container.shared.applicationTasks().selectedTaskID == nil || Container.shared.applicationTasks().selectedTaskID == activity)
                }, validate: {
                    let token = try await GmailReadTools.token(source.account)
                    await GmailQuota.shared.spend(5)
                    let message = try await GmailAPI.call("GET", path: "messages/" + source.messageID,
                        query: ["format": "minimal"], token: token)
                    guard message["id"] as? String == source.messageID, message["threadId"] as? String == source.threadID else {
                        throw GmailReadTools.Refusal(text: "The original message is unavailable.")
                    }
                }, restore: {
                    if let error = await self.selectReturnedResult(activity, localActionID: call.id) { return error }
                    Container.shared.applicationTasks().select(nil)
                    return nil
                }, rendered: { realtime.renderedWorkspace }, perform: {
                    self.liveAnchors[call.delegation] = self.liveQueueRevision
                    self.liveUnheardDelegations.remove(call.delegation)
                    self.liveQueueActionAnchor = self.standingStep.map { .init(step: $0, profileId: profile, revision: self.liveQueueRevision) }
                    var recovered = call
                    recovered.recoveryAnchor = self.liveQueueActionAnchor
                    self.runLiveFunction(recovered)
                })
            if let error { refuseLiveFunction(call, reason: "activity_source_recovery_refused", output: "Not executed: " + error) }
        }
        return true
        #else
        return false
        #endif
    }
}
