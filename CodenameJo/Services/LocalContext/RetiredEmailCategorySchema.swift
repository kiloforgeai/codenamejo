import GRDB

/// Retained only to migrate older databases before removing the retired table.
enum RetiredEmailCategorySchema {
    static func createSchema(_ db: Database) throws {
        try db.create(table: "email_category") { t in
            t.column("user_id", .text).notNull()
            t.column("account", .text).notNull()
            t.column("name", .text).notNull()
            t.column("description", .text).notNull()
            t.column("last_seen", .datetime).notNull()
            t.column("playbook", .text)
            t.primaryKey(["user_id", "account", "name"])
        }
    }

}
