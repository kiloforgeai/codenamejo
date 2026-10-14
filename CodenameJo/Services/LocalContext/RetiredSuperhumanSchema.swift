import GRDB

/// The Superhuman section, snooze and snippet cache, kept only so the shipped migrations still
/// run: v19 creates it on an install that never had it, and v40 drops it.
enum RetiredSuperhumanSchema {
    /// v19, as shipped.
    static func createSchema(_ db: Database) throws {
        try db.create(table: "mail_superhuman_state") { t in
            t.column("userId", .text).notNull()
            t.column("account", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("payload", .blob).notNull()
            t.column("fetchedAt", .datetime).notNull()
            t.primaryKey(["userId", "account", "kind"])
        }
    }

    static func drop(_ db: Database) throws {
        try db.execute(sql: "DROP TABLE IF EXISTS mail_superhuman_state")
    }
}
