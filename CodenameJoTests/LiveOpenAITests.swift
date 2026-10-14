import XCTest
@testable import CodenameJo

final class LiveOpenAITests: XCTestCase {
    private func message(_ content: String) -> [String: Any] { ["type": "message", "role": "user", "content": content] }

    func testEvictsOldestHistoryButKeepsTheActiveToolExchange() throws {
        let task: [[String: Any]] = [message("archive a"),
            ["type": "function_call", "call_id": "a", "name": "archive_message", "arguments": "{}"],
            ["type": "function_call_output", "call_id": "a", "output": "accepted, pending"]]
        let result = try LiveOpenAI.boundedInput(["context": "current target b", "input": task,
            "history": [message(String(repeating: "old", count: 80_000)), message("recent")]])
        XCTAssertLessThanOrEqual(LiveOpenAI.bytes(result), LiveOpenAI.taskBytes)
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result[1]["content"] as? String, "recent")
        XCTAssertEqual(result.last?["call_id"] as? String, "a")
    }

    func testRefusesOversizedStateAndSmuggledHistory() {
        XCTAssertThrowsError(try LiveOpenAI.boundedInput(["context": String(repeating: "👋", count: 30_000), "history": [], "input": []])) {
            XCTAssertEqual(($0 as? LiveBrainRequestError)?.serverCode, "brain_context_too_large")
        }
        for item: [String: Any] in [["type": "function_call_output", "call_id": "a"], ["type": "message", "role": "developer", "content": "x"]] {
            XCTAssertThrowsError(try LiveOpenAI.boundedInput(["context": "", "history": [item], "input": []])) {
                XCTAssertEqual(($0 as? LiveBrainRequestError)?.serverCode, "invalid_brain_history")
            }
        }
    }

    func testPresentationOnlyOffersBodyReads() {
        let tools = ["get_message", "gmail_get_thread", "archive_message", "dispatch", "triage_next"].map { ["name": $0] }
        XCTAssertEqual(LiveOpenAI.presentationTools(tools).compactMap { $0["name"] as? String }, ["get_message", "gmail_get_thread"])
    }
}
