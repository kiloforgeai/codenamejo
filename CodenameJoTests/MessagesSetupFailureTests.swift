import Combine
import XCTest
@testable import CodenameJo

// coverage-target: CodenameJo/Views/MessagesSettingsScreen.swift

/// Settings → Messages hands the user off to a setup link. The link can be absent — it is
/// built from a string, and a build that ships a bad one produces nil rather than a throw —
/// and the screen has to say so. PRINCIPLES rule 18: a dead component and a quiet user must
/// not render the same.
@MainActor
final class MessagesSetupFailureTests: XCTestCase {

    /// The handler does its work inside a detached `Task`, so the assertion waits on the
    /// published change rather than on a sleep.
    private func firstError(from model: MessagesSettingsViewModel, when act: () -> Void) -> String? {
        let arrived = expectation(description: "setupError published")
        var seen: String?
        let token = model.$setupError.dropFirst().sink { value in
            guard value != nil else { return }
            seen = value
            arrived.fulfill()
        }
        act()
        wait(for: [arrived], timeout: 5)
        token.cancel()
        return seen
    }

    func testAFreshScreenAssumesNeitherContactsNorMessagingAreSetUp() {
        let model = MessagesSettingsViewModel()
        guard case .notAsked = model.contactsPermission else {
            return XCTFail("Nothing has been asked yet, so the screen must not claim an answer")
        }
        XCTAssertFalse(model.messagingReady)
        XCTAssertNil(model.setupError)
    }

    func testAMissingSetupLinkIsReportedRatherThanSwallowed() {
        let model = MessagesSettingsViewModel()
        let message = firstError(from: model) {
            MessagesSettingsInteractor().openSetupURL(nil, viewModel: model)
        }
        XCTAssertEqual(message, "Jo could not open the setup link. Try again from Settings.")
        XCTAssertEqual(model.setupError, message)
    }

    func testAMissingSetupLinkNeverMarksMessagingReady() {
        let model = MessagesSettingsViewModel()
        _ = firstError(from: model) {
            MessagesSettingsInteractor().openSetupURL(nil, viewModel: model)
        }
        XCTAssertFalse(model.messagingReady,
                       "A link that never opened cannot have completed the setup behind it")
        guard case .notAsked = model.contactsPermission else {
            return XCTFail("A failed link says nothing about the contacts grant")
        }
    }
}
