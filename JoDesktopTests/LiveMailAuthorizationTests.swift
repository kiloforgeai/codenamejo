import XCTest
@testable import CodenameJo

@MainActor
final class LiveMailAuthorizationTests: XCTestCase {
    @MainActor private final class Harness {
        var wire: [[String: Any]] = []
        var calls: [LiveSessionAdapter.Call] = []
        var finished = false
        var state = #"{"done":false,"item":{"id":"email-b","threadId":"thread-b","account":"owner@example.test"}}"#
        var scope: String? = "profile-a"
        lazy var adapter: LiveSessionAdapter = LiveSessionAdapter(wire: { [weak self] in self?.wire.append($0) }, emit: { [weak self] signal in
            guard let self else { return }
            if case .liveInputFinished = signal { finished = true }
            if case .liveFunction(let call) = signal {
                XCTAssertNil(adapter.mailRequestRefusal(for: call), "Executor must revalidate the same grant")
                calls.append(call)
            }
        })
        func receive(_ event: [String: Any]) throws { adapter.receive(try JSONSerialization.data(withJSONObject: event)) }
        func input(_ text: String, at time: Double = 100) throws {
            finished = false
            try receive(["type": "session.input_transcript.delta", "delta": text, "start_ms": time, "end_ms": time + 100])
        }
        func settle() async throws {
            for _ in 0..<400 where !finished { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(finished)
        }
        func start(_ text: String, afterButton: Bool = false) async throws {
            adapter.silentInputRecoveryDelay = 60
            adapter.clientBrainState = { [weak self] in (self?.state ?? "{}", self?.scope) }
            try receive(["type": "session.started"])
            if afterButton {
                XCTAssertTrue(adapter.beginButtonAction(callId: "previous", action: .archive))
                adapter.outbound(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": "previous", "output": "Archived email A."]])
            }
            try input(text); try await settle()
            try receive(["type": "session.delegation.created", "offset_ms": 200, "delegation": ["id": "d1", "response_id": "r1"]])
            try receive(["type": "response.event", "event": ["type": "response.created", "response": ["id": "r1"]]])
        }
        func call(_ name: String, id: String) throws {
            try receive(["type": "response.event", "event": ["type": "response.output_item.done", "response_id": "r1",
                "item": ["type": "function_call", "call_id": id, "name": name,
                         "arguments": #"{"account":"owner@example.test","message_id":"email-b"}"#]]])
        }
        func result(_ id: String) {
            adapter.outbound(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": id, "output": "Confirmed."]])
        }
    }

    func testDictatedNegationDoesNotCancelReplyOrAuthorizeBodyInstructions() {
        let operations = LiveMailAuthorization("Reply saying please do not cancel the meeting, and archive the attached copy when done.").operations
        XCTAssertEqual(operations, [.send, .draft])
        XCTAssertEqual(LiveMailAuthorization.proposedOperations("Would you like me to archive this email?"), [.archive])
        XCTAssertTrue(LiveMailAuthorization.proposedOperations("Should I archive or delete it?").isEmpty)
        XCTAssertTrue(LiveMailAuthorization("Do not reply saying yes").operations.isEmpty)
        XCTAssertTrue(LiveMailAuthorization("Actually don't send that email").operations.isEmpty)
    }

    func testCalendarQuestionAfterArchiveButtonCannotMutateOrAdvance() async throws {
        let h = Harness(); defer { h.adapter.close() }
        try await h.start("Which proposed meeting times work with my calendar?", afterButton: true)
        for (index, tool) in ["archive_message", "trash_message", "delete_message", "mark_spam", "send_email", "forward_email", "create_draft", "triage_next"].enumerated() {
            try h.call(tool, id: "refused-\(index)")
        }
        XCTAssertTrue(h.calls.isEmpty, "Zero provider mutations or feed advances")
        try h.call("list_calendar_events", id: "calendar")
        XCTAssertEqual(h.calls.map(\.name), ["list_calendar_events"])
    }

    func testNonverbalAndUnfinishedInputCannotReuseAnEarlierArchive() async throws {
        for text in ["[sniffing]", "[breathing]", "Please reply to", "Uh"] {
            let h = Harness(); defer { h.adapter.close() }
            try await h.start(text, afterButton: true)
            h.adapter.silentInputRecoveryDelay = 0.01
            try await Task.sleep(for: .milliseconds(80))
            for (index, tool) in ["archive_message", "trash_message", "send_email", "triage_next"].enumerated() {
                try h.call(tool, id: "delayed-\(index)")
            }
            XCTAssertTrue(h.calls.isEmpty, "Incidental or incomplete input must not reach the executor: \(text)")
        }
    }

    func testExplicitCombinedRequestAllowsReadAndExactlyOneArchive() async throws {
        let h = Harness(); defer { h.adapter.close() }
        try await h.start("Check availability, then archive this email")
        try h.call("list_calendar_events", id: "calendar"); h.result("calendar")
        try h.call("archive_message", id: "archive"); h.result("archive")
        try h.call("archive_message", id: "duplicate")
        try h.call("trash_message", id: "not-requested")
        XCTAssertEqual(h.calls.map(\.name), ["list_calendar_events", "archive_message"])
    }

    func testDelayedOutputCannotFollowSelectionOrProfileOrNewRequest() async throws {
        for change in ["selection", "profile", "request"] {
            let h = Harness(); defer { h.adapter.close() }
            try await h.start("Archive this email")
            switch change {
            case "selection": h.state = h.state.replacingOccurrences(of: "email-b", with: "email-c")
            case "profile": h.scope = "profile-b"
            default: try h.input("What does this email mean?", at: 4_000); try await h.settle()
            }
            try h.call("archive_message", id: "late")
            XCTAssertTrue(h.calls.isEmpty, change)
        }
    }

    func testQuestionsNegationsCorrectionsAndDictationDoNotGrantUnrequestedActions() {
        for text in ["Why did you archive this?", "Should I archive and send a reply?", "Don't archive this", "Actually keep it instead", "Find the archived email", "Send me a summary of the meeting times"] {
            XCTAssertTrue(LiveMailAuthorization(text).operations.isEmpty, text)
        }
        let reply = LiveMailAuthorization("Reply saying please archive this email and delete the old one")
        XCTAssertEqual(reply.operations, [.send, .draft])
        XCTAssertEqual(LiveMailAuthorization("Draft a reply").operations, [.draft])
        XCTAssertEqual(LiveMailAuthorization("Can you archive this email?").operations, [.archive])
        XCTAssertEqual(LiveMailAuthorization("Now that the reply is sent, archive that email").operations, [.archive])
    }
}
