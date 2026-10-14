import Foundation
import XCTest
@testable import CodenameJo

/// The device's own context store. Widening a recall is asymmetric on purpose — what was
/// said travels between calls, what was *fetched* does not — and it never crosses an
/// account. The refusals are the other half of the contract: a `save_context` the model was
/// told not to make is answered, not silently obeyed.
final class LocalContextRecallScopeTests: XCTestCase {
    private var path: URL!
    private var store: LocalContextStore!

    override func setUp() async throws {
        try await super.setUp()
        path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = LocalContextStore(url: path)
        XCTAssertNotNil(store.dbPool)
    }

    override func tearDown() async throws {
        try? store.dbPool?.close()
        try? FileManager.default.removeItem(at: path)
        store = nil
        try await super.tearDown()
    }

    /// One `mcp_call` item as it arrives: the output is a JSON *string* inside the envelope.
    private func item(output: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["output": output]), encoding: .utf8)!
    }

    @discardableResult
    private func saveQuote(conversation: String, userId: String = "user-a") async -> String {
        await store.save(request: "the contractor quoted nine thousand", result: "quote: 9000",
                         summary: "", kind: "note", conversationId: conversation, userId: userId)
    }

    private func recordSearchResult(
        conversation: String, userId: String, query: String = "unpaid invoices"
    ) async {
        await store.record(
            tool: "gmail_search_messages", serverLabel: "aurex",
            argumentsJSON: "{\"query\":\"\(query)\"}",
            itemJSON: item(output: "[{\"id\":\"19fd\",\"subject\":\"Invoice 4\"}]"),
            userId: userId, conversationId: conversation)
    }

    func testAWidenedRecallReachesTheModelsNotesButNotAnEarlierCallsFetchedMail() async {
        await saveQuote(conversation: "call-0")
        await recordSearchResult(conversation: "call-0", userId: "user-a", query: "contractor")
        let narrow = await store.search("contractor", conversationId: "call-1",
                                        userId: "user-a", scope: .call)
        XCTAssertTrue(narrow.rows.isEmpty)
        let widened = await store.search("contractor", conversationId: "call-1",
                                         userId: "user-a", scope: .today)
        XCTAssertEqual(widened.matched, .text)
        XCTAssertEqual(widened.rows.map(\.kind), ["note"])
        // The mail row from that call stays out of reach: a stale unread list offered as a
        // live answer is the failure this asymmetry exists for.
        XCTAssertFalse(widened.rows.contains { $0.request.contains("[gmail_search_messages]") })
    }

    func testAWidenedRecallStopsAtTheAccountBoundary() async {
        await saveQuote(conversation: "call-0")
        let other = await store.search("contractor", conversationId: "call-1",
                                       userId: "user-b", scope: .today)
        XCTAssertTrue(other.rows.isEmpty)
        // An empty owner widens to nothing, which is the safe direction.
        let anonymous = await store.search("contractor", conversationId: "call-1",
                                           userId: "", scope: .today)
        XCTAssertTrue(anonymous.rows.isEmpty)
    }

    func testAKeyFromAnEarlierCallIsNotHonouredAsAKey() async {
        let saved = await saveQuote(conversation: "call-0")
        XCTAssertEqual(saved, "Cached as m_1.")
        // The sequence restarts per conversation, so `m_1` is ambiguous once widened.
        let widened = await store.search("m_1", conversationId: "call-1",
                                         userId: "user-a", scope: .today)
        XCTAssertNotEqual(widened.matched, .key)
        // Within its own call it is an exact fetch that bypasses ranking.
        let own = await store.search("m_1", conversationId: "call-0",
                                     userId: "user-a", scope: .call)
        XCTAssertEqual(own.matched, .key)
        XCTAssertEqual(own.rows.first?.result, "quote: 9000")
    }

    func testASaveWithNothingInItIsRefusedInWordsRatherThanStored() async {
        let noRequest = await store.save(request: "   ", result: "data", summary: "",
                                         kind: "note", conversationId: "call-1")
        let noResult = await store.save(request: "what the contractor said", result: " \n",
                                        summary: "", kind: "note", conversationId: "call-1")
        XCTAssertTrue(noRequest.hasPrefix("NOT SAVED"))
        XCTAssertTrue(noResult.hasPrefix("NOT SAVED"))
        let count = await store.count(in: "call-1")
        XCTAssertEqual(count, 0)
    }

    func testTheModelIsRefusedWhenItRetellsARowTheToolAlreadyStored() async {
        await recordSearchResult(conversation: "call-1", userId: "user-a")
        let answer = await store.save(request: "mail matching unpaid invoices",
                                      result: "there were four", summary: "", kind: "note",
                                      conversationId: "call-1", userId: "user-a")
        XCTAssertTrue(answer.hasPrefix("Already cached as m_1"), answer)
        let count = await store.count(in: "call-1")
        XCTAssertEqual(count, 1)
    }

    func testForgettingSaysWhetherAnythingWasThere() async {
        await saveQuote(conversation: "call-1")
        let noKey = await store.forget(key: "", conversationId: "call-1")
        XCTAssertEqual(noKey, "NOT FORGOTTEN — a key is required.")
        let unknown = await store.forget(key: "m_9", conversationId: "call-1")
        // A key belonging to another conversation is not this one's to forget.
        let otherCall = await store.forget(key: "m_1", conversationId: "call-0")
        XCTAssertEqual(unknown, "Nothing stored under m_9.")
        XCTAssertEqual(otherCall, "Nothing stored under m_1.")
        let forgotten = await store.forget(key: " m_1 ", conversationId: "call-1")
        XCTAssertEqual(forgotten, "Forgot m_1.")
        let count = await store.count(in: "call-1")
        XCTAssertEqual(count, 0)
    }

    func testAnOversizedResultIsCutWithAMarkerRatherThanSilently() {
        let exact = String(repeating: "x", count: LocalContextStore.maxResult)
        XCTAssertEqual(LocalContextStore.clip(exact), exact)
        let clipped = LocalContextStore.clip(
            String(repeating: "x", count: LocalContextStore.maxResult + 1))
        XCTAssertLessThanOrEqual(clipped.count, LocalContextStore.maxResult)
        XCTAssertTrue(clipped.contains("cut off at 16 KB"))
    }

    func testAWriteAnnotatesTheMessageItActedOnInsteadOfStoringAReceipt() async {
        let message = "[{\"id\":\"0000000000000002\",\"from\":\"a@x.test\",\"subject\":\"Inv\"}]"
        await store.record(tool: "gmail_triage_next", serverLabel: "aurex", argumentsJSON: "{}",
                           itemJSON: item(output: message), userId: "user-a",
                           conversationId: "call-1")
        for _ in 0..<2 {
            await store.record(
                tool: "gmail_archive_message", serverLabel: "aurex",
                argumentsJSON: "{\"message_id\":\"0000000000000002\"}",
                itemJSON: item(output: "Archived. {\"ok\":true}"), userId: "user-a",
                conversationId: "call-1")
        }
        let count = await store.count(in: "call-1")
        XCTAssertEqual(count, 1, "a write's receipt is never a row of its own")
        let row = await store.row(key: "m_1", in: "call-1")
        // Said once, however many times the archive is reported.
        XCTAssertEqual(row?.summary, "You archived this.")
    }
}
