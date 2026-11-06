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
            if case .liveDelegation(_, let turn) = $0 { turns.append(turn) }
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
        XCTAssertTrue(adapter.beginButtonAction(callId: "archive", action: .archive))
        XCTAssertFalse(adapter.beginButtonAction(callId: "overlap", action: .next))
        adapter.outbound(["type": "conversation.item.create", "item": [
            "type": "function_call_output", "call_id": "archive", "output": "The application is presenting the next item."]])
        XCTAssertTrue(adapter.beginButtonAction(callId: "next", action: .next))
        XCTAssertFalse(adapter.beginFastAction(callId: "voice-replay", action: .next))
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
        XCTAssertNil(FeedActionContext(rendered))
        let model = DesktopWorkspaceModel()
        XCTAssertNil(model.feedActionContext, "Idle preview is not a session action target")
    }
}
