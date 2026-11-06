import Foundation
import FactoryKit
import Combine

extension DispatchJobStore {
    func beginCalendarAction(_ action: CalendarActionReceipt, ownerID: String, profileID: String?,
                             conversationID: String?, origin: DispatchJob.MailOrigin?) async throws -> (DispatchJob, Bool) {
        guard backend.userId == ownerID, ProfileRuntime.snapshot?.profileId == profileID else {
            throw CalendarTools.Refusal(text: "No calendar change: the active account or profile changed.")
        }
        if let existing = jobs.first(where: { job in
            guard job.userId == ownerID, job.profileId == profileID, let prior = job.calendarAction else { return false }
            return (action.requestKey != nil && prior.requestKey == action.requestKey)
                || ([.pending, .unknown].contains(prior.state) && prior.fingerprint == action.fingerprint)
        }) { return (existing, false) }
        let job = DispatchJob(id: UUID(), task: action.activityTitle, state: "running",
            result: "Waiting for Google Calendar to confirm this action.", startedAt: Date(), deliveredAt: Date(),
            profileId: profileID, reportBack: false, userId: ownerID,
            conversationId: conversationID.flatMap(UUID.init(uuidString:)), origin: origin, calendarAction: action)
        jobs.append(job)
        guard await save() else {
            throw CalendarTools.Refusal(text: "No calendar change: its action receipt could not be saved.")
        }
        return (job, true)
    }

    @discardableResult
    func recordCalendarAction(_ id: UUID, action: CalendarActionReceipt, result: String) async -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }), let prior = jobs[index].calendarAction else { return false }
        if prior.confirmed && !action.confirmed { return true }
        jobs[index].calendarAction = action
        jobs[index].state = action.confirmed ? "done" : action.state == .pending ? "running" : action.state.rawValue
        jobs[index].result = result
        if action.state != .pending, prior.state != action.state || jobs[index].completedAt == nil { jobs[index].completedAt = Date() }
        jobs[index].receipts = [.init(callId: action.requestKey ?? id.uuidString, tool: action.tool,
            outcome: action.confirmed ? "success" : action.state.rawValue)]
        return await save()
    }

    func recordCalendarArchive(parentID: UUID? = nil, conversationID: String? = nil,
                               account: String? = nil, messageID: String? = nil, state: String) async {
        var changed = false
        for index in jobs.indices {
            guard let action = jobs[index].calendarAction, action.confirmed,
                  jobs[index].userId == backend.userId else { continue }
            let parentMatches = parentID != nil && action.parentJobID == parentID
            let sourceMatches = conversationID != nil && jobs[index].conversationId?.uuidString == conversationID
                && account != nil && jobs[index].origin?.account == account?.lowercased()
                && messageID != nil && jobs[index].origin?.messageID == messageID
            guard parentMatches || sourceMatches else { continue }
            jobs[index].calendarAction?.archiveState = state
            changed = true
        }
        if changed { await save() }
    }
}


/// The dispatch log, kept on the phone: `DispatchWorker` writes each job's row, and the next call
/// reads back answers nobody heard and marks them delivered.
/// Not `final`: `PreviewDispatchJobStore` overrides `history()` and `recover()` to serve fixtures.
@MainActor
class DispatchJobStore: ObservableObject {
    @Published var persistenceError: String?
    @Published var changes = 0
    @Injected(\.backend) private var backend
    private let persistence = DispatchQueue(label: "jo.dispatch-jobs.persistence", qos: .utility)
    private let url: URL
    private var jobs: [DispatchJob]

