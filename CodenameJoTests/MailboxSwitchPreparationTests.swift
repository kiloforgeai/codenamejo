import XCTest
import GRDB
@testable import CodenameJo

/// Switching mailboxes inside one profile: every mailbox is prepared ahead, so the switch restores
/// a row from disc instead of building the other inbox in front of the user.
@MainActor
final class MailboxSwitchPreparationTests: XCTestCase {
    private let work = "work@example.test"
    private let personal = "personal@example.test"
    private var previousFlag: Any?
    private var previousScope: String?

    override func setUp() {
        super.setUp()
        previousFlag = UserDefaults.standard.object(forKey: ThreadQueue.storageKey)
        UserDefaults.standard.set(true, forKey: ThreadQueue.storageKey)
        // The automatic start is the week ranked by importance; these rows carry fixed old dates,
        // so the walk is pinned to the unread pile the way a Settings choice would.
        previousScope = UserDefaults.standard.string(forKey: TriageScope.storageKey)
        TriageScope.store(.unread)
    }

    override func tearDown() {
        if let previousFlag { UserDefaults.standard.set(previousFlag, forKey: ThreadQueue.storageKey) }
        else { UserDefaults.standard.removeObject(forKey: ThreadQueue.storageKey) }
        if let previousScope { UserDefaults.standard.set(previousScope, forKey: TriageScope.storageKey) }
        else { TriageScope.clear() }
        super.tearDown()
    }

    // MARK: - Daily preparation covers every mailbox

    func testDailyPreparationWritesARowForEveryMailbox() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        try await seedBothMailboxes(fixture)
        let queue = makeQueue()
        await queue.prepareDailySnapshot(store: fixture.store)

