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
