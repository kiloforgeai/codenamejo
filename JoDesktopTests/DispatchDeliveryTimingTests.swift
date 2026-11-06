import XCTest
import FactoryKit
@testable import CodenameJo

@MainActor
final class DispatchDeliveryTimingTests: XCTestCase {
    func testResultHeldDuringUserSpeechLogsCompletionToOutputStart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = VoiceDiagnostics(directory: folder)
        let client = FullDuplexVoiceClient()
        client.diagnostics = log.begin(engine: "live")
        client.userSpeaking = true
        let job = UUID()
        let turn = UUID()
        client.dispatchHistory[job] = (turn, "Private fixture request")
        client.pendingReports = [.init(kind: .dispatch, jobId: job,
            task: "Private fixture request", text: "Private fixture answer", ok: true,
            landedAt: .now, finishedAt: .now.advanced(by: .seconds(-2)),
            delivery: .nextQuietBeat, origin: nil)]
        var delivered: [UUID] = []
        client.onJobDelivered = { delivered.append($0) }
        var reserved = false
        XCTAssertFalse(FullDuplexVoiceClient.reserveDispatchReportTurn(responseInFlight: &reserved,
            userSpeaking: true, assistantAudible: false, foregroundToolPending: false))
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertNil(client.pendingJobSpeech)
        client.userSpeaking = false
        XCTAssertTrue(FullDuplexVoiceClient.reserveDispatchReportTurn(responseInFlight: &reserved,
            userSpeaking: false, assistantAudible: false, foregroundToolPending: false))
        client.injectDispatchReport(client.pendingReports.removeFirst(), speak: true)
        XCTAssertEqual(delivered, [job])
        XCTAssertEqual(client.pendingJobSpeech?.id, job)
        client.handle(.event(.outputAudioStarted))
        client.handle(.event(.outputAudioStarted))
        let data = try await log.snapshot()
        let rows = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        let started = rows.filter { $0["event"] as? String == "jobSpeechStarted" }
        XCTAssertEqual(started.count, 1)
        let fields = try XCTUnwrap(started.first?["fields"] as? [String: String])
        XCTAssertEqual(fields["job_id"], job.uuidString)
        XCTAssertEqual(fields["turn_id"], turn.uuidString)
        XCTAssertGreaterThanOrEqual(Int(fields["duration_ms"] ?? "") ?? 0, 2000)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Private fixture"))
    }

    func testInterruptedResultCannotClaimTheNextTurnsAudio() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = VoiceDiagnostics(directory: folder)
        let client = FullDuplexVoiceClient()
        client.diagnostics = log.begin(engine: "live")
        client.pendingJobSpeech = .init(id: UUID(), finishedAt: .now)
        client.handle(.liveUserActivity)
        client.handle(.event(.outputAudioStarted))
        let text = String(decoding: try await log.snapshot(), as: UTF8.self)
        XCTAssertTrue(text.contains("jobSpeechCancelled"))
        XCTAssertFalse(text.contains("jobSpeechStarted"))
    }
}

@MainActor
final class TaskReceiptTests: XCTestCase {
    var folder: URL!
    var store: DispatchJobStore!
    var context: LocalContextStore!

    override func setUp() async throws {
        Container.shared.manager.push()
        ProfileRuntime.install(nil)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let backend = BackendService(restoringSession: false)
        backend.userId = "receipt-user"
        Container.shared.backend.register { backend }
        context = LocalContextStore(url: folder.appendingPathComponent("context.sqlite"))
        let context = context!
        Container.shared.localContext.register { context }
        store = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        let store = store!
        Container.shared.dispatchJobs.register { store }
    }

    override func tearDown() async throws {
        try? context.dbPool?.close()
        Scope.singleton.reset()
        Container.shared.manager.pop()
        ProfileRuntime.install(nil)
        try? FileManager.default.removeItem(at: folder)
    }

