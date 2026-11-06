import XCTest
@testable import CodenameJo

@MainActor
final class LiveOpeningPresentationTests: XCTestCase {
    @MainActor private final class Harness {
        var sent: [[String: Any]] = []
        var acknowledged = Set<String>()
        var suppressed: [Bool] = []
        var calls: [LiveSessionAdapter.Call] = []
        lazy var adapter = LiveSessionAdapter(wire: { [unowned self] in sent.append($0) }, emit: { [unowned self] in
            if case .liveFunction(let call) = $0 { calls.append(call) }
        })
        var latest: LiveSessionAdapter.EmailOpeningResolution? = .init(line: "Fallback A", summary: nil,
            revision: 0, reason: "preparation_pending", targetHash: "A")
        func receive(_ value: [String: Any]) throws { adapter.receive(try JSONSerialization.data(withJSONObject: value)) }
        func start() throws {
            adapter.onOutputSuppressed = { [weak self] in self?.suppressed.append($0) }
            try receive(["type": "session.started"])
            adapter.stageEmailOpening { [weak self] in self?.latest }
            adapter.outbound(["type": "response.create", "response": ["instructions": "Open the feed."]])
        }
        func acknowledgeAll() throws {
            for _ in 0..<15 {
                let next = sent.filter {
                    ["session.thinking.append", "session.instructions.append", "session.commentary.append"].contains($0["type"] as? String ?? "")
                        && ($0["event_id"] as? String).map { !acknowledged.contains($0) } == true
                }
                if next.isEmpty { return }
                for item in next {
                    let id = try XCTUnwrap(item["event_id"] as? String)
                    acknowledged.insert(id)
                    try receive(["type": (item["type"] as! String) + "ed", "client_event_id": id])
                }
            }
            XCTFail("Speech context did not settle")
        }
        func ready(_ body: String = "Alex asks for the document.") {
            latest = .init(line: "Ready A: " + body, summary: body, revision: 1, reason: "ready", targetHash: "A")
            adapter.refreshEmailOpening()
        }
        var speech: [String] { sent.filter { $0["type"] as? String == "session.commentary.append" }.compactMap { $0["content"] as? String } }
    }

    func testPreparationBetweenConstructionAndCommitReplacesFallback() throws {
        let h = Harness(); defer { h.adapter.close() }
        try h.start()
        h.ready()
        try h.acknowledgeAll()
        XCTAssertEqual(h.speech.count, 1)
        XCTAssertFalse(h.sent.contains { ($0["content"] as? String) == "Fallback A" })
        XCTAssertTrue(h.sent.contains { ($0["content"] as? String)?.hasPrefix("Ready A") == true })
    }

    func testLatePreparationBeforePlaybackSupersedesQueuedFallbackOnce() throws {
        let h = Harness(); defer { h.adapter.close() }
        try h.start(); try h.acknowledgeAll()
        XCTAssertEqual(h.speech.count, 1)
        h.ready(); try h.acknowledgeAll()
        h.adapter.refreshEmailOpening(); try h.acknowledgeAll()
        XCTAssertEqual(h.speech.count, 2, "One original request and one replacement, never two replacements")
        XCTAssertEqual(h.sent.filter { ($0["content"] as? String)?.hasPrefix("Cancel the queued email fallback") == true }.count, 1)
        XCTAssertTrue(h.speech.last?.contains("latest") == true)
    }

    func testLatePreparationDuringPlaybackWaitsThenOnlySpeaksMissingSummary() async throws {
        let h = Harness(); defer { h.adapter.close() }
        try h.start(); try h.acknowledgeAll()
        h.adapter.observePlayback(0.1)
        h.ready()
        XCTAssertEqual(h.speech.count, 1)
        try await Task.sleep(for: .milliseconds(850))
        h.adapter.observePlayback(0)
        try h.acknowledgeAll()
        XCTAssertEqual(h.speech.count, 2)
        XCTAssertTrue(h.speech.last?.contains("Alex asks for the document.") == true)
        XCTAssertFalse(h.speech.last?.contains("What would") == true)
        h.adapter.refreshEmailOpening()
        XCTAssertEqual(h.speech.count, 2)
    }

