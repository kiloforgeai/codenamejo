import XCTest
@testable import CodenameJo

final class LiveClientBrainTests: XCTestCase {
    @MainActor private final class Harness {
        var requests: [[String: Any]] = []
        var replies: [CheckedContinuation<[String: Any], Error>] = []
        var events: [[String: Any]] = []
        var speech: [String] = []
        var spokenDelegations: [String?] = []
        var failures: [String] = []
        lazy var brain = LiveClientBrain(request: { [unowned self] body in
            requests.append(body)
            return try await withCheckedThrowingContinuation { replies.append($0) }
        }, deliver: { [unowned self] in events.append($0) },
           speak: { [unowned self] text, delegation in
               speech.append(text); spokenDelegations.append(delegation)
           },
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
        XCTAssertEqual(h.speech, h.failures, "The failure line reaches the speaker")
    }

    @MainActor func testNewQuestionStartsWithoutWaitingForOldRequestAndIgnoresItsLateFailure() async throws {
        let h = Harness(); h.start(); await drain()
        h.brain.user("read my calendar", turn: 2)
        h.brain.begin("d2", live: true, turn: 2)
        h.brain.settle(turn: 2); await drain()
        XCTAssertEqual(h.requests.count, 2)
        h.replies.removeFirst().resume(throwing: NSError(domain: "network", code: 1)); await drain()
        XCTAssertTrue(h.failures.isEmpty)
        XCTAssertTrue(h.brain.busy, "A late failure must not clear the newer request")
        let input = try XCTUnwrap(h.requests.last?["input"] as? [[String: Any]])
        XCTAssertEqual(input.last?["content"] as? String, "read my calendar")
        h.reply([["type": "message", "content": [["text": "You have a meeting at two."]]]]); await drain()
        XCTAssertEqual(h.speech, ["You have a meeting at two."])
        XCTAssertFalse(h.brain.busy)
        let events = h.events.compactMap { $0["event"] as? [String: Any] }
        XCTAssertEqual(events.filter { $0["type"] as? String == "response.completed" }.count, 2)
    }

    @MainActor func testTimedOutRequestReleasesTurnAndRejectsLateWriteProposal() async throws {
        let h = Harness(); h.brain.requestBound = 0.05; h.start(); await drain()
        try await Task.sleep(for: .milliseconds(150)); await drain()
        XCTAssertFalse(h.brain.busy)
        XCTAssertEqual(h.failures.count, 1)
        XCTAssertEqual(h.spokenDelegations.first!, "d1")
        h.brain.requestBound = 20
        h.brain.user("what is this email about?", turn: 2)
        h.brain.begin("d2", live: true, turn: 2); h.brain.settle(turn: 2); await drain()
        XCTAssertEqual(h.requests.count, 2)
        h.reply([Self.call]); await drain()
        XCTAssertTrue(h.calls.isEmpty, "A late request must never execute its write proposal")
        XCTAssertTrue(h.brain.busy)
        h.reply([["type": "message", "content": [["text": "It is a meeting invitation."]]]]); await drain()
        XCTAssertEqual(h.speech.last, "It is a meeting invitation.")
        XCTAssertEqual(h.failures.count, 1)
        let events = h.events.compactMap { $0["event"] as? [String: Any] }
        XCTAssertEqual(events.filter { $0["type"] as? String == "response.failed" }.count, 1)
    }

    @MainActor func testNewQuestionPreservesAcceptedActionWhileDroppingItsSlowPresentation() async throws {
        let h = Harness(); h.start(); await drain()
        h.reply([Self.call]); await drain()
        h.brain.acceptToolCall("c1")
        h.brain.item(["type": "function_call_output", "call_id": "c1", "output": "Archive queued for email A"])
        h.brain.continueResponse(delegation: "d1"); await drain()
        h.brain.user("what did you do with that email?", turn: 2)
        h.brain.begin("d2", live: true, turn: 2); h.brain.settle(turn: 2); await drain()
        XCTAssertEqual(h.requests.count, 3)
        XCTAssertTrue((h.requests.last?["context"] as? String)?.contains("Archive queued for email A") == true)
        h.reply([Self.call]); await drain()
        XCTAssertEqual(h.calls.count, 1, "Do not repeat the accepted archive")
        h.reply([["type": "message", "content": [["text": "The archive is queued."]]]]); await drain()
        XCTAssertEqual(h.speech, ["The archive is queued."])
    }

