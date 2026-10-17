import Foundation
import GRDB

/// One account/day/scope checkpoint. Queue internals live in a JSON payload so additions stay
/// backward-compatible; the identifying dimensions stay queryable GRDB columns.
struct DailyEmailQueueSnapshotRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "daily_email_queue_snapshot"

    let key: String
    let account: String
    let localDay: String
    let scope: String
    let split: String
    let payload: Data
    let updatedAt: Date
    /// The owner (`BackendService.userId`), so one account never resumes another's walk.
    var userId: String = ""

    enum CodingKeys: String, CodingKey {
        case key, account, localDay, scope, split, payload, updatedAt
        case userId = "user_id"
    }

    static func createSchema(_ db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("key", .text)
            t.column("account", .text).notNull()
            t.column("localDay", .text).notNull()
            t.column("scope", .text).notNull()
            t.column("split", .text).notNull().defaults(to: "")
            t.column("payload", .blob).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        try db.create(
            index: "daily_email_queue_account_day_idx",
            on: databaseTableName,
            columns: ["account", "localDay", "updatedAt"])
    }

    /// `v44-queue-snapshot-owner`. Existing rows are given the install's id by `v45`.
    static func addOwner(_ db: Database) throws {
        try db.alter(table: databaseTableName) { t in
            t.add(column: "user_id", .text).notNull().defaults(to: "")
        }
    }
}

/// How the triage queue persists across the day: one checkpoint per account, day and scope, read
/// back when a later call resumes the walk.
enum TriageQueueSnapshotStore {
    typealias Item = LocalTriageQueue.Item
    typealias Scope = LocalTriageQueue.Scope

    /// The queue's internals, saved as the record's JSON `payload`.
    struct Payload: Codable, Sendable {
        let items: [Item]
        let grouping: Bool?
        /// Mailboxes this snapshot was built to cover. Optional for older checkpoints.
        let accounts: [String]?
        /// Position inside `items`, not the spoken/global ordinal.
        let position: Int
        /// Completed positions omitted from a compact restored buffer.
        let ordinalOffset: Int?
        let before: Int64?
        let more: Bool
        let total: Int
        let mailboxUnreadAtStart: Int
        let scope: Scope
        let scopeUnsaid: Bool
        /// Optional so snapshots written before staged Gmail walks still decode.
        let scopePlan: [Scope]?
        let adopted: Bool
        let completed: Bool
        /// Optional so checkpoints written before Gmail walk scoping still decode.
        let gmailWalkDealtWith: [String]?
        var summarizedReadThreads: [String]? = nil
        var pendingArchives: [PendingArchive]? = nil
        var dispatchSweepIDs: [String]? = nil
        /// The band this walk was standing in. Optional so older checkpoints decode, as unbanded walks.
        var band: String? = nil
        /// The score half of that walk's cursor.
        var beforeScore: Int? = nil
        var beforeID: String? = nil
        var topicGrouping: Bool? = nil
        var presentedTopicKeys: [String]? = nil
        /// Items, mail count and keys omitted before the cursor. Nil for legacy full-buffer rows.
        var trimmedItems: Int? = nil
        var trimmedOrdinals: Int? = nil
        var trimmedKeys: [String]? = nil

        /// This buffer row with its cursor row laid over it: the cursor's position is in the live
        /// buffer's terms, so the items the row left out are taken off it and added to the ordinal.
        func applying(_ cursor: Cursor) -> Payload {
            Payload(
                items: items, grouping: grouping, accounts: accounts,
                position: cursor.position - (trimmedItems ?? 0),
                ordinalOffset: cursor.ordinalOffset + (trimmedOrdinals ?? 0),
                before: cursor.before, more: cursor.more, total: cursor.total,
                mailboxUnreadAtStart: mailboxUnreadAtStart, scope: scope, scopeUnsaid: cursor.scopeUnsaid,
                scopePlan: scopePlan, adopted: adopted, completed: cursor.completed,
                gmailWalkDealtWith: cursor.gmailWalkDealtWith,
                summarizedReadThreads: cursor.summarizedReadThreads,
                pendingArchives: cursor.pendingArchives, dispatchSweepIDs: cursor.dispatchSweepIDs,
                band: cursor.band, beforeScore: cursor.beforeScore, beforeID: cursor.beforeID,
                topicGrouping: topicGrouping, presentedTopicKeys: cursor.presentedTopicKeys,
                trimmedItems: trimmedItems, trimmedOrdinals: trimmedOrdinals, trimmedKeys: trimmedKeys)
        }
    }

