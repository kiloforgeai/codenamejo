import XCTest
@testable import CodenameJo

@MainActor
final class UnsupportedPresentationReplayTests: XCTestCase {
    @MainActor private final class Harness {
        var requests: [[String: Any]] = []
        var replies: [CheckedContinuation<[String: Any], Error>] = []
        var spoken: [String] = []
        var reasons: [String] = []
        var events: [[String: Any]] = []
        lazy var brain = LiveClientBrain(request: { [unowned self] body in
            requests.append(body)
            return try await withCheckedThrowingContinuation { replies.append($0) }
        }, deliver: { [unowned self] in events.append($0) },
        speak: { [unowned self] text, _ in spoken.append(text) },
        failed: { XCTFail($0) })

        func start(_ text: String, turn: Int) {
            brain.user(text, turn: turn)
            brain.begin("request-" + String(turn), live: true, turn: turn)
            brain.settle(turn: turn)
        }
        func waitForRequest() async throws {
            for _ in 0..<2000 {
                if !replies.isEmpty { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTFail("Expected model request")
        }
        func answer(_ text: String) async {
            replies.removeFirst().resume(returning: ["output": [
                ["type": "message", "content": [["type": "output_text", "text": text]]]]])
            for _ in 0..<40 { await Task.yield() }
        }
        func call(_ name: String, id: String) async {
            replies.removeFirst().resume(returning: ["output": [
                ["type": "function_call", "name": name, "call_id": id, "arguments": "{}"]]])
            for _ in 0..<40 { await Task.yield() }
        }
        func context() throws -> [String: Any] {
            let raw = try XCTUnwrap(requests.last?["context"] as? String)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        }
    }

    private let invented = "Up next is an Atlassian Jira email about a comment waiting for review. What would you like to do with it?"

    func testFactualCorrectionRejectsInflightInterpretationAndClearsOldPresentationContext() async throws {
        let h = Harness()
        let source = selected("same-source")
        h.brain.updateState(source, scope: "fixture")
        h.brain.observe("Stale interpretation: ordered the newsletter")
        h.start("Summarize this email", turn: 1)
        try await h.waitForRequest()
        var cache = LiveEmailPreparationCache(profileId: "fixture")
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(source))
        cache.correct(key, text: "It was a book, not the newsletter")
        h.brain.updateState(cache.annotatingCorrection(source), scope: "fixture")
        h.brain.correctEmailInterpretation()
        await h.answer("Sender ordered the newsletter.")
        XCTAssertTrue(h.spoken.isEmpty, "The in-flight obsolete answer must never reach the speaker")
        try await h.waitForRequest()
        let context = try h.context()
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: context), as: UTF8.self)
        XCTAssertTrue(encoded.contains("a book, not the newsletter"))
        XCTAssertFalse(encoded.contains("Stale interpretation"))
        await h.answer("You clarified that Sender ordered a book.")
        XCTAssertEqual(h.spoken, ["You clarified that Sender ordered a book."])
        h.brain.close()
    }

    private func selected(_ id: String) -> String {
        GmailReadTools.json(["done": false, "item": ["account": "fixture@example.test",
            "id": id, "threadId": "thread-" + id, "from": "Same Sender", "subject": "Same Subject"]])
    }

    func testEmptySelectionNegativeSearchAndFeedbackCannotReviveInventedEmail() async throws {
        let h = Harness()
        h.brain.onPresentationInvalidated = { reason, _ in h.reasons.append(reason) }
        h.brain.updateState("No email selected.", scope: "fixture")
        h.brain.jobCompleted(id: UUID(), result: "Delayed research about an earlier email; no selection")
        h.start("What is next?", turn: 1)
        try await h.waitForRequest()
        await h.answer(invented)
        XCTAssertEqual(h.spoken, [LiveSelectionGrounding.correction])
        h.brain.assistant(invented)
        h.start("Which issue is that?", turn: 2)
        try await h.waitForRequest()
        XCTAssertEqual(try h.context()["pendingQuestion"] as? String, "")
        await h.call("gmail_search_messages", id: "lookup")
        h.brain.item(["type": "function_call_output", "call_id": "lookup", "output": #"{"messages":[]}"#])
        h.brain.continueResponse(delegation: "request-2")
        try await h.waitForRequest()
        XCTAssertTrue(h.reasons.contains("negative_verification"))
        await h.answer("I cannot find that email.")
        h.brain.assistant("Would you like to act on that Jira email?")
        h.start("Save feedback: that email does not exist.", turn: 3)
        try await h.waitForRequest()
        XCTAssertEqual(try h.context()["pendingQuestion"] as? String, "")
        XCTAssertEqual(try h.context()["selectionStatus"] as? String, "none")
        await h.call("log_feedback", id: "feedback")
        h.brain.item(["type": "function_call_output", "call_id": "feedback", "output": #"{"saved":true}"#])
        h.brain.continueResponse(delegation: "request-3")
        try await h.waitForRequest()
        await h.answer("Feedback saved. " + invented)
        XCTAssertEqual(h.spoken.last, LiveSelectionGrounding.noSelection)
        XCTAssertFalse(h.spoken.contains { $0.contains("Jira") })
        let functions = h.events.compactMap { $0["event"] as? [String: Any] }
            .compactMap { $0["item"] as? [String: Any] }
            .compactMap { $0["name"] as? String }
        XCTAssertEqual(functions, ["gmail_search_messages", "log_feedback"], "No mailbox write or queue advance")
        h.brain.close()
    }

    func testSameSubjectSelectionChangeInvalidatesOldQuestionButReturnedSourceCanBePresented() async throws {
        let h = Harness()
        h.brain.updateState(selected("A"), scope: "fixture")
        h.brain.assistant("Would you like to archive this email?")
        h.brain.updateState(selected("B"), scope: "fixture")
        h.start("Yes", turn: 1)
        try await h.waitForRequest()
        XCTAssertEqual(try h.context()["pendingQuestion"] as? String, "")
        await h.answer("Which action do you want for the selected email?")
        // A returned result becomes legitimate only after the application selects its immutable source.
        h.brain.updateState(selected("R"), scope: "fixture")
        h.start("What email is selected?", turn: 2)
        try await h.waitForRequest()
        await h.answer("The current email is from Same Sender, with subject Same Subject.")
        XCTAssertEqual(h.spoken.last, "The current email is from Same Sender, with subject Same Subject.")
        h.brain.close()
    }

    func testStreamingUnsupportedIntroductionIsInvalidatedOnceWithoutDiscardingHeardTranscript() throws {
        var wire: [[String: Any]] = []
        var heard = ""
        let adapter = LiveSessionAdapter(wire: { wire.append($0) }, emit: {
            if case .event(.assistantTranscriptDelta(_, let delta, _)) = $0 { heard += delta }
        })
        adapter.clientBrainState = { ("No email selected.", "fixture") }
        adapter.enableClientDelegation { _ in XCTFail("Speech must not trigger a write"); return ["output": []] }
        defer { adapter.close() }
        adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.started"]))
        for fragment in ["Up next ", "is an Atlassian Jira email.", " What should I do with it?"] {
            adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.output_transcript.delta",
                "delta": fragment, "start_ms": 100, "end_ms": 200]))
        }
        XCTAssertEqual(heard, "Up next is an Atlassian Jira email. What should I do with it?")
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: wire), as: UTF8.self)
        XCTAssertTrue(raw.contains("Stop the unsupported email introduction"))
        XCTAssertEqual(raw.components(separatedBy: "Stop the unsupported email introduction").count - 1, 1)
    }

    func testNoSelectionDoesNotBlockGeneralAnswersOrTreatPartialSearchAsProofOfAbsence() {
        XCTAssertFalse(LiveSelectionGrounding.unsupportedIntroduction("I cannot find that email.", state: "No email selected."))
        XCTAssertFalse(LiveSelectionGrounding.unsupportedIntroduction("The weather is sunny.", state: "No email selected."))
        XCTAssertFalse(LiveSelectionGrounding.emptySearch(#"{"messages":[],"nextPageToken":"more"}"#))
        XCTAssertFalse(LiveSelectionGrounding.emptySearch(#"{"messages":[{"id":"A"}],"matches":[]}"#))
        XCTAssertTrue(LiveSelectionGrounding.emptySearch(#"{"messages":[]}"#))
    }
}
