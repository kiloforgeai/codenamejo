import XCTest
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
