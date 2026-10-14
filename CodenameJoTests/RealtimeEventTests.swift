import XCTest
@testable import CodenameJo

/// `ResponseUsage`: the absences that must stay absences.
final class RealtimeEventTests: XCTestCase {

    func testCachedPercentRoundsAndRefusesToDivideByNothing() {
        func usage(_ input: Int?, _ cached: Int?) -> ResponseUsage {
            ResponseUsage(
                inputTokens: input, cachedTokens: cached,
                cachedAudioTokens: nil, cachedTextTokens: nil)
        }
        XCTAssertEqual(usage(3, 1).cachedPercent, 33)
        XCTAssertEqual(usage(3, 2).cachedPercent, 67)
        XCTAssertNil(usage(0, 0).cachedPercent)
        XCTAssertNil(usage(100, nil).cachedPercent)
        // Only a cache breakdown, with neither total: nothing to report a rate from.
        XCTAssertTrue(ResponseUsage(
            inputTokens: nil, cachedTokens: nil,
            cachedAudioTokens: 5, cachedTextTokens: nil).isEmpty)
        XCTAssertFalse(usage(1, nil).isEmpty)
    }
}
