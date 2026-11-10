import XCTest
@testable import CodenameJo

@MainActor
final class AtComputerNarrationTests: XCTestCase {
    func testRequestedAnswerDoesNotAuthorizeLaterLiveNarration() throws {
        var captions: [String] = [], gate: [Bool] = [], wire: [[String: Any]] = []
        let adapter = LiveSessionAdapter(wire: { wire.append($0) }, emit: {
            if case .event(.assistantTranscriptDelta(_, let text, _)) = $0 { captions.append(text) }
        })
        defer { adapter.close() }
        adapter.onOutputSuppressed = { gate.append($0) }
        func receive(_ event: [String: Any]) throws { adapter.receive(try JSONSerialization.data(withJSONObject: event)) }
        func acknowledge() throws {
            for item in wire where item["type"] as? String == "session.instructions.append" || item["type"] as? String == "session.thinking.append" {
                try receive(["type": "session.instructions.appended", "client_event_id": item["event_id"]!])
            }
        }
        try receive(["type": "session.started"])
        adapter.setNarrationMode(.atComputer)
        try acknowledge()
        try receive(["type": "session.input_transcript.delta", "delta": "Reply saying thanks", "start_ms": 100, "end_ms": 200])
        try receive(["type": "session.output_transcript.delta", "delta": "Here is the next email.", "start_ms": 210, "end_ms": 250])
        XCTAssertTrue(captions.isEmpty)
        XCTAssertEqual(gate.last, true, "A request alone never unmutes unrestricted model audio")
        adapter.speakExactly("Reply sent.")
        try acknowledge()
        XCTAssertEqual(gate.last, false)
        try receive(["type": "session.output_transcript.delta", "delta": "Reply sent. Next up is a newsletter. What would you like to do?", "start_ms": 300, "end_ms": 400])
        XCTAssertEqual(captions.joined(), "Reply sent.")
        XCTAssertEqual(gate.last, true)
        try receive(["type": "session.input_transcript.delta", "delta": "[sniffing]", "start_ms": 4000, "end_ms": 4100])
        try receive(["type": "session.output_transcript.delta", "delta": "This email is about lunch.", "start_ms": 4200, "end_ms": 4300])
        XCTAssertEqual(captions.joined(), "Reply sent.")
        XCTAssertEqual(adapter.narrationMode, .atComputer)
        adapter.speakExactly("The sender prefers the afternoon.")
        try acknowledge()
        for delta in ["The sender pre", "fers the afternoon."] {
            try receive(["type": "session.output_transcript.delta", "delta": delta, "start_ms": 4400, "end_ms": 4500])
        }
        XCTAssertEqual(captions.suffix(2).joined(), "The sender prefers the afternoon.")
        try receive(["type": "session.output_transcript.delta", "delta": " Now another email.", "start_ms": 4600, "end_ms": 4700])
        XCTAssertFalse(captions.joined().contains("another email"))
    }

