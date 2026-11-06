import XCTest
@testable import CodenameJo

@MainActor
final class FastResultContinuationTests: XCTestCase {
    @MainActor final class Harness {
        var adapter: LiveSessionAdapter!
        var wire: [[String: Any]] = []
        var calls: [LiveSessionAdapter.Call] = []
        var requests: [[String: Any]] = []
        var errors: [String] = []
        var archives = 0
        var profile = "fixture"
        var selected = "A"
        init() {
            adapter = LiveSessionAdapter(wire: { [weak self] in self?.wire.append($0) }, emit: { [weak self] signal in
                guard let self else { return }
                if case .liveInputFinished(let text) = signal, text == "Archive it" {
                    if adapter.beginFastAction(callId: "voice-archive", action: .archive) { archives += 1 }
                }
                if case .liveFunction(let call) = signal { calls.append(call) }
                if case .event(.error(_, let code)) = signal { errors.append(code ?? "") }
            })
            adapter.clientBrainState = { [weak self] in
                let id = self?.selected ?? "none"
                return (GmailReadTools.json(["done": false, "item": ["id": id, "account": "qa@example.test", "threadId": "thread-" + id]]), self?.profile)
            }
            adapter.enableClientDelegation { [weak self] request in
                guard let self else { return ["output": []] }
                requests.append(request)
                if requests.count == 1 {
                    return ["output": [["type": "function_call", "call_id": "read-B", "name": "gmail_get_message",
                        "arguments": #"{"account":"qa@example.test","message_id":"B"}"#]]]
                }
                return ["output": [["type": "message", "content": [["type": "output_text", "text": "Archived A. The next email is B, asking about lunch."]]]]]
            }
        }
        func receive(_ event: [String: Any]) throws { adapter.receive(try JSONSerialization.data(withJSONObject: event)) }
        func output(_ id: String, _ text: String) {
            adapter.outbound(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": id, "output": text]])
        }
        func start() async throws {
            try receive(["type": "session.started"])
            for event in wire where event["type"] as? String == "session.instructions.append" {
                try receive(["type": "session.instructions.appended", "client_event_id": event["event_id"]!])
            }
            try receive(["type": "session.input_transcript.delta", "delta": "Archive it", "start_ms": 10, "end_ms": 100])
            try await Task.sleep(for: .milliseconds(550))
            XCTAssertEqual(archives, 1)
            selected = "B"
            output("voice-archive", "Archived A. Email B is now selected.")
            for _ in 0..<100 { if !calls.isEmpty { break }; await Task.yield() }
            XCTAssertEqual(calls.map(\.name), ["gmail_get_message"])
        }
        var speech: String { wire.filter { $0["type"] as? String == "session.commentary.append" }.compactMap { $0["content"] as? String }.joined(separator: "\n") }
    }

    func testSpokenArchiveResumesAfterPresentationReadEvenWithoutResponseCreateWakeup() async throws {
        for outcome in ["B is an invitation to lunch.", "Read failed: provider unavailable."] {
            let h = Harness()
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let log = VoiceDiagnostics(directory: folder)
            h.adapter.diagnostics = log.begin(engine: "live")
            defer { h.adapter.close(); try? FileManager.default.removeItem(at: folder) }
            try await h.start()
            try await Task.sleep(for: .milliseconds(30))
            h.output("read-B", outcome)
            for _ in 0..<100 { if h.requests.count == 2 { break }; await Task.yield() }
            XCTAssertEqual(h.requests.count, 2)
            XCTAssertTrue(h.requests.allSatisfy { $0["presentationOnly"] as? Bool == true })
            for _ in 0..<50 { await Task.yield() }
            XCTAssertTrue(h.speech.contains("Say exactly:"), h.speech)
            XCTAssertTrue(h.speech.contains("Archived A"), h.speech)
            XCTAssertNil(h.adapter.buttonActionBlockReason)
            XCTAssertTrue(h.adapter.beginButtonAction(callId: "button-next", action: .next))
            XCTAssertEqual(h.archives, 1)
            XCTAssertEqual(h.calls.count, 1)
            let events = try String(decoding: await log.snapshot(), as: UTF8.self).split(separator: "\n").compactMap {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }.compactMap { $0["fields"] as? [String: String] }
            let owed = try XCTUnwrap(events.first { $0["transition"] == "continuation_owed" })
            let resumed = try XCTUnwrap(events.first { $0["transition"] == "continuation_resumed" })
            XCTAssertEqual(owed["continuation_owed"], "true")
            XCTAssertEqual(resumed["continuation_owed"], "false")
            XCTAssertEqual(owed["continuation_owner"], h.calls[0].delegation)
            XCTAssertEqual(resumed["continuation_owner"], h.calls[0].delegation)
            XCTAssertEqual(owed["pending_phase"], "result_presentation")
        }
    }

    func testLostPresentationReadIsReleasedAndItsLateResultCannotRestartIt() async throws {
        let h = Harness()
        h.adapter.buttonPresentationBound = 0.07
        defer { h.adapter.close() }
        try await h.start()
        XCTAssertTrue(h.adapter.buttonActionBlockReason?.contains("reading context") == true)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(h.errors, ["live_button_presentation_timeout"])
        XCTAssertNil(h.adapter.buttonActionBlockReason)
        h.output("read-B", "Late read result")
        h.adapter.outbound(["type": "response.create"])
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(h.requests.count, 1)
        XCTAssertEqual(h.archives, 1)
        XCTAssertTrue(h.adapter.beginButtonAction(callId: "button-next", action: .next))
    }

    func testNewUserInputReleasesOldPresentationAndLateDelegationCannotArchiveAgain() async throws {
        let h = Harness()
        defer { h.adapter.close() }
        try await h.start()
        try h.receive(["type": "session.input_transcript.delta", "delta": "What is wrong?", "start_ms": 7000, "end_ms": 7200])
        h.output("read-B", "Late read result")
        try h.receive(["type": "session.delegation.created", "offset_ms": 100, "delegation": ["id": "late-original", "target": "client"]])
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(h.archives, 1)
        XCTAssertEqual(h.requests.count, 1)
        XCTAssertNil(h.adapter.buttonActionBlockReason)
        XCTAssertFalse(h.errors.contains("live_tool_result_mismatch"))
    }

    func testChangedSelectionOrProfileDropsOldPresentation() async throws {
        for changeProfile in [false, true] {
            let h = Harness()
            defer { h.adapter.close() }
            try await h.start()
            if changeProfile { h.profile = "other" } else { h.selected = "C" }
            h.output("read-B", "Original B content")
            for _ in 0..<100 { await Task.yield() }
            XCTAssertEqual(h.requests.count, 1)
            XCTAssertFalse(h.speech.contains("Archived A"))
            XCTAssertNil(h.adapter.buttonActionBlockReason)
            XCTAssertEqual(h.archives, 1)
        }
    }
}