    init(url: URL = DispatchJobStore.defaultURL) {
        self.url = url
        jobs = (try? Data(contentsOf: url)).flatMap {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode([DispatchJob].self, from: $0)
        } ?? []
        for index in jobs.indices where jobs[index].mailAction?.state == .pending {
            jobs[index].mailAction?.state = .unknown
            jobs[index].state = "unknown"
            jobs[index].result = "The app closed before Gmail's response was saved. Check Gmail before trying again; this action will not be repeated automatically."
        }
        for index in jobs.indices where jobs[index].calendarAction?.state == .pending {
            jobs[index].calendarAction?.state = .unknown
            jobs[index].state = "unknown"
            jobs[index].result = "The app closed before the calendar outcome was saved. Check the event before retrying; Jo will not repeat it automatically."
        }
        for index in jobs.indices where jobs[index].context != nil && jobs[index].isRunning {
            let queued = jobs[index].state == "queued"
            jobs[index].state = queued ? "awaiting_input" : "unknown"
            jobs[index].result = queued ? "The app closed before this task started. Review its source and instructions before resuming."
                : "The app closed while this task was running. Check its receipts and provider state before retrying; its outcome is unknown."
            jobs[index].reportBack = true
        }
        for index in jobs.indices where jobs[index].state == "awaiting_input" && jobs[index].browserState != nil {
            jobs[index].result = jobs[index].browserState == .unsubmitted
                ? "The previous form expired when the app closed. Reopen this task's form, then review it and approve again. Nothing is currently open."
                : "The previous browser is unavailable. Check the site's submission status before any further action; old approvals cannot be reused."
        }
        for index in jobs.indices {
            guard var intent = jobs[index].calendarIntent, jobs[index].state != "cancelled" else { continue }
            let owner = jobs[index].userId, profile = jobs[index].profileId
            intent.reconcile(jobs.filter { $0.userId == owner && $0.profileId == profile })
            jobs[index].calendarIntent = intent
            if !intent.needsInvitation { jobs[index].task = intent.complete ? "Email reply completed" : "Finish email reply" }
            if intent.complete {
                jobs[index].state = "done"
                jobs[index].deliveredAt = jobs[index].deliveredAt ?? Date()
                jobs[index].reportBack = false
                jobs[index].result = "Reply: \(intent.replyState). Invitation: \(intent.inviteState)."
            }
        }
        reconcileMailRetries()
    }

