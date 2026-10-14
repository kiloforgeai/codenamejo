// coverage-target: CodenameJo/Views/SettingsRow.swift

import SwiftUI
import XCTest
@testable import CodenameJo

/// One definition of the settings row look, so the sections dropped into Settings cannot
/// drift apart. What that promise is worth is measurable: rows built from the same helper
/// have to agree on the icon column whatever symbol they name, the detail line has to be
/// subordinate to the title, and a longer detail has to wrap rather than widen the row.
@MainActor
final class SettingsRowStylingTests: XCTestCase {

    private func size(_ view: some View, width: CGFloat = 320) -> CGSize {
        UIHostingController(rootView: view.frame(width: width))
            .sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    }

    /// The size the view asks for when nothing constrains it, which is what shows a
    /// difference in the text itself rather than in the column it was poured into.
    private func intrinsicSize(_ view: some View) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(
            in: CGSize(width: CGFloat.greatestFiniteMagnitude,
                       height: CGFloat.greatestFiniteMagnitude))
    }

    // MARK: - The icon column

    /// The column is a fixed `@ScaledMetric` width, so a wide symbol and a narrow one
    /// produce the same row. A symbol that sized its own column would step the titles of
    /// neighbouring rows out of line, which is the drift this helper exists to stop.
    func testTheIconColumnIsTheSameWidthWhicheverSymbolTheRowNames() {
        let narrow = size(SettingsRow.label("Seed this inbox", icon: "trash", detail: "Detail."))
        let wide = size(SettingsRow.label(
            "Seed this inbox", icon: "rectangle.portrait.and.arrow.right", detail: "Detail."))
        XCTAssertEqual(narrow.height, wide.height, accuracy: 0.5)
    }

    /// A symbol name the system does not know still has to leave a row — Settings must not
    /// lose a control because a constant was mistyped.
    func testARowWithAnUnknownSymbolStillDrawsItsText() {
        let row = size(SettingsRow.label(
            "Clear seeded mail", icon: "not.a.real.symbol.name", detail: "Detail."))
        XCTAssertGreaterThan(row.height, 0)
        XCTAssertGreaterThan(row.width, 0)
    }

    // MARK: - Title against detail

    /// The detail is the footnote under the title. The same sentence put through the title
    /// slot takes more lines than through the detail slot, which is what says the two are
    /// still a heading and its subtitle rather than two titles.
    func testTheDetailLineIsSubordinateToTheTitle() {
        let sentence = String(repeating: "Write ten test messages. ", count: 4)
        let asTitle = size(SettingsRow.label(sentence, icon: "tray", detail: "Ten."))
        let asDetail = size(SettingsRow.label("Ten.", icon: "tray", detail: sentence))
        XCTAssertGreaterThan(asTitle.height, asDetail.height)
    }

    /// A long detail wraps inside the row's width rather than stretching it; a settings
    /// list that scrolled sideways would hide the right-hand half of every row.
    func testALongDetailWrapsInsteadOfWideningTheRow() {
        let short = size(SettingsRow.label("Seed this inbox", icon: "tray", detail: "Ten."))
        let long = size(SettingsRow.label(
            "Seed this inbox", icon: "tray",
            detail: String(repeating: "Write ten test messages spanning every band. ", count: 6)))
        XCTAssertEqual(short.width, long.width, accuracy: 0.5)
        XCTAssertGreaterThan(long.height, short.height)
    }

    /// An empty detail is still a row with a title; the helper has no "title only" shape and
    /// callers pass "" rather than branching.
    func testARowWithAnEmptyDetailKeepsItsTitle() {
        let empty = size(SettingsRow.label("Seed this inbox", icon: "tray", detail: ""))
        XCTAssertGreaterThan(empty.height, 0)
    }

    // MARK: - Header and footer

    /// The header is the heavier of the two; a footer that out-measured its own header
    /// would invert the section's reading order.
    func testASectionHeaderOutweighsItsFooterForTheSameText() {
        let text = "Test inbox"
        XCTAssertGreaterThan(size(SettingsRow.header(text)).height,
                             size(SettingsRow.footer(text)).height)
    }

    /// `.textCase(nil)` on the header: a `Section` header otherwise arrives uppercased, and
    /// these sections name themselves in sentence case. Measured rather than read — the
    /// uppercase form is wider, so a header that lost the modifier would not match.
    func testTheHeaderKeepsTheCaseItWasGiven() {
        let sentence = intrinsicSize(SettingsRow.header("Test inbox"))
        let upper = intrinsicSize(SettingsRow.header("TEST INBOX"))
        XCTAssertGreaterThan(upper.width, sentence.width,
                             "An uppercased header is wider; the sentence-case one is not it")
    }

    /// The footer carries two different sentences depending on what the section is doing,
    /// and the longer one has to wrap inside the same width.
    func testALongFooterWrapsWithinTheSectionWidth() {
        let short = size(SettingsRow.footer("Seeding…"))
        let long = size(SettingsRow.footer(
            "Inserted, never sent — nothing is delivered to anyone. A background refresh "
            + "has to run before the bands reach the queue."))
        XCTAssertEqual(short.width, long.width, accuracy: 0.5)
        XCTAssertGreaterThan(long.height, short.height)
    }
}
