import Foundation
import XCTest
@testable import CodenameJo

@MainActor
final class SelectedEmailInquiryTests: XCTestCase {
    private var previousHeaders: Any?
    private static let account = "source@example.test"
    private static let answer = "Under condition X, the sender says people generally prefer B because it is simpler."

    override func setUp() async throws {
        previousHeaders = UserDefaults.standard.object(forKey: MailHeadersOnly.storageKey)
        UserDefaults.standard.set(false, forKey: MailHeadersOnly.storageKey)
        ProfileRuntime.install(nil)
    }

    override func tearDown() async throws {
        if let previousHeaders { UserDefaults.standard.set(previousHeaders, forKey: MailHeadersOnly.storageKey) }
        else { UserDefaults.standard.removeObject(forKey: MailHeadersOnly.storageKey) }
        ProfileRuntime.install(nil)
    }

    private static func state(id: String = "Q", body: String? = nil, complete: Bool = false) -> String {
        var item: [String: Any] = ["id": id, "threadId": "thread-" + id, "account": account,
                                  "bodySummary": "Choose A or B."]
        if let body { item["emailContent"] = ["messages": [["id": id, "threadId": "thread-" + id,
            "text": body, "textComplete": complete, "fullReadComplete": complete, "from": "Sender", "date": "Today"]]] }
        return GmailReadTools.json(["done": false, "item": item])
    }

    private static func result(body: String, id: String = "Q", account: String = "source@example.test", complete: Bool = true) -> String {
        GmailReadTools.json([["account": account, "result": ["id": id, "threadId": "thread-" + id,
            "from": "Sender", "body": body, "bodyComplete": complete]]])
    }

    @MainActor private final class Harness {
        var requests: [[String: Any]] = []
        var calls: [[String: Any]] = []
        var speech: [String] = []
        var failures: [String] = []
        var holdAnswer = false
        var answerContinuation: CheckedContinuation<[String: Any], Never>?
        lazy var brain = LiveClientBrain(request: { [unowned self] body in
            requests.append(body)
            if holdAnswer { return await withCheckedContinuation { answerContinuation = $0 } }
            return ["output": [["type": "message", "content": [["text": SelectedEmailInquiryTests.answer]]]]]
        }, deliver: { [unowned self] event in
            if let event = event["event"] as? [String: Any], let item = event["item"] as? [String: Any],
               item["type"] as? String == "function_call" { calls.append(item) }
        }, speak: { [unowned self] text, _ in speech.append(text) }, failed: { [unowned self] in failures.append($0) })
        func start(_ state: String) {
            brain.updateState(state, scope: "source-profile")
            brain.user("What does the sender recommend?", turn: 1)
            brain.begin("source", live: true, turn: 1)
            brain.settle(turn: 1)
        }
        func supply(_ output: String) {
            brain.item(["type": "function_call_output", "call_id": calls.last!["call_id"]!, "output": output])
            brain.continueResponse(delegation: "source")
        }
    }

