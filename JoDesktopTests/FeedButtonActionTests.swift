import XCTest
@testable import CodenameJo

@MainActor
final class FeedButtonActionTests: XCTestCase {
    private func receive(_ adapter: LiveSessionAdapter, _ event: [String: Any]) throws {
        adapter.receive(try JSONSerialization.data(withJSONObject: event))
    }
    private func started(_ adapter: LiveSessionAdapter, wire: () -> [[String: Any]]) throws {
        try receive(adapter, ["type": "session.started"])
        for item in wire() where item["type"] as? String == "session.instructions.append" {
            try receive(adapter, ["type": "session.instructions.appended", "client_event_id": item["event_id"]!])
        }
    }

    func testClickStartsItsOwnTurnAndCannotOverlapOrAuthorizeVoiceReplay() throws {
        for action in LiveFastAction.buttons {
            XCTAssertEqual(LiveFastAction.parse(action.requestText), action, "Buttons use the same write-intent checks as speech")
        }
        var wire: [[String: Any]] = []
        var turns: [Int] = []
        let adapter = LiveSessionAdapter(wire: { wire.append($0) }, emit: {
            if case .liveButtonAction = $0 { turns.append(turns.count + 1) }
        })
        defer { adapter.close() }
        XCTAssertFalse(adapter.beginButtonAction(callId: "before", action: .archive))
        try started(adapter, wire: { wire })
        XCTAssertTrue(adapter.beginButtonAction(callId: "click", action: .archive))
        XCTAssertFalse(adapter.beginButtonAction(callId: "double-click", action: .next))
        XCTAssertFalse(adapter.beginFastAction(callId: "echo", action: .archive))
        XCTAssertEqual(turns, [1])
        adapter.outbound(["type": "conversation.item.create", "item": [
            "type": "function_call_output", "call_id": "click", "output": "Archive failed. The original email remains selected."]])
        XCTAssertFalse(adapter.beginButtonAction(callId: "before-result", action: .archive),
                       "Pending result presentation cannot be overtaken")
        adapter.close()
        XCTAssertFalse(adapter.beginButtonAction(callId: "closed", action: .archive))
    }

    func testUnfinishedSpeechAndBackendWorkBlockClicks() throws {
        var wire: [[String: Any]] = []
        let adapter = LiveSessionAdapter(wire: { wire.append($0) }, emit: { _ in })
        defer { adapter.close() }
        try started(adapter, wire: { wire })
        try receive(adapter, ["type": "session.input_transcript.delta", "delta": "Don't",
                              "start_ms": 100, "end_ms": 200])
        XCTAssertFalse(adapter.beginButtonAction(callId: "speech", action: .archive))
        let other = LiveSessionAdapter(wire: { _ in }, emit: { _ in })
        defer { other.close() }
        try receive(other, ["type": "session.started"])
        try receive(other, ["type": "session.delegation.created", "delegation": ["id": "d1", "response_id": "r1"]])
        try receive(other, ["type": "response.event", "event": ["type": "response.created", "response": ["id": "r1"]]])
        XCTAssertFalse(other.beginButtonAction(callId: "backend", action: .next))
    }

    func testCompletedClickAllowsANewActionWithoutDictatingAnotherTurn() throws {
        var wire: [[String: Any]] = []
        let adapter = LiveSessionAdapter(wire: { wire.append($0) }, emit: { _ in })
        adapter.enableClientDelegation { _ in
            XCTFail("A local button action must not ask the model to authorize it")
            return ["output": []]
        }
        defer { adapter.close() }
        try started(adapter, wire: { wire })
        adapter.outbound(["type": "conversation.item.create", "item": ["type": "message", "role": "developer",
            "content": [["type": "input_text", "text": "Presentation context whose acknowledgement is delayed"]]]])
        XCTAssertTrue(adapter.beginButtonAction(callId: "archive", action: .archive))
        XCTAssertFalse(adapter.beginButtonAction(callId: "overlap", action: .next))
        adapter.outbound(["type": "conversation.item.create", "item": [
            "type": "function_call_output", "call_id": "archive", "output": "The application is presenting the next item."]])
        XCTAssertTrue(adapter.beginButtonAction(callId: "next", action: .next))
        XCTAssertFalse(adapter.beginFastAction(callId: "voice-replay", action: .next))
    }

    func testOneSecTimesOutWithoutReplayingAndAllowsNextButton() async throws {
        var wire: [[String: Any]] = []
        var errors: [String] = []
        var clicks: [String] = []
        let adapter = LiveSessionAdapter(wire: { wire.append($0) }, emit: {
            if case .event(.error(_, let code)) = $0 { errors.append(code ?? "") }
            if case .liveButtonAction(let id, _) = $0 { clicks.append(id) }
        })
        adapter.enableClientDelegation { _ in XCTFail("No replay or extra continuation"); return ["output": []] }
        adapter.buttonPresentationBound = 0.05
        defer { adapter.close() }
        try started(adapter, wire: { wire })
        XCTAssertTrue(adapter.beginButtonAction(callId: "button-first", action: .archive))
        adapter.outbound(["type": "conversation.item.create", "item": ["type": "function_call_output",
            "call_id": "button-first", "output": "The application is presenting the next item."]])
        adapter.outbound(["type": "response.create"])
        try receive(adapter, ["type": "session.output_transcript.delta", "delta": "One sec.", "start_ms": 0, "end_ms": 100])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(errors, ["live_button_presentation_timeout"])
        XCTAssertNil(adapter.buttonActionBlockReason)
        XCTAssertTrue(adapter.beginButtonAction(callId: "button-second", action: .next))
        XCTAssertEqual(clicks, ["button-first", "button-second"])
    }

