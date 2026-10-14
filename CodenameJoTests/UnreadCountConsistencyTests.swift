import XCTest
import GRDB
@testable import CodenameJo

/// The unread contents and the unread *count* come from two different places — `UNREAD`
/// label rows and `SyncState.inboxUnread` — and nothing repairs the second mid-call. So
/// `dropUnread` moves both together, decrements by the rows it deleted, and never walks a
/// count below the truth or into another mailbox.
final class UnreadCountConsistencyTests: XCTestCase {

    private var path: URL!
    private var db: DatabasePool!
    private var store: MailStore!

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        db = try DatabasePool(path: path.path)
        try db.write {
            try MailStore.createUserScopedSchema($0)
            // A purge reaches every mail-owned table, so they all have to exist or the
            // whole transaction rolls back.
            try DailyEmailQueueSnapshotRecord.createSchema($0)
            try DailyEmailQueueSnapshotRecord.addOwner($0)
            try EmailCleanupRecord.createSchema($0)
        }
        store = MailStore(database: db, userId: "owner")
    }

    override func tearDownWithError() throws {
        try? db.close()
        try? FileManager.default.removeItem(at: path)
    }

    private func ingest(_ id: String, account: String, unread: Bool = true) throws -> MailStore.Ingest {
        let labels = unread ? "[\"INBOX\",\"UNREAD\"]" : "[\"INBOX\"]"
        let detail = try JSONDecoder().decode(GmailAPI.MessageDetail.self, from: Data("""
            {"id":"\(id)","threadId":"thread-\(id)","labelIds":\(labels),
             "snippet":"body","internalDate":"1"}
            """.utf8))
        return MailStore.Ingest(detail: detail, account: account)
    }

    private func seed(_ ids: [String], account: String, count: Int) async throws {
        await store.apply(try ids.map { try ingest($0, account: account) },
                          account: account, historyId: "history", inboxUnread: count)
    }

    private func unreadCount(_ account: String) async -> Int? {
        await store.syncState(account: account)?.inboxUnread
    }

    private func pending(_ account: String) async -> [String] {
        await store.pendingMarkReads(account: account).map(\.messageId)
    }

    func testDroppingUnreadTakesTheCountDownWithTheLabels() async throws {
        try await seed(["a", "b", "c"], account: "work@test", count: 3)
        try await seed(["h1"], account: "home@test", count: 1)

        await store.dropUnread(["a", "b"], account: "work@test")

        let work = await unreadCount("work@test")
        let home = await unreadCount("home@test")
        let unread = await store.unreadIds(among: ["a", "b", "c"])
        let kept = await store.messages(ids: ["a"]).count
        XCTAssertEqual(work, 1)
        XCTAssertEqual(unread, ["c"])
        XCTAssertEqual(home, 1, "another mailbox is untouched")
        XCTAssertEqual(kept, 1, "read mail stays cached; only the label goes")
    }

    /// Called twice for the same archive, the second call deletes nothing — so it must
    /// decrement nothing.
    func testASecondDropOfTheSameMessagesChangesNothing() async throws {
        try await seed(["a", "b", "c"], account: "work@test", count: 3)

        await store.dropUnread(["a", "b"], account: "work@test")
        await store.dropUnread(["a", "b"], account: "work@test")

        let work = await unreadCount("work@test")
        let unread = await store.unreadIds(among: ["a", "b", "c"])
        XCTAssertEqual(work, 1)
        XCTAssertEqual(unread, ["c"])
    }

    /// Decremented by the rows removed, not the ids asked for.
    func testIdsFromAnotherMailboxNeitherClearNorDecrement() async throws {
        try await seed(["a"], account: "work@test", count: 1)
        try await seed(["h1"], account: "home@test", count: 1)

        await store.dropUnread(["h1"], account: "work@test")

        let work = await unreadCount("work@test")
        let home = await unreadCount("home@test")
        let unread = await store.unreadIds(among: ["a", "h1"])
        XCTAssertEqual(work, 1)
        XCTAssertEqual(home, 1)
        XCTAssertEqual(unread, ["a", "h1"])
    }

    /// A count spoken out loud can never be negative — and a message that was already read
    /// has no row to delete, so it cannot take the count down on its way past either.
    func testTheCountIsFlooredAtZeroAndAnAlreadyReadMessageNeverDecrementsIt() async throws {
        await store.apply([try ingest("a", account: "work@test"),
                           try ingest("b", account: "work@test"),
                           try ingest("read", account: "work@test", unread: false)],
                          account: "work@test", historyId: "history", inboxUnread: 1)

        await store.dropUnread(["read"], account: "work@test")
        let afterRead = await unreadCount("work@test")
        XCTAssertEqual(afterRead, 1)

        await store.dropUnread(["a", "b"], account: "work@test")
        let work = await unreadCount("work@test")
        let unread = await store.unreadIds(among: ["a", "b"])
        XCTAssertEqual(work, 0, "two rows went against a claimed one; it floors rather than goes negative")
        XCTAssertEqual(unread, [])
    }

    /// The durable half: the local clear and the "Gmail still needs telling" row commit
    /// together, and the row's job ends when Gmail confirms it.
    func testTheMarkReadOutboxIsScopedToItsMailboxAndClearedOnConfirmation() async throws {
        try await seed(["a", "b"], account: "work@test", count: 2)
        try await seed(["h1"], account: "home@test", count: 1)

        await store.clearUnreadDurably(id: "a", account: "work@test")
        await store.clearUnreadDurably(id: "h1", account: "home@test")

        let unread = await store.unreadIds(among: ["a", "b", "h1"])
        let work = await pending("work@test")
        let home = await pending("home@test")
        XCTAssertEqual(unread, ["b"])
        XCTAssertEqual(work, ["a"])
        XCTAssertEqual(home, ["h1"])

        await store.removeMarkReadOutbox("a")

        let workAfter = await pending("work@test")
        let homeAfter = await pending("home@test")
        XCTAssertTrue(workAfter.isEmpty)
        XCTAssertEqual(homeAfter, ["h1"], "confirming one mailbox leaves the other's waiting")
    }

    /// Purging a mailbox takes its pending retries with it — a row left behind would be
    /// retried forever against a grant that no longer exists (the outbox's cascade).
    func testPurgingAMailboxTakesItsPendingRetriesWithIt() async throws {
        try await seed(["a"], account: "work@test", count: 1)
        try await seed(["h1"], account: "home@test", count: 1)
        await store.clearUnreadDurably(id: "a", account: "work@test")
        await store.clearUnreadDurably(id: "h1", account: "home@test")

        _ = await store.purge(account: "work@test")

        let work = await pending("work@test")
        let home = await pending("home@test")
        XCTAssertTrue(work.isEmpty)
        XCTAssertEqual(home, ["h1"])
    }

    /// A store with no user has no database at all — rule 16's backstop.
    func testAStoreWithNoOwnerReadsAndWritesNothing() async throws {
        try await seed(["a"], account: "work@test", count: 1)
        let anonymous = MailStore(database: db, userId: "")

        await anonymous.dropUnread(["a"], account: "work@test")
        await anonymous.clearUnreadDurably(id: "a", account: "work@test")

        let state = await anonymous.syncState(account: "work@test")
        let theirs = await anonymous.pendingMarkReads(account: "work@test")
        let work = await unreadCount("work@test")
        let unread = await store.unreadIds(among: ["a"])
        XCTAssertNil(state)
        XCTAssertTrue(theirs.isEmpty)
        XCTAssertEqual(work, 1, "the real owner's count is untouched")
        XCTAssertEqual(unread, ["a"])
    }
}
