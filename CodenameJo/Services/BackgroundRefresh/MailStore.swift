import Foundation
import GRDB

/// Cached mail, in two tables of `context.sqlite`: GRDB allows one migrator per file, so the schema is
/// registered from `LocalContextStore.migrator`. Never cleared by a context sweep; `DatabasePool` serialises writes.
struct MailStore: Sendable {
    /// One cached message. Metadata as Gmail returned it, flattened.
    struct Message: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
        static let databaseTableName = "mail_message"
        var user_id: String = ""

        /// Gmail's message id, and the primary key. Stable for the life of the message.
        let id: String
        /// Which mailbox this came from.
        let account: String
        let threadId: String
        let sender: String?
        let recipient: String?
        let subject: String?
        /// Gmail's one-line preview; the only body-ish text stored.
        let snippet: String?
        /// Milliseconds since epoch, converted from Gmail's string on ingest.
        let internalDate: Int64?
        /// When this row was last written from Gmail: the freshness a reader shows.
        let cachedAt: Date
        var rfcMessageID: String? = nil
        var inReplyTo: String? = nil
        var referenceHeaders: String? = nil
        var ancestryCached: Bool? = nil

        /// Our importance band (`high`, `normal`, `low`, or nil until scored); what `LocalTriageQueue` walks.
        /// A column, not a `Label` row, because it derives from immutable content and never churns.
        var importanceBand: String? = nil
        /// At most eight words on what this sender needs, for a top-band message only.
        var importanceWhy: String? = nil
        /// 1–10, ordering messages **within** `importanceBand` only. Nil sorts last of its
        /// band rather than first: a message nothing has read must not lead a pile.
        var importanceScore: Int? = nil
        var topicId: String? = nil
        var topicVersion: Int? = nil
        var hasListUnsubscribe: Bool? = nil