    @MainActor func testNewQuestionWaitsForAcceptedToolButSkipsOldContinuation() async throws {
        let h = Harness(); h.start(); await drain()
        h.reply([Self.call]); await drain()
        h.brain.acceptToolCall("c1")
        h.brain.user("what is the next email about?", turn: 2)
        h.brain.begin("d2", live: true, turn: 2); h.brain.settle(turn: 2); await drain()
        XCTAssertEqual(h.requests.count, 1, "An accepted action must keep its result")
        h.brain.item(["type": "function_call_output", "call_id": "c1", "output": "Archive queued for email A"])
        h.brain.continueResponse(delegation: "d1"); await drain()
        XCTAssertEqual(h.requests.count, 2)
        let input = try XCTUnwrap(h.requests.last?["input"] as? [[String: Any]])
        XCTAssertEqual(input.last?["content"] as? String, "what is the next email about?")
        XCTAssertTrue((h.requests.last?["context"] as? String)?.contains("Archive queued for email A") == true)
        h.reply([["type": "message", "content": [["text": "The next email asks for approval."]]]]); await drain()
        XCTAssertEqual(h.speech, ["The next email asks for approval."])
    }

    @MainActor func testRequestDeadlineDoesNotExpireWhileAcceptedToolRuns() async throws {
        let h = Harness(); h.brain.requestBound = 0.05; h.start(); await drain()
        h.reply([Self.call]); await drain()
        h.brain.acceptToolCall("c1")
        try await Task.sleep(for: .milliseconds(150)); await drain()
        XCTAssertTrue(h.failures.isEmpty)
        XCTAssertTrue(h.brain.busy)
        h.brain.item(["type": "function_call_output", "call_id": "c1", "output": "Archive queued"])
        h.brain.continueResponse(delegation: "d1"); await drain()
        h.reply([]); await drain()
    }

    @MainActor func testAcceptedSerialCallsOutliveTheBrainWatchdog() async throws {
        let h = Harness(); h.brain.toolCallBound = 0.05; h.start(); await drain()
        var second = Self.call; second["call_id"] = "c2"
        h.reply([Self.call, second]); await drain()
        h.brain.acceptToolCall("c1")
        h.brain.acceptToolCall("c2")
        for id in ["c1", "c2"] {
            try await Task.sleep(for: .milliseconds(100)); await drain()
            XCTAssertEqual(h.requests.count, 1, "Queued and executing calls remain adapter-owned")
            XCTAssertTrue(h.brain.busy)
            h.brain.item(["type": "function_call_output", "call_id": id, "output": "Completed " + id])
        }
        h.brain.continueResponse(delegation: "d1"); await drain()
        XCTAssertEqual(h.requests.count, 2)
        let input = try XCTUnwrap(h.requests.last?["input"] as? [[String: Any]])
        XCTAssertEqual(input.filter { $0["type"] as? String == "function_call_output" }
            .compactMap { $0["output"] as? String }, ["Completed c1", "Completed c2"])
        h.reply([]); await drain()
    }

    @MainActor func testUnclaimedCallTimesOutWithoutReleasingAnAcceptedCall() async throws {
        let h = Harness(); h.brain.toolCallBound = 0.05; h.start(); await drain()
        var second = Self.call; second["call_id"] = "c2"
        h.reply([Self.call, second]); await drain()
        h.brain.acceptToolCall("c1")
        try await Task.sleep(for: .milliseconds(150)); await drain()
        XCTAssertEqual(h.requests.count, 1)
        XCTAssertTrue(h.brain.busy)
        h.brain.item(["type": "function_call_output", "call_id": "c1", "output": "Completed c1"])
        h.brain.continueResponse(delegation: "d1"); await drain()
        let input = try XCTUnwrap(h.requests.last?["input"] as? [[String: Any]])
        let outputs = input.filter { $0["type"] as? String == "function_call_output" }
        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(outputs.first { $0["call_id"] as? String == "c2" }?["output"] as? String,
                       LiveSessionAdapter.toolCallUnfinished)
        XCTAssertEqual(outputs.first { $0["call_id"] as? String == "c1" }?["output"] as? String, "Completed c1")
        h.reply([]); await drain()
    }

