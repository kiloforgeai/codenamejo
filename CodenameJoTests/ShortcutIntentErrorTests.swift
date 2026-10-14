// coverage-target: CodenameJo/AppIntents/ShortcutRequestIntent.swift
// coverage-target: CodenameJo/AppIntents/PendingContactIntent.swift
// coverage-target: CodenameJo/AppIntents/ProcessMessagesIntent.swift

import XCTest
@testable import CodenameJo

/// The failure text the Messages bridge shows inside Shortcuts.
///
/// These are the only thing a user sees when an automation goes wrong — Shortcuts
/// renders the error and stops — so each case has to say something different and each
/// has to render through `CustomLocalizedStringResourceConvertible` rather than falling
/// back to a type name. The intents themselves are `@available(iOS 27, *)` and cannot be
/// run on this runtime; their error types are not, and they are what this covers.
final class ShortcutIntentErrorTests: XCTestCase {

    // MARK: - A claimed request that no longer exists

    func testAnExpiredRequestDescribesItself() {
        let description = ShortcutRequestError.expired.errorDescription
        XCTAssertNotNil(description)
        XCTAssertFalse(description?.isEmpty ?? true)
    }

    /// `errorDescription` and the localized resource are two renderings of one string;
    /// Shortcuts picks whichever it likes, so they must not diverge.
    func testAnExpiredRequestRendersTheSameThroughBothConformances() {
        XCTAssertEqual(
            ShortcutRequestError.expired.errorDescription,
            String(localized: ShortcutRequestError.expired.localizedStringResource))
    }

    // MARK: - A contact the phone does not have

    func testAMissingContactNamesThePersonThatWasAskedFor() {
        let description = PendingContactError.noContact("Sarah Chen").errorDescription
        XCTAssertEqual(description?.contains("Sarah Chen"), true)
    }

    /// An empty name means there was no contact request waiting at all — a different
    /// fault from "I looked and could not find them", and it must not read as a search
    /// for a person with no name.
    func testAMissingContactWithNoNameIsADifferentFaultFromANamedOne() {
        let anonymous = PendingContactError.noContact("").errorDescription
        let named = PendingContactError.noContact("Sarah Chen").errorDescription
        XCTAssertNotNil(anonymous)
        XCTAssertNotEqual(anonymous, named)
        XCTAssertEqual(anonymous?.contains("Sarah Chen"), false)
    }

    // MARK: - The parked Process Messages route

    /// Three genuinely different reasons the action can fail; collapsing any two would
    /// send someone to fix the wrong end of their automation.
    func testTheThreeProcessMessagesFailuresAreAllDistinct() {
        let unavailable = ProcessMessagesError.unavailable.errorDescription
        let empty = ProcessMessagesError.emptyInput.errorDescription
        let failed = ProcessMessagesError.failed("broker said no").errorDescription
        XCTAssertNotNil(unavailable)
        XCTAssertNotEqual(unavailable, empty)
        XCTAssertNotEqual(empty, failed)
        XCTAssertNotEqual(unavailable, failed)
    }

    /// The broker's own reason is the only actionable part of a failure; dropping it
    /// leaves "Jo could not process the messages" and nothing to do about it.
    func testAFailureCarriesTheUnderlyingReason() {
        let description = ProcessMessagesError.failed("broker said no").errorDescription
        XCTAssertEqual(description?.contains("broker said no"), true)
    }

    func testEveryProcessMessagesFailureRendersThroughItsLocalizedResource() {
        for error: ProcessMessagesError in [.unavailable, .emptyInput, .failed("boom")] {
            XCTAssertEqual(
                error.errorDescription, String(localized: error.localizedStringResource),
                "\(error) rendered differently through its two conformances")
        }
    }
}
