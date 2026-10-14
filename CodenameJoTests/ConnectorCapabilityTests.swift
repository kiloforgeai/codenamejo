import XCTest
@testable import CodenameJo

/// The Google connector's capability chips — what Settings → Connections promises before the
/// user authorizes, and what it keeps promising afterwards.
///
/// Two things are load-bearing and neither is the wording. The `scope` is the join key when
/// reconciling granted scopes from the server and is also the chip's `id`, so a duplicate or
/// a typo mislabels what the assistant can reach. And the sending sentence is *computed* per
/// call from the connected inboxes: stored once, it would show whichever answer was current
/// the first time anyone opened the screen and never change again.
final class ConnectorCapabilityTests: XCTestCase {

    private let work = "work@kiloforge.test"
    private let personal = "personal@kiloforge.test"

    override func setUp() {
        super.setUp()
        UserProfile.clearLocalSettings()
    }

    override func tearDown() {
        UserProfile.clearLocalSettings()
        super.tearDown()
    }

    private func mailDetail(_ inboxes: [String]) throws -> String {
        try XCTUnwrap([ConnectorCapability].google(inboxes: inboxes).first?.detail)
    }

    // MARK: - The scopes, which are the join key

    func testEveryChipIsIdentifiedByItsOwnScope() {
        let chips = [ConnectorCapability].google(inboxes: [work])

        XCTAssertEqual(chips.map(\.id), chips.map(\.scope))
        XCTAssertEqual(
            Set(chips.map(\.scope)).count, chips.count,
            "a duplicate id collides in a ForEach and drops a promise off the screen")
    }

    /// Byte-identical to `GOOGLE_SCOPES` in the broker — a typo here is a lie about what the
    /// user is granting, which is the one thing this type exists to get right.
    func testTheScopesAreTheOnesTheBrokerAsksFor() {
        XCTAssertEqual(
            [ConnectorCapability].google(inboxes: [work]).map(\.scope),
            [
                "https://www.googleapis.com/auth/gmail.modify",
                "https://www.googleapis.com/auth/gmail.settings.basic",
                "https://www.googleapis.com/auth/calendar.readonly",
                "https://www.googleapis.com/auth/calendar.events",
            ])
    }

    func testEveryChipCarriesALabelAnIconAndAnAccessibilityDetail() {
        for chip in [ConnectorCapability].google(inboxes: [work]) {
            XCTAssertFalse(chip.label.isEmpty, chip.scope)
            XCTAssertFalse(chip.icon.isEmpty, chip.scope)
            XCTAssertFalse(chip.detail.isEmpty, chip.scope)
        }
    }

    // MARK: - The sending sentence follows the setting

    func testTheThreeSendingStatesAreDescribedThreeDifferentWays() throws {
        UserDefaults.standard.set(true, forKey: DraftsOnly.storageKey)
        let allDraft = try mailDetail([work, personal])

        DraftsOnly.set(false, for: work)
        let mixed = try mailDetail([work, personal])

        DraftsOnly.set(false, for: personal)
        let allSend = try mailDetail([work, personal])

        XCTAssertNotEqual(allDraft, mixed, "one inbox that sends is not the same promise")
        XCTAssertNotEqual(mixed, allSend)
        XCTAssertNotEqual(allDraft, allSend)
    }

    /// The hazard the computed property exists for: a chip read before the switch moved and
    /// again after it has to answer differently both times.
    func testTheChipIsReadAtThePointOfUseRatherThanCachedOnFirstAccess() throws {
        UserDefaults.standard.set(true, forKey: DraftsOnly.storageKey)
        let before = try mailDetail([work])

        DraftsOnly.set(false, for: work)
        let after = try mailDetail([work])

        XCTAssertNotEqual(before, after)
    }

    /// The sentence describes the inboxes it is handed, not the account-wide flag on its own —
    /// which is what makes a mixed account describable at all.
    func testTheSentenceAnswersForTheInboxesItIsGivenNotTheAccountFlag() throws {
        UserDefaults.standard.set(false, forKey: DraftsOnly.storageKey)
        DraftsOnly.set(true, for: work)

        let namedInboxDrafts = try mailDetail([work])

        UserProfile.clearLocalSettings()
        UserDefaults.standard.set(true, forKey: DraftsOnly.storageKey)
        let accountDrafts = try mailDetail([work])

        XCTAssertEqual(
            namedInboxDrafts, accountDrafts,
            "an inbox set to draft reads the same however it got there")
    }

    func testOnlyTheMailChipMovesWithTheSendingSetting() throws {
        UserDefaults.standard.set(true, forKey: DraftsOnly.storageKey)
        let drafting = [ConnectorCapability].google(inboxes: [work])

        DraftsOnly.set(false, for: work)
        let sending = [ConnectorCapability].google(inboxes: [work])

        XCTAssertEqual(Array(drafting.dropFirst()), Array(sending.dropFirst()))
        XCTAssertNotEqual(drafting.first, sending.first)
    }

    // MARK: - Notion, back on the six-verb surface (issue #1089)

    /// The chips promise what the broker's compact surface can do and name its edge: no
    /// deleting, no rewriting a page. Both are structural on the broker side, so a chip that
    /// drifted from them would be a lie about the connector rather than stale copy.
    func testNotionChipsAreUniqueCompleteAndNameTheNoDeleteEdge() {
        let chips = [ConnectorCapability].notion
        XCTAssertEqual(chips.map(\.id), chips.map(\.scope))
        XCTAssertEqual(Set(chips.map(\.scope)).count, chips.count)
        for chip in chips {
            XCTAssertFalse(chip.label.isEmpty, chip.scope)
            XCTAssertFalse(chip.icon.isEmpty, chip.scope)
            XCTAssertFalse(chip.detail.isEmpty, chip.scope)
        }
        let write = chips.first { $0.scope == "notion.write" }
        XCTAssertTrue(write?.detail.contains("never deletes") == true)
        XCTAssertFalse(write?.detail.lowercased().contains("comment") == true,
                       "comments are not on the compact surface, so the chip must not promise them")
    }

    func testAnAccountWithNoInboxesStillDescribesItselfSafely() throws {
        UserDefaults.standard.set(false, forKey: DraftsOnly.storageKey)
        let empty = try mailDetail([])

        UserDefaults.standard.set(true, forKey: DraftsOnly.storageKey)
        let drafting = try mailDetail([work])

        XCTAssertEqual(
            empty, drafting,
            "no inboxes is unobservable, so it reads as the drafting answer even with "
                + "account-wide sending switched on")
    }
}