    @MainActor func testUnansweredToolCallIsReleasedAndTheResponseContinues() async throws {
        let h = Harness(); h.brain.toolCallBound = 0.05; h.start(); await drain()
        h.reply([Self.call]); await drain()
        XCTAssertEqual(h.calls.count, 1); XCTAssertTrue(h.brain.busy)
        try await Task.sleep(for: .milliseconds(300)); await drain()
        XCTAssertEqual(h.requests.count, 2, "The released call lets the response go on")
        let input = try XCTUnwrap(h.requests.last?["input"] as? [[String: Any]])
        let output = input.first { $0["type"] as? String == "function_call_output" }
        XCTAssertEqual(output?["call_id"] as? String, "c1")
        XCTAssertEqual(output?["output"] as? String, LiveSessionAdapter.toolCallUnfinished)
        h.reply([["type": "message", "content": [["type": "output_text", "text": "That did not confirm."]]]]); await drain()
        XCTAssertFalse(h.brain.busy)
        XCTAssertEqual(h.speech, ["That did not confirm."])
    }

    @MainActor func testSwitchToolsOwnResultSurvivesTheScopeChangeItCaused() async throws {
        let h = Harness(); h.start(); await drain()
        let switchCall: [String: Any] = ["type": "function_call", "call_id": "s1",
            "name": LiveClientBrain.scopeSwitchTool, "arguments": "{\"name\":\"Work\"}"]
        h.reply([switchCall]); await drain()
        XCTAssertEqual(h.calls.count, 1)
        // The switch lands: the state refresh sees the new scope before the tool's result arrives.
        h.brain.updateState("work email", scope: "work")
        h.brain.item(["type": "function_call_output", "call_id": "s1", "output": "Switched to Work. First email: work email."])
        h.brain.continueResponse(delegation: "d1"); await drain()
        XCTAssertEqual(h.requests.count, 2, "The response is not cut short by the scope change")
        let body = String(decoding: try JSONSerialization.data(withJSONObject: try XCTUnwrap(h.requests.last)), as: UTF8.self)
        XCTAssertTrue(body.contains("Switched to Work"))
        XCTAssertFalse(body.contains("email A"), "The old scope's private state still goes")
        h.reply([["type": "message", "content": [["type": "output_text", "text": "Switched to Work. First up, work email."]]]]); await drain()
        XCTAssertEqual(h.speech, ["Switched to Work. First up, work email."])
    }

