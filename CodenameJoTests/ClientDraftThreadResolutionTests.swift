import XCTest
@testable import CodenameJo

@MainActor
final class ClientDraftThreadResolutionTests: XCTestCase {
    func testQueuedMessageIdResolvesToItsThread() {
        XCTAssertEqual(
            LocalTriageQueue.resolvedReplyThreadId("message-2", in: [item()]),
            "thread-2")
    }

    func testRealThreadIdPassesThrough() {
        XCTAssertEqual(
            LocalTriageQueue.resolvedReplyThreadId("thread-2", in: [item()]),
            "thread-2")
    }

    func testRelayPreservesSelectedMemberAndDraftFields() throws {
        let input = """
        {"body":"Three o'clock works.","thread_id":"older","reply_all":true,"verbatim":true}
        """
        let grouped = LocalTriageQueue.groupByConversation([
            LocalTriageQueue.Item(account: "me@example.com", id: "older", threadId: "thread-2",
                from: "Priya <priya@example.com>", subject: "Planning", date: "Sep 3",
                snippet: "Earlier reply", internalDate: 1), item()
        ], grouping: true)
        let output = LocalTriageQueue.draftRelayArguments(input, in: grouped)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(json["thread_id"] as? String, "thread-2")
        XCTAssertEqual(json["reply_message_id"] as? String, "older")
        XCTAssertEqual(json["account"] as? String, "me@example.com")
        XCTAssertEqual(json["body"] as? String, "Three o'clock works.")
        XCTAssertEqual(json["reply_all"] as? Bool, true)
        XCTAssertEqual(json["verbatim"] as? Bool, true)
    }

    func testExplicitMailboxIsPreserved() {
        let input = """
        {"thread_id":"message-2","account":"other@example.com"}
        """
        XCTAssertEqual(LocalTriageQueue.draftRelayArguments(input, in: [item()]), input)
        XCTAssertEqual(LocalTriageQueue.resolvedReplyThreadId("message-2", in: [item()],
            account: "other@example.com"), "message-2")
    }

    func testMissingContextAndAmbiguousMailboxDoNotRewriteSelection() {
        let input = """
        {"thread_id":"message-2"}
        """
        let other = item(account: "other@example.com")
        XCTAssertEqual(LocalTriageQueue.draftRelayArguments(input, in: []), input)
        XCTAssertEqual(LocalTriageQueue.draftRelayArguments(input, in: [item(), other]), input)
    }

    func testCompletionPreservesOlderSelectionAcrossSameThreadContinuations() {
        let older = LocalTriageQueue.Item(account: "me@example.com", id: "older", threadId: "thread-2",
            from: "Priya", subject: "Planning", date: "", snippet: "", internalDate: 1)
        let items = [older, item()]
        XCTAssertEqual(LocalTriageQueue.selectedReplyMessageID("older", account: "me@example.com", in: items), "older")
        XCTAssertFalse(items[1].holds("older"))
        XCTAssertNil(LocalTriageQueue.selectedReplyMessageID("thread-2", account: "me@example.com", in: items))
        XCTAssertNil(LocalTriageQueue.selectedReplyMessageID("older", account: "other@example.com", in: items))
        XCTAssertNil(LocalTriageQueue.selectedReplyMessageID("message-2", account: nil,
            in: [item(), item(account: "other@example.com")]))
    }

    func testRelayWithExplicitMailboxCarriesBothReplyIdentities() throws {
        let output = LocalTriageQueue.draftRelayArguments(
            #"{"thread_id":"message-2","account":"me@example.com","to":"chosen@example.com"}"#, in: [item()])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(json["thread_id"] as? String, "thread-2")
        XCTAssertEqual(json["reply_message_id"] as? String, "message-2")
        XCTAssertEqual(json["to"] as? String, "chosen@example.com")
    }

    func testCanonicalThreadDoesNotImplicitlySelectItsFirstMessage() throws {
        let first = LocalTriageQueue.Item(account: "me@example.com", id: "thread-2", threadId: "thread-2",
            from: "Sam", subject: "Planning", date: "", snippet: "", internalDate: 1)
        let rows = [first, item()]
        let output = LocalTriageQueue.draftRelayArguments(#"{"thread_id":"thread-2"}"#, in: rows)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(json["thread_id"] as? String, "thread-2")
        XCTAssertNil(json["reply_message_id"])
        XCTAssertNil(LocalTriageQueue.selectedReplyMessageID("thread-2", account: "me@example.com", in: rows))
        let explicit = LocalTriageQueue.draftRelayArguments(
            #"{"thread_id":"thread-2","reply_message_id":"thread-2","account":"me@example.com"}"#, in: rows)
        let selected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(explicit.utf8)) as? [String: Any])
        XCTAssertEqual(selected["reply_message_id"] as? String, "thread-2")
    }

    func testExplicitSelectionSurvivesLegacyThreadNormalization() throws {
        let output = LocalTriageQueue.draftRelayArguments(
            #"{"thread_id":"message-2","reply_message_id":"older","account":"me@example.com"}"#, in: [item()])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(json["thread_id"] as? String, "thread-2")
        XCTAssertEqual(json["reply_message_id"] as? String, "older")
    }

    private func item(account: String = "me@example.com") -> LocalTriageQueue.Item {
        LocalTriageQueue.Item(
            account: account, id: "message-2", threadId: "thread-2",
            from: "Nate <nate@example.com>", subject: "Planning", date: "Sep 4",
            snippet: "Can we meet?", internalDate: 2)
    }
}