    nonisolated static var defaultURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("dispatch-jobs.json")
    }

    /// The active profile's rows; the default profile also owns rows written before profiles.
    private var visible: [DispatchJob] {
        let owned = jobs.filter { $0.userId == backend.userId }
        guard let scope = ProfileRuntime.snapshot else { return owned.filter { $0.profileId == nil } }
        return owned.filter { $0.profileId == scope.profileId || (scope.isDefault && $0.profileId == nil) }
    }

    /// Every stored row, newest first — the History screen's Dispatch panel reads this. Read-only.
    var decisionDependencies: [DispatchJob] {
        visible.filter { $0.context?.holdsDecision == true && $0.origin != nil && $0.state != "cancelled" }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    var pendingCalendarIntent: CalendarConversationIntent? {
        visible.filter { $0.calendarIntent != nil && $0.state != "cancelled" }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            .compactMap { row in
                var intent = row.calendarIntent!
                intent.reconcile(visible)
                return intent.complete ? nil : intent
            }.first
    }

    func reconciledCalendarIntent(_ intent: CalendarConversationIntent) -> CalendarConversationIntent {
        var value = intent; value.reconcile(visible); return value
    }

    @discardableResult
    func saveCalendarIntent(_ intent: CalendarConversationIntent, ownerID: String?, profileID: String?) async -> Bool {
        guard let owner = ownerID, owner == backend.userId, profileID == ProfileRuntime.snapshot?.profileId else { return false }
        let profile = profileID
        if let index = jobs.firstIndex(where: { $0.id == intent.id }) {
            guard jobs[index].userId == owner, jobs[index].profileId == profile else { return false }
            guard (jobs[index].calendarIntent?.revision ?? 0) <= (intent.revision ?? 0) else { return false }
            jobs[index].calendarIntent = intent
            jobs[index].state = intent.complete ? "done" : "awaiting_input"
            jobs[index].result = "Scheduling reply: \(intent.replyState). Invitation: \(intent.inviteState)."
            if !intent.needsInvitation { jobs[index].task = intent.complete ? "Email reply completed" : "Finish email reply" }
            if intent.complete { jobs[index].deliveredAt = Date(); jobs[index].reportBack = false }
        } else {
            jobs.append(.init(id: intent.id, task: intent.needsInvitation ? "Finish scheduling invitation" : "Finish email reply",
                state: intent.complete ? "done" : "awaiting_input",
                result: "Reply: \(intent.replyState). Invitation: \(intent.inviteState).", startedAt: Date(),
                deliveredAt: intent.complete ? Date() : nil, profileId: profile, reportBack: intent.complete ? false : nil,
                userId: owner, origin: intent.source, calendarIntent: intent))
        }
        return await save()
    }

    func releaseDecisionHold(_ selection: MailSelection) async {
        let ids = Set(decisionDependencies.filter { $0.sourceSelection == selection }.map(\.id))
        guard !ids.isEmpty else { return }
        for index in jobs.indices where ids.contains(jobs[index].id) { jobs[index].context?.decisionReleased = true }
        await save()
    }

    func history() async -> [DispatchJob] {
        visible.sorted {
            ($0.completedAt ?? $0.startedAt ?? .distantPast) > ($1.completedAt ?? $1.startedAt ?? .distantPast)
        }
    }

    func diagnosticHistory(conversations: Set<String>) -> [DispatchJob] {
        jobs.filter { $0.userId == backend.userId && $0.userId != nil
            && $0.conversationId.map { conversations.contains($0.uuidString) } == true }
    }

    /// Every answer that came back with nobody there to hear it, oldest first. Safe only at connect,
    /// before this call has dispatched anything.
    func recover() async -> [DispatchJob] {
        let now = Date()
        await prune(asOf: now)
        let undelivered = visible.filter { $0.deliveredAt == nil }
        for job in undelivered where job.hasStopped(asOf: now) && job.recoveredAnswer(asOf: now) == nil {
            await settle(job.id)
        }
        let recoverable = undelivered.filter { $0.recoveredAnswer(asOf: now) != nil }
            .sorted { ($0.completedAt ?? $0.startedAt ?? .distantPast) < ($1.completedAt ?? $1.startedAt ?? .distantPast) }
        if !recoverable.isEmpty {
            RealtimeLog.log("dispatch: recovered \(recoverable.count) answer(s) from an earlier call")
        }
        return recoverable
    }

    /// The job's answer has reached a conversation. A mark, not a delete, so History keeps the row.
    func settle(_ id: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].deliveredAt == nil else { return }
        jobs[index].deliveredAt = Date()
        await save()
    }

    /// Only the current owner/profile can restore a stopped job's unambiguous source email.
    func selectableResult(_ id: UUID, allowedAccounts: [String]) -> DispatchJob? {
        visible.first { job in
            guard job.id == id, job.hasStopped(), let origin = job.origin else { return false }
            return allowedAccounts.contains { $0.caseInsensitiveCompare(origin.account) == .orderedSame }
        }
    }

    func commandResult(_ id: UUID) -> DispatchJob? {
        visible.first { $0.id == id && $0.command != nil }
    }

    func existing(_ id: UUID) -> DispatchJob? { visible.first { $0.id == id } }

    func resolvedMailCall(_ callID: String, source: DispatchJob.MailOrigin) -> Bool {
        visible.contains { job in
            guard let action = job.mailAction, action.requestKey?.hasSuffix(":" + callID) == true,
                  action.account.lowercased() == source.account.lowercased(),
                  action.replyMessageID == source.messageID else { return false }
            return [.sent, .draft, .review, .discarded, .failed].contains(action.state)
        }
    }
    func contains(_ id: UUID) -> Bool { jobs.contains { $0.id == id } }

    func shouldPresent(_ id: UUID, revision: Int? = nil) -> Bool {
        guard contains(id) else { return true }
        guard let job = existing(id), revision == nil || job.taskRevision == revision else { return false }
        return job.resolution == nil && job.deliveredAt == nil && !(job.isDone && job.effectivePreference == .quiet) && job.state != "cancelled"
    }

    func matches(_ id: UUID, revision: Int?) -> Bool {
        guard let revision else { return true }
        return jobs.first { $0.id == id }?.taskRevision == revision
    }

    func acceptContext(_ id: UUID, context: DispatchJob.TaskContext, preference: DispatchJob.CompletionPreference? = nil) async -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return false }
        jobs[index].context = context
        jobs[index].state = "queued"
        jobs[index].completionPreference = preference
        return await save()
    }

    func setPreference(_ id: UUID, revision: Int, preference: DispatchJob.CompletionPreference) async -> Bool {
        guard matches(id, revision: revision), let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].completionPreference != preference else { return false }
        jobs[index].completionPreference = preference
        if jobs[index].isDone {
            jobs[index].reportBack = preference == .bringBack
            jobs[index].deliveredAt = preference == .quiet ? Date() : nil
        }
        return await save()
    }

    func revise(_ id: UUID, revision: Int, task: String, linkChoice: String? = nil) async -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].taskRevision == revision,
              !jobs[index].isRunning, !jobs[index].hasCommittedWrites,
              jobs[index].state != "unknown", jobs[index].inFlightOperation == nil,
              jobs[index].context != nil else { return false }
        jobs[index].task = task
        jobs[index].context?.revision += 1
        jobs[index].context?.authoredAt = Date()
        jobs[index].context?.linkChoice = linkChoice
        jobs[index].inputChoices = nil
        jobs[index].state = "queued"
        jobs[index].result = nil
        jobs[index].completedAt = nil
        jobs[index].deliveredAt = nil
        return await save()
    }

    func requireChoice(_ id: UUID, revision: Int?, choices: [DispatchJob.InputChoice]) async -> Bool {
        guard matches(id, revision: revision), let index = jobs.firstIndex(where: { $0.id == id }) else { return false }
        jobs[index].inputChoices = choices
        return await save()
    }

    func markOperation(_ id: UUID, revision: Int?, callID: String?) async -> Bool {
        guard matches(id, revision: revision), let index = jobs.firstIndex(where: { $0.id == id }) else { return false }
        jobs[index].inFlightOperation = callID
        return await save()
    }

    func recordBrowserState(_ id: UUID, state: DispatchJob.BrowserState, verifiedInspection: Bool = false) async -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].userId == backend.userId,
              jobs[index].profileId == ProfileRuntime.snapshot?.profileId else { return false }
        if jobs[index].browserState == .confirmed { return true }
        if jobs[index].browserState == .userControlled && state == .unsubmitted && !verifiedInspection { return true }
        jobs[index].browserState = state
        return await save()
    }

    func recordBrowserURL(_ id: UUID, url: URL) async -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].userId == backend.userId,
              jobs[index].profileId == ProfileRuntime.snapshot?.profileId else { return false }
        // Keep the original entry page, not a later submission or tokenized receipt URL.
        if jobs[index].browserURL != nil { return true }
        jobs[index].browserURL = url.absoluteString
        return await save()
    }

    func latestCommandAttempt(from id: UUID) -> DispatchJob? {
        guard var current = commandResult(id) else { return nil }
        var seen: Set<UUID> = [id]
        while true {
            let children = visible.filter { $0.command?.retryOf == current.id }
            guard children.count <= 1 else { return nil }
            guard let next = children.first else { return current }
            guard seen.insert(next.id).inserted, next.origin == current.origin else { return nil }
            current = next
        }
    }

    func jobWithCommittedWrite(_ id: UUID, profileID: String?) -> DispatchJob? {
        jobs.first { $0.id == id && $0.userId == backend.userId && $0.profileId == profileID
            && $0.receipts?.contains(where: { $0.outcome == "success" }) == true }
    }

    func previousOperation(_ operation: DispatchMailOperation, profileID: String?, excluding id: UUID? = nil) -> DispatchJob? {
        jobs.last { $0.id != id && $0.userId == backend.userId && $0.profileId == profileID && $0.operation == operation
            && ($0.isDone || $0.isRunning || $0.state == "unknown") }
    }

    /// A job has started; a retried memo reuses its id and starts its row again.
    func begin(id: UUID, task: String, profileId: String?, conversationId: UUID? = nil, turnId: String? = nil, operation: DispatchMailOperation? = nil, origin: DispatchJob.MailOrigin? = nil, command: DispatchJob.CommandRun? = nil, quickMailAction: DispatchJob.QuickMailAction? = nil) async {
        if let index = jobs.firstIndex(where: { $0.id == id && $0.context != nil }) {
            if jobs[index].state == "queued" { jobs[index].state = "running"; await save() }
            return
        }
        if let index = jobs.firstIndex(where: { $0.id == id && $0.state == "queued" }) {
            jobs[index].state = "running"
            await save()
            return
        }
        jobs.removeAll { $0.id == id }
        let profiles = Container.shared.workspaceProfiles()
        let defaultProfile = profileId == nil || profiles.profiles.first(where: { $0.id == profileId })?.isDefault == true
        let owner = backend.userId.map { $0 + (defaultProfile ? "" : ":profile:" + (profileId ?? "")) }
        jobs.append(DispatchJob(id: id, task: task, state: "running", startedAt: Date(), profileId: profileId,
            userId: backend.userId, conversationId: conversationId, turnId: turnId, historyOwner: owner, operation: operation, origin: origin, command: command, quickMailAction: quickMailAction))
        await save()
        await recordHistoryOutcome(jobs.first { $0.id == id }, status: .pending)
    }

    func setState(_ id: UUID, state: String, revision: Int? = nil) async {
        guard matches(id, revision: revision), let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
        await save()
    }

    func receipt(_ id: UUID, callId: String, tool: String, failed: Bool, targetHash: String? = nil, commandStep: Int? = nil, revision: Int? = nil) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        var receipts = jobs[index].receipts ?? []
        guard !receipts.contains(where: { $0.callId == callId && $0.revision == revision }) else { return }
        receipts.append(.init(callId: callId, tool: tool, outcome: failed ? "failed" : "success", targetHash: targetHash, commandStep: commandStep, revision: revision))
        jobs[index].receipts = receipts
        if ToolNarration.canonical(tool) == "archive_message" {
            await recordCalendarArchive(parentID: id, state: failed ? "unconfirmed — archive failed" : "confirmed")
        }
        await save()
    }

    func completeCommandStep(_ id: UUID, index: Int, result: String, revision: Int? = nil) async {
        guard matches(id, revision: revision), let row = jobs.firstIndex(where: { $0.id == id }), var command = jobs[row].command,
              index == command.completedSteps, index < command.actions.count else { return }
        command.completedSteps += 1
        command.completedResults.append(LiveCompactContext.bounded(result, bytes: 4_000, includeEmailContent: false))
        jobs[row].command = command
        await save()
    }

    func finish(_ id: UUID, state: String, result: String, reportBack: Bool? = nil, historyStatus: CommandRecord.CommandStatus? = nil, foregroundContinuation: Bool? = nil, revision: Int? = nil) async {
        guard matches(id, revision: revision), let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
        jobs[index].foregroundContinuation = foregroundContinuation
        jobs[index].result = result
        jobs[index].completedAt = Date()
        jobs[index].reportBack = reportBack
        if let preference = jobs[index].completionPreference {
            jobs[index].reportBack = state == "done" ? preference == .bringBack : state != "cancelled"
        }
        if state == "done", jobs[index].reportBack == false { jobs[index].deliveredAt = Date() }
        reconcileMailRetries()
        let job = jobs[index]
        await save()
        let status: CommandRecord.CommandStatus = state == "done" ? .success : state == "partial" ? .partial : state == "unknown" ? .unknown : .failed
        await recordHistoryOutcome(job, status: historyStatus ?? status)
    }

    private func recordHistoryOutcome(_ job: DispatchJob?, status: CommandRecord.CommandStatus) async {
        guard let job, let owner = job.historyOwner, let turn = job.turnId else { return }
        do {
            try await TurnStore(database: Container.shared.localContext().dbPool)
                .recordJobOutcome(userID: owner, turnID: turn, jobID: job.id, outcome: status)
            if owner == Container.shared.workspaceProfiles().contextOwner { await Container.shared.commandStore().refresh() }
        } catch { RealtimeLog.log("dispatch: could not reconcile history outcome — \(error.localizedDescription)") }
    }

    private func reconcileMailRetries() {
        let successes = jobs.filter { $0.isDone && $0.inFlightOperation == nil && $0.command == nil
            && $0.receipts?.count == 1 && $0.receipts?.first?.outcome == "success" && $0.reconcilableMailAction != nil }
        for index in jobs.indices {
            let failure = jobs[index]
            guard failure.state == "failed", failure.resolution == nil, failure.command == nil,
                  failure.inFlightOperation == nil, !failure.hasCommittedWrites,
                  let action = failure.reconcilableMailAction, let completed = failure.completedAt,
                  let success = successes.first(where: {
                      $0.id != failure.id && $0.userId != nil && $0.userId == failure.userId
                          && $0.profileId == failure.profileId && $0.sourceSelection == failure.sourceSelection
                          && $0.reconcilableMailAction == action && $0.receipts?.first?.tool == action.tool
                          && ($0.startedAt ?? .distantPast) >= completed
                  }) else { continue }
            jobs[index].resolution = .init(jobID: success.id, at: success.completedAt ?? Date(), reason: "matching_retry_confirmed")
            RealtimeLog.log("task: \(failure.id) resolution=\(success.id) reason=matching_retry_confirmed queue=excluded recovery=excluded")
        }
    }

    func discard(_ id: UUID) async {
        await recordHistoryOutcome(jobs.first { $0.id == id }, status: .failed)
        jobs.removeAll { $0.id == id }
        await save()
    }

    /// Sign-out: the next account inherits nothing.
    func removeAll() {
        jobs = []
        let url = url
        persistence.async {
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } catch { RealtimeLog.log("dispatch: could not remove job log — \(error.localizedDescription)") }
        }
    }

    /// Delivered rows past `DispatchJob.retention`. An undelivered answer is never pruned.
    private func prune(asOf now: Date) async {
        let before = jobs.count
        jobs.removeAll { job in job.mailAction == nil && job.calendarAction == nil && (job.deliveredAt.map { now.timeIntervalSince($0) > DispatchJob.retention } ?? false) }
        if jobs.count != before { await save() }
    }

    @discardableResult
    private func save() async -> Bool {
        let snapshot = jobs, url = url
        let error: String? = await withCheckedContinuation { continuation in
            persistence.async {
                do {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    let data = try encoder.encode(snapshot)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    continuation.resume(returning: nil)
                } catch {
                    RealtimeLog.log("dispatch: could not persist job receipts — \(error.localizedDescription)")
                    continuation.resume(returning: "Task history could not be saved. Check available disk space before starting more work.")
                }
            }
        }
        persistenceError = error
        changes += 1
        return error == nil
    }
}

