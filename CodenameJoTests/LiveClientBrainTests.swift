import XCTest
@testable import CodenameJo

final class LiveClientBrainTests: XCTestCase {
    @MainActor private final class Harness {
        var requests: [[String: Any]] = []
        var replies: [CheckedContinuation<[String: Any], Error>] = []
        var events: [[String: Any]] = []
        var speech: [String] = []
        var failures: [String] = []
        lazy var brain = LiveClientBrain(request: { [unowned self] body in
            requests.append(body)
            return try await withCheckedThrowingContinuation { replies.append($0) }
        }, deliver: { [unowned self] in events.append($0) },
           speak: { [unowned self] text, _ in speech.append(text) },
           failed: { [unowned self] in failures.append($0) })
        func start() {
            brain.updateState("email A", scope: "personal")
            brain.user("archive it", turn: 1)
            brain.begin("d1", live: true, turn: 1)
            brain.settle(turn: 1)
        }
        func reply(_ output: [[String: Any]]) { replies.removeFirst().resume(returning: ["output": output]) }
        var calls: [[String: Any]] {
            events.compactMap { $0["event"] as? [String: Any] }
                .compactMap { $0["item"] as? [String: Any] }.filter { $0["type"] as? String == "function_call" }
        }
    }
    private static let call: [String: Any] = ["type": "function_call", "call_id": "c1",
        "name": "archive_message", "arguments": "{\"message_id\":\"a\"}"]
    @MainActor private func drain() async { for _ in 0..<20 { await Task.yield() } }

    @MainActor func testCorrectionSuppressesProposalAndWaitsForSettledTranscript() async {
        let h = Harness(); h.start(); await drain()
        h.brain.user("archive it — no, skip it", turn: 1)
        h.reply([Self.call]); await drain()
        XCTAssertTrue(h.calls.isEmpty)
        XCTAssertEqual(h.requests.count, 1)
        h.brain.settle(turn: 1); await drain()
        XCTAssertEqual(h.requests.count, 2)
        let input = h.requests.last?["input"] as? [[String: Any]]
        XCTAssertEqual(input?.last?["content"] as? String, "archive it — no, skip it")
        h.reply([]); await drain()
    }

    @MainActor func testCompletedToolExchangeIsWholeAndRepeatedResultsAreIgnored() async throws {
        let h = Harness(); h.start(); await drain()
        h.reply([Self.call]); await drain()
        XCTAssertEqual(h.calls.count, 1)
        let result: [String: Any] = ["type": "function_call_output", "call_id": "c1", "output": "Queued for email a, not completed"]
        h.brain.item(result); h.brain.item(result)
        h.brain.updateState("email B", scope: "personal")
        h.brain.continueResponse(delegation: "d1"); await drain()
        let input = try XCTUnwrap(h.requests.last?["input"] as? [[String: Any]])
        XCTAssertEqual(input.filter { $0["type"] as? String == "function_call" }.count, 1)
        XCTAssertEqual(input.filter { $0["type"] as? String == "function_call_output" }.count, 1)
        let context = try XCTUnwrap(h.requests.last?["context"] as? String)
        XCTAssertTrue(context.contains("email A")); XCTAssertTrue(context.contains("email B"))
        h.reply([]); await drain()
        h.brain.begin("duplicate", live: true, turn: 1); h.brain.settle(turn: 1); await drain()
        XCTAssertEqual(h.requests.count, 2)
    }

    @MainActor func testFastActionSuppressesInFlightBackendWrite() async {
        let h = Harness(); h.start(); await drain()
        h.brain.recordFastResult("Archived email A", turn: 1)
        h.reply([Self.call]); await drain()
        XCTAssertTrue(h.calls.isEmpty); XCTAssertTrue(h.speech.isEmpty)
    }

