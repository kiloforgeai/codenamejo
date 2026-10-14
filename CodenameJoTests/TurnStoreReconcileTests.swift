import Foundation
import GRDB
import XCTest
@testable import CodenameJo

/// The mirror of a user's own conversations. Two things hold whatever order the network
/// delivers in: one account's reconcile never deletes another's turns, and a response
/// overtaken in flight never deletes what landed after its snapshot.
final class TurnStoreReconcileTests: XCTestCase {
    private var path: URL!
    private var pool: DatabasePool!
    private var store: TurnStore!

    override func setUp() async throws {
        try await super.setUp()
        path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        pool = try XCTUnwrap(LocalContextStore(url: path).dbPool)
        store = TurnStore(database: pool)
    }

    override func tearDown() async throws {
        try? pool.close()
        try? FileManager.default.removeItem(at: path)
        pool = nil
        store = nil
        try await super.tearDown()
    }

    private func turn(
        _ id: String, userId: String, conversationId: String = "call-1",
        command: String = "what did the contractor say",
        issuedAt: Date = Date(), mirroredAt: Date = Date()
    ) -> TurnStore.Turn {
        TurnStore.Turn(
            id: id, userId: userId, conversationId: conversationId, commandText: command,
            responseText: "he wants the invoice", serviceName: "aurex", status: "success",
            issuedAt: issuedAt, mirroredAt: mirroredAt)
    }

    private func storedIds() throws -> [String] {
        try pool.read { try String.fetchAll($0, sql: "SELECT id FROM turn_row ORDER BY id") }
    }

    func testAnAbsentScopeIsNotTheSameAsANarrowOneAndATypoNeverWidens() {
        XCTAssertNil(RecallScope.parse(nil))
        XCTAssertNil(RecallScope.parse(""))
        XCTAssertEqual(RecallScope.parse("TODAY"), .today)
        XCTAssertEqual(RecallScope.parse("call"), .call)
        // An unrecognised value narrows rather than widens.
        XCTAssertEqual(RecallScope.parse("this-week"), .call)
        XCTAssertFalse(RecallScope.call.reachesEarlier)
        XCTAssertTrue(RecallScope.today.reachesEarlier)

        let noon = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(RecallScope.call.since(now: noon))
        XCTAssertEqual(RecallScope.today.since(now: noon), Calendar.current.startOfDay(for: noon))
        XCTAssertEqual(TurnStore.limit(for: .call), 3)
        XCTAssertEqual(TurnStore.limit(for: .today), 8)
        XCTAssertEqual(TurnStore.legacyLimit, 3)
    }

    func testHistoryReadsBackTheWholeRecordForItsOwnerOnly() async throws {
        var record = CommandRecord(commandText: "archive the invoice", responseText: "Done.",
                                   serviceName: "Gmail", status: .success, durationSeconds: 2.5)
        record.toolSteps = [.init(tool: "archive_message", milliseconds: 120)]
        try await store.save(TurnStore.Turn(record, userId: "user-a"))
        await store.record(turn("legacy", userId: "user-a", issuedAt: Date() - 60))
        await store.record(turn("theirs", userId: "user-b"))
        let history = try await store.history(owner: "user-a")
        XCTAssertEqual(history.map(\.commandText), ["archive the invoice", "what did the contractor say"])
        XCTAssertEqual(history.first?.toolSteps, record.toolSteps)
        XCTAssertEqual(history.first?.durationSeconds, 2.5)
        XCTAssertEqual(history.last?.serviceIcon, CommandRecord.icon(for: "aurex"))
        try await store.remove(id: record.id)
        let after = try await store.history(owner: "user-a")
        XCTAssertEqual(after.count, 1)
    }

    func testASearchNeverReachesAnotherAccountsTurnsEvenAsTheOnlyMatch() async {
        await store.record(turn("theirs", userId: "user-b", command: "the contractor invoice"))
        let hits = await store.search("contractor invoice", userId: "user-a",
                                      conversationId: "call-1", scope: .today)
        XCTAssertTrue(hits.isEmpty)
        // An empty owner matches nothing either — see `Turn.userId`.
        let anonymous = await store.search("contractor invoice", userId: "",
                                           conversationId: "call-1", scope: .today)
        XCTAssertTrue(anonymous.isEmpty)
    }

    func testABlankQueryIsAMissRatherThanTheLastCallsTranscript() async {
        await store.record(turn("mine", userId: "user-a"))
        for query in ["", "   ", "\n\t"] {
            let hits = await store.search(query, userId: "user-a", conversationId: "call-1",
                                          scope: nil)
            XCTAssertTrue(hits.isEmpty, "\"\(query)\" should not fall through to recency")
        }
    }

    func testAnEarlierCallIsReachedOnlyWhenTheScopeAsksForIt() async {
        await store.record(turn("earlier", userId: "user-a", conversationId: "call-0"))
        let narrow = await store.search("contractor", userId: "user-a",
                                        conversationId: "call-1", scope: .call)
        XCTAssertTrue(narrow.isEmpty)
        let widened = await store.search("contractor", userId: "user-a",
                                         conversationId: "call-1", scope: .today)
        XCTAssertEqual(widened.matched.map(\.id) + widened.recent.map(\.id), ["earlier"])
    }

    func testAStoreWithNoDatabaseDegradesInsteadOfFailing() async {
        let none = TurnStore(database: nil)
        await none.record(turn("mine", userId: "user-a"))
        await none.purge(userId: "user-a")
        let hits = await none.search("contractor", userId: "user-a",
                                     conversationId: "call-1", scope: .today)
        XCTAssertTrue(hits.isEmpty)
    }
}
