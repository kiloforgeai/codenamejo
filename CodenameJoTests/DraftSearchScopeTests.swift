import XCTest
import GRDB
@testable import CodenameJo

/// `search_drafts` answers off the phone's cache, and the two things it must never get
/// wrong are whose drafts it reads and which mailbox they came from. A cross-user row is
/// PRINCIPLES rule 16; a draft rendered without its account is "found it in the wrong
/// account". Every case here stays on the local path — a cache miss would reach Gmail.
final class DraftSearchScopeTests: XCTestCase {

    private var path: URL!
    private var db: DatabasePool!
    private var store: MailStore!

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        db = try DatabasePool(path: path.path)
        try db.write { try MailStore.createUserScopedSchema($0) }
        store = MailStore(database: db, userId: "owner")
    }

    override func tearDownWithError() throws {
        try? db.close()
        try? FileManager.default.removeItem(at: path)
    }

    private func draft(
        _ id: String, account: String, subject: String, date: Int64,
        recipient: String? = "\"Sarah Chen\" <sarah@example.test>"
    ) -> MailStore.Draft {
        .init(id: id, messageId: "msg-\(id)", threadId: "thread-\(id)", account: account,
              recipient: recipient, subject: subject, snippet: nil, internalDate: date,
              cachedAt: Date(timeIntervalSince1970: 0))
    }

    private func seedTwoMailboxes() async {
        await store.cacheDrafts([
            draft("w1", account: "work@test", subject: "Invoice for March", date: 3_000),
            draft("w2", account: "work@test", subject: "Invoice reminder", date: 2_000),
            draft("h1", account: "home@test", subject: "Invoice from the plumber", date: 1_000),
            draft("w3", account: "work@test", subject: "Lunch on Friday", date: 4_000),
        ])
    }

    /// "Read me my drafts" carries no terms, so the answer is the mailbox itself.
    func testAnUntermedRequestListsEveryMailboxNewestFirstAndServedLocally() async {
        await seedTwoMailboxes()
        let result = await DraftSearch.run(query: "", account: nil, store: store)

        XCTAssertEqual(result.drafts.map(\.id), ["w3", "w1", "w2", "h1"])
        XCTAssertFalse(result.servedLive, "a cache hit never asks Gmail")
    }

    func testNamingAMailboxNeverAnswersWithAnother() async {
        await seedTwoMailboxes()
        let work = await DraftSearch.run(query: "", account: "work@test", store: store)
        let home = await DraftSearch.run(query: "", account: "home@test", store: store)

        XCTAssertEqual(work.drafts.map(\.id), ["w3", "w1", "w2"])
        XCTAssertEqual(home.drafts.map(\.id), ["h1"])
        XCTAssertEqual(Set(work.drafts.map(\.account)), ["work@test"])
    }

    /// A one-character term is dropped, so the request falls back to listing rather
    /// than reading as a search that found nothing.
    func testASingleCharacterTermFallsBackToListingTheMailbox() async {
        await seedTwoMailboxes()
        let result = await DraftSearch.run(query: "a", account: "work@test", store: store)

        XCTAssertEqual(result.drafts.map(\.id), ["w3", "w1", "w2"])
        XCTAssertFalse(result.servedLive)
    }

    /// Two accounts share one database, so the scoping that matters is the row's
    /// `user_id` — not the sign-out purge.
    func testAnotherUsersDraftIsNeverReadable() async {
        await seedTwoMailboxes()
        let intruder = MailStore(database: db, userId: "intruder")
        await intruder.cacheDrafts([
            draft("x1", account: "work@test", subject: "They must not see this", date: 9_000),
        ])

        let mine = await DraftSearch.run(query: "", account: nil, store: store)
        let theirs = await DraftSearch.run(query: "", account: nil, store: intruder)

        XCTAssertEqual(mine.drafts.map(\.id), ["w3", "w1", "w2", "h1"])
        XCTAssertEqual(theirs.drafts.map(\.id), ["x1"])
    }

    /// The cap is a token budget, not screen space.
    func testAFullMailboxIsCappedAtTheSearchLimit() async {
        let extra = DraftSearch.limit + 1
        await store.cacheDrafts((0..<extra).map {
            draft("d\($0)", account: "work@test", subject: "Draft \($0)", date: Int64($0))
        })
        let result = await DraftSearch.run(query: "", account: nil, store: store)

        XCTAssertEqual(result.drafts.count, DraftSearch.limit)
        XCTAssertEqual(result.drafts.first?.id, "d\(extra - 1)", "newest first, then truncated")
        XCTAssertFalse(result.drafts.contains { $0.id == "d0" }, "the oldest is what drops")
    }

    /// The account rides on each line only when more than one mailbox is represented, and
    /// the id offered is the *message* id — a server-side reader cannot resolve a draft id.
    func testRenderedLinesCarryTheAccountOnlyWhenMailboxesAreMixed() async {
        await seedTwoMailboxes()
        let mixed = await DraftSearch.run(query: "", account: nil, store: store)
        let rendered = DraftSearch.formatted(mixed, query: "", requestedAccount: nil)

        XCTAssertTrue(rendered.contains("· work@test"))
        XCTAssertTrue(rendered.contains("· home@test"))
        XCTAssertTrue(rendered.contains("[msg-w1]"))
        XCTAssertFalse(rendered.contains("[w1]"), "the draft id is not what a reader can act on")
        XCTAssertTrue(rendered.contains("Sarah Chen"), "the display name is what gets said back")
        XCTAssertFalse(rendered.contains("sarah@example.test"))

        // Sender-supplied text going to a model, so the fences are part of the contract.
        XCTAssertTrue(rendered.contains("untrusted mail content below"))
        XCTAssertTrue(rendered.contains("end untrusted content"))

        let single = await DraftSearch.run(query: "", account: "work@test", store: store)
        let oneMailbox = DraftSearch.formatted(single, query: "", requestedAccount: "work@test")
        XCTAssertFalse(oneMailbox.contains("· work@test"),
                       "one mailbox needs no tag on every line")
    }

    /// An empty answer has to say which mailbox was looked in, or the model reports "no
    /// drafts" for an account nobody asked about.
    func testAnEmptyAnswerNamesTheMailboxAndOnlyClaimsAQueryWhenThereWasOne() {
        let empty = DraftSearch.Result(drafts: [], servedLive: false, ms: 0)

        let searched = DraftSearch.formatted(empty, query: "invoice", requestedAccount: "work@test")
        XCTAssertTrue(searched.contains("invoice"))
        XCTAssertTrue(searched.contains("work@test"))

        let listed = DraftSearch.formatted(empty, query: "   ", requestedAccount: nil)
        XCTAssertFalse(listed.contains("matching"), "whitespace is not a query")
        XCTAssertFalse(listed.contains("@"), "no mailbox was named, so none is claimed")
    }
}
