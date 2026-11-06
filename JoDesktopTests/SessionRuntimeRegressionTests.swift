import XCTest
@testable import CodenameJo

final class SessionRuntimeRegressionTests: XCTestCase {
    func testExplicitSessionExitAcceptsDisfluencyButNotMailOrCalendarDecisions() {
        for text in ["Yeah, I guess let's end the session.", "Hang up", "Could you end the call please?",
                     "[inhale] Okay, let's end the session", "I'm done with the call", "goodbye"] {
            XCTAssertTrue(SpokenCommand.explicitlyEndsSession(text), text)
        }
        for text in ["I'm done", "I'm done with this email", "skip this", "decline the meeting",
                     "don't end the session", "yes, but don't hang up", "end the session, no wait", "read the words hang up"] {
            XCTAssertFalse(SpokenCommand.explicitlyEndsSession(text), text)
        }
    }

    @MainActor func testVoiceExitBypassesFailedReasoningAndUnansweredToolsExactlyOnce() async throws {
        for stuckTool in [false, true] {
            var wire: [[String: Any]] = []
            var requests = 0
            var exits: [String] = []
            let adapter = LiveSessionAdapter(wire: { wire.append($0) }, emit: { signal in
                if case .liveEndRequested(let text) = signal { exits.append(text) }
            })
            adapter.clientBrainState = { (String(repeating: "large mail context ", count: 20_000), "work") }
            adapter.enableClientDelegation { _ in
                requests += 1
                if stuckTool {
                    return ["output": [["type": "function_call", "call_id": "stuck", "name": "gmail_get_thread", "arguments": "{}"]]]
                }
                throw URLError(.timedOut)
            }
            func receive(_ event: [String: Any]) throws { adapter.receive(try JSONSerialization.data(withJSONObject: event)) }
            try receive(["type": "session.started"])
            try receive(["type": "session.input_transcript.delta", "delta": "read this email", "start_ms": 0, "end_ms": 100])
            try receive(["type": "session.delegation.created", "offset_ms": 100, "delegation": ["id": "read", "target": "client"]])
            try await Task.sleep(for: .milliseconds(1200))
            XCTAssertEqual(requests, 1)
            try receive(["type": "session.input_transcript.delta", "delta": "Yeah, I guess let's end the session.", "start_ms": 2000, "end_ms": 2500])
            try receive(["type": "session.delegation.created", "offset_ms": 2500, "delegation": ["id": "end", "target": "client"]])
            try await Task.sleep(for: .milliseconds(1200))
            XCTAssertEqual(exits, ["Yeah, I guess let's end the session."])
            XCTAssertEqual(requests, 1, "Exit must never request another reasoning step")
            try receive(["type": "session.input_transcript.delta", "delta": "hang up", "start_ms": 4000, "end_ms": 4500])
            adapter.close()
            XCTAssertEqual(wire.filter { $0["type"] as? String == "session.close" }.count, 1)
            XCTAssertEqual(exits.count, 1)
        }
    }

    func testAvailabilityDiagnosisOnlyChangesWithStateOrANewSession() {
        var cache = ModelAvailabilityCache()
        var queries = 0
        var diagnoses: [Bool] = []
        for second in 0..<1_080 {
            for _ in 0..<4 {
                XCTAssertFalse(cache.read(now: Double(second), onChange: { diagnoses.append($0) }) {
                    queries += 1; return false
                })
            }
        }
        XCTAssertEqual(queries, 18)
        XCTAssertEqual(diagnoses, [false])
        XCTAssertTrue(cache.read(now: 1_080, onChange: { diagnoses.append($0) }) { true })
        XCTAssertFalse(cache.read(now: 1_140, onChange: { diagnoses.append($0) }) { false })
        cache.invalidate()
        XCTAssertFalse(cache.read(now: 1_141, onChange: { diagnoses.append($0) }) { false })
        XCTAssertEqual(diagnoses, [false, true, false, false])
    }

    func testInferenceFailureStopsRepeatedRoutingUntilCooldownOrNewSession() {
        var cache = ModelAvailabilityCache()
        XCTAssertTrue(cache.read(now: 0) { true })
        XCTAssertTrue(cache.suppress(now: 1))
        XCTAssertFalse(cache.suppress(now: 1))
        var queries = 0
        for _ in 0..<1_088 {
            XCTAssertFalse(cache.read(now: 60) { queries += 1; return true })
        }
        XCTAssertEqual(queries, 0)
        XCTAssertTrue(cache.read(now: 61) { queries += 1; return true })
        XCTAssertEqual(queries, 1)
        cache.suppress(now: 62)
        cache.invalidate()
        XCTAssertTrue(cache.read(now: 63) { true })
    }

    func testUnavailableModelIsQueriedOnceForManyTranscriptFragmentsAndCanRecover() {
        var cache = ModelAvailabilityCache()
        var queries = 0
        for _ in 0..<1_088 {
            XCTAssertFalse(cache.read(now: 0) { queries += 1; return false })
        }
        XCTAssertEqual(queries, 1)
        XCTAssertTrue(cache.read(now: 60) { queries += 1; return true })
        XCTAssertFalse(cache.read(now: 120) { queries += 1; return false })
        cache.invalidate()
        XCTAssertTrue(cache.read(now: 121) { queries += 1; return true })
        XCTAssertEqual(queries, 4)
    }

    func testVectorDiagnosticHandlesEmptyAndScoredLookups() {
        XCTAssertEqual(LocalContextStore.vectorDiagnostic(count: 0, best: nil),
                       "localContext: vector scanned 0, best 0.000, floor 0.55")
        XCTAssertEqual(LocalContextStore.vectorDiagnostic(count: 3, best: 0.825),
                       "localContext: vector scanned 3, best 0.825, floor 0.55")
    }

    func testCueRejectsUnavailableHardwareFormat() {
        XCTAssertFalse(ConnectCue.validOutput(sampleRate: 0, channels: 2))
        XCTAssertFalse(ConnectCue.validOutput(sampleRate: 48_000, channels: 0))
        XCTAssertFalse(ConnectCue.validOutput(sampleRate: .nan, channels: 1))
        XCTAssertTrue(ConnectCue.validOutput(sampleRate: 48_000, channels: 2))
    }
}
