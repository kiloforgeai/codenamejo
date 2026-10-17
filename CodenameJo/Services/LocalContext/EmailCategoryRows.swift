import Foundation
import GRDB

/// Each mailbox's email categories and the playbook for each, in `context.sqlite`. Every row carries `user_id`.
struct EmailCategoryRows: Sendable {
    struct Row: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
        static let databaseTableName = "email_category"
        var user_id: String
        /// Lowercased.
        var account: String
        var name: String
        var description: String
        var last_seen: Date
        var playbook: String?
    }

    struct Unavailable: Error {}

    static let maxCategories = 20

    static func createSchema(_ db: Database) throws {
        try db.create(table: Row.databaseTableName) { t in
            t.column("user_id", .text).notNull()
            t.column("account", .text).notNull()
            t.column("name", .text).notNull()
            t.column("description", .text).notNull()
            t.column("last_seen", .datetime).notNull()
            t.column("playbook", .text)
            t.primaryKey(["user_id", "account", "name"])
        }
    }

    let dbPool: DatabasePool?

    private func pool() throws -> DatabasePool {
        guard let dbPool else { throw Unavailable() }
        return dbPool
    }

    /// The mailbox's categories, most recently seen first.
    func known(userId: String, account: String) async throws -> [Row] {
        try await pool().read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM email_category WHERE user_id = ? AND account = ?
                ORDER BY last_seen DESC LIMIT \(Self.maxCategories)
                """, arguments: [userId, account.lowercased()])
        }
    }

    func category(userId: String, account: String, name: String) async throws -> Row? {
        try await pool().read { db in
            try Row.fetchOne(db, key: ["user_id": userId, "account": account.lowercased(), "name": name])
        }
    }

    /// Marks a category seen, creating it when new. Beyond the cap the least recently seen drops off.
    func touch(userId: String, account: String, name: String, description: String, now: Date = Date()) async throws {
        let account = account.lowercased()
        try await pool().write { db in
            try db.execute(sql: """
                INSERT INTO email_category (user_id, account, name, description, last_seen) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (user_id, account, name) DO UPDATE SET last_seen = excluded.last_seen
                """, arguments: [userId, account, name, description, now])
            try db.execute(sql: """
                DELETE FROM email_category WHERE user_id = ? AND account = ? AND name NOT IN (
                  SELECT name FROM email_category WHERE user_id = ? AND account = ?
                  ORDER BY last_seen DESC LIMIT \(Self.maxCategories))
                """, arguments: [userId, account, userId, account])
        }
    }

    func setPlaybook(userId: String, account: String, name: String, playbook: String) async throws {
        try await pool().write { db in
            try db.execute(sql: "UPDATE email_category SET playbook = ? WHERE user_id = ? AND account = ? AND name = ?",
                           arguments: [playbook, userId, account.lowercased(), name])
        }
    }

    /// Playbooks are learned from transcripts, so they leave with the account at sign-out.
    func purge(userId: String) async throws {
        try await pool().write { db in try db.execute(sql: "DELETE FROM email_category WHERE user_id = ?", arguments: [userId]) }
    }
}
