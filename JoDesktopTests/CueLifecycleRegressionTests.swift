import XCTest
@testable import CodenameJo

@MainActor
final class CueLifecycleRegressionTests: XCTestCase {
    private func events(_ log: VoiceDiagnostics) async throws -> [[String: Any]] {
        try String(decoding: await log.snapshot(), as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func testRepeatedCuePlaybackReleasesEachGraphAndRecordsItsFormat() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = VoiceDiagnostics(directory: folder)
        let cue = ConnectCue(label: "fixture cue")
        cue.diagnostics = log.begin(engine: "cue_test")
        await cue.play()
        await cue.play()
        let rows = try await events(log)
        let requests = rows.filter { $0["event"] as? String == "speechRequested" }
        let finished = rows.filter { $0["event"] as? String == "speechFinished" }
        XCTAssertFalse(rows.contains { $0["event"] as? String == "speechFailed" })
        XCTAssertEqual(finished.count, 2)
        let ids = requests.compactMap { ($0["fields"] as? [String: String])?["request_id"] }
        XCTAssertEqual(Set(ids).count, 2)
        for request in requests {
            let fields = try XCTUnwrap(request["fields"] as? [String: String])
            XCTAssertGreaterThan(Double(fields["sample_rate"] ?? "") ?? 0, 0)
            XCTAssertGreaterThan(Int(fields["output_channels"] ?? "") ?? 0, 0)
        }
        let released = rows.filter { $0["event"] as? String == "audioReleased" }
            .compactMap { ($0["fields"] as? [String: String])?["request_id"] }
        XCTAssertEqual(Set(released), Set(ids))
        XCTAssertEqual(released.count, 2)
    }

    func testStopDuringQueuedStartupReleasesTheGraphAndAllowsTheNextCue() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = VoiceDiagnostics(directory: folder)
        let queue = AudioQueue()
        let barrier = DispatchSemaphore(value: 0)
        let waiting = expectation(description: "Audio queue held before startup")
        queue.detached("cue test barrier") {
            waiting.fulfill()
            _ = barrier.wait(timeout: .now() + 5)
        }
        await fulfillment(of: [waiting], timeout: 2)
        let cue = ConnectCue(label: "fixture interrupted cue", queue: queue)
        cue.diagnostics = log.begin(engine: "cue_test")
        let first = Task { await cue.play() }
        try await Task.sleep(for: .milliseconds(20))
        let stopping = Task { await cue.stop() }
        try await Task.sleep(for: .milliseconds(20))
        barrier.signal()
        await stopping.value
        await cue.play()
        await first.value
        let rows = try await events(log)
        let cancelled = rows.filter { $0["event"] as? String == "speechCancelled" }
        XCTAssertTrue(cancelled.contains { ($0["fields"] as? [String: String])?["reason"] == "superseded_during_start" })
        XCTAssertEqual(rows.filter { $0["event"] as? String == "speechStarted" }.count, 1)
        XCTAssertEqual(rows.filter { $0["event"] as? String == "speechFinished" }.count, 1)
        XCTAssertEqual(rows.filter { $0["event"] as? String == "audioReleased" }.count, 2)
        XCTAssertFalse(rows.contains { $0["event"] as? String == "speechFailed" })
    }
}
