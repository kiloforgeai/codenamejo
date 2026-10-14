import Foundation
import FactoryKit
import GRDB

/// What has already been looked up in calls, held on the phone. Filled from the call's own
/// tool results (`RealtimeEvent.mcpCallResult`); not `@MainActor`, since nothing draws it.
///
/// A WAL pool so a search never waits behind a burst of `annotate` writes; the single writer
/// is what `nextKey` relies on. Every failure is soft: a failed open leaves `dbPool` nil.
final class LocalContextStore: Sendable {
    /// The most rows the full-text tier hands back. A line is the handle plus
    /// `headLength`, ~70 tokens, so 15 is ~1k against the 40,000/min ceiling.
    static let textLimit = 15

    /// The most rows the recency tier hands back. Stays small where `textLimit` does not:
    /// these rows ignored the query and are labelled unrelated, so extra ones are noise.
    static let recencyLimit = 5

    /// The cosine below which a vector match is not worth showing. `NLEmbedding` puts
    /// unrelated English sentences around 0.2–0.4, so this is deliberately above that.
    static let similarityFloor: Float = 0.55

    /// The most rows the vector scan will load and score. A cap on the phone's work, not
    /// on what comes back — `textLimit` still decides that.
    static let vectorScanLimit = 500

    /// The `request` + head of `result` as a stored vector: users paraphrase the sender and
    /// subject, and ask about the content.
    static func embedding(request: String, result: String) -> Data? {
        let head = result.prefix(headLength * 2)
        guard let vector = ContextEmbedding.vector(for: "\(request). \(head)") else { return nil }
        return ContextEmbedding.encode(vector)
    }

    /// How much of one row's result a search may quote. The row keeps the answer whole.
    static let headLength = 220

    /// The most of one result that is kept. `formatted` already bounds what reaches a turn;
    /// this bounds the phone, where FTS5 indexes every byte of a long attachment.
    static let maxResult = 16 * 1024

    /// Caps on the two short fields; `request` is a sender-and-subject line, so 500 is a backstop.
    static let maxRequest = 500
    static let maxSummary = 500

    /// Shared with `MailStore`, which writes its tables into the same file through one writer.
    /// `nil` when the file could not be opened, which every reader treats as an empty store.
    let dbPool: DatabasePool?

    init(url: URL? = nil) {
        dbPool = Self.open(at: url ?? Self.defaultURL())
    }

    // MARK: - Recording

    /// Store one finished `mcp_call`, one row per message it returned (`LocalContextKeys.emails(in:)`),
    /// or a single row keyed by `describe(tool:argumentsJSON:)` otherwise.
    func record(
        tool: String,
        serverLabel: String?,
        argumentsJSON: String,
        itemJSON: String,
        userId: String = "",
        conversationId: String?
    ) async {
        guard let dbPool, !tool.isEmpty else { return }
        let envelope = LocalContextKeys.object(from: itemJSON)
        guard let output = envelope["output"] as? String, !output.isEmpty else { return }

        // Stored only for a cacheable name whose output is real JSON rather than a refusal in prose.
        let isTriage = LocalContextKeys.triageTools.contains(tool)
        let isCacheable = isTriage || LocalContextKeys.cached.contains(tool)
        let conversation = conversationId ?? ""
        var pending: [(kind: String, request: String, result: String)] = []

        // A write's receipt is never stored, but what it did is noted on the message's own row:
        // an archived message is answerable afterwards only from this copy.
        if !isCacheable {
            if let note = LocalContextKeys.actionNote(for: tool) {
                await annotate(
                    ids: LocalContextKeys.actedMessageIds(in: argumentsJSON),
                    note: note, conversation: conversation, tool: tool)
            }
            return
        }
        guard LocalContextKeys.isData(output) else { return }

        if isTriage {
            // Per message only for the queue tool; a `search_messages` list stays one row.
            for email in LocalContextKeys.emails(in: output) {
                guard let json = LocalContextKeys.json(for: email) else { continue }
                pending.append((
                    kind: "message",
                    request: LocalContextKeys.describe(email: email, tool: tool),
                    result: json))
            }
        } else {
            pending.append((
                kind: "message",
                request: LocalContextKeys.describe(tool: tool, argumentsJSON: argumentsJSON),
                result: output))
        }
        guard !pending.isEmpty else { return }
        await write(pending, conversation: conversation, tool: tool, userId: userId)
    }

