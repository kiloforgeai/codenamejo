// coverage-target: CodenameJo/Theme.swift

import SwiftUI
import UIKit
import XCTest
@testable import CodenameJo

/// `Theme.serviceColor(for:)` is a positive list keyed on the connector's display name.
/// A name it does not recognise falls back to amethyst, which is safe but anonymous — so
/// what matters is that the names the app actually passes are recognised, and that the
/// fallback really is a fallback rather than a colour a caller can land on by accident.
final class ThemeTokensTests: XCTestCase {

    /// Colours resolve per appearance; pin one so a comparison is a comparison.
    private func rgba(_ color: Color) -> [CGFloat] {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a]
    }

    func testEveryNamedConnectorHasItsOwnColour() {
        let named = ["Gmail", "Slack", "Linear", "Asana", "Notion", "Calendar",
                     "Drive", "Mercury", "Typefully", "GitHub"]
        let fallback = rgba(Theme.amethyst)
        for name in named {
            XCTAssertNotEqual(rgba(Theme.serviceColor(for: name)), fallback,
                              "\(name) fell through to the default colour")
        }
    }

    func testAnUnknownConnectorFallsBackToAmethyst() {
        XCTAssertEqual(rgba(Theme.serviceColor(for: "Dropbox")), rgba(Theme.amethyst))
    }

    /// The switch matches the display name exactly. A caller passing a lowercased name
    /// gets the anonymous fallback rather than Gmail's red, which is worth knowing
    /// before a new call site invents its own spelling.
    func testTheLookupIsCaseSensitive() {
        XCTAssertEqual(rgba(Theme.serviceColor(for: "gmail")), rgba(Theme.amethyst))
        XCTAssertNotEqual(rgba(Theme.serviceColor(for: "Gmail")), rgba(Theme.amethyst))
    }

    func testAnEmptyNameFallsBackRatherThanCrashing() {
        XCTAssertEqual(rgba(Theme.serviceColor(for: "")), rgba(Theme.amethyst))
    }

    /// A switched-on Toggle is green in both appearances because the dark accent is
    /// near-white and an on switch read the same as a blank one. `toggleOn` exists only
    /// to say that out loud, so it has to stay the same colour as `success`.
    func testASwitchedOnToggleIsTheSuccessGreen() {
        XCTAssertEqual(rgba(Theme.toggleOn), rgba(Theme.success))
    }
}
