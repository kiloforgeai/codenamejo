import Foundation
import FactoryKit

/// The dispatch log, kept on the phone: `DispatchWorker` writes each job's row, and the next call
/// reads back answers nobody heard and marks them delivered.
/// Not `final`: `PreviewDispatchJobStore` overrides `history()` and `recover()` to serve fixtures.
@MainActor
class DispatchJobStore {
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

    func previousOperation(_ operation: DispatchMailOperation, profileID: String?) -> DispatchJob? {
        jobs.last { $0.userId == backend.userId && $0.profileId == profileID && $0.operation == operation
            && ($0.isDone || $0.isRunning || $0.state == "unknown") }
    }

    /// A job has started; a retried memo reuses its id and starts its row again.
    func begin(id: UUID, task: String, profileId: String?, conversationId: UUID? = nil, turnId: String? = nil, operation: DispatchMailOperation? = nil, origin: DispatchJob.MailOrigin? = nil, command: DispatchJob.CommandRun? = nil) async {
        jobs.removeAll { $0.id == id }
        let profiles = Container.shared.workspaceProfiles()
        let defaultProfile = profileId == nil || profiles.profiles.first(where: { $0.id == profileId })?.isDefault == true
        let owner = backend.userId.map { $0 + (defaultProfile ? "" : ":profile:" + (profileId ?? "")) }
        jobs.append(DispatchJob(id: id, task: task, state: "running", startedAt: Date(), profileId: profileId,
            userId: backend.userId, conversationId: conversationId, turnId: turnId, historyOwner: owner, operation: operation, origin: origin, command: command))
        await save()
        await recordHistoryOutcome(jobs.first { $0.id == id }, status: .pending)
    }

    func receipt(_ id: UUID, callId: String, tool: String, failed: Bool, targetHash: String? = nil, commandStep: Int? = nil) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        var receipts = jobs[index].receipts ?? []
        guard !receipts.contains(where: { $0.callId == callId }) else { return }
        receipts.append(.init(callId: callId, tool: tool, outcome: failed ? "failed" : "success", targetHash: targetHash, commandStep: commandStep))
        jobs[index].receipts = receipts
        await save()
    }

    func completeCommandStep(_ id: UUID, index: Int, result: String) async {
        guard let row = jobs.firstIndex(where: { $0.id == id }), var command = jobs[row].command,
              index == command.completedSteps, index < command.actions.count else { return }
        command.completedSteps += 1
        command.completedResults.append(LiveCompactContext.bounded(result, bytes: 4_000, includeEmailContent: false))
        jobs[row].command = command
        await save()
    }

    func finish(_ id: UUID, state: String, result: String, reportBack: Bool? = nil, historyStatus: CommandRecord.CommandStatus? = nil, foregroundContinuation: Bool? = nil) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
        jobs[index].foregroundContinuation = foregroundContinuation
        jobs[index].result = result
        jobs[index].completedAt = Date()
        jobs[index].reportBack = reportBack
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
        jobs.removeAll { job in job.deliveredAt.map { now.timeIntervalSince($0) > DispatchJob.retention } ?? false }
        if jobs.count != before { await save() }
    }

    private func save() async {
        let snapshot = jobs, url = url
        await withCheckedContinuation { continuation in
            persistence.async {
                do {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    let data = try encoder.encode(snapshot)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                } catch { RealtimeLog.log("dispatch: could not persist job receipts — \(error.localizedDescription)") }
                continuation.resume()
            }
        }
    }
}
