import Combine
import XCTest
@testable import CodenameJo

@MainActor
final class ActionHistoryOutcomeTests: XCTestCase {
    func testRefusalSurvivesDuplicateCallReplyCheckpointAndRestart() async throws {
        let service = RealtimeService(), client = FullDuplexVoiceClient()
        service.bindLiveHistory(client)
        client.handle(.liveUserActivity)
        client.handle(.liveInputText("Archive this email"))
        let pending = try XCTUnwrap(service.lastCompletedTurn)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let log = VoiceDiagnostics(directory: folder.appendingPathComponent("logs"))
        client.diagnostics = log.begin(engine: "live", userID: "fixture")
        let call = LiveSessionAdapter.Call(id: "attempt-1", name: "archive_message",
            arguments: #"{"account":"owner@example.test","message_id":"original"}"#, delegation: "d1")
        for _ in 0..<2 { client.refuseLiveFunction(call, reason: "target_mismatch", output: "Not executed.") }
        client.handle(.event(.assistantTranscriptDelta(itemId: "reply", delta: "I could not archive it.", spoken: true)))
        client.emitFinalTranscript()
        client.checkpointHistory()
        let refused = try XCTUnwrap(service.lastCompletedTurn)
        XCTAssertEqual(refused.status, .failed)
        XCTAssertEqual(refused.toolSteps?.count, 1)
        XCTAssertEqual(refused.toolSteps?.first?.outcome, "refused")
        XCTAssertEqual(refused.toolSteps?.first?.callID, "attempt-1")
        client.diagnostics?.record(.toolResultDelivered, ["call_id": "attempt-1", "outcome": "reported"])
        let context = LocalContextStore(url: folder.appendingPathComponent("db"))
        defer { try? context.dbPool?.close(); try? FileManager.default.removeItem(at: folder) }
        try await TurnStore(database: context.dbPool).save(.init(refused, userId: "fixture"))
        try await TurnStore(database: context.dbPool).save(.init(pending, userId: "fixture"))
        let rows = try await TurnStore(database: context.dbPool).history(owner: "fixture")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.status, .failed)
        XCTAssertEqual(rows.first?.toolSteps?.filter { $0.outcome == "refused" }.count, 1)
        let exported = String(decoding: try SessionExport.append(records: rows, jobs: [],
            to: try await log.snapshot(userID: "fixture"), includeContent: false), as: UTF8.self)
        XCTAssertEqual(exported.components(separatedBy: "\"event\":\"toolFinished\"").count - 1, 1)
        XCTAssertTrue(exported.contains("toolResultDelivered"))
        XCTAssertTrue(exported.contains("attempt-1"))
        XCTAssertFalse(exported.contains("owner@example.test"))
        XCTAssertFalse(exported.contains("Archive this email"))
    }

    func testGuardReasonsDistinguishMissingMalformedAndChangedSelections() {
        let step = #"{"done":false,"item":{"account":"owner@example.test","id":"a","threadId":"t"}}"#
        let conversation = UUID()
        var rendered = RenderedFeedState(profileID: "p", conversationID: conversation,
            focus: .init(account: "owner@example.test", messageID: "a"),
            queueCurrent: .init(account: "owner@example.test", messageID: "a"))
        func reason(_ source: String?, _ state: RenderedFeedState?, anchor: String = "p") -> String? {
            RenderedSelectionGuard.reason(step: source, rendered: state, profileID: "p",
                conversationID: conversation, anchorProfileID: anchor, hasAnchor: true)
        }
        XCTAssertNil(reason(step, rendered))
        XCTAssertEqual(reason(nil, rendered), "missing_voice_selection")
        XCTAssertEqual(reason("{}", rendered), "invalid_voice_selection_key")
        XCTAssertEqual(reason(step, nil), "missing_render")
        XCTAssertEqual(reason(step, rendered, anchor: "other"), "profile_changed")
        rendered.conversationID = UUID()
        XCTAssertEqual(reason(step, rendered), "conversation_changed")
        rendered.conversationID = conversation
        rendered.profileID = "other"
        XCTAssertEqual(reason(step, rendered), "render_profile_changed")
        rendered.profileID = "p"
        rendered.focus = .init(account: "owner@example.test", messageID: "b")
        XCTAssertEqual(reason(step, rendered), "target_mismatch")
        rendered.focus = nil
        XCTAssertEqual(reason(step, rendered), "missing_rendered_selection")
    }

    func testFeedbackFinalizesEveryFragmentAndLatePendingWritesCannotUndoIt() async throws {
        final class Feedback: UserFeedback {
            var notes: [(String, Submission)] = []
            let noteID = UUID()
            override func capture() -> Submission { .init(userID: "fixture", context: .init(profileID: "p")) }
            override func save(_ message: String, source: FeedbackSource, submission: Submission) async throws -> UUID {
                notes.append((message, submission)); return noteID
            }
        }
        let feedback = Feedback(), conversation = UUID()
        feedback.voiceSaveDelay = .milliseconds(80)
        var history = TurnHistory(), completed: [CommandRecord] = []
        let ids = (0..<4).map { _ in UUID() }
        let words = ["Log feedback", "The archive button", "is hard to find", "save it"]
        for (id, text) in zip(ids, words) {
            _ = history.checkpoint(id: id, text: text, conversationID: conversation, steps: [])
            XCTAssertTrue(feedback.voiceInput(text, turnID: id.uuidString, reply: { _ in }, transition: { _ in },
                settled: { turns, note, status in completed = history.feedbackSettled(ids: turns, feedbackID: note, status: status) }))
        }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(feedback.notes.count, 1)
        XCTAssertEqual(feedback.notes.first?.0, "The archive button\nis hard to find")
        XCTAssertEqual(Set(feedback.notes.first?.1.context.fragmentTurnIDs ?? []), Set(ids.map(\.uuidString)))
        XCTAssertEqual(completed.count, 4)
        XCTAssertTrue(completed.allSatisfy { $0.status == .success && $0.feedbackID == feedback.noteID })
        for (id, text) in zip(ids, words) {
            let stale = history.complete(.init(id: id, commandText: text, status: .pending, toolSteps: []))
            XCTAssertEqual(stale.status, .success)
            XCTAssertEqual(stale.feedbackID, feedback.noteID)
            XCTAssertEqual(stale.commandText, text)
        }
    }

    func testUnansweredInputEndsCancelledWithoutClaimingSuccess() {
        var history = TurnHistory()
        let id = UUID()
        _ = history.checkpoint(id: id, text: "I want to give feedback", conversationID: UUID(), steps: [])
        XCTAssertEqual(history.cancelUnanswered(id: id)?.status, .cancelled)
    }
}
