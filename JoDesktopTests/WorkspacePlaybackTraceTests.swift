import XCTest
@testable import CodenameJo

@MainActor
final class WorkspacePlaybackTraceTests: XCTestCase {
    private func rows(_ log: VoiceDiagnostics) async throws -> [[String: Any]] {
        try String(decoding: await log.snapshot(), as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
    func testPlaybackKeepsTranscriptOriginWhenForegroundMovesAndJoinsRenderedResponse() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = VoiceDiagnostics(directory: folder)
        let trace = log.begin(engine: "live")
        let client = FullDuplexVoiceClient()
        client.diagnostics = trace
        let a = MailSelection(account: "private@example.test", messageID: "A")
        let b = MailSelection(account: "private@example.test", messageID: "B")
        client.standingStep = GmailReadTools.json(["done": false, "item": ["id": "A", "account": a.account, "threadId": "thread-A"]])
        client.liveQueueRevision = 1
        let adapter = LiveSessionAdapter(wire: { _ in }, emit: { client.handle($0) })
        adapter.onPlaybackBoundary = { client.recordPlaybackBoundary(id: $0, item: $1, phase: $2) }
        adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.output_transcript.delta",
            "delta": "Private fixture response", "start_ms": 0, "end_ms": 100]))
        let itemID = try XCTUnwrap(client.currentAssistantItem)
        client.standingStep = GmailReadTools.json(["done": false, "item": ["id": "B", "account": b.account, "threadId": "thread-B"]])
        client.liveQueueRevision = 2
        adapter.observePlayback(0.1)
        adapter.observePlayback(0.1)
        var rendered = RenderedFeedState(profileID: nil, conversationID: nil, focus: b, queueCurrent: b,
            queueOrder: [b.canonical], queueRevision: 2, response: "Private fixture response", previousResponse: true)
        rendered.responseItemID = itemID
        rendered.responseTurnID = client.currentAssistantTurnID
        trace.record(.workspaceRendered, rendered.diagnosticFields(session: trace, revision: 5))
        adapter.close()
        let events = try await rows(log)
        let playback = events.filter { $0["event"] as? String == "playbackBoundary" }.compactMap { $0["fields"] as? [String: String] }
        XCTAssertEqual(playback.map { $0["phase"] }, ["started", "closed"])
        XCTAssertEqual(Set(playback.compactMap { $0["playback_id"] }).count, 1)
        XCTAssertTrue(playback.allSatisfy { $0["response_item_id"] == itemID && $0["target_hash"] == trace.target(a.canonical) && $0["queue_revision"] == "1" })
        let ui = try XCTUnwrap(events.first { $0["event"] as? String == "workspaceRendered" }?["fields"] as? [String: String])
        XCTAssertEqual(ui["response_item_id"], itemID)
        XCTAssertEqual(ui["target_hash"], trace.target(b.canonical))
        XCTAssertEqual(ui["response_role"], "previous")
        let text = String(decoding: try await log.snapshot(), as: UTF8.self)
        XCTAssertFalse(text.contains("private@example.test"))
        XCTAssertFalse(text.contains("Private fixture response"))
    }

    func testAudioBeforeTranscriptHasUnknownAttributionInsteadOfBorrowingAnEarlierItem() async throws {
        var boundaries: [(String, String?, String)] = []
        let adapter = LiveSessionAdapter(wire: { _ in }, emit: { _ in })
        adapter.onPlaybackBoundary = { boundaries.append(($0, $1, $2)) }
        adapter.observePlayback(0.1)
        adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.output_transcript.delta",
            "delta": "Late caption", "start_ms": 0, "end_ms": 100]))
        adapter.close()
        XCTAssertEqual(boundaries.count, 2)
        XCTAssertTrue(boundaries.allSatisfy { $0.1 == nil })
        XCTAssertEqual(boundaries.first?.0, boundaries.last?.0)
    }

    func testEachRenderedSnapshotIsSelfContainedAndMissingFocusIsAMismatch() {
        let log = VoiceDiagnostics()
        let session = log.begin(engine: "trace_test")
        let selected = MailSelection(account: "fixture@example.test", messageID: "B")
        var state = RenderedFeedState(profileID: nil, conversationID: nil, focus: nil, queueCurrent: selected,
            queueOrder: [selected.canonical], queueRevision: 7)
        state.position = 2; state.total = 12
        state.jobStates = [UUID().uuidString + ":done"]
        let first = VoiceDiagnostics.safeFields(state.diagnosticFields(session: session, revision: 10))
        state.response = "New response"
        let next = VoiceDiagnostics.safeFields(state.diagnosticFields(session: session, revision: 11))
        XCTAssertEqual(first["queue_order"], next["queue_order"])
        XCTAssertEqual(next["mismatch"], "true")
        XCTAssertEqual(next["selection_state"], "transitioning")
        XCTAssertEqual(next["response_item_id"], "unknown")
        XCTAssertEqual(next["displayed_position"], "2")
        XCTAssertEqual(next["displayed_total"], "12")
        XCTAssertEqual(next["job_states"], state.jobStates.first)
    }
}