extension DispatchJobStore {
    func beginMailAction(_ action: MailActionReceipt, ownerID: String, profileID: String?,
                         conversationID: String?, origin: DispatchJob.MailOrigin?,
                         draftReview: MailDraftReview? = nil) async throws -> (DispatchJob, Bool) {
        guard backend.userId == ownerID, ProfileRuntime.snapshot?.profileId == profileID else {
            throw GmailReadTools.Refusal(text: "Nothing was sent or saved. The active user or profile changed.")
        }
        if let key = action.requestKey, let existing = jobs.first(where: {
            $0.userId == ownerID && $0.profileId == profileID && $0.mailAction?.requestKey == key
        }) { return (existing, false) }
        // A new model call ID is not permission to repeat an unresolved send.
        if !action.kind.isDraft, let existing = jobs.first(where: { job in
            guard job.userId == ownerID, job.profileId == profileID, let prior = job.mailAction,
                  [.pending, .unknown].contains(prior.state) else { return false }
            guard prior.kind == action.kind, prior.account == action.account else { return false }
            if prior.kind == .send, prior.replyMessageID != nil, prior.replyMessageID == action.replyMessageID,
               prior.threadID == action.threadID { return true }
            return prior.to == action.to && prior.cc == action.cc && prior.bcc == action.bcc
                && prior.subject == action.subject && prior.body == action.body && prior.attachments == action.attachments
        }) { return (existing, false) }
        let job = DispatchJob(id: UUID(), task: action.title + " · " + action.subject, state: draftReview == nil ? "running" : "awaiting_input",
            result: draftReview == nil ? "Waiting for Gmail to confirm this action." : LocalDraftReview.notice,
            startedAt: Date(), deliveredAt: Date(), profileId: profileID,
            reportBack: false, userId: ownerID, conversationId: conversationID.flatMap(UUID.init(uuidString:)),
            origin: origin, mailAction: action, draftReview: draftReview)
        jobs.append(job)
        guard await save() else {
            throw GmailReadTools.Refusal(text: "Nothing was sent or saved because the action history could not be saved.")
        }
        return (job, true)
    }

