import Foundation
import GRDB

struct EmailCleanupRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "email_cleanup"

    let userId: String
    let account: String
    let messageId: String
    let category: String
    let action: String
    let senderInboxCount: Int
    let atLeast: Bool
    let matchingMessageIDsJSON: Data
    let checkedAt: Date

    enum CodingKeys: String, CodingKey {
        case account, messageId, category, action, senderInboxCount, atLeast, checkedAt
        case userId = "user_id"
        case matchingMessageIDsJSON = "matchingMessageIDsJSON"
    }

    static func createSchema(_ db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.column("user_id", .text).notNull()
            t.column("account", .text).notNull()
            t.column("messageId", .text).notNull()
            t.column("category", .text).notNull()
            t.column("action", .text).notNull()
            t.column("senderInboxCount", .integer).notNull()
            t.column("atLeast", .boolean).notNull()
            t.column("matchingMessageIDsJSON", .blob).notNull()
            t.column("checkedAt", .datetime).notNull()
            t.primaryKey(["user_id", "account", "messageId"])
        }
    }

    static func recreateUserScopedSchema(_ db: Database) throws {
        try db.drop(table: databaseTableName)
        try createSchema(db)
    }
}

/// Adds Gmail-category cleanup context without classifying content or changing queue order.
actor EmailCleanupEnricher {
    private static let countCap = 500
    private static let cacheLifetime: TimeInterval = 15 * 60

    private struct Key: Hashable, Sendable {
        let userId: String
        let account: String
        let messageId: String
    }

    private var decisions: [Key: EmailCleanupDecision] = [:]
    private var completed: Set<Key> = []
    private var checkedAt: [Key: Date] = [:]
    private var workers: [Key: Task<Void, Never>] = [:]

    /// `within` caps the wait on an uncached lookup; the worker keeps running past it so
    /// the next step finds the answer cached. `nil` waits for the Gmail round trip.
    func decision(
        for item: EmailCleanupInput, userId: String, store: MailStore,
        within deadline: Duration? = nil
    ) async -> EmailCleanupDecision? {
        guard !userId.isEmpty else { return nil }
        let key = Self.key(item, userId: userId)
        if completed.contains(key),
           let checked = checkedAt[key], Date().timeIntervalSince(checked) <= Self.cacheLifetime {
            return decisions[key]
        }
        decisions.removeValue(forKey: key)
        completed.remove(key)
        checkedAt.removeValue(forKey: key)
        if let persisted = await cached(item, userId: userId, store: store) {
            decisions[key] = persisted.decision
            completed.insert(key)
            checkedAt[key] = persisted.checkedAt
            return persisted.decision
        }
        let worker = worker(for: item, userId: userId, store: store)
        if let deadline {
            let timer = Task { try? await Task.sleep(for: deadline) }
            let raced = Task { await worker.value; timer.cancel() }
            await timer.value
            raced.cancel()
            guard completed.contains(key) else {
                RealtimeLog.log("emailCleanup: \(item.id) still looking up after \(deadline); presenting without cleanup")
                return nil
            }
        } else {
            await worker.value
        }
        return decisions[key]
    }

    func prefetch(_ items: [EmailCleanupInput], userId: String, store: MailStore) {
        guard !userId.isEmpty else { return }
        for item in items {
            _ = worker(for: item, userId: userId, store: store)
        }
    }

    func cancelAll() async {
        let active = Array(workers.values)
        active.forEach { $0.cancel() }
        for task in active { await task.value }
        workers.removeAll()
        decisions.removeAll()
        completed.removeAll()
        checkedAt.removeAll()
    }

    func cancel(account: String) async {
        let account = account.lowercased()
        let keys = Set(workers.keys.filter { $0.account == account })
            .union(decisions.keys.filter { $0.account == account })
            .union(completed.filter { $0.account == account })
            .union(checkedAt.keys.filter { $0.account == account })
        let active = keys.compactMap { workers[$0] }
        active.forEach { $0.cancel() }
        for task in active { await task.value }
        for key in keys {
            workers.removeValue(forKey: key)
            decisions.removeValue(forKey: key)
            completed.remove(key)
            checkedAt.removeValue(forKey: key)
        }
    }

    private func worker(
        for item: EmailCleanupInput, userId: String, store: MailStore
    ) -> Task<Void, Never> {
        let key = Self.key(item, userId: userId)
        if completed.contains(key),
           let checked = checkedAt[key], Date().timeIntervalSince(checked) <= Self.cacheLifetime {
            return Task { }
        }
        if let existing = workers[key] { return existing }
        let created = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.enrich(item, userId: userId, store: store)
        }
        workers[key] = created
        return created
    }

    private func enrich(_ item: EmailCleanupInput, userId: String, store: MailStore) async {
        let key = Self.key(item, userId: userId)
        defer { workers.removeValue(forKey: key) }
        guard !Task.isCancelled else { return }

        if let persisted = await cached(item, userId: userId, store: store) {
            decisions[key] = persisted.decision
            completed.insert(key)
            checkedAt[key] = persisted.checkedAt
            return
        }

        guard let sender = EmailCleanupPolicy.sender(item.from),
              case .success(let token) = await GoogleCredential.token(for: item.account)
        else {
            // Settled, not retried on every step: the answer will not change this walk.
            completed.insert(key)
            checkedAt[key] = Date()
            return
        }

        do {
            let cachedCategory = await store.gmailCategory(id: item.id, account: item.account)
            let decision: EmailCleanupDecision
            if cachedCategory == .promotions {
                let query = "in:inbox category:promotions from:\(sender)"
                async let countPage = GmailAPI.messagePage(
                    token: token.accessToken, query: query, limit: Self.countCap)
                async let canUnsubscribe = GmailAPI.hasSafeUnsubscribeRoute(
                    token: token.accessToken, id: item.id)
                let (page, safeRoute) = try await (countPage, canUnsubscribe)
                let count = page.messages?.count ?? 0
                guard count > 0 else {
                    completed.insert(key)
                    checkedAt[key] = Date()
                    return
                }
                decision = EmailCleanupDecision(
                    category: .promotions,
                    action: safeRoute ? .unsubscribe : .archive,
                    senderInboxCount: count,
                    atLeast: page.nextPageToken != nil,
                    matchingMessageIDs: page.messages?.map(\.id) ?? [])
            } else {
                // Gmail does not consistently expose Purchases as message labelIds, so verify
                // membership with the exact sender/category query.
                let query = "in:inbox category:purchases from:\(sender)"
                let page = try await GmailAPI.messagePage(
                    token: token.accessToken, query: query, limit: Self.countCap)
                let matches = page.messages ?? []
                guard matches.contains(where: { $0.id == item.id }) else {
                    completed.insert(key)
                    checkedAt[key] = Date()
                    return
                }
                decision = EmailCleanupDecision(
                    category: .purchases,
                    action: .archive,
                    senderInboxCount: matches.count,
                    atLeast: page.nextPageToken != nil,
                    matchingMessageIDs: matches.map(\.id))
            }
            guard !Task.isCancelled else { return }
            await persist(decision, for: item, userId: userId, store: store)
            guard !Task.isCancelled else { return }
            decisions[key] = decision
            completed.insert(key)
            checkedAt[key] = Date()
            RealtimeLog.log(
                "emailCleanup: \(item.id) category=\(decision.category.rawValue) "
                    + "action=\(decision.action.rawValue) count="
                    + (decision.atLeast ? "at-least-" : "")
                    + "\(decision.senderInboxCount)")
        } catch is CancellationError {
            return
        } catch {
            RealtimeLog.log("emailCleanup: enrichment failed for \(item.id) — \(error)")
            // Settled for the cache lifetime: a retry would cost a Gmail round trip on every step.
            completed.insert(key)
            checkedAt[key] = Date()
        }
    }

    private static func key(_ item: EmailCleanupInput, userId: String) -> Key {
        Key(userId: userId, account: item.account.lowercased(), messageId: item.id)
    }

    private func cached(
        _ item: EmailCleanupInput, userId: String, store: MailStore
    ) async -> (decision: EmailCleanupDecision, checkedAt: Date)? {
        guard let database = store.database else { return nil }
        do {
            guard let record = try await database.read({ db in
                try EmailCleanupRecord
                    .filter(Column("user_id") == userId
                        && Column("account") == item.account.lowercased()
                        && Column("messageId") == item.id)
                    .fetchOne(db)
            }), Date().timeIntervalSince(record.checkedAt) <= Self.cacheLifetime,
            let category = GmailMailCategory(rawValue: record.category),
            let action = EmailCleanupDecision.Action(rawValue: record.action)
            else { return nil }
            let matchingIDs = (try? JSONDecoder().decode(
                [String].self, from: record.matchingMessageIDsJSON)) ?? []
            return (
                decision: EmailCleanupDecision(
                    category: category,
                    action: action,
                    senderInboxCount: record.senderInboxCount,
                    atLeast: record.atLeast,
                    matchingMessageIDs: matchingIDs),
                checkedAt: record.checkedAt)
        } catch {
            RealtimeLog.log("emailCleanup: cache read failed — \(error)")
            return nil
        }
    }

    private func persist(
        _ decision: EmailCleanupDecision,
        for item: EmailCleanupInput,
        userId: String,
        store: MailStore
    ) async {
        guard let database = store.database else { return }
        do {
            let matchingIDs = try JSONEncoder().encode(decision.matchingMessageIDs)
            try await database.write { db in
                try EmailCleanupRecord(
                    userId: userId,
                    account: item.account.lowercased(),
                    messageId: item.id,
                    category: decision.category.rawValue,
                    action: decision.action.rawValue,
                    senderInboxCount: decision.senderInboxCount,
                    atLeast: decision.atLeast,
                    matchingMessageIDsJSON: matchingIDs,
                    checkedAt: Date()).save(db)
            }
        } catch {
            RealtimeLog.log("emailCleanup: cache write failed — \(error)")
        }
    }

}
