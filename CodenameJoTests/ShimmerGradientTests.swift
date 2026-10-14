import SwiftUI
import XCTest

@testable import CodenameJo

// coverage-target: CodenameJo/ThirdPartyCode/Shimmer/Shimmer.swift

/// Where the shimmer band starts and ends, which is the only arithmetic in the modifier.
///
/// `bandSize` is not a width in points — it is how far off each edge the gradient is parked
/// before it travels, so a band of 0.3 starts at -0.3 and finishes at 1.3. The sign is the
/// part that is easy to get backwards, and backwards means a placeholder that flashes in
/// from the wrong side or never crosses the view at all. These read the pre-animation state,
/// which is the one the modifier is constructed in.
final class ShimmerGradientTests: XCTestCase {

    func testTheDefaultBandStartsOffTheLeadingEdgeByItsOwnSize() {
        let shimmer = Shimmer()

        XCTAssertEqual(shimmer.startPoint, UnitPoint(x: -0.3, y: -0.3),
                       "The default 0.3 band is parked 0.3 beyond the corner before it travels.")
    }

    func testTheDefaultBandEndsAtTheLeadingCorner() {
        let shimmer = Shimmer()

        XCTAssertEqual(shimmer.endPoint, UnitPoint(x: 0, y: 0),
                       "Start and end are one band apart, so the whole band is off-view at rest.")
    }

    func testAZeroWidthBandStartsFlushWithTheView() {
        let shimmer = Shimmer(bandSize: 0)

        XCTAssertEqual(shimmer.startPoint, UnitPoint(x: 0, y: 0))
        XCTAssertEqual(shimmer.endPoint, UnitPoint(x: 0, y: 0))
    }

    func testAFullWidthBandStartsAWholeViewOffScreen() {
        let shimmer = Shimmer(bandSize: 1)

        XCTAssertEqual(shimmer.startPoint, UnitPoint(x: -1, y: -1),
                       "A band as wide as the view has to clear the view entirely before it moves.")
    }

    func testTheDefaultGradientIsOpaqueOnlyInTheMiddle() {
        let stops = Shimmer.defaultGradient.stops

        XCTAssertEqual(stops.count, 3)
        XCTAssertEqual(stops.map(\.location), [0, 0.5, 1],
                       "A translucent-opaque-translucent ramp is what makes the pass read as a sheen.")
    }

    func testOverlayModeDefaultsToSourceAtop() {
        guard case .overlay(let blendMode) = Shimmer.Mode.overlay() else {
            return XCTFail("`.overlay()` must stay an overlay case.")
        }

        XCTAssertEqual(blendMode, .sourceAtop,
                       "Anything else lets the band paint outside the view it is shimmering.")
    }
}
