import Foundation
import GRDB

/// One cached lookup. `result` is the tool's own output, not the `mcp_call` envelope;
/// a failed call's error lands in `result` with a `kind` of `error`.
struct LocalContextRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "context_rows"

    var id: Int64?
    /// `m_1`, `m_2`, … within one conversation, the handle the model quotes back.
    /// `DatabasePool` has one writer, so two inserts cannot mint the same key.
    var key: String
    /// `note`, `message` for a cached lookup, or `error` for a call that came back failed.
    var kind: String
    var request: String
    var result: String
    /// Empty on every row. Kept because the index weights it between `request` and `result`.
    var summary: String
    /// `RealtimeService.activeConversationId`, part of the uniqueness key. Empty string rather than
    /// `NULL`, because SQLite treats NULLs as distinct in a unique index.
    var conversationId: String
    /// `BackendService.userId`, or empty when none was signed in. Only the widened `today` read
    /// needs it; inside a conversation the conversation id already scopes the row.
    var userId: String = ""
    /// The `request` + `result` head as a normalised 512-float vector, or `nil` on rows
    /// written before the column existed and on any row `NLEmbedding` could not embed.
    var embedding: Data?
    var createdAt: Date

    /// `save_context`'s default `kind`, and the only kind allowed out of its own conversation;
    /// every other row is an automatic snapshot of something that moves.
    static let noteKind = "note"

    enum CodingKeys: String, CodingKey {
        case id, key, kind, request, result, summary, embedding
        case userId = "user_id"
        case conversationId = "conversation_id"
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension LocalContextRow {
    /// How old this row is: minutes up to an hour, then hours, then days. Nothing expires,
    /// so this is the only signal that a stored answer is stale.
    func age(now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(createdAt))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}