        let rows = try await fixture.database.read { db in
            try DailyEmailQueueSnapshotRecord.order(Column("account")).fetchAll(db)
        }
        XCTAssertEqual(rows.map(\.account), [personal, work], "One row per mailbox, not only the first")
        for row in rows {
            let saved = try JSONSerialization.jsonObject(with: row.payload) as? [String: Any]
            let items = try XCTUnwrap(saved?["items"] as? [[String: Any]])
            XCTAssertFalse(items.isEmpty)
            XCTAssertTrue(items.allSatisfy { ($0["account"] as? String) == row.account },
                          "A mailbox's row holds only its own mail")
            XCTAssertEqual(saved?["accounts"] as? [String], [row.account])
            XCTAssertEqual(saved?["completed"] as? Bool, false)
            XCTAssertEqual(saved?["position"] as? Int, 1, "Prepared, not walked")
        }
        // The preparation leaves nothing running: the first call builds its own view.
        let mailbox = await queue.currentMailbox
        XCTAssertNil(mailbox)
    }

    func testSwitchToAMailboxPreparedTodayRestoresFromDisc() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        try await seedBothMailboxes(fixture)
        let queue = makeQueue()
        await queue.prepareDailySnapshot(store: fixture.store)

        let opening = await queue.step(.init(), store: fixture.store)
        XCTAssertEqual(try current(opening.output)["account"] as? String, work)

        let switched = await queue.step(.init(account: personal), store: fixture.store)
        XCTAssertEqual(switched.served, .hit, "A mailbox prepared today is served from its row, not built")
        XCTAssertEqual(try current(switched.output)["account"] as? String, personal)
        XCTAssertEqual(try current(switched.output)["id"] as? String, "p-1")
        let mailbox = await queue.currentMailbox
        XCTAssertEqual(mailbox, personal)

        // And back, the same way.
        let back = await queue.step(.init(account: work), store: fixture.store)
        XCTAssertEqual(back.served, .hit)
        XCTAssertEqual(try current(back.output)["id"] as? String, "w-1")
        await queue.end()
    }

    // MARK: - The walk prepares the other mailbox behind the first card

    func testWalkPreparesTheOtherMailboxBehindTheFirstCard() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        try await seedBothMailboxes(fixture)
        let queue = makeQueue()

        let opening = await queue.step(.init(scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(opening.output)["account"] as? String, work)
        await queue.awaitMailboxAhead()

        let rows = try await fixture.database.read { db in
            try DailyEmailQueueSnapshotRecord.order(Column("account")).fetchAll(db)
        }
        XCTAssertEqual(rows.map(\.account), [personal, work],
                       "The other mailbox's row is written while the first is walked")
        // The walk itself is untouched by the prefetch.
        let mailbox = await queue.currentMailbox
        XCTAssertEqual(mailbox, work)
        let standing = await queue.standing
        XCTAssertEqual(standing?.position, 1)

        let switched = await queue.step(.init(account: personal), store: fixture.store)
        XCTAssertEqual(switched.served, .hit)
        XCTAssertEqual(try current(switched.output)["id"] as? String, "p-1")
        await queue.end()
    }

    func testAScratchQueuePreparesOnlyItsOwnMailbox() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        try await seedBothMailboxes(fixture)
        let scratch = LocalTriageQueue(mailAccounts: { [self.personal] }, unreadOpeningLoader: { _ in [] })
        let served = await scratch.prepareMailboxAhead(store: fixture.store)
        XCTAssertNotNil(served)
        let rows = try await fixture.database.read { db in try DailyEmailQueueSnapshotRecord.fetchAll(db) }
        XCTAssertEqual(rows.map(\.account), [personal])
        let mailbox = await scratch.currentMailbox
        XCTAssertNil(mailbox, "The scratch queue ends itself once the row has landed")
    }

    // MARK: - Thread context comes off the row, not Gmail

    func testRestoredThreadContextIsReusedForAnUnchangedThread() {
        let saved = contextItem(id: "m-2", thread: "t", members: ["m-1", "m-2"], verified: false)
        let fresh = plain(id: "m-2", thread: "t")
        let reused = try? XCTUnwrap(LocalTriageQueue.reusingThreadContext(fresh, from: saved))
        XCTAssertEqual(reused?.exchangeContext?.map(\.id), ["m-1", "m-2"])
        XCTAssertEqual(reused?.threadMessageCount, 2)
        XCTAssertEqual(reused?.messages?.first?.rfcMessageID, "<m-2@test>")
        XCTAssertEqual(reused?.messages?.first?.exchangeID, "exchange-m-2")
        XCTAssertNil(reused?.summaryMessages, "An unverified thread has no read summary to carry")
    }

    func testAThreadWithANewMessageIsFetchedAgain() {
        let saved = contextItem(id: "m-2", thread: "t", members: ["m-1", "m-2"], verified: true)
        XCTAssertNil(LocalTriageQueue.reusingThreadContext(plain(id: "m-3", thread: "t"), from: saved),
                     "A member the row never saw means the thread moved on")
        XCTAssertNil(LocalTriageQueue.reusingThreadContext(plain(id: "m-2", thread: "other"), from: saved))
    }

    func testAReadVerdictDoesNotSurviveAnUnreadMember() {
        let saved = contextItem(id: "m-2", thread: "t", members: ["m-1", "m-2"], verified: true)
        var fresh = plain(id: "m-2", thread: "t")
        fresh.messages = fresh.conversation.map { var m = $0; m.unread = true; return m }
        let reused = LocalTriageQueue.reusingThreadContext(fresh, from: saved)
        XCTAssertEqual(reused?.threadReadVerified, false)
        XCTAssertNil(reused?.summaryMessages)
        fresh.messages = fresh.conversation.map { var m = $0; m.unread = false; return m }
        let read = LocalTriageQueue.reusingThreadContext(fresh, from: saved)
        XCTAssertEqual(read?.threadReadVerified, true)
        XCTAssertEqual(read?.summaryMessages?.count, 2)
    }

    func testThreadContextIndexKeepsTheFullerContextAndSkipsBareItems() {
        let short = contextItem(id: "m-1", thread: "t", members: ["m-1"], verified: false)
        let full = contextItem(id: "m-2", thread: "t", members: ["m-1", "m-2"], verified: false)
        let index = LocalTriageQueue.threadContextIndex([short, plain(id: "x", thread: "u"), full])
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index.values.first?.exchangeContext?.count, 2)
    }

    // MARK: - Helpers

    private func makeQueue() -> LocalTriageQueue {
        // No Gmail in a test: the opening loader answers an empty page, so the walk is the cache.
        LocalTriageQueue(mailAccounts: { [self.work, self.personal] }, unreadOpeningLoader: { _ in [] })
    }

    private func seedBothMailboxes(_ fixture: StoreFixture) async throws {
        let rows = [row("w-1", thread: "w-1", date: 30_000, sender: "Work One", account: work),
                    row("w-2", thread: "w-2", date: 20_000, sender: "Work Two", account: work),
                    row("p-1", thread: "p-1", date: 30_000, sender: "Personal One", account: personal),
                    row("p-2", thread: "p-2", date: 20_000, sender: "Personal Two", account: personal)]
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        await fixture.store.apply([], account: work, historyId: nil, inboxUnread: 2)
        await fixture.store.apply([], account: personal, historyId: nil, inboxUnread: 2)
    }

    private func row(_ id: String, thread: String, date: Int64, sender: String, account: String) -> MailStore.Message {
        .init(user_id: "test-user", id: id, account: account, threadId: thread, sender: sender, recipient: nil,
              subject: "Subject \(id)", snippet: "Snippet \(id)", internalDate: date, cachedAt: Date(),
              rfcMessageID: "<\(id)@test>", inReplyTo: nil, referenceHeaders: nil)
    }

    private func plain(id: String, thread: String) -> LocalTriageQueue.Item {
        .init(account: work, id: id, threadId: thread, from: "Someone", subject: "Subject", date: "",
              snippet: "Snippet", internalDate: 1_000)
    }

    private func contextItem(id: String, thread: String, members: [String], verified: Bool) -> LocalTriageQueue.Item {
        let context = members.enumerated().map { offset, member in
            LocalTriageQueue.Item.Message(id: member, from: "Someone", subject: "Subject", date: "",
                snippet: "Snippet", internalDate: Int64(offset), unread: false, exchangeID: "exchange-\(member)",
                ancestryCached: true, rfcMessageID: "<\(member)@test>", threadId: thread)
        }
        var item = plain(id: id, thread: thread)
        item.threadReadVerified = verified
        item.threadMessageCount = members.count
        item.exchangeContext = context
        item.summaryMessages = verified ? context : nil
        return item
    }

    private func current(_ output: String) throws -> [String: Any] {
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        return try XCTUnwrap(payload["item"] as? [String: Any], "No item in \(output)")
    }

    private struct StoreFixture {
        let directory: URL
        let database: DatabasePool
        var store: MailStore { MailStore(database: database, userId: "test-user") }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            database = try DatabasePool(path: directory.appendingPathComponent("mail.sqlite").path)
            try database.write { db in
                try MailStore.createUserScopedSchema(db)
                try EmailCleanupRecord.createSchema(db)
                try DailyEmailQueueSnapshotRecord.createSchema(db)
                try DailyEmailQueueSnapshotRecord.addOwner(db)
            }
        }

        func seed(_ rows: [MailStore.Message], unread: Set<String>) async throws {
            try await database.write { db in
                for row in rows {
                    try row.insert(db)
                    try MailStore.Label(user_id: "test-user", messageId: row.id, account: row.account,
                                        label: "INBOX").insert(db)
                    if unread.contains(row.id) {
                        try MailStore.Label(user_id: "test-user", messageId: row.id, account: row.account,
                                            label: "UNREAD").insert(db)
                    }
                }
            }
        }

        func close() {
            do {
                try database.close()
                try FileManager.default.removeItem(at: directory)
            } catch { XCTFail("Could not remove test database: \(error)") }
        }
    }
}
