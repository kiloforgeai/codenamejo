import XCTest
import GRDB
@testable import CodenameJo

/// Full bodies kept beside cached mail so a read is local: what is kept, for how long, and for whom.
final class MailBodyCacheTests: XCTestCase {
    private var path: URL!
    private var db: DatabasePool!
    private let account = "owner@test"
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    override func setUp() async throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        db = try DatabasePool(path: path.path)
        try await db.write {
            try MailStore.createUserScopedSchema($0)
            try DailyEmailQueueSnapshotRecord.createSchema($0)
            try DailyEmailQueueSnapshotRecord.addOwner($0)
            try EmailCleanupRecord.createSchema($0)
        }
        MailHeadersOnly.set(false)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: MailHeadersOnly.storageKey)
        try? db.close()
        try? FileManager.default.removeItem(at: path)
    }

    private var recent: Int64 { Int64(now.timeIntervalSince1970 * 1000) - 60_000 }

    private func ingest(_ store: MailStore, id: String, labels: [String], date: Int64? = nil) async throws {
        let labelJSON = labels.map { "\"\($0)\"" }.joined(separator: ",")
        let detail = try JSONDecoder().decode(GmailAPI.MessageDetail.self, from: Data("""
            {"id":"\(id)","threadId":"t-\(id)","labelIds":[\(labelJSON)],"snippet":"hi","internalDate":"\(date ?? recent)"}
            """.utf8))
        await store.apply([.init(detail: detail, account: account)], account: account, historyId: "1")
    }

    private func message(_ id: String, text: String = "hello") -> GmailAPI.FullMessage {
        GmailAPI.FullMessage(id: id, threadId: "t-\(id)", labelIds: ["INBOX"], internalDate: nil,
            payload: GmailAPI.FullPart(mimeType: "text/plain", filename: "", headers: nil,
                body: GmailAPI.PartBody(size: text.utf8.count, data: Data(text.utf8).base64EncodedString().replacingOccurrences(of: "=", with: ""), attachmentId: nil),
                parts: nil))
    }

    func testABodyRoundTripsAndIsReadAsTheEnvelope() async throws {
        let store = MailStore(database: db, userId: "owner")
        try await ingest(store, id: "m1", labels: ["INBOX", "UNREAD"])
        await store.saveBodies([message("m1")], account: account)

        let hit = await MailBodyCache.cached(accounts: ["other@test", account], id: "m1", store: store)
        XCTAssertEqual(hit?.account, account)
        XCTAssertEqual(hit.map { GmailReadTools.envelope($0.message)["body"] as? String }, "hello")
    }

    func testOnlyMailWithACachedHeaderAndAReasonableSizeIsStored() async throws {
        let store = MailStore(database: db, userId: "owner")
        try await ingest(store, id: "big", labels: ["INBOX"])
        await store.saveBodies([message("unknown"), message("big", text: String(repeating: "x", count: MailStore.maxBodyBytes))],
                               account: account)
        let unknown = await store.body(account: account, id: "unknown")
        let big = await store.body(account: account, id: "big")
        XCTAssertNil(unknown)
        XCTAssertNil(big)
    }

    func testMissingBodiesAreLiveMailNewestFirstAndPruneDropsTheRest() async throws {
        let store = MailStore(database: db, userId: "owner")
        let old = Int64(now.timeIntervalSince1970 * 1000) - 30 * 24 * 3_600_000
        try await ingest(store, id: "unread-old", labels: ["UNREAD"], date: old)
        try await ingest(store, id: "inbox-new", labels: ["INBOX"])
        try await ingest(store, id: "inbox-old", labels: ["INBOX"], date: old)
        try await ingest(store, id: "archived", labels: [])

        let missing = await store.idsMissingBodies(account: account, limit: 10, now: now)
        XCTAssertEqual(missing, ["inbox-new", "unread-old"])

        await store.saveBodies([message("inbox-new"), message("unread-old"), message("archived")], account: account)
        let stillMissing = await store.idsMissingBodies(account: account, limit: 10, now: now)
        XCTAssertTrue(stillMissing.isEmpty)

        await store.clearUnread(["unread-old"])
        await store.pruneBodies(account: account, now: now)
        let kept = await store.body(account: account, id: "inbox-new")
        let read = await store.body(account: account, id: "unread-old")
        let archived = await store.body(account: account, id: "archived")
        XCTAssertNotNil(kept)
        XCTAssertNil(read, "read and outside the inbox window")
        XCTAssertNil(archived)
    }

    func testPurgesTakeTheBodiesAndOtherUsersNeverSeeThem() async throws {
        let owner = MailStore(database: db, userId: "owner")
        let other = MailStore(database: db, userId: "other")
        for store in [owner, other] {
            try await ingest(store, id: "m1", labels: ["INBOX"])
            try await ingest(store, id: "m2", labels: ["INBOX"])
        }
        await owner.saveBodies([message("m1"), message("m2")], account: account)

        let leaked = await other.body(account: account, id: "m1")
        XCTAssertNil(leaked)

        await owner.purge(account: account)
        let afterDisconnect = await owner.body(account: account, id: "m1")
        XCTAssertNil(afterDisconnect)

        try await ingest(owner, id: "m1", labels: ["INBOX"])
        await owner.saveBodies([message("m1")], account: account)
        await owner.purgeAll()
        let afterSignOut = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM mail_message_body") }
        XCTAssertEqual(afterSignOut, 0)
    }

    func testHeadersOnlyServesNothingAndPurgeEmptiesTheTable() async throws {
        let store = MailStore(database: db, userId: "owner")
        try await ingest(store, id: "m1", labels: ["INBOX"])
        await store.saveBodies([message("m1")], account: account)

        MailHeadersOnly.set(true)
        let withheld = await MailBodyCache.cached(accounts: [account], id: "m1", store: store)
        XCTAssertNil(withheld)
        await store.purgeBodies()
        MailHeadersOnly.set(false)
        let after = await store.body(account: account, id: "m1")
        XCTAssertNil(after)
    }

    func testTheMigratorCreatesTheTable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let pool = try DatabasePool(path: url.path)
        defer { try? pool.close() }
        try LocalContextStore.migrator(installId: { "install" }).migrate(pool)
        let exists = try await pool.read { try $0.tableExists(MailStore.Body.databaseTableName) }
        XCTAssertTrue(exists)
    }
}