    /// The part of a checkpoint that moves on every step, in its own row (`split` = `cursorSplit`):
    /// a step writes these few fields, and the item buffer only when the buffer itself changed.
    struct Cursor: Codable, Sendable {
        /// Position in the live buffer. `Payload.applying` translates it to the saved one.
        let position: Int
        let ordinalOffset: Int
        let before: Int64?
        let more: Bool
        let total: Int
        let completed: Bool
        let scopeUnsaid: Bool
        let gmailWalkDealtWith: [String]
        let summarizedReadThreads: [String]
        let pendingArchives: [PendingArchive]?
        let dispatchSweepIDs: [String]?
        let band: String?
        let beforeScore: Int?
        let beforeID: String?
        let presentedTopicKeys: [String]
    }

    /// The `split` of a cursor row; the item buffer row's is `""`, as every row's was before the split.
    static let cursorSplit = "cursor"

    static func key(account: String, day: String, scope: Scope, split: String) -> String {
        [account.lowercased(), day, scope.rawValue, split].joined(separator: "|")
    }

    /// Overlay cursors on their buffers, newest update first; legacy rows stand alone.
    private static func payloads(
        _ records: [DailyEmailQueueSnapshotRecord]
    ) -> [(record: DailyEmailQueueSnapshotRecord, saved: Payload)] {
        let decoder = JSONDecoder()
        var cursors: [String: (cursor: Cursor, updatedAt: Date)] = [:]
        for record in records where record.split == cursorSplit {
            guard let cursor = try? decoder.decode(Cursor.self, from: record.payload),
                  let scope = Scope(rawValue: record.scope) else { continue }
            cursors[key(account: record.account, day: record.localDay, scope: scope, split: "")] = (cursor, record.updatedAt)
        }
        return records.filter { $0.split.isEmpty }
            .compactMap { record -> (DailyEmailQueueSnapshotRecord, Payload, Date)? in
                guard let saved = try? decoder.decode(Payload.self, from: record.payload) else { return nil }
                guard let (cursor, movedAt) = cursors[record.key] else { return (record, saved, record.updatedAt) }
                return (record, saved.applying(cursor), max(record.updatedAt, movedAt))
            }
            .sorted { $0.2 > $1.2 }
            .map { ($0.0, $0.1) }
    }

