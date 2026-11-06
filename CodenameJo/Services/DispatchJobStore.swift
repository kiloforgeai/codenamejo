import Foundation
import FactoryKit
import Combine

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
        for index in jobs.indices where jobs[index].context != nil && jobs[index].isRunning {
            let queued = jobs[index].state == "queued"
            jobs[index].state = queued ? "awaiting_input" : "unknown"
            jobs[index].result = queued ? "The app closed before this task started. Review its source and instructions before resuming."
                : "The app closed while this task was running. Check its receipts and provider state before retrying; its outcome is unknown."
            jobs[index].reportBack = true
        }
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
    func contains(_ id: UUID) -> Bool { jobs.contains { $0.id == id } }

    func shouldPresent(_ id: UUID, revision: Int? = nil) -> Bool {
        guard contains(id) else { return true }
        guard let job = existing(id), revision == nil || job.taskRevision == revision else { return false }
        return job.deliveredAt == nil && !(job.isDone && job.effectivePreference == .quiet) && job.state != "cancelled"
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
    func begin(id: UUID, task: String, profileId: String?, conversationId: UUID? = nil, turnId: String? = nil, operation: DispatchMailOperation? = nil, origin: DispatchJob.MailOrigin? = nil, command: DispatchJob.CommandRun? = nil) async {
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
            userId: backend.userId, conversationId: conversationId, turnId: turnId, historyOwner: owner, operation: operation, origin: origin, command: command))
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
        jobs.removeAll { job in job.mailAction == nil && (job.deliveredAt.map { now.timeIntervalSince($0) > DispatchJob.retention } ?? false) }
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
                         conversationID: String?, origin: DispatchJob.MailOrigin?) async throws -> (DispatchJob, Bool) {
        guard backend.userId == ownerID, ProfileRuntime.snapshot?.profileId == profileID else {
            throw GmailReadTools.Refusal(text: "Nothing was sent or saved. The active user or profile changed.")
        }
        if let key = action.requestKey, let existing = jobs.first(where: {
            $0.userId == ownerID && $0.profileId == profileID && $0.mailAction?.requestKey == key
        }) { return (existing, false) }
        let job = DispatchJob(id: UUID(), task: action.title + " · " + action.subject, state: "running",
            result: "Waiting for Gmail to confirm this action.", startedAt: Date(), deliveredAt: Date(), profileId: profileID,
            reportBack: false, userId: ownerID, conversationId: conversationID.flatMap(UUID.init(uuidString:)),
            origin: origin, mailAction: action)
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
            let message = action.kind == .draft ? provider["message"] as? [String: Any] : provider
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
        jobs[index].state = action.confirmed ? "done" : state == .failed ? "failed" : state == .unknown ? "unknown" : "running"
        jobs[index].result = result
        jobs[index].completedAt = state == .pending || state == .queued ? nil : Date()
        jobs[index].receipts = [.init(callId: id.uuidString, tool: action.tool,
            outcome: action.confirmed ? "success" : state == .failed ? "failed" : state == .unknown ? "unknown" : "pending")]
        return await save()
    }
}
