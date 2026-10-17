import Foundation
import GRDB
import XCTest
@testable import CodenameJo

/// `v45-install-identity`: a phone upgrading from the Better Auth build keeps its profiles,
/// queue, categories and turns, re-owned by the install id.
final class InstallIdentityMigrationTests: XCTestCase {
    private var path: URL!
    private let old = "ba-" + UUID().uuidString
    private let install = "install-" + UUID().uuidString

    override func setUp() async throws {
        try await super.setUp()
        path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: path)
        try? FileManager.default.removeItem(at: DealtWithLog.url(userID: old))
        try? FileManager.default.removeItem(at: DealtWithLog.url(userID: install))
        try await super.tearDown()
    }

    func testEveryRowTheOldAccountOwnedMovesToTheInstallId() async throws {
        let pool = try DatabasePool(path: path.path)
        let migrator = LocalContextStore.migrator(installId: { self.install })
        try migrator.migrate(pool, upTo: "v44-queue-snapshot-owner")

        // What the Better Auth build left behind.
        let profiles = WorkspaceProfileRows(dbPool: pool)
        let work = try await profiles.create(userId: old, name: "Work")
        try await profiles.adopt(userId: old, emails: ["me@example.test"], into: work.id)
        try await EmailCategoryRows(dbPool: pool).touch(userId: old, account: "me@example.test",
                                                        name: "receipts", description: "Receipts")
        let turns = TurnStore(database: pool)
        await turns.record(TurnStore.Turn(id: "t1", userId: old, conversationId: "c", commandText: "hi",
            responseText: "hello", serviceName: "General", status: "success", issuedAt: Date()))
        await turns.record(TurnStore.Turn(id: "t2", userId: old + ":profile:" + work.id, conversationId: "c",
            commandText: "work", responseText: "ok", serviceName: "General", status: "success", issuedAt: Date()))
        await turns.record(TurnStore.Turn(id: "t3", userId: "", conversationId: "c", commandText: "orphan",
            responseText: "", serviceName: "General", status: "success", issuedAt: Date()))
        try await pool.write { db in
            try DailyEmailQueueSnapshotRecord(key: "k", account: "me@example.test", localDay: "2026-10-12",
                scope: "unread", split: "", payload: Data("{}".utf8), updatedAt: Date()).insert(db)
        }
        DealtWithLog.save(["me@example.test:m1": Date().timeIntervalSince1970], userID: old)

        try migrator.migrate(pool)

        let listed = try await profiles.list(userId: install)
        XCTAssertTrue(listed.contains { $0.id == work.id && $0.name == "Work" })
        let mailboxes = try await profiles.mailboxes(userId: install, profileId: work.id)
        XCTAssertEqual(mailboxes, ["me@example.test"])
        let categories = try await EmailCategoryRows(dbPool: pool).known(userId: install, account: "me@example.test")
        XCTAssertEqual(categories.map(\.name), ["receipts"])
        let owners = try await pool.read { db in
            try [String: String](uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT id, user_id FROM turn_row")
                .map { ($0["id"] as String, $0["user_id"] as String) })
        }
        XCTAssertEqual(owners, ["t1": install, "t2": install + ":profile:" + work.id, "t3": ""])
        let snapshotOwner = try await pool.read { try String.fetchOne($0, sql: "SELECT user_id FROM daily_email_queue_snapshot") }
        XCTAssertEqual(snapshotOwner, install)
        XCTAssertEqual(DealtWithLog.load(userID: install).keys.sorted(), ["me@example.test:m1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: DealtWithLog.url(userID: old).path))
        // No table keeps the old id anywhere.
        let leftovers = try await pool.read { db in
            try InstallIdentity.ownedTables(db).filter { owned in
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(owned.table) WHERE \(owned.column) LIKE ?",
                                  arguments: [self.old + "%"]) ?? 0) > 0
            }.map(\.table)
        }
        XCTAssertEqual(leftovers, [])
        try pool.close()
    }

    func testAFreshInstallMigratesWithoutTouchingAnything() throws {
        let pool = try DatabasePool(path: path.path)
        try LocalContextStore.migrator(installId: { self.install }).migrate(pool)
        let applied = try pool.read { try DatabaseMigrator().appliedIdentifiers($0) }
        XCTAssertTrue(applied.contains("v45-install-identity"))
        try pool.close()
    }

    func testTheUserDefaultsKeysAndValuesThatCarriedTheOldIdFollowIt() throws {
        let suite = "install-identity-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["day": "2026-10-12"], forKey: "dailyEmailQueueCoachingCadence.\(old)")
        defaults.set("p1", forKey: "workspaceProfile.selected.\(old)")
        defaults.set(old, forKey: "userProfileOwnerUserId")
        defaults.set("unrelated", forKey: "something")

        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE owned (id TEXT PRIMARY KEY, user_id TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO owned VALUES ('a', ?)", arguments: [old])
            try InstallIdentity.adopt(install, in: db, defaults: defaults)
        }
        XCTAssertNil(defaults.object(forKey: "dailyEmailQueueCoachingCadence.\(old)"))
        XCTAssertEqual(defaults.dictionary(forKey: "dailyEmailQueueCoachingCadence.\(install)")?["day"] as? String, "2026-10-12")
        XCTAssertEqual(defaults.string(forKey: "workspaceProfile.selected.\(install)"), "p1")
        XCTAssertEqual(defaults.string(forKey: "userProfileOwnerUserId"), install)
        XCTAssertEqual(defaults.string(forKey: "something"), "unrelated")
        XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "SELECT user_id FROM owned") }, install)
    }
}
