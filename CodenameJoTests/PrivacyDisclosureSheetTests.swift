// coverage-target: CodenameJo/Onboarding/PrivacyDisclosureSheet.swift

import SwiftUI
import UIKit
import XCTest
@testable import CodenameJo

/// The sheet that answers "what happens to my mail" at the consent moment, and carries the
/// headers-only switch with it.
///
/// Two things make it worth a test. It binds the live `MailHeadersOnly` key, so merely
/// opening it must not become a write — the value belongs to the account and
/// `UserProfileStore` syncs it back. And its rows are representations made at that moment:
/// the first one says what is cached on the phone, which is a different sentence depending
/// on the switch, so the sheet has to read the stored value rather than draw one card.
///
/// The second half is checked by rendering, because an XCTest has no assistive technology
/// attached and SwiftUI vends no accessibility tree without one. Two renders of the same
/// stored value are compared against each other within the run; nothing is stored as a
/// baseline and no copy is asserted by text.
@MainActor
final class PrivacyDisclosureSheetTests: XCTestCase {

    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: MailHeadersOnly.storageKey)
        UserDefaults.standard.removeObject(forKey: MailHeadersOnly.storageKey)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: MailHeadersOnly.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: MailHeadersOnly.storageKey)
        }
        super.tearDown()
    }

    /// One render at a fixed phone size, as PNG bytes.
    ///
    /// Through a hosting controller in a window rather than `ImageRenderer`: the sheet's
    /// `@AppStorage` is a dynamic property, and an offscreen renderer does not install one
    /// — every state rendered identically, which is exactly the bug these tests look for.
    private func render(_ view: some View, width: CGFloat = 390, height: CGFloat = 844) -> Data? {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: bounds, format: {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return format
        }()).image { context in
            host.view.layer.render(in: context.cgContext)
        }
        window.isHidden = true
        window.rootViewController = nil
        return image.pngData()
    }

    // MARK: - The sheet is not a write

    /// The key belongs to the account. Showing the sheet with nothing stored has to leave
    /// nothing stored — an `@AppStorage` default that materialised as a write would make
    /// every consent screen claim the user answered a question they were only shown.
    func testOpeningTheSheetDoesNotStoreAnAnswerNobodyGave() {
        _ = render(PrivacyDisclosureSheet())
        XCTAssertNil(UserDefaults.standard.object(forKey: MailHeadersOnly.storageKey))
        XCTAssertFalse(MailHeadersOnly.isOn)
    }

    /// And an answer already given — on this phone or synced from the account — survives
    /// being looked at.
    func testAnExistingAnswerSurvivesTheSheetBeingShown() {
        for stored in [true, false] {
            UserDefaults.standard.set(stored, forKey: MailHeadersOnly.storageKey)
            _ = render(PrivacyDisclosureSheet())
            XCTAssertEqual(
                UserDefaults.standard.object(forKey: MailHeadersOnly.storageKey) as? Bool, stored)
        }
    }

    /// The sheet's own `@AppStorage` default and the predicate every fetch site reads have
    /// to agree, or the switch describes behaviour nobody is getting.
    func testTheSheetsDefaultMatchesTheOneTheFetchSitesRead() {
        XCTAssertFalse(MailHeadersOnly.isOn,
                       "Absent reads as off, which is what the sheet's switch opens on")
    }

    // MARK: - It draws something

    func testTheSheetDrawsWithNothingStoredYet() throws {
        let image = try XCTUnwrap(render(PrivacyDisclosureSheet()))
        XCTAssertGreaterThan(image.count, 1_000, "An empty card would compress to almost nothing")
    }

    /// Deterministic within a run: the same stored answer renders the same sheet. Without
    /// this the comparison below could not tell a real difference from render noise.
    func testTheSameStoredAnswerRendersTheSameSheetTwice() throws {
        UserDefaults.standard.set(false, forKey: MailHeadersOnly.storageKey)
        let first = try XCTUnwrap(render(PrivacyDisclosureSheet()))
        let second = try XCTUnwrap(render(PrivacyDisclosureSheet()))
        XCTAssertEqual(first, second)
    }

    // MARK: - The rows track the switch

    /// The point of the file's own warning: every line is a representation made at the
    /// consent moment, and the cache row is false in one of the two states. If the sheet
    /// drew the same card either way, one of those two sheets would be lying.
    func testTheSheetReadsTheStoredAnswerRatherThanDrawingOneCard() throws {
        UserDefaults.standard.set(false, forKey: MailHeadersOnly.storageKey)
        let bodiesAllowed = try XCTUnwrap(render(PrivacyDisclosureSheet()))
        UserDefaults.standard.set(true, forKey: MailHeadersOnly.storageKey)
        let headersOnly = try XCTUnwrap(render(PrivacyDisclosureSheet()))
        XCTAssertNotEqual(bodiesAllowed, headersOnly)
    }

    /// Nothing stored has to draw the off sheet, not a third thing: absent and off are the
    /// same answer everywhere else in the app.
    func testNothingStoredDrawsTheSameSheetAsAnExplicitOff() throws {
        let absent = try XCTUnwrap(render(PrivacyDisclosureSheet()))
        UserDefaults.standard.set(false, forKey: MailHeadersOnly.storageKey)
        XCTAssertEqual(absent, try XCTUnwrap(render(PrivacyDisclosureSheet())))
    }

    /// A small phone is the narrowest this is ever shown on, and the card has to survive
    /// it — the long detail lines are the ones that wrap.
    func testTheSheetStillDrawsOnTheNarrowestPhone() throws {
        let narrow = try XCTUnwrap(render(PrivacyDisclosureSheet(), width: 320, height: 568))
        XCTAssertGreaterThan(narrow.count, 1_000)
    }

    // MARK: - The teaser

    /// The row that opens the sheet sits in the fine print under the consent button on all
    /// three screens that ask for the grant; it is the only way in. Drawing it must not be
    /// the same thing as tapping it.
    func testDrawingTheTeaserDoesNotOpenTheSheet() throws {
        var opened = 0
        let drawn = try XCTUnwrap(render(PrivacyDisclosureTeaser { opened += 1 },
                                         width: 320, height: 44))
        XCTAssertGreaterThan(drawn.count, 100)
        XCTAssertEqual(opened, 0)
    }
}
