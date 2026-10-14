import GRDB

/// The writing-tone tables, kept only so the shipped migrations still run: v18 and v26 create
/// them on an install that never had them, and v39 drops them.
enum RetiredWritingToneSchema {
    /// v18, as shipped.
    static func createSchema(_ db: Database) throws {
        try createStatusOutbox(db)
        try db.create(table: "tone_sample") { t in
            t.column("messageId", .text).notNull()
            t.column("userId", .text).notNull().defaults(to: "")
            t.column("account", .text).notNull()
            t.column("body", .text).notNull()
            t.column("recipient", .text).notNull().defaults(to: "")
            t.column("sentAt", .integer).notNull().defaults(to: 0)
            t.column("addedAt", .datetime).notNull()
            t.primaryKey(["userId", "messageId"])
        }
        try db.create(index: "tone_sample_recipient_idx", on: "tone_sample", columns: ["account", "recipient"])
        try db.create(index: "tone_sample_account_idx", on: "tone_sample", columns: ["account", "sentAt"])
        try db.create(table: "writing_tone_scan") { t in
            t.column("account", .text).notNull()
            t.column("userId", .text).notNull().defaults(to: "")
            t.primaryKey(["userId", "account"])
            t.column("scannedAt", .datetime).notNull()
            t.column("newestSentAt", .integer).notNull().defaults(to: 0)
            t.column("oldestSentAt", .integer).notNull().defaults(to: 0)
            t.column("uploadedAt", .datetime)
            t.column("uploadedCount", .integer).notNull().defaults(to: 0)
            t.column("seenTotal", .integer).notNull().defaults(to: 0)
        }
        try db.create(table: "writing_tone") { t in
            t.column("account", .text).notNull()
            t.column("userId", .text).notNull().defaults(to: "")
            t.primaryKey(["userId", "account"])
            t.column("tone", .text).notNull()
            t.column("examplesJSON", .text).notNull().defaults(to: "[]")
            t.column("samples", .integer).notNull().defaults(to: 0)
            t.column("learnedAt", .datetime).notNull()
        }
        try db.create(table: "draft_watch") { t in
            t.column("draftId", .text).notNull()
            t.column("userId", .text).notNull().defaults(to: "")
            t.column("account", .text).notNull()
            t.column("threadId", .text).notNull()
            t.column("body", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("resolvedAt", .datetime)
            t.primaryKey(["userId", "draftId"])
        }
        try db.create(index: "draft_watch_thread_idx", on: "draft_watch", columns: ["account", "threadId"])
        try db.create(table: "writing_tone_recipient") { t in
            t.column("userId", .text).notNull().defaults(to: "")
            t.column("account", .text).notNull()
            t.column("recipient", .text).notNull()
            t.column("learnedAt", .datetime).notNull()
            t.primaryKey(["userId", "account", "recipient"])
        }
    }

    /// v26, as shipped.
    static func createStatusOutbox(_ db: Database) throws {
        try db.create(table: "writing_tone_status_outbox", ifNotExists: true) { t in
            t.column("id", .text).notNull()
            t.column("userId", .text).notNull()
            t.column("body", .blob).notNull()
            t.column("createdAt", .datetime).notNull()
            t.primaryKey(["userId", "id"])
        }
    }

    /// v39: the tone tables, and the sent-mail bodies that were cached only for tone learning.
    static func drop(_ db: Database) throws {
        for table in ["tone_sample", "writing_tone_scan", "writing_tone", "draft_watch", "writing_tone_recipient",
                      "writing_tone_status_outbox", "mail_sent_body", "mail_sent_body_sync"] {
            try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
        }
    }
}