    func testClientConsumesQueuedClickAsOneHistoryTurnBeforeAnyToolCallbacks() async throws {
        let client = FullDuplexVoiceClient()
        let transport = FullDuplexTransport()
        var wire: [[String: Any]] = []
        var pending: [RealtimeSignal] = []
        let adapter = LiveSessionAdapter(wire: { wire.append($0) }, emit: { pending.append($0) })
        transport.liveAdapter = adapter
        client.activateFeedForTesting(transport: transport)
        client.liveConfiguration = .init(fastActions: [LiveFastAction.archive.rawValue])
        defer { adapter.close() }
        try started(adapter, wire: { wire })
        pending.removeAll()
        let selection = MailSelection(account: "fixture@example.test", messageID: "A")
        let context = try XCTUnwrap(FeedActionContext(.init(profileID: "fixture", conversationID: UUID(), focus: selection, queueCurrent: selection)))
        var checkpoints: [(UUID, String)] = []
        var toolUserTexts: [String] = []
        client.onHistoryCheckpoint = { checkpoints.append(($0, $1)) }
        client.onToolUse = { _ in toolUserTexts.append(client.historyUserText) }
        let before = client.historyTurnID
        XCTAssertNil(client.performFeedAction(.archive, context: context))
        XCTAssertNotNil(client.performFeedAction(.archive, context: context))
        XCTAssertEqual(client.historyTurnID, before, "The stream has not consumed the button yet")
        for event in pending { client.handle(event) }
        XCTAssertNotEqual(client.historyTurnID, before)
        XCTAssertEqual(client.historyUserText, "Archive (button)")
        XCTAssertEqual(toolUserTexts, ["Archive (button)"], "Even the stale-target refusal belongs to the button turn")
        XCTAssertTrue(checkpoints.contains { $0.0 == client.historyTurnID && $0.1 == "Archive (button)" })
        XCTAssertFalse(client.userSpeaking)
    }

    func testPresentationTimeoutDoesNotEndTheCallOrMarkTheWriteFailed() {
        let client = FullDuplexVoiceClient()
        var notices: [String] = []
        client.onRecoverableNotice = { notices.append($0) }
        client.onError = { _ in XCTFail("A missing presentation is recoverable") }
        client.onTurnFailed = { _ in XCTFail("The actual action receipt still determines success") }
        client.handle(.event(.error(message: "Presentation timed out", code: "live_button_presentation_timeout")))
        XCTAssertEqual(notices, ["Presentation timed out"])
        let model = DesktopWorkspaceModel()
        model.feedActionError = "An action is still running. Wait for its result."
        let session = VoiceDiagnostics().begin(engine: "test")
        let fields = VoiceDiagnostics.safeFields(model.renderedState.diagnosticFields(session: session, revision: 1))
        XCTAssertEqual(fields["action_error_visible"], "true")
        XCTAssertNotNil(fields["action_error_hash"])
    }

    func testResultPresentationUsesExactSpeechAndReplacesEmptyAcknowledgement() async throws {
        var wire: [[String: Any]] = []
        let adapter = LiveSessionAdapter(wire: { wire.append($0) }, emit: { _ in })
        adapter.enableClientDelegation { request in
            XCTAssertEqual(request["presentationOnly"] as? Bool, true)
            return ["output": [["type": "message", "content": [["type": "output_text", "text": "One sec."]]]]]
        }
        defer { adapter.close() }
        try started(adapter, wire: { wire })
        XCTAssertTrue(adapter.beginButtonAction(callId: "button-present", action: .archive))
        adapter.outbound(["type": "conversation.item.create", "item": ["type": "function_call_output",
            "call_id": "button-present", "output": "Archived A. Email B is selected."]])
        for _ in 0..<50 { await Task.yield() }
        let comments = wire.filter { $0["type"] as? String == "session.commentary.append" }
            .compactMap { $0["content"] as? String }.joined()
        XCTAssertTrue(comments.contains("Say exactly:"), comments)
        XCTAssertTrue(comments.contains("couldn't explain the next item"), comments)
        XCTAssertFalse(comments.contains("One sec."), comments)
    }

    func testButtonContextRequiresVisibleSelectionAndChangesWithSessionProfileAndQueue() throws {
        let selection = MailSelection(account: "work@example.test", messageID: "A")
        var rendered = RenderedFeedState(profileID: "work", conversationID: UUID(), focus: selection, queueCurrent: selection)
        let context = try XCTUnwrap(FeedActionContext(rendered))
        rendered.focus = nil
        XCTAssertNil(FeedActionContext(rendered))
        rendered.focus = selection
        rendered.queueCurrent = .init(account: selection.account, messageID: "B")
        XCTAssertNil(FeedActionContext(rendered))
        rendered.queueCurrent = selection
        rendered.queueRevision += 1
        XCTAssertNotEqual(FeedActionContext(rendered), context)
        rendered.queueRevision -= 1
        rendered.profileID = "personal"
        XCTAssertNotEqual(FeedActionContext(rendered), context)
        rendered.profileID = "work"
        rendered.conversationID = UUID()
        XCTAssertNotEqual(FeedActionContext(rendered), context)
        rendered.conversationID = nil
        XCTAssertNotNil(FeedActionContext(rendered), "An explicit desktop selection does not need a voice conversation")
        let model = DesktopWorkspaceModel()
        XCTAssertNil(model.feedActionContext, "An empty desktop has no action target")
    }
}