    @MainActor func testFeedTextReachesBackendAndDoesNotAccumulateAfterAdvance() async throws {
        let h = Harness()
        let step = #"{"item":{"id":"a","account":"owner","emailContent":{"messages":[{"id":"a","text":"Unique source body","textComplete":true}]}}}"#
        h.brain.updateState(step, scope: "personal")
        h.brain.observe(step)
        h.brain.user("How much is due?", turn: 1)
        h.brain.begin("d1", live: true, turn: 1)
        h.brain.settle(turn: 1)
        await drain()
        let context = try XCTUnwrap(h.requests.last?["context"] as? String)
        XCTAssertEqual(context.components(separatedBy: "Unique source body").count, 2)
        h.reply([]); await drain()
        h.brain.updateState("email B", scope: "personal")
        h.brain.user("What is this?", turn: 2)
        h.brain.begin("d2", live: true, turn: 2)
        h.brain.settle(turn: 2)
        await drain()
        XCTAssertFalse(try XCTUnwrap(h.requests.last?["context"] as? String).contains("Unique source body"))
        h.reply([]); await drain()
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
        try await Task.sleep(for: .milliseconds(1150))
        await drain()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(wire.contains { ["response.create", "response.item.create"].contains($0["type"] as? String ?? "") })
        XCTAssertTrue(wire.contains { $0["type"] as? String == "session.commentary.append" && $0["delegation_id"] as? String == "client-d1" })
        adapter.close()
    }
}

extension LiveClientBrainTests {
    @MainActor func testAcceptedFastResultStartsPresentationWithoutWaitingForOldProposal() async {
        let h = Harness(); h.start(); await drain()
        h.brain.recordFastResult("Archived A; B requires a body read", turn: 1)
        h.brain.updateState("email B", scope: "personal")
        h.brain.presentResult("Archived A; B requires a body read", delegation: "presentation", turn: 1)
        await drain()
        XCTAssertEqual(h.requests.count, 2)
        h.reply([Self.call]); await drain()
        XCTAssertTrue(h.calls.isEmpty)
        XCTAssertTrue(h.brain.busy)
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

    @MainActor func testAdapterAnswersNewQuestionWhileOldRequestNeverFinishes() async throws {
        var wire: [[String: Any]] = []
        var replies: [CheckedContinuation<[String: Any], Error>] = []
        var calls = 0
        let adapter = LiveSessionAdapter(wire: { wire.append($0) }, emit: {
            if case .liveFunction = $0 { calls += 1 }
        })
        adapter.clientBrainState = { ("email A", "personal") }
        adapter.enableClientDelegation { _ in
            try await withCheckedThrowingContinuation { replies.append($0) }
        }
        func receive(_ event: [String: Any]) throws { adapter.receive(try JSONSerialization.data(withJSONObject: event)) }
        try receive(["type": "session.started"])
        for turn in 1...2 {
            try receive(["type": "session.input_transcript.delta", "delta": "what does this email say?",
                         "start_ms": turn * 2000, "end_ms": turn * 2000 + 100])
            try receive(["type": "session.delegation.created", "offset_ms": turn * 2000 + 100,
                         "delegation": ["id": "d\(turn)", "target": "client"]])
            try await Task.sleep(for: .milliseconds(1150)); await drain()
        }
        XCTAssertEqual(replies.count, 2, "The old response must release the adapter's running response")
        guard replies.count == 2 else {
            replies.forEach { $0.resume(returning: ["output": []]) }
            adapter.close()
            return
        }
        replies[1].resume(returning: ["output": [["type": "message", "content": [["text": "It is a meeting invitation."]]]]])
        await drain()
        replies[0].resume(returning: ["output": [Self.call]])
        await drain()
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(wire.contains { $0["content"] as? String == "It is a meeting invitation."
            && $0["delegation_id"] as? String == "d2" })
        adapter.close()
    }

    @MainActor func testSkippedOldContinuationDoesNotBlockRecoveryOfNewQuestion() async throws {
        var requests = 0
        var calls: [String] = []
        let adapter = LiveSessionAdapter(wire: { _ in }, emit: {
            if case .liveFunction(let call) = $0 { calls.append(call.id) }
        })
        adapter.clientBrainState = { ("email A", "personal") }
        adapter.enableClientDelegation { _ in
            requests += 1
            return ["output": requests == 1 ? [Self.call] : []]
        }
        func receive(_ event: [String: Any]) throws { adapter.receive(try JSONSerialization.data(withJSONObject: event)) }
        try receive(["type": "session.started"])
        try receive(["type": "session.input_transcript.delta", "delta": "archive it", "start_ms": 100, "end_ms": 200])
        try receive(["type": "session.delegation.created", "offset_ms": 200,
                     "delegation": ["id": "d1", "target": "client"]])
        try await Task.sleep(for: .milliseconds(1150)); await drain()
        XCTAssertEqual(calls, ["c1"])
        try receive(["type": "session.input_transcript.delta", "delta": "what does the next email say?",
                     "start_ms": 2000, "end_ms": 2100])
        try await Task.sleep(for: .milliseconds(1150)); await drain()
        adapter.outbound(["type": "conversation.item.create", "item": ["type": "function_call_output",
            "call_id": "c1", "output": "Archive queued for email A"]])
        adapter.outbound(["type": "response.create"])
        await drain()
        XCTAssertEqual(requests, 1, "The obsolete continuation must not make another model request")
        XCTAssertTrue(adapter.recoverUnworkedRequest(anchor: .init(step: "email B", profileId: "personal", revision: 1)))
        await drain()
        XCTAssertEqual(requests, 2, "Recovery must not remain blocked by backendStarting")
        adapter.close()
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
            try await Task.sleep(for: .milliseconds(1150)); await drain()
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
