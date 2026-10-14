import Foundation

/// One dispatched job, as `DispatchWorker` recorded it in the phone's dispatch log.
struct DispatchJob: Codable, Identifiable, Hashable {
    let id: UUID
    var task: String
    /// `running`, `done` or `failed`. Read it through the helpers below.
    var state: String
    /// The answer on `done`, the reason on `failed`, nil while `running` — speakable prose either way.
    var result: String?
    var startedAt: Date?
    var completedAt: Date?
    /// When the answer reached a conversation; nil is what `DispatchJobStore.recover()` looks for.
    var deliveredAt: Date?
    var profileId: String? = nil
    /// Only a confirmed action success is silent.
    var reportBack: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, task, state, result
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case deliveredAt = "delivered_at"
        case profileId = "profile_id"
        case reportBack = "report_back"
    }

    var isRunning: Bool { state == "running" }
    var didFail: Bool { state == "failed" }
    var isDone: Bool { state == "done" }

    /// How long a `running` row is given before it is presumed dead: above `DispatchWorker.budget`,
    /// since a job killed with the app writes no terminal state.
    static let runningTolerance: TimeInterval = 330

    /// How long a delivered row is kept before `recover()` prunes it. The exact number doesn't
    /// matter.
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    /// True once this job has stopped, one way or another.
    func hasStopped(asOf now: Date = Date()) -> Bool {
        guard isRunning else { return true }
        guard let startedAt else { return true }
        return now.timeIntervalSince(startedAt) > Self.runningTolerance
    }

    /// Whether this job has something to say, and what, with the stale-`running` case in one place.
    func recoveredAnswer(asOf now: Date = Date()) -> String? {
        if isDone && reportBack == false { return nil }
        if isRunning {
            // Still inside its budget — it may yet finish and be recovered on a
            // later connect. Saying anything now would be wrong.
            guard hasStopped(asOf: now) else { return nil }
            // A stale `running` row means the outcome is unknown: the worker writes the terminal
            // state last, so the job may have sent mail before it was killed.
            return "That job never reported back, so it is not known whether it finished "
                + "or what it managed to do. Do not tell the user it did nothing — say it "
                + "is unresolved, and offer to check the part that matters."
        }
        guard isDone || didFail, let result, !result.isEmpty else { return nil }
        return result
    }
}