    func mailAction(_ id: UUID) -> DispatchJob? { jobs.first { $0.id == id && $0.mailAction != nil } }

    @discardableResult
    func recordMailAction(_ id: UUID, state: MailActionReceipt.State, result: String,
                          provider: [String: Any]? = nil) async -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }), var action = jobs[index].mailAction else { return false }
        if action.confirmed, state != action.state { return true }
        if let provider {
            action.providerID = provider["id"] as? String
            let message = action.kind.isDraft ? provider["message"] as? [String: Any] : provider
            action.providerMessageID = message?["id"] as? String
            action.providerThreadID = message?["threadId"] as? String
            if let providerID = action.providerID, jobs.contains(where: {
                $0.id != id && $0.userId == jobs[index].userId && $0.profileId == jobs[index].profileId
                    && $0.mailAction?.account == action.account && $0.mailAction?.kind == action.kind
                    && $0.mailAction?.providerID == providerID && $0.mailAction?.confirmed == true
            }) {
                jobs.remove(at: index)
                return await save()
            }
        }
        action.state = state
        jobs[index].mailAction = action
        jobs[index].state = action.confirmed ? "done" : state == .review ? "awaiting_input" : state == .discarded ? "cancelled"
            : state == .failed ? "failed" : state == .unknown ? "unknown" : "running"
        if action.confirmed || state == .discarded { jobs[index].draftReview = nil }
        jobs[index].result = result
        jobs[index].completedAt = state == .pending || state == .queued || state == .review ? nil : Date()
        jobs[index].receipts = [.init(callId: id.uuidString, tool: action.tool,
            outcome: action.confirmed ? "success" : state == .discarded ? "cancelled" : state == .review ? "awaiting_review"
                : state == .failed ? "failed" : state == .unknown ? "unknown" : "pending")]
        return await save()
    }

    @discardableResult
    func recordMailArchive(_ id: UUID, state: String) async -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].mailAction != nil else { return false }
        jobs[index].mailAction?.archiveState = state
        return await save()
    }

    /// Claim the exact reviewed revision before suspending, so double clicks cannot issue two writes.
    func editDraftReview(_ id: UUID, revision: Int, subject: String, body: String,
                         saving: Bool = false) async throws -> DispatchJob {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].userId == backend.userId, jobs[index].profileId == ProfileRuntime.snapshot?.profileId,
              var review = jobs[index].draftReview, review.revision == revision,
              jobs[index].mailAction?.state == .review || jobs[index].mailAction?.state == .failed else {
            throw GmailReadTools.Refusal(text: "This draft changed or is no longer awaiting review. Reopen its latest version before saving.")
        }
        guard !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              subject.rangeOfCharacter(from: .newlines) == nil else {
            throw GmailReadTools.Refusal(text: "Give the draft a subject on one line before saving.")
        }
        if review.message.subject != subject || review.message.body != body {
            review.message.subject = subject; review.message.body = body
            review.originalRaw = nil
            jobs[index].mailAction?.subject = subject; jobs[index].mailAction?.body = body
        }
        review.revision += 1
        jobs[index].draftReview = review
        jobs[index].mailAction?.state = saving ? .pending : .review
        jobs[index].state = saving ? "running" : "awaiting_input"
        jobs[index].result = saving ? "Saving the reviewed draft to Gmail. Confirmation is pending." : LocalDraftReview.notice
        jobs[index].completedAt = nil
        let claimed = jobs[index]
        guard await save() else {
            if let current = jobs.firstIndex(where: { $0.id == id }), jobs[current].draftReview?.revision == review.revision {
                jobs[current].mailAction?.state = .review; jobs[current].state = "awaiting_input"
                jobs[current].result = "The local changes could not be saved. Nothing was written to Gmail."
            }
            throw GmailReadTools.Refusal(text: "The local draft could not be saved. Nothing was written to Gmail.")
        }
        return claimed
    }

    /// Reconcile a paused workflow without automatically executing its remaining actions.
    func reconcileDraftParent(_ id: UUID) async {
        guard let child = mailAction(id), let action = child.mailAction, let parentID = action.parentJobID,
              let parent = jobs.first(where: { $0.id == parentID }), parent.state == "awaiting_input",
              parent.result?.hasPrefix(LocalDraftReview.notice) == true else { return }
        if action.state == .discarded {
            await finish(parentID, state: "cancelled", result: "The draft was discarded. Later task steps were not run.", reportBack: false)
        } else if action.confirmed {
            var complete = parent.operation?.tool == "create_draft"
            if let command = parent.command, command.completedSteps < command.actions.count {
                let step = command.completedSteps
                await receipt(parentID, callId: id.uuidString, tool: action.tool, failed: false, commandStep: step, revision: parent.taskRevision)
                await completeCommandStep(parentID, index: step, result: child.result ?? "Draft saved in Gmail.", revision: parent.taskRevision)
                complete = step + 1 == command.actions.count
            }
            await finish(parentID, state: complete ? "done" : "partial", result: (child.result ?? "Draft saved in Gmail.")
                + (complete ? "" : " The task paused for draft review; any remaining steps have not run."), reportBack: !complete)
        } else if action.state == .unknown {
            await finish(parentID, state: "unknown", result: child.result ?? "The draft save is unconfirmed. Check Gmail before retrying.", reportBack: true)
        }
    }

    func discardDraftReview(_ id: UUID, revision: Int) async throws {
        guard let row = visible.first(where: { $0.id == id }), row.draftReview?.revision == revision,
              row.mailAction?.state == .review || row.mailAction?.state == .failed else {
            throw GmailReadTools.Refusal(text: "This draft is already saving or has changed. Reopen its current status.")
        }
        guard await recordMailAction(id, state: .discarded, result: "Discarded the local draft. Nothing was created in Gmail and the source email was kept.") else {
            throw GmailReadTools.Refusal(text: "The discard could not be saved locally. Nothing was changed in Gmail.")
        }
        await reconcileDraftParent(id)
    }
}
