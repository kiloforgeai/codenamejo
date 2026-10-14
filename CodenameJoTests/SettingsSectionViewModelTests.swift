// coverage-target: CodenameJo/Views/ConnectorDetailView.swift
// coverage-target: CodenameJo/Views/WorkspaceProfilesView.swift

import XCTest

@testable import CodenameJo

/// The state two Settings screens open on, before anything has been fetched.
///
/// Each of these screens describes an account — which connector granted what, which
/// workspace profile is live — and each one is drawn before its
/// answer arrives. What the opening state claims is therefore a correctness question, not a
/// cosmetic one: a profile list that opens claiming management is available offers buttons
/// the broker may refuse, a delete alert that opens with a stale consequence count names
/// the wrong number of inboxes.
///
/// The interactors are deliberately left out: they inject the backend and the profile
/// service and their work is network, not logic.
@MainActor
final class SettingsSectionViewModelTests: XCTestCase {

    // MARK: - A connector's detail screen

    private func capability(_ scope: String) -> ConnectorCapability {
        ConnectorCapability(scope: scope, label: "Read mail", icon: "envelope", detail: "Reads it")
    }

    func testAConnectorScreenKeepsEveryFieldItWasHandedAndTheirOrder() {
        let scopes = ["https://example.test/a", "https://example.test/b"]
        let model = ConnectorDetailViewModel(
            name: "Notion", service: "notion",
            capabilities: scopes.map(capability), summary: "2 accounts connected")

        XCTAssertEqual(model.name, "Notion")
        XCTAssertEqual(model.service, "notion")
        XCTAssertEqual(model.summary, "2 accounts connected")
        XCTAssertEqual(model.capabilities.map(\.scope), scopes,
                       "The consent list is read top to bottom; reordering it changes what "
                       + "the screen claims was granted")
    }

    /// The display name and the wire name are separate fields on purpose — a screen headed
    /// "Notion" talks to a service called `notion`, and swapping them is silent.
    func testTheVisibleNameAndTheServiceKeyAreNotTheSameField() {
        let model = ConnectorDetailViewModel(
            name: "Google", service: "gmail", capabilities: [], summary: nil)
        XCTAssertNotEqual(model.name, model.service)
        XCTAssertEqual(model.service, "gmail")
    }

    func testAConnectorWithNothingToSummariseCarriesNoSummaryRatherThanAnEmptyOne() {
        let model = ConnectorDetailViewModel(
            name: "Slack", service: "slack", capabilities: [capability("x")], summary: nil)
        XCTAssertNil(model.summary,
                     "Absent and empty read differently on screen; nil is the absent one")
        XCTAssertEqual(model.capabilities.count, 1)
    }

    func testAConnectorThatGrantedNothingIsStillAValidScreen() {
        let model = ConnectorDetailViewModel(
            name: "Notion", service: "notion", capabilities: [], summary: "Not connected")
        XCTAssertTrue(model.capabilities.isEmpty)
        XCTAssertEqual(model.summary, "Not connected")
    }

    // MARK: - The workspace profile list

    func testTheProfileListOffersNothingUntilTheBrokerSaysItIsAvailable() {
        let model = WorkspaceProfilesViewModel()
        XCTAssertFalse(model.available,
                       "Management is a broker capability; assuming it offers buttons it may refuse")
        XCTAssertFalse(model.canDelete, "Deletion is a separate capability and defaults off too")
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertNil(model.active)
        XCTAssertTrue(model.connections.isEmpty)
    }

    func testTheProfileListOpensIdleWithNoSwitchInFlightAndNoError() {
        let model = WorkspaceProfilesViewModel()
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.switchingTo, "No row owns the spinner until a switch starts")
        XCTAssertNil(model.error)
        XCTAssertFalse(model.showSheet)
    }

    /// The delete alert names how many inboxes go with the profile. Nothing is pending and
    /// the count is zero, so a stale count can never be the first thing the alert shows.
    func testNoDeletionIsPendingAndItsConsequenceCountsZero() {
        let model = WorkspaceProfilesViewModel()
        XCTAssertNil(model.pendingDelete)
        XCTAssertFalse(model.showDelete)
        XCTAssertEqual(model.deleteConnectionCount, 0)
    }

    func testTheRenameSheetOpensOnNothingRatherThanTheLastNameTyped() {
        let model = WorkspaceProfilesViewModel()
        XCTAssertFalse(model.showName)
        XCTAssertEqual(model.name, "")
        XCTAssertNil(model.editing, "An absent edit target is what makes the sheet a create")
    }
}
