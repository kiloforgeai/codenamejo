import Foundation
import GRDB

/// How far back a recall reaches: one argument on `search_context`, since the model ignores a
/// second tool the prompt does not name. The day boundary uses the phone's own `Calendar`.
enum RecallScope: String, Sendable, CaseIterable {
    /// This call only.
    case call
    /// Since midnight, this call included. The widest there is: no scope reaches yesterday.
    case today

    /// Parsed from the model's argument. Nil when absent, which keeps the pre-scope behaviour
    /// for a broker that cannot send one; an unrecognised value is `call`, so a typo never widens.
    static func parse(_ argument: String?) -> RecallScope? {
        guard let argument, !argument.isEmpty else { return nil }
        return RecallScope(rawValue: argument.lowercased()) ?? .call
    }

    /// The oldest thing this scope may reach, or nil for no bound.
    func since(now: Date = Date()) -> Date? {
        switch self {
        case .call: return nil
        case .today: return Calendar.current.startOfDay(for: now)
        }
    }

    /// Whether this scope reaches past the current conversation.
    var reachesEarlier: Bool { self != .call }
}

/// This phone's copy of its own conversations, and the store History reads. More tables in
/// `context.sqlite`, for the reasons in `MailStore`'s header; not `@MainActor`.
struct TurnStore: Sendable {
    /// One stored turn for recall: what was asked, what was said, and when. The whole
    /// `CommandRecord` rides in `record`.
    struct Turn: Codable, FetchableRecord, PersistableRecord, Sendable {
        static let databaseTableName = "turn_row"

        /// `CommandRecord.id.uuidString`.
        let id: String
        /// Whose turn this is — `BackendService.userId`, plus `:profile:<id>` outside the default profile.
        /// Every read filters on it, so widening never reaches another account; "" matches none.
        var userId: String
        /// Empty string rather than NULL, because SQLite treats NULLs as distinct.
        var conversationId: String
        var commandText: String
        var responseText: String
        var serviceName: String
        var status: String
        var issuedAt: Date
        /// When this phone wrote the row, which is not `issuedAt`.
        var mirroredAt: Date = Date()
        /// The whole `CommandRecord` as JSON, for History. Nil on rows written before `v43`.
        var record: Data? = nil

        enum CodingKeys: String, CodingKey {
            case id, status, record
            case userId = "user_id"
            case mirroredAt = "mirrored_at"
            case conversationId = "conversation_id"
            case commandText = "command_text"
            case responseText = "response_text"
            case serviceName = "service_name"
            case issuedAt = "issued_at"
        }
    }

    /// How long the phone keeps a turn, and therefore how far back History reaches.
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    /// How many turns one search hands back, per scope, against the Realtime 40,000 token/minute ceiling.
    static func limit(for scope: RecallScope) -> Int { scope == .call ? 3 : 8 }

    /// How many of a widened page are held back for the previous call, so broad matches
    /// cannot crowd it out. Three is one exchange plus its context.
    static let previousCallReserve = 3

    /// The turn limit for a search that named no scope.
    static let legacyLimit = 3

    private let dbPool: DatabasePool?

    init(database: DatabasePool?) {
        dbPool = database
    }

    // MARK: - Schema

