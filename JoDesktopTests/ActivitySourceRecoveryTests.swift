import XCTest
@testable import CodenameJo

@MainActor
final class ActivitySourceRecoveryTests: XCTestCase {
    let source = MailSelection(account: "work@example.test", messageID: "a")
    let conversation = UUID()
    func state(_ source: MailSelection, activity: UUID? = nil, transitioning: Bool = false) -> RenderedFeedState {
        .init(profileID: "work", conversationID: conversation, focus: source, queueCurrent: source,
              transitioning: transitioning, activityID: activity)
    }

    func testAdapterRestorationOnlyAllowsCurrentCallWithoutPendingWork() async throws {
        var finished = false
        let adapter = LiveSessionAdapter(wire: { _ in }, emit: { if case .liveInputFinished = $0 { finished = true } })
        defer { adapter.close() }
        func receive(_ event: [String: Any]) throws { adapter.receive(try JSONSerialization.data(withJSONObject: event)) }
        try receive(["type": "session.started"])
        try receive(["type": "session.input_transcript.delta", "delta": "Now that the reply is sent, archive that email", "start_ms": 100, "end_ms": 200])
        for _ in 0..<400 where !finished { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(finished)
        try receive(["type": "session.delegation.created", "offset_ms": 200, "delegation": ["id": "d", "response_id": "r"]])
        try receive(["type": "response.event", "event": ["type": "response.created", "response": ["id": "r"]]])
        func call(_ id: String) throws {
            try receive(["type": "response.event", "event": ["type": "response.output_item.done", "response_id": "r",
                "item": ["type": "function_call", "call_id": id, "name": "archive_message", "arguments": "{}"]]])
        }
        try call("archive")
        XCTAssertTrue(adapter.canRestoreReturnedWork("archive"))
        XCTAssertFalse(adapter.canRestoreReturnedWork("unrelated"))
        try call("pending")
        XCTAssertFalse(adapter.canRestoreReturnedWork("archive"))
        try receive(["type": "session.input_transcript.delta", "delta": "Actually stop", "start_ms": 4000, "end_ms": 4100])
        XCTAssertFalse(adapter.canRestoreReturnedWork("archive"))
    }

    func testActivityUsesRecordedTupleAndRejectsAmbiguousStaleAndUnavailableSources() {
        let id = UUID(), origin = DispatchJob.MailOrigin(account: source.account, messageID: "a", threadID: "thread-a", sender: "Same name", subject: "Same subject")
        var job = DispatchJob(id: id, task: "Reply", state: "done", result: "Sent", profileId: "work", origin: origin)
        func resolve(_ arguments: String = "{}", _ original: MailSelection? = nil, _ began: UUID? = id,
                     _ profile: String? = "work", _ accounts: [String] = ["work@example.test"]) -> DispatchJob.MailOrigin? {
            ActivitySourceRecovery.source(job: job, arguments: arguments, original: original,
                beganOnActivity: began, selectedActivity: id, profile: profile, accounts: accounts)
        }
        XCTAssertEqual(resolve(), origin)
        XCTAssertEqual(resolve("{}", source, nil), origin, "The activity may appear after speech began on this source")
        XCTAssertNil(resolve("{}", .init(account: source.account, messageID: "b"), nil))
        for arguments in [#"{"account":"other@example.test"}"#, #"{"message_id":"b"}"#,
                          #"{"thread_id":"thread-b"}"#, #"{"message_ids":["a","b"]}"#] {
            XCTAssertNil(resolve(arguments))
        }
        XCTAssertNil(resolve("{}", nil, id, "personal"))
        XCTAssertNil(resolve("{}", nil, id, "work", []))
        job.state = "running"; XCTAssertNil(resolve())
        job.state = "done"; job.origin = nil; XCTAssertNil(resolve())
    }

    func testReadAndRenderedRestorePrecedeExactlyOneWrite() async {
        let recovery = ActivitySourceRecovery(), activity = UUID()
        var events: [String] = [], polls = 0
        var rendered = state(source, activity: activity)
        let result = await recovery.run(callID: "archive", source: source, profile: "work", conversation: conversation,
            current: { true }, validate: { events.append("read") }, restore: {
                events.append("restore"); rendered = self.state(self.source, transitioning: true); return nil
            }, rendered: {
                polls += 1
                if polls == 2 { rendered = self.state(self.source) }
                return rendered
            }, perform: { events.append("archive") }, attempts: 3)
        XCTAssertNil(result)
        XCTAssertEqual(events, ["read", "restore", "archive"])
        let duplicate = await recovery.run(callID: "archive", source: source, profile: "work", conversation: conversation,
            current: { true }, validate: { XCTFail("Duplicate read") }, restore: { XCTFail("Duplicate restore"); return nil },
            rendered: { rendered }, perform: { XCTFail("Duplicate write") })
        XCTAssertNotNil(duplicate)
    }

    func testSelectionProfileConversationAndPendingWorkChangesNeverWrite() async {
        for point in 0..<6 {
            let recovery = ActivitySourceRecovery()
            var current = point != 0
            var rendered = state(source)
            let result = await recovery.run(callID: "call", source: source, profile: "work", conversation: conversation,
                current: { current }, validate: { if point == 1 { current = false } }, restore: {
                    if point == 2 { current = false }
                    if point == 3 { rendered.profileID = "other" }
                    if point == 4 { rendered.conversationID = UUID() }
                    if point == 5 { rendered = self.state(.init(account: self.source.account, messageID: "b")) }
                    return nil
                }, rendered: { rendered }, perform: { XCTFail("Changed context executed") }, attempts: 1)
            XCTAssertNotNil(result)
        }
    }

    func testDeletedSourceAndUnrenderedActivityGiveActionableRecoveryWithoutWrite() async {
        enum Missing: Error { case message }
        for missing in [true, false] {
            let result = await ActivitySourceRecovery().run(callID: "call", source: source, profile: "work", conversation: conversation,
                current: { true }, validate: { if missing { throw Missing.message } }, restore: { return nil },
                rendered: { self.state(self.source, activity: UUID()) }, perform: { XCTFail("Unavailable source executed") }, attempts: 1)
            XCTAssertNotNil(result)
            XCTAssertTrue(result?.contains(missing ? "unavailable" : "Work on this email") == true)
        }
    }
}