    static func localDay(for date: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0,
                      parts.day ?? 0)
    }

    static func restoredHandledKeys(_ keys: [String], items: [Item], accounts: [String]) -> Set<String> {
        let mailboxes = Set(accounts.map { $0.lowercased() })
        return Set(keys.flatMap { key -> [String] in
            if key.hasPrefix("message:") { return [key] }
            let owners = Set(items.filter { $0.holds(key) }.map { $0.account.lowercased() })
            if owners.count == 1, let owner = owners.first { return [LocalTriageQueue.messageKey(account: owner, id: key)] }
            if owners.isEmpty, mailboxes.count == 1, let owner = mailboxes.first {
                return [LocalTriageQueue.messageKey(account: owner, id: key)]
            }
            RealtimeLog.log("localTriage: legacy handled identity has ambiguous mailbox ownership")
            return []
        })
    }

    static func refreshedSavedItems(
        _ saved: [Item], rows: [MailStore.Message], eligibleIDs: Set<String>?,
        requeuedInboxIDs: Set<String>? = nil
    ) -> [Item] {
        let heldByID = Dictionary(rows.map { (LocalTriageQueue.messageKey(account: $0.account, id: $0.id), $0) }, uniquingKeysWith: { a, _ in a })
        return saved.flatMap { item -> [Item] in
            if item.isTopicGroup {
                let parts = refreshedSavedItems(item.unwrappedTopics, rows: rows, eligibleIDs: eligibleIDs,
                    requeuedInboxIDs: requeuedInboxIDs)
                let members = parts.flatMap(\.conversation)
                return item.keeping(members).map { [$0] } ?? []
            }
            return item.ids.compactMap { id in
                let eligible = item.unresolvedContinuation == true
                    ? requeuedInboxIDs?.contains(id) != false : eligibleIDs?.contains(id) != false
                guard eligible, let row = heldByID[LocalTriageQueue.messageKey(account: item.account, id: id)],
                      row.account.lowercased() == item.account.lowercased() else { return nil }
                var refreshed = TriageMailSource.item(from: row)
                refreshed.messages = refreshed.conversation.map { member in
                    var member = member
                    member.unread = item.conversation.first(where: { $0.id == id })?.unread ?? member.unread
                    return member
                }
                refreshed.hasDraft = item.hasDraft
                refreshed.threadReadVerified = item.threadReadVerified
                refreshed.threadMessageCount = item.threadMessageCount
                refreshed.displayGroupID = item.displayGroupID
                refreshed.summaryMessages = item.summaryMessages
                refreshed.exchangeContext = item.exchangeContext
                refreshed.unresolvedContinuation = item.unresolvedContinuation
                refreshed.coachingCounted = item.coachingCounted
                return refreshed
            }
        }
    }

    /// Whether a persisted stage belongs to the automatic walk this session would start now. Matched
    /// against the stored plan, since the queue may legitimately be on a later stage.
    private static func snapshotMatchesAutomatic(
        scope: Scope,
        scopePlan: [Scope]?,
        preferred: TriageScope?
    ) -> Bool {
        let first = preferred.flatMap { Scope(rawValue: $0.rawValue) } ?? Scope.automaticStart
        let expected = first.restOfWalk
        guard let scopePlan, !scopePlan.isEmpty else {
            // Compatibility with snapshots written before staged daily walks existed.
            return scope == first
        }
        return scopePlan == expected && expected.contains(scope)
    }

    /// Resume ordering is intentionally independent of persistence: unresolved current first,
    /// newly arrived messages next, then the saved tail, with ids deduplicated throughout.
    static func mergeForResume(
        currentID: String?, eligibleSaved: [Item], fresh: [Item], currentAccount: String? = nil
    ) -> [Item] {
        var result: [Item] = []
        var seen = Set<String>()
        func append(_ item: Item) {
            guard let fresh = item.keeping(item.conversation.filter {
                seen.insert(LocalTriageQueue.messageKey(account: item.account, id: $0.id)).inserted
            }) else { return }
            result.append(fresh)
        }
        if let currentID,
           let current = eligibleSaved.first(where: {
               $0.holds(currentID) && (currentAccount == nil || $0.account == currentAccount)
           }) {
            append(current)
        }
        fresh.forEach(append)
        eligibleSaved.forEach(append)
        return result
    }

    static func restoringPage(
        _ fresh: [Item], to restored: [Item], currentID: String?, currentAccount: String?, grouping: Bool
    ) -> [Item] {
        let currentIndex = restored.firstIndex {
            $0.holds(currentID ?? "") && $0.account.lowercased() == currentAccount?.lowercased()
        }
        let normalized = LocalTriageQueue.appendingPage(fresh, to: restored,
            position: currentIndex.map { $0 + 1 } ?? 0, grouping: grouping)
        let current = currentIndex.map { restored[$0] }
        let freshGroups = fresh.flatMap { incoming in
            normalized.filter { candidate in
                candidate.account.lowercased() == incoming.account.lowercased()
                    && !Set(candidate.ids).isDisjoint(with: incoming.ids)
            }
        }
        return mergeForResume(currentID: current?.id, eligibleSaved: normalized,
            fresh: freshGroups, currentAccount: current?.account)
    }

    static func snapshotAccountsMatch(
        saved: [String], current: [String], allowsSubset: Bool
    ) -> Bool {
        let saved = Set(saved.map { $0.lowercased() })
        let current = Set(current.map { $0.lowercased() })
        guard !saved.isEmpty else { return false }
        return allowsSubset ? saved.isSubset(of: current) : saved == current
    }

    /// The newest unfinished checkpoint for today that this session may resume, or nil.
    static func resumable(
        in database: DatabasePool, userId: String, day: String, account selectedAccount: String?,
        input: LocalTriageQueue.Input, currentAccounts: Set<String>
    ) async -> (account: String, saved: Payload)? {
        let wantedScope = input.scope?.rawValue
        let records: [DailyEmailQueueSnapshotRecord] = (try? await database.read { db in
            var request = DailyEmailQueueSnapshotRecord
                .filter(Column("user_id") == userId)
                .filter(Column("localDay") == day)
            if let selectedAccount {
                request = request.filter(Column("account") == selectedAccount)
            }
            if let wantedScope { request = request.filter(Column("scope") == wantedScope) }
            return try request.order(Column("updatedAt").desc).fetchAll(db)
        }) ?? []
        for (record, saved) in payloads(records) {
            guard !saved.completed else { continue }
            let savedAccounts = Set((saved.accounts ?? saved.items.map(\.account)).map {
                $0.lowercased()
            })
            // Mixed-account snapshots predate mailbox containers and cannot be resumed
            // truthfully as one inbox. A single-account checkpoint remains compatible.
            guard savedAccounts == Set([record.account.lowercased()]) else { continue }
            guard Self.snapshotAccountsMatch(
                saved: saved.accounts ?? saved.items.map(\.account),
                current: Array(currentAccounts),
                allowsSubset: true)
            else { continue }
            // An argument names the queue exactly. With no argument this is the automatic daily
            // opening, so it must match the walk an automatic opening would build now.
            if input.account == nil, input.scope == nil,
               !Self.snapshotMatchesAutomatic(
                   scope: saved.scope,
                   scopePlan: saved.scopePlan,
                   preferred: TriageScope.preferred) {
                continue
            }
            return (record.account, saved)
        }
        return nil
    }

    /// Today's checkpoints for this account, newest first. Rows that no longer decode are skipped.
    static func savedToday(account: String, userId: String, database: DatabasePool) async throws -> [Payload] {
        let day = localDay()
        // The row is keyed by the mailbox as it was connected; callers may spell it lowercased.
        let records = try await database.read { db in
            try DailyEmailQueueSnapshotRecord.filter(Column("user_id") == userId)
                .filter(Column("localDay") == day).order(Column("updatedAt").desc).fetchAll(db)
        }.filter { $0.account.caseInsensitiveCompare(account) == .orderedSame }
        return payloads(records).map(\.saved)
    }

    struct BufferMissing: Error {}

    /// Atomically save a cursor and optional buffer. A cursor-only write requires an existing
    /// buffer; false tells the caller to resend it.
    @discardableResult
    static func save(cursor: Cursor, buffer: Payload?, account: String, day: String, scope: Scope,
                     store: MailStore, database: DatabasePool) async -> Bool {
        let encoder = JSONEncoder()
        guard let cursorData = try? encoder.encode(cursor) else { return false }
        let bufferData: Data?
        if let buffer {
            guard let data = try? encoder.encode(buffer) else { return false }
            bufferData = data
        } else {
            bufferData = nil
        }
        let now = Date()
        let bufferKey = key(account: account, day: day, scope: scope, split: "")
        let cursorRecord = DailyEmailQueueSnapshotRecord(
            key: key(account: account, day: day, scope: scope, split: cursorSplit), account: account,
            localDay: day, scope: scope.rawValue, split: cursorSplit, payload: cursorData, updatedAt: now,
            userId: store.userId)
        do {
            try await database.write { db in
                if let bufferData {
                    try DailyEmailQueueSnapshotRecord(
                        key: bufferKey, account: account, localDay: day, scope: scope.rawValue,
                        split: "", payload: bufferData, updatedAt: now, userId: store.userId).save(db)
                } else if try !DailyEmailQueueSnapshotRecord.exists(db, key: bufferKey) {
                    throw BufferMissing()
                }
                try cursorRecord.save(db)
                // Day rollover is destructive for this account by design; another account's
                // checkpoint remains separate.
                try DailyEmailQueueSnapshotRecord
                    .filter(Column("user_id") == store.userId)
                    .filter(Column("account") == account && Column("localDay") != day)
                    .deleteAll(db)
            }
            return true
        } catch {
            RealtimeLog.log("localTriage: checkpoint not written — \(error)")
            return false
        }
    }

    /// Delete today's checkpoints for these accounts, or for every account when none are given.
    static func discard(day: String, accounts: [String], store: MailStore, database: DatabasePool) async {
        try? await database.write { db in
            var request = DailyEmailQueueSnapshotRecord.filter(Column("user_id") == store.userId)
                .filter(Column("localDay") == day)
            if !accounts.isEmpty { request = request.filter(accounts.contains(Column("account"))) }
            try request.deleteAll(db)
        }
    }
}

