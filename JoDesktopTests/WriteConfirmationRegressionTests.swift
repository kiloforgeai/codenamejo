import Foundation
import XCTest
@testable import CodenameJo

@MainActor
final class WriteConfirmationRegressionTests: XCTestCase {
    func testDelayedArchiveCannotRunAfterClarificationOrFeedback() async throws {
        var calls: [LiveSessionAdapter.Call] = []
        var sent: [[String: Any]] = []
        let adapter = LiveSessionAdapter(wire: { sent.append($0) }, emit: {
            if case .liveFunction(let call) = $0 { calls.append(call) }
        })
        defer { adapter.close() }
        func receive(_ event: [String: Any]) throws {
            adapter.receive(try JSONSerialization.data(withJSONObject: event))
        }
        func input(_ text: String, at: Int) throws {
            try receive(["type": "session.input_transcript.delta", "delta": text,
                         "start_ms": at, "end_ms": at + 500])
        }
        func delegate(_ id: String, at: Int) throws {
            try receive(["type": "session.delegation.created", "offset_ms": at,
                         "delegation": ["id": id, "response_id": id]])
        }
        func call(_ id: String, delegation: String, tool: String, message: String) throws {
            let args = String(decoding: try JSONSerialization.data(withJSONObject:
                ["message_id": message, "account": "owner@example.test"]), as: UTF8.self)
            try receive(["type": "response.event", "delegation_id": delegation, "event": [
                "type": "response.output_item.done", "response_id": delegation,
                "item": ["type": "function_call", "call_id": id, "name": tool, "arguments": args]]])
        }
        func finish(_ id: String, output: String) {
            adapter.outbound(["type": "conversation.item.create", "item": [
                "type": "function_call_output", "call_id": id, "output": output]])
        }

        try receive(["type": "session.started"])
        try input("Archive it now.", at: 100)
        try delegate("interrupted-request", at: 100)
        try await Task.sleep(for: .milliseconds(1100))
        try input("Which email are you archiving?", at: 2000)
        try delegate("clarification", at: 2000)
        try call("stale-archive", delegation: "interrupted-request", tool: "archive_message", message: "invitation-a")
        XCTAssertTrue(calls.isEmpty, "A clarification must supersede an uncommitted write")
        try await Task.sleep(for: .milliseconds(1100))
        try receive(["type": "session.output_transcript.delta", "delta": "Archive booking B?",
                     "start_ms": 3000, "end_ms": 3300])
        try input("Correct, go ahead.", at: 5000)
        try delegate("confirmation-b", at: 5000)
        try call("confirmed-archive", delegation: "confirmation-b", tool: "archive_message", message: "booking-b")
        XCTAssertEqual(calls.map(\.id), ["confirmed-archive"])
        finish("confirmed-archive", output: "Not completed: provider unavailable.")
        try await Task.sleep(for: .milliseconds(1100))
        try input("Record feedback about that failure.", at: 7000)
        try delegate("feedback", at: 7000)
        try call("revived-old-job", delegation: "interrupted-request", tool: "dispatch", message: "invitation-a")
        try call("revived-confirmation", delegation: "confirmation-b", tool: "archive_message", message: "booking-b")
        try call("feedback-write", delegation: "feedback", tool: "archive_message", message: "booking-b")
        try call("feedback-record", delegation: "feedback", tool: "log_feedback", message: "booking-b")
        XCTAssertEqual(calls.map(\.id), ["confirmed-archive", "feedback-record"])
        finish("feedback-record", output: "Feedback saved.")
        for id in ["interrupted-request", "clarification", "confirmation-b", "feedback"] {
            try receive(["type": "response.event", "event": ["type": "response.completed",
                         "response": ["id": id, "output": []]]])
        }
        for id in ["stale-archive", "revived-old-job", "revived-confirmation", "feedback-write"] {
            XCTAssertTrue(sent.contains {
                let item = $0["item"] as? [String: Any]
                return item?["call_id"] as? String == id
                    && (item?["output"] as? String)?.hasPrefix("Not executed:") == true
            }, id)
        }
    }
}