    /// `v12-turns`, defined beside the code that reads it.
    static func createSchema(_ db: Database) throws {
        try db.create(table: Turn.databaseTableName) { t in
            t.primaryKey("id", .text)
            t.column("user_id", .text).notNull().defaults(to: "")
            t.column("conversation_id", .text).notNull().defaults(to: "")
            t.column("command_text", .text).notNull()
            t.column("response_text", .text).notNull()
            t.column("service_name", .text).notNull().defaults(to: "")
            t.column("status", .text).notNull().defaults(to: "success")
            t.column("issued_at", .datetime).notNull()
        }
        // Every read filters the owner and then bounds or orders by time; the retention
        // trim scans the second column alone, which a composite index still serves.
        try db.create(index: "turn_row_owner_idx", on: Turn.databaseTableName,
                      columns: ["user_id", "issued_at"])
        // `call` scope filters on this before ranking.
        try db.create(index: "turn_row_conversation_idx", on: Turn.databaseTableName,
                      columns: ["conversation_id"])
        // `synchronize` writes the triggers and backfills. Column order is the `bm25()` argument
        // order in `search`; reordering silently inverts the weighting.
        try db.create(virtualTable: "turn_fts", using: FTS5()) { t in
            t.synchronize(withTable: Turn.databaseTableName)
            t.tokenizer = .porter(wrapping: .unicode61())
            t.column("command_text")
            t.column("response_text")
        }
    }

    /// `v43-turn-record`: History reads the whole record back from here.
    static func addRecord(_ db: Database) throws {
        try db.alter(table: Turn.databaseTableName) { t in
            t.add(column: "record", .blob)
        }
    }