    func finished(_ state: String, account: String = "original@example.test", sender: String = "Original D") async -> UUID {
        let id = UUID()
        await store.begin(id: id, task: "Label and archive", profileId: nil,
            origin: .init(account: account, messageID: id.uuidString, threadID: "thread", sender: sender, subject: "Same subject"))
        await store.finish(id, state: state, result: "Verified result for \(sender).", reportBack: true)
        return id
    }

    func report(_ id: UUID, revision: Int = 1) -> FullDuplexVoiceClient.DispatchReport {
        .init(kind: .dispatch, jobId: id, task: "Stale request", text: "Still running on F", ok: true,
            landedAt: .now, delivery: .nextQuietBeat, origin: nil, revision: revision)
    }

    func start(_ adapter: LiveSessionAdapter, wire: () -> [[String: Any]]) throws {
        adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.started"]))
        for item in wire() where item["type"] as? String == "session.instructions.append" {
            adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.instructions.appended", "client_event_id": item["event_id"]!]))
        }
    }

    func testEveryTerminalReceiptUsesStoredOriginAndLatestOutcome() async throws {
        let client = FullDuplexVoiceClient()
        client.standingStep = #"{"item":{"id":"F","account":"foreground@example.test","from":"Current F","subject":"Same subject"}}"#
        for state in ["done", "failed", "partial", "unknown", "awaiting_input"] {
            let id = await finished(state)
            let receipt = try XCTUnwrap(client.currentTaskReceipt(report(id)))
            XCTAssertEqual(receipt.state, state)
            let spoken = try XCTUnwrap(receipt.spokenReceipt)
            XCTAssertTrue(spoken.contains("Original D"))
            XCTAssertFalse(spoken.contains("original@example.test"))
            XCTAssertFalse(spoken.contains("Current F"))
            XCTAssertFalse(spoken.contains("running"))
        }
        let cancelled = await finished("cancelled")
        XCTAssertNil(client.currentTaskReceipt(report(cancelled)))
        XCTAssertTrue(store.existing(cancelled)?.spokenReceipt?.contains("cancelled") == true)
    }

    func testOldRevisionRunningTaskAndOtherProfileCannotSpeak() async throws {
        let id = await finished("failed")
        let client = FullDuplexVoiceClient()
        await store.acceptContext(id, context: .init(revision: 2, scope: "current_email", expects: "answer",
            authoredAt: Date(), timeZone: "UTC", input: "Corrected request"))
        XCTAssertNil(client.currentTaskReceipt(report(id)))
        XCTAssertNil(client.currentTaskReceipt(report(id, revision: 2)))
        await store.finish(id, state: "done", result: "Corrected result", reportBack: true, revision: 2)
        XCTAssertNotNil(client.currentTaskReceipt(report(id, revision: 2)))
        ProfileRuntime.install(.init(profileId: "other", isDefault: false, emails: []))
        XCTAssertNil(client.currentTaskReceipt(report(id, revision: 2)))
    }

    func testOutOfOrderIdenticalSubjectsKeepTheirAccountsAndSenders() async throws {
        let second = await finished("failed", account: "second@example.test", sender: "Second sender")
        let first = await finished("done", account: "first@example.test", sender: "First sender")
        let client = FullDuplexVoiceClient()
        for (id, account) in [(second, "second@example.test"), (first, "first@example.test")] {
            let receipt = try XCTUnwrap(client.currentTaskReceipt(report(id)))
            XCTAssertEqual(receipt.origin?.account, account)
            XCTAssertTrue(receipt.spokenReceipt?.contains(receipt.origin!.sender) == true)
        }
    }