    /// Record on a message's stored row that something was done to it, matched on the Gmail id
    /// inside `result`. Annotates rather than replaces, so the row keeps its `m_N` key.
    private func annotate(
        ids: [String], note: String, conversation: String, tool: String
    ) async {
        guard let dbPool, !ids.isEmpty else { return }
        do {
            var touched = 0
            try await dbPool.write { db in
                for id in ids {
                    let rows = try LocalContextRow
                        .filter(Column("conversation_id") == conversation)
                        .filter(Column("result").like("%\(id)%"))
                        .fetchAll(db)
                    for var row in rows where !row.summary.contains(note) {
                        // Capped: distinct notes still append, and `summary` outranks `result` in the index.
                        row.summary = String((row.summary.isEmpty
                            ? "You \(note) this."
                            : "\(row.summary) You \(note) this.").prefix(Self.maxSummary))
                        try row.update(db)
                        touched += 1
                    }
                }
            }
            if touched > 0 {
                RealtimeLog.log("localContext: noted \"\(note)\" on \(touched) row(s) for \(tool)")
            }
        } catch {
            RealtimeLog.log("localContext: annotating \(tool) failed — \(error)")
        }
    }

    /// Insert or replace a batch of rows, minting a key per row.
    private func write(
        _ pending: [(kind: String, request: String, result: String)],
        conversation: String, tool: String, userId: String
    ) async {
        guard let dbPool else { return }
        do {
            try await dbPool.write { db in
                for entry in pending {
                    // Clipped before the match: `request` is the unique key, so matching the full text would
                    // miss the stored row and the insert would collide with it.
                    let request = String(entry.request.prefix(Self.maxRequest))
                    // One row per question per conversation, with `created_at` refreshed.
                    try LocalContextRow
                        .filter(Column("conversation_id") == conversation)
                        .filter(Column("request").collating(.nocase) == request)
                        .deleteAll(db)
                    var row = LocalContextRow(
                        id: nil,
                        key: try Self.nextKey(in: conversation, db),
                        kind: entry.kind,
                        request: request,
                        result: Self.clip(entry.result),
                        summary: "",
                        conversationId: conversation,
                        userId: userId,
                        embedding: Self.embedding(request: request, result: entry.result),
                        createdAt: Date())
                    try row.insert(db)
                }
            }
            RealtimeLog.log("localContext: stored \(pending.count) row(s) for \(tool)")
        } catch {
            RealtimeLog.log("localContext: recording \(tool) failed — \(error)")
        }
    }

    // MARK: - The model's own saves

