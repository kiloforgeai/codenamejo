import XCTest
@testable import CodenameJo

@MainActor
final class UnansweredCommandTests: XCTestCase {
    @MainActor private final class Harness {
        var requests: [[String: Any]] = []
        var signals: [RealtimeSignal] = []
        var wire: [[String: Any]] = []
        lazy var adapter = LiveSessionAdapter(wire: { self.wire.append($0) }, emit: { self.signals.append($0) })
        func start() throws {
            adapter.silentInputRecoveryDelay = 0.05
            adapter.silentInputBound = 0.1
            adapter.enableClientDelegation { [weak self] request in
                self?.requests.append(request)
                return ["output": [["type": "message", "content": [["type": "output_text", "text": "Which saved command did you mean?"]]]]]
            }
            try receive(["type": "session.started"])
        }
        func receive(_ event: [String: Any]) throws { adapter.receive(try JSONSerialization.data(withJSONObject: event)) }
        func input(_ text: String, start: Double = 100, end: Double = 200) throws {
            try receive(["type": "session.input_transcript.delta", "delta": text, "start_ms": start, "end_ms": end])
        }
        func waitForInputFinished(_ text: String, file: StaticString = #filePath, line: UInt = #line) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            func finished() -> Bool {
                signals.contains { if case .liveInputFinished(let value) = $0 { return value == text }; return false }
            }
            while !finished(), .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(finished(), "The command must settle before attempting its action", file: file, line: line)
        }
        var errors: [String] { signals.compactMap { if case .event(.error(_, let code)) = $0 { return code }; return nil } }
    }

    func testSavedCommandWithoutLiveDelegationGetsOneBoundedReasoningAttempt() async throws {
        for text in ["follow up", "run my follow-up command", "Do not run the follow-up command", "Is follow up enabled?"] {
            let h = Harness(); try h.start(); defer { h.adapter.close() }
            try h.input(text)
            try await Task.sleep(for: .milliseconds(1300))
            XCTAssertEqual(h.requests.count, 1, text)
            let input = h.requests.first?["input"] as? [[String: Any]]
            XCTAssertEqual(input?.last?["content"] as? String, text, "Recovery preserves negation and does not manufacture an action")
            XCTAssertTrue((h.requests.first?["context"] as? String)?.contains("supplies no authorization") == true)
            XCTAssertFalse(h.signals.contains { if case .liveFunction = $0 { return true }; return false })
            XCTAssertEqual(h.errors, ["live_input_unanswered"], "Unheard model text cannot silently finish the turn")
        }
    }

    func testNonverbalFragmentsAndIncompleteForwardDoNotResumeDesktopOrRecoverHistory() async throws {
        let h = Harness(); try h.start(); defer { h.adapter.close() }
        h.adapter.beginDesktopInteraction(origin: "archive", revision: 8)
        for (index, text) in ["[sniff", "ing]", "[sighs]", "forward, an"].enumerated() {
            let start = index < 2 ? Double(100 + index * 100) : Double(index * 3_000)
            try h.input(text, start: start, end: start + 100)
            try await Task.sleep(for: .milliseconds(1050))
            XCTAssertTrue(h.adapter.desktopQuiet, text)
            XCTAssertFalse(h.adapter.allowsNewDispatch, text)
            XCTAssertTrue(h.requests.isEmpty, text)
        }
        try h.input("Forward this one to the same person too", start: 20_000, end: 20_100)
        try await h.waitForInputFinished("Forward this one to the same person too")
        XCTAssertFalse(h.adapter.desktopQuiet)
        XCTAssertTrue(h.adapter.allowsNewDispatch)
        for text in ["sniffing", "[breath]", "[coughing]", "forward, an", "please forward to", "go ahead"] {
            XCTAssertNotNil(LiveRequestRecovery.dispatchRefusal(text), text)
        }
        XCTAssertNil(LiveRequestRecovery.dispatchRefusal("Retry that failed forward"))
    }

    func testFragmentedPhraseWaitsForFullInputAndLongUnansweredPauseStartsNewTurn() async throws {
        let h = Harness(); try h.start(); defer { h.adapter.close() }
        try h.input("follow-")
        try await Task.sleep(for: .milliseconds(600))
        try h.input("up command", start: 200, end: 300)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(h.requests.count, 1)
        XCTAssertEqual((h.requests.first?["input"] as? [[String: Any]])?.last?["content"] as? String, "follow-up command")
        try h.input("Hey Jo", start: 10_000, end: 10_200)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(h.requests.count, 2)
        XCTAssertEqual(h.requests.last?["turnIndex"] as? Int, 2)
        XCTAssertEqual((h.requests.last?["input"] as? [[String: Any]])?.last?["content"] as? String, "Hey Jo")
    }

    func testUnfinishedNegationNeverStartsWorkAndEndingCancelsRecovery() async throws {
        let h = Harness(); try h.start(); defer { h.adapter.close() }
        try h.input("Don't")
        try await Task.sleep(for: .milliseconds(1250))
        XCTAssertTrue(h.requests.isEmpty)
        XCTAssertEqual(h.errors, ["live_input_unanswered"])
        let ended = Harness(); try ended.start()
        try ended.input("follow up")
        ended.adapter.close()
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertTrue(ended.requests.isEmpty)
        XCTAssertTrue(ended.errors.isEmpty)
    }

    func testARealSpokenAnswerSuppressesTheFallback() async throws {
        let h = Harness(); try h.start(); defer { h.adapter.close() }
        try h.input("Which command should I use?")
        try h.receive(["type": "session.output_transcript.delta", "delta": "Which saved command did you mean?", "start_ms": 300, "end_ms": 700])
        try await Task.sleep(for: .milliseconds(1250))
        XCTAssertTrue(h.requests.isEmpty)
        XCTAssertTrue(h.errors.isEmpty)
    }

    func testCompletedReplyBackchannelsNeverRecoverTheOldSendButNewRequestsDo() async throws {
        for acknowledgment in ["Mm.", "[chuckles]", "Thanks."] {
            let h = Harness(); try h.start(); defer { h.adapter.close() }
            h.adapter.silentInputRecoveryDelay = 10
            try h.input("Reply to this email with thanks, see you tomorrow.")
            try await h.waitForInputFinished("Reply to this email with thanks, see you tomorrow.")
            XCTAssertTrue(h.adapter.beginFastAction(callId: "sent-once", action: nil, routed: true))
            h.adapter.silentInputRecoveryDelay = 0.05
            h.adapter.outbound(["type": "conversation.item.create", "item": ["type": "function_call_output",
                "call_id": "sent-once", "output": "Sent. Gmail confirmation: fixture-sent-1. Queue advanced to email B."]])
            try h.receive(["type": "session.output_transcript.delta", "delta": "Sent your reply.", "start_ms": 500, "end_ms": 900])
            try h.input(acknowledgment, start: 14_000, end: 14_100)
            try await Task.sleep(for: .milliseconds(1250))
            XCTAssertTrue(h.requests.isEmpty, acknowledgment)
            XCTAssertTrue(h.errors.isEmpty, acknowledgment)
            XCTAssertFalse(h.adapter.beginFastAction(callId: "repeat", action: .archive))
            XCTAssertFalse(h.adapter.beginFastAction(callId: "stale-routed", action: nil, routed: true))
            try h.input("Show me the reply that was sent.", start: 20_000, end: 20_100)
            try await Task.sleep(for: .milliseconds(1250))
            XCTAssertEqual(h.requests.count, 1)
            XCTAssertEqual((h.requests.first?["input"] as? [[String: Any]])?.last?["content"] as? String,
                "Show me the reply that was sent.")
        }
    }

    func testDelayedAndUnknownReceiptsCannotTurnAcknowledgmentIntoAnotherAction() async throws {
        for receipt in ["Sent. Gmail confirmation: fixture-sent-1.", "Outcome unknown. Check Gmail before trying again.", "Gmail refused this send."] {
            let h = Harness(); try h.start(); defer { h.adapter.close() }
            h.adapter.silentInputRecoveryDelay = 10
            try h.input("Reply to this email with thanks.")
            try await h.waitForInputFinished("Reply to this email with thanks.")
            XCTAssertTrue(h.adapter.beginFastAction(callId: "attempt", action: nil, routed: true))
            h.adapter.silentInputRecoveryDelay = 0.05
            try h.input("Mm.", start: 3_000, end: 3_100)
            h.adapter.outbound(["type": "conversation.item.create", "item": ["type": "function_call_output",
                "call_id": "attempt", "output": receipt]])
            try await Task.sleep(for: .milliseconds(1250))
            XCTAssertTrue(h.requests.isEmpty, receipt)
            XCTAssertTrue(h.errors.isEmpty, receipt)
            XCTAssertFalse(h.adapter.hasUnresolvedQueueAction)
        }
    }

    func testStandaloneAndDesktopAcknowledgmentsDoNotResumeOldWork() async throws {
        for desktop in [false, true] {
            let h = Harness(); try h.start(); defer { h.adapter.close() }
            if desktop { h.adapter.beginDesktopInteraction(origin: "test", revision: 1) }
            try h.input("Thank you.")
            try await Task.sleep(for: .milliseconds(1250))
            XCTAssertTrue(h.requests.isEmpty)
            XCTAssertTrue(h.errors.isEmpty)
            XCTAssertEqual(h.adapter.desktopQuiet, desktop)
        }
        for request in ["Yes", "Okay, reply to Dana", "Thanks, archive this", "What did you send?", "Reply to the other email"] {
            XCTAssertFalse(LiveRequestRecovery.isBackchannel(request), request)
        }
    }

    func testSupersededAndEndedUnansweredHistoryIsTerminalWithoutInventingAReply() {
        let service = RealtimeService()
        let client = FullDuplexVoiceClient()
        service.bindLiveHistory(client)
        client.handle(.liveUserActivity)
        client.handle(.liveInputText("follow up"))
        let first = client.historyTurnID
        client.handle(.liveUserActivity)
        XCTAssertEqual(service.lastCompletedTurn?.id, first)
        XCTAssertEqual(service.lastCompletedTurn?.status, .cancelled)
        XCTAssertEqual(service.lastCompletedTurn?.responseText, "")
        client.handle(.liveInputText("Are you there?"))
        client.handle(.closed(reason: "test disconnect"))
        XCTAssertEqual(service.lastCompletedTurn?.status, .cancelled)
        client.handle(.liveUserActivity)
        client.handle(.liveInputText("follow up again"))
        client.handle(.event(.error(message: "No action started", code: "live_input_unanswered")))
        client.onHistoryInterrupted?(client.historyTurnID)
        XCTAssertEqual(service.lastCompletedTurn?.status, .failed, "Do not overwrite explicit failure or provider receipts")
    }

    func testHyphenVariantsMatchOnlyOneCommandAndRetainDisabledAndMissingRefusals() {
        var command = CustomCommand(id: "follow", keyword: "follow-up", spoken: "Follow-up", instruction: "",
            actions: [.init(tool: "label_message", detail: "Apply Follow up"), .init(tool: "archive_message", detail: "Archive")],
            enabled: true, createdAt: nil)
        XCTAssertEqual(CustomCommandRules.matching("follow up", commands: [command])?.id, "follow")
        XCTAssertEqual(CustomCommandRules.matching("follow–up", commands: [command])?.id, "follow")
        XCTAssertNil(CustomCommandRules.matching("Do not run follow up", commands: [command]))
        var duplicate = command; duplicate.keyword = "follow up"
        XCTAssertNil(CustomCommandRules.matching("follow—up", commands: [command, duplicate]))
        XCTAssertEqual(CustomCommandRules.matching("follow-up", commands: [command, duplicate])?.keyword, "follow-up")
        command.enabled = false
        if case .failure(let error) = CustomCommandRules.run(keyword: "follow up", commands: [command]) {
            XCTAssertTrue(error.sentence.contains("switched off"))
        } else { XCTFail("Disabled alias must not run") }
        if case .success = CustomCommandRules.run(keyword: "missing", commands: [command]) { XCTFail("Missing command must not run") }
    }
}
