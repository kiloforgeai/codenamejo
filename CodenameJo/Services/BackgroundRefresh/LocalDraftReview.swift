import FactoryKit
import Foundation

enum LocalDraftReview {
    static let notice = "Review and edit this draft, then choose Save to Gmail. It is currently saved only in Jo; nothing has been sent and the source email was kept."

    static func result(_ job: DispatchJob) -> FullDuplexBroker.ToolResult {
        .init(text: notice + " The preview is open in the center pane. Do not advance the feed or claim the draft was saved in Gmail.",
              ok: true, performedTool: "create_draft", localDraftID: job.id)
    }

    @MainActor static func stage(action original: MailActionReceipt, message: MailMIME.Outgoing,
                                originalRaw: String? = nil, owner: String, profile: String?, conversation: String?,
                                origin: DispatchJob.MailOrigin?, archiveAfterSave: Bool,
                                attachmentAccounts: [String]) async throws -> FullDuplexBroker.ToolResult {
        var action = original
        action.state = .review
        action.archiveState = nil
        var visible = message
        visible.body = action.body; visible.footer = false
        let review = MailDraftReview(message: visible, originalRaw: originalRaw, archiveAfterSave: archiveAfterSave,
            attachmentAccounts: attachmentAccounts, membershipRevision: ProfileRuntime.snapshot?.membershipRevision)
        let (job, _) = try await Container.shared.dispatchJobs().beginMailAction(action, ownerID: owner,
            profileID: profile, conversationID: conversation, origin: origin, draftReview: review)
        return job.mailAction?.state == .review ? result(job) : MailActionAudit.replay(job)
    }

    @MainActor static func save(_ id: UUID, revision: Int, subject: String, body: String) async throws -> DispatchJob {
        let store = Container.shared.dispatchJobs()
        guard let initial = store.existing(id), let preview = initial.draftReview else {
            throw GmailReadTools.Refusal(text: "This local draft is no longer available in the current profile.")
        }
        try validate(initial, preview)
        let job = try await store.editDraftReview(id, revision: revision, subject: subject, body: body, saving: true)
        guard let review = job.draftReview, let action = job.mailAction else { throw CancellationError() }
        do {
            let token = try await GmailReadTools.token(action.account)
            await GmailQuota.shared.spend(10)
            try validate(job, review)
            let warning = try await MailActionAudit.write(job, receipt: "Draft saved in Gmail. Nothing was sent.", validate: {
                try Task.checkCancellation()
                try await validate(job, review)
            }) {
                try await LocalCompose.saveDraft(token, raw: review.raw, threadId: action.threadID, spendQuota: false)
            }
            // Provider confirmation precedes any standing-rule filing of the original thread.
            let effects = GmailManageTools.Effects()
            if review.archiveAfterSave {
                try validate(job, review)
                await LocalCompose.fileByRule(token, account: action.account, threadId: action.threadID, effects)
                await store.recordMailArchive(id, state: effects.list.contains { $0.removeLabelIds?.contains("INBOX") == true }
                    ? "confirmed" : "unconfirmed")
                await LocalCompose.applyEffects(effects.list)
            }
            await MailActionAudit.update(job, result: "Draft saved in Gmail. Nothing was sent." + warning
                + (review.archiveAfterSave ? (effects.list.isEmpty ? " The source archive was not confirmed." : " The source was archived.") : ""))
        } catch {
            if store.mailAction(id)?.mailAction?.state == .pending {
                await store.recordMailAction(id, state: .failed, result: "Draft not saved: " + GmailManageTools.detail(error))
            } else if store.mailAction(id)?.mailAction?.confirmed == true {
                await store.recordMailArchive(id, state: "unconfirmed")
                await MailActionAudit.update(job, result: "Draft saved in Gmail. The source archive was not confirmed after the account or profile changed.")
            }
            await store.reconcileDraftParent(id)
            throw error
        }
        await store.reconcileDraftParent(id)
        return store.mailAction(id) ?? job
    }

    @MainActor private static func validate(_ job: DispatchJob, _ review: MailDraftReview) throws {
        let accounts = ProfileRuntime.allowedMailAccounts(GoogleAccountStore.mailAccounts()).map { $0.lowercased() }
        guard job.userId == Container.shared.backend().userId, job.profileId == ProfileRuntime.snapshot?.profileId,
              review.membershipRevision == ProfileRuntime.snapshot?.membershipRevision,
              let account = job.mailAction?.account, accounts.contains(account.lowercased()),
              review.attachmentAccounts.allSatisfy({ accounts.contains($0.lowercased()) }),
              review.message.attachments?.isEmpty != false || (!MailHeadersOnly.withholdsBodies && ProfileRuntime.snapshot?.mailHeadersOnly != true) else {
            throw GmailReadTools.Refusal(text: "The draft’s account, profile or attachment access changed. Restore that access before saving this draft.")
        }
    }
}
