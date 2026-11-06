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
        var sendsRequest = true
        lazy var brain: LiveClientBrain = LiveClientBrain(request: { [weak self] body in
            guard let self else { throw CancellationError() }
            if sendsRequest { brain.requestWasSent(body["requestId"] as? String ?? "") }
            requests.append(body)
            return try await withCheckedThrowingContinuation { self.replies.append($0) }
        }, deliver: { [weak self] in self?.events.append($0) },
           speak: { [weak self] text, delegation in
               self?.speech.append(text); self?.spokenDelegations.append(delegation)
           },
           failed: { [weak self] in self?.failures.append($0) })
        func start() {
            brain.updateState("email A", scope: "personal")
            brain.user("archive it", turn: 1)
            brain.begin("d1", live: true, turn: 1)
            brain.settle(turn: 1)
        }
        func reply(_ output: [[String: Any]], file: StaticString = #filePath, line: UInt = #line) {
            guard !replies.isEmpty else { return XCTFail("No provider request is waiting for this reply", file: file, line: line) }
            replies.removeFirst().resume(returning: ["output": output])
        }
        var calls: [[String: Any]] {
            events.compactMap { $0["event"] as? [String: Any] }
                .compactMap { $0["item"] as? [String: Any] }.filter { $0["type"] as? String == "function_call" }
        }
    }
    private static let call: [String: Any] = ["type": "function_call", "call_id": "c1",
        "name": "archive_message", "arguments": "{\"message_id\":\"a\"}"]
    @MainActor private func drain() async { for _ in 0..<20 { await Task.yield() } }

    @MainActor func testPreRequestFailuresHaveOneTerminalReasonWithoutAProviderRequest() async throws {
        for reason in ["context_limit", "context_encoding_failed", "step_limit"] {
            let h = Harness()
            var outcomes: [[String: String]] = []
            h.brain.onAttemptOutcome = { turn, fields in
                XCTAssertEqual(turn, 1); outcomes.append(fields)
            }
            if reason == "context_limit" { h.brain.contextByteLimit = 1 }
            if reason == "context_encoding_failed" { h.brain.encodeContext = { _ in throw CocoaError(.fileWriteInapplicableStringEncoding) } }
            if reason == "step_limit" { h.brain.stepLimit = 0 }
            h.start(); await drain(); h.brain.close()
            XCTAssertTrue(h.requests.isEmpty)
            XCTAssertEqual(outcomes.count, 1)
            XCTAssertEqual(outcomes.first?["reason"], reason)
            XCTAssertEqual(outcomes.first?["delegation_id"], "d1")
            XCTAssertEqual(outcomes.first?["request_sent"], "false")
            XCTAssertNil(outcomes.first?["request_id"])
            if reason == "context_limit" {
                XCTAssertGreaterThan(Int(outcomes[0]["total_bytes"] ?? "0") ?? 0, 1)
                XCTAssertNotNil(outcomes[0]["currentSelection_bytes"])
            }
        }
    }

    @MainActor func testQueuedDelegationsReportCancellationWithoutInventingARequest() {
        let h = Harness()
        var outcomes: [[String: String]] = []
        h.brain.onAttemptOutcome = { _, fields in outcomes.append(fields) }
        h.brain.begin("d1", live: true, turn: 1)
        h.brain.begin("d2", live: true, turn: 2)
        h.brain.close(); h.brain.close()
        XCTAssertEqual(outcomes.map { $0["reason"] }, ["superseded", "cancelled"])
        XCTAssertTrue(outcomes.allSatisfy { $0["stage"] == "queued" && $0["request_sent"] == "false" && $0["request_id"] == nil })
        XCTAssertTrue(h.requests.isEmpty)
    }

    @MainActor func testReadReceiptThenRejectedPresentationAndRetryHaveDistinctOutcomes() async throws {
        let h = Harness()
        var outcomes: [[String: String]] = []
        h.brain.onAttemptOutcome = { _, fields in outcomes.append(fields) }
        h.start(); await waitForRequest(1, in: h)
        h.reply([["type": "function_call", "call_id": "read", "name": "gmail_get_message", "arguments": "{}"]])
        await drain()
        h.brain.item(["type": "function_call_output", "call_id": "read", "output": "verified source é 😀"])
        h.brain.contextByteLimit = 1
        h.brain.continueResponse(delegation: "d1")
        h.brain.user("retry", turn: 2); h.brain.begin("d2", live: true, turn: 2); h.brain.settle(turn: 2)
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(outcomes.map { $0["reason"] }, ["context_limit", "context_limit"])
        XCTAssertEqual(outcomes[0]["request_sent"], "true")
        XCTAssertEqual(outcomes[0]["tool_result_bytes"], String("verified source é 😀".utf8.count))
        XCTAssertEqual(outcomes[1]["request_sent"], "false")
        XCTAssertEqual(h.requests.count, 1)
        XCTAssertEqual(h.calls.count, 1)
        h.brain.close()
    }

    @MainActor func testCompletedFailedAndCancelledRequestsTerminateOnlyOnce() async throws {
        for reason in ["completed", "provider_failure", "request_preparation_failed", "cancelled", "timeout", "superseded"] {
            let h = Harness()
            h.sendsRequest = reason != "request_preparation_failed"
            var outcomes: [[String: String]] = []
            let terminated = expectation(description: reason)
            h.brain.onAttemptOutcome = { _, fields in outcomes.append(fields); terminated.fulfill() }
            h.brain.requestBound = reason == "timeout" ? 0.03 : 10
            h.brain.user("read the current email", turn: 1)
            h.brain.begin("d1", live: true, turn: 1); h.brain.settle(turn: 1)
            await waitForRequest(1, in: h)
            switch reason {
            case "completed": h.reply([])
            case "provider_failure", "request_preparation_failed": h.replies.removeFirst().resume(throwing: URLError(.badServerResponse))
            case "timeout": break
            case "superseded": h.brain.user("another request", turn: 2); h.reply([])
            default: h.brain.close(); h.reply([])
            }
            await fulfillment(of: [terminated], timeout: 2)
            if reason == "timeout" { h.reply([]) }
            h.brain.close()
            XCTAssertEqual(outcomes.count, 1, reason)
            XCTAssertEqual(outcomes.first?["reason"], reason)
            XCTAssertEqual(outcomes.first?["request_sent"], String(h.sendsRequest))
        }
    }

    @MainActor func testLargeCommandLookupDoesNotPoisonContinuationOrNextTurn() async throws {
        let h = Harness(); h.start(); await drain()
        let instructions = String(repeating: "command instruction ", count: 5_500)
        h.reply([["type": "function_call", "call_id": "cmd", "name": "commands",
                  "arguments": #"{"action":"run","keyword":"follow up"}"#]])
        await drain()
        h.brain.item(["type": "function_call_output", "call_id": "cmd", "output": instructions])
        h.brain.continueResponse(delegation: "d1"); await drain()
        XCTAssertTrue(h.failures.isEmpty)
        guard h.requests.count == 2 else { return XCTFail("Command continuation was rejected before reaching the model") }
        let body = try XCTUnwrap(h.requests.last)
        let input = try LiveOpenAI.boundedInput(body)
        let result = try XCTUnwrap(input.first { $0["call_id"] as? String == "cmd" && $0["type"] as? String == "function_call_output" }?["output"] as? String)
        XCTAssertTrue(result.contains("source_call_id"))
        XCTAssertTrue(result.contains("read_tool_result"))
        XCTAssertFalse((body["context"] as? String ?? "").contains("command instruction"))
        h.reply([Self.call]); await drain()
        h.brain.item(["type": "function_call_output", "call_id": "c1", "output": "Archive queued for email A"])
        h.brain.continueResponse(delegation: "d1"); await drain()
        h.reply([]); await drain()
        h.brain.user("What did you do?", turn: 2); h.brain.begin("d2", live: true, turn: 2)
        h.brain.settle(turn: 2); await drain()
        let context = try XCTUnwrap(h.requests.last?["context"] as? String)
        XCTAssertFalse(context.contains("command instruction"))
        XCTAssertTrue(context.contains("Archive queued for email A"))
        XCTAssertTrue(context.contains("follow up"))
        XCTAssertTrue(h.failures.isEmpty)
        h.reply([]); await drain()
    }

    @MainActor func testCommandSaveRetainsReceiptWithoutRepeatingItsDefinition() async throws {
        let h = Harness(); h.start(); await drain()
        let detail = String(repeating: "saved instruction ", count: 6_000)
        let args: [String: Any] = ["action": "save", "keyword": "follow up",
            "actions": [["tool": "label_message", "detail": detail]]]
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        h.reply([["type": "function_call", "call_id": "save", "name": "commands", "arguments": raw]])
        await drain()
        h.brain.item(["type": "function_call_output", "call_id": "save", "output": "Saved follow up."])
        h.brain.continueResponse(delegation: "d1"); await drain()
        XCTAssertTrue(h.failures.isEmpty)
        guard h.requests.count == 2 else { return XCTFail("Saved definition blocked its own receipt") }
        let context = try XCTUnwrap(h.requests.last?["context"] as? String)
        XCTAssertTrue(context.contains("Saved follow up."))
        XCTAssertFalse(context.contains("saved instruction"))
        let input = try LiveOpenAI.boundedInput(try XCTUnwrap(h.requests.last))
        XCTAssertEqual(input.first { $0["call_id"] as? String == "save" }?["arguments"] as? String, raw)
        h.reply([]); await drain()
    }

    @MainActor func testPreviousReceiptCannotSatisfyNewArchiveOnNextSelection() async throws {
        let h = Harness(); h.start(); await waitForRequest(1, in: h)
        h.reply([Self.call]); await waitForCalls(1, in: h)
        h.brain.item(["type": "function_call_output", "call_id": "c1", "output": "Archived A"])
        h.brain.continueResponse(delegation: "d1"); await waitForRequest(2, in: h)
        h.reply([]); await drain()
        h.brain.updateState("email F", scope: "personal")
        h.brain.user("Just archive this", turn: 2)
        h.brain.begin("d2", live: true, turn: 2); h.brain.settle(turn: 2)
        await waitForRequest(3, in: h)
        let context = try XCTUnwrap(h.requests.last?["context"] as? String)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: Any])
        let action = try XCTUnwrap((fields["recordedActions"] as? [[String: Any]])?.first)
        XCTAssertEqual(action["origin_turn"] as? Int, 1)
        XCTAssertEqual(action["origin_selection"] as? String, "email A")
        XCTAssertEqual(fields["current_turn"] as? Int, 2)
        h.reply([["type": "message", "content": [["text": "Archived A. Next is F. What next?"]]]]); await drain()
        XCTAssertFalse(h.speech.contains("Archived A. Next is F. What next?"))
        XCTAssertTrue(h.speech.last?.contains("haven't executed") == true)
        XCTAssertEqual(h.calls.count, 1)
        XCTAssertFalse(h.brain.busy)
    }

    @MainActor func testUnexecutedArchiveMayClarifyTheTargetWithoutClaimingSuccess() async throws {
        let h = Harness(); h.start(); await waitForRequest(1, in: h)
        h.reply([["type": "message", "content": [["text": "Which email do you mean?"]]]]); await drain()
        XCTAssertEqual(h.speech, ["Which email do you mean?"])
        XCTAssertTrue(h.failures.isEmpty)
        XCTAssertTrue(h.calls.isEmpty)
    }

    @MainActor func testSupersessionAndTimeoutHaveDistinctCorrelatedReasons() async throws {
        let h = Harness()
        var reasons: [(String, Int)] = []
        var requestIDs: [String] = []
        h.brain.onRequestTransition = { reason, request, delegation, turn in
            XCTAssertFalse(request.isEmpty); XCTAssertFalse(delegation.isEmpty)
            reasons.append((reason, turn))
            requestIDs.append(request)
        }
        h.start(); await waitForRequest(1, in: h)
        h.brain.user("read my calendar", turn: 2)
        h.brain.requestBound = 0.05
        h.brain.begin("d2", live: true, turn: 2); h.brain.settle(turn: 2)
        await waitForRequest(2, in: h)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(reasons.map { $0.0 }, ["request_superseded", "request_timed_out"])
        XCTAssertEqual(reasons.map { $0.1 }, [1, 2])
        XCTAssertEqual(requestIDs, h.requests.compactMap { $0["requestId"] as? String })
        XCTAssertFalse(h.brain.busy)
        h.reply([Self.call]); h.reply([Self.call]); await drain()
        XCTAssertTrue(h.calls.isEmpty)
    }

    @MainActor private func waitForRequest(_ count: Int, in harness: Harness) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while harness.requests.count < count, .now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(harness.requests.count, count)
    }

    @MainActor private func waitForCalls(_ count: Int, in harness: Harness) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while harness.calls.count < count, .now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(harness.calls.count, count)
    }

    @MainActor func testCompletedJobInvalidatesAnInflightRunningAnnouncement() async throws {
        let h = Harness()
        h.brain.updateState("email A", scope: "personal")
        h.brain.user("How is that job going?", turn: 1)
        h.brain.begin("d1", live: true, turn: 1); h.brain.settle(turn: 1)
        await waitForRequest(1, in: h)
        let job = UUID()
        h.brain.jobCompleted(id: job, result: "Archived the selected email.")
        h.reply([["type": "message", "content": [["type": "output_text", "text": "That job is still running."]]]])
        await waitForRequest(2, in: h)
        XCTAssertTrue(h.speech.isEmpty)
        guard h.requests.count == 2 else { return }
        let context = try XCTUnwrap(h.requests.last?["context"] as? String)
        XCTAssertTrue(context.contains(job.uuidString))
        XCTAssertTrue(context.contains("finished"))
        XCTAssertTrue(context.contains("Archived the selected email."))
        h.brain.jobCompleted(id: job, result: "Archived the selected email.")
        h.reply([["type": "message", "content": [["type": "output_text", "text": "Archived."]]]])
        await drain()
        XCTAssertEqual(h.speech, ["Archived."])
        XCTAssertEqual(h.requests.count, 2, "A duplicate completion must not trigger another reasoning round")
    }

    @MainActor func testCompletedJobsRemainAvailableAfterPresentationHintsAndClearOnProfileSwitch() async throws {
        let h = Harness(); h.start(); await drain()
        let job = UUID()
        h.brain.jobCompleted(id: job, result: "Attachment result.")
        for i in 0..<12 { h.brain.observe("Presentation hint \(i)") }
        h.reply([]); await waitForRequest(2, in: h)
        guard h.requests.count == 2 else { return }
        let context = try XCTUnwrap(h.requests.last?["context"] as? String)
        XCTAssertTrue(context.contains("Attachment result."))
        h.reply([]); await drain()
        h.brain.updateState("email B", scope: "work")
        h.brain.user("What is this?", turn: 2)
        h.brain.begin("d2", live: true, turn: 2)
        h.brain.settle(turn: 2); await drain()
        let next = try XCTUnwrap(h.requests.last?["context"] as? String)
        XCTAssertFalse(next.contains(job.uuidString))
        XCTAssertFalse(next.contains("Attachment result."))
        h.reply([]); await drain()
    }

    @MainActor func testCompletedJobContextHasABoundedSize() async throws {
        let h = Harness(); h.start(); await drain()
        for _ in 0..<20 { h.brain.jobCompleted(id: UUID(), result: String(repeating: "Long result. ", count: 10_000)) }
        h.reply([]); await waitForRequest(2, in: h)
        guard h.requests.count == 2 else { return }
        let context = try XCTUnwrap(h.requests.last?["context"] as? String)
        XCTAssertLessThan(context.utf8.count, 30_000)
        XCTAssertTrue(context.contains("Result shortened"))
        h.reply([]); await drain()
    }

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
        let h = Harness(); h.start(); await waitForRequest(1, in: h)
        h.reply([Self.call])
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while h.calls.isEmpty, .now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(h.calls.count, 1)
        let result: [String: Any] = ["type": "function_call_output", "call_id": "c1", "output": "Queued for email a, not completed"]
        h.brain.item(result); h.brain.item(result)
        h.brain.updateState("email B", scope: "personal")
        h.brain.continueResponse(delegation: "d1"); await waitForRequest(2, in: h)
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
        let h = Harness(); h.brain.requestBound = 0.05; h.start(); await waitForRequest(1, in: h)
        defer { h.brain.close() }
        let timeoutDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while h.failures.isEmpty, .now < timeoutDeadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(h.brain.busy)
        XCTAssertEqual(h.failures.count, 1)
        XCTAssertEqual(try XCTUnwrap(h.spokenDelegations.first), "d1")
        h.brain.requestBound = 20
        h.brain.user("what is this email about?", turn: 2)
        h.brain.begin("d2", live: true, turn: 2); h.brain.settle(turn: 2); await waitForRequest(2, in: h)
        XCTAssertEqual(h.requests.count, 2)
        h.reply([Self.call]); await drain()
        XCTAssertTrue(h.calls.isEmpty, "A late request must never execute its write proposal")
        XCTAssertTrue(h.brain.busy)
        h.reply([["type": "message", "content": [["text": "It is a meeting invitation."]]]])
        let responseDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while h.brain.busy, .now < responseDeadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(h.speech.last, "It is a meeting invitation.")
        XCTAssertEqual(h.failures.count, 1)
        let events = h.events.compactMap { $0["event"] as? [String: Any] }
        XCTAssertEqual(events.filter { $0["type"] as? String == "response.failed" }.count, 1)
    }

    @MainActor func testNewQuestionPreservesAcceptedActionWhileDroppingItsSlowPresentation() async throws {
        let h = Harness(); h.start(); await waitForRequest(1, in: h)
        defer { h.brain.close() }
        h.reply([Self.call])
        let callDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while h.calls.isEmpty, .now < callDeadline { try await Task.sleep(for: .milliseconds(1)) }
        guard h.calls.count == 1 else { return XCTFail("The initial archive proposal was not delivered") }
        h.brain.acceptToolCall("c1")
        h.brain.item(["type": "function_call_output", "call_id": "c1", "output": "Archive queued for email A"])
        h.brain.continueResponse(delegation: "d1"); await waitForRequest(2, in: h)
        h.brain.user("what did you do with that email?", turn: 2)
        h.brain.begin("d2", live: true, turn: 2); h.brain.settle(turn: 2); await waitForRequest(3, in: h)
        XCTAssertEqual(h.requests.count, 3)
        XCTAssertTrue((h.requests.last?["context"] as? String)?.contains("Archive queued for email A") == true)
        h.reply([Self.call]); await drain()
        XCTAssertEqual(h.calls.count, 1, "Do not repeat the accepted archive")
        h.reply([["type": "message", "content": [["text": "The archive is queued."]]]])
        let speechDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while h.speech.isEmpty, .now < speechDeadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(h.speech, ["The archive is queued."])
    }

    @MainActor func testNewQuestionWaitsForAcceptedToolButSkipsOldContinuation() async throws {
        let h = Harness(); h.start(); await waitForRequest(1, in: h)
        h.reply([Self.call])
        let callDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while h.calls.isEmpty, .now < callDeadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(h.calls.count, 1)
        h.brain.acceptToolCall("c1")
        h.brain.user("what is the next email about?", turn: 2)
        h.brain.begin("d2", live: true, turn: 2); h.brain.settle(turn: 2); await drain()
        XCTAssertEqual(h.requests.count, 1, "An accepted action must keep its result")
        h.brain.item(["type": "function_call_output", "call_id": "c1", "output": "Archive queued for email A"])
        h.brain.continueResponse(delegation: "d1"); await waitForRequest(2, in: h)
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
        let h = Harness(); h.start(); await waitForRequest(1, in: h)
        defer { h.brain.close() }
        let switchCall: [String: Any] = ["type": "function_call", "call_id": "s1",
            "name": LiveClientBrain.scopeSwitchTool, "arguments": "{\"name\":\"Work\"}"]
        h.reply([switchCall])
        let callDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while h.calls.isEmpty, .now < callDeadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(h.calls.count, 1)
        // The switch lands: the state refresh sees the new scope before the tool's result arrives.
        h.brain.updateState("work email", scope: "work")
        h.brain.item(["type": "function_call_output", "call_id": "s1", "output": "Switched to Work. First email: work email."])
        h.brain.continueResponse(delegation: "d1"); await waitForRequest(2, in: h)
        XCTAssertEqual(h.requests.count, 2, "The response is not cut short by the scope change")
        let body = String(decoding: try JSONSerialization.data(withJSONObject: try XCTUnwrap(h.requests.last)), as: UTF8.self)
        XCTAssertTrue(body.contains("Switched to Work"))
        XCTAssertFalse(body.contains("email A"), "The old scope's private state still goes")
        h.reply([["type": "message", "content": [["type": "output_text", "text": "Switched to Work. First up, work email."]]]])
        let speechDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while h.speech.isEmpty, .now < speechDeadline { try await Task.sleep(for: .milliseconds(1)) }
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
    private func longThreadStep() throws -> String {
        let members = (0..<27).map { index -> [String: Any] in
            ["id": "message-\(index)", "threadId": "long-thread", "from": "Person \(index) <person@example.test>",
             "recipient": "Recipient <recipient@example.test>", "subject": "A project meeting and its requirements",
             "date": "Sat, 24 Oct 2026 09:06:01 -0700", "unread": false, "fromMe": false,
             "ancestryCached": true, "internalDate": 1_793_000_000_000,
             "rfcMessageID": "<message-\(index)@example.test>", "inReplyTo": "<previous@example.test>",
             "references": String(repeating: "<previous-message@example.test> ", count: 40),
             "exchangeID": String(repeating: "exchange", count: 20), "snippet": "Some source text"]
        }
        return GmailReadTools.json(["done": false, "item": ["id": "selected", "threadId": "long-thread",
            "account": "owner@example.test", "subject": "Current email", "exchangeId": "reply-chain",
            "summaryMessages": members, "exchangeContext": members]])
    }

    func testLongThreadCompactionDoesNotExpandSmallFieldsOrRestoreOriginalPayload() throws {
        let source = try longThreadStep()
        let bounded = LiveCompactContext.bounded(source, bytes: 24_000)
        XCTAssertLessThanOrEqual(LiveOpenAI.bytes(bounded), 24_000)
        XCTAssertEqual(LiveSelectionGrounding.selection(bounded), LiveSelectionGrounding.selection(source))
        let reference = LiveCompactContext.selectionReference(source)
        XCTAssertLessThan(LiveOpenAI.bytes(reference), 1_000)
        XCTAssertEqual(LiveSelectionGrounding.selection(reference), LiveSelectionGrounding.selection(source))
        XCTAssertFalse(reference.contains("previous-message"))
        XCTAssertFalse(reference.contains("summaryMessages"))
        let floor = LiveCompactContext.bounded(source, bytes: 1_000)
        XCTAssertLessThan(LiveOpenAI.bytes(floor), LiveOpenAI.bytes(LiveCompactContext.text(source)))
        XCTAssertEqual(LiveSelectionGrounding.selection(floor), LiveSelectionGrounding.selection(source))
    }

    func testShortenedArrayResultsCarryAContentNotice() throws {
        let source = GmailReadTools.json([String(repeating: "details ", count: 5_000)])
        let result = LiveCompactContext.bounded(source, bytes: 2_000)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertLessThanOrEqual(LiveOpenAI.bytes(result), 2_000)
        XCTAssertEqual(fields["contextShortened"] as? Bool, true)
        XCTAssertNotNil(fields["contextNotice"])
        XCTAssertEqual((fields["value"] as? [String])?.count, 1)
    }

    @MainActor func testLongThreadReadContinuesToCalendarAndDoesNotPoisonNextTurn() async throws {
        let h = Harness()
        defer { h.brain.close() }
        let source = try longThreadStep()
        h.brain.updateState(source, scope: "work")
        h.brain.user("Find calendar availability during the dates in this email", turn: 1)
        h.brain.begin("d1", live: true, turn: 1); h.brain.settle(turn: 1)
        await waitForRequest(1, in: h)
        h.reply([["type": "function_call", "call_id": "read", "name": "gmail_get_message",
                  "arguments": #"{"message_id":"selected","account":"owner@example.test"}"#]])
        await waitForCalls(1, in: h)
        h.brain.item(["type": "function_call_output", "call_id": "read",
                      "output": GmailReadTools.json(["id": "selected", "text": "Meet November 4–13. " + String(repeating: "body ", count: 4_000)])])
        h.brain.continueResponse(delegation: "d1"); await waitForRequest(2, in: h)
        h.reply([["type": "function_call", "call_id": "calendar", "name": "list_calendar_events", "arguments": "{}"]])
        await waitForCalls(2, in: h)
        h.brain.item(["type": "function_call_output", "call_id": "calendar", "output": "No conflicting fixture events."])
        h.brain.continueResponse(delegation: "d1"); await waitForRequest(3, in: h)
        h.reply([]); await drain()
        h.brain.user("Try another time", turn: 2)
        h.brain.begin("d2", live: true, turn: 2); h.brain.settle(turn: 2)
        await waitForRequest(4, in: h)
        for request in h.requests {
            XCTAssertNoThrow(try LiveOpenAI.boundedInput(request))
            let context = try XCTUnwrap(request["context"] as? String)
            XCTAssertLessThanOrEqual(context.utf8.count, 96_000)
        }
        XCTAssertEqual(h.calls.compactMap { $0["name"] as? String }, ["gmail_get_message", "list_calendar_events"])
        XCTAssertTrue(h.failures.isEmpty)
        h.reply([]); await drain()
    }

    @MainActor func testLargeSelectedMetadataKeepsIdentityAndAllowsRetry() async throws {
        let h = Harness()
        let item: [String: Any] = ["id": "a", "account": "owner", "threadId": "thread-a",
            "from": String(repeating: "🦊 long header ", count: 15_000), "unknownMetadata": String(repeating: "large ", count: 20_000),
            "emailContent": ["messages": [["id": "a", "text": String(repeating: "source ", count: 20_000), "textComplete": true]]]]
        let source = String(decoding: try JSONSerialization.data(withJSONObject: ["item": item]), as: UTF8.self)
        h.brain.updateState(source, scope: "work")
        for turn in 1...2 {
            h.brain.user(turn == 1 ? "What does this email say?" : "Try again", turn: turn)
            h.brain.begin("d\(turn)", live: true, turn: turn); h.brain.settle(turn: turn)
            await waitForRequest(turn, in: h)
            let body = try XCTUnwrap(h.requests.last)
            let context = try XCTUnwrap(body["context"] as? String)
            XCTAssertLessThanOrEqual(context.utf8.count, LiveOpenAI.contextBytes)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: Any])
            let selected = try XCTUnwrap(fields["currentSelection"] as? String)
            XCTAssertEqual(LiveSelectionGrounding.selection(selected), LiveSelectionGrounding.selection(source))
            XCTAssertTrue(selected.contains("contextShortened"))
            XCTAssertFalse(selected.contains(#""textComplete":true"#))
            XCTAssertNoThrow(try LiveOpenAI.boundedInput(body))
            h.reply([]); await drain()
        }
        XCTAssertTrue(h.failures.isEmpty)
    }

    @MainActor func testLargeSuccessfulReadIsPagedWithoutRepeatingReadOrPoisoningRetry() async throws {
        let h = Harness()
        h.brain.updateState(#"{"item":{"id":"a","account":"owner"}}"#, scope: "work")
        h.brain.user("Read the selected message", turn: 1)
        h.brain.begin("d1", live: true, turn: 1); h.brain.settle(turn: 1)
        await waitForRequest(1, in: h)
        h.reply([["type": "function_call", "call_id": "read", "name": "gmail_get_message", "arguments": #"{"id":"a","account":"owner"}"#]])
        await drain()
        let original = "FIRST\n" + String(repeating: "quoted \"body\" 🦊\n", count: 5_000) + "\nFINAL"
        h.brain.item(["type": "function_call_output", "call_id": "read", "output": original])
        h.brain.continueResponse(delegation: "d1"); await waitForRequest(2, in: h)
        var reconstructed = ""
        var pages = 0
        while pages < 12 {
            let body = try XCTUnwrap(h.requests.last)
            XCTAssertNoThrow(try LiveOpenAI.boundedInput(body))
            let input = try XCTUnwrap(body["input"] as? [[String: Any]])
            let output = try XCTUnwrap(input.last { $0["type"] as? String == "function_call_output" }?["output"] as? String)
            let page = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            XCTAssertEqual(page["offset"] as? Int, reconstructed.utf8.count)
            reconstructed += try XCTUnwrap(page["text"] as? String)
            pages += 1
            if page["complete"] as? Bool == true { break }
            let args = String(decoding: try JSONSerialization.data(withJSONObject: ["source_call_id": "read", "offset": page["next_offset"]!]), as: UTF8.self)
            h.reply([["type": "function_call", "call_id": "page-\(pages)", "name": "read_tool_result", "arguments": args]])
            await waitForRequest(pages + 2, in: h)
        }
        XCTAssertEqual(reconstructed, original)
        XCTAssertEqual(h.calls.count, 1, "Chunk reads stay local and do not repeat provider calls or writes")
        let failedPresentation = expectation(description: "Injected presentation failure settled")
        h.brain.onAttemptOutcome = { _, fields in
            if fields["reason"] == "provider_failure" { failedPresentation.fulfill() }
        }
        h.replies.removeFirst().resume(throwing: NSError(domain: "network", code: 1))
        await fulfillment(of: [failedPresentation], timeout: 2)
        h.brain.user("Try again", turn: 2)
        h.brain.begin("d2", live: true, turn: 2); h.brain.settle(turn: 2)
        await waitForRequest(pages + 2, in: h)
        XCTAssertNoThrow(try LiveOpenAI.boundedInput(try XCTUnwrap(h.requests.last)))
        XCTAssertEqual(h.failures.count, 1, "Only the injected presentation failure should fail")
        h.reply([]); await drain()
    }

    func testBoundedSelectionPreservesLargeGroupMembershipAndMultibyteBoundaries() throws {
        for size in [23_999, 24_000, 24_001, 100_000] {
            let source: [String: Any] = ["item": ["id": "a", "account": "owner", "messages": (0..<40).map { ["id": "m\($0)", "from": String(repeating: "é", count: size / 2)] }]]
            let raw = String(decoding: try JSONSerialization.data(withJSONObject: source), as: UTF8.self)
            let result = LiveCompactContext.bounded(raw, bytes: 24_000)
            XCTAssertLessThanOrEqual(LiveOpenAI.bytes(result), 24_000)
            XCTAssertEqual(LiveSelectionGrounding.selection(result), LiveSelectionGrounding.selection(raw))
            XCTAssertFalse(result.contains("�"))
        }
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
        for _ in 0..<2_000 where h.speech.isEmpty {
            try? await Task.sleep(for: .milliseconds(1))
        }
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
            try receive(["type": "session.input_transcript.delta", "delta": turn == 1 ? "archive it" : "Are you still connected?", "start_ms": turn * 2000, "end_ms": turn * 2000 + 100])
            try receive(["type": "session.delegation.created", "offset_ms": turn * 2000 + 100,
                "delegation": ["id": "d\(turn)", "target": "client"]])
            for _ in 0..<150 {
                if requests >= turn { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            await drain()
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