    func testReplyDictationDropsLateSummaryWithoutInterrupting() throws {
        let h = Harness(); defer { h.adapter.close() }
        try h.start(); try h.acknowledgeAll()
        h.adapter.observePlayback(0.1)
        try h.receive(["type": "session.input_transcript.delta", "delta": "Reply saying thanks",
            "start_ms": 100, "end_ms": 200])
        let count = h.speech.count
        h.ready(); try h.acknowledgeAll()
        XCTAssertEqual(h.speech.count, count)
    }

    func testSourceOrProfileChangeDropsPendingOpening() throws {
        let h = Harness(); defer { h.adapter.close() }
        try h.start()
        h.latest = nil
        try h.acknowledgeAll()
        h.ready("Another account's message")
        try h.acknowledgeAll()
        XCTAssertTrue(h.speech.isEmpty)
    }

    func testWarmStartAndFailedPreparationEachProduceOnePresentation() throws {
        for ready in [false, true] {
            let h = Harness(); defer { h.adapter.close() }
            if ready { h.ready() }
            try h.start(); try h.acknowledgeAll()
            h.adapter.refreshEmailOpening(); try h.acknowledgeAll()
            XCTAssertEqual(h.speech.count, 1)
            XCTAssertEqual(h.sent.filter { ($0["content"] as? String) == "Fallback A" }.count, ready ? 0 : 1)
        }
    }

    func testAtComputerSuppressesOpeningAndLatePreparationButKeepsExplicitReadAloud() throws {
        let h = Harness(); defer { h.adapter.close() }
        h.adapter.setNarrationMode(.atComputer)
        try h.start(); try h.acknowledgeAll()
        h.ready(); h.adapter.presentPreparedEmail("Next email must stay quiet")
        h.adapter.presentScript("A cleanup offer must stay quiet")
        try h.acknowledgeAll()
        XCTAssertTrue(h.speech.isEmpty)
        try h.receive(["type": "session.input_transcript.delta", "delta": "Read this email aloud",
            "start_ms": 100, "end_ms": 200])
        h.adapter.speakExactly("The complete requested email text.")
        try h.acknowledgeAll()
        XCTAssertEqual(h.speech.count, 1)
        XCTAssertTrue(h.speech[0].contains("The complete requested email text."))
        XCTAssertEqual(h.adapter.narrationMode, .atComputer)
        XCTAssertEqual(h.suppressed.last, false)
    }

    func testSwitchToAtComputerCancelsQueuedOpeningAndBackchannelsCannotUnmuteIt() throws {
        let h = Harness(); defer { h.adapter.close() }
        try h.start()
        h.adapter.setNarrationMode(.atComputer)
        try h.acknowledgeAll(); h.ready(); try h.acknowledgeAll()
        XCTAssertTrue(h.speech.isEmpty)
        XCTAssertEqual(h.suppressed.last, true)
        try h.receive(["type": "session.input_transcript.delta", "delta": "[sniffing]",
            "start_ms": 100, "end_ms": 200])
        XCTAssertEqual(h.suppressed.last, true)
        h.adapter.observePlayback(0.5)
        XCTAssertTrue(h.speech.isEmpty)
    }

    func testClickQuestionDictationClickDoesNotChangeNarrationMode() throws {
        let h = Harness(); defer { h.adapter.close() }
        h.adapter.setNarrationMode(.atComputer)
        try h.start(); try h.acknowledgeAll()
        for (index, request) in ["What time is the meeting?", "Reply saying Tuesday works."].enumerated() {
            h.adapter.beginDesktopInteraction(origin: "archive", revision: index)
            try h.receive(["type": "session.input_transcript.delta", "delta": request,
                "start_ms": Double(3000 * (index + 1)), "end_ms": Double(3000 * (index + 1) + 100)])
            h.adapter.speakExactly(index == 0 ? "Tuesday at noon." : "Your draft is ready.")
            try h.acknowledgeAll()
            XCTAssertFalse(h.adapter.desktopQuiet)
            XCTAssertEqual(h.adapter.narrationMode, .atComputer)
            h.adapter.presentPreparedEmail("Next email should not be spoken")
        }
        XCTAssertEqual(h.speech.count, 2)
        h.adapter.beginDesktopInteraction(origin: "archive", revision: 3)
        h.adapter.presentPreparedEmail("Another automatic introduction")
        XCTAssertTrue(h.adapter.desktopQuiet)
        XCTAssertEqual(h.adapter.narrationMode, .atComputer)
    }