    private func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected asynchronous source transition", file: file, line: line)
    }

    func testOriginalIsReadBeforeFirstAnswerAndLateQualificationReachesTheModel() async throws {
        let h = Harness(); defer { h.brain.close() }
        h.start(Self.state(body: "Choose A or B.", complete: false))
        try await wait { h.calls.count == 1 }
        XCTAssertTrue(h.requests.isEmpty)
        XCTAssertTrue(h.speech.isEmpty)
        XCTAssertEqual(h.calls.first?["name"] as? String, GmailReadTools.getMessage)
        let args = ToolArguments(h.calls.first?["arguments"] as? String ?? "")
        XCTAssertEqual(args.string("message_id"), "Q")
        XCTAssertEqual(args.string("account"), Self.account)
        let full = String(repeating: "Earlier quoted discussion. ", count: 1800) + Self.answer
        h.supply(Self.result(body: full))
        try await wait { h.speech.count == 1 }
        let context = try XCTUnwrap(h.requests.first?["context"] as? String)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: Any])
        let evidence = try XCTUnwrap(fields["selectedEmailEvidence"] as? [String: Any])
        XCTAssertEqual(evidence["complete"] as? Bool, true)
        XCTAssertTrue(context.contains(Self.answer))
        XCTAssertTrue(context.contains("Preserve qualifications"))
        XCTAssertEqual((evidence["messages"] as? [[String: Any]])?.first?["body"] as? String, full)
        XCTAssertNoThrow(try LiveOpenAI.boundedInput(h.requests[0]))
        XCTAssertEqual(h.speech, [Self.answer])
        XCTAssertTrue(h.brain.holdsFeedDecision)
        XCTAssertEqual(h.calls.count, 1, "Source inquiry must not write or advance")
    }

    func testCompleteNeutralCacheDoesNotNeedAnotherRead() async throws {
        let h = Harness(); defer { h.brain.close() }
        h.start(Self.state(body: "A and B have different benefits. I have no preference.", complete: true))
        try await wait { h.requests.count == 1 }
        XCTAssertTrue(h.calls.isEmpty)
        XCTAssertTrue((h.requests[0]["context"] as? String)?.contains("I have no preference") == true)
        XCTAssertTrue((h.requests[0]["context"] as? String)?.contains("complete_selected_email_cache") == true)
    }

    func testPreviewCompletenessDoesNotProveTheOriginalMIMEBodyWasComplete() async throws {
        let h = Harness(); defer { h.brain.close() }
        let state = Self.state(body: "A visible portion.", complete: true)
            .replacingOccurrences(of: #""fullReadComplete":true"#, with: #""fullReadComplete":false"#)
        h.start(state)
        try await wait { h.calls.count == 1 }
        XCTAssertTrue(h.requests.isEmpty)
        h.supply(Self.result(body: Self.answer))
        try await wait { h.speech.count == 1 }
        XCTAssertTrue((h.requests[0]["context"] as? String)?.contains(Self.answer) == true)
    }

    func testReadFailurePartialBodyAndWrongIdentityCannotBecomeANegativeAnswer() async throws {
        for output in ["Network unavailable", Self.result(body: Self.answer, complete: false),
                       Self.result(body: Self.answer, id: "other"), Self.result(body: Self.answer, account: "other@example.test")] {
            let h = Harness()
            h.start(Self.state())
            try await wait { h.calls.count == 1 }
            h.supply(output)
            try await wait { !h.failures.isEmpty }
            XCTAssertTrue(h.requests.isEmpty)
            XCTAssertTrue(h.speech.last?.contains("can't verify") == true)
            XCTAssertEqual(h.calls.count, 1)
            h.brain.close()
        }
    }

    func testHeadersOnlyAndOversizedSourceExplainLimitsWithoutGuessing() async throws {
        for headers in [true, false] {
            UserDefaults.standard.set(headers, forKey: MailHeadersOnly.storageKey)
            let h = Harness()
            h.start(Self.state(body: String(repeating: "Large source. ", count: 10000), complete: true))
            if !headers {
                try await wait { h.calls.count == 1 }
                h.supply(Self.result(body: String(repeating: "Large source. ", count: 10000)))
            }
            try await wait { !h.failures.isEmpty }
            XCTAssertTrue(h.requests.isEmpty)
            XCTAssertFalse(h.speech.isEmpty)
            h.brain.close()
        }
    }

    func testChangingSelectionOrProfileDropsLateSourceAndInterruptedReadCannotAnswer() async throws {
        for change in ["selection", "profile", "close"] {
            let h = Harness()
            h.start(Self.state())
            try await wait { h.calls.count == 1 }
            if change == "selection" { h.brain.updateState(Self.state(id: "R"), scope: "source-profile") }
            else if change == "profile" { h.brain.updateState(Self.state(), scope: "other-profile") }
            else { h.brain.close() }
            h.supply(Self.result(body: Self.answer))
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(h.requests.isEmpty)
            XCTAssertFalse(h.speech.contains(Self.answer))
            h.brain.close()
        }
    }

    func testSelectedHTMLReadRetainsLaterEvidenceAndOrdinaryReadsStayBounded() throws {
        let html = "<table><tr><td>Condition X</td><td>Prefer B because it is simpler</td></tr></table>"
        let body = String(repeating: "Earlier discussion. ", count: 1500) + html
        let data = try JSONSerialization.data(withJSONObject: ["id": "Q", "threadId": "thread-Q", "labelIds": [],
            "payload": ["mimeType": "text/html", "body": ["data": Data(body.utf8).base64EncodedString(), "size": body.utf8.count]]])
        let message = try JSONDecoder().decode(GmailAPI.FullMessage.self, from: data)
        let envelope = GmailReadTools.envelope(message, completeSelectedSource: true)
        XCTAssertEqual(envelope["bodyComplete"] as? Bool, true)
        XCTAssertTrue((envelope["body"] as? String)?.contains("Prefer B") == true)
        let ordinary = GmailReadTools.envelope(message)
        XCTAssertEqual(ordinary["bodyComplete"] as? Bool, false)
        XCTAssertFalse((ordinary["body"] as? String)?.contains("Prefer B") == true)
        let unavailable = GmailAPI.FullPart(mimeType: "text/plain", filename: nil, headers: nil,
            body: .init(size: 100, data: nil, attachmentId: "unloaded-body"), parts: nil)
        XCTAssertFalse(MailBodyText.isComplete(unavailable))
    }

    func testLateGeneratedAnswerCannotDescribeANewSelection() async throws {
        let h = Harness(); defer { h.brain.close() }
        h.holdAnswer = true
        h.start(Self.state(body: Self.answer, complete: true))
        try await wait { h.answerContinuation != nil }
        h.brain.updateState(Self.state(id: "R"), scope: "source-profile")
        h.answerContinuation?.resume(returning: ["output": [["type": "message", "content": [["text": Self.answer]]]]])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(h.speech.isEmpty)
        XCTAssertEqual(h.requests.count, 1)
    }

    func testLiveRoutesTheQuestionWithoutWaitingForModelDelegation() async throws {
        var sent: [[String: Any]] = []
        var calls: [LiveSessionAdapter.Call] = []
        var requests: [[String: Any]] = []
        let adapter = LiveSessionAdapter(wire: { sent.append($0) }, emit: {
            if case .liveFunction(let call) = $0 { calls.append(call) }
        })
        defer { adapter.close() }
        adapter.clientBrainState = { (Self.state(), "source-profile") }
        adapter.enableClientDelegation { body in
            requests.append(body)
            return ["output": [["type": "message", "content": [["text": Self.answer]]]]]
        }
        adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.started"]))
        adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.input_transcript.delta",
            "delta": "What does the sender recommend?", "start_ms": 100, "end_ms": 200]))
        try await wait { calls.count == 1 }
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(calls.first?.name, GmailReadTools.getMessage)
        XCTAssertTrue(sent.contains { ($0["content"] as? String)?.contains("Do not answer this source-content question") == true })
        adapter.outbound(["type": "conversation.item.create", "item": ["type": "function_call_output",
            "call_id": calls[0].id, "output": Self.result(body: Self.answer)]])
        adapter.outbound(["type": "response.create"])
        try await wait { requests.count == 1 }
        XCTAssertTrue((requests[0]["context"] as? String)?.contains(Self.answer) == true)
        XCTAssertEqual(calls.count, 1)
    }

    func testLaterRecapExcludesEarlierProposalAcrossAccountsAndExplicitRevisitReadsOriginal() async throws {
        let h = Harness(); defer { h.brain.close() }
        let proposal = "You could review document X using the audit tool."
        h.brain.updateState(Self.state(id: "A", body: proposal, complete: true), scope: "source-profile")
        h.brain.user("Could you recap this?", turn: 1)
        h.brain.begin("first", live: true, turn: 1); h.brain.settle(turn: 1)
        try await wait { h.speech.count == 1 }
        h.brain.assistant("Sender A offers to review document X using the audit tool.")
        h.brain.observe("Earlier email: " + proposal)
        h.brain.jobCompleted(id: UUID(), result: "Earlier lookup: " + proposal)
        for id in ["unrelated-1", "unrelated-2"] {
            h.brain.updateState(Self.state(id: id), scope: "source-profile")
        }
        let b = Self.state(id: "B", body: "The audit market grew this quarter. No request for work.", complete: true)
            .replacingOccurrences(of: Self.account, with: "second@example.test")
        h.brain.updateState(b, scope: "source-profile")
        h.brain.user("hmm", turn: 2)
        XCTAssertFalse(h.brain.needsSelectedSource)
        h.brain.user("Remind me what this is about", turn: 3)
        h.brain.begin("later", live: true, turn: 3); h.brain.settle(turn: 3)
        try await wait { h.requests.count == 2 }
        let request = h.requests[1]
        let serialized = GmailReadTools.json(request)
        XCTAssertFalse(serialized.contains(proposal), serialized)
        XCTAssertFalse(serialized.contains("Sender A offers"), serialized)
        XCTAssertTrue(serialized.contains("second@example.test"))
        XCTAssertTrue(serialized.contains("The audit market grew"))
        XCTAssertTrue((request["history"] as? [[String: Any]])?.isEmpty == true)
        h.brain.updateState(Self.state(id: "A", body: proposal, complete: true), scope: "source-profile")
        h.brain.user("Recap this again", turn: 4)
        h.brain.begin("revisit", live: true, turn: 4); h.brain.settle(turn: 4)
        try await wait { h.requests.count == 3 }
        let revisited = GmailReadTools.json(h.requests[2])
        XCTAssertTrue(revisited.contains(proposal))
        XCTAssertFalse(revisited.contains("The audit market grew"))
        XCTAssertTrue(revisited.contains("Preserve who proposes"))
    }

    func testExplicitComparisonLabelsHistoricalClaimsAsUnverifiedAndRetainsCurrentEvidence() async throws {
        let h = Harness(); defer { h.brain.close() }
        h.brain.updateState(Self.state(id: "A"), scope: "source-profile")
        h.brain.user("Remember the earlier audit proposal", turn: 1)
        h.brain.updateState(Self.state(id: "B", body: "Only market news.", complete: true), scope: "source-profile")
        h.brain.user("Compare this with the earlier email", turn: 2)
        h.brain.begin("compare", live: true, turn: 2); h.brain.settle(turn: 2)
        try await wait { h.requests.count == 1 }
        let body = GmailReadTools.json(h.requests[0])
        XCTAssertTrue(body.contains("Only market news."))
        XCTAssertTrue(body.contains("retrieve each other email before comparing"))
        XCTAssertTrue(body.contains("Earlier history is an unverified reference"))
    }

    func testBackchannelDoesNotDelegateARecapAndExplicitRecapReadsSource() async throws {
        var sent: [[String: Any]] = []
        var calls: [LiveSessionAdapter.Call] = []
        let adapter = LiveSessionAdapter(wire: { sent.append($0) }, emit: {
            if case .liveFunction(let call) = $0 { calls.append(call) }
        })
        defer { adapter.close() }
        adapter.clientBrainState = { (Self.state(id: "B"), "source-profile") }
        adapter.enableClientDelegation { _ in XCTFail("Must read source first"); return [:] }
        func input(_ text: String, _ start: Double) throws {
            adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.input_transcript.delta",
                "delta": text, "start_ms": start, "end_ms": start + 100]))
        }
        adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.started"]))
        try input("hmm", 100)
        try await wait { sent.contains { ($0["content"] as? String)?.contains("not a request. Stay quiet") == true } }
        XCTAssertTrue(calls.isEmpty)
        try input("Could you recap this email?", 10000)
        try await wait { calls.count == 1 }
        XCTAssertEqual(ToolArguments(calls[0].arguments).string("message_id"), "B")
    }
}