    func testSpeechRequestAndPlaybackUseSameSavedTaskWithoutRepeatingTools() async throws {
        let id = await finished("failed")
        let client = FullDuplexVoiceClient()
        let diagnostics = VoiceDiagnostics(directory: folder.appendingPathComponent("logs"))
        client.diagnostics = diagnostics.begin(engine: "fixture")
        var wire: [[String: Any]] = []
        let adapter = LiveSessionAdapter(wire: { wire.append($0) }, emit: { if case .event(.outputAudioStarted) = $0 { client.handle($0) } })
        try start(adapter, wire: { wire })
        let transport = FullDuplexTransport()
        transport.liveAdapter = adapter
        client.transport = transport
        var delivered: [UUID] = []
        client.onJobDelivered = { delivered.append($0) }
        client.injectDispatchReport(report(id), speak: true)
        let speech = wire.filter { $0["type"] as? String == "session.commentary.append" }
            .compactMap { $0["content"] as? String }.joined()
        XCTAssertTrue(speech.contains("Original D"), speech)
        XCTAssertTrue(speech.contains("task failed"), speech)
        XCTAssertFalse(speech.contains("Still running"))
        XCTAssertTrue(delivered.isEmpty)
        adapter.observePlayback(0.1)
        XCTAssertTrue(delivered.isEmpty, "The first audio frame must not mark the answer delivered")
        let line = try XCTUnwrap(store.existing(id)?.spokenReceipt)
        client.handle(.event(.assistantTranscriptDelta(itemId: "answer", delta: line, spoken: true)))
        client.handle(.event(.assistantTranscriptDone(itemId: "answer", transcript: line)))
        XCTAssertTrue(delivered.isEmpty, "The transcript alone does not prove playback completed")
        client.handle(.event(.outputAudioStopped))
        client.handle(.event(.outputAudioStopped))
        XCTAssertEqual(delivered, [id])
        XCTAssertFalse(wire.contains { $0["type"] as? String == "response.create" })
        let log = String(decoding: try await diagnostics.snapshot(), as: UTF8.self)
        XCTAssertTrue(log.contains("speech_enqueued"))
        XCTAssertTrue(log.contains("jobSpeechStarted"))
        XCTAssertTrue(log.contains("jobSpeechCompleted"))
        XCTAssertFalse(log.contains("Original D"))
        XCTAssertFalse(log.contains("example.test"))
        adapter.close()
    }

    func testQueuedReceiptIsDroppedWhenStateChangesBeforeContextAcknowledgement() async throws {
        let id = await finished("failed")
        let client = FullDuplexVoiceClient()
        var wire: [[String: Any]] = []
        let adapter = LiveSessionAdapter(wire: { wire.append($0) }, emit: { if case .event(.outputAudioStarted) = $0 { client.handle($0) } })
        try start(adapter, wire: { wire })
        let transport = FullDuplexTransport()
        transport.liveAdapter = adapter
        client.transport = transport
        adapter.outbound(["type": "conversation.item.create", "item": ["type": "message", "role": "system",
            "content": [["type": "input_text", "text": "Pending context"]]]])
        client.injectDispatchReport(report(id), speak: true)
        await store.setState(id, state: "cancelled")
        for item in wire where item["type"] as? String == "session.thinking.append" {
            adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.thinking.appended", "client_event_id": item["event_id"]!]))
        }
        XCTAssertFalse(wire.contains { $0["type"] as? String == "session.commentary.append" })
        XCTAssertNil(client.pendingJobSpeech)
        adapter.close()
    }