    @MainActor func testProfileSwitchDropsPrivateStateAndOldProposal() async throws {
        let h = Harness(); h.start(); await drain()
        h.brain.assistant("Private question?")
        h.brain.observe("private context")
        h.brain.updateState("work email", scope: "work")
        h.reply([Self.call]); await drain()
        XCTAssertTrue(h.calls.isEmpty)
        h.brain.user("summarize", turn: 2); h.brain.begin("d2", live: true, turn: 2)
        h.brain.settle(turn: 2); await drain()
        let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(h.requests.last))
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(body.contains("private")); XCTAssertFalse(body.contains("Private"))
        XCTAssertFalse(body.contains("email A")); XCTAssertTrue(body.contains("work email"))
        h.reply([]); await drain()
    }

    @MainActor func testTransportFailureDoesNotRetryWriteProposal() async {
        let h = Harness(); h.start(); await drain()
        h.replies.removeFirst().resume(throwing: NSError(domain: "network", code: 1)); await drain()
        XCTAssertEqual(h.failures.count, 1); XCTAssertEqual(h.requests.count, 1)
        XCTAssertTrue(h.calls.isEmpty)
    }

    func testCompactChainKeepsSummaryLatestReplyTargetsAndContextMembers() throws {
        let item: [String: Any] = ["id": "a", "account": "owner", "bodySummary": "The chain discusses pricing; latest reply asks for approval.",
            "messages": [["id": "a", "body": String(repeating: "body", count: 20_000)], ["id": "b", "from": "latest", "body": "latest body"]],
            "summaryMessages": [["id": "ancestor", "body": "old body"], ["id": "b", "body": "latest body"]]]
        let original = String(decoding: try JSONSerialization.data(withJSONObject: ["item": item, "suggestion": "reply", "pending": true]), as: UTF8.self)
        let compact = LiveCompactContext.text(original)
        XCTAssertLessThan(compact.utf8.count, 1500)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(compact.utf8)) as? [String: Any])
        let selected = try XCTUnwrap(json["item"] as? [String: Any])
        XCTAssertEqual(selected["bodySummary"] as? String, item["bodySummary"] as? String)
        let members = try XCTUnwrap(selected["messages"] as? [[String: Any]])
        XCTAssertEqual(members.compactMap { $0["id"] as? String }, ["a", "b"])
        XCTAssertEqual((selected["summaryMessages"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["ancestor", "b"])
        XCTAssertEqual(json["pending"] as? Bool, true)
        XCTAssertEqual(LiveCompactContext.text(compact), compact)
    }

    func testMalformedOrMissingIdentityIsNotSilentlyDiscarded() {
        let text = #"prefix {"item":{"id":"a","account":"owner","messages":[{"body":"needed but no id"}]}} suffix"#
        XCTAssertTrue(LiveCompactContext.text(text).contains("needed but no id"))
        XCTAssertEqual(LiveCompactContext.text("broken {\"body\":"), "broken {\"body\":")
    }
}

extension LiveClientBrainTests {
    @MainActor func testAdapterRoutesClientDelegationAndToolResultWithoutManagedCommands() async throws {
        var wire: [[String: Any]] = []
        var requests: [[String: Any]] = []
        var calls = 0
        var adapter: LiveSessionAdapter!
        adapter = LiveSessionAdapter(wire: { wire.append($0) }, emit: { signal in
            if case .liveFunction(let call) = signal {
                calls += 1
                adapter.outbound(["type": "conversation.item.create", "item": ["type": "function_call_output",
                    "call_id": call.id, "output": "Archived email A."]])
                adapter.outbound(["type": "response.create"])
            }
        })
        adapter.clientBrainState = { ("email A", "personal") }
        adapter.enableClientDelegation { body in
            requests.append(body)
            if requests.count == 1 { return ["output": [Self.call]] }
            return ["output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Archived email A."]]]]]
        }
        func receive(_ event: [String: Any]) throws { adapter.receive(try JSONSerialization.data(withJSONObject: event)) }
        try receive(["type": "session.started"])
        try receive(["type": "session.input_transcript.delta", "delta": "archive it", "start_ms": 0, "end_ms": 100])
        try receive(["type": "session.delegation.created", "offset_ms": 100,
                     "delegation": ["id": "client-d1", "target": "client"]])
        try await Task.sleep(for: .milliseconds(650))
        await drain()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(wire.contains { ["response.create", "response.item.create"].contains($0["type"] as? String ?? "") })
        XCTAssertTrue(wire.contains { $0["type"] as? String == "session.commentary.append" && $0["delegation_id"] as? String == "client-d1" })
        adapter.close()
    }
}

extension LiveClientBrainTests {
    @MainActor func testUnpreparedFastResultGetsPresentationAfterOldProposalIsSuppressed() async {
        let h = Harness(); h.start(); await drain()
        h.brain.recordFastResult("Archived A; B requires a body read", turn: 1)
        h.brain.updateState("email B", scope: "personal")
        h.brain.presentResult("Archived A; B requires a body read", delegation: "presentation", turn: 1)
        XCTAssertEqual(h.requests.count, 1)
        h.reply([Self.call]); await drain()
        XCTAssertTrue(h.calls.isEmpty)
        XCTAssertEqual(h.requests.count, 2)
        XCTAssertEqual(h.requests.last?["presentationOnly"] as? Bool, true)
        h.reply([["type": "message", "content": [["type": "output_text", "text": "B asks for approval."]]]])
        await drain()
        XCTAssertEqual(h.speech, ["B asks for approval."])
    }

