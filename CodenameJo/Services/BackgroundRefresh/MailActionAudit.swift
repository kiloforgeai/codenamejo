import FactoryKit
import Foundation

enum MailActionAudit {
    struct Failure: Error { let text: String }

    static func replay(_ job: DispatchJob) -> FullDuplexBroker.ToolResult {
        if job.mailAction?.state == .review { return LocalDraftReview.result(job) }
        let action = job.mailAction
        return .init(text: (job.result ?? "This action is already recorded.") + " No duplicate write was attempted.",
            ok: action?.confirmed == true ? true : false,
            deferred: action?.state == .pending || action?.state == .queued, performedTool: action?.tool,
            outcomeUnknown: action?.state == .unknown)
    }

    static func write(_ job: DispatchJob, receipt: String,
                      validate: @Sendable () async throws -> Void = {},
                      request: () async throws -> [String: Any]) async throws -> String {
        guard let action = job.mailAction else { throw Failure(text: "Nothing was sent; the action receipt is missing.") }
        let store = await MainActor.run { Container.shared.dispatchJobs() }
        do {
            let owner = await MainActor.run { Container.shared.backend().userId }
            guard owner == job.userId, ProfileRuntime.snapshot?.profileId == job.profileId else {
                throw GmailReadTools.Refusal(text: "Nothing was sent or saved. The active user or profile changed.")
            }
            try await validate()
        }
        catch {
            await store.recordMailAction(job.id, state: .failed, result: GmailManageTools.detail(error))
            throw error
        }
        let provider: [String: Any]
        do {
            provider = try await request()
            guard let id = provider["id"] as? String, !id.isEmpty else {
                throw Failure(text: "Gmail returned no confirmation ID. The outcome is unknown; check Gmail before trying again.")
            }
        } catch {
            let state = MailActionReceipt.failureState(error, attempted: true)
            let text = state == .unknown
                ? "Gmail did not confirm this \(action.kind.isDraft ? "draft" : "send"). Its outcome is unknown. Check Gmail before trying again; Jo will not repeat it automatically."
                : "Gmail refused this \(action.kind.isDraft ? "draft" : "send"): \(GmailManageTools.detail(error))."
            await store.recordMailAction(job.id, state: state, result: text)
            if state == .unknown { throw Failure(text: text) }
            throw error
        }
        let saved = await store.recordMailAction(job.id, state: action.kind.isDraft ? .draft : .sent,
                                                result: receipt, provider: provider)
        return saved ? "" : " Gmail confirmed the action, but its local history could not be saved. Do not repeat it."
    }

    @MainActor static func update(_ job: DispatchJob, result: String) async {
        guard let kind = job.mailAction?.kind else { return }
        await Container.shared.dispatchJobs().recordMailAction(job.id, state: kind.isDraft ? .draft : .sent, result: result)
    }

    @MainActor static func result(_ job: DispatchJob, fallback: String) -> String {
        Container.shared.dispatchJobs().mailAction(job.id)?.result ?? fallback
    }
}
