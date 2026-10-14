import Foundation
import FactoryKit
import CryptoKit
import GRDB

/// At most 12 attempts inside 24 hours, backing off to 15 minutes.
enum PendingMailWritePolicy {
    static let maxAttempts = 12
    static let maxAge: TimeInterval = 24 * 60 * 60

    /// Retry-After is a lower bound, including when it exceeds the normal 15-minute cap.
    static func delay(attempt: Int, retryAfter: TimeInterval = 0, random: Double = .random(in: 0..<1)) -> TimeInterval {
        max(retryAfter, min(15 * 60, pow(2, Double(min(attempt, 20)))) * (1 + random))
    }

    static func expired(_ write: PendingMailWrite, now: Date) -> Bool {
        now.timeIntervalSince(write.createdAt) >= maxAge || write.attempts > maxAttempts
    }

    /// The failures worth another attempt: Gmail throttling, its 5xx, and no network.
    static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case GmailAPI.Failure.throttled, GmailAPI.Failure.transport: return true
        case GmailAPI.Failure.http(let code): return (500..<600).contains(code)
        case is PendingMailWrites.CredentialUnreachable: return true
        default: return false
        }
    }
}

/// One accepted archive, spam or trash whose Gmail call has not been confirmed yet, or a draft Gmail throttled.
struct PendingMailWrite: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "pending_mail_writes"

    enum State: String, Codable, Sendable { case pending, running, succeeded, failed }

    var id: String
    var user_id: String
    /// `archive_message`, `mark_spam`, `trash_message` or `create_draft`.
    var operation: String
    var account: String
    /// A draft has no message yet: this holds a digest of the built message, so the same draft is queued once.
    var messageId: String
    /// Archive only: learned from the message call, so a retry finishes with the thread call alone.
    var threadId: String?
    /// The call that accepted it, so a failure is told in that conversation and no other.
    var conversationId: String?
    var attempts: Int
    var dueAt: Date
    var createdAt: Date
    var completedAt: Date?
    var state: State
    /// The sentence the user hears if this never lands.
    var lastError: String?
    /// `create_draft` only: the built message, as `QueuedDraft` JSON. Replayed as is; a retry never re-derives it.
    var payload: String? = nil

    var receipt: PendingArchive {
        PendingArchive(id: id, account: account, messageId: messageId,
                       threadId: operation == "archive_message" ? threadId : nil, operation: operation)
    }

    static func createSchema(_ db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("id", .text)
            t.column("user_id", .text).notNull()
            t.column("operation", .text).notNull()
            t.column("account", .text).notNull()
            t.column("messageId", .text).notNull()
            t.column("threadId", .text)
            t.column("conversationId", .text)
            t.column("attempts", .integer).notNull().defaults(to: 0)
            t.column("dueAt", .datetime).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("completedAt", .datetime)
            t.column("state", .text).notNull()
            t.column("lastError", .text)
        }
        try db.create(index: "pending_mail_writes_due_idx", on: databaseTableName, columns: ["user_id", "state", "dueAt"])
    }

    static func addPayload(_ db: Database) throws {
        try db.alter(table: databaseTableName) { t in t.add(column: "payload", .text) }
    }

    /// What a throttled draft's row replays: the raw message and the thread it answers.
    struct QueuedDraft: Codable, Sendable {
        let raw: String
        let to: String
        let threadId: String?
    }

    var draft: PendingDraft? {
        guard operation == "create_draft",
              let queued = payload.flatMap({ try? JSONDecoder().decode(QueuedDraft.self, from: Data($0.utf8)) })
        else { return nil }
        return PendingDraft(id: id, account: account, to: queued.to, threadId: queued.threadId)
    }
}

/// Failure sentences for a deferred write that was told to the user before Gmail answered, held for the
/// conversation that started it and appended to that conversation's next function output.
final class LocalWriteNotices: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [(conversation: String, text: String)] = []

    func push(_ text: String, conversation: String?) {
        guard let conversation, !conversation.isEmpty else {
            RealtimeLog.log("notices: no conversation to tell — \(text.prefix(120))")
            return
        }
        lock.lock()
        held.append((conversation, text))
        lock.unlock()
        RealtimeLog.log("notices: held for the next function output: \(text.prefix(120))")
    }

    /// Taken once, in the order they happened. Another conversation's notices are dropped: that call is over.
    func drain(conversation: String?) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let mine = held.filter { $0.conversation == conversation }.map(\.text)
        let stale = held.count - mine.count
        held.removeAll()
        if stale > 0 { RealtimeLog.log("notices: dropped \(stale) from an earlier conversation") }
        return mine
    }

    /// `output` with any held notices appended.
    func appending(to output: String, conversation: String?) -> String {
        let notices = drain(conversation: conversation)
        return notices.isEmpty ? output : output + "\n\n" + notices.joined(separator: " ")
    }
}

