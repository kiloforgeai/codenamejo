import XCTest
@testable import CodenameJo

@MainActor
final class ArchiveIntentReplayTests: XCTestCase {
    private func receive(_ adapter: LiveSessionAdapter, _ event: [String: Any]) throws {
        adapter.receive(try JSONSerialization.data(withJSONObject: event))
    }
    private func input(_ adapter: LiveSessionAdapter, _ text: String, at start: Double) throws {
        try receive(adapter, ["type": "session.input_transcript.delta", "delta": text, "start_ms": start, "end_ms": start + 100])
    }

    func testEachExplicitArchiveGetsOneLocalActionAndAReceiptCannotAuthorizeTheNextOne() async throws {
        var wire: [[String: Any]] = []
        let adapter = LiveSessionAdapter(wire: { wire.append($0) }, emit: { _ in })
        adapter.enableClientDelegation { _ in
            XCTFail("Already-presented local archives must not need a model request")
            return ["output": []]
        }
        defer { adapter.close() }
        try receive(adapter, ["type": "session.started"])
        for (index, command) in ["Just archive this", "Archive that", "Archive it now"].enumerated() {
            let id = "archive-\(index)"
            try input(adapter, command, at: Double(index * 3_000 + 100))
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertTrue(adapter.beginFastAction(callId: id, action: .archive), command)
            XCTAssertFalse(adapter.beginFastAction(callId: "duplicate", action: .archive))
            adapter.outbound(["type": "conversation.item.create", "item": ["type": "function_call_output",
                "call_id": id, "output": "Archived the original target. The application is presenting the next item."]])
            // No model result is needed to authorize the next explicit command.
        }
        XCTAssertTrue(LiveSessionSetup.fastActionNames.contains("archive_message"))
        XCTAssertEqual(DispatchMailOperation.archiveRequest("Just archive this now", account: "work@example.test", messageID: "F")?.messageID, "F")
    }

    func testPausedNegationConditionalAndReminderCannotBecomeArchiveAuthorization() async throws {
        for prefix in ["Don't", "If I agree later", "Remind me to"] {
            var inputs: [String] = []
            let adapter = LiveSessionAdapter(wire: { _ in }, emit: {
                if case .liveInputFinished(let text) = $0 { inputs.append(text) }
            })
            try receive(adapter, ["type": "session.started"])
            try input(adapter, prefix, at: 100)
            try await Task.sleep(for: .milliseconds(1100))
            try receive(adapter, ["type": "session.output_transcript.delta", "delta": "I'm listening.", "start_ms": 300, "end_ms": 400])
            try input(adapter, "archive it", at: 2_000)
            try await Task.sleep(for: .milliseconds(1100))
            XCTAssertFalse(adapter.beginFastAction(callId: "must-not-run", action: .archive), prefix)
            XCTAssertEqual(inputs.last, prefix + " archive it")
            adapter.close()
        }
    }

    func testBackchannelKeepsRequestAuthorizationButNewIntentGetsItsOwnTurn() async throws {
        var inputs: [String] = []
        let adapter = LiveSessionAdapter(wire: { _ in }, emit: {
            if case .liveInputFinished(let text) = $0 { inputs.append(text) }
        })
        defer { adapter.close() }
        try receive(adapter, ["type": "session.started"])
        try input(adapter, "Archive that", at: 100)
        try await Task.sleep(for: .milliseconds(600))
        try input(adapter, "mm-hmm", at: 2_000)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertTrue(adapter.beginFastAction(callId: "original", action: .archive))
        adapter.outbound(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": "original", "output": "Archived."]])
        try input(adapter, "What time is it?", at: 4_000)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(inputs.last, "What time is it?")
        XCTAssertFalse(adapter.beginFastAction(callId: "unrequested", action: .archive))
    }

    func testRepeatedSettlingDoesNotRestartRecoveryDeadline() {
        var recovery = LiveQueueActionRecovery(now: 0)
        XCTAssertEqual(recovery.poll(now: 1.5), .retry)
        // Eight backchannels/settles keep the same unresolved intent and its original deadline.
        for tick in [2.0, 2.539, 3, 3.5, 4, 4.5, 5, 6] { XCTAssertNil(recovery.poll(now: tick)) }
        XCTAssertEqual(recovery.poll(now: 6.5), .failed)
        XCTAssertTrue(recovery.finished)
        XCTAssertNil(recovery.poll(now: 10))
        var committed = LiveQueueActionRecovery(now: 0)
        committed.started()
        XCTAssertNil(committed.poll(now: 10), "Committed work must never be retried")
    }
}
