import Foundation
import GRDB

/// The user's saved voice commands, in `context.sqlite`. Every row carries `user_id` and the
/// profile it belongs to (`""` for the default profile), and a keyword is unique within that pair.
struct CustomCommandRows: Sendable {
    struct Row: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
        static let databaseTableName = "custom_command"
        var user_id: String
        var profile_id: String
        var id: String
        /// Normalised (`CustomCommandRules.normalise`).
        var keyword: String
        var spoken: String
        var instruction: String
        /// `[CommandAction]` as JSON.
        var actions: String
        var enabled: Bool
        var created_at: Date

        var value: CustomCommand {
            CustomCommand(id: id, keyword: keyword, spoken: spoken, instruction: instruction,
                          actions: (try? JSONDecoder().decode([CommandAction].self, from: Data(actions.utf8))) ?? [],
                          enabled: enabled, createdAt: created_at)
        }
    }

    struct Unavailable: Error {}

    static func createSchema(_ db: Database) throws {
        try db.create(table: Row.databaseTableName) { t in
            t.column("user_id", .text).notNull()
            t.column("profile_id", .text).notNull()
            t.column("id", .text).notNull()
            t.column("keyword", .text).notNull()
            t.column("spoken", .text).notNull()
            t.column("instruction", .text).notNull()
            t.column("actions", .text).notNull()
            t.column("enabled", .boolean).notNull().defaults(to: true)
            t.column("created_at", .datetime).notNull()
            t.primaryKey(["user_id", "id"])
        }
        try db.execute(sql: "CREATE UNIQUE INDEX custom_command_keyword ON custom_command(user_id, profile_id, keyword)")
    }

    let dbPool: DatabasePool?

    private func pool() throws -> DatabasePool {
        guard let dbPool else { throw Unavailable() }
        return dbPool
    }

    /// Every command in the profile, enabled or not, newest first.
    func all(userId: String, profileId: String) async throws -> [CustomCommand] {
        try await pool().read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM custom_command WHERE user_id = ? AND profile_id = ? ORDER BY created_at DESC
                """, arguments: [userId, profileId]).map(\.value)
        }
    }

    /// Creates the command, or replaces the steps, label and spelling on the one that already has
    /// this keyword. **Steps are replaced wholesale**: "no, research means…" is a correction, and a
    /// merge would leave the old steps running beside the new. `id` and `enabled` are kept, so a
    /// command switched off stays off.
    func save(userId: String, profileId: String, keyword: String, spoken: String, label: String,
              actions: [CommandAction], now: Date = Date()) async throws -> CustomCommand {
        let json = String(decoding: try JSONEncoder().encode(actions), as: UTF8.self)
        return try await pool().write { db in
            try db.execute(sql: """
                INSERT INTO custom_command (user_id, profile_id, id, keyword, spoken, instruction, actions, enabled, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)
                ON CONFLICT (user_id, profile_id, keyword) DO UPDATE SET
                  spoken = excluded.spoken, instruction = excluded.instruction, actions = excluded.actions
                """, arguments: [userId, profileId, UUID().uuidString, keyword, spoken, label, json, now])
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM custom_command WHERE user_id = ? AND profile_id = ? AND keyword = ?
                """, arguments: [userId, profileId, keyword]) else { throw Unavailable() }
            return row.value
        }
    }

    /// Exact keyword only. Nil when nothing matched — the caller refuses rather than reporting success.
    func delete(userId: String, profileId: String, keyword: String) async throws -> CustomCommand? {
        try await pool().write { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT * FROM custom_command WHERE user_id = ? AND profile_id = ? AND keyword = ?
                """, arguments: [userId, profileId, keyword])
            if let row { _ = try row.delete(db) }
            return row?.value
        }
    }

    /// Exact keyword only. Nil when nothing matched.
    func setEnabled(userId: String, profileId: String, keyword: String, enabled: Bool) async throws -> CustomCommand? {
        try await pool().write { db in
            try db.execute(sql: """
                UPDATE custom_command SET enabled = ? WHERE user_id = ? AND profile_id = ? AND keyword = ?
                """, arguments: [enabled, userId, profileId, keyword])
            return try Row.fetchOne(db, sql: """
                SELECT * FROM custom_command WHERE user_id = ? AND profile_id = ? AND keyword = ?
                """, arguments: [userId, profileId, keyword])?.value
        }
    }

    /// A deleted profile's commands have nowhere to run.
    func purge(userId: String, profileId: String) async throws {
        try await pool().write { db in
            try db.execute(sql: "DELETE FROM custom_command WHERE user_id = ? AND profile_id = ?",
                           arguments: [userId, profileId])
        }
    }

    func purge(userId: String) async throws {
        try await pool().write { db in try db.execute(sql: "DELETE FROM custom_command WHERE user_id = ?", arguments: [userId]) }
    }
}
