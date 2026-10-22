import XCTest
@testable import CodenameJo

final class LiveSessionAdapterTests: XCTestCase {
    @MainActor
    private final class Harness {
        var sent: [[String: Any]] = []
        var calls: [LiveSessionAdapter.Call] = []
        var idleCount = 0
        var finishedTranscripts: [String] = []
        var queueRecovery: [Bool] = []
        var unworkedSpeech: [String] = []
        var delegationTurns: [String: Int] = [:]
        var firstSpeech: [Int] = []
        var usage: [ResponseUsage] = []
        var contextRatios: [Double] = []
        var brainSteps: [CommandRecord.BrainStep] = []
        var resets = 0
        var completedInputs: [String] = []
        lazy var adapter = LiveSessionAdapter(wire: { [unowned self] in sent.append($0) }, emit: { [unowned self] in
            if case .liveFunction(let call) = $0 { calls.append(call) }
            if case .liveQueueActionUnworked(let exhausted) = $0 { queueRecovery.append(exhausted) }
            if case .liveBackendIdle = $0 { idleCount += 1 }
            if case .event(.assistantTranscriptDone(_, let transcript)) = $0 { finishedTranscripts.append(transcript) }
            if case .liveTurnIdleWithoutDelegation(let speech) = $0 { unworkedSpeech.append(speech) }
            if case .liveDelegation(let id, let turn) = $0 { delegationTurns[id] = turn }
            if case .liveFirstSpeech(let ms) = $0 { firstSpeech.append(ms) }
            if case .liveBackendUsage(let reported, _) = $0 { usage.append(reported) }
            if case .liveContextUsage(let ratio) = $0 { contextRatios.append(ratio) }
            if case .liveBrainStep(let step) = $0 { brainSteps.append(step) }
            if case .liveResetRequested = $0 { resets += 1 }
            if case .liveInputFinished(let text) = $0 { completedInputs.append(text) }
        })

        func receive(_ event: [String: Any]) throws {
            adapter.receive(try JSONSerialization.data(withJSONObject: event))
            if event["type"] as? String == "session.started" {
                let guidance = sent.filter { ($0["content"] as? String) == LiveSessionAdapter.interruptionGuidance }
                for instruction in guidance {
                    try receive(["type": "session.instructions.appended", "client_event_id": try XCTUnwrap(instruction["event_id"])])
                }
                sent.removeAll { ($0["content"] as? String) == LiveSessionAdapter.interruptionGuidance }
            }
        }

        func start(_ response: String = "r1", delegation: String = "d1") throws {
            try receive(["type": "session.started"])
            try receive(["type": "session.delegation.created",
                         "delegation": ["id": delegation, "response_id": response]])
            try lifecycle("response.created", response: response)
        }

        func lifecycle(_ type: String, response: String = "r1") throws {
            try receive(["type": "response.event", "event": ["type": type, "response": ["id": response, "output": []]]])
        }

        func function(_ id: String, response: String = "r1", name: String = "archive_message") throws {
            try receive(["type": "response.event", "event": [
                "type": "response.output_item.done", "response_id": response,
                "item": ["type": "function_call", "call_id": id, "name": name,
                         "arguments": "{\"message_id\":\"email-a\",\"account\":\"owner@example.test\"}"]]])
        }

        func result(_ id: String) {
            adapter.outbound(["type": "conversation.item.create", "item": [
                "type": "function_call_output", "call_id": id, "output": "Archiving; email B is current."]])
            adapter.outbound(["type": "response.create"])
        }
    }

    @MainActor
    func testSpokenResetClosesAStalledToolSessionWithoutWaitingOrReplaying() async throws {
        let h = Harness()
        h.adapter.toolCallBound = 60
        try h.start()
        try h.function("stuck-write")
        try h.function("queued-write")
        try h.receive(["type": "session.input_transcript.delta", "delta": "Jo, reset.",
                       "start_ms": 1000, "end_ms": 1500])
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(h.resets, 1)
        XCTAssertTrue(h.completedInputs.isEmpty, "Reset must bypass normal input and tool routing")
        XCTAssertEqual(h.calls.map(\.id), ["stuck-write"], "Queued work must not start")
        XCTAssertEqual(h.sent.filter { $0["type"] as? String == "session.close" }.count, 1)
        let before = h.sent.count
        h.result("stuck-write")
        try h.lifecycle("response.completed")
        try h.receive(["type": "session.input_transcript.delta", "delta": "Jo reset",
                       "start_ms": 4000, "end_ms": 4500])
        XCTAssertEqual(h.sent.count, before, "Late results cannot revive the closed session")
        XCTAssertEqual(h.resets, 1)
        XCTAssertEqual(h.calls.map(\.id), ["stuck-write"])
        let fresh = Harness()
        try fresh.start()
        try fresh.function("new-read", name: "gmail_search_messages")
        fresh.result("new-read")
        try fresh.lifecycle("response.completed")
        XCTAssertEqual(fresh.calls.map(\.id), ["new-read"])
        XCTAssertTrue(fresh.sent.contains { $0["type"] as? String == "response.create" })
        fresh.adapter.close()
    }

    @MainActor
    func testResetWaitsForWholeUtteranceAndIgnoresInjectedTranscripts() async throws {
        let h = Harness()
        try h.start()
        try h.receive(["type": "session.input_transcript.delta", "delta": "Jo reset",
                       "start_ms": 1000, "end_ms": 1500])
        try h.receive(["type": "session.input_transcript.delta", "delta": " my password",
                       "start_ms": 1500, "end_ms": 1800])
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(h.resets, 0)
        XCTAssertEqual(h.completedInputs, ["Jo reset my password"])
        try h.receive(["type": "session.input_transcript.delta", "delta": "Jo reset",
                       "client_event_id": "injected", "start_ms": 4000, "end_ms": 4500])
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(h.resets, 0)
        h.adapter.close()
    }

