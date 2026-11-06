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
    var userId: String? = nil
    var conversationId: UUID? = nil
    var turnId: String? = nil
    var receipts: [Receipt]? = nil
    var historyOwner: String? = nil
    var operation: DispatchMailOperation? = nil
    var foregroundContinuation: Bool? = nil
    /// Captured from the authorized handoff, never reconstructed from result prose or a subject.
    var origin: MailOrigin? = nil
    var command: CommandRun? = nil

    struct CommandRun: Codable, Hashable, Sendable {
        let keyword: String
        let actions: [CommandAction]
        var completedSteps = 0
        var completedResults: [String] = []
        var retryOf: UUID? = nil
    }

    struct RetryRefusal: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func commandRetry(using saved: CustomCommand, profileID: String?, accounts: [String]) throws -> CommandRun {
        guard self.profileId == profileID, let origin,
              accounts.contains(where: { $0.caseInsensitiveCompare(origin.account) == .orderedSame }) else {
            throw RetryRefusal(message: "The original email is not connected in this profile. Switch back to its profile and account before retrying.")
        }
        guard didFail, let command, command.keyword == saved.keyword else {
            throw RetryRefusal(message: "This is not a failed run of that command. No action was repeated.")
        }
        guard saved.enabled, command.completedSteps >= 0,
              command.completedSteps < saved.actions.count,
              Array(command.actions.prefix(command.completedSteps)) == Array(saved.actions.prefix(command.completedSteps)) else {
            throw RetryRefusal(message: "The command is disabled, finished, or its already completed steps changed. Review its result before starting different work.")
        }
        guard (receipts ?? []).filter({ $0.outcome == "success" }).allSatisfy({
            $0.commandStep.map { $0 >= 0 && $0 < command.completedSteps } == true
        }) else {
            throw RetryRefusal(message: "A previous write has a receipt but no matching command checkpoint. Check that result before retrying; Jo will not repeat an uncertain write.")
        }
        return .init(keyword: saved.keyword, actions: saved.actions, completedSteps: command.completedSteps,
            completedResults: command.completedResults, retryOf: id)
    }

    struct MailOrigin: Codable, Hashable, Sendable {
        let account: String
        let messageID: String
        let threadID: String
        let sender: String
        let subject: String

        static func from(_ target: [String: Any]?) -> Self? {
            guard let target, let account = target["account"] as? String, !account.isEmpty,
                  let id = target["id"] as? String, !id.isEmpty,
                  ((target["messages"] as? [Any])?.count ?? 1) == 1 else { return nil }
            return .init(account: account.lowercased(), messageID: id,
                threadID: target["threadId"] as? String ?? "", sender: target["from"] as? String ?? "",
                subject: target["subject"] as? String ?? "")
        }

        var about: LocalTriageQueue.Outcome.About {
            .init(account: account, id: messageID, threadId: threadID, from: sender, subject: subject)
        }
    }

    struct Receipt: Codable, Hashable {
        let callId: String
        let tool: String
        let outcome: String
        var targetHash: String? = nil
        var commandStep: Int? = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, task, state, result, receipts, historyOwner, operation, foregroundContinuation, origin, command
        case userId = "user_id"
        case conversationId = "conversation_id"
        case turnId = "turn_id"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case deliveredAt = "delivered_at"
        case profileId = "profile_id"
        case reportBack = "report_back"
    }

    var isRunning: Bool { state == "running" }
    var didFail: Bool { state == "failed" || state == "partial" }
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
        guard isDone || didFail || state == "unknown", let result, !result.isEmpty else { return nil }
        return result
    }
}

enum CommandRetryText {
    static func matches(_ text: String, keyword: String) -> Bool {
        let words = SpokenAnswerText.words(text)
        let prefixes: Set<String> = ["okay", "ok", "yeah", "yes", "please", "now"]
        let value = words.drop(while: prefixes.contains).joined(separator: " ")
        let name = SpokenAnswerText.words(keyword).joined(separator: " ")
        return ["run it again", "try it again", "retry it", "retry the command", "run that command again",
            "run command \(name) again", "run the command \(name) again", "retry command \(name)",
            "run \(name) again"].contains(value)
    }
}
