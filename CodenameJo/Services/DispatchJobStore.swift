import Foundation

/// The dispatch log, kept on the phone: `DispatchWorker` writes each job's row, and the next call
/// reads back answers nobody heard and marks them delivered.
/// Not `final`: `PreviewDispatchJobStore` overrides `history()` and `recover()` to serve fixtures.
@MainActor
class DispatchJobStore {
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
        guard let scope = ProfileRuntime.snapshot else { return jobs.filter { $0.profileId == nil } }
        return jobs.filter { $0.profileId == scope.profileId || (scope.isDefault && $0.profileId == nil) }
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
        prune(asOf: now)
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
        save()
    }

    /// A job has started; a retried memo reuses its id and starts its row again.
    func begin(id: UUID, task: String, profileId: String?) {
        jobs.removeAll { $0.id == id }
        jobs.append(DispatchJob(id: id, task: task, state: "running", startedAt: Date(), profileId: profileId))
        save()
    }

    func finish(_ id: UUID, state: String, result: String, reportBack: Bool? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
        jobs[index].result = result
        jobs[index].completedAt = Date()
        jobs[index].reportBack = reportBack
        save()
    }

    func discard(_ id: UUID) {
        jobs.removeAll { $0.id == id }
        save()
    }

    /// Sign-out: the next account inherits nothing.
    func removeAll() {
        jobs = []
        try? FileManager.default.removeItem(at: url)
    }

    /// Delivered rows past `DispatchJob.retention`. An undelivered answer is never pruned.
    private func prune(asOf now: Date) {
        let before = jobs.count
        jobs.removeAll { job in job.deliveredAt.map { now.timeIntervalSince($0) > DispatchJob.retention } ?? false }
        if jobs.count != before { save() }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(jobs) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