/// The phone's queue of accepted archives, spam reports and trashes: written before the receipt is
/// spoken, drained right after, on foreground, during background refresh and when a call starts.
/// A drain that is killed with the app loses its retry; the message stays in the inbox and the queue shows it again.
actor PendingMailWrites {
    struct CredentialUnreachable: Error {}
    struct Unrecoverable: Error { let text: String }

    enum Outcome: Sendable {
        case succeeded([GmailWriteEffect])
        case failed(String)
    }

    typealias Perform = @Sendable (PendingMailWrite) async throws -> (effects: [GmailWriteEffect], threadId: String?)
    typealias Settled = @Sendable (PendingMailWrite, Outcome) async -> Void

    private let dbPool: DatabasePool?
    private let perform: Perform
    private let settled: Settled
    private let now: @Sendable () -> Date
    private var draining: Task<Void, Never>?
    private var wake: Task<Void, Never>?

    init(dbPool: DatabasePool?, perform: @escaping Perform = PendingMailWrites.gmail,
         settled: @escaping Settled = PendingMailWrites.report, now: @escaping @Sendable () -> Date = Date.init) {
        self.dbPool = dbPool
        self.perform = perform
        self.settled = settled
        self.now = now
    }

    /// Accept one write. A second accept of the same message while one is active returns that one.
    func enqueue(userId: String, operation: String, account: String, messageId: String, threadId: String? = nil,
                 conversationId: String?, delay: TimeInterval = 0) async throws -> PendingArchive {
        try await accept(userId: userId, operation: operation, account: account, messageId: messageId,
                         threadId: threadId, conversationId: conversationId, delay: delay).receipt
    }

    /// Queue a draft Gmail throttled. The same message queued twice while one is active returns that one.
    func enqueueDraft(userId: String, account: String, draft: PendingMailWrite.QueuedDraft,
                      conversationId: String?, delay: TimeInterval) async throws -> PendingDraft {
        let payload = String(decoding: try JSONEncoder().encode(draft), as: UTF8.self)
        let row = try await accept(userId: userId, operation: "create_draft", account: account,
                                   messageId: Self.digest(draft), threadId: draft.threadId,
                                   conversationId: conversationId, delay: delay, payload: payload)
        guard let pending = row.draft else { throw Unrecoverable(text: "the queued draft could not be read back") }
        return pending
    }

    /// The whole built message, so two drafts that differ only by a copy or a thread are two rows.
    private static func digest(_ draft: PendingMailWrite.QueuedDraft) -> String {
        var hasher = SHA256()
        hasher.update(data: Data((draft.raw + "\n" + (draft.threadId ?? "")).utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func accept(userId: String, operation: String, account: String, messageId: String, threadId: String?,
                        conversationId: String?, delay: TimeInterval, payload: String? = nil) async throws -> PendingMailWrite {
        guard let dbPool else { throw Unrecoverable(text: "The phone's mail database is unavailable.") }
        let at = now()
        let account = account.lowercased()
        let write = try await dbPool.write { db -> PendingMailWrite in
            if let active = try PendingMailWrite
                .filter(Column("user_id") == userId && Column("account") == account
                    && Column("messageId") == messageId && Column("operation") == operation)
                .filter([PendingMailWrite.State.pending.rawValue, PendingMailWrite.State.running.rawValue].contains(Column("state")))
                .fetchOne(db) { return active }
            let write = PendingMailWrite(id: UUID().uuidString.lowercased(), user_id: userId, operation: operation,
                account: account, messageId: messageId, threadId: threadId, conversationId: conversationId,
                attempts: 0, dueAt: at.addingTimeInterval(delay), createdAt: at, completedAt: nil, state: .pending, lastError: nil,
                payload: payload)
            try write.insert(db)
            return write
        }
        RealtimeLog.log("pendingWrites: queued \(operation) \(write.id)")
        return write
    }

    /// Start a drain unless one is running. Returns once that drain has finished.
    func drain(userId: String) async {
        if let draining { return await draining.value }
        let task = Task { await self.drainDue(userId: userId) }
        draining = task
        await task.value
        draining = nil
        await scheduleWake(userId: userId)
    }

    /// Fire-and-forget form of `drain`, for the paths that must not wait on Gmail.
    nonisolated func drainSoon(userId: String) {
        Task { await self.drain(userId: userId) }
    }

    func status(userId: String, includeSucceeded: Bool = true) async -> ArchiveRetryStatus {
        guard let dbPool else { return ArchiveRetryStatus(pending: []) }
        let since = now().addingTimeInterval(-2 * 24 * 60 * 60)
        do {
            return try await dbPool.read { db in
                // A queued draft is not an archive: the queue's retry status and unarchive guard never see it.
                let mine = PendingMailWrite.filter(Column("user_id") == userId && Column("operation") != "create_draft")
                let pending = try mine
                    .filter([PendingMailWrite.State.pending.rawValue, PendingMailWrite.State.running.rawValue].contains(Column("state")))
                    .order(Column("createdAt")).fetchAll(db).map(\.receipt)
                guard includeSucceeded else { return ArchiveRetryStatus(pending: pending) }
                let succeeded = try mine.filter(Column("state") == PendingMailWrite.State.succeeded.rawValue)
                    .filter(Column("completedAt") > since).order(Column("completedAt").desc).fetchAll(db).map(\.receipt)
                return ArchiveRetryStatus(pending: pending, succeeded: succeeded)
            }
        } catch {
            RealtimeLog.log("pendingWrites: status read failed — \(error)")
            return ArchiveRetryStatus(pending: [])
        }
    }

    func pending(userId: String) async -> [PendingArchive] {
        await status(userId: userId, includeSucceeded: false).pending
    }

    // MARK: - Draining

    private func drainDue(userId: String) async {
        guard let dbPool else { return }
        while let job = await claim(userId: userId, dbPool: dbPool) {
            var outcome: Outcome?
            var retryAt: Date?
            var learnedThread: String?
            if PendingMailWritePolicy.expired(job, now: now()) {
                outcome = .failed(job.lastError ?? Self.failure(for: job, error: Unrecoverable(text: "the retry window expired")))
            } else {
                do {
                    let done = try await perform(job)
                    learnedThread = done.threadId
                    outcome = .succeeded(done.effects)
                } catch {
                    if let partial = error as? PartialWrite { learnedThread = partial.threadId }
                    let cause = (error as? PartialWrite)?.cause ?? error
                    let sentence = Self.failure(for: job, error: cause, threadStep: learnedThread != nil && job.threadId == nil)
                    let later = now().addingTimeInterval(PendingMailWritePolicy.delay(attempt: job.attempts + 1))
                    if PendingMailWritePolicy.isRetryable(cause), job.attempts < PendingMailWritePolicy.maxAttempts,
                       later.timeIntervalSince(job.createdAt) < PendingMailWritePolicy.maxAge {
                        retryAt = later
                        await record(job, state: .pending, dueAt: later, error: sentence, thread: learnedThread)
                    } else {
                        outcome = .failed(sentence)
                    }
                }
            }
            guard let outcome else {
                RealtimeLog.log("pendingWrites: \(job.id) attempt=\(job.attempts) pending until \(retryAt.map { "\($0)" } ?? "?")")
                continue
            }
            switch outcome {
            case .succeeded:
                await record(job, state: .succeeded, dueAt: job.dueAt, error: nil, thread: learnedThread)
            case .failed(let sentence):
                await record(job, state: .failed, dueAt: job.dueAt, error: sentence, thread: learnedThread)
            }
            RealtimeLog.log("pendingWrites: \(job.operation) \(job.id) attempt=\(job.attempts) "
                + "\(outcome.isSuccess ? "landed" : "failed") \(Int(now().timeIntervalSince(job.createdAt) * 1000))ms after accept")
            var settledJob = job
            settledJob.threadId = job.threadId ?? learnedThread
            await settled(settledJob, outcome)
        }
    }

    /// One due row, marked running with its attempt counted, so a drain killed mid-call never repeats it unseen.
    private func claim(userId: String, dbPool: DatabasePool) async -> PendingMailWrite? {
        let at = now()
        do {
            return try await dbPool.write { db -> PendingMailWrite? in
                // A row left running was a drain killed with the app; it is due again.
                guard var job = try PendingMailWrite.filter(Column("user_id") == userId)
                    .filter([PendingMailWrite.State.pending.rawValue, PendingMailWrite.State.running.rawValue].contains(Column("state")))
                    .filter(Column("dueAt") <= at).order(Column("dueAt")).fetchOne(db) else { return nil }
                job.state = .running
                job.attempts += 1
                try job.update(db)
                return job
            }
        } catch {
            RealtimeLog.log("pendingWrites: claim failed — \(error)")
            return nil
        }
    }

    private func record(_ job: PendingMailWrite, state: PendingMailWrite.State, dueAt: Date, error: String?, thread: String?) async {
        guard let dbPool else { return }
        var row = job
        row.state = state
        row.dueAt = dueAt
        row.lastError = error
        row.threadId = job.threadId ?? thread
        row.completedAt = state == .pending ? nil : now()
        do {
            try await dbPool.write { db in try row.update(db) }
        } catch {
            RealtimeLog.log("pendingWrites: could not record \(job.id) as \(state.rawValue) — \(error)")
        }
    }

    /// While the app is alive, come back for the next retry rather than waiting for a foreground.
    private func scheduleWake(userId: String) async {
        wake?.cancel()
        guard let dbPool else { return }
        let next: Date?
        do {
            next = try await dbPool.read { db in
                try Date.fetchOne(db, PendingMailWrite.select(min(Column("dueAt")))
                    .filter(Column("user_id") == userId && Column("state") == PendingMailWrite.State.pending.rawValue))
            }
        } catch {
            RealtimeLog.log("pendingWrites: next retry read failed — \(error)")
            return
        }
        guard let next else { return }
        let wait = max(0, next.timeIntervalSince(now()))
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            await self.drain(userId: userId)
        }
    }

    // MARK: - Gmail

    /// The message call landed and the thread call did not; a retry starts at the thread.
    struct PartialWrite: Error {
        let threadId: String
        let cause: Error
    }

    @Sendable static func gmail(_ job: PendingMailWrite) async throws -> (effects: [GmailWriteEffect], threadId: String?) {
        let token: String
        switch await GoogleCredential.token(for: job.account) {
        case .success(let granted): token = granted.accessToken
        case .failure(.noStoredGrant), .failure(.grantRevoked), .failure(.scopesMissing):
            throw Unrecoverable(text: "the mailbox needs reconnecting before this can finish")
        case .failure:
            throw CredentialUnreachable()
        }
        let effects = GmailManageTools.Effects()
        let remove = ["INBOX", "UNREAD"]
        switch job.operation {
        case "create_draft":
            // A retried draft never files the thread it answers.
            guard let queued = job.payload.flatMap({ try? JSONDecoder().decode(PendingMailWrite.QueuedDraft.self, from: Data($0.utf8)) })
            else { throw Unrecoverable(text: "the queued draft could not be read back") }
            try await LocalCompose.saveDraft(token, raw: queued.raw, threadId: queued.threadId)
            return ([], nil)
        case "mark_spam", "trash_message":
            _ = try await GmailManageTools.modify(token, account: job.account, id: job.messageId,
                add: [job.operation == "mark_spam" ? "SPAM" : "TRASH"], remove: remove, effects)
            return (effects.list, nil)
        default:
            if let thread = job.threadId {
                try await GmailManageTools.modifyThread(token, account: job.account, threadId: thread, add: [], remove: remove, effects)
                return (effects.list, thread)
            }
            let message = try await GmailManageTools.modify(token, account: job.account, id: job.messageId,
                                                           add: [], remove: remove, effects)
            guard !message.threadId.isEmpty else { return (effects.list, nil) }
            do {
                try await GmailManageTools.modifyThread(token, account: job.account, threadId: message.threadId,
                                                        add: [], remove: remove, effects)
            } catch {
                throw PartialWrite(threadId: message.threadId, cause: error)
            }
            return (effects.list, message.threadId)
        }
    }

    /// The failure sentence for the operation the row holds.
    static func failure(for job: PendingMailWrite, error: Error, threadStep: Bool = false) -> String {
        if job.operation == "create_draft" {
            return LocalCompose.draftFailure(error, account: job.account)
        }
        if let unrecoverable = error as? Unrecoverable {
            return "that didn't go through (\(unrecoverable.text)) — \(LocalMailWrites.unchanged(job.operation))."
        }
        return LocalMailWrites.failure(error, account: job.account, operation: job.operation, threadStep: threadStep)
    }

    /// The default `Settled`: confirmed effects reach the cache and the queue; a failure is told and shown again.
    @Sendable static func report(_ job: PendingMailWrite, _ outcome: Outcome) async {
        let triage = Container.shared.localTriage()
        switch outcome {
        case .succeeded(let effects):
            guard !effects.isEmpty else { return }
            let store = await MainActor.run { Container.shared.mailStore() }
            _ = await triage.applyConfirmedEffects(effects, store: store)
        case .failed(let sentence):
            await triage.dropPendingArchive(id: job.id)
            Container.shared.localWriteNotices().push(sentence, conversation: job.conversationId)
        }
    }
}

private extension PendingMailWrites.Outcome {
    var isSuccess: Bool {
        if case .succeeded = self { return true }
        return false
    }
}
