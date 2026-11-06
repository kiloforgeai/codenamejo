import Foundation

@MainActor
final class ActivitySourceRecovery {
    private var claimed = Set<String>()

    static func source(job: DispatchJob?, arguments: String, original: MailSelection?,
                       beganOnActivity: UUID?, selectedActivity: UUID, profile: String?, accounts: [String]) -> DispatchJob.MailOrigin? {
        guard let job, job.id == selectedActivity, !job.isRunning, job.hasStopped(), job.profileId == profile,
              let source = job.origin, !source.messageID.isEmpty, !source.threadID.isEmpty,
              accounts.contains(where: { $0.caseInsensitiveCompare(source.account) == .orderedSame }),
              beganOnActivity == selectedActivity || original == job.sourceSelection else { return nil }
        let args = ToolArguments(arguments)
        if let account = args.string("account"), account.caseInsensitiveCompare(source.account) != .orderedSame { return nil }
        if let message = args.string("message_id"), message != source.messageID { return nil }
        if let thread = args.string("thread_id"), thread != source.threadID { return nil }
        if let data = arguments.data(using: .utf8), let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ids = raw["message_ids"] as? [String], ids.contains(where: { $0 != source.messageID }) { return nil }
        return source
    }

    func run(callID: String, source: MailSelection, profile: String?, conversation: UUID?,
             current: () -> Bool, validate: () async throws -> Void, restore: () async -> String?,
             rendered: () -> RenderedFeedState?, perform: () -> Void, attempts: Int = 40) async -> String? {
        guard claimed.insert(callID).inserted else { return "This request was already handled. Check its recorded outcome before retrying." }
        guard current() else { return "The request or profile changed. Select the intended email and ask again." }
        do { try await validate() }
        catch { return "The original email is unavailable. Nothing was executed. Select an accessible source email before retrying." }
        guard current(), !Task.isCancelled else { return "The request changed before its source could be restored. Nothing was executed." }
        if let error = await restore() { return error }
        for _ in 0..<attempts {
            guard current(), !Task.isCancelled else { return "The request changed during source restoration. Nothing was executed." }
            if let state = rendered(), state.conversationID == conversation,
               state.permits(source, profileID: profile) {
                perform()
                return nil
            }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return "Source restoration was cancelled. Nothing was executed." }
        }
        return "The original email has not appeared yet. Use Work on this email in the activity, then repeat your request. Nothing was executed."
    }
}
