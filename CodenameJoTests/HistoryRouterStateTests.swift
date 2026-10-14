import XCTest
@testable import CodenameJo

// coverage-target: CodenameJo/Views/HistoryRouter.swift

/// `HistoryRouter` holds three separate pieces of pending intent, and the whole point of
/// the split is that each consumer clears only its own. These tests pin that: one
/// consumer must never swallow another's half, and a request made without a tab must not
/// leave an earlier tab request standing.
@MainActor
final class HistoryRouterStateTests: XCTestCase {

    func testOpenRequestsThePaneAndCarriesTheTabAndRow() {
        let router = HistoryRouter()
        let entry = UUID()

        router.open(tab: .actions, entry: entry)

        XCTAssertTrue(router.pendingPane)
        XCTAssertEqual(router.pendingTab, .actions)
        XCTAssertEqual(router.pendingEntryId, entry)
    }

    func testConsumingThePaneLeavesTheTabAndRowStanding() {
        let router = HistoryRouter()
        let entry = UUID()
        router.open(tab: .actions, entry: entry)

        router.consumePane()

        XCTAssertFalse(router.pendingPane)
        XCTAssertEqual(router.pendingTab, .actions, "the picker has not been set yet")
        XCTAssertEqual(router.pendingEntryId, entry, "the list has not scrolled yet")
    }

    func testConsumingTheTabAndRowLeavesThePaneRequestStanding() {
        let router = HistoryRouter()
        router.open(tab: .conversations, entry: UUID())

        router.consumeTab()
        router.consumeEntry()

        XCTAssertNil(router.pendingTab)
        XCTAssertNil(router.pendingEntryId)
        XCTAssertTrue(router.pendingPane, "the pager still has to move")
    }

    /// Opening by the top-corner button asks for no tab, and that must clear whatever an
    /// earlier droplet asked for rather than re-picking it.
    func testOpeningWithoutATabClearsAnEarlierTabAndRowRequest() {
        let router = HistoryRouter()
        router.open(tab: .actions, entry: UUID())
        router.consumePane()

        router.open()

        XCTAssertTrue(router.pendingPane)
        XCTAssertNil(router.pendingTab)
        XCTAssertNil(router.pendingEntryId)
    }
}
