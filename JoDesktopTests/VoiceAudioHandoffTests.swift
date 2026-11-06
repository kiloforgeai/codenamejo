import AVFoundation
import XCTest
@testable import CodenameJo

@MainActor
final class VoiceAudioHandoffTests: XCTestCase {
    func testFallbackWaitsForLiveAudioRelease() async throws {
        let handoff = VoiceAudioHandoff()
        let releasing = expectation(description: "Live teardown started")
        var finish: CheckedContinuation<Void, Never>?
        var events: [String] = []
        handoff.release {
            events.append("releasing")
            await withCheckedContinuation { finish = $0; releasing.fulfill() }
            events.append("released")
        }
        let fallback = Task {
            try await handoff.wait()
            events.append("fallback")
        }
        await fulfillment(of: [releasing], timeout: 2)
        XCTAssertEqual(events, ["releasing"])
        finish?.resume()
        try await fallback.value
        XCTAssertEqual(events, ["releasing", "released", "fallback"])
    }

    func testCancelledFallbackDoesNotOpenAudioAfterRelease() async throws {
        let handoff = VoiceAudioHandoff()
        let releasing = expectation(description: "Teardown started")
        var finish: CheckedContinuation<Void, Never>?
        handoff.release { await withCheckedContinuation { finish = $0; releasing.fulfill() } }
        var opened = false
        let fallback = Task { try await handoff.wait(); opened = true }
        await fulfillment(of: [releasing], timeout: 2)
        fallback.cancel()
        finish?.resume()
        do { try await fallback.value; XCTFail("Cancelled handoff must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(opened)
    }

    func testSystemVoiceDoesNotShareTheMicrophoneAudioSessionOnMac() {
        let synthesizer = AVSpeechSynthesizer()
        let speech = LocalSpeech(synthesizer: synthesizer)
        XCTAssertFalse(synthesizer.usesApplicationAudioSession)
        withExtendedLifetime(speech) {}
    }

    func testSystemSpeechReportsStartedAndFinishedCallbacks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let log = VoiceDiagnostics(directory: folder)
        let trace = log.begin(engine: "speaker_test")
        let speech = LocalSpeech()
        try await speech.speakWithoutMicrophone("Jo speaker check.", diagnostics: trace)
        let data = try await log.snapshot()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("speechRequested"))
        XCTAssertTrue(text.contains("speechStarted"))
        XCTAssertTrue(text.contains("speechFinished"))
        XCTAssertFalse(text.contains("speechFailed"))
        XCTAssertFalse(text.contains("Jo speaker check"))
        try FileManager.default.removeItem(at: folder)
    }
}