/// The queue's original entry points, kept so existing callers read unchanged.
extension LocalTriageQueue {
    static func localDay(for date: Date = Date(), calendar: Calendar = .current) -> String {
        TriageQueueSnapshotStore.localDay(for: date, calendar: calendar)
    }

    static func restoredHandledKeys(_ keys: [String], items: [Item], accounts: [String]) -> Set<String> {
        TriageQueueSnapshotStore.restoredHandledKeys(keys, items: items, accounts: accounts)
    }

    static func refreshedSavedItems(
        _ saved: [Item], rows: [MailStore.Message], eligibleIDs: Set<String>?,
        requeuedInboxIDs: Set<String>? = nil
    ) -> [Item] {
        TriageQueueSnapshotStore.refreshedSavedItems(
            saved, rows: rows, eligibleIDs: eligibleIDs, requeuedInboxIDs: requeuedInboxIDs)
    }

    static func mergeForResume(
        currentID: String?, eligibleSaved: [Item], fresh: [Item], currentAccount: String? = nil
    ) -> [Item] {
        TriageQueueSnapshotStore.mergeForResume(
            currentID: currentID, eligibleSaved: eligibleSaved, fresh: fresh, currentAccount: currentAccount)
    }

    static func restoringPage(
        _ fresh: [Item], to restored: [Item], currentID: String?, currentAccount: String?, grouping: Bool
    ) -> [Item] {
        TriageQueueSnapshotStore.restoringPage(
            fresh, to: restored, currentID: currentID, currentAccount: currentAccount, grouping: grouping)
    }

    static func snapshotAccountsMatch(
        saved: [String], current: [String], allowsSubset: Bool
    ) -> Bool {
        TriageQueueSnapshotStore.snapshotAccountsMatch(saved: saved, current: current, allowsSubset: allowsSubset)
    }
}
