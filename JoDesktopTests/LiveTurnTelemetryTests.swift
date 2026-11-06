import XCTest
@testable import CodenameJo

final class LiveTurnTelemetryTests: XCTestCase {
    @MainActor
    func testResponseTimingUsageAndToolsStayWithOriginAfterNewInput() async throws {
        let h = Harness(); defer { h.adapter.close() }
        var clock = Date(timeIntervalSince1970: 100)
        h.adapter.telemetryNow = { clock }
        let turn1 = UUID(), turn2 = UUID()
        h.adapter.historyIDForTurn = { $0 == 1 ? turn1.uuidString : turn2.uuidString }
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "delta": "Reply saying thanks", "start_ms": 100, "end_ms": 200])
        clock = clock.addingTimeInterval(1)
        try h.receive(["type": "session.delegation.created", "delegation": ["id": "d1", "response_id": "r1", "offset_ms": 200]])
        try h.lifecycle("response.created")
        try h.function("send", name: "send_email")
        try await Task.sleep(for: .milliseconds(1100))
        try h.receive(["type": "session.input_transcript.delta", "delta": "hmm", "start_ms": 4000, "end_ms": 4200])
        clock = clock.addingTimeInterval(2)
        let complete: [String: Any] = ["type": "response.event", "event": ["type": "response.completed",
            "response": ["id": "r1", "usage": ["input_tokens": 100, "output_tokens": 10]]]]
        try h.receive(complete); try h.receive(complete)
        XCTAssertEqual(h.usage.count, 1)
        XCTAssertEqual(h.brainSteps.count, 1)
        XCTAssertEqual(h.brainSteps[0].turnID, turn1.uuidString)
        XCTAssertEqual(h.brainSteps[0].tools, ["send_email"])
        XCTAssertEqual(h.brainSteps[0].ms, 2000)
        XCTAssertNil(h.brainSteps[0].userSpokeMs)
        clock = clock.addingTimeInterval(20)
        try h.receive(["type": "response.event", "delegation_id": "d1", "event": ["type": "response.created", "response": ["id": "r2"]]])
        clock = clock.addingTimeInterval(1)
        try h.lifecycle("response.completed", response: "r2")
        XCTAssertEqual(h.brainSteps.last?.ms, 1000, "Each response measures its own interval")
        XCTAssertEqual(h.brainSteps.last?.turnID, turn1.uuidString)
        XCTAssertNil(h.brainSteps.last?.tools, "Earlier tools must not repeat in a continuation")
    }

    @MainActor
    func testUnansweredReplyDictationKeepsOneHistoryTurnAcrossLongPauses() async throws {
        let h = Harness(); defer { h.adapter.close() }
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "delta": "Reply saying thank you for the document.", "start_ms": 100, "end_ms": 200])
        try await Task.sleep(for: .milliseconds(1100))
        try h.receive(["type": "session.input_transcript.delta", "delta": "I will review it tomorrow.", "start_ms": 20000, "end_ms": 21000])
        try await Task.sleep(for: .milliseconds(1100))
        try h.receive(["type": "session.delegation.created", "delegation": ["id": "reply", "response_id": "reply-r", "offset_ms": 21000]])
        XCTAssertEqual(h.delegationTurns["reply"], 1)
        XCTAssertEqual(h.completedInputs.last, "Reply saying thank you for the document. I will review it tomorrow.")
    }
    @MainActor
    private final class Harness {
        var sent: [[String: Any]] = []
        var calls: [LiveSessionAdapter.Call] = []
        var idleCount = 0
        var finishedTranscripts: [String] = []
        var queueRecovery: [Bool] = []
        var unworkedSpeech: [String] = []
        var delegationTurns: [String: Int] = [:]
        var firstSpeech: [Int] = []
        var usage: [ResponseUsage] = []
        var contextRatios: [Double] = []
        var brainSteps: [CommandRecord.BrainStep] = []
        var resets = 0
        var completedInputs: [String] = []
        lazy var adapter = LiveSessionAdapter(wire: { [unowned self] in sent.append($0) }, emit: { [unowned self] in
            if case .liveFunction(let call) = $0 { calls.append(call) }
            if case .liveQueueActionUnworked(let exhausted) = $0 { queueRecovery.append(exhausted) }
            if case .liveBackendIdle = $0 { idleCount += 1 }
            if case .event(.assistantTranscriptDone(_, let transcript)) = $0 { finishedTranscripts.append(transcript) }
            if case .liveTurnIdleWithoutDelegation(let speech) = $0 { unworkedSpeech.append(speech) }
            if case .liveDelegation(let id, let turn) = $0 { delegationTurns[id] = turn }
            if case .liveFirstSpeech(let ms) = $0 { firstSpeech.append(ms) }
            if case .liveBackendUsage(let reported, _) = $0 { usage.append(reported) }
            if case .liveContextUsage(let ratio) = $0 { contextRatios.append(ratio) }
            if case .liveBrainStep(let step) = $0 { brainSteps.append(step) }
            if case .liveResetRequested = $0 { resets += 1 }
            if case .liveInputFinished(let text) = $0 { completedInputs.append(text) }
        })

        func receive(_ event: [String: Any]) throws {
            adapter.receive(try JSONSerialization.data(withJSONObject: event))
            if event["type"] as? String == "session.started" {
                let guidance = sent.filter { ($0["content"] as? String) == LiveSessionAdapter.interruptionGuidance }
                for instruction in guidance {
                    try receive(["type": "session.instructions.appended", "client_event_id": try XCTUnwrap(instruction["event_id"])])
                }
                sent.removeAll { ($0["content"] as? String) == LiveSessionAdapter.interruptionGuidance }
            }
        }

        func start(_ response: String = "r1", delegation: String = "d1") throws {
            try receive(["type": "session.started"])
            try receive(["type": "session.delegation.created",
                         "delegation": ["id": delegation, "response_id": response]])
            try lifecycle("response.created", response: response)
        }

        func lifecycle(_ type: String, response: String = "r1") throws {
            try receive(["type": "response.event", "event": ["type": type, "response": ["id": response, "output": []]]])
        }

        func function(_ id: String, response: String = "r1", name: String = "archive_message") throws {
            try receive(["type": "response.event", "event": [
                "type": "response.output_item.done", "response_id": response,
                "item": ["type": "function_call", "call_id": id, "name": name,
                         "arguments": "{\"message_id\":\"email-a\",\"account\":\"owner@example.test\"}"]]])
        }

        func result(_ id: String) {
            adapter.outbound(["type": "conversation.item.create", "item": [
                "type": "function_call_output", "call_id": id, "output": "Archiving; email B is current."]])
            adapter.outbound(["type": "response.create"])
        }
    }


}