    @MainActor
    func testClockLineNamesDateZoneAndOffset() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let line = LiveSessionAdapter.clockLine(now: Date(timeIntervalSince1970: 1_787_331_600), zone: zone)
        XCTAssertTrue(line.hasPrefix("Clock: Friday, August 21, 2026"), line)
        XCTAssertTrue(line.contains("in America/Los_Angeles (UTC-07:00)."), line)
    }

    @MainActor
    func testClockRefreshesOnlyOnceStale() throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        let start = Date(timeIntervalSince1970: 1_787_331_600)
        let clocks = { h.sent.filter { ($0["content"] as? String)?.hasPrefix("Clock:") == true }.count }
        h.adapter.appendClock(now: start)
        h.adapter.appendClock(now: start.addingTimeInterval(60))
        XCTAssertEqual(clocks(), 1, "A fresh clock is not repeated")
        h.adapter.appendClock(now: start.addingTimeInterval(301))
        XCTAssertEqual(clocks(), 2, "A five-minute-old clock is refreshed")
        XCTAssertEqual(h.sent.last?["type"] as? String, "session.thinking.append")
    }

    @MainActor
    func testStartsCompleteCallBeforeResponseEndsAndCorrelatesMissingEnvelopeDelegation() async throws {
        let h = Harness()
        try h.start()
        try h.function("archive-a")
        XCTAssertEqual(h.calls.map(\.id), ["archive-a"])
        XCTAssertEqual(h.calls.first?.delegation, "d1")
        XCTAssertEqual(h.idleCount, 0)
        h.result("archive-a")
        XCTAssertTrue(h.sent.isEmpty, "Backend continuation must wait for the terminal response event")
        try h.lifecycle("response.completed")
        XCTAssertEqual(h.sent.compactMap { $0["type"] as? String }, ["response.item.create", "response.create"])
        XCTAssertEqual(h.idleCount, 0, "A continuation is already starting")
    }

    @MainActor
    func testUnansweredToolIsReleasedAndTheNextCallRuns() async throws {
        let h = Harness()
        h.adapter.toolCallBound = 0.2
        try h.start()
        try h.function("archive-a")
        try h.function("second-call")
        XCTAssertEqual(h.calls.map(\.id), ["archive-a"], "Local calls stay serial")
        var waited = 0
        while h.calls.count < 2, waited < 100 { try await Task.sleep(for: .milliseconds(20)); waited += 1 }
        XCTAssertEqual(h.calls.map(\.id), ["archive-a", "second-call"],
                       "The watchdog answers for the unanswered call and the next one runs")
        // Answered well inside its own bound, so only the first call is ever answered for.
        try h.lifecycle("response.completed")
        h.result("second-call")
        let outputs = h.sent.filter { $0["type"] as? String == "response.item.create" }
            .compactMap { $0["item"] as? [String: Any] }
        XCTAssertEqual(outputs.compactMap { $0["call_id"] as? String }, ["archive-a", "second-call"])
        XCTAssertEqual(outputs.first?["output"] as? String, LiveSessionAdapter.toolCallUnfinished)
        XCTAssertEqual(h.sent.last?["type"] as? String, "response.create")
        // The real result arriving late is dropped, not reported as a mismatch or posted twice.
        let before = h.sent.count
        h.adapter.outbound(["type": "conversation.item.create", "item": [
            "type": "function_call_output", "call_id": "archive-a", "output": "Archived after all."]])
        XCTAssertEqual(h.sent.count, before)
        // A call answered in time is never answered for.
        try h.receive(["type": "session.delegation.created", "delegation": ["id": "d2", "response_id": "r2"]])
        try h.lifecycle("response.created", response: "r2")
        try h.function("third-call", response: "r2")
        XCTAssertEqual(h.calls.map(\.id), ["archive-a", "second-call", "third-call"])
        h.result("third-call")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(h.sent.filter { (($0["item"] as? [String: Any])?["output"] as? String) == LiveSessionAdapter.toolCallUnfinished }.count, 1)
    }

    @MainActor
    func testRepeatedCallCannotExecuteTwiceAndLocalCallsStaySerial() async throws {
        let h = Harness()
        try h.start()
        try h.function("archive-a")
        try h.function("archive-a")
        try h.function("second-call")
        XCTAssertEqual(h.calls.map(\.id), ["archive-a"])
        h.result("archive-a")
        XCTAssertEqual(h.calls.map(\.id), ["archive-a", "second-call"])
        try h.lifecycle("response.completed")
        XCTAssertFalse(h.sent.contains { $0["type"] as? String == "response.create" })
        h.result("second-call")
        XCTAssertEqual(h.sent.compactMap { $0["type"] as? String },
                       ["response.item.create", "response.item.create", "response.create"])
    }

    @MainActor
    func testNextItemCanBeSpokenWhileBackendIsStillRunning() async throws {
        let h = Harness()
        try h.start()
        try h.function("archive-a")
        h.result("archive-a")
        h.adapter.outbound(["type": "response.create", "response": ["instructions": "Archiving. Next is email B."]])
        let append = try XCTUnwrap(h.sent.first)
        XCTAssertEqual(append["type"] as? String, "session.thinking.append")
        try h.receive(["type": "session.thinking.appended", "client_event_id": try XCTUnwrap(append["event_id"])])
        XCTAssertEqual(h.sent.last?["type"] as? String, "session.commentary.append")
        XCTAssertFalse(h.sent.contains { $0["type"] as? String == "response.create" })
    }

    @MainActor
    func testPreparedEmailAsksForSpeechInTheSameBreathAsItsLine() throws {
        let h = Harness()
        try h.start()
        try h.function("archive-a")
        h.result("archive-a")
        let line = "This turn only, read: Next, Alex sent a budget request."
        h.adapter.presentPreparedEmail(line)
        // Nothing is acknowledged in between: the line and the request to speak it leave
        // together, because the request refers only to the line directly ahead of it.
        XCTAssertEqual(h.sent.suffix(2).compactMap { $0["type"] as? String },
                       ["session.thinking.append", "session.commentary.append"])
        XCTAssertEqual(h.sent.dropLast().last?["content"] as? String, line)
        XCTAssertFalse(h.sent.contains { $0["type"] as? String == "response.create" },
                       "Prepared speech must not wait for the backend response to complete")
    }

    @MainActor
    func testAnAdvanceWhileJoIsSpeakingInterruptsTheOldEmailFirst() throws {
        let h = Harness()
        try h.start()
        h.adapter.observePlayback(0.5)
        let line = "This turn only, read: Next, Alex sent a budget request."
        h.adapter.presentPreparedEmail(line)
        XCTAssertEqual(h.sent.suffix(2).compactMap { $0["content"] as? String },
                       [LiveSessionAdapter.supersededPresentation, line])
        let stop = h.sent[h.sent.count - 2]
        XCTAssertEqual(stop["type"] as? String, "session.instructions.append")
        XCTAssertFalse(h.sent.contains { $0["type"] as? String == "session.commentary.append" },
                       "The new email is spoken only once the interrupt has landed")
        try h.receive(["type": "session.instructions.appended", "client_event_id": try XCTUnwrap(stop["event_id"])])
        XCTAssertEqual(h.sent.last?["type"] as? String, "session.commentary.append")
    }

    @MainActor
    func testAFeedOfferYesLetsTheAcknowledgementFinish() throws {
        let h = Harness()
        try h.start()
        h.adapter.observePlayback(0.5)
        h.adapter.presentPreparedEmail("This turn only, read: First up, Alex sent a budget request.",
                                       interruptsSpeech: false)
        XCTAssertFalse(h.sent.contains { $0["content"] as? String == LiveSessionAdapter.supersededPresentation })
        XCTAssertEqual(h.sent.last?["type"] as? String, "session.commentary.append")
    }

    @MainActor
    func testAnAdvanceWhileJoIsQuietSendsNoInterrupt() throws {
        let h = Harness()
        try h.start()
        h.adapter.presentPreparedEmail("This turn only, read: Next, Alex sent a budget request.")
        XCTAssertFalse(h.sent.contains { $0["content"] as? String == LiveSessionAdapter.supersededPresentation })
    }

    @MainActor
    func testAWholeCommandSettlesBeforeOtherSpeech() async throws {
        var finished: [String] = []
        let adapter = LiveSessionAdapter(wire: { _ in }, emit: {
            if case .liveInputFinished(let text) = $0 { finished.append(text) }
        })
        adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.started"]))
        adapter.receive(try JSONSerialization.data(withJSONObject: [
            "type": "session.input_transcript.delta", "delta": "archive it", "start_ms": 1000, "end_ms": 1500]))
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(finished, ["archive it"])
        adapter.receive(try JSONSerialization.data(withJSONObject: [
            "type": "session.input_transcript.delta", "delta": "archive it and reply", "start_ms": 4000, "end_ms": 4500]))
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(finished, ["archive it"], "Anything else still waits the full second")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(finished, ["archive it", "archive it and reply"])
        adapter.close()
    }

    @MainActor
    func testPreparedEmailStillWaitsOnOtherContextAndCanBeCancelledWhileItDoes() throws {
        let h = Harness()
        try h.start()
        // Material written separately from the request still gates it. `presentPreparedEmail`
        // opts its own line out of that gate and nothing else's, so a presentation issued
        // while earlier context is in flight waits — and can still be taken back.
        h.adapter.outbound(["type": "conversation.item.create", "item": [
            "type": "message", "role": "system",
            "content": [["type": "input_text", "text": "A checkpoint."]]]])
        let checkpoint = try XCTUnwrap(h.sent.last { $0["type"] as? String == "session.thinking.append" })
        h.adapter.presentPreparedEmail("This turn only, read: Next, Alex sent a budget request.")
        XCTAssertFalse(h.sent.contains { $0["type"] as? String == "session.commentary.append" })
        h.adapter.cancelPreparedEmail()
        let cancellation = try XCTUnwrap(h.sent.last)
        XCTAssertTrue((cancellation["content"] as? String)?.contains("cancelled") == true)
        try h.receive(["type": "session.thinking.appended", "client_event_id": try XCTUnwrap(cancellation["event_id"])])
        try h.receive(["type": "session.thinking.appended", "client_event_id": try XCTUnwrap(checkpoint["event_id"])])
        XCTAssertFalse(h.sent.contains { $0["type"] as? String == "session.commentary.append" },
                       "A presentation cancelled before its request went out is never spoken")
    }

    @MainActor
    func testOptionalDossierContextDoesNotWaitForAcknowledgementBeforeSpeaking() throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        h.adapter.outbound([
            "type": "conversation.item.create", "await_context_ack": false,
            "speaker_brief": "No active dossier context is available.",
            "item": ["type": "message", "role": "system",
                     "content": [["type": "input_text", "text": "Earlier profile dossier context is inactive."]]],
        ])
        h.adapter.speakExactly("Your profile is ready.")
        XCTAssertTrue(h.sent.contains { $0["type"] as? String == "session.commentary.append" },
                      "An optional dossier append must not delay the next spoken response")
    }

    @MainActor
    func testASpeakerBriefReplacesTheStepForTheSpeakerButNeverForTheBackend() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        let step = #"{"item":{"identity":"Latest Lee","snippet":"padding"}}"#
            + String(repeating: " detail", count: 200)
        let brief = #"Say exactly this, then stop: "First up, Latest Lee needs the form back.""#
        h.adapter.outbound([
            "type": "conversation.item.create",
            "speaker_brief": brief,
            "item": ["type": "message", "role": "system",
                     "content": [["type": "input_text", "text": step]]],
        ])

        let backend = try XCTUnwrap(h.sent.first { $0["type"] as? String == "response.item.create" })
        XCTAssertEqual((backend["item"] as? [String: Any])?["content"] as? String, step,
                       "The backend must still get every field of the step")

        let appends = h.sent.filter { $0["type"] as? String == "session.thinking.append" }
        XCTAssertEqual(appends.count, 1, "The speaker's line must not be chunked")
        XCTAssertEqual(appends.first?["content"] as? String, brief)
        XCTAssertFalse((appends.first?["content"] as? String ?? "").contains("snippet"),
                       "The step's own fields must not reach the speaker")
    }

    @MainActor
    func testWithoutABriefTheWholeContextItemStillReachesTheSpeaker() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        h.adapter.outbound([
            "type": "conversation.item.create",
            "item": ["type": "message", "role": "system",
                     "content": [["type": "input_text", "text": "A short note."]]],
        ])
        let appends = h.sent.filter { $0["type"] as? String == "session.thinking.append" }
        XCTAssertEqual(appends.first?["content"] as? String, "A short note.")
    }

    @MainActor
    func testOpeningInstructionsAreAcknowledgedBeforeSpeechAndNotRepeated() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        let greeting = "Hi, welcome back. Let's go through your inbox."
        h.adapter.prepareOpening(instructions: "Begin exactly with \"\(greeting)\"")
        h.adapter.outbound(["type": "response.create", "response": ["instructions": "First up, present the current email."]])
        let updates = h.sent
        XCTAssertEqual(updates.compactMap { $0["type"] as? String },
                       ["session.instructions.append", "session.thinking.append"])
        XCTAssertTrue((updates[0]["content"] as? String)?.contains(greeting) == true)
        try h.receive(["type": "session.thinking.appended", "client_event_id": try XCTUnwrap(updates[1]["event_id"])])
        XCTAssertEqual(h.sent.count, 2, "Do not request speech before the greeting instruction is accepted")
        try h.receive(["type": "session.instructions.appended", "client_event_id": try XCTUnwrap(updates[0]["event_id"])])
        XCTAssertEqual(h.sent.last?["type"] as? String, "session.commentary.append")
        let count = h.sent.count
        h.adapter.prepareOpening(instructions: "Do not introduce the same call twice")
        XCTAssertEqual(h.sent.count, count)
    }

    @MainActor
    func testSpeakerNeverReadsTheQueuesCheckpointBookkeepingButTheBackendStillDoes() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        let step = #"{"interstitial":"feed","coaching":{"checkpoint":1,"id":"work|2026-09-14|1|feed","note":"Ask exactly `Hey, do you want to learn something new about Jo?`"},"calendarDue":false}"#
        h.adapter.outbound(["type": "conversation.item.create", "item": [
            "role": "system", "content": [["type": "input_text", "text": "Coaching checkpoint below.\n" + step]]]])
        h.adapter.outbound(["type": "response.create", "response": [
            "instructions": "Acknowledge briefly, follow the queue result.\n" + step]])

        let backend = try XCTUnwrap(h.sent.first { $0["type"] as? String == "response.item.create" })
        XCTAssertTrue(((backend["item"] as? [String: Any])?["content"] as? String)?.contains("\"checkpoint\":1") == true,
                      "coach_capability needs the checkpoint and id it echoes back")
        let spoken = h.sent.filter { ($0["type"] as? String)?.hasSuffix(".append") == true }
            .compactMap { $0["content"] as? String }.joined()
        XCTAssertFalse(spoken.isEmpty)
        XCTAssertFalse(spoken.contains("checkpoint"), "The speaking model must not be handed the word")
        XCTAssertFalse(spoken.contains(":1"), "Nor the ordinal it announced")
        XCTAssertTrue(spoken.contains("Hey, do you want to learn something new about Jo?"))
    }

    @MainActor
    func testOverlappingBackendResponsesDoNotReleaseContinuationEarly() async throws {
        let h = Harness()
        try h.start()
        try h.start("r2", delegation: "d2")
        try h.function("archive-a")
        h.result("archive-a")
        try h.lifecycle("response.completed")
        XCTAssertTrue(h.sent.isEmpty)
        try h.lifecycle("response.completed", response: "r2")
        XCTAssertEqual(h.sent.compactMap { $0["type"] as? String }, ["response.item.create", "response.create"])
    }
    @MainActor
    func testFarewellSpeaksDirectlyWithoutAnotherBackendTurn() throws {
        let h = Harness()
        try h.start()
        try h.function("end-call")
        h.adapter.beginFarewell()
        h.result("end-call")
        let guidance = h.sent.filter { $0["type"] as? String == "session.thinking.append" }
        XCTAssertFalse(guidance.isEmpty)
        for append in guidance {
            try h.receive(["type": "session.thinking.appended",
                           "client_event_id": try XCTUnwrap(append["event_id"])])
        }
        XCTAssertEqual(h.sent.last?["type"] as? String, "session.commentary.append")
        XCTAssertTrue((h.sent.last?["content"] as? String)?.contains("Goodbye, take care") == true)
        try h.lifecycle("response.completed")
        XCTAssertTrue(h.sent.contains { $0["type"] as? String == "response.item.create" })
        XCTAssertFalse(h.sent.contains { $0["type"] as? String == "response.create" })
        XCTAssertEqual(h.idleCount, 0, "Do not resume the feed during a farewell")
        let count = h.sent.count
        h.adapter.beginFarewell()
        h.adapter.outbound(["type": "response.create", "response": ["instructions": "Next email"]])
        XCTAssertEqual(h.sent.count, count, "A duplicate end request or feed nudge cannot replace the goodbye")
    }

    @MainActor
    private func finalizedCommand(_ h: Harness, start: Double = 100) async throws {
        try h.receive(["type": "session.input_transcript.delta", "start_ms": start,
                       "end_ms": start + 100, "delta": "Archive this."])
        try h.start("r\(Int(start))", delegation: "d\(Int(start))")
        try await Task.sleep(for: .milliseconds(1050))
    }

    @MainActor
    private func waitBeats(_ h: Harness) -> [String] {
        h.sent.filter { $0["type"] as? String == "session.commentary.append" }
            .compactMap { $0["content"] as? String }
            .filter { line in LiveSessionAdapter.waitBeats.contains { line.contains($0) } }
    }

    @MainActor
    private func acknowledgeCommentary(_ h: Harness) throws {
        for append in h.sent where append["type"] as? String == "session.commentary.append" {
            try h.receive(["type": "session.commentary.appended",
                           "client_event_id": try XCTUnwrap(append["event_id"])])
        }
    }

    @MainActor
    func testQuietToolTurnHearsAtMostTwoPresenceLines() async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try await finalizedCommand(h)
        try h.function("slow", response: "r100", name: "list_calendar_events")
        h.adapter.observePlayback(0)
        XCTAssertEqual(waitBeats(h).count, 1)
        XCTAssertTrue(waitBeats(h)[0].contains("Still working on that."))
        h.adapter.observePlayback(0)
        XCTAssertEqual(waitBeats(h).count, 1, "Each line restarts the quiet clock")
        try acknowledgeCommentary(h)
        try await Task.sleep(for: .milliseconds(100))
        h.adapter.observePlayback(0)
        XCTAssertEqual(waitBeats(h).count, 1, "The next line waits until the first is heard")
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1300,
                       "end_ms": 1500, "delta": "Still working on that."])
        try await Task.sleep(for: .milliseconds(100))
        h.adapter.observePlayback(0)
        XCTAssertEqual(waitBeats(h).count, 2)
        XCTAssertEqual(h.adapter.currentTurnSpeech, "")
        try acknowledgeCommentary(h)
        try await Task.sleep(for: .milliseconds(100))
        h.adapter.observePlayback(0)
        XCTAssertEqual(waitBeats(h).count, 2, "Two lines per request at most")
    }

    @MainActor
    func testNoPresenceLineWhileJoSpeaksOrOnceWorkIsDone() async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try await finalizedCommand(h)
        try h.function("slow", response: "r100", name: "list_calendar_events")
        h.adapter.observePlayback(0.5)
        XCTAssertTrue(waitBeats(h).isEmpty, "Never over Jo's own audio")
        try await Task.sleep(for: .milliseconds(100))
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 300,
                       "end_ms": 400, "delta": "Hmm, let me see."])
        h.adapter.observePlayback(0)
        XCTAssertTrue(waitBeats(h).isEmpty, "Recent speech is not a quiet stretch")
        h.result("slow")
        try h.lifecycle("response.completed", response: "r100")
        try h.lifecycle("response.created", response: "continuation")
        try h.lifecycle("response.completed", response: "continuation")
        try await Task.sleep(for: .milliseconds(1000))
        h.adapter.observePlayback(0)
        XCTAssertTrue(waitBeats(h).isEmpty, "Nothing is in flight once the backend finishes")
    }

    @MainActor
    func testPresenceLineSpokenAfterTheUserCutsInIsNotTheirAnswer() async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try await finalizedCommand(h)
        try h.function("slow", response: "r100", name: "list_calendar_events")
        h.adapter.observePlayback(0)
        XCTAssertEqual(waitBeats(h).count, 1)
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 5000,
                       "end_ms": 5300, "delta": "Is it free?"])
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 5400,
                       "end_ms": 5700, "delta": "Still working on that."])
        XCTAssertEqual(h.adapter.currentTurnSpeech, "", "A late presence line never answers the new question")
    }

    @MainActor
    func testAnswerSharingAFragmentWithThePresenceLineKeepsOnlyTheAnswer() async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try await finalizedCommand(h)
        try h.function("slow", response: "r100", name: "list_calendar_events")
        h.adapter.observePlayback(0)
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1300,
                       "end_ms": 1400, "delta": "Still working on"])
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1400,
                       "end_ms": 1800, "delta": " that. You're free at ten."])
        XCTAssertEqual(h.adapter.currentTurnSpeech, " You're free at ten.")
    }

    @MainActor
    func testReplyThatOnlySharesThePresenceWordsIsKeptWhole() async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try await finalizedCommand(h)
        try h.function("slow", response: "r100", name: "list_calendar_events")
        h.adapter.observePlayback(0)
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1300,
                       "end_ms": 1400, "delta": "Still working on"])
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1400,
                       "end_ms": 1800, "delta": " that draft, should I save it?"])
        XCTAssertEqual(h.adapter.currentTurnSpeech, "Still working on that draft, should I save it?")
    }

    @MainActor
    func testPresenceLineSpokenAsTwoSentencesIsStillPresence() async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try await finalizedCommand(h)
        try h.function("slow", response: "r100", name: "list_calendar_events")
        h.adapter.observePlayback(0)
        try acknowledgeCommentary(h)
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1300,
                       "end_ms": 1500, "delta": "Still working on that."])
        try await Task.sleep(for: .milliseconds(100))
        h.adapter.observePlayback(0)
        XCTAssertEqual(waitBeats(h).count, 2)
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 6000,
                       "end_ms": 6200, "delta": "Still here."])
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 6200,
                       "end_ms": 6600, "delta": " Still working on that."])
        XCTAssertEqual(h.adapter.currentTurnSpeech, "")
        XCTAssertTrue(h.finishedTranscripts.isEmpty)
    }

    @MainActor
    func testRewordedPresenceLineStaysOutOfHistory() async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try await finalizedCommand(h)
        try h.function("slow", response: "r100", name: "list_calendar_events")
        h.adapter.observePlayback(0)
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1300,
                       "end_ms": 1600, "delta": " I'm still here and still working on that."])
        h.adapter.observePlayback(0.5)
        try await Task.sleep(for: .milliseconds(850))
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.adapter.currentTurnSpeech, "")
        XCTAssertTrue(h.finishedTranscripts.isEmpty, "Seen on device: a reworded line became a History row")
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 3000,
                       "end_ms": 3400, "delta": "I found two emails."])
        XCTAssertEqual(h.adapter.currentTurnSpeech, "I found two emails.")
    }

    @MainActor
    func testPresenceWordSplitAcrossDeltasIsStillPresence() async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try await finalizedCommand(h)
        try h.function("slow", response: "r100", name: "list_calendar_events")
        h.adapter.observePlayback(0)
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1300,
                       "end_ms": 1400, "delta": "Still work"])
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1400,
                       "end_ms": 1600, "delta": "ing on that."])
        XCTAssertEqual(h.adapter.currentTurnSpeech, "")
    }

    @MainActor
    func testStillWorkingOnItIsPresence() async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try await finalizedCommand(h)
        try h.function("slow", response: "r100", name: "list_calendar_events")
        h.adapter.observePlayback(0)
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1300,
                       "end_ms": 1600, "delta": "Still working on it."])
        XCTAssertEqual(h.adapter.currentTurnSpeech, "")
    }

    @MainActor
    func testAStallAfterThePresenceLineStaysVisibleToRecovery() async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try await finalizedCommand(h)
        try h.function("slow", response: "r100", name: "list_calendar_events")
        h.adapter.observePlayback(0)
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1300,
                       "end_ms": 1500, "delta": "Still working on that."])
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 3000,
                       "end_ms": 3200, "delta": " I'm on it."])
        XCTAssertEqual(h.adapter.currentTurnSpeech, " I'm on it.")
    }

    @MainActor
    func testShortReplyThatPrefixesThePresenceLineIsKept() async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try await finalizedCommand(h)
        try h.function("slow", response: "r100", name: "list_calendar_events")
        h.adapter.observePlayback(0)
        try acknowledgeCommentary(h)
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1300,
                       "end_ms": 1500, "delta": "Still working on that."])
        try await Task.sleep(for: .milliseconds(100))
        h.adapter.observePlayback(0)
        XCTAssertEqual(waitBeats(h).count, 2)
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 5000,
                       "end_ms": 5300, "delta": "Are you there?"])
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 5400,
                       "end_ms": 5600, "delta": "Still here."])
        XCTAssertEqual(h.adapter.currentTurnSpeech, "Still here.")
    }

    @MainActor
    func testInterruptedPresenceLineNeverJoinsTheNextReply() async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try await finalizedCommand(h)
        try h.function("slow", response: "r100", name: "list_calendar_events")
        h.adapter.observePlayback(0)
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1300,
                       "end_ms": 1400, "delta": "Still working on "])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 5000,
                       "end_ms": 5300, "delta": "Never mind."])
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 5400,
                       "end_ms": 5500, "delta": "Okay."])
        XCTAssertEqual(h.adapter.currentTurnSpeech, "Okay.")
    }

    @MainActor
    func testAnswerThatStartsLikeAPresenceLineIsKeptWhole() async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try await finalizedCommand(h)
        try h.function("slow", response: "r100", name: "list_calendar_events")
        h.adapter.observePlayback(0)
        XCTAssertEqual(waitBeats(h).count, 1)
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1300,
                       "end_ms": 1400, "delta": "Still"])
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1400,
                       "end_ms": 1600, "delta": " unavailable on Monday."])
        XCTAssertEqual(h.adapter.currentTurnSpeech, "Still unavailable on Monday.")
    }

    @MainActor
    func testNoPresenceLineAfterTheUserStopsJo() async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try await finalizedCommand(h)
        try h.function("slow", response: "r100", name: "list_calendar_events")
        h.adapter.outbound(["type": "output_audio_buffer.clear"])
        for append in h.sent where append["type"] as? String == "session.instructions.append" {
            try h.receive(["type": "session.instructions.appended",
                           "client_event_id": try XCTUnwrap(append["event_id"])])
        }
        try await Task.sleep(for: .milliseconds(100))
        h.adapter.observePlayback(0)
        XCTAssertTrue(waitBeats(h).isEmpty, "A tap to stop is not undone by a presence line")
    }

    @MainActor
    func testPresenceLineStoppedMidwayNeverJoinsTheAnswer() async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try await finalizedCommand(h)
        try h.function("slow", response: "r100", name: "list_calendar_events")
        h.adapter.observePlayback(0)
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1300,
                       "end_ms": 1400, "delta": "Still working on "])
        h.adapter.outbound(["type": "output_audio_buffer.clear"])
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 3000,
                       "end_ms": 3400, "delta": "You're free at ten."])
        XCTAssertEqual(h.adapter.currentTurnSpeech, "You're free at ten.")
    }

    @MainActor
    func testAnUnspokenPresenceLineDoesNotSilenceTheNextRequest() async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try await finalizedCommand(h)
        try h.function("slow", response: "r100", name: "list_calendar_events")
        h.adapter.observePlayback(0)
        XCTAssertEqual(waitBeats(h).count, 1)
        try acknowledgeCommentary(h)
        try await finalizedCommand(h, start: 5000)
        try h.function("slow-2", response: "r5000", name: "list_calendar_events")
        h.result("slow")
        h.adapter.observePlayback(0)
        XCTAssertEqual(waitBeats(h).count, 2, "The line never spoken last turn does not block this one")
    }

    @MainActor
    func testPresenceLineCoversTheBackendDecidingBeforeItsFirstTool() async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "When am I free on Monday?"])
        try await Task.sleep(for: .milliseconds(1050))
        h.adapter.observePlayback(0)
        XCTAssertTrue(waitBeats(h).isEmpty, "Nothing was delegated, so nothing is running")
        try h.start("r100", delegation: "d100")
        h.adapter.observePlayback(0)
        XCTAssertEqual(waitBeats(h).count, 1)
    }

    @MainActor
    func testNoPresenceLineWhileADispatchStarts() async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Research this in the background."])
        try h.start("r100", delegation: "d100")
        try await Task.sleep(for: .milliseconds(1050))
        h.adapter.observePlayback(0)
        XCTAssertTrue(waitBeats(h).isEmpty, "Background work is reported when it comes back")
    }

    @MainActor
    func testNoPresenceLineWhileOrAfterADispatchRuns() async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try await finalizedCommand(h)
        try h.function("handoff", response: "r100", name: "dispatch")
        h.adapter.observePlayback(0)
        XCTAssertTrue(waitBeats(h).isEmpty, "Jo is about to say it will come back with the answer")
        h.adapter.outbound(["type": "conversation.item.create", "item": [
            "type": "function_call_output", "call_id": "handoff", "output": "Started. The answer arrives later."]])
        try await Task.sleep(for: .milliseconds(100))
        h.adapter.observePlayback(0)
        XCTAssertTrue(waitBeats(h).isEmpty, "Jo already said it will come back with the answer")
    }

    @MainActor
    private func assertPresenceLineCannotSettleTheTurn(beatBeforeCompletion: Bool) async throws {
        let h = Harness()
        h.adapter.waitBeatQuiet = 0.05
        try await finalizedCommand(h)
        try h.function("slow", response: "r100", name: "list_calendar_events")
        h.adapter.observePlayback(0)
        try acknowledgeCommentary(h)
        func beat() throws {
            try h.receive(["type": "session.output_transcript.delta", "start_ms": 1300,
                           "end_ms": 1400, "delta": "Still working"])
            try h.receive(["type": "session.output_transcript.delta", "start_ms": 1400,
                           "end_ms": 1500, "delta": " on that"])
            try h.receive(["type": "session.output_transcript.delta", "start_ms": 1500,
                           "end_ms": 1500, "delta": "."])
        }
        if beatBeforeCompletion { try beat() }
        h.result("slow")
        try h.lifecycle("response.completed", response: "r100")
        try h.lifecycle("response.created", response: "continuation")
        try h.lifecycle("response.completed", response: "continuation")
        if !beatBeforeCompletion { try beat() }
        h.adapter.observePlayback(0.5)
        try await Task.sleep(for: .milliseconds(850))
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.idleCount, 0, "The presence line alone must not settle the turn")
        XCTAssertEqual(h.finishedTranscripts, [], "Its audio ending is not the end of a reply")
        XCTAssertEqual(h.adapter.currentTurnSpeech, "", "Presence speech never feeds recovery")
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 3000,
                       "end_ms": 3400, "delta": "You're free at ten."])
        try await Task.sleep(for: .milliseconds(850))
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.idleCount, 1, "The spoken result settles it as before")
        XCTAssertEqual(h.adapter.currentTurnSpeech, "You're free at ten.")
        XCTAssertEqual(h.finishedTranscripts, ["You're free at ten."], "History records the answer, not the filler")
    }

    @MainActor
    func testPresenceLineHeardBeforeBackendCompletionCannotSettleTheTurn() async throws {
        try await assertPresenceLineCannotSettleTheTurn(beatBeforeCompletion: true)
    }

    @MainActor
    func testPresenceLineHeardAfterBackendCompletionCannotSettleTheTurn() async throws {
        try await assertPresenceLineCannotSettleTheTurn(beatBeforeCompletion: false)
    }

    @MainActor
    func testPresenceLinesAreNotStallAnnouncements() {
        for line in LiveSessionAdapter.waitBeats {
            XCTAssertFalse(FullDuplexVoiceClient.announcesLookup(FullDuplexVoiceClient.normalize(line)))
        }
    }

    @MainActor
    func testExplicitBackgroundRequestRequiresStartedDispatchBeforeNext() async throws {
        let h = Harness()
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100, "end_ms": 200,
                       "delta": "Do this in the background and move to the next email."])
        try h.start()
        try await Task.sleep(for: .milliseconds(1050))

        try h.function("premature-next", name: "triage_next")
        XCTAssertTrue(h.calls.isEmpty)

        try h.function("handoff", name: "dispatch")
        XCTAssertEqual(h.calls.map(\.id), ["handoff"])
        XCTAssertTrue(h.adapter.requestedBackground(for: try XCTUnwrap(h.calls.first)))
        h.adapter.outbound(["type": "conversation.item.create", "item": [
            "type": "function_call_output", "call_id": "handoff", "output": "Started. The answer arrives later."]])
        try h.function("after-handoff", name: "triage_next")
        XCTAssertEqual(h.calls.map(\.id), ["handoff", "after-handoff"])
        try h.lifecycle("response.completed")
        XCTAssertTrue(h.sent.contains { (($0["item"] as? [String: Any])?["output"] as? String)?
            .contains("Call dispatch first") == true },
            "The rejection is delivered after the backend response completes")
    }

    @MainActor
    func testBackgroundRequestDetectionDoesNotTreatNegationAsConsent() {
        XCTAssertTrue(LiveSessionAdapter.explicitlyRequestsBackground("Just do this in the background."))
        XCTAssertTrue(LiveSessionAdapter.explicitlyRequestsBackground("Dispatch it and let's move on."))
        XCTAssertFalse(LiveSessionAdapter.explicitlyRequestsBackground("Do not do this in the background."))
        XCTAssertFalse(LiveSessionAdapter.explicitlyRequestsBackground("What's her background?"))
    }

    @MainActor
    func testFastActionWaitsForFinalTranscriptAndSuppressesDuplicateTool() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100, "end_ms": 200, "delta": "Archive this."])
        try h.start()
        XCTAssertFalse(h.adapter.beginFastAction(callId: "early", action: .archive))
        try await Task.sleep(for: .milliseconds(1050))
        XCTAssertTrue(h.adapter.beginFastAction(callId: "local", action: .archive))
        XCTAssertFalse(h.adapter.beginFastAction(callId: "duplicate", action: .archive))
        try h.function("late")
        XCTAssertTrue(h.calls.isEmpty, "The brain call waits while the app action is pending")
        h.result("local")
        XCTAssertTrue(h.calls.isEmpty, "The late brain call must reuse the app result")
        try h.lifecycle("response.completed")
        let items = h.sent.compactMap { $0["item"] as? [String: Any] }
        XCTAssertTrue(items.contains { $0["role"] as? String == "developer" })
        XCTAssertTrue(items.contains { $0["call_id"] as? String == "late" })
        XCTAssertFalse(items.contains { $0["call_id"] as? String == "local" },
                       "A synthetic call must never be sent as a Responses function result")
    }

    @MainActor
    func testBrainWinningTheRaceDisablesFastAction() async throws {
        let h = Harness()
        try await finalizedCommand(h)
        try h.function("brain-first", response: "r100")
        XCTAssertEqual(h.calls.count, 1)
        XCTAssertFalse(h.adapter.beginFastAction(callId: "local", action: .archive))
    }

    @MainActor
    func testAnsweredAcknowledgementDoesNotPoisonTheNextArchiveAuthorization() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Thank you."])
        try await Task.sleep(for: .milliseconds(1050))
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 300,
                       "end_ms": 500, "delta": "You're welcome."])
        try await finalizedCommand(h, start: 3000)
        XCTAssertTrue(h.adapter.beginFastAction(callId: "after-aside", action: .archive))
    }

    @MainActor
    func testUndelegatedArchiveCorrelatesContinuationAndSuppressesLateDelegation() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "You can archive."])
        try await Task.sleep(for: .milliseconds(1050))
        XCTAssertTrue(h.adapter.beginFastAction(callId: "local", action: .archive))
        XCTAssertEqual(h.delegationTurns["local"], 1)
        h.result("local")
        try h.lifecycle("response.created", response: "continuation")
        try h.function("duplicate-continuation", response: "continuation")
        XCTAssertTrue(h.calls.isEmpty)
        try h.lifecycle("response.completed", response: "continuation")
        try h.lifecycle("response.created", response: "continuation-result")
        try h.lifecycle("response.completed", response: "continuation-result")
        try h.receive(["type": "session.delegation.created", "offset_ms": 100,
                       "delegation": ["id": "late", "response_id": "late-response"]])
        try h.function("duplicate-delegation", response: "late-response")
        XCTAssertTrue(h.calls.isEmpty)
        try h.lifecycle("response.completed", response: "late-response")
        let items = h.sent.compactMap { $0["item"] as? [String: Any] }
        XCTAssertTrue(items.contains { $0["call_id"] as? String == "duplicate-continuation" })
        XCTAssertTrue(items.contains { $0["call_id"] as? String == "duplicate-delegation" })
    }

    @MainActor
    func testOlderBackendStillBlocksUndelegatedFastAction() async throws {
        let h = Harness()
        try h.start()
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Archive."])
        try await Task.sleep(for: .milliseconds(1050))
        XCTAssertFalse(h.adapter.beginFastAction(callId: "local", action: .archive))
    }

    @MainActor
    func testRefusalIsReusedWithoutRetryAndNewTurnCanAct() async throws {
        let h = Harness()
        try await finalizedCommand(h)
        XCTAssertTrue(h.adapter.beginFastAction(callId: "local", action: .archive))
        h.adapter.outbound(["type": "conversation.item.create", "item": ["type": "function_call_output",
            "call_id": "local", "output": "Refused: account unavailable. No archive was accepted."]])
        try h.function("late", response: "r100")
        XCTAssertTrue(h.calls.isEmpty)
        try h.lifecycle("response.completed", response: "r100")
        let result = h.sent.compactMap { $0["item"] as? [String: Any] }.first { $0["call_id"] as? String == "late" }
        XCTAssertTrue((result?["output"] as? String)?.contains("Refused: account unavailable") == true)
        try h.lifecycle("response.created", response: "r-followup")
        try h.lifecycle("response.completed", response: "r-followup")
        try await finalizedCommand(h, start: 3000)
        try h.function("new-request", response: "r3000")
        XCTAssertEqual(h.calls.map(\.id), ["new-request"])
    }

    @MainActor
    func testFollowupReadsAllowedButLateWritesAndDispatchAreSuppressed() async throws {
        let h = Harness()
        try await finalizedCommand(h)
        XCTAssertTrue(h.adapter.beginFastAction(callId: "local", action: .archive))
        h.result("local")
        for name in ["archive_message", "triage_next", "dispatch", "gmail_archive_message", "gmail_send_email"] {
            try h.receive(["type": "response.event", "delegation_id": "d100", "event": [
                "type": "response.output_item.done", "response_id": "r100",
                "item": ["type": "function_call", "call_id": name, "name": name, "arguments": "{}"]]])
        }
        XCTAssertTrue(h.calls.isEmpty)
        try h.receive(["type": "response.event", "delegation_id": "d100", "event": [
            "type": "response.output_item.done", "response_id": "r100",
            "item": ["type": "function_call", "call_id": "read", "name": "gmail_get_message", "arguments": "{}"]]])
        XCTAssertEqual(h.calls.map(\.id), ["read"])
        XCTAssertTrue(h.adapter.allowsFastFollowup(try XCTUnwrap(h.calls.first)))
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 3000, "end_ms": 3100, "delta": "Wait."])
        XCTAssertFalse(h.adapter.allowsFastFollowup(try XCTUnwrap(h.calls.first)))
    }

    @MainActor
    func testCaptionPauseCannotDiscardNegationBeforeArchive() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100, "end_ms": 200, "delta": "Don't"])
        try await Task.sleep(for: .milliseconds(1050))
        try await finalizedCommand(h, start: 2000)
        XCTAssertFalse(h.adapter.beginFastAction(callId: "local", action: .archive))
        try h.function("normal-brain", response: "r2000")
        XCTAssertEqual(h.calls.map(\.id), ["normal-brain"])
    }

    @MainActor
    func testBackchannelCannotDiscardPausedNegationBeforeArchive() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Don't"])
        try await Task.sleep(for: .milliseconds(1050))
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 300,
                       "end_ms": 400, "delta": "Mm-hmm."])
        try await finalizedCommand(h, start: 2000)
        XCTAssertFalse(h.adapter.beginFastAction(callId: "local", action: .archive))
    }

    @MainActor
    func testSubstantiveAssistantSpeechCannotDiscardConditionalAuthorization() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "If I agree later"])
        try await Task.sleep(for: .milliseconds(1050))
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 300,
                       "end_ms": 400, "delta": "I'll wait for you to finish."])
        try await finalizedCommand(h, start: 2000)
        XCTAssertFalse(h.adapter.beginFastAction(callId: "local", action: .archive))
    }

    @MainActor
    func testClarificationKeepsArchiveInsideTheOriginalReminderRequest() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Remind me to"])
        try await Task.sleep(for: .milliseconds(1050))
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 300,
                       "end_ms": 400, "delta": "What should I remind you to do?"])
        try await finalizedCommand(h, start: 2000)
        XCTAssertFalse(h.adapter.beginFastAction(callId: "local", action: .archive))
    }

    @MainActor
    func testStatementClarificationKeepsArchiveInsideTheOriginalReminderRequest() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Remind me to"])
        try await Task.sleep(for: .milliseconds(1050))
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 300,
                       "end_ms": 400, "delta": "Tell me what you'd like to be reminded to do."])
        try await finalizedCommand(h, start: 2000)
        XCTAssertFalse(h.adapter.beginFastAction(callId: "local", action: .archive))
    }

    @MainActor
    func testContinuedSpeechInvalidatesFastCommandAndEmptyCompletionDoesNotDiscardContext() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100, "end_ms": 200, "delta": "Don't"])
        try h.start()
        try h.lifecycle("response.completed")
        try await Task.sleep(for: .milliseconds(1050))
        try await finalizedCommand(h, start: 2000)
        XCTAssertFalse(h.adapter.beginFastAction(callId: "local", action: .archive))
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 2200, "end_ms": 2300, "delta": " until I say so"])
        XCTAssertFalse(h.adapter.beginFastAction(callId: "local", action: .archive))
    }

    @MainActor
    func testSyntheticResultRetainsDelegationWhenBrainEmittedNoTool() async throws {
        let h = Harness()
        try await finalizedCommand(h)
        XCTAssertTrue(h.adapter.beginFastAction(callId: "local", action: .archive))
        h.result("local")
        try h.lifecycle("response.completed", response: "r100")
        try h.lifecycle("response.created", response: "continuation")
        try h.function("late-continuation", response: "continuation")
        XCTAssertTrue(h.calls.isEmpty, "Continuation inherits the handled delegation and cannot archive again")
    }

    @MainActor
    func testBackendCompletionWaitsForInputAndAssistantTranscriptToSettle() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "You can archive this one."])
        try h.start()
        try h.lifecycle("response.completed")
        XCTAssertEqual(h.idleCount, 0, "Backend idle is not the end of the user's or speaker's turn")
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 300,
                       "end_ms": 700, "delta": "Okay, I'll handle that."])
        try await Task.sleep(for: .milliseconds(1050))
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.idleCount, 1, "Recheck when input and speech settle after backend completion")
    }

    @MainActor
    func testOldBackendCompletionCannotEndAnInterruptingUserTurn() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Archive this."])
        try h.start()
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 2000,
                       "end_ms": 2100, "delta": "Wait, keep it."])
        try h.lifecycle("response.completed")
        try await Task.sleep(for: .milliseconds(1050))
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.idleCount, 0, "An old delegation must not authorize recovery for a correction")
    }

    @MainActor
    func testRecoverySpeechExcludesPreviousTurnAndLateOldFragments() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 10,
                       "end_ms": 90, "delta": "Archived. Here is the previous email."])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "You can archive this."])
        try h.start()
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 50,
                       "end_ms": 90, "delta": " A delayed old fragment."])
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 300,
                       "end_ms": 400, "delta": "Okay, I'll handle "])
        try h.lifecycle("response.completed")
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1700,
                       "end_ms": 1800, "delta": "that."])
        try await Task.sleep(for: .milliseconds(1050))
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.adapter.recoveryContext?.speech, "Okay, I'll handle that.")
        XCTAssertEqual(h.idleCount, 1)
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.idleCount, 1, "Playback polling cannot repeat the same check")
    }

    @MainActor
    func testLateSpeechAfterAcceptedToolNeverBecomesMissingActionRecovery() async throws {
        let h = Harness()
        try await finalizedCommand(h)
        try h.function("accepted", response: "r100")
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 3000,
                       "end_ms": 3100, "delta": "What happened?"])
        h.result("accepted")
        try h.lifecycle("response.completed", response: "r100")
        try h.lifecycle("response.created", response: "continuation")
        try h.lifecycle("response.completed", response: "continuation")
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 3200,
                       "end_ms": 3300, "delta": "Okay, I'll handle that."])
        try await Task.sleep(for: .milliseconds(1050))
        h.adapter.observePlayback(0)
        XCTAssertNil(h.adapter.recoveryContext, "Old accepted work cannot authorize a new action")
        XCTAssertEqual(h.calls.map(\.id), ["accepted"])
        XCTAssertEqual(h.idleCount, 0)
    }

    @MainActor
    func testToolEvidenceSurvivesBackendContinuationAndLateTranscript() async throws {
        let h = Harness()
        try await finalizedCommand(h)
        try h.function("accepted", response: "r100")
        h.result("accepted")
        try h.lifecycle("response.completed", response: "r100")
        try h.lifecycle("response.created", response: "continuation")
        try h.lifecycle("response.completed", response: "continuation")
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 400,
                       "end_ms": 500, "delta": "Okay, I'll handle that."])
        try await Task.sleep(for: .milliseconds(850))
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.idleCount, 1)
        XCTAssertNil(h.adapter.recoveryContext, "No second write after the response flag was reset")
    }

    @MainActor
    func testFailedBackendStillDeliversAcceptedToolResultAndContinuesOnce() async throws {
        let h = Harness()
        try h.start()
        try h.function("accepted")
        h.result("accepted")
        try h.lifecycle("response.failed")
        XCTAssertEqual(h.sent.compactMap { $0["type"] as? String },
                       ["response.item.create", "response.create"])
        XCTAssertNil(h.adapter.recoveryContext, "Failure is not proof that the tool did not execute")
        XCTAssertEqual(h.calls.map(\.id), ["accepted"])
    }

    @MainActor
    func testClosedSessionCannotFinalizeInputOrRecoverFromLateEvents() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Archive this."])
        try h.start()
        h.adapter.close()
        try h.lifecycle("response.completed")
        try h.function("late")
        try await Task.sleep(for: .milliseconds(1050))
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.idleCount, 0)
        XCTAssertTrue(h.calls.isEmpty)
    }

    @MainActor
    func testDelayedDelegationCarriesOriginalInputTurnAcrossCardChange() throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Archive the visible email."])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 2000,
                       "end_ms": 2100, "delta": "Keep this next one."])
        try h.receive(["type": "session.delegation.created", "offset_ms": 500,
                       "delegation": ["id": "delayed", "response_id": "old"]])
        try h.receive(["type": "session.delegation.created", "offset_ms": 2200,
                       "delegation": ["id": "current", "response_id": "new"]])
        XCTAssertEqual(h.delegationTurns["delayed"], 1)
        XCTAssertEqual(h.delegationTurns["current"], 2)
    }

    @MainActor
    func testContinuityPromptArrivesOnceBeforeOpeningAndWaitsForAllAcknowledgments() throws {
        let h = Harness()
        h.adapter.prepareConversation()
        h.adapter.prepareConversation()
        XCTAssertTrue(h.sent.isEmpty, "Instructions wait for the session to start")
        try h.receive(["type": "session.started"])
        let clock = try XCTUnwrap(h.sent.last)
        XCTAssertEqual(clock["type"] as? String, "session.thinking.append")
        XCTAssertTrue((clock["content"] as? String)?.hasPrefix("Clock:") == true)
        let updates = Array(h.sent.dropLast())
        XCTAssertFalse(updates.isEmpty)
        XCTAssertTrue(updates.allSatisfy { $0["type"] as? String == "session.instructions.append" })
        XCTAssertTrue(updates.allSatisfy { ($0["content"] as? String ?? "").utf8.count <= 450 })
        XCTAssertEqual(updates.compactMap { $0["content"] as? String }.joined(),
                       LiveSessionAdapter.conversationContinuityInstructions)
        h.adapter.outbound(["type": "response.create"])
        for update in updates.dropLast() {
            try h.receive(["type": "session.instructions.appended", "client_event_id": update["event_id"]!])
        }
        XCTAssertEqual(h.sent.count, updates.count + 1, "Speech waits for the whole instruction, not the clock")
        try h.receive(["type": "session.instructions.appended", "client_event_id": updates.last!["event_id"]!])
        XCTAssertEqual(h.sent.last?["type"] as? String, "session.commentary.append")
        let count = h.sent.count
        h.adapter.prepareConversation()
        XCTAssertEqual(h.sent.count, count, "Later requests do not append another standing policy")
    }

    @MainActor
    func testCleanupOfferSpeaksBeforeBackendFinishesAndPreservesFullApprovalContext() throws {
        let step = try LiveEmailPresentationTests.encode(LiveEmailPresentationTests.cleanupStep(action: .unsubscribe))
        let line = try XCTUnwrap(LiveEmailPresentation.cleanupSpeakerLine(for: step))
        let h = Harness()
        try h.start()
        try h.function("archive-a")
        h.adapter.outbound(["type": "conversation.item.create", "item": [
            "type": "function_call_output", "call_id": "archive-a", "output": step]])
        h.adapter.presentPreparedEmail(line)
        let append = try XCTUnwrap(h.sent.last { $0["type"] as? String == "session.thinking.append" })
        XCTAssertEqual(append["content"] as? String, line)
        XCTAssertEqual(h.sent.last?["type"] as? String, "session.commentary.append")
        XCTAssertEqual(h.calls.map(\.id), ["archive-a"], "Speaking an offer must not execute its Dispatch")
        XCTAssertFalse(h.sent.contains { $0["type"] as? String == "response.create" })
        try h.lifecycle("response.completed")
        let result = try XCTUnwrap(h.sent.first { $0["type"] as? String == "response.item.create" })
        XCTAssertEqual((result["item"] as? [String: Any])?["output"] as? String, step,
                       "The backend retains the exact account, item, query, approval and Dispatch facts")
        h.adapter.close()
        let count = h.sent.count
        h.adapter.presentPreparedEmail(line)
        XCTAssertEqual(h.sent.count, count, "A closed session cannot speak an old offer")
    }

    @MainActor
    func testAnEmptyBriefKeepsBackendOnlyPolicyOutOfTheSpeakersContext() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        let policy = "For this checkpoint follow coaching.note. After yes speak lesson.speech exactly."
        h.adapter.outbound([
            "type": "conversation.item.create",
            "speaker_brief": "",
            "item": ["type": "message", "role": "system",
                     "content": [["type": "input_text", "text": policy]]],
        ])
        let backend = try XCTUnwrap(h.sent.first { $0["type"] as? String == "response.item.create" })
        XCTAssertEqual((backend["item"] as? [String: Any])?["content"] as? String, policy)
        XCTAssertTrue(h.sent.allSatisfy { $0["type"] as? String != "session.thinking.append" },
                      "Policy the speaker cannot act on must not reach it at all")
    }

    @MainActor
    func testSpeakExactlyRecitesOneLineAndIsRefusedAfterAFarewellOrClose() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        h.adapter.speakExactly("Quick tip: You're in your Feed right now. Was that helpful?")
        let request = try XCTUnwrap(h.sent.last)
        XCTAssertEqual(request["type"] as? String, "session.commentary.append")
        let content = try XCTUnwrap(request["content"] as? String)
        XCTAssertTrue(content.hasPrefix("Say exactly: Quick tip: You're in your Feed right now."), content)
        XCTAssertTrue(content.contains("call no tool"), content)

        h.adapter.speakExactly("")
        XCTAssertEqual(h.sent.last?["content"] as? String, content, "An empty line is not a recitation")

        h.adapter.beginFarewell()
        let afterFarewell = h.sent.count
        h.adapter.speakExactly("Quick tip: too late.")
        XCTAssertEqual(h.sent.count, afterFarewell, "A farewell owns the rest of the call")

        h.adapter.close()
        let afterClose = h.sent.count
        h.adapter.speakExactly("Quick tip: later still.")
        XCTAssertEqual(h.sent.count, afterClose)
    }

    @MainActor
    func testARecitationWaitsForItsContextToBeAcknowledged() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        h.adapter.outbound([
            "type": "conversation.item.create",
            "item": ["type": "message", "role": "system",
                     "content": [["type": "input_text", "text": "A checkpoint."]]],
        ])
        let append = try XCTUnwrap(h.sent.last { $0["type"] as? String == "session.thinking.append" })
        h.adapter.speakExactly("Quick tip: Was that helpful?")
        XCTAssertFalse(h.sent.contains { $0["type"] as? String == "session.commentary.append" })
        try h.receive(["type": "session.thinking.appended", "client_event_id": append["event_id"]!])
        XCTAssertEqual(h.sent.last?["type"] as? String, "session.commentary.append")
    }

    /// The recorded stall: "You can archive" → "Okay, archiving that." and no delegation, so
    /// `.liveBackendIdle` could never fire and the feed waited for the user to speak again.
    @MainActor
    func testAsideThatEndsInSpeechWithoutDelegationSignalsAfterItSettles() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "You can archive"])
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 300,
                       "end_ms": 700, "delta": "Okay, archiving that."])
        try await Task.sleep(for: .milliseconds(1050))
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.unworkedSpeech, [], "Speech must settle longer than the idle recheck first")
        try await Task.sleep(for: .milliseconds(600))
        h.adapter.observePlayback(0)
        XCTAssertTrue(h.unworkedSpeech.isEmpty)
        XCTAssertTrue(h.adapter.hasUnresolvedQueueAction)
        XCTAssertEqual(h.idleCount, 0)
        h.adapter.observePlayback(0)
        XCTAssertTrue(h.unworkedSpeech.isEmpty, "Phrase-based speech recovery is superseded")
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 3000,
                       "end_ms": 3100, "delta": "Wait."])
        try await Task.sleep(for: .milliseconds(1700))
        h.adapter.observePlayback(0)
        XCTAssertTrue(h.unworkedSpeech.isEmpty, "Recovery is tracked independently of assistant speech")
    }

    @MainActor
    func testADelegationForTheTurnSuppressesTheUnworkedSignal() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "You can archive."])
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 300,
                       "end_ms": 700, "delta": "Okay, archiving that."])
        try h.receive(["type": "session.delegation.created",
                       "delegation": ["id": "d1", "response_id": "r1"]])
        try await Task.sleep(for: .milliseconds(1700))
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.unworkedSpeech, [], "A delegated turn is the backend's to finish")
    }

    @MainActor
    func testReportedPhraseStartsAtInputCompletionWithoutSpeechOrDelegation() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Awesome. Can you archive this one for me, please"])
        XCTAssertFalse(h.adapter.beginFastAction(callId: "early", action: .archive))
        try await Task.sleep(for: .milliseconds(1050))
        XCTAssertTrue(h.adapter.beginFastAction(callId: "local", action: .archive))
        XCTAssertFalse(h.adapter.hasUnresolvedQueueAction)
        XCTAssertTrue(h.sent.isEmpty, "Starting the action requires no new model request or context round trip")
        XCTAssertFalse(h.adapter.beginFastAction(callId: "duplicate", action: .archive))
    }

    @MainActor
    func testSilentUnstartedActionSignalsRecoveryAndNewInputDisarmsIt() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Please archive it for me"])
        try await Task.sleep(for: .milliseconds(2600))
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.queueRecovery, [false])
        XCTAssertTrue(h.unworkedSpeech.isEmpty)
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 3000,
                       "end_ms": 3100, "delta": "Actually don't."])
        XCTAssertFalse(h.adapter.hasUnresolvedQueueAction)
        h.adapter.close()
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.queueRecovery, [false])
    }

    @MainActor
    func testProseOnlyDelegationStillLeavesTheArchiveUnresolved() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Can you please archive this email"])
        try h.receive(["type": "session.delegation.created",
                       "delegation": ["id": "d1", "response_id": "r1"]])
        try await Task.sleep(for: .milliseconds(2600))
        h.adapter.observePlayback(0)
        XCTAssertTrue(h.queueRecovery.isEmpty, "Never race an active backend")
        try h.lifecycle("response.completed")
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.queueRecovery, [false], "A completed delegation is not an executed action")
        h.adapter.close()
    }

    @MainActor
    func testReadBeforeInputSettlesDoesNotResolveAnArchiveRequest() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Archive this one for me, please"])
        try h.start()
        try h.function("read", name: "gmail_get_message")
        try await Task.sleep(for: .milliseconds(1050))
        XCTAssertTrue(h.adapter.hasUnresolvedQueueAction, "A read is not archive execution")
        h.adapter.observePlayback(0)
        XCTAssertTrue(h.queueRecovery.isEmpty, "Never race the in-flight read")
        h.adapter.close()
    }

    @MainActor
    func testArchiveBeforeInputSettlesCannotRearmRecovery() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Archive this one for me, please"])
        try h.start()
        try h.function("archive")
        try await Task.sleep(for: .milliseconds(1050))
        XCTAssertFalse(h.adapter.hasUnresolvedQueueAction)
        h.adapter.close()
    }

    @MainActor
    func testBackchannelDoesNotPoisonImmediateFastArchive() async throws {
        for filler in ["Mm-hmm", "�", "Um"] {
            let h = Harness()
            try h.receive(["type": "session.started"])
            try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                           "end_ms": 200, "delta": filler])
            try await Task.sleep(for: .milliseconds(1050))
            try h.receive(["type": "session.input_transcript.delta", "start_ms": 2000,
                           "end_ms": 2100, "delta": "You can archive"])
            try await Task.sleep(for: .milliseconds(1050))
            XCTAssertTrue(h.adapter.beginFastAction(callId: "local", action: .archive), filler)
            XCTAssertTrue(h.sent.isEmpty, "The shortcut must require no backend request")
            XCTAssertFalse(h.adapter.hasUnresolvedQueueAction)
            h.adapter.close()
        }
    }

    @MainActor
    func testUnrecognizedRequestArmsRecoveryWithoutAssistantSpeech() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Get this out of my inbox, please"])
        XCTAssertNil(LiveFastAction.parse("Get this out of my inbox, please"))
        try await Task.sleep(for: .milliseconds(2600))
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.queueRecovery, [false])
        XCTAssertTrue(h.adapter.recoverUnworkedRequest(anchor: .init(step: "email-a", profileId: "personal", revision: 1)))
        XCTAssertEqual(h.sent.compactMap { $0["type"] as? String },
                       ["session.thinking.append", "response.item.create", "response.item.create", "response.create"])
        XCTAssertFalse(h.adapter.recoverUnworkedRequest(anchor: .init(step: "email-a", profileId: "personal", revision: 1)))
        h.adapter.close()
    }

    @MainActor
    func testAnsweredQuestionDoesNotArmRecovery() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Where are they located"])
        try await Task.sleep(for: .milliseconds(1050))
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1300,
                       "end_ms": 1500, "delta": "They're based in London, UK."])
        try await Task.sleep(for: .milliseconds(1550))
        h.adapter.observePlayback(0)
        XCTAssertFalse(h.adapter.hasUnresolvedQueueAction)
        XCTAssertTrue(h.queueRecovery.isEmpty, "A second assessment would say the answer again")
        XCTAssertEqual(h.unworkedSpeech, ["They're based in London, UK."], "The aside still returns to the email")
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 5000,
                       "end_ms": 5100, "delta": "Um"])
        try await Task.sleep(for: .milliseconds(2600))
        h.adapter.observePlayback(0)
        XCTAssertTrue(h.queueRecovery.isEmpty, "An answered question must not ride along into a later turn")
        h.adapter.close()
    }

    @MainActor
    func testUnansweredQuestionStillRecovers() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Where are they located"])
        try await Task.sleep(for: .milliseconds(2600))
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.queueRecovery, [false], "Silence is not an answer")
        h.adapter.close()
    }

    @MainActor
    func testAcknowledgementOrOverlappingSpeechDoesNotAnswerAQuestion() async throws {
        for (start, said) in [(1300.0, "Let me check."), (150.0, "Next, Alex Example confirms the retention setting.")] {
            let h = Harness()
            try h.receive(["type": "session.started"])
            try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                           "end_ms": 200, "delta": "Where are they located"])
            try h.receive(["type": "session.output_transcript.delta", "start_ms": start,
                           "end_ms": start + 200, "delta": said])
            try await Task.sleep(for: .milliseconds(2600))
            h.adapter.observePlayback(0)
            XCTAssertEqual(h.queueRecovery, [false], said)
            h.adapter.close()
        }
    }

    @MainActor
    func testOnlyAFinishedAnsweringSentenceAnswersAQuestion() {
        for said in ["They're based in London, UK.", "Checking. It doesn't say."] {
            XCTAssertTrue(LiveSessionAdapter.answersQuestion(said), said)
        }
        for said in ["Checking.", "Let me check.", "Sure.", "They're based in Lon", "Which company do you mean?",
                     "There are two companies mentioned. Which one do you mean?", "Okay, I'll take care of that.",
                     "That's a good question.", "Yes, of course.", "Okay, got it."] {
            XCTAssertFalse(LiveSessionAdapter.answersQuestion(said), said)
        }
    }

    @MainActor
    func testQuestionBackToTheUserDoesNotRecover() async throws {
        for (said, expected) in [("What would you like me to do with that email?", [Bool]()),
                                 ("Archived. Anything else?", [false])] {
            let h = Harness()
            try h.receive(["type": "session.started"])
            try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                           "end_ms": 200, "delta": "She's gonna"])
            try await Task.sleep(for: .milliseconds(1050))
            try h.receive(["type": "session.output_transcript.delta", "start_ms": 1300,
                           "end_ms": 1500, "delta": said])
            try await Task.sleep(for: .milliseconds(1550))
            h.adapter.observePlayback(0)
            XCTAssertEqual(h.queueRecovery, expected, said)
            h.adapter.close()
        }
    }

    @MainActor
    func testClarificationAcrossDeltasDoesNotRecoverOrAnswer() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Where are they located"])
        try await Task.sleep(for: .milliseconds(1050))
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1300,
                       "end_ms": 1500, "delta": "There are two companies mentioned."])
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1500,
                       "end_ms": 1800, "delta": " Which one do you mean?"])
        try await Task.sleep(for: .milliseconds(1550))
        h.adapter.observePlayback(0)
        XCTAssertTrue(h.queueRecovery.isEmpty, "A second assessment would ask it again")
        XCTAssertFalse(LiveSessionAdapter.answersQuestion("There are two companies mentioned. Which one do you mean?"))
        h.adapter.close()
    }

    @MainActor
    func testHalfAReplyAfterTheDeadlineWaitsRatherThanRetires() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Where are they located"])
        try await Task.sleep(for: .milliseconds(2600))
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 2800,
                       "end_ms": 3000, "delta": "There are two companies mentioned."])
        h.adapter.observePlayback(0)
        XCTAssertTrue(h.queueRecovery.isEmpty, "Recovery mid-answer would answer the question twice")
        XCTAssertTrue(h.adapter.hasUnresolvedQueueAction, "Half a reply cannot retire the question")
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 3000,
                       "end_ms": 3300, "delta": " Which one do you mean?"])
        try await Task.sleep(for: .milliseconds(850))
        h.adapter.observePlayback(0)
        XCTAssertTrue(h.queueRecovery.isEmpty, "The finished reply asked the user")
        h.adapter.close()
    }

    @MainActor
    func testQuestionStillBeingAnsweredAtTheDeadlineIsNotAnsweredTwice() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "When are the times"])
        try await Task.sleep(for: .milliseconds(1050))
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1300,
                       "end_ms": 1800, "delta": "It says either of these times, Friday,"])
        try await Task.sleep(for: .milliseconds(1550))
        h.adapter.observePlayback(0.1)
        XCTAssertTrue(h.queueRecovery.isEmpty, "Jo is still answering")
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 1800,
                       "end_ms": 2400, "delta": " but I don't have the actual times."])
        h.adapter.observePlayback(0.1)
        XCTAssertTrue(h.queueRecovery.isEmpty, "Jo is still answering")
        try await Task.sleep(for: .milliseconds(850))
        h.adapter.observePlayback(0)
        XCTAssertTrue(h.queueRecovery.isEmpty, "A finished answer retires the question")
        XCTAssertFalse(h.adapter.hasUnresolvedQueueAction)
        h.adapter.close()
    }

    @MainActor
    func testQuestionAnswerAudibleBeforeItsTranscriptStillHolds() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "When are the times"])
        try await Task.sleep(for: .milliseconds(2600))
        h.adapter.observePlayback(0.1)
        XCTAssertTrue(h.queueRecovery.isEmpty, "Jo is audibly answering before its transcript lands")
        h.adapter.close()
    }

    @MainActor
    func testDroppedRequestRecoversAfterSpeechSettles() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Please archive it for me"])
        try await Task.sleep(for: .milliseconds(2600))
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 2800,
                       "end_ms": 3000, "delta": "Sure, archiving"])
        h.adapter.observePlayback(0.1)
        XCTAssertTrue(h.queueRecovery.isEmpty, "Recovery cannot race the spoken acknowledgement")
        try await Task.sleep(for: .milliseconds(850))
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.queueRecovery, [false], "Speech does not prove the action executed")
        h.adapter.close()
    }

    @MainActor
    func testQuestionAnsweredOnlyWithAnAcknowledgementRecoversOnceSettled() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "When are the times"])
        try await Task.sleep(for: .milliseconds(2600))
        try h.receive(["type": "session.output_transcript.delta", "start_ms": 2800,
                       "end_ms": 3000, "delta": "Let me check."])
        h.adapter.observePlayback(0.1)
        XCTAssertTrue(h.queueRecovery.isEmpty)
        try await Task.sleep(for: .milliseconds(850))
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.queueRecovery, [false], "An acknowledgement does not answer the question")
        h.adapter.close()
    }

    @MainActor
    func testOnlyAQuestionAsksTheUser() {
        for said in ["What would you like me to do with that email?", "Okay. Which label would you like me to apply?",
                     "Do you mean this email, or a different one? "] {
            XCTAssertTrue(LiveSessionAdapter.asksUser(said), said)
        }
        for said in ["", "Hold on.", "Archived. Anything else?", "Which one? I can archive",
                     "I only heard \"she's gonna.\" Could you finish?"] {
            XCTAssertFalse(LiveSessionAdapter.asksUser(said), said)
        }
    }

    @MainActor
    func testQuestionAfterDroppedCommandStillArmsRecovery() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Get this out of my inbox"])
        try await Task.sleep(for: .milliseconds(1050))
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 1500,
                       "end_ms": 1600, "delta": "Is it done?"])
        try await Task.sleep(for: .milliseconds(2600))
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.queueRecovery, [false])
        h.adapter.close()
    }

    @MainActor
    func testRecoveryIncludesPreparedCalendarOffer() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Deal with this one"])
        try await Task.sleep(for: .milliseconds(2600))
        h.adapter.observePlayback(0)
        let prepared = #"{"item":{"id":"email-a","bodySummary":"Maya requests a meeting.","suggestedQuestion":"Want me to find a time?"}}"#
        XCTAssertTrue(h.adapter.recoverUnworkedRequest(
            anchor: .init(step: "email-a", profileId: "personal", revision: 1), preparedStep: prepared))
        let item = try XCTUnwrap(h.sent.compactMap { $0["item"] as? [String: Any] }
            .first { $0["role"] as? String == "user" })
        let content = try XCTUnwrap(item["content"] as? String)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: String])
        XCTAssertEqual(envelope["pinned_feed"], prepared)
        h.adapter.close()
    }

    @MainActor
    func testRecoveryAndLateDelegationHaveOnlyOneExecutionOwner() async throws {
        for nativeWins in [false, true] {
            let h = Harness()
            try h.receive(["type": "session.started"])
            try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                           "end_ms": 200, "delta": "Get this out of my inbox"])
            try await Task.sleep(for: .milliseconds(1050))
            XCTAssertTrue(h.adapter.recoverUnworkedRequest(anchor: .init(step: "email-a", profileId: "personal", revision: 1)))
            try h.lifecycle("response.created", response: "recovery")
            try h.receive(["type": "session.delegation.created", "offset_ms": 100,
                           "delegation": ["id": "native", "response_id": "native-response"]])
            let first = nativeWins ? "native-response" : "recovery"
            let second = nativeWins ? "recovery" : "native-response"
            try h.function("winner", response: first)
            try h.function("loser", response: second)
            XCTAssertEqual(h.calls.map(\.id), ["winner"])
            h.result("winner")
            XCTAssertEqual(h.calls.map(\.id), ["winner"], "Late backend work must not execute twice")
            XCTAssertEqual(h.calls.first?.recoveryAnchor?.profileId, "personal")
            XCTAssertEqual(h.calls.first?.recoveryAnchor?.step, "email-a")
            XCTAssertFalse(h.adapter.hasUnresolvedQueueAction)
            try h.lifecycle("response.completed", response: first)
            try h.lifecycle("response.completed", response: second)
            try h.lifecycle("response.created", response: "continuation")
            try h.function("followup", response: "continuation", name: "gmail_get_message")
            XCTAssertEqual(h.calls.map(\.id), ["winner", "followup"],
                           "Rejecting a duplicate must not steal the winning backend's continuation")
            h.adapter.close()
        }
    }

    @MainActor
    func testCorrectionPreventsOldRecoveryFromExecuting() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Get this out of my inbox"])
        try await Task.sleep(for: .milliseconds(1050))
        XCTAssertTrue(h.adapter.recoverUnworkedRequest(anchor: .init(step: "email-a", profileId: "personal", revision: 1)))
        try h.lifecycle("response.created", response: "recovery")
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 3000,
                       "end_ms": 3100, "delta": "Actually keep it"])
        try h.function("stale", response: "recovery")
        XCTAssertTrue(h.calls.isEmpty)
        h.adapter.close()
    }

    @MainActor
    func testExplicitNoActionDecisionDisarmsRecoveryAndLateDelegation() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "That makes sense"])
        try await Task.sleep(for: .milliseconds(1050))
        XCTAssertTrue(h.adapter.recoverUnworkedRequest(anchor: .init(step: "email-a", profileId: "personal", revision: 1)))
        let id = try XCTUnwrap(h.delegationTurns.keys.first)
        try h.lifecycle("response.created", response: "recovery")
        let text = "{\"request_id\":\"\(id)\",\"disposition\":\"no_action\",\"message\":\"\"}"
        try h.receive(["type": "response.event", "event": ["type": "response.completed",
            "response": ["id": "recovery", "output": [["type": "message", "content": [
                ["type": "output_text", "text": text]]]]]]])
        XCTAssertEqual(h.adapter.currentRequestDecision, .noAction)
        XCTAssertFalse(h.adapter.hasUnresolvedQueueAction)
        try h.receive(["type": "session.delegation.created", "offset_ms": 100,
                       "delegation": ["id": "late", "response_id": "late-response"]])
        try h.function("late", response: "late-response")
        XCTAssertTrue(h.calls.isEmpty)
        h.adapter.close()
    }

    @MainActor
    func testStreamedClarificationWithEmptyTerminalOutputWaitsForAnswer() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Get this"])
        try await Task.sleep(for: .milliseconds(2600))
        h.adapter.observePlayback(0)
        XCTAssertTrue(h.adapter.recoverUnworkedRequest(anchor: .init(step: "email-a", profileId: "personal", revision: 1)))
        let id = try XCTUnwrap(h.delegationTurns.keys.first)
        try h.receive(["type": "session.delegation.created", "offset_ms": 100,
                       "delegation": ["id": "native", "response_id": "recovery"]])
        try h.lifecycle("response.created", response: "recovery")
        let text = "{\"request_id\":\"\(id)\",\"disposition\":\"clarification\",\"message\":\"Archive or skip?\"}"
        for fragment in [String(text.prefix(20)), String(text.dropFirst(20))] {
            try h.receive(["type": "response.event", "delegation_id": "native", "event": [
                "type": "response.output_text.delta", "output_index": 0, "content_index": 0, "delta": fragment]])
        }
        XCTAssertNil(h.adapter.currentRequestDecision, "Partial output must wait for successful completion")
        try h.lifecycle("response.completed", response: "recovery")
        XCTAssertEqual(h.adapter.currentRequestDecision, .clarification)
        XCTAssertFalse(h.adapter.hasUnresolvedQueueAction)
        XCTAssertTrue(h.adapter.shouldHoldFeedForRequest)
        try await Task.sleep(for: .milliseconds(5100))
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.queueRecovery, [false], "A valid clarification must not time out as failure")
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 4000,
                       "end_ms": 4100, "delta": "Archive it"])
        XCTAssertNil(h.adapter.currentRequestDecision)
        h.adapter.close()
    }

    @MainActor
    func testStreamedDecisionRequiresMatchingRequestAndCurrentTurn() async throws {
        for mode in ["valid", "wrong-request", "stale", "failed", "unrelated"] {
            let h = Harness()
            try h.receive(["type": "session.started"])
            try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                           "end_ms": 200, "delta": "Get this"])
            try await Task.sleep(for: .milliseconds(1050))
            XCTAssertTrue(h.adapter.recoverUnworkedRequest(anchor: .init(step: "email-a", profileId: "personal", revision: 1)))
            let id = try XCTUnwrap(h.delegationTurns.keys.first)
            try h.lifecycle("response.created", response: "recovery")
            let request = mode == "wrong-request" ? "other" : id
            let text = "{\"request_id\":\"\(request)\",\"disposition\":\"no_action\",\"message\":\"\"}"
            try h.receive(["type": "response.event", "delegation_id": mode == "unrelated" ? "other" : id,
                           "event": ["type": "response.output_item.done", "output_index": 0,
                            "item": ["type": "message", "content": [["type": "output_text", "text": text]]]]])
            if mode == "stale" {
                try h.receive(["type": "session.input_transcript.delta", "start_ms": 4000,
                               "end_ms": 4100, "delta": "Actually keep it"])
            }
            try h.lifecycle(mode == "failed" ? "response.failed" : "response.completed", response: "recovery")
            XCTAssertEqual(h.adapter.currentRequestDecision, mode == "valid" ? .noAction : nil, mode)
            h.adapter.close()
        }
    }

    @MainActor
    func testLocalCheckpointAnswerDoesNotTriggerAssessment() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Yes"])
        try await Task.sleep(for: .milliseconds(1050))
        h.adapter.resolveLocalInput()
        XCTAssertFalse(h.adapter.hasUnresolvedQueueAction)
        XCTAssertFalse(h.adapter.recoverUnworkedRequest(anchor: .init(step: "email-a", profileId: "personal", revision: 1)))
        h.adapter.close()
    }

    @MainActor
    func testRecoveryWaitsForPlaybackEvenBeforeItsTranscript() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Get this out of my inbox"])
        try await Task.sleep(for: .milliseconds(2600))
        h.adapter.observePlayback(0.1)
        XCTAssertTrue(h.queueRecovery.isEmpty)
        try await Task.sleep(for: .milliseconds(850))
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.queueRecovery, [false])
        h.adapter.close()
    }

    @MainActor
    func testAcknowledgementWithoutDecisionCannotResolveRecovery() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Get this out of my inbox"])
        try await Task.sleep(for: .milliseconds(2600))
        h.adapter.observePlayback(0)
        XCTAssertTrue(h.adapter.recoverUnworkedRequest(anchor: .init(step: "email-a", profileId: "personal", revision: 1)))
        try h.lifecycle("response.created", response: "recovery")
        try h.receive(["type": "response.event", "event": ["type": "response.completed",
            "response": ["id": "recovery", "output": [["type": "message", "content": [
                ["type": "output_text", "text": "Sure, I'll take care of that."]]]]]]])
        XCTAssertNil(h.adapter.currentRequestDecision)
        XCTAssertTrue(h.adapter.hasUnresolvedQueueAction)
        XCTAssertTrue(h.adapter.shouldHoldFeedForRequest)
        try await Task.sleep(for: .milliseconds(5100))
        h.adapter.observePlayback(0)
        XCTAssertEqual(h.queueRecovery, [false, true])
        XCTAssertTrue(h.adapter.shouldHoldFeedForRequest, "Exhaustion must not restart the email loop")
        h.adapter.close()
    }

    @MainActor
    func testCompletedNormalToolWorkDoesNotTriggerAnotherAssessment() async throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.input_transcript.delta", "start_ms": 100,
                       "end_ms": 200, "delta": "Turn that rule on"])
        try await Task.sleep(for: .milliseconds(1050))
        try h.start()
        try h.function("rule", name: "set_rule")
        h.result("rule")
        try h.lifecycle("response.completed")
        try h.lifecycle("response.created", response: "continuation")
        try h.lifecycle("response.completed", response: "continuation")
        XCTAssertFalse(h.adapter.hasUnresolvedQueueAction)
        XCTAssertFalse(h.adapter.recoverUnworkedRequest(anchor: .init(step: "email-a", profileId: "personal", revision: 1)))
        h.adapter.close()
    }

    @MainActor
    func testRepeatedQueueNoteReachesBackendInFullOnlyEveryInterval() throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        let note = String(repeating: "Archive is never the default queue action. ", count: 20)
        for index in 0..<12 {
            let step = String(decoding: try JSONSerialization.data(withJSONObject: [
                "item": ["id": "email-\(index)"], "note": note, "next": ["note": "short"]]), as: UTF8.self)
            h.adapter.outbound(["type": "conversation.item.create", "speaker_brief": "Next.", "item": [
                "type": "message", "role": "system", "content": [["type": "input_text", "text": "Step:\n" + step]]]])
        }
        let notes = try h.sent.filter { $0["type"] as? String == "response.item.create" }.map { payload -> [String: Any] in
            let content = try XCTUnwrap((payload["item"] as? [String: Any])?["content"] as? String)
            let json = try XCTUnwrap(content.components(separatedBy: "Step:\n").last)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        XCTAssertEqual(notes.count, 12)
        let full = notes.indices.filter { notes[$0]["note"] as? String == note }
        XCTAssertEqual(full, [0, LiveSessionAdapter.noteResendInterval], "Full on first sight, then once per interval")
        XCTAssertTrue(notes.indices.filter { !full.contains($0) }
            .allSatisfy { notes[$0]["note"] as? String == LiveSessionAdapter.noteReference })
        XCTAssertTrue(notes.allSatisfy { ($0["next"] as? [String: Any])?["note"] as? String == "short" },
                      "A short note is never replaced")
    }

    @MainActor
    func testInterruptionGuidancePrecedesQueuedSpeechWithoutAClientCancel() throws {
        let h = Harness()
        h.adapter.outbound(["type": "response.create", "response": ["instructions": "Say hello."]])
        XCTAssertTrue(h.sent.isEmpty)
        h.adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.started"]))
        XCTAssertEqual(h.sent.first?["type"] as? String, "session.instructions.append")
        XCTAssertEqual(h.sent.first?["content"] as? String, LiveSessionAdapter.interruptionGuidance)
        XCTAssertFalse(h.sent.contains { $0["type"] as? String == "session.commentary.append" })
        for instruction in h.sent where instruction["type"] as? String == "session.instructions.append"
            || instruction["type"] as? String == "session.thinking.append" {
            try h.receive(["type": "session.instructions.appended", "client_event_id": try XCTUnwrap(instruction["event_id"])])
        }
        XCTAssertTrue(h.sent.contains { $0["type"] as? String == "session.commentary.append" })
    }

    @MainActor
    func testBargeInStopLineIsAppendedOncePerUserTurn() throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        let stops = { h.sent.filter { ($0["content"] as? String)?.hasPrefix("Stop speaking now") == true }.count }
        h.adapter.outbound(["type": "response.cancel"])
        h.adapter.outbound(["type": "output_audio_buffer.clear"])
        XCTAssertEqual(stops(), 1)
        try h.receive(["type": "session.input_transcript.delta", "delta": "wait", "start_ms": 1000, "end_ms": 1500])
        h.adapter.outbound(["type": "response.cancel"])
        XCTAssertEqual(stops(), 2, "A new user turn gets its own stop line")
    }

    @MainActor
    func testFirstSpeechAfterUserInputIsTimedOncePerTurn() throws {
        let h = Harness()
        try h.receive(["type": "session.started"])
        try h.receive(["type": "session.output_transcript.delta", "delta": "Hi.", "start_ms": 100, "end_ms": 400])
        XCTAssertEqual(h.firstSpeech, [], "The opening precedes any user turn")
        try h.receive(["type": "session.input_transcript.delta", "delta": "archive it", "start_ms": 1000, "end_ms": 2000])
        try h.receive(["type": "session.output_transcript.delta", "delta": "Okay,", "start_ms": 2600, "end_ms": 2900])
        try h.receive(["type": "session.output_transcript.delta", "delta": " archiving.", "start_ms": 2900, "end_ms": 3300])
        try h.receive(["type": "session.input_transcript.delta", "delta": "next", "start_ms": 5000, "end_ms": 6000])
        try h.receive(["type": "session.output_transcript.delta", "delta": "Before", "start_ms": 5500, "end_ms": 5800])
        try h.receive(["type": "session.output_transcript.delta", "delta": "Next,", "start_ms": 6400, "end_ms": 6700])
        XCTAssertEqual(h.firstSpeech, [600, 400], "Speech that began before the user finished is not the reply")
    }

    @MainActor
    func testBackendUsageAndContextRatioAreReported() throws {
        let h = Harness()
        try h.start()
        try h.receive(["type": "response.event", "delegation_id": "d1", "event": ["type": "response.completed",
            "response": ["id": "r1", "output": [],
                         "usage": ["input_tokens": 41_000, "input_tokens_details": ["cached_tokens": 39_000]]]]])
        try h.receive(["type": "session.usage.updated", "usage": ["seconds": 12, "context_window": ["usage_ratio": 0.42]]])
        XCTAssertEqual(h.usage, [ResponseUsage(inputTokens: 41_000, cachedTokens: 39_000)])
        XCTAssertEqual(h.usage.first?.cachedPercent, 95)
        XCTAssertEqual(h.contextRatios, [0.42])
    }

    @MainActor
    func testBrainStepCarriesItsToolsAndTokens() throws {
        let h = Harness()
        try h.receive(["type": "session.input_transcript.delta", "delta": "reply yes", "start_ms": 0, "end_ms": 900])
        try h.start()
        try h.function("c1", name: "send_email")
        try h.receive(["type": "response.event", "delegation_id": "d1", "event": ["type": "response.completed",
            "response": ["id": "r1", "output": [],
                         "usage": ["input_tokens": 18_000, "output_tokens": 240,
                                   "input_tokens_details": ["cached_tokens": 17_000]]]]])
        let step = try XCTUnwrap(h.brainSteps.first)
        XCTAssertEqual(step.tools, ["send_email"])
        XCTAssertEqual(step.inputTokens, 18_000)
        XCTAssertEqual(step.cachedTokens, 17_000)
        XCTAssertEqual(step.outputTokens, 240)
        XCTAssertNotNil(step.handoffMs)
        XCTAssertNil(step.userSpokeMs, "Nobody spoke after the hand-off")
    }

}
