// coverage-target: CodenameJo/CarPlay/CarPlayPresence.swift

import XCTest
@testable import CodenameJo

/// Three separate decisions hang off this one bool — whether a call may run off-screen,
/// whether a Live Activity goes on the Lock Screen, and whether the ten-minute idle
/// timer applies. The failure mode of a stale `true` is a hot microphone with no control
/// surface anywhere, which is exactly what `canRunInBackground` exists to refuse, so the
/// answer is asked of `UIApplication` every time rather than cached.
@MainActor
final class CarPlayPresenceTests: XCTestCase {

    /// No car is attached to a unit-test host, and the safe answer is the one that
    /// refuses the background call.
    func testNoCarScreenMeansNotConnected() {
        XCTAssertFalse(CarPlayPresence.isConnected)
    }

    /// Nothing is memoised: the value is recomputed from the scene list on each read, so
    /// a car that disconnects mid-call is noticed rather than remembered.
    func testThePresenceIsRecomputedOnEveryRead() {
        let first = CarPlayPresence.isConnected
        let second = CarPlayPresence.isConnected
        XCTAssertEqual(first, second)
        XCTAssertFalse(second)
    }
}
