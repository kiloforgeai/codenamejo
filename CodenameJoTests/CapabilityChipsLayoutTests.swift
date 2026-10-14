// coverage-target: CodenameJo/Views/CapabilityChips.swift

import SwiftUI
import XCTest
@testable import CodenameJo

/// The capability labels under a connector row, and the single-pass flow layout behind them.
///
/// The file's own comment says why the layout exists: a connector gains capabilities over
/// time, and "a horizontal scroll would hide them". So the one behaviour worth holding is
/// that every chip stays reachable at any width — it wraps onto another line rather than
/// running off the edge or collapsing. Nothing here asserts a point value: fonts and symbol
/// metrics are the runtime's, so the assertions are relations between measurements taken in
/// the same run.
@MainActor
final class CapabilityChipsLayoutTests: XCTestCase {

    private func capability(_ label: String, scope: String? = nil) -> ConnectorCapability {
        ConnectorCapability(
            scope: scope ?? "https://example.test/\(label)",
            label: label,
            icon: "envelope.fill",
            detail: "Lets the assistant do \(label).")
    }

    /// Height the chips ask for inside a container of `width`.
    private func height(_ capabilities: [ConnectorCapability], width: CGFloat) -> CGFloat {
        let host = UIHostingController(rootView: CapabilityChips(capabilities: capabilities))
        return host.sizeThatFits(
            in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    private var four: [ConnectorCapability] {
        [capability("Read mail"), capability("Send mail"),
         capability("Read calendar"), capability("Write calendar")]
    }

    // MARK: - Nothing to draw

    /// A connector with no capabilities must take no vertical room at all, not an empty
    /// row's worth: the section is drawn from the same code whether or not there is
    /// anything to say about the connector.
    func testAConnectorWithNoCapabilitiesTakesNoHeight() {
        XCTAssertEqual(height([], width: 320), 0, accuracy: 0.5)
    }

    // MARK: - One line

    func testASingleChipOccupiesOneLine() {
        let single = height([capability("Read mail")], width: 320)
        XCTAssertGreaterThan(single, 0, "A chip with a label has to draw something")
        XCTAssertLessThan(single, 60, "One chip is one line, not a stack")
    }

    /// Four short labels fit a phone-width row, so widening the container past that cannot
    /// change the height — there is nothing left to pull up.
    func testWideningAFittingRowDoesNotChangeItsHeight() {
        XCTAssertEqual(height(four, width: 1_000), height(four, width: 2_000), accuracy: 0.5)
    }

    // MARK: - Wrapping

    /// The reason the layout exists. The same chips in a narrow container have to be taller,
    /// because the ones that no longer fit move down rather than out of sight.
    func testChipsWrapInsteadOfRunningOffTheEdge() {
        let wide = height(four, width: 1_000)
        let narrow = height(four, width: 120)
        XCTAssertGreaterThan(narrow, wide,
                             "A narrow container has to wrap the chips onto further lines")
    }

    /// Monotonic across a sweep: every extra point of width can only ever pull chips up, so
    /// a wider container is never taller than a narrower one. A line-breaker that measured
    /// the wrong edge would show up here as a bump.
    func testHeightNeverGrowsAsTheContainerWidens() {
        var previous = height(four, width: 60)
        for width in stride(from: CGFloat(80), through: 600, by: 40) {
            let current = height(four, width: width)
            XCTAssertLessThanOrEqual(current, previous + 0.5,
                                     "Widening to \(width) made the chips taller")
            previous = current
        }
    }

    /// A container narrower than one chip is the boundary the line-breaker has to survive:
    /// the first chip of a line is placed whatever it costs, so four chips become four
    /// lines rather than an empty line repeated forever.
    func testAContainerNarrowerThanOneChipGivesEveryChipItsOwnLine() {
        let oneLine = height([capability("Read mail")], width: 1_000)
        let stacked = height(four, width: 10)
        XCTAssertGreaterThan(stacked, oneLine * 3,
                             "Four chips that cannot share a line need four lines")
        XCTAssertLessThan(stacked, oneLine * 6, "…and no more than four")
    }

    // MARK: - Identity

    /// `id` is the scope, not the label. Two capabilities that happen to read the same are
    /// still two chips — collapsing them would under-describe what was granted.
    func testTwoCapabilitiesSharingALabelStillDrawTwoChips() {
        let pair = [capability("Read mail", scope: "https://example.test/a"),
                    capability("Read mail", scope: "https://example.test/b")]
        let one = height([capability("Read mail")], width: 10)
        XCTAssertGreaterThan(height(pair, width: 10), one * 1.5,
                             "Same label, different scope: both chips are drawn")
    }

    /// Production's own list, rather than fixtures, through the same widths. The Google
    /// grant is the only connector this draws today and it is the longest list there is.
    func testTheGoogleGrantsOwnCapabilitiesWrapTheSameWay() {
        let google = [ConnectorCapability].google(inboxes: ["person@example.test"])
        XCTAssertFalse(google.isEmpty, "The Google connector declares capabilities")
        XCTAssertGreaterThan(height(google, width: 100), height(google, width: 1_000))
    }
}