    /// `v13-turn-mirrored-at`. Its own migration because `v12` has shipped: GRDB never re-runs
    /// a migration by name.
    static func addMirroredAt(_ db: Database) throws {
        try db.alter(table: Turn.databaseTableName) { t in
            t.add(column: "mirrored_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
        }
        try db.create(index: "turn_row_mirrored_idx", on: Turn.databaseTableName,
                      columns: ["mirrored_at"])
    }

    // MARK: - Writing

    /// Store one turn. Throwing, so History can tell a stored turn from a lost one.
    func save(_ turn: Turn) async throws {
        guard let dbPool else { throw BackendError.invalidResponse }
        try await dbPool.write { db in
            try turn.save(db)
            try Self.trim(db)
        }
    }

    /// Store one turn, logging rather than throwing a failure.
    func record(_ turn: Turn) async {
        guard let dbPool else { return }
        do {
            try await dbPool.write { db in
                try turn.save(db)
                try Self.trim(db)
            }
        } catch {
            RealtimeLog.log("turns: mirror failed for \(turn.id) — \(error)")
        }
    }

    /// Drop one turn — History's delete, which is also the assistant's memory of it.
    func remove(id: UUID) async throws {
        guard let dbPool else { throw BackendError.invalidResponse }
        try await dbPool.write { db in
            _ = try Turn.deleteOne(db, key: id.uuidString)
        }
    }

    /// One owner's turns for History, newest first. `owner` is `contextOwner`, so a profile
    /// sees its own turns and the default profile sees the unscoped ones.
    func history(owner: String) async throws -> [CommandRecord] {
        guard let dbPool, !owner.isEmpty else { return [] }
        let rows = try await dbPool.read { db in
            try Turn.filter(Column("user_id") == owner).order(Column("issued_at").desc).fetchAll(db)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return rows.map { row in
            if let data = row.record {
                do { return try decoder.decode(CommandRecord.self, from: data) }
                catch { RealtimeLog.log("turns: stored record \(row.id) unreadable — \(error)") }
            }
            return row.commandRecord
        }
    }

    /// One account's turns, at sign-out. Scoped by `userId` because the purge is detached and can
    /// land after the next account has written; nil clears everything.
    func purge(userId: String? = nil) async {
        guard let dbPool else { return }
        do {
            try await dbPool.write { db in
                if let userId, !userId.isEmpty {
                    // Unattributed rows too: no widened read can reach them, so nothing else would clean them up.
                    _ = try Turn
                        .filter(sql: "user_id = ? OR user_id = '' OR substr(user_id, 1, ?) = ?",
                                arguments: [userId, (userId + ":profile:").count, userId + ":profile:"])
                        .deleteAll(db)
                } else {
                    _ = try Turn.deleteAll(db)
                }
            }
        } catch {
            RealtimeLog.log("turns: purge failed — \(error)")
        }
    }

    private static func trim(_ db: Database) throws {
        try Turn
            .filter(Column("issued_at") < Date().addingTimeInterval(-retention))
            .deleteAll(db)
    }

    // MARK: - Reading

    /// Turns matching all terms of `query`, else any, best first; the question outweighs the answer.
    /// A nil `scope` is unscoped, the behaviour a broker without the argument still gets.
    func search(
        _ query: String,
        userId: String,
        conversationId: String?,
        scope: RecallScope?,
        limit: Int? = nil
    ) async -> Hits {
        guard let dbPool, !userId.isEmpty else {
            return Hits(matched: [], recent: [], recentIsPreviousCall: false)
        }
        // A blank query is a miss: the model calls with `{}` while thinking, and recency would
        // answer it with the previous call's transcript.
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Hits(matched: [], recent: [], recentIsPreviousCall: false)
        }
        let conversation = conversationId ?? ""
        let cap = limit ?? (scope.map(Self.limit(for:)) ?? Self.legacyLimit)
        // This call always, plus everything since the bound. Unlike the cache, anything said widens.
        let earlier = scope?.reachesEarlier ?? true
        let since = scope?.since() ?? Date.distantPast
        do {
            return try await dbPool.read { db in
                var matched: [Turn] = []
                var weak = false
                for allTokens in [true, false] {
                    let pattern = allTokens
                        ? FTS5Pattern(matchingAllTokensIn: query)
                        : FTS5Pattern(matchingAnyTokenIn: query)
                    guard let pattern else { continue }
                    matched = try Turn.fetchAll(db, sql: """
                        SELECT \(Turn.databaseTableName).*
                        FROM \(Turn.databaseTableName)
                        JOIN turn_fts ON turn_fts.rowid = \(Turn.databaseTableName).rowid
                        WHERE turn_fts MATCH ?
                          AND \(Turn.databaseTableName).user_id = ?
                          AND (\(Turn.databaseTableName).conversation_id = ?
                               OR (? AND \(Turn.databaseTableName).issued_at >= ?))
                        ORDER BY bm25(turn_fts, 5.0, 1.0),
                                 \(Turn.databaseTableName).issued_at DESC
                        LIMIT ?
                        """, arguments: [pattern, userId, conversation, earlier, since, cap])
                    if !matched.isEmpty { weak = !allTokens; break }
                }
                // Topped up with recent turns, kept separate so the caller can say which is which:
                // "what did we discuss on my last call" shares no words with the call it means.
                // Only a weak, any-token page is trimmed to reserve room for the previous call.
                if earlier, weak, matched.count > cap - Self.previousCallReserve {
                    matched = Array(matched.prefix(max(1, cap - Self.previousCallReserve)))
                }
                guard matched.count < cap else {
                    return Hits(matched: matched, recent: [], recentIsPreviousCall: false)
                }
                let seen = matched.map(\.id)
                // The fill is the previous call, not the day: a day-wide fill described the wrong call.
                // Only when the scope reaches earlier calls, or `.call` scope would cross the boundary.
                let previous: String? = earlier ? try String.fetchOne(db, sql: """
                    SELECT conversation_id FROM \(Turn.databaseTableName)
                     WHERE user_id = ? AND conversation_id <> '' AND conversation_id <> ?
                       AND issued_at >= ?
                     ORDER BY issued_at DESC LIMIT 1
                    """, arguments: [userId, conversation, since]) : nil
                if let previous {
                    let rows = try Turn
                        .filter(Column("user_id") == userId)
                        .filter(Column("conversation_id") == previous)
                        .filter(!seen.contains(Column("id")))
                        .order(Column("issued_at").desc)
                        .limit(cap - matched.count)
                        .fetchAll(db)
                    if !rows.isEmpty {
                        // Oldest first: a call reads forward.
                        return Hits(matched: matched,
                                    recent: rows.sorted { $0.issuedAt < $1.issuedAt },
                                    recentIsPreviousCall: true)
                    }
                }
                // No earlier call in reach — fall back to plain recency, which is this call.
                let recent = try Turn
                    .filter(Column("user_id") == userId)
                    .filter(!seen.contains(Column("id")))
                    .filter(Column("conversation_id") == conversation
                        || (earlier && Column("issued_at") >= since))
                    .order(Column("issued_at").desc)
                    .limit(cap - matched.count)
                    .fetchAll(db)
                return Hits(matched: matched, recent: recent, recentIsPreviousCall: false)
            }
        } catch {
            RealtimeLog.log("turns: search failed — \(error)")
            return Hits(matched: [], recent: [], recentIsPreviousCall: false)
        }
    }

    /// What a turn search found, and how, as `LocalContextStore.Result.matched` does.
    struct Hits: Sendable {
        /// Ranked by the query.
        let matched: [Turn]
        /// The rest of the limit, filled by recency rather than by the query.
        let recent: [Turn]
        /// Whether `recent` is the whole previous call rather than a scatter of recent turns.
        /// The caller says "your last call" only when this is true.
        let recentIsPreviousCall: Bool

        var isEmpty: Bool { matched.isEmpty && recent.isEmpty }
    }

    /// One of the day's calls, as the model is shown it.
    struct Call: Sendable {
        let id: String
        let started: Date
        let ended: Date
        let turns: Int
        /// The user's first ask in the call, which answers "what was each one about" without the
        /// model searching once per call.
        let opening: String

        /// The plain shortened start time, before any collision suffix.
        var clock: String { started.formatted(date: .omitted, time: .shortened) }

        /// The handle the model quotes back to read this call: its start time, which the user says too.
        /// Stored because two calls in one minute both get seconds appended by `daySummary`.
        let handle: String

        /// How long the call ran, from turn timestamps, which miss the time around the first and last
        /// turn; nil for a one-turn call rather than a claim that may be untrue.
        var length: String? {
            guard turns > 1 else { return nil }
            let seconds = ended.timeIntervalSince(started)
            guard seconds >= 60 else { return "a minute or so of exchanges" }
            return "\(Int(seconds / 60)) min of exchanges"
        }

        /// The start time alone.
        func label() -> String { handle }
    }


    /// How many calls and turns today holds, which a search cannot count. Today only, from
    /// `startOfDay`; turns with no conversation id are not a call.
    func daySummary(userId: String, now: Date = Date()) async -> (calls: [Call], turns: Int)? {
        guard let dbPool, !userId.isEmpty else { return nil }
        let since = Calendar.current.startOfDay(for: now)
        // One conversation id is one call, however long the pauses within it.
        let rows = try? await dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT conversation_id AS id, COUNT(*) AS turns,
                       MIN(issued_at) AS started, MAX(issued_at) AS ended,
                       (SELECT command_text FROM \(Turn.databaseTableName) t2
                         WHERE t2.conversation_id = t.conversation_id
                           AND t2.user_id = t.user_id
                           AND TRIM(t2.command_text) <> ''
                         ORDER BY t2.issued_at LIMIT 1) AS opening
                  FROM \(Turn.databaseTableName) t
                 WHERE user_id = ? AND issued_at >= ? AND conversation_id <> ''
                 GROUP BY conversation_id
                 ORDER BY started DESC
                """, arguments: [userId, since])
        }
        guard let rows, !rows.isEmpty else { return nil }
        let calls = rows.compactMap { row -> Call? in
            guard let id = row["id"] as String?,
                  let started = row["started"] as Date?,
                  let ended = row["ended"] as Date? else { return nil }
            return Call(id: id, started: started, ended: ended,
                        turns: row["turns"] as Int? ?? 0,
                        opening: (row["opening"] as String? ?? "")
                            .replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespaces),
                        handle: started.formatted(date: .omitted, time: .shortened))
        }
        // A handle shared by two calls gets the seconds on both, so neither silently wins `first(where:)`.
        var counts: [String: Int] = [:]
        for call in calls { counts[call.handle, default: 0] += 1 }
        let resolved = calls.map { call -> Call in
            guard counts[call.handle, default: 0] > 1 else { return call }
            // `.standard`, because "12:40 PM" + ":07" reads back as no time at all.
            return Call(id: call.id, started: call.started, ended: call.ended,
                        turns: call.turns, opening: call.opening,
                        handle: call.started.formatted(date: .omitted, time: .standard))
        }
        let ordered = resolved.sorted { $0.started < $1.started }
        return (calls: ordered, turns: ordered.reduce(0) { $0 + $1.turns })
    }

    /// The turns of one call, named by the start time the day list printed, matched on the minute.
    /// Returns the call too, so the caller can say which conversation it is reading back.
    func turns(ofCallStartingAt handle: String, userId: String, now: Date = Date(),
               limit: Int = 12) async -> (call: Call, turns: [Turn], truncated: Bool)? {
        guard let summary = await daySummary(userId: userId, now: now), let dbPool else {
            return nil
        }
        // Compared with every space stripped: iOS puts a narrow no-break space (U+202F) before AM/PM,
        // and the model quotes it back with an ordinary one.
        func key(_ text: String) -> String {
            text.lowercased().filter { !$0.isWhitespace }
        }
        let wanted = key(handle)
        let hits = summary.calls.filter { key($0.handle) == wanted || key($0.clock) == wanted }
        // Two calls on one handle means a stale handle; picking either would read the wrong call.
        guard hits.count == 1, let call = hits.first else { return nil }
        let turns: [Turn] = (try? await dbPool.read { db in
            try Turn
                .filter(Column("user_id") == userId)
                .filter(Column("conversation_id") == call.id)
                .order(Column("issued_at").asc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
        // The caller has to be told when these are not the whole call.
        return turns.isEmpty ? nil : (call: call, turns: turns, truncated: call.turns > turns.count)
    }

    /// The call handle a query is asking for, when the query is one. Anchored, so "the 3:30 meeting"
    /// still searches; whitespace normalised for U+202F; seconds accepted for `daySummary`'s collisions.
    static func callHandle(in query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let spaced = String(trimmed.map { $0.isWhitespace ? " " : $0 })
        let pattern = "^[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?( ?[AaPp]\\.?[Mm]\\.?)?$"
        guard spaced.range(of: pattern, options: [.regularExpression]) != nil else {
            return nil
        }
        return trimmed
    }
}

extension TurnStore.Turn {
    /// The row for a finished turn. Built on whichever actor holds the record, so the
    /// store itself never touches `@MainActor` state.
    init(_ record: CommandRecord, userId: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do { self.record = try encoder.encode(record) }
        catch { RealtimeLog.log("turns: record \(record.id) not encoded — \(error)") }
        id = record.id.uuidString
        self.userId = userId
        conversationId = record.conversationId?.uuidString ?? ""
        commandText = record.commandText
        responseText = record.responseText
        serviceName = record.serviceName
        status = record.status.rawValue
        issuedAt = record.issuedAt
    }

    /// What History draws for a row written before the whole record was kept.
    var commandRecord: CommandRecord {
        var record = CommandRecord(
            id: UUID(uuidString: id) ?? UUID(), commandText: commandText, responseText: responseText,
            serviceName: serviceName, serviceIcon: CommandRecord.icon(for: serviceName),
            status: CommandRecord.CommandStatus(rawValue: status) ?? .success, issuedAt: issuedAt,
            conversationId: UUID(uuidString: conversationId))
        record.profile_id = userId.components(separatedBy: ":profile:").dropFirst().first
        return record
    }

    /// `09:41`, in the user's own locale.
    var clock: String {
        issuedAt.formatted(date: .omitted, time: .shortened)
    }
}