    func testFastActionReportsReceiptWithoutAskingModelToReadReplacement() async throws {
        var wire: [[String: Any]] = [], calls: [String] = []
        var adapter: LiveSessionAdapter!
        adapter = LiveSessionAdapter(wire: { wire.append($0) }, emit: {
            if case .liveInputFinished(let text) = $0, LiveFastAction.parse(text) == .archive {
                XCTAssertTrue(adapter.beginFastAction(callId: "archive", action: .archive))
            }
            if case .liveFunction(let call) = $0 { calls.append(call.name) }
        })
        defer { adapter.close() }
        adapter.enableClientDelegation { _ in XCTFail("A completed fast action needs no next-item presentation request"); return ["output": []] }
        func receive(_ event: [String: Any]) throws { adapter.receive(try JSONSerialization.data(withJSONObject: event)) }
        try receive(["type": "session.started"])
        adapter.setNarrationMode(.atComputer)
        for event in wire where event["type"] as? String == "session.instructions.append" {
            try receive(["type": "session.instructions.appended", "client_event_id": event["event_id"]!])
        }
        try receive(["type": "session.input_transcript.delta", "delta": "Archive", "start_ms": 100, "end_ms": 200])
        try await Task.sleep(for: .milliseconds(600))
        adapter.outbound(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": "archive",
            "output": "Archived.\n\nQueue: Email B is a newsletter. What would you like to do?"]])
        let speech = wire.filter { $0["type"] as? String == "session.commentary.append" }.compactMap { $0["content"] as? String }.joined()
        XCTAssertTrue(speech.contains("Say exactly: Archived."), speech)
        XCTAssertFalse(speech.contains("newsletter"))
        XCTAssertTrue(calls.isEmpty)
        XCTAssertNil(adapter.buttonActionBlockReason)
    }

    func testDelegatedReplyCannotAppendNextItemEvenWhenModelIgnoresMode() async throws {
        var events: [[String: Any]] = [], speech: [String] = []
        var requests = 0
        let brain = LiveClientBrain(request: { _ in
            requests += 1
            if requests == 1 {
                return ["output": [["type": "function_call", "call_id": "reply", "name": "send_email",
                    "arguments": #"{"account":"owner@example.test","thread_id":"thread-A","reply_message_id":"A","body":"Thanks."}"#]]]
            }
            return ["output": [["type": "message", "content": [["text": "Sent. Jordan wants a meeting tomorrow. What would you like to do with it?"]]]]]
        }, deliver: { events.append($0) }, speak: { text, _ in speech.append(text) }, failed: { XCTFail($0) })
        defer { brain.close() }
        brain.automaticNarration = false
        brain.updateState(#"{"done":false,"item":{"id":"A","account":"owner@example.test","threadId":"thread-A"}}"#, scope: "work")
        brain.user("Reply to this email: thanks", turn: 1)
        brain.begin("reply", live: true, turn: 1); brain.settle(turn: 1)
        for _ in 0..<100 where !GmailReadTools.json(events).contains("function_call") { try await Task.sleep(for: .milliseconds(5)) }
        brain.item(["type": "function_call_output", "call_id": "reply", "output": "Sent to teammate@example.test from owner@example.test."])
        brain.updateState(#"{"done":false,"item":{"id":"B","account":"owner@example.test","threadId":"thread-B","bodySummary":"Jordan wants a meeting tomorrow."}}"#, scope: "work")
        brain.continueResponse(delegation: "reply")
        for _ in 0..<100 where speech.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(speech, ["Reply sent."])
        XCTAssertEqual(requests, 2)
    }

    func testAtComputerStillAllowsTheExplicitSessionFarewell() throws {
        var captions: [String] = [], gate: [Bool] = []
        let adapter = LiveSessionAdapter(wire: { _ in }, emit: {
            if case .event(.assistantTranscriptDelta(_, let text, _)) = $0 { captions.append(text) }
        })
        defer { adapter.close() }
        adapter.onOutputSuppressed = { gate.append($0) }
        adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.started"]))
        adapter.setNarrationMode(.atComputer)
        adapter.beginFarewell()
        XCTAssertEqual(gate.last, false)
        adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.output_transcript.delta",
            "delta": "Goodbye, take care.", "start_ms": 100, "end_ms": 200]))
        XCTAssertEqual(captions, ["Goodbye, take care."])
    }

    func testReceiptPolicyNeverTurnsFailureOrPendingIntoSuccess() {
        for (result, expected) in [
            ("Sent to teammate@example.test from owner@example.test.", "Reply sent."),
            ("Sending to teammate@example.test. Gmail has not confirmed it yet.", "Sending. Gmail has not confirmed it yet; check Activity for the receipt."),
            ("Not executed: source changed", "That action was not executed. Check Activity for the reason and recovery options."),
            ("Gmail did not confirm. Its outcome is unknown.", "The outcome is unknown. Check Activity before trying again.")
        ] {
            XCTAssertEqual(LiveNarrationPolicy.confirmation(tool: "send_email", result: result), expected)
        }
        XCTAssertEqual(LiveNarrationPolicy.answer("The meeting is Tuesday. Next up is an email about lunch. What would you like to do?"), "The meeting is Tuesday.")
        XCTAssertEqual(LiveNarrationPolicy.answer("The sender says the next email will contain the agenda."), "The sender says the next email will contain the agenda.")
        var allowance = LiveSpeechAllowance("Thanks, received.")
        XCTAssertEqual(allowance.accept("Thanks, "), "Thanks, ")
        XCTAssertEqual(allowance.accept("received."), "received.")
        XCTAssertFalse(allowance.violated)
        XCTAssertEqual(allowance.accept(" This email is about lunch."), "")
        XCTAssertTrue(allowance.violated)
    }
}
