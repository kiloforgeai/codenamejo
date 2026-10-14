import FactoryKit
import Foundation
import GRDB

/// Full messages for live cached mail, so reading one aloud is a local lookup. Live means unread, or in
/// the inbox inside the important window; `pruneBodies` drops the rest and the cascade follows `mail_message`.
extension MailStore {
    struct Body: Codable, FetchableRecord, PersistableRecord, Sendable {
        static let databaseTableName = "mail_message_body"
        var user_id: String = ""

        let account: String
        let messageId: String
        /// `GmailAPI.FullMessage` as JSON.
        let payload: Data
        let cachedAt: Date
    }

    /// A body bigger than this is fetched each time rather than stored.
    static let maxBodyBytes = 512 * 1024

    static func createBodies(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS mail_message_body (
                user_id TEXT NOT NULL, account TEXT NOT NULL, messageId TEXT NOT NULL,
                payload BLOB NOT NULL, cachedAt DATETIME NOT NULL,
                PRIMARY KEY (user_id, account, messageId),
                FOREIGN KEY (user_id, account, messageId) REFERENCES mail_message(user_id, account, id) ON DELETE CASCADE
            );
            """)
    }

    /// The stored message, or nil on a miss.
    func body(account: String, id: String) async -> GmailAPI.FullMessage? {
        guard let dbPool = database else { return nil }
        do {
            let row = try await dbPool.read { db in
                try Body.filter(Column("user_id") == userId).filter(Column("account") == account)
                    .filter(Column("messageId") == id).fetchOne(db)
            }
            guard let row else { return nil }
            return try JSONDecoder().decode(GmailAPI.FullMessage.self, from: row.payload)
        } catch {
            RealtimeLog.log("mailStore: body read failed — \(error)")
            return nil
        }
    }

    /// Store these messages' bodies. Only mail with a cached header row is kept; anything else is skipped.
    func saveBodies(_ messages: [GmailAPI.FullMessage], account: String) async {
        guard let dbPool = database, !messages.isEmpty else { return }
        do {
            let encoder = JSONEncoder()
            let rows = try messages.map { ($0.id, try encoder.encode($0)) }.filter { $0.1.count <= Self.maxBodyBytes }
            try await dbPool.write { db in
                for (id, payload) in rows {
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO mail_message_body (user_id, account, messageId, payload, cachedAt)
                        SELECT ?, ?, ?, ?, ? WHERE EXISTS (
                            SELECT 1 FROM mail_message WHERE user_id = ? AND account = ? AND id = ?)
                        """, arguments: [userId, account, id, payload, Date(), userId, account, id])
                }
            }
        } catch {
            RealtimeLog.log("mailStore: body write failed — \(error)")
        }
    }

    /// Live messages with no stored body, newest first.
    func idsMissingBodies(account: String, limit: Int, now: Date = Date()) async -> [String] {
        guard let dbPool = database else { return [] }
        do {
            return try await dbPool.read { db in
                try String.fetchAll(db, sql: """
                    SELECT m.id FROM mail_message m
                     WHERE m.user_id = ? AND m.account = ? AND \(Self.liveSQL)
                       AND NOT EXISTS (SELECT 1 FROM mail_message_body b
                                        WHERE b.user_id = m.user_id AND b.account = m.account AND b.messageId = m.id)
                     ORDER BY m.internalDate DESC LIMIT ?
                    """, arguments: [userId, account, Self.importantSince(now: now), limit])
            }
        } catch {
            RealtimeLog.log("mailStore: missing bodies unavailable — \(error)")
            return []
        }
    }

    /// Drop bodies whose message was read and archived, or aged out of the window.
    func pruneBodies(account: String, now: Date = Date()) async {
        guard let dbPool = database else { return }
        do {
            try await dbPool.write { db in
                try db.execute(sql: """
                    DELETE FROM mail_message_body
                     WHERE user_id = ? AND account = ? AND messageId NOT IN (
                        SELECT m.id FROM mail_message m WHERE m.user_id = ? AND m.account = ? AND \(Self.liveSQL))
                    """, arguments: [userId, account, userId, account, Self.importantSince(now: now)])
            }
        } catch {
            RealtimeLog.log("mailStore: body prune failed — \(error)")
        }
    }

    /// Every stored body for this user, for when bodies become withheld.
    func purgeBodies() async {
        guard let dbPool = database else { return }
        do {
            _ = try await dbPool.write { db in try Body.filter(Column("user_id") == userId).deleteAll(db) }
        } catch {
            RealtimeLog.log("mailStore: body purge failed — \(error)")
        }
    }

    /// Row `m` is unread, or in the inbox since the bound `?` (an `importantSince` value).
    private static let liveSQL = """
        (EXISTS (SELECT 1 FROM mail_message_label l WHERE l.user_id = m.user_id AND l.account = m.account
                    AND l.messageId = m.id AND l.label = 'UNREAD')
         OR (m.internalDate >= ? AND EXISTS (SELECT 1 FROM mail_message_label l WHERE l.user_id = m.user_id
                    AND l.account = m.account AND l.messageId = m.id AND l.label = 'INBOX')))
        """
}

/// Full-message reads that try the body cache before Gmail.
enum MailBodyCache {
    static var withheld: Bool { MailHeadersOnly.withholdsBodies || ProfileRuntime.snapshot?.mailHeadersOnly == true }

    /// The first of these accounts holding the message, with its body.
    static func cached(accounts: [String], id: String, store: MailStore) async -> (account: String, message: GmailAPI.FullMessage)? {
        guard !withheld else { return nil }
        for account in accounts {
            if let message = await store.body(account: account, id: id) { return (account, message) }
        }
        return nil
    }

    /// The stored message, else Gmail's, which is then stored.
    static func fullMessage(account: String, id: String, token: () async throws -> String) async throws -> GmailAPI.FullMessage {
        let store = await Container.shared.mailStore()
        if let hit = await cached(accounts: [account], id: id, store: store) { return hit.message }
        let message = try await GmailAPI.fullMessage(token: try await token(), id: id)
        if !withheld { await store.saveBodies([message], account: account) }
        return message
    }
}