    func testSwitchAwayWaitsForBoundaryAndResolvesOnlyCurrentItem() throws {
        let h = Harness(); defer { h.adapter.close() }
        h.adapter.setNarrationMode(.atComputer)
        try h.start(); try h.acknowledgeAll()
        h.adapter.setNarrationMode(.away)
        h.adapter.introduceCurrentWhenSettled { [weak h] in h?.latest }
        XCTAssertTrue(h.speech.isEmpty, "Mode instructions must settle before introducing an item")
        h.latest = .init(line: "Only current B", summary: "B body", revision: 8, reason: "selected", targetHash: "B")
        try h.acknowledgeAll()
        h.adapter.observePlayback(0)
        try h.acknowledgeAll()
        XCTAssertEqual(h.speech.count, 1)
        XCTAssertTrue(h.sent.contains { $0["content"] as? String == "Only current B" })
        XCTAssertFalse(h.sent.contains { $0["content"] as? String == "Fallback A" })
        h.adapter.observePlayback(0); try h.acknowledgeAll()
        XCTAssertEqual(h.speech.count, 1)
    }

    func testRapidModeChangesDropPendingAwayIntroduction() throws {
        let h = Harness(); defer { h.adapter.close() }
        h.adapter.setNarrationMode(.atComputer)
        try h.start(); try h.acknowledgeAll()
        h.adapter.setNarrationMode(.away)
        h.adapter.introduceCurrentWhenSettled { h.latest }
        h.adapter.setNarrationMode(.atComputer)
        try h.acknowledgeAll(); h.adapter.observePlayback(0)
        XCTAssertTrue(h.speech.isEmpty)
    }

    func testNarrationPreferenceSurvivesDefaultsReloadWithSafeFallback() throws {
        let name = "jo-mode-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(WorkSessionMode.stored(in: defaults), .away)
        defaults.set(WorkSessionMode.atComputer.rawValue, forKey: WorkSessionMode.storageKey)
        XCTAssertEqual(WorkSessionMode.stored(in: try XCTUnwrap(UserDefaults(suiteName: name))), .atComputer)
        defaults.set("unknown", forKey: WorkSessionMode.storageKey)
        XCTAssertEqual(WorkSessionMode.stored(in: defaults), .away)
    }

    func testModeSwitchDoesNotCancelAcceptedWorkOrReplayItsTool() async throws {
        let h = Harness(); defer { h.adapter.close() }
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "delta": "Archive this email",
            "start_ms": 100, "end_ms": 200])
        try await Task.sleep(for: .milliseconds(1100))
        try h.receive(["type": "session.delegation.created", "delegation": ["id": "d1", "response_id": "r1"]])
        try h.receive(["type": "response.event", "event": ["type": "response.created", "response": ["id": "r1"]]])
        try h.receive(["type": "response.event", "event": ["type": "response.output_item.done", "response_id": "r1",
            "item": ["type": "function_call", "call_id": "accepted-archive", "name": "archive_message", "arguments": "{}"]]])
        h.adapter.setNarrationMode(.atComputer)
        XCTAssertEqual(h.calls.map(\.id), ["accepted-archive"])
        h.adapter.outbound(["type": "conversation.item.create", "item": ["type": "function_call_output",
            "call_id": "accepted-archive", "output": "Archive confirmed; email B is current."]])
        try h.receive(["type": "response.event", "event": ["type": "response.completed", "response": ["id": "r1", "output": []]]])
        h.adapter.setNarrationMode(.away); h.adapter.setNarrationMode(.atComputer)
        try h.acknowledgeAll()
        XCTAssertEqual(h.calls.map(\.id), ["accepted-archive"])
        XCTAssertEqual(h.sent.filter { (($0["item"] as? [String: Any])?["call_id"] as? String) == "accepted-archive" }.count, 1)
    }
}

