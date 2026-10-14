import XCTest
import GRDB
@testable import CodenameJo

final class MailOwnershipTests: XCTestCase {
    func testSameMailboxAndIDsStayIsolatedAcrossUsers() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = try DatabasePool(path: path.path)
        defer { try? db.close(); try? FileManager.default.removeItem(at: path) }
        try await db.write {
            try MailStore.createUserScopedSchema($0)
            try DailyEmailQueueSnapshotRecord.createSchema($0)
            try DailyEmailQueueSnapshotRecord.addOwner($0)
            try EmailCleanupRecord.createSchema($0)
        }
        let a = MailStore(database: db, userId: "owner'a")
        let b = MailStore(database: db, userId: "owner-b")
        let detail = try JSONDecoder().decode(GmailAPI.MessageDetail.self, from: Data("""
            {"id":"same","threadId":"thread","labelIds":["INBOX","UNREAD"],"snippet":"invoice","internalDate":"1"}
            """.utf8))
        let batch = [MailStore.Ingest(detail: detail, account: "shared@test")]
        for store in [a, b] {
            await store.apply(batch, account: "shared@test", historyId: store.userId, inboxUnread: 1)
            await store.applyDrafts([.init(id: "draft", messageId: "draft-message", threadId: "thread",
                account: "shared@test", recipient: nil, subject: "invoice", snippet: nil,
                internalDate: 1, cachedAt: Date())], account: "shared@test")
        }
        await a.clearUnreadDurably(id: "same", account: "shared@test")
        let aUnread = await a.unreadIds(among: ["same"])
        let bUnread = await b.unreadIds(among: ["same"])
        let aPending = await a.pendingMarkReads(account: "shared@test")
        let bPending = await b.pendingMarkReads(account: "shared@test")
        XCTAssertEqual(aUnread, [])
        XCTAssertEqual(bUnread, ["same"])
        XCTAssertEqual(aPending.count, 1)
        XCTAssertTrue(bPending.isEmpty)
        let aSearch = await a.search("invoice")
        let bSearch = await b.search("invoice")
        XCTAssertEqual(aSearch.map(\.user_id), [a.userId])
        XCTAssertEqual(bSearch.map(\.user_id), [b.userId])
        let removed = await a.purge(account: "shared@test")
        XCTAssertEqual(removed, 1)
        let bRows = await b.messages(ids: ["same"])
        let bDrafts = await b.drafts()
        let bState = await b.syncState(account: "shared@test")
        XCTAssertEqual(bRows.count, 1)
        XCTAssertEqual(bDrafts.count, 1)
        XCTAssertEqual(bState?.historyId, b.userId)
        let anonymous = MailStore(database: db, userId: "")
        let anonymousRows = await anonymous.messages(ids: ["same"])
        XCTAssertTrue(anonymousRows.isEmpty)
    }

    /// **The collision `v29` exists for.** A raw Gmail id is unique inside one mailbox and
    /// nothing stops two connected accounts being handed the same one. Keyed on
    /// `(user_id, id)` the second copy replaced the first, its labels landed on whichever
    /// row survived, and one pending mark-read could exist for both.
    func testSameRawIDInTwoMailboxesKeepsBothRows() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = try DatabasePool(path: path.path)
        defer { try? db.close(); try? FileManager.default.removeItem(at: path) }
        try await db.write { try MailStore.createUserScopedSchema($0) }
        let store = MailStore(database: db, userId: "owner")
        let detail = try JSONDecoder().decode(GmailAPI.MessageDetail.self, from: Data("""
            {"id":"same","threadId":"thread","labelIds":["INBOX","UNREAD"],"snippet":"invoice","internalDate":"1"}
            """.utf8))
        for account in ["first@test", "second@test"] {
            await store.apply([MailStore.Ingest(detail: detail, account: account)],
                              account: account, historyId: account, inboxUnread: 1)
        }

        let both = await store.messages(ids: ["same"])
        XCTAssertEqual(Set(both.map(\.account)), ["first@test", "second@test"],
                       "each mailbox keeps its own copy of the id")

        // Labels are per mailbox too, so clearing one copy cannot clear the other. Read the
        // rows directly: `unreadIds(among:)` asks across mailboxes and cannot show the split.
        await store.clearUnreadDurably(id: "same", account: "first@test")
        let unreadAccounts = try await db.read { db in
            try String.fetchAll(db, sql: "SELECT account FROM mail_message_label "
                + "WHERE messageId = 'same' AND label = 'UNREAD'")
        }
        XCTAssertEqual(unreadAccounts, ["second@test"],
                       "only the mailbox that was read loses its UNREAD row")

        // And so is the outbox: a mark that has not landed belongs to one mailbox.
        await store.clearUnreadDurably(id: "same", account: "second@test")
        let firstPending = await store.pendingMarkReads(account: "first@test")
        let secondPending = await store.pendingMarkReads(account: "second@test")
        XCTAssertEqual(firstPending.count, 1)
        XCTAssertEqual(secondPending.count, 1, "both mailboxes can hold a pending mark-read for one id")
    }

    /// `mail_draft` was the table `v29` nearly left behind: it carries an account column and
    /// two indexes that use it, but its key did not.
    func testSameDraftIDInTwoMailboxesKeepsBothRows() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = try DatabasePool(path: path.path)
        defer { try? db.close(); try? FileManager.default.removeItem(at: path) }
        try await db.write { try MailStore.createUserScopedSchema($0) }
        let store = MailStore(database: db, userId: "owner")
        for account in ["first@test", "second@test"] {
            await store.applyDrafts([.init(id: "draft", messageId: "draft-message", threadId: "thread",
                account: account, recipient: nil, subject: "invoice", snippet: nil,
                internalDate: 1, cachedAt: Date())], account: account)
        }
        let drafts = await store.drafts()
        XCTAssertEqual(Set(drafts.map(\.account)), ["first@test", "second@test"])
        XCTAssertEqual(drafts.filter { $0.id == "draft" }.count, 2)
    }

    func testUpgradeDiscardsUnownedCacheAndReopens() async throws {
        try await checkCacheUpgrade(alreadyMigrated: false)
    }

    func testAlreadyMigratedLegacyCacheIsRemovedAndReopens() async throws {
        try await checkCacheUpgrade(alreadyMigrated: true)
    }

    private func checkCacheUpgrade(alreadyMigrated: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("context.sqlite")
        let old = try DatabaseQueue(path: url.path)
        try LocalContextStore.migrator.migrate(old, upTo: "v23-gmail-reply-ancestry")
        try await old.write { db in
            try db.execute(sql: "INSERT INTO mail_message(id, account, threadId, cachedAt) VALUES ('old', 'shared@test', 'thread', 0)")
            try db.execute(sql: "INSERT INTO mail_draft(id, messageId, threadId, account, cachedAt) VALUES ('old-draft', 'old', 'thread', 'shared@test', 0)")
            try db.execute(sql: "INSERT INTO mail_message_label VALUES ('old', 'UNREAD')")
            try db.execute(sql: "INSERT INTO mail_mark_read_outbox VALUES ('old', 'shared@test')")
            try db.execute(sql: "INSERT INTO mail_sync_state(account, lastSyncedAt, historyId) VALUES ('shared@test', 0, 'stale')")
        }
        if alreadyMigrated {
            try await old.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA foreign_keys = OFF; PRAGMA legacy_alter_table = ON")
                for table in ["mail_message_label", "mail_mark_read_outbox", "mail_message",
                              "mail_draft", "mail_sync_state", "mail_message_fts"] {
                    try db.execute(sql: "ALTER TABLE \(table) RENAME TO \(table)_legacy_unowned")
                }
                for name in ["mail_message_fts_insert", "mail_message_fts_delete", "mail_message_fts_update"] {
                    try db.execute(sql: "DROP TRIGGER IF EXISTS \(name)")
                }
                for name in ["mail_message_account_date_idx", "mail_message_thread_idx", "mail_message_label_idx",
                             "mail_draft_account_date_idx", "mail_draft_account_thread_idx"] {
                    try db.execute(sql: "DROP INDEX IF EXISTS \(name)")
                }
                try MailStore.createUserScopedSchema(db)
                try db.execute(sql: "INSERT INTO mail_message(user_id, id, account, threadId, cachedAt) VALUES ('owner', 'owned', 'shared@test', 'thread', 0)")
                try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v24-mail-user-ownership')")
                try db.execute(sql: "PRAGMA legacy_alter_table = OFF; PRAGMA foreign_keys = ON")
                XCTAssertThrowsError(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check"))
            }
        }
        try old.close()
        let pool = try XCTUnwrap(LocalContextStore(url: url).dbPool)
        try await pool.read { db in
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mail_message WHERE id = 'old'"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mail_sync_state"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mail_draft"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE '%legacy_unowned%'"), 0)
            // Nothing survives either way now: `v29` re-keys the cache by dropping it, so an
            // owned row goes with the rest and the next refresh brings it back from Gmail.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mail_message WHERE id = 'owned'"), 0)
        }
        let mail = MailStore(database: pool, userId: "owner")
        let detail = try JSONDecoder().decode(GmailAPI.MessageDetail.self, from: Data("""
            {"id":"fresh","threadId":"thread","labelIds":["INBOX","UNREAD"],"snippet":"invoice","internalDate":"1"}
            """.utf8))
        await mail.apply([.init(detail: detail, account: "shared@test")], account: "shared@test", historyId: "fresh", inboxUnread: 1)
        try pool.close()
        let reopened = try XCTUnwrap(LocalContextStore(url: url).dbPool)
        defer { try? reopened.close() }
        let refreshed = MailStore(database: reopened, userId: "owner")
        let rows = await refreshed.messages(ids: ["fresh"])
        XCTAssertEqual(rows.count, 1)
        await refreshed.clearUnreadDurably(id: "fresh", account: "shared@test")
        let pending = await refreshed.pendingMarkReads(account: "shared@test")
        XCTAssertEqual(pending.count, 1)
        let matches = await refreshed.search("invoice")
        XCTAssertEqual(matches.map(\.id), ["fresh"])
        try await reopened.read { db in
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testThreadHydrationOverlapsRequestsWithinLimit() async {
        actor Probe {
            var active = 0
            var peak = 0
            func fetch(_ id: String) async -> String {
                active += 1
                peak = max(peak, active)
                try? await Task.sleep(for: .milliseconds(20))
                active -= 1
                return id
            }
        }
        let probe = Probe()
        let ids = (0..<12).map(String.init)
        let result = await LocalTriageQueue.threadContexts(ids: ids + ids, limit: 4) { await probe.fetch($0) }
        let peak = await probe.peak
        XCTAssertEqual(result.count, 12)
        XCTAssertEqual(peak, 4)
    }
}