        // No `labels` column: labels churn, so they live in `Label` as many-to-many state.
    }

    /// A label on a message: the mutable half of the schema. Unread is the `UNREAD` row, not a boolean.
    struct Label: Codable, FetchableRecord, PersistableRecord, Sendable {
        static let databaseTableName = "mail_message_label"
        var user_id: String = ""

        let messageId: String
        /// Which mailbox's copy this label belongs to. In the key because two accounts can share a raw Gmail id.
        let account: String
        /// Gmail's label id: `INBOX`, `UNREAD`, `STARRED`, or a user label's opaque id.
        let label: String
    }

    /// One cached draft; `messageId` is what a reader passes to `gmail_get_message`.
    /// Wholesale-synced by `applyDrafts`: Gmail has no draft history to diff against.
    struct Draft: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
        static let databaseTableName = "mail_draft"
        var user_id: String = ""

        /// Gmail's draft id, and the primary key. Not the message id.
        let id: String
        let messageId: String
        let threadId: String
        let account: String
        let recipient: String?
        let subject: String?
        let snippet: String?
        let internalDate: Int64?
        let cachedAt: Date
    }

    /// Where each account's delta sync has got to.
    struct SyncState: Codable, FetchableRecord, PersistableRecord, Sendable {
        static let databaseTableName = "mail_sync_state"
        var user_id: String = ""

        let account: String
        /// The watermark `users.history.list` counts from, persisted in the same transaction as its messages.
        let historyId: String?
        let lastSyncedAt: Date

        /// Unused, but kept: a shipped migration added them, and dropping them would make schema and code disagree.
        var backfillPageToken: String?
        var backfillDone: Bool?

        /// Unread count for the whole inbox, not the cached window, from Gmail's label counter.
        var inboxUnread: Int?
    }

    /// A `markRead` that has landed locally, waiting on Gmail. Inserted with the local `UNREAD` clear;
    /// deleted by `BackgroundMailRefresh.flushMarkReadOutbox` once Gmail agrees.
    struct MarkReadOutbox: Codable, FetchableRecord, PersistableRecord, Sendable {
        static let databaseTableName = "mail_mark_read_outbox"
        var user_id: String = ""

        let messageId: String
        /// Which mailbox to retry against.
        let account: String
    }

    private let dbPool: DatabasePool?
    let userId: String

    private var ownerSQL: String { "'" + userId.replacingOccurrences(of: "'", with: "''") + "'" }

    /// Shared only with other durable mail features that use the same migrator and file.
    var database: DatabasePool? { dbPool }

    /// `nil` when the database could not be opened; every method then degrades to a no-op.
    init(database: DatabasePool?, userId: String) {
        self.userId = userId
        dbPool = userId.isEmpty ? nil : database
    }

    /// v27 and v28, as shipped. The sent bodies fed only tone learning; v39 drops both tables.
    static func createSentBodies(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS mail_sent_body (
                user_id TEXT NOT NULL, messageId TEXT NOT NULL, account TEXT NOT NULL,
                payload BLOB NOT NULL, cachedAt DATETIME NOT NULL,
                PRIMARY KEY(user_id, account, messageId),
                FOREIGN KEY(user_id, account, messageId) REFERENCES mail_message(user_id, account, id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS mail_sent_body_account ON mail_sent_body(user_id, account);
            CREATE TABLE IF NOT EXISTS mail_sent_body_sync (
                user_id TEXT NOT NULL, account TEXT NOT NULL, pageToken TEXT,
                complete BOOLEAN NOT NULL DEFAULT 0, forwardToken TEXT, PRIMARY KEY(user_id,account)
            );
            """)
    }

    static func addSentForwardCursor(_ db: Database) throws {
        if try !db.columns(in: "mail_sent_body_sync").contains(where: { $0.name == "forwardToken" }) {
            try db.execute(sql: "ALTER TABLE mail_sent_body_sync ADD COLUMN forwardToken TEXT")
        }
    }

    /// Registered from `LocalContextStore.migrator`, which owns the only migrator for this
    /// file. Defined here so the schema lives beside the code that reads it.
    static func addReplyAncestry(_ db: Database) throws {
        let columns = Set(try db.columns(in: Message.databaseTableName).map(\.name))
        for name in ["rfcMessageID", "inReplyTo", "referenceHeaders"] where !columns.contains(name) {
            try db.alter(table: Message.databaseTableName) { $0.add(column: name, .text) }
        }
        if !columns.contains("ancestryCached") {
            try db.alter(table: Message.databaseTableName) { $0.add(column: "ancestryCached", .boolean) }
        }
    }

    /// Importance bands and the band-major walk's index. Existing rows read as `nil`, the middle band.
    static func addImportance(_ db: Database) throws {
        let columns = Set(try db.columns(in: Message.databaseTableName).map(\.name))
        if !columns.contains("topicId") {
            try db.alter(table: Message.databaseTableName) { $0.add(column: "topicId", .text) }
        }
        if !columns.contains("topicVersion") {
            try db.alter(table: Message.databaseTableName) { $0.add(column: "topicVersion", .integer) }
        }
        for name in ["importanceBand", "importanceWhy"] where !columns.contains(name) {
            try db.alter(table: Message.databaseTableName) { $0.add(column: name, .text) }
        }
        if !columns.contains("importanceScore") {
            try db.alter(table: Message.databaseTableName) { $0.add(column: "importanceScore", .integer) }
        }
        if !columns.contains("hasListUnsubscribe") {
            try db.alter(table: Message.databaseTableName) { $0.add(column: "hasListUnsubscribe", .boolean) }
        }
        try db.create(index: "mail_message_band_idx", on: Message.databaseTableName,
                      columns: ["user_id", "account", "importanceBand", "internalDate"],
                      ifNotExists: true)
    }

    // Unowned cache rows cannot safely be attributed to a user; refresh them from Gmail.
    static func scopeToUsers(_ db: Database) throws {
        for table in ["mail_message_label", "mail_mark_read_outbox", "mail_message_fts",
                      "mail_message", "mail_draft", "mail_sync_state"] {
            try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
        }
        try createUserScopedSchema(db)
    }

    /// Put the mailbox in the key: a raw Gmail id is unique only within one mailbox.
    /// The cache starts clean and refills from Gmail; unconfirmed mark-reads come back as unread.
    static func scopeToMailboxes(_ db: Database) throws {
        try rebuildMailCache(db)
    }


    /// Throw the mail cache away and let the next refresh refill it from Gmail. Everything dropped is
    /// derived except the mark-read outbox, which is unattributable here.
    static func rebuildMailCache(_ db: Database) throws {
        for table in ["mail_message_label", "mail_mark_read_outbox", "mail_sent_body", "mail_message_body",
                      "mail_message_fts", "mail_message", "mail_draft", "mail_sync_state"] {
            try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
        }
        try createUserScopedSchema(db)
    }

    static func discardLegacyUnownedCache(_ db: Database) throws {
        for table in ["mail_message_label", "mail_mark_read_outbox", "mail_message_fts",
                      "mail_message", "mail_draft", "mail_sync_state"] {
            try db.execute(sql: "DROP TABLE IF EXISTS \(table)_legacy_unowned")
        }
    }

    static func createUserScopedSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS mail_message (
                user_id TEXT NOT NULL, id TEXT NOT NULL, account TEXT NOT NULL,
                threadId TEXT NOT NULL, sender TEXT, recipient TEXT, subject TEXT, snippet TEXT,
                internalDate INTEGER, cachedAt DATETIME NOT NULL,
                rfcMessageID TEXT, inReplyTo TEXT, referenceHeaders TEXT, ancestryCached BOOLEAN,
                importanceBand TEXT, importanceWhy TEXT, importanceScore INTEGER, topicId TEXT, topicVersion INTEGER, hasListUnsubscribe BOOLEAN,
                PRIMARY KEY (user_id, account, id)
            );
            CREATE INDEX IF NOT EXISTS mail_message_account_date_idx ON mail_message(user_id, account, internalDate);
            CREATE INDEX IF NOT EXISTS mail_message_thread_idx ON mail_message(user_id, account, threadId);
            CREATE TABLE IF NOT EXISTS mail_message_label (
                user_id TEXT NOT NULL, account TEXT NOT NULL, messageId TEXT NOT NULL, label TEXT NOT NULL,
                PRIMARY KEY (user_id, account, messageId, label),
                FOREIGN KEY (user_id, account, messageId) REFERENCES mail_message(user_id, account, id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS mail_message_label_idx ON mail_message_label(user_id, label);
            CREATE TABLE IF NOT EXISTS mail_draft (
                user_id TEXT NOT NULL, id TEXT NOT NULL, messageId TEXT NOT NULL,
                threadId TEXT NOT NULL, account TEXT NOT NULL, recipient TEXT, subject TEXT,
                snippet TEXT, internalDate INTEGER, cachedAt DATETIME NOT NULL,
                PRIMARY KEY (user_id, account, id)
            );
            CREATE INDEX IF NOT EXISTS mail_draft_account_date_idx ON mail_draft(user_id, account, internalDate);
            CREATE INDEX IF NOT EXISTS mail_draft_account_thread_idx ON mail_draft(user_id, account, threadId);
            CREATE TABLE IF NOT EXISTS mail_sync_state (
                user_id TEXT NOT NULL, account TEXT NOT NULL, historyId TEXT,
                lastSyncedAt DATETIME NOT NULL, backfillPageToken TEXT, backfillDone BOOLEAN,
                inboxUnread INTEGER, PRIMARY KEY (user_id, account)
            );
            CREATE TABLE IF NOT EXISTS mail_mark_read_outbox (
                user_id TEXT NOT NULL, messageId TEXT NOT NULL, account TEXT NOT NULL,
                PRIMARY KEY (user_id, account, messageId),
                FOREIGN KEY (user_id, account, messageId) REFERENCES mail_message(user_id, account, id) ON DELETE CASCADE
            );
            """)
        if try !db.tableExists("mail_message_fts") { try createSearchIndex(db) }
        try createSentBodies(db)
        try createBodies(db)
    }

    static func createSchema(_ db: Database) throws {
        try db.create(table: Message.databaseTableName) { t in
            t.primaryKey("id", .text)
            t.column("account", .text).notNull()
            t.column("threadId", .text).notNull()
            t.column("sender", .text)
            t.column("recipient", .text)
            t.column("subject", .text)
            t.column("snippet", .text)
            // `internalDate` is Gmail's receipt time; the `Date` header is client-supplied and often wrong.
            t.column("internalDate", .integer)
            t.column("cachedAt", .datetime).notNull()
            t.column("rfcMessageID", .text)
            t.column("inReplyTo", .text)
            t.column("referenceHeaders", .text)
            t.column("ancestryCached", .boolean)
        }
        // The list query: one account, newest first.
        try db.create(
            index: "mail_message_account_date_idx",
            on: Message.databaseTableName,
            columns: ["account", "internalDate"]
        )
        try db.create(
            index: "mail_message_thread_idx",
            on: Message.databaseTableName,
            columns: ["threadId"]
        )

        try db.create(table: Label.databaseTableName) { t in
            t.column("messageId", .text)
                .notNull()
                // Cascade in SQLite so no write path can leave orphaned labels.
                .references(Message.databaseTableName, onDelete: .cascade)
            t.column("label", .text).notNull()
            t.primaryKey(["messageId", "label"])
        }
        // Label-first lookups, which the composite primary key cannot serve.
        try db.create(
            index: "mail_message_label_idx",
            on: Label.databaseTableName,
            columns: ["label"]
        )

        try db.create(table: SyncState.databaseTableName) { t in
            t.primaryKey("account", .text)
            t.column("historyId", .text)
            t.column("lastSyncedAt", .datetime).notNull()
        }
    }

    /// The contentless FTS5 index over subject, sender, recipient and snippet, kept current by triggers
    /// so no write path can leave it silently stale.
    static func createSearchIndex(_ db: Database) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE mail_message_fts USING fts5(
                subject, sender, recipient, snippet,
                content='\(Message.databaseTableName)',
                content_rowid='rowid'
            )
            """)
        // Backfill the index so the first search after an upgrade is not empty.
        try db.execute(sql: """
            INSERT INTO mail_message_fts(rowid, subject, sender, recipient, snippet)
            SELECT rowid, subject, sender, recipient, snippet FROM \(Message.databaseTableName)
            """)
        try db.execute(sql: """
            CREATE TRIGGER mail_message_fts_insert AFTER INSERT ON \(Message.databaseTableName)
            BEGIN
                INSERT INTO mail_message_fts(rowid, subject, sender, recipient, snippet)
                VALUES (new.rowid, new.subject, new.sender, new.recipient, new.snippet);
            END
            """)
        // Contentless FTS5 needs the old values to delete a row, or orphaned tokens match forever.
        try db.execute(sql: """
            CREATE TRIGGER mail_message_fts_delete AFTER DELETE ON \(Message.databaseTableName)
            BEGIN
                INSERT INTO mail_message_fts(mail_message_fts, rowid, subject, sender, recipient, snippet)
                VALUES ('delete', old.rowid, old.subject, old.sender, old.recipient, old.snippet);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER mail_message_fts_update AFTER UPDATE ON \(Message.databaseTableName)
            BEGIN
                INSERT INTO mail_message_fts(mail_message_fts, rowid, subject, sender, recipient, snippet)
                VALUES ('delete', old.rowid, old.subject, old.sender, old.recipient, old.snippet);
                INSERT INTO mail_message_fts(rowid, subject, sender, recipient, snippet)
                VALUES (new.rowid, new.subject, new.sender, new.recipient, new.snippet);
            END
            """)
    }

    /// The inbox unread counter, as a new migration because devices already carry the old schema.
    static func createUnreadCounter(_ db: Database) throws {
        try db.alter(table: SyncState.databaseTableName) { t in
            t.add(column: "inboxUnread", .integer)
        }
    }

    /// The backfill cursor. A separate migration: GRDB records applied migrations in the file,
    /// so an edited `v4` would never re-run on a device that already has it.
    static func createBackfillCursor(_ db: Database) throws {
        try db.alter(table: SyncState.databaseTableName) { t in
            t.add(column: "backfillPageToken", .text)
            t.add(column: "backfillDone", .boolean)
        }
    }

    /// The mark-read outbox: a queue of pending work, so rows disappear once Gmail confirms.
    static func createMarkReadOutbox(_ db: Database) throws {
        try db.create(table: MarkReadOutbox.databaseTableName) { t in
            t.primaryKey("messageId", .text)
            t.column("account", .text).notNull()
        }
    }

    /// Recreates the outbox with a cascade to its message, so purging an account drops its pending rows.
    /// SQLite can't add a foreign key in place; dropping is safe because the local `UNREAD` clear already landed.
    static func createMarkReadOutboxForeignKey(_ db: Database) throws {
        try db.drop(table: MarkReadOutbox.databaseTableName)
        try db.create(table: MarkReadOutbox.databaseTableName) { t in
            t.column("messageId", .text).notNull()
                .references(Message.databaseTableName, onDelete: .cascade)
            t.column("account", .text).notNull()
            t.primaryKey(["messageId"])
        }
    }

    /// The drafts table, mirrored wholesale (see `Draft`).
    static func createDraftsSchema(_ db: Database) throws {
        try db.create(table: Draft.databaseTableName) { t in
            t.primaryKey("id", .text)
            t.column("messageId", .text).notNull()
            t.column("threadId", .text).notNull()
            t.column("account", .text).notNull()
            t.column("recipient", .text)
            t.column("subject", .text)
            t.column("snippet", .text)
            t.column("internalDate", .integer)
            t.column("cachedAt", .datetime).notNull()
        }
        // The list query: one account (or every account), newest first.
        try db.create(
            index: "mail_draft_account_date_idx",
            on: Draft.databaseTableName,
            columns: ["account", "internalDate"]
        )
    }

    // MARK: - Writing

    /// Apply one pass: upsert, drop what Gmail says is gone, and move the watermark in one transaction.
    /// A `historyId` written outside it would skip the gap's messages forever if iOS kills the pass.
    func apply(
        _ batch: [Ingest], deletedIds: [String] = [], account: String, historyId: String?,
        inboxUnread: Int? = nil
    ) async {
        guard let dbPool else { return }
        do {
            try await dbPool.write { db in
                for item in batch { try write(item, db) }
                if !deletedIds.isEmpty {
                    // The label rows go too, by the cascade declared in the schema.
                    try Message.filter(Column("user_id") == userId)
                        .filter(deletedIds.contains(Column("id")))
                        .deleteAll(db)
                }
                // Preserve the backfill cursor; a fresh `SyncState` would blank it.
                let existing = try SyncState.filter(Column("user_id") == userId).filter(Column("account") == account).fetchOne(db)
                try SyncState(
                    user_id: userId, account: account,
                    historyId: historyId,
                    lastSyncedAt: Date(),
                    backfillPageToken: existing?.backfillPageToken,
                    backfillDone: existing?.backfillDone,
                    inboxUnread: inboxUnread ?? existing?.inboxUnread
                ).save(db)
            }
        } catch {
            // Soft: a background pass must not crash because SQLite was busy.
            print("[mail] write failed: \(error)")
        }
    }

    /// One message and its labels, inside a caller's transaction.
    ///
    /// Labels are replaced wholesale: Gmail returns the complete set, and a merge would never drop a removed label.
    private func write(_ item: Ingest, _ db: Database) throws {
        // Upsert, keeping the importance and topic fields already scored.
        var message = item.message
        message.user_id = userId
        if let existing = try Message.filter(Column("user_id") == userId)
            .filter(Column("account") == message.account).filter(Column("id") == message.id).fetchOne(db) {
            message.importanceBand = existing.importanceBand
            message.importanceWhy = existing.importanceWhy
            message.importanceScore = existing.importanceScore
            message.topicId = existing.topicId
            message.topicVersion = existing.topicVersion
        }
        try message.save(db)
        try Label.filter(Column("user_id") == userId).filter(Column("account") == item.message.account)
            .filter(Column("messageId") == item.message.id).deleteAll(db)
        for label in item.labels {
            try Label(user_id: userId, messageId: item.message.id,
                      account: item.message.account, label: label).insert(db)
        }
    }

    // MARK: - Drafts

    /// Replace one account's cached drafts wholesale.
    func applyDrafts(_ drafts: [Draft], account: String) async {
        guard let dbPool else { return }
        do {
            try await dbPool.write { db in
                try Draft.filter(Column("user_id") == userId).filter(Column("account") == account).deleteAll(db)
                for var draft in drafts { draft.user_id = userId; try draft.insert(db) }
            }
        } catch {
            print("[mail] draft write failed: \(error)")
        }
    }

    /// Upsert drafts without touching the rest of the account's cache.
    ///
    /// For a live search miss, not a sync: replacing on a partial listing would delete the other drafts.
    func cacheDrafts(_ drafts: [Draft]) async {
        guard let dbPool, !drafts.isEmpty else { return }
        try? await dbPool.write { db in
            for var draft in drafts { draft.user_id = userId; try draft.save(db) }
        }
    }

    static func createDraftThreadIndex(_ db: Database) throws {
        try db.create(index: "mail_draft_account_thread_idx", on: Draft.databaseTableName,
                      columns: ["account", "threadId"], ifNotExists: true)
    }

    func draftThreadIDs(account: String, among threads: Set<String>) async -> Set<String>? {
        guard !threads.isEmpty else { return [] }
        guard let dbPool else {
            RealtimeLog.log("mailStore: draft thread state unavailable — no database")
            return nil
        }
        do {
            return try await dbPool.read { db in
                var result = Set<String>()
                let ids = Array(threads)
                for start in stride(from: 0, to: ids.count, by: 500) {
                    let chunk = Array(ids[start..<min(start + 500, ids.count)])
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    result.formUnion(try String.fetchAll(db,
                        sql: "SELECT DISTINCT threadId FROM mail_draft WHERE user_id = \(ownerSQL) AND account = ? AND threadId IN (\(placeholders))",
                        arguments: StatementArguments([account] + chunk)))
                }
                return result
            }
        } catch {
            RealtimeLog.log("mailStore: draft thread lookup failed — \(error)")
            return nil
        }
    }

    /// Newest first. One mailbox, or every cached mailbox interleaved by date when `account`
    /// is nil — the same convention `unread(limit:account:)` uses.
    func drafts(account: String? = nil, limit: Int = 8) async -> [Draft] {
        await draftState(account: account, limit: limit) ?? []
    }

    func draftState(account: String? = nil, limit: Int = 8) async -> [Draft]? {
        guard let dbPool else {
            RealtimeLog.log("mailStore: draft state unavailable — no database")
            return nil
        }
        do {
            return try await dbPool.read { db in
                try Draft.fetchAll(db,
                    sql: """
                        SELECT * FROM \(Draft.databaseTableName)
                         WHERE user_id = \(ownerSQL) AND (? IS NULL OR account = ?)
                         ORDER BY internalDate DESC
                         LIMIT ?
                        """,
                    arguments: [account, account, limit])
            }
        } catch {
            RealtimeLog.log("mailStore: draft state lookup failed — \(error)")
            return nil
        }
    }

    /// Drafts whose recipient, subject or snippet mention every term in `query`.
    ///
    /// A plain `LIKE`: drafts are too few for an FTS index to pay for itself.
    func searchDrafts(_ query: String, account: String? = nil, limit: Int = 8) async -> [Draft] {
        guard let dbPool else { return [] }
        let terms = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count > 1 }
        guard !terms.isEmpty else { return await drafts(account: account, limit: limit) }

        let clauses = terms
            .map { _ in "(lower(subject) LIKE ? OR lower(recipient) LIKE ? OR lower(snippet) LIKE ?)" }
            .joined(separator: " AND ")
        var arguments: [String?] = terms.flatMap { term in
            Array(repeating: "%\(term)%", count: 3)
        }
        arguments.append(contentsOf: [account, account])

        return (try? await dbPool.read { db in
            try Draft.fetchAll(
                db,
                sql: """
                    SELECT * FROM \(Draft.databaseTableName)
                     WHERE user_id = \(ownerSQL) AND \(clauses) AND (? IS NULL OR account = ?)
                     ORDER BY internalDate DESC
                     LIMIT ?
                    """,
                arguments: StatementArguments(arguments) + StatementArguments([limit])
            )
        }) ?? []
    }

    /// Every cached draft for one mailbox, keyed by id — what a sync diffs against to skip
    /// re-fetching a draft nothing has changed since the last pass.
    func draftsById(account: String) async -> [String: Draft] {
        guard let dbPool else { return [:] }
        let rows = (try? await dbPool.read { db in
            try Draft.filter(Column("user_id") == userId).filter(Column("account") == account).fetchAll(db)
        }) ?? []
        return Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// How many drafts are cached — one mailbox, or every one. Diagnostics, like `count()`.
    func draftCount(account: String? = nil) async -> Int {
        guard let dbPool else { return 0 }
        return (try? await dbPool.read { db -> Int in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM \(Draft.databaseTableName)
                     WHERE user_id = \(ownerSQL) AND (? IS NULL OR account = ?)
                    """,
                arguments: [account, account]
            ) ?? 0
        }) ?? 0
    }

    // MARK: - Reading

    /// Write messages without touching the watermark.
    ///
    /// For a search, not a sync: `apply` would advance `historyId` past mail the delta hasn't seen.
    func cache(_ batch: [Ingest]) async {
        guard let dbPool, !batch.isEmpty else { return }
        do {
            try await dbPool.write { db in
                for item in batch { try write(item, db) }
            }
        } catch {
            print("[mail] cache write failed: \(error)")
        }
    }

    /// Which of these are already stored.
    ///
    /// A stored message that has since been read still matches, so the delta updates its row rather than dropping it.
    func existingIds(among ids: [String]) async -> Set<String> {
        guard let dbPool, !ids.isEmpty else { return [] }
        return (try? await dbPool.read { db in
            let rows = try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM \(Message.databaseTableName)
                    WHERE user_id = \(ownerSQL) AND id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                    """,
                arguments: StatementArguments(ids)
            )
            return Set(rows)
        }) ?? []
    }

    /// Stored messages we hold as unread that are **not** in the given set.
    ///
    /// Gmail just listed every unread id, so anything still `UNREAD` here and absent there was read elsewhere.
    /// `live` must be the whole inbox's unread set for `account`; a partial set silently marks the rest read.
    func unreadIdsNotIn(_ live: Set<String>, account: String) async -> [String] {
        guard let dbPool else { return [] }
        return (try? await dbPool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT l.messageId FROM \(Label.databaseTableName) l
                      JOIN \(Message.databaseTableName) m ON m.id = l.messageId AND m.user_id = l.user_id
                     WHERE l.user_id = \(ownerSQL) AND l.label = 'UNREAD' AND m.account = ?
                    """,
                arguments: [account]
            )
        })?.filter { !live.contains($0) } ?? []
    }

    /// Drop the `UNREAD` label from these messages, keeping the messages.
    ///
    /// Not a delete: read mail stays cached.
    func clearUnread(_ ids: [String]) async {
        guard let dbPool, !ids.isEmpty else { return }
        try? await dbPool.write { db in
            try db.execute(
                sql: """
                    DELETE FROM \(Label.databaseTableName)
                     WHERE user_id = \(ownerSQL) AND label = 'UNREAD'
                       AND messageId IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                    """,
                arguments: StatementArguments(ids)
            )
        }
    }

    /// Stored messages we hold in the inbox, inside `since`, that are **not** in the given set.
    ///
    /// `live` is every id Gmail lists for `in:inbox newer_than:7d`, so the check is bounded by `since`
    /// or anything outside the window would read as archived.
    func inboxIdsNotIn(_ live: Set<String>, account: String, since: Int64) async -> [String] {
        guard let dbPool else { return [] }
        return (try? await dbPool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT l.messageId FROM \(Label.databaseTableName) l
                      JOIN \(Message.databaseTableName) m ON m.id = l.messageId AND m.user_id = l.user_id
                     WHERE l.user_id = \(ownerSQL) AND l.label = 'INBOX' AND m.account = ?
                       AND m.internalDate >= ?
                    """,
                arguments: [account, since]
            )
        })?.filter { !live.contains($0) } ?? []
    }

    /// Drop the `INBOX` label from these messages, keeping the messages — they were archived.
    func clearInbox(_ ids: [String]) async {
        guard let dbPool, !ids.isEmpty else { return }
        try? await dbPool.write { db in
            try db.execute(
                sql: """
                    DELETE FROM \(Label.databaseTableName)
                     WHERE user_id = \(ownerSQL) AND label = 'INBOX'
                       AND messageId IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                    """,
                arguments: StatementArguments(ids)
            )
        }
    }

    /// Inbox mail nothing has banded yet, newest first: unread mail of any age plus read mail inside
    /// the important scope's week, never sent-to-self.
    func unscored(account: String, limit: Int) async -> [Message] {
        guard let dbPool else { return [] }
        return (try? await dbPool.read { db in
            try Message.fetchAll(
                db,
                sql: """
                    SELECT m.* FROM \(Message.databaseTableName) m
                     WHERE m.user_id = \(ownerSQL) AND m.account = ? AND (m.importanceBand IS NULL OR COALESCE(m.topicVersion, 0) < 1)
                       AND (m.internalDate >= ? OR EXISTS (SELECT 1 FROM \(Label.databaseTableName) l
                                    WHERE l.user_id = m.user_id AND l.account = m.account
                                      AND l.messageId = m.id AND l.label = 'UNREAD'))
                       AND NOT (\(Self.fromSelfSQL))
                       AND EXISTS (SELECT 1 FROM \(Label.databaseTableName) inbox
                                    WHERE inbox.user_id = m.user_id AND inbox.account = m.account
                                      AND inbox.messageId = m.id AND inbox.label = 'INBOX')
                     ORDER BY (m.importanceBand IS NULL) DESC, m.internalDate DESC
                     LIMIT ?
                    """,
                arguments: [account, Self.importantSince(), limit]
            )
        }) ?? []
    }

    func applyTopics(_ topics: [String: String], version: Int, account: String) async {
        guard let dbPool, version == 1 else { return }
        do {
            try await dbPool.write { db in
                for (id, topic) in topics {
                    try db.execute(sql: "UPDATE \(Message.databaseTableName) SET topicId=?, topicVersion=? WHERE user_id=\(ownerSQL) AND account=? AND id=?",
                        arguments: [topic, version, account, id])
                }
            }
        } catch { RealtimeLog.log("mailStore: topic persistence failed — \(error)") }
    }

    /// Already-classified mail from these senders, newest first: the topics a new message may join.
    func topicCandidates(account: String, senders: [String], limit: Int = 100) async -> [Message]? {
        guard let dbPool else { return nil }
        guard !senders.isEmpty else { return [] }
        do {
            let rows = try await dbPool.read { db in
                try Message.fetchAll(db, sql: """
                    SELECT m.* FROM \(Message.databaseTableName) m
                     WHERE m.user_id=\(ownerSQL) AND m.account=? AND m.topicVersion=1 AND m.topicId IS NOT NULL
                       AND (\(senders.map { _ in "instr(lower(COALESCE(m.sender, '')), ?) > 0" }.joined(separator: " OR ")))
                     ORDER BY m.internalDate DESC, m.id LIMIT ?
                    """, arguments: StatementArguments([account] + senders + [limit * 4]))
            }
            let wanted = Set(senders)
            return Array(rows.filter { wanted.contains(MailTopics.sender($0.sender ?? "")) }.prefix(limit))
        } catch {
            RealtimeLog.log("mailStore: topic candidates unavailable — \(error)")
            return nil
        }
    }

    func topicSiblings(of messages: [Message]) async -> [Message] {
        guard let dbPool else { return [] }
        let accountTopics = Dictionary(grouping: messages.filter { $0.topicVersion == 1 && $0.topicId != nil }, by: \.account)
        do {
            return try await dbPool.read { db in
                var result: [Message] = []
                for (account, members) in accountTopics {
                    let topics = Array(Set(members.compactMap(\.topicId)))
                    result += try Message.fetchAll(db, sql: """
                        SELECT m.* FROM \(Message.databaseTableName) m
                         WHERE m.user_id=\(ownerSQL) AND m.account=? AND m.topicVersion=1
                           AND m.topicId IN (\(topics.map { _ in "?" }.joined(separator: ",")))
                           AND EXISTS (SELECT 1 FROM \(Label.databaseTableName) l
                               WHERE l.user_id=m.user_id AND l.account=m.account AND l.messageId=m.id AND l.label='UNREAD')
                           AND EXISTS (SELECT 1 FROM \(Label.databaseTableName) l
                               WHERE l.user_id=m.user_id AND l.account=m.account AND l.messageId=m.id AND l.label='INBOX')
                        """, arguments: StatementArguments([account] + topics))
                }
                return result
            }
        } catch { RealtimeLog.log("mailStore: topic siblings unavailable — \(error)"); return [] }
    }

    func importanceLabels(account: String, ids: [String]) async -> [String: [String]]? {
        guard let dbPool else { return nil }
        guard !ids.isEmpty else { return [:] }
        do {
            return try await dbPool.read { db in
                let rows = try Label.filter(Column("user_id") == self.userId)
                    .filter(Column("account") == account).filter(ids.contains(Column("messageId"))).fetchAll(db)
                return Dictionary(grouping: rows, by: \.messageId).mapValues { $0.map(\.label) }
            }
        } catch {
            RealtimeLog.log("importance: cached labels unavailable — \(error)")
            return nil
        }
    }

    /// Is there banded mail still unread and in the inbox? False means the walk pages in date order.
    func hasBands(account: String) async -> Bool {
        guard let dbPool else { return false }
        let found = try? await dbPool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS (
                      SELECT 1 FROM \(Message.databaseTableName) m
                       WHERE m.user_id = \(ownerSQL) AND m.account = ?
                         AND m.importanceBand IS NOT NULL
                         AND EXISTS (SELECT 1 FROM \(Label.databaseTableName) l
                                      WHERE l.user_id = m.user_id AND l.account = m.account
                                        AND l.messageId = m.id AND l.label = 'UNREAD')
                         AND EXISTS (SELECT 1 FROM \(Label.databaseTableName) i
                                      WHERE i.user_id = m.user_id AND i.account = m.account
                                        AND i.messageId = m.id AND i.label = 'INBOX'))
                    """,
                arguments: [account]
            )
        }
        return found.flatMap { $0 } ?? false
    }

    /// Store bands for messages already in the cache.
    ///
    /// Only ever an UPDATE: a band for an uncached message would create an invisible, never-rescored row.
    func applyBands(_ bands: [String: (band: String, why: String, score: Int?)], account: String) async {
        guard let dbPool, !bands.isEmpty else { return }
        do {
            try await dbPool.write { db in
                for (id, verdict) in bands {
                    try db.execute(
                        sql: """
                            UPDATE \(Message.databaseTableName)
                               SET importanceBand = ?, importanceWhy = ?, importanceScore = ?
                             WHERE user_id = \(ownerSQL) AND account = ? AND id = ?
                            """,
                        arguments: [verdict.band, verdict.why.isEmpty ? nil : verdict.why,
                                    verdict.score, account, id]
                    )
                }
            }
        } catch {
            RealtimeLog.log("mailStore: banding \(bands.count) message(s) failed — \(error)")
        }
    }

    /// Clear unread locally and record that Gmail still needs telling, in one transaction so a
    /// local clear is always retried. Logged on failure, unlike `clearUnread`.
    func clearUnreadDurably(id: String, account: String) async {
        guard let dbPool else { return }
        do {
            try await dbPool.write { db in
                // Scoped to the mailbox: the same raw id can exist in another inbox.
                try db.execute(
                    sql: """
                        DELETE FROM \(Label.databaseTableName)
                         WHERE user_id = \(ownerSQL) AND label = 'UNREAD' AND messageId = ?
                           AND LOWER(account) = LOWER(?)
                        """,
                    arguments: [id, account])
                try MarkReadOutbox(user_id: userId, messageId: id, account: account).save(db)
            }
        } catch {
            print("[mail] durable mark-read write failed for \(id): \(error)")
        }
    }

    /// Every message for this mailbox still waiting on Gmail to confirm it was read.
    func pendingMarkReads(account: String) async -> [MarkReadOutbox] {
        guard let dbPool else { return [] }
        return (try? await dbPool.read { db in
            try MarkReadOutbox.filter(Column("user_id") == userId).filter(Column("account") == account).fetchAll(db)
        }) ?? []
    }

    /// Gmail confirmed it — the row's whole job is done.
    func removeMarkReadOutbox(_ id: String) async {
        guard let dbPool else { return }
        try? await dbPool.write { db in
            try MarkReadOutbox.filter(Column("user_id") == userId).filter(Column("messageId") == id).deleteAll(db)
        }
    }

    /// Drop a message from the unread set and decrement `inboxUnread` by the rows actually deleted,
    /// floored at zero; unlike `clearUnread`, nothing repairs the count mid-call.
    func confirmedEffectIDs(_ effect: GmailWriteEffect) async -> Set<String> {
        var ids = Set(effect.messageIds)
        guard !effect.messageIdsComplete, effect.scope == "thread", let thread = effect.threadId,
              let dbPool else { return ids }
        do {
            let cached = try await dbPool.read { db in
                try String.fetchAll(db, sql: "SELECT id FROM \(Message.databaseTableName) WHERE user_id = \(ownerSQL) AND LOWER(account) = LOWER(?) AND threadId = ?",
                                    arguments: [effect.account, thread])
            }
            ids.formUnion(cached)
        } catch { RealtimeLog.log("gmail effects: thread lookup failed — \(error)") }
        return ids
    }

    func applyConfirmedEffect(_ effect: GmailWriteEffect, ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        guard let dbPool else {
            RealtimeLog.log("gmail effects: cache unavailable")
            return
        }
        do {
            try await dbPool.write { db in
                var unreadDelta = 0
                for id in ids {
                    guard try Message.filter(Column("user_id") == userId).filter(Column("id") == id)
                        .filter(sql: "LOWER(account) = LOWER(?)", arguments: [effect.account]).fetchOne(db) != nil else { continue }
                    let before = Set(try String.fetchAll(db,
                        sql: "SELECT label FROM \(Label.databaseTableName) WHERE user_id = \(ownerSQL) "
                            + "AND LOWER(account) = LOWER(?) AND messageId = ?",
                        arguments: [effect.account, id]))
                    var after = before.subtracting(effect.removed).union(effect.added)
                    if effect.isDeletion { after = [] }
                    unreadDelta += (after.contains("INBOX") && after.contains("UNREAD") ? 1 : 0)
                        - (before.contains("INBOX") && before.contains("UNREAD") ? 1 : 0)
                    try Label.filter(Column("user_id") == userId).filter(Column("messageId") == id)
                        .filter(sql: "LOWER(account) = LOWER(?)", arguments: [effect.account]).deleteAll(db)
                    for label in after {
                        try Label(user_id: userId, messageId: id, account: effect.account, label: label).insert(db)
                    }
                    if effect.isDeletion {
                        try Message.filter(Column("user_id") == userId).filter(Column("id") == id)
                            .filter(sql: "LOWER(account) = LOWER(?)", arguments: [effect.account]).deleteAll(db)
                    }
                }
                try db.execute(sql: """
                    UPDATE \(SyncState.databaseTableName)
                       SET inboxUnread = MAX(0, inboxUnread + ?)
                     WHERE user_id = \(ownerSQL) AND LOWER(account) = LOWER(?)
                    """, arguments: [unreadDelta, effect.account])
            }
        } catch { RealtimeLog.log("gmail effects: cache reconciliation failed — \(error)") }
    }

    func dropUnread(_ ids: [String], account: String? = nil) async {
        guard let dbPool, !ids.isEmpty else { return }
        try? await dbPool.write { db in
            try db.execute(
                sql: """
                    DELETE FROM \(Label.databaseTableName)
                     WHERE user_id = \(ownerSQL) AND label = 'UNREAD'
                       AND messageId IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                       AND (? IS NULL OR messageId IN (
                           SELECT id FROM \(Message.databaseTableName) WHERE user_id = \(ownerSQL) AND LOWER(account) = LOWER(?)
                       ))
                    """,
                arguments: StatementArguments(ids) + StatementArguments([account, account])
            )
            let removed = db.changesCount
            guard removed > 0 else { return }
            try db.execute(
                sql: """
                    UPDATE \(SyncState.databaseTableName)
                       SET inboxUnread = MAX(0, inboxUnread - ?)
                     WHERE user_id = \(ownerSQL) AND inboxUnread IS NOT NULL AND (? IS NULL OR LOWER(account) = LOWER(?))
                    """,
                arguments: StatementArguments([removed]) + StatementArguments([account, account])
            )
        }
    }

    /// Which of these are unread.
    func unreadIds(among ids: [String]) async -> Set<String> {
        await unreadState(among: ids) ?? []
    }

    // Nil means the cache could not answer; an empty set is a successful all-read result.
    func unreadState(among ids: [String]) async -> Set<String>? {
        guard !ids.isEmpty else { return [] }
        guard let dbPool else {
            RealtimeLog.log("mailStore: unread state unavailable — no database")
            return nil
        }
        do {
            return try await dbPool.read { db in
                let rows = try String.fetchAll(db,
                    sql: """
                        SELECT messageId FROM \(Label.databaseTableName)
                        WHERE user_id = \(ownerSQL) AND label = 'UNREAD' AND messageId IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                        """,
                    arguments: StatementArguments(ids))
                return Set(rows)
            }
        } catch {
            RealtimeLog.log("mailStore: unread state lookup failed — \(error)")
            return nil
        }
    }

    /// Which of these are unread and still in the inbox; a cached row outlives an archive done elsewhere.
    func unreadInboxIds(among ids: [String]) async -> Set<String>? {
        guard let unread = await unreadState(among: ids), let inbox = await inboxIds(among: ids) else { return nil }
        return unread.intersection(inbox)
    }

    func inboxIds(among ids: [String], account: String? = nil) async -> Set<String>? {
        guard !ids.isEmpty else { return [] }
        guard let dbPool else {
            RealtimeLog.log("mailStore: eligibility unavailable — no database")
            return nil
        }
        do {
            return try await dbPool.read { db in
                let rows = try String.fetchAll(
                    db,
                    sql: """
                        SELECT messageId FROM \(Label.databaseTableName)
                        WHERE user_id = \(ownerSQL) AND label = 'INBOX' AND messageId IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                        """ + (account == nil ? "" : " AND LOWER(account) = LOWER(?)"),
                    arguments: StatementArguments(ids + (account.map { [$0] } ?? []))
                )
                return Set(rows)
            }
        } catch {
            RealtimeLog.log("mailStore: eligibility lookup failed — \(error)")
            return nil
        }
    }

    /// Which of these are still in the important scope, so a restored queue skips archived, answered or aged-out mail.
    func importantIds(among ids: [String]) async -> Set<String>? {
        guard !ids.isEmpty else { return [] }
        guard let dbPool else {
            RealtimeLog.log("mailStore: eligibility unavailable — no database")
            return nil
        }
        do {
            return try await dbPool.read { db in
                let rows = try String.fetchAll(
                    db,
                    sql: """
                        SELECT m.id FROM \(Message.databaseTableName) m
                         WHERE m.user_id = \(ownerSQL)
                           AND m.id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                           AND EXISTS (SELECT 1 FROM \(Label.databaseTableName) inbox
                                        WHERE inbox.user_id = m.user_id AND inbox.account = m.account
                                          AND inbox.messageId = m.id AND inbox.label = 'INBOX')
                           AND \(Self.importantWeekSQL)
                        """,
                    arguments: StatementArguments(ids + [Self.importantSince()])
                )
                return Set(rows)
            }
        } catch {
            RealtimeLog.log("mailStore: eligibility lookup failed — \(error)")
            return nil
        }
    }

    /// How many messages the important scope holds across these mailboxes, off disc.
    /// The cache is the authority for this scope; the week listing and `INBOX` reconcile keep it current.
    func importantCount(accounts: [String]) async -> Int? {
        guard let dbPool, !accounts.isEmpty else { return nil }
        return try? await dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM \(Message.databaseTableName) m
                     WHERE m.user_id = \(ownerSQL)
                       AND lower(m.account) IN (\(accounts.map { _ in "?" }.joined(separator: ",")))
                       AND EXISTS (SELECT 1 FROM \(Label.databaseTableName) inbox
                                    WHERE inbox.user_id = m.user_id AND inbox.account = m.account
                                      AND inbox.messageId = m.id AND inbox.label = 'INBOX')
                       AND \(Self.importantWeekSQL)
                    """,
                arguments: StatementArguments(accounts.map { $0.lowercased() } + [Self.importantSince()])
            ) ?? 0
        }
    }

    /// The important week has mail, all of it scored and none of it high. False when unreadable.
    func weekHasNothingImportant(accounts: [String]) async -> Bool {
        guard let dbPool, !accounts.isEmpty else { return false }
        return (try? await dbPool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) > 0 AND SUM(m.importanceBand IS NULL OR m.importanceBand = 'high') = 0
                      FROM \(Message.databaseTableName) m
                     WHERE m.user_id = \(ownerSQL)
                       AND lower(m.account) IN (\(accounts.map { _ in "?" }.joined(separator: ",")))
                       AND EXISTS (SELECT 1 FROM \(Label.databaseTableName) inbox
                                    WHERE inbox.user_id = m.user_id AND inbox.account = m.account
                                      AND inbox.messageId = m.id AND inbox.label = 'INBOX')
                       AND \(Self.importantWeekSQL)
                    """,
                arguments: StatementArguments(accounts.map { $0.lowercased() } + [Self.importantSince()])
            )
        }) ?? false
    }

    /// The important scope's window: the past week of the inbox.
    static let importantWindow: TimeInterval = 7 * 24 * 60 * 60

    /// The oldest `internalDate`, in milliseconds, the important scope still holds.
    static func importantSince(now: Date = Date()) -> Int64 {
        Int64((now.timeIntervalSince1970 - importantWindow) * 1000)
    }

    /// Row `m` was sent by its own mailbox. The address is matched whole: a substring would take `dan@x.com` for `an@x.com`.
    static let fromSelfSQL = """
        lower(trim(COALESCE(m.sender, ''))) = lower(m.account)
        OR instr(lower(COALESCE(m.sender, '')), '<' || lower(m.account) || '>') > 0
        """

    /// What the important scope keeps of an inbox row `m`: this week, not from self, any band, not already
    /// answered (no later `SENT` in the thread). One `?`: the `importantSince()` cutoff.
    static let importantWeekSQL = """
        m.internalDate >= ?
        AND NOT (\(fromSelfSQL))
        AND NOT EXISTS (SELECT 1 FROM \(Message.databaseTableName) s
                          JOIN \(Label.databaseTableName) sent
                            ON sent.user_id = s.user_id AND sent.account = s.account
                           AND sent.messageId = s.id AND sent.label = 'SENT'
                         WHERE s.user_id = m.user_id AND s.account = m.account
                           AND s.threadId = m.threadId AND s.internalDate > m.internalDate)
        """

    func cachedMailbox(messageId: String) async -> String? {
        guard let dbPool else {
            RealtimeLog.log("mailStore: message mailbox unavailable — no database")
            return nil
        }
        do {
            let accounts = try await dbPool.read { db in
                try String.fetchAll(db, sql: "SELECT DISTINCT account FROM \(Message.databaseTableName) WHERE user_id = \(ownerSQL) AND id = ?",
                                    arguments: [messageId])
            }
            return accounts.count == 1 ? accounts.first : nil
        } catch {
            RealtimeLog.log("mailStore: message mailbox lookup failed — \(error)")
            return nil
        }
    }

    /// Stored messages by id, unordered and unfiltered: the caller already decided membership.
    /// Pass `account`: an archive is keyed on `Message.account`, so a row from another mailbox misroutes it.
    func messages(ids: [String], account: String? = nil) async -> [Message] {
        guard let dbPool, !ids.isEmpty else { return [] }
        return (try? await dbPool.read { db in
            try Message.fetchAll(
                db,
                sql: """
                    SELECT * FROM \(Message.databaseTableName)
                     WHERE user_id = \(ownerSQL) AND id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                       AND (? IS NULL OR account = ?)
                    """,
                arguments: StatementArguments(ids) + StatementArguments([account, account])
            )
        }) ?? []
    }

    /// The watermark for an account; nil means it has never synced, so the refresh seeds.
    func syncState(account: String) async -> SyncState? {
        guard let dbPool else { return nil }
        return try? await dbPool.read { db in
            try SyncState.filter(Column("user_id") == userId).filter(Column("account") == account).fetchOne(db)
        }
    }

    /// The newest unread messages, no query, filtered on `UNREAD` because read mail stays cached.
    /// `account` nil interleaves every cached mailbox by date.
    func unread(limit: Int = 8, account: String? = nil) async -> [Message] {
        guard let dbPool else { return [] }
        return (try? await dbPool.read { db in
            try Message.fetchAll(
                db,
                sql: """
                    SELECT m.* FROM \(Message.databaseTableName) m
                     WHERE m.user_id = \(ownerSQL) AND EXISTS (SELECT 1 FROM \(Label.databaseTableName) l
                                    WHERE l.user_id = m.user_id AND l.account = m.account AND l.messageId = m.id AND l.label = 'UNREAD')
                       AND EXISTS (SELECT 1 FROM \(Label.databaseTableName) inbox
                                    WHERE inbox.user_id = m.user_id AND inbox.account = m.account AND inbox.messageId = m.id AND inbox.label = 'INBOX')
                       AND (? IS NULL OR m.account = ?)
                     ORDER BY m.internalDate DESC
                     LIMIT ?
                    """,
                arguments: [account, account, limit]
            )
        }) ?? []
    }

    /// The newest cached messages, read or unread.
    /// Arrival order, so a message already opened still counts.
    /// - Parameter account: one mailbox, or nil for every cached mailbox interleaved by date.
    func recent(limit: Int = 8, account: String? = nil) async -> [Message] {
        guard let dbPool else { return [] }
        return (try? await dbPool.read { db in
            try Message.fetchAll(
                db,
                sql: """
                    SELECT m.* FROM \(Message.databaseTableName) m
                     WHERE m.user_id = \(ownerSQL) AND (? IS NULL OR m.account = ?)
                     ORDER BY m.internalDate DESC
                     LIMIT ?
                    """,
                arguments: [account, account, limit]
            )
        }) ?? []
    }

    /// One page of unread mail older than a watermark, newest first. `before` is exclusive `internalDate` ms.
    /// A score-ordered band walk must page on `(score, internalDate, id)` via `beforeScore`, not on date alone.
    func unreadPage(
        before: Int64?, limit: Int, importantOnly: Bool = false, account: String? = nil,
        band: String? = nil, beforeScore: Int? = nil, beforeID: String? = nil,
        importanceOrder: Bool = false
    ) async -> [Message] {
        guard let dbPool else { return [] }
        return (try? await dbPool.read { db in
            try Message.fetchAll(
                db,
                sql: """
                    SELECT m.* FROM \(Message.databaseTableName) m
                     WHERE m.user_id = \(ownerSQL) AND (? = 1 OR EXISTS (SELECT 1 FROM \(Label.databaseTableName) l
                                    WHERE l.user_id = m.user_id AND l.account = m.account AND l.messageId = m.id AND l.label = 'UNREAD'))
                       AND EXISTS (SELECT 1 FROM \(Label.databaseTableName) inbox
                                    WHERE inbox.user_id = m.user_id AND inbox.account = m.account AND inbox.messageId = m.id AND inbox.label = 'INBOX')
                       AND (? = 0 OR (\(Self.importantWeekSQL)))
                       AND (? IS NULL OR m.internalDate < ?)
                       AND (? IS NULL OR
                            (COALESCE(m.importanceScore, 0), COALESCE(m.internalDate, 0), m.id) < (?, ?, ?))
                       AND (? IS NULL OR m.account = ?)
                       AND (? IS NULL OR COALESCE(m.importanceBand, ?) = ?)
                     ORDER BY CASE WHEN ? = 1 THEN
                                  CASE COALESCE(m.importanceBand, 'normal') WHEN 'high' THEN 0 WHEN 'low' THEN 2 ELSE 1 END
                                  ELSE 0 END,
                              CASE WHEN ? = 1 THEN COALESCE(m.importanceScore, 0) ELSE 0 END DESC,
                              COALESCE(m.internalDate, 0) DESC, m.id DESC
                     LIMIT ?
                    """,
                // The two cursors are exclusive: a band walk passes nil for the date-only one.
                arguments: [importantOnly ? 1 : 0, importantOnly ? 1 : 0, Self.importantSince(),
                            beforeScore == nil ? before : nil, beforeScore == nil ? before : nil,
                            beforeScore, beforeScore, before, beforeID ?? "",
                            account, account,
                            band, MailImportance.unscoredBand, band,
                            importanceOrder ? 1 : 0, (band != nil || importanceOrder) ? 1 : 0, limit]
            )
        }) ?? []
    }

    /// Cached messages matching every term of `query` as a prefix (FTS5 tokenises exactly), newest first.
    /// A blank query falls back to `unread()`; otherwise read mail matches too.
    func search(_ query: String, limit: Int = 8, account: String? = nil) async -> [Message] {
        guard let dbPool else { return [] }
        let terms = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count > 1 && !Self.stopWords.contains(String($0)) }
            .map { "\($0)*" }
        guard !terms.isEmpty else { return await unread(limit: limit, account: account) }
        let match = terms.joined(separator: " AND ")

        return (try? await dbPool.read { db in
            try Message.fetchAll(
                db,
                sql: """
                    SELECT m.* FROM \(Message.databaseTableName) m
                     WHERE m.user_id = \(ownerSQL) AND m.rowid IN (SELECT rowid FROM mail_message_fts
                                        WHERE mail_message_fts MATCH ?)
                       AND (? IS NULL OR m.account = ?)
                     ORDER BY m.internalDate DESC
                     LIMIT ?
                    """,
                arguments: [match, account, account, limit]
            )
        }) ?? []
    }

    /// Words that describe the *request* rather than the mail, dropped before matching.
    /// The model sends words like `unread` that describe the request but appear in none of the mail.
    private static let stopWords: Set<String> = [
        "unread", "email", "emails", "mail", "message", "messages", "inbox",
        "new", "latest", "recent", "what", "whats", "any", "anything", "show", "read",
    ]

    /// The cached unread count summed across every mailbox, with the mailboxes it covers, so
    /// `FullDuplexBroker` can check coverage before speaking it. `nil` before any pass has run.
    func inboxUnread() async -> (accounts: [String], count: Int)? {
        guard let dbPool else { return nil }
        return try? await dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT account, inboxUnread FROM \(SyncState.databaseTableName)
                     WHERE user_id = \(ownerSQL) AND inboxUnread IS NOT NULL
                     ORDER BY account
                """
            )
            guard !rows.isEmpty else { return nil }
            return (
                accounts: rows.map { $0["account"] as String },
                count: rows.reduce(0) { $0 + ($1["inboxUnread"] as Int) }
            )
        } ?? nil
    }

    /// Cached inbox messages carrying one Gmail label. Nil when there is no cache or the
    /// read failed, so a caller can tell "none" from "unknown".
    func inboxLabelCount(_ label: String) async -> Int? {
        guard let dbPool else { return nil }
        do {
            return try await dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM \(Message.databaseTableName) m
                     WHERE m.user_id = \(ownerSQL) AND EXISTS (SELECT 1 FROM \(Label.databaseTableName) l
                                    WHERE l.user_id = m.user_id AND l.account = m.account AND l.messageId = m.id AND l.label = 'INBOX')
                       AND EXISTS (SELECT 1 FROM \(Label.databaseTableName) l2
                                    WHERE l2.user_id = m.user_id AND l2.messageId = m.id AND l2.label = ?)
                    """,
                arguments: [label]
            ) ?? 0
            }
        } catch {
            RealtimeLog.log("mail: label count for \(label) failed — \(error.localizedDescription)")
            return nil
        }
    }

    /// Gmail's category for one cached message, scoped to its mailbox.
    func gmailCategory(id: String, account: String) async -> GmailMailCategory? {
        guard let dbPool else { return nil }
        do {
            let labels = try await dbPool.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                        SELECT l.label FROM \(Label.databaseTableName) l
                          JOIN \(Message.databaseTableName) m ON m.id = l.messageId AND m.user_id = l.user_id
                         WHERE l.user_id = \(ownerSQL) AND l.messageId = ? AND lower(m.account) = lower(?)
                        """,
                    arguments: [id, account])
            }
            return GmailMailCategory.from(labels: labels)
        } catch {
            RealtimeLog.log("mail: category read failed for \(id) — \(error.localizedDescription)")
            return nil
        }
    }

    /// Cached inbox IDs in one Gmail category, or every category when nil.
    func inboxMessageIDs(
        account: String, sender: String, category: GmailMailCategory? = nil
    ) async -> [String]? {
        let sender = sender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let dbPool, !sender.isEmpty else { return nil }
        do {
            return try await dbPool.read { db in
                let categoryLabels: [String]
                switch category {
                case .promotions: categoryLabels = ["CATEGORY_PROMOTIONS"]
                case .purchases: categoryLabels = ["CATEGORY_PURCHASES", "PURCHASES"]
                case .reservations: categoryLabels = ["CATEGORY_RESERVATIONS", "RESERVATIONS"]
                case .updates: categoryLabels = ["CATEGORY_UPDATES"]
                case .social: categoryLabels = ["CATEGORY_SOCIAL"]
                case .forums: categoryLabels = ["CATEGORY_FORUMS"]
                case nil: categoryLabels = []
                }

                var sql = """
                    SELECT m.id FROM \(Message.databaseTableName) m
                     WHERE m.user_id = \(ownerSQL) AND lower(m.account) = lower(?)
                       AND EXISTS (
                           SELECT 1 FROM \(Label.databaseTableName) inbox
                            WHERE inbox.user_id = m.user_id AND inbox.account = m.account AND inbox.messageId = m.id AND inbox.label = 'INBOX'
                              AND inbox.account = m.account
                       )
                    """
                var arguments = StatementArguments([account])
                if sender.contains("@") {
                    // Gmail metadata is a bare address or `Name <address>`.
                    sql += " AND (lower(trim(m.sender)) = ? OR lower(m.sender) LIKE ?)"
                    arguments += StatementArguments([sender, "%<\(sender)>%"])
                } else {
                    // Match the host and subdomains, with address boundaries rejecting lookalikes.
                    sql += """

                       AND (
                           lower(trim(m.sender)) LIKE ? OR lower(m.sender) LIKE ?
                           OR lower(trim(m.sender)) LIKE ? OR lower(m.sender) LIKE ?
                       )
                    """
                    arguments += StatementArguments([
                        "%@\(sender)", "%@\(sender)>%",
                        "%@%.\(sender)", "%@%.\(sender)>%",
                    ])
                }
                if !categoryLabels.isEmpty {
                    sql += """

                       AND EXISTS (
                           SELECT 1 FROM \(Label.databaseTableName) category
                            WHERE category.user_id = m.user_id AND category.messageId = m.id
                              AND category.account = m.account
                              AND category.label IN (\(categoryLabels.map { _ in "?" }.joined(separator: ",")))
                       )
                    """
                    arguments += StatementArguments(categoryLabels)
                }
                return try String.fetchAll(db, sql: sql, arguments: arguments)
            }
        } catch {
            RealtimeLog.log("mail: cleanup id read failed — \(error.localizedDescription)")
            return nil
        }
    }

    static func logCleanupCounts(database: DatabasePool?) async {
        guard let database else {
            RealtimeLog.log("cache cleanup: verification unavailable — no database")
            return
        }
        do {
            let counts = try await database.read { db in
                [
                    "messages": try Message.fetchCount(db),
                    "labels": try Label.fetchCount(db),
                    "drafts": try Draft.fetchCount(db),
                    "sync states": try SyncState.fetchCount(db),
                    "pending read updates": try MarkReadOutbox.fetchCount(db),
                    "daily queue snapshots": try DailyEmailQueueSnapshotRecord.fetchCount(db),
                    "cleanup records": try EmailCleanupRecord.fetchCount(db),
                ]
            }
            for (name, count) in counts.sorted(by: { $0.key < $1.key }) {
                RealtimeLog.log("cache cleanup: \(name) remaining=\(count)")
            }
        } catch {
            RealtimeLog.log("cache cleanup: count verification failed")
        }
    }

    /// How many messages are cached. Cheap, and the number a diagnostics row shows.
    func count() async -> Int {
        guard let dbPool else { return 0 }
        return (try? await dbPool.read { db in
            try Message.filter(Column("user_id") == userId).fetchCount(db)
        }) ?? 0
    }

    /// Delete every cached message, label and cursor for every account. Takes no account on purpose:
    /// sign-out has no address left to name. Required for Google's restricted-scope deletion path.
    func purgeAll() async {
        guard let dbPool else { return }
        try? await dbPool.write { db in
            try Message.filter(Column("user_id") == userId).deleteAll(db)
            try Draft.filter(Column("user_id") == userId).deleteAll(db)
            try SyncState.filter(Column("user_id") == userId).deleteAll(db)
            try DailyEmailQueueSnapshotRecord.deleteAll(db)
            try EmailCleanupRecord.filter(Column("user_id") == userId).deleteAll(db)
        }
    }

    /// - Returns: how many messages went, so a disconnect can say what it deleted.
    @discardableResult
    func purge(account: String) async -> Int {
        guard let dbPool else { return 0 }
        return (try? await dbPool.write { db in
            let gone = try Message.filter(Column("user_id") == userId).filter(Column("account") == account).deleteAll(db)
            try Draft.filter(Column("user_id") == userId).filter(Column("account") == account).deleteAll(db)
            try SyncState.filter(Column("user_id") == userId).filter(Column("account") == account).deleteAll(db)
            try DailyEmailQueueSnapshotRecord
                .filter(Column("user_id") == userId)
                .filter(Column("account") == account)
                .deleteAll(db)
            try EmailCleanupRecord.filter(Column("user_id") == userId)
                .filter(Column("account") == account.lowercased())
                .deleteAll(db)
            return gone
        }) ?? 0
    }
}

extension MailStore {
    /// One message and its labels, as a pass hands them over.
    /// Travels as one value so the message and labels can't drift out of step.
    struct Ingest: Sendable {
        let message: Message
        let labels: [String]

        /// Build one from a Gmail metadata response.
        /// Header lookup is case-insensitive because Gmail echoes the sender's casing.
        init(detail: GmailAPI.MessageDetail, account: String) {
            message = Message(
                id: detail.id,
                account: account,
                threadId: detail.threadId,
                sender: detail.header("From"),
                recipient: detail.header("To"),
                subject: detail.header("Subject"),
                snippet: detail.snippet,
                internalDate: detail.internalDate.flatMap(Int64.init),
                cachedAt: Date(),
                rfcMessageID: detail.header("Message-ID"),
                inReplyTo: detail.header("In-Reply-To"),
                referenceHeaders: detail.header("References"),
                ancestryCached: true,
                hasListUnsubscribe: !(detail.header("List-Unsubscribe") ?? "").isEmpty
            )
            labels = detail.labelIds ?? []
        }
    }
}
