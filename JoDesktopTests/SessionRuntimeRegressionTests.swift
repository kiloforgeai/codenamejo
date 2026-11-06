import XCTest
@testable import CodenameJo

final class SessionRuntimeRegressionTests: XCTestCase {
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