    @MainActor func testOldPresentationDoesNotResumeAfterANewRequest() async {
        let h = Harness(); h.start(); await drain()
        h.brain.recordFastResult("Archived A", turn: 1)
        h.brain.presentResult("Present B", delegation: "presentation", turn: 1)
        h.brain.user("Stop; read my calendar", turn: 2)
        h.reply([]); await drain()
        XCTAssertEqual(h.requests.count, 1)
        XCTAssertTrue(h.speech.isEmpty)
    }

    @MainActor func testOptionalUpdatesAreEvictedBeforePendingQuestionAndActiveState() async throws {
        let h = Harness()
        h.brain.updateState("email A", scope: "personal")
        h.brain.assistant("Confirm sending to Alice?")
        for i in 0..<6 { h.brain.observe("old update \(i) " + String(repeating: "x", count: 20_000)) }
        h.brain.user("yes", turn: 1); h.brain.begin("d1", live: true, turn: 1); h.brain.settle(turn: 1)
        await drain()
        let context = try XCTUnwrap(h.requests.first?["context"] as? String)
        XCTAssertLessThanOrEqual(context.utf8.count, 64_000)
        XCTAssertTrue(context.contains("Confirm sending to Alice?"))
        XCTAssertTrue(context.contains("email A"))
        h.reply([]); await drain()
    }

    @MainActor func testAdapterReportsOneTaskFailureAndAcceptsNextTurn() async throws {
        var codes: [String] = []
        var requests = 0
        var wire: [[String: Any]] = []
        let adapter = LiveSessionAdapter(wire: { wire.append($0) }, emit: {
            if case .event(.error(_, let code)) = $0 { codes.append(code ?? "") }
        })
        adapter.clientBrainState = { ("email A", "personal") }
        adapter.enableClientDelegation { _ in
            requests += 1
            if requests == 1 { throw LiveBrainRequestError(status: 400, serverCode: "brain_context_too_large") }
            return ["output": [["type": "message", "content": [["type": "output_text", "text": "Still connected."]]]]]
        }
        func receive(_ event: [String: Any]) throws { adapter.receive(try JSONSerialization.data(withJSONObject: event)) }
        try receive(["type": "session.started"])
        for turn in 1...2 {
            try receive(["type": "session.input_transcript.delta", "delta": "archive it", "start_ms": turn * 2000, "end_ms": turn * 2000 + 100])
            try receive(["type": "session.delegation.created", "offset_ms": turn * 2000 + 100,
                "delegation": ["id": "d\(turn)", "target": "client"]])
            try await Task.sleep(for: .milliseconds(650)); await drain()
        }
        XCTAssertEqual(codes, ["live_client_brain_failed"])
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(wire.contains { ($0["content"] as? String) == "Still connected." })
        adapter.close()
    }

    @MainActor func testLateAheadFragmentStaysWithAcceptedFastAction() async throws {
        var turns = 0
        var adapter: LiveSessionAdapter!
        adapter = LiveSessionAdapter(wire: { _ in }, emit: {
            if case .liveUserActivity = $0 { turns += 1 }
            if case .liveInputFinished = $0, turns == 1 {
                _ = adapter.beginFastAction(callId: "fast", action: nil, routed: true)
            }
        })
        adapter.answersPendingOffer = { _ in true }
        adapter.enableClientDelegation { _ in ["output": []] }
        func receive(_ event: [String: Any]) throws { adapter.receive(try JSONSerialization.data(withJSONObject: event)) }
        try receive(["type": "session.started"])
        try receive(["type": "session.input_transcript.delta", "delta": "Yeah, go", "start_ms": 0, "end_ms": 100])
        try await Task.sleep(for: .milliseconds(650))
        try receive(["type": "session.input_transcript.delta", "delta": " ahead", "start_ms": 700, "end_ms": 800])
        XCTAssertEqual(turns, 1)
        try await Task.sleep(for: .milliseconds(650))
        try receive(["type": "session.input_transcript.delta", "delta": "No, skip it", "start_ms": 900, "end_ms": 1000])
        XCTAssertEqual(turns, 2)
        adapter.close()
    }

    func testDiagnosticsNeverEchoAnUnknownServerBody() {
        XCTAssertEqual(LiveBrainRequestError(status: 400, serverCode: "private email content").diagnostic, "http=400 code=unknown")
        XCTAssertEqual(LiveBrainRequestError(status: 400, serverCode: "brain_context_too_large").diagnostic, "http=400 code=brain_context_too_large")
    }
}