    func testAnswerLeadsSpeechWithoutInternalInstructionsAndFullResultStaysInCard() async throws {
        let id = UUID()
        let task = String(repeating: "Search internal constraints in account hidden@example.test; query SECRET. ", count: 100)
        let answer = "I found the destination under [the project page](https://example.test/private/path). "
            + String(repeating: "Additional verified detail. ", count: 100)
        await store.begin(id: id, task: task, profileId: nil)
        await store.finish(id, state: "done", result: answer, reportBack: true)
        let job = try XCTUnwrap(store.existing(id))
        let spoken = try XCTUnwrap(job.spokenReceipt)
        XCTAssertTrue(spoken.hasPrefix("I found the destination under the project page."))
        XCTAssertFalse(spoken.contains("SECRET"))
        XCTAssertFalse(spoken.contains("hidden@example.test"))
        XCTAssertFalse(spoken.contains("https://"))
        XCTAssertLessThan(spoken.count, 660)
        XCTAssertEqual(job.result, answer, "The result card retains the complete answer and link")
        XCTAssertEqual(DispatchJob(id: UUID(), task: task, state: "done", result: "Filed the note and archived the email.").spokenReceipt,
            "Filed the note and archived the email.")
        XCTAssertTrue(DispatchJob(id: UUID(), task: task, state: "partial", result: "Filed the note; archive failed.")
            .spokenReceipt?.contains("only partially completed. Filed the note; archive failed.") == true)
    }

    func testTruncatedOrInterruptedSpeechKeepsAnswerAvailableWithoutRepeatingWork() async throws {
        let id = await finished("done")
        let client = FullDuplexVoiceClient()
        var delivered: [UUID] = []
        client.onJobDelivered = { delivered.append($0) }
        client.injectDispatchReport(report(id), speak: true)
        client.handle(.event(.outputAudioStarted))
        client.handle(.event(.assistantTranscriptDelta(itemId: "partial", delta: "The task completed.", spoken: true)))
        client.handle(.event(.assistantTranscriptDone(itemId: "partial", transcript: "The task completed.")))
        client.handle(.event(.outputAudioStopped))
        XCTAssertTrue(delivered.isEmpty)
        client.handle(.liveUserActivity)
        XCTAssertNil(client.pendingJobSpeech)
        XCTAssertNotNil(client.currentTaskReceipt(report(id)))
        let saved = try XCTUnwrap(store.existing(id))
        XCTAssertNil(saved.deliveredAt)
        XCTAssertEqual(saved.result, "Verified result for Original D.")
    }

    func testPlaybackEndingBeforeFinalTranscriptStillDeliversOnceAndQuietResultDoesNotSpeak() async throws {
        let id = await finished("done")
        let client = FullDuplexVoiceClient()
        var delivered: [UUID] = []
        client.onJobDelivered = { delivered.append($0) }
        client.injectDispatchReport(report(id), speak: true)
        let line = try XCTUnwrap(store.existing(id)?.spokenReceipt)
        client.handle(.event(.outputAudioStarted))
        client.handle(.event(.assistantTranscriptDelta(itemId: "answer", delta: line, spoken: true)))
        client.handle(.event(.outputAudioStopped))
        XCTAssertTrue(delivered.isEmpty)
        client.handle(.event(.assistantTranscriptDone(itemId: "answer", transcript: line)))
        client.handle(.event(.assistantTranscriptDone(itemId: "answer", transcript: line)))
        XCTAssertEqual(delivered, [id])
        let quiet = await finished("done", sender: "Quiet result")
        client.injectDispatchReport(report(quiet), speak: false)
        XCTAssertNil(client.pendingJobSpeech)
        XCTAssertEqual(delivered, [id, quiet])
    }

    func testFeedbackTurnDropsQueuedGuardedSpeech() throws {
        var wire: [[String: Any]] = []
        let adapter = LiveSessionAdapter(wire: { wire.append($0) }, emit: { _ in })
        try start(adapter, wire: { wire })
        adapter.outbound(["type": "conversation.item.create", "item": ["type": "message", "role": "system",
            "content": [["type": "input_text", "text": "Pending context"]]]])
        adapter.speakExactly("Task result", ifCurrent: { true })
        adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.input_transcript.delta",
            "delta": "I want to give feedback", "start_ms": 1000, "end_ms": 2000]))
        for item in wire where item["type"] as? String == "session.thinking.append" {
            adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.thinking.appended", "client_event_id": item["event_id"]!]))
        }
        XCTAssertFalse(wire.contains { $0["type"] as? String == "session.commentary.append" })
        adapter.close()
    }
}