    /// `save_context`, answered on the device. Refuses what a tool result already stored, since the
    /// model ignores being told not to; answered as a result, because an error invites a retry.
    func save(
        request: String, result: String, summary: String, kind: String,
        conversationId: String?, userId: String = ""
    ) async -> String {
        guard let dbPool else { return "Nothing was saved — the store is unavailable." }
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else {
            return "NOT SAVED — say what was looked up, in `request`."
        }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "NOT SAVED — pass the data itself in `result`."
        }
        let conversation = conversationId ?? ""
        // An automatic row carries a bracketed tool name, which the model's saves never do.
        // Only an exact or literal hit may refuse; vector and recency hits are merely close.
        let duplicate = await search(request, conversationId: conversationId, limit: 1)
        if duplicate.matched == .key || duplicate.matched == .text,
           let existing = duplicate.rows.first,
           existing.request.contains("[") {
            return "Already cached as \(existing.key) — that lookup was saved "
                + "automatically, with the full result. Nothing more to do."
        }
        // Clipped before the delete matches on it, for the reason `write` gives.
        let stored = String(request.prefix(Self.maxRequest))
        do {
            return try await dbPool.write { db in
                var row = LocalContextRow(
                    id: nil,
                    key: try Self.nextKey(in: conversation, db),
                    kind: kind.isEmpty ? "note" : kind,
                    request: stored,
                    result: Self.clip(result),
                    summary: String(summary.prefix(Self.maxSummary)),
                    conversationId: conversation,
                    userId: userId,
                    embedding: Self.embedding(request: stored, result: result),
                    createdAt: Date())
                try LocalContextRow
                    .filter(Column("conversation_id") == conversation)
                    .filter(Column("request").collating(.nocase) == stored)
                    .deleteAll(db)
                try row.insert(db)
                return "Cached as \(row.key)."
            }
        } catch {
            RealtimeLog.log("localContext: save failed — \(error)")
            return "Nothing was saved — the store refused it."
        }
    }

    /// `forget_context`, answered on the device. Still the only way a row leaves.
    func forget(key: String, conversationId: String?) async -> String {
        guard let dbPool else { return "Nothing was forgotten — the store is unavailable." }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "NOT FORGOTTEN — a key is required." }
        let conversation = conversationId ?? ""
        do {
            let removed = try await dbPool.write { db in
                try LocalContextRow
                    .filter(Column("conversation_id") == conversation)
                    .filter(Column("key") == key)
                    .deleteAll(db)
            }
            return removed > 0 ? "Forgot \(key)." : "Nothing stored under \(key)."
        } catch {
            RealtimeLog.log("localContext: forget failed — \(error)")
            return "Nothing was forgotten — the store refused it."
        }
    }

    /// Cut an oversized result to fit, and say so in prose, or the row reads as complete.
    /// Deliberately not a JSON repair: a plausible truncated object is worse.
    static func clip(_ result: String) -> String {
        guard result.count > maxResult else { return result }
        let note = "\n\n[This stored copy was cut off at 16 KB — what came after it is "
            + "missing. If the answer might be in the rest, fetch it again with the "
            + "connector's own tool rather than treating this as the whole thing.]"
        return String(result.prefix(maxResult - note.count)) + note
    }

    /// `m_1`, `m_2`, … within one conversation. Safe without a retry only because the pool has
    /// one writer and this runs inside `write`.
    private static func nextKey(in conversation: String, _ db: Database) throws -> String {
        let highest = try Int.fetchOne(db, sql: """
            SELECT COALESCE(MAX(CAST(SUBSTR(key, 3) AS INTEGER)), 0)
            FROM context_rows WHERE conversation_id = ?
            """, arguments: [conversation]) ?? 0
        return "m_\(highest + 1)"
    }

    // MARK: - Searching

    /// Rows matching any token of `query`, best first, within `conversationId`. A wider `scope`
    /// reaches earlier rows only where `kind` is `note`; captured rows never leave their call.
    func search(
        _ query: String,
        conversationId: String?,
        userId: String = "",
        scope: RecallScope = .call,
        limit: Int = LocalContextStore.textLimit
    ) async -> Result {
        guard let dbPool else { return Result(rows: [], matched: .recency) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversation = conversationId ?? ""
        let earlier = scope.reachesEarlier
        let since = scope.since() ?? Date.distantPast
        // Tier 2's SQL repeats this filter by hand; tier 1 is narrower still.
        func scoped<T: FetchableRecord>(_ request: QueryInterfaceRequest<T>) -> QueryInterfaceRequest<T> {
            guard earlier else {
                return request.filter(Column("conversation_id") == conversation)
            }
            return request.filter(
                Column("conversation_id") == conversation
                    || (Column("kind") == LocalContextRow.noteKind
                        && Column("created_at") >= since
                        && !userId.isEmpty && Column("user_id") == userId))
        }
        do {
            return try await dbPool.read { db in
                // Tier 1: an exact `m_N` fetch, which bypasses ranking.
                if trimmed.range(of: "^m_[0-9]+$", options: .regularExpression) != nil {
                    // Scoped to this conversation whatever the scope: `nextKey` restarts per conversation,
                    // so `m_1` would be ambiguous across calls.
                    let rows = try LocalContextRow
                        .filter(Column("conversation_id") == conversation)
                        .filter(Column("key") == trimmed)
                        .order(Column("created_at").desc)
                        .limit(1)
                        .fetchAll(db)
                    if !rows.isEmpty { return Result(rows: rows, matched: .key) }
                }
                // Tier 2: full text, any token.
                if let pattern = FTS5Pattern(matchingAnyTokenIn: trimmed) {
                    // Column weights are request, summary, result; lower bm25 is better, and recency breaks ties.
                    let rows = try LocalContextRow.fetchAll(db, sql: """
                        SELECT context_rows.*
                        FROM context_rows
                        JOIN context_fts ON context_fts.rowid = context_rows.id
                        WHERE context_fts MATCH ?
                          AND (context_rows.conversation_id = ?
                               OR (? AND context_rows.kind = ?
                                   AND context_rows.created_at >= ?
                                   AND ? <> '' AND context_rows.user_id = ?))
                        ORDER BY bm25(context_fts, 10.0, 3.0, 1.0), context_rows.created_at DESC
                        LIMIT ?
                        """, arguments: [pattern, conversation, earlier,
                                       LocalContextRow.noteKind, since, userId, userId,
                                       limit])
                    if !rows.isEmpty { return Result(rows: rows, matched: .text) }
                }
                // Tier 3: meaning, where the words missed. Rows without an embedding are absent from the scan.
                if let queryVector = ContextEmbedding.vector(for: trimmed) {
                    let candidates = try scoped(LocalContextRow.all())
                        .filter(Column("embedding") != nil)
                        .order(Column("created_at").desc)
                        .limit(Self.vectorScanLimit)
                        .fetchAll(db)
                    let scored = candidates
                        .compactMap { row -> (LocalContextRow, Float)? in
                            guard let blob = row.embedding,
                                  let vector = ContextEmbedding.decode(blob) else { return nil }
                            return (row, ContextEmbedding.similarity(queryVector, vector))
                        }
                        .sorted { $0.1 > $1.1 }
                    RealtimeLog.log(String(
                        format: "localContext: vector scanned %d, best %.3f, floor %.2f",
                        scored.count, scored.first?.1 ?? 0, Self.similarityFloor))
                    let ranked = scored.filter { $0.1 >= Self.similarityFloor }
                        .prefix(limit)
                        .map(\.0)
                    if !ranked.isEmpty { return Result(rows: Array(ranked), matched: .vector) }
                }
                // Tier 4: the most recent rows, ignoring the query. `matched` lets the caller say so.
                // Capped below `limit`, so the `limit: 1` duplicate check stays a single row.
                let recent = try scoped(LocalContextRow.all())
                    .order(Column("created_at").desc)
                    .limit(min(limit, Self.recencyLimit))
                    .fetchAll(db)
                return Result(rows: recent, matched: .recency)
            }
        } catch {
            RealtimeLog.log("localContext: search failed — \(error)")
            return Result(rows: [], matched: .recency)
        }
    }

    /// What a search found, and how: only the caller can tell the model recency is not relevance.
    struct Result: Sendable {
        enum Matched: String, Sendable { case key, text, vector, recency }
        let rows: [LocalContextRow]
        let matched: Matched
    }

    /// One row by its `m_N` key, within a conversation.
    /// One row by its `m_N` key, within a conversation.
    func row(key: String, in conversation: String) async -> LocalContextRow? {
        guard let dbPool else { return nil }
        return try? await dbPool.read { db in
            try LocalContextRow
                .filter(Column("conversation_id") == conversation)
                .filter(Column("key") == key)
                .fetchOne(db)
        }
    }

    /// Rows stored for one conversation, sent to the mint so the model knows when there is
    /// nothing to search.
    func count(in conversationId: String?) async -> Int {
        guard let dbPool else { return 0 }
        let conversation = conversationId ?? ""
        return (try? await dbPool.read { db in
            try LocalContextRow
                .filter(Column("conversation_id") == conversation)
                .fetchCount(db)
        }) ?? 0
    }

    /// Every conversation this phone holds context for, which gates History's Resume.
    /// Rows with no conversation id are dropped.
    func conversationsWithContext() async -> Set<UUID> {
        guard let dbPool else { return [] }
        let ids: [String] = (try? await dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT conversation_id FROM context_rows
                 WHERE conversation_id <> ''
                """)
        }) ?? []
        return Set(ids.compactMap(UUID.init(uuidString:)))
    }

    /// Drop everything; sign-out has to call this. Scoped by `userId` because it runs detached
    /// and could land after the next account has written rows.
    func purge(userId: String? = nil) async {
        guard let dbPool else { return }
        do {
            try await dbPool.write { db in
                if let userId, !userId.isEmpty {
                    // Unattributed rows too: no widened read can reach them, so nothing else would clean them up.
                    _ = try LocalContextRow
                        .filter(sql: "user_id = ? OR user_id = '' OR substr(user_id, 1, ?) = ?",
                                arguments: [userId, (userId + ":profile:").count, userId + ":profile:"])
                        .deleteAll(db)
                } else {
                    _ = try LocalContextRow.deleteAll(db)
                }
            }
        } catch {
            RealtimeLog.log("localContext: purge failed — \(error)")
        }
    }

    // MARK: - Formatting for the model

    /// Render search results as the text a `function_call_output` carries, each line led by its key.
    /// The miss sentence is returned only when `hasTurns` is false, since turns are appended after it.
    static func formatted(_ result: Result, query: String, conversationId: String? = nil,
                          hasTurns: Bool = false) -> String {
        let conversation = conversationId ?? ""
        guard !result.rows.isEmpty else {
            guard !hasTurns else { return "" }
            return "Nothing is stored on this phone yet. Nothing has been read here that "
                + "could answer \"\(query)\" — use the normal tools to look it up."
        }
        // The header says which tier answered, or recency reads as relevance.
        let header: String
        switch result.matched {
        case .key: header = "The stored lookup you asked for:"
        case .text: header = "Stored on this phone, closest first:"
        case .vector: header = "Nothing stored uses those words — these are the closest "
                + "in meaning, so check each one actually answers it:"
        case .recency:
            header = "Nothing stored matches \"\(query)\" — these are simply the most "
                + "recent lookups on this phone, so treat them as unrelated unless one "
                + "obviously answers it:"
        }
        let lines = result.rows.map { row -> String in
            let head = row.result
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(headLength)
            let failed = row.kind == "error" ? " [this call failed]" : ""
            // No key on a row from another call: tier 1 is scoped, so it would resolve to another row.
            let handle = row.conversationId == conversation ? "[\(row.key)] " : ""
            return "• \(handle)\(row.request)\(failed) (\(row.age())): \(head)"
        }
        return header + "\n"
            + lines.joined(separator: "\n")
            + "\n(Excerpts of what was read earlier. If one is stale for what they asked, "
            + "or cut short of the part you need, read the real thing again.)"
    }

    // MARK: - Opening

    private static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LocalContext", isDirectory: true)
            .appendingPathComponent("context.sqlite")
    }

    private static func open(at url: URL) -> DatabasePool? {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                // Calls continue with the screen locked, and `complete` would fail every read and write then.
                // Set on the directory so SQLite's `-wal` and `-shm` files inherit it.
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let pool = try DatabasePool(path: url.path)
            try migrator.migrate(pool)
            // A cache, so it is excluded from backup.
            var directoryURL = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directoryURL.setResourceValues(values)
            RealtimeLog.log("localContext: opened \(url.lastPathComponent)")
            return pool
        } catch {
            RealtimeLog.log("localContext: could not open the store — \(error). "
                + "Local context is off for this launch.")
            return nil
        }
    }

    static var migrator: DatabaseMigrator { migrator(installId: { InstallIdentity.current }) }

    /// - Parameter installId: who owns this phone's rows, read only if `v45` has not run yet.
    static func migrator(installId: @escaping () -> String?) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // Must stay off: a schema change would silently delete everything. Never edit or rename
        // a shipped migration; GRDB records them by name. Every change is a new `registerMigration`.
        migrator.eraseDatabaseOnSchemaChange = false
        migrator.registerMigration("v2-rows-per-item") { db in
            try db.create(table: LocalContextRow.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("key", .text).notNull()
                t.column("kind", .text).notNull()
                // `NOCASE` makes the unique key below case-insensitive.
                t.column("request", .text).notNull().collate(.nocase)
                t.column("result", .text).notNull()
                t.column("summary", .text).notNull().defaults(to: "")
                t.column("conversation_id", .text).notNull().defaults(to: "")
                t.column("created_at", .datetime).notNull()
                t.uniqueKey(["conversation_id", "request"])
                t.uniqueKey(["conversation_id", "key"])
            }
            try db.create(index: "context_rows_recency", on: LocalContextRow.databaseTableName,
                          columns: ["created_at"])
            // `synchronize` writes the triggers. Column order is the `bm25()` argument order in
            // `search(_:)`; reordering silently inverts the weighting.
            try db.create(virtualTable: "context_fts", using: FTS5()) { t in
                t.synchronize(withTable: LocalContextRow.databaseTableName)
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("request")
                t.column("summary")
                t.column("result")
            }
        }
        // Drops receipt rows from before the write gate: only `describe()`'s bare-name default lacks
        // a bracketed tool name.
        migrator.registerMigration("v3-drop-pre-gate-receipts") { db in
            try db.execute(sql: """
                DELETE FROM \(LocalContextRow.databaseTableName) WHERE request NOT LIKE '%[%'
                """)
        }
        // Mail shares this file, and one file means one migrator: GRDB records applied migrations in it.
        migrator.registerMigration("v4-mail-cache", migrate: MailStore.createSchema)
        // The backfill cursor, separate because `v4` had already shipped.
        migrator.registerMigration("v5-mail-backfill", migrate: MailStore.createBackfillCursor)
        // The mail FTS index and its triggers. See `MailQuery`.
        migrator.registerMigration("v6-mail-search", migrate: MailStore.createSearchIndex)
        // The inbox unread total, which the 24-hour cache cannot answer from its own rows.
        migrator.registerMigration("v7-mail-unread-count", migrate: MailStore.createUnreadCounter)
        // Drafts. Named `v8` out of order: GRDB keys a migration by this exact string, and it shipped.
        migrator.registerMigration("v8-mail-drafts", migrate: MailStore.createDraftsSchema)
        // The mark-read outbox — see `MailStore.clearUnreadDurably`.
        migrator.registerMigration("v8-mail-mark-read-outbox", migrate: MailStore.createMarkReadOutbox)
        // The outbox's cascade delete — see `MailStore.createMarkReadOutboxForeignKey`.
        migrator.registerMigration(
            "v9-mail-mark-read-outbox-fk", migrate: MailStore.createMarkReadOutboxForeignKey)
        // The calendar cache, defined in `CalendarStore`.
        migrator.registerMigration("v10-calendar-cache", migrate: CalendarStore.createSchema)
        // The correspondent directory behind `find_person`; see `ContactStore`.
        migrator.registerMigration("v11-contacts", migrate: ContactStore.createSchema)
        // This phone's own conversations; see `TurnStore`.
        migrator.registerMigration("v12-turns", migrate: TurnStore.createSchema)
        // The local insertion time, see `TurnStore.Turn.mirroredAt`.
        migrator.registerMigration("v13-turn-mirrored-at", migrate: TurnStore.addMirroredAt)
        // The owner of a cached row. Only widened reads require it — see `LocalContextRow`.
        migrator.registerMigration("v14-context-owner") { db in
            try db.alter(table: LocalContextRow.databaseTableName) { t in
                t.add(column: "user_id", .text).notNull().defaults(to: "")
            }
        }
        // Nullable and unbackfilled: an existing row stays keyword-only until it is
        // rewritten, which for a cache of a live call is the next lookup.
        migrator.registerMigration("v15-context-embedding") { db in
            try db.alter(table: LocalContextRow.databaseTableName) { t in
                t.add(column: "embedding", .blob)
            }
        }
        // Unread, but a shipped migration cannot be withdrawn.
        migrator.registerMigration("v16-contact-embedding") { db in
            try db.alter(table: ContactStore.Contact.databaseTableName) { t in
                t.add(column: "embedding", .blob)
            }
        }
        // Device-local daily email queue checkpoints. Kept in context.sqlite so they share
        // the mail cache's file protection, WAL writer and account lifetime.
        migrator.registerMigration(
            "v17-daily-email-queue", migrate: DailyEmailQueueSnapshotRecord.createSchema)
        // How the user writes: de-identified sent-mail samples, the learned profile and the
        // assistant's drafts being watched for an edit. Retired; v39 drops them.
        migrator.registerMigration("v18-writing-tone", migrate: RetiredWritingToneSchema.createSchema)
        // Superhuman's section, snooze and snippet cache. Retired; v40 drops it.
        migrator.registerMigration("v19-superhuman-queue-state", migrate: RetiredSuperhumanSchema.createSchema)
        migrator.registerMigration(
            "v20-gmail-email-cleanup", migrate: EmailCleanupRecord.createSchema)
        migrator.registerMigration(
            "v21-user-scoped-email-cleanup", migrate: EmailCleanupRecord.recreateUserScopedSchema)
        migrator.registerMigration(
            "v22-gmail-draft-thread-index", migrate: MailStore.createDraftThreadIndex)
        migrator.registerMigration("v23-gmail-reply-ancestry", migrate: MailStore.addReplyAncestry)
        migrator.registerMigration("v24-mail-user-ownership", migrate: MailStore.scopeToUsers)
        migrator.registerMigration("v25-discard-unowned-mail-cache", migrate: MailStore.discardLegacyUnownedCache)
        migrator.registerMigration("v26-writing-tone-status", migrate: RetiredWritingToneSchema.createStatusOutbox)
        migrator.registerMigration("v27-sent-message-bodies", migrate: MailStore.createSentBodies)
        migrator.registerMigration("v28-sent-forward-cursor", migrate: MailStore.addSentForwardCursor)
        // The mailbox joins the key: two accounts can be handed the same raw Gmail id, and
        // the cache could hold only one of them. See `MailStore.scopeToMailboxes`.
        migrator.registerMigration("v29-mailbox-scoped-mail-keys", migrate: MailStore.scopeToMailboxes)
        // Preserve the shipped schema for migration compatibility; repeat offers no longer use it.
        migrator.registerMigration("v30-sender-asks") { db in
            try db.create(table: "sender_asks") { t in
                t.column("user_id", .text).notNull()
                t.column("account", .text).notNull()
                t.column("sender", .text).notNull()
                t.column("verb", .text).notNull()
                t.column("askCount", .integer).notNull()
                t.column("lastAskAt", .datetime).notNull()
                t.column("offeredAt", .datetime)
                t.primaryKey(["user_id", "account", "sender", "verb"])
            }
        }
        // Where a correspondent came from, so a mail walk stops deleting the people only the
        // calendar knows about. See `ContactStore.addSource`.
        migrator.registerMigration("v31-contact-source", migrate: ContactStore.addSource)
        migrator.registerMigration("v32-mail-importance", migrate: MailStore.addImportance)
        migrator.registerMigration("v33-mail-importance-score", migrate: MailStore.addImportance)
        migrator.registerMigration("v34-mail-importance-signals") { db in
            try MailStore.addImportance(db)
            try db.execute(sql: "UPDATE mail_message SET importanceBand = NULL, importanceWhy = NULL, importanceScore = NULL")
        }
        migrator.registerMigration("v35-mail-topics", migrate: MailStore.addImportance)
        // Slack is gone; an install that ran "v35-slack-queue-snapshot" has an empty table left.
        migrator.registerMigration("v36-drop-slack-queue-snapshot") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS slack_queue_snapshot")
        }
        migrator.registerMigration("v37-pending-mail-writes", migrate: PendingMailWrite.createSchema)
        migrator.registerMigration("v38-pending-draft-payload", migrate: PendingMailWrite.addPayload)
        // The writing-tone feature is gone, and with it the sent bodies cached only to learn from.
        migrator.registerMigration("v39-drop-writing-tone", migrate: RetiredWritingToneSchema.drop)
        // The Superhuman connector is gone.
        migrator.registerMigration("v40-drop-superhuman", migrate: RetiredSuperhumanSchema.drop)
        migrator.registerMigration("v41-workspace-profiles", migrate: WorkspaceProfileRows.createSchema)
        migrator.registerMigration("v42-email-categories", migrate: EmailCategoryRows.createSchema)
        migrator.registerMigration("v43-turn-record", migrate: TurnStore.addRecord)
        migrator.registerMigration("v44-queue-snapshot-owner", migrate: DailyEmailQueueSnapshotRecord.addOwner)
        // The Better Auth user id is gone; every row it owned moves to this install's id.
        migrator.registerMigration("v45-install-identity") { db in
            guard let id = installId() else { throw BackendError.notSignedIn }
            try db.execute(sql: "UPDATE daily_email_queue_snapshot SET user_id = ? WHERE user_id = ''",
                           arguments: [id])
            try InstallIdentity.adopt(id, in: db)
        }
        migrator.registerMigration("v46-custom-commands", migrate: CustomCommandRows.createSchema)
        migrator.registerMigration("v47-calendar-busy-fields", migrate: CalendarStore.addBusyFields)
        return migrator
    }
}
