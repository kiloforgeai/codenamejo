import XCTest
@testable import CodenameJo

/// The per-inbox send/draft setting — `DraftsOnly`, and the half of it that is arithmetic.
///
/// **Every way of getting this wrong produces working software that sends mail the user did
/// not agree to send.** A map keyed in the wrong case misses and falls back; an inbox nobody
/// has answered for must reach the account-wide flag rather than a hardcoded default; and a
/// stale entry left by a disconnect must not describe a mailbox that has been reconnected.
/// None of those throws, and none of them shows up in a build.
///
/// **It is the mirror of `auth:scripts/grade-mail-send-policy.mts`**, deliberately. The two
/// ends store the same map, key it the same way and resolve it the same way, so the pair of
/// suites is what keeps them from drifting into agreeing about JSON while disagreeing about
/// what it means.
final class DraftsOnlyTests: XCTestCase {
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

    // MARK: - Resolution

    func testAnUnansweredInboxTakesTheAccountWideAnswer() {
        UserDefaults.standard.set(false, forKey: DraftsOnly.storageKey)
        XCTAssertFalse(DraftsOnly.isOn(for: work), "no entry means the account decides")

        UserDefaults.standard.set(true, forKey: DraftsOnly.storageKey)
        XCTAssertTrue(DraftsOnly.isOn(for: work), "and it decides in both directions")
    }

    func testAnAbsentAccountAnswerStillMeansDrafts() {
        XCTAssertTrue(
            DraftsOnly.isOn(for: work),
            "silence fails towards drafting at every level, which is the whole default")
    }

    func testAnInboxAnswerOutranksTheAccount() {
        UserDefaults.standard.set(true, forKey: DraftsOnly.storageKey)
        DraftsOnly.set(false, for: work)

        XCTAssertFalse(DraftsOnly.isOn(for: work), "the named inbox sends")
        XCTAssertTrue(DraftsOnly.isOn(for: personal), "and answers for no other inbox")
    }

    /// A miss here does not throw — it falls back, and for a user whose fallback is `false`
    /// that is mail leaving a mailbox they set to draft.
    func testAddressesMatchWithoutRegardToCaseOrPadding() {
        UserDefaults.standard.set(false, forKey: DraftsOnly.storageKey)
        DraftsOnly.set(true, for: "  WORK@Kiloforge.TEST ")

        XCTAssertTrue(DraftsOnly.isOn(for: work))
        XCTAssertTrue(DraftsOnly.isOn(for: "Work@KILOFORGE.test"))
    }

    func testForgettingAnInboxReturnsItToTheAccountAnswer() {
        UserDefaults.standard.set(false, forKey: DraftsOnly.storageKey)
        DraftsOnly.set(true, for: work)
        XCTAssertTrue(DraftsOnly.isOn(for: work))

        // Disconnect drops the entry, so reconnecting the same address is a new mailbox —
        // and a new mailbox is given an explicit `true` by `ConnectionsService`.
        DraftsOnly.forget(work)
        XCTAssertFalse(
            DraftsOnly.isOn(for: work),
            "with the entry gone the address is one nobody has answered for")
    }

    // MARK: - What the account looks like as a whole

    func testSummaryTellsTheThreeCasesApart() {
        UserDefaults.standard.set(true, forKey: DraftsOnly.storageKey)
        XCTAssertEqual(DraftsOnly.summary(for: [work, personal]), .allDraft)

        DraftsOnly.set(false, for: work)
        XCTAssertEqual(
            DraftsOnly.summary(for: [work, personal]), .mixed,
            "one dissenter is what the Mail chip has to describe differently")

        DraftsOnly.set(false, for: personal)
        XCTAssertEqual(DraftsOnly.summary(for: [work, personal]), .allSend)
    }

    func testAStaleEntryForADisconnectedInboxDoesNotMakeTheAccountMixed() {
        UserDefaults.standard.set(true, forKey: DraftsOnly.storageKey)
        DraftsOnly.set(false, for: work)

        XCTAssertEqual(
            DraftsOnly.summary(for: [personal]), .allDraft,
            "an answer about an inbox that is not connected describes nothing on screen")
    }

    func testNoInboxesReadsAsDrafting() {
        UserDefaults.standard.set(false, forKey: DraftsOnly.storageKey)
        XCTAssertEqual(
            DraftsOnly.summary(for: []), .allDraft,
            "matching mailWriteMode server-side: unobservable, so answer safely")
    }

    // MARK: - The profile round trip

    /// The wire contract. The broker reads this map out of the same profile row
    /// (`draftsOnlyByAccount` in `auth:lib/db.ts`), so what matters is that a value written
    /// here survives being captured, applied and read back — the shape that breaks silently
    /// when local storage and the profile field drift apart.
    func testTheMapTravelsOnTheProfileAndComesBackTheSame() {
        UserDefaults.standard.set(true, forKey: DraftsOnly.storageKey)
        DraftsOnly.set(false, for: work)

        let captured = UserProfile.capturingLocalSettings()
        XCTAssertEqual(captured.draftsOnlyByAccount, [work: false])

        UserProfile.clearLocalSettings()
        XCTAssertTrue(DraftsOnly.isOn(for: work), "cleared, it is back to the default")

        captured.applyToLocalSettings()
        XCTAssertFalse(DraftsOnly.isOn(for: work), "and applying the profile restores it")
    }

    /// `nil` and an empty map are the same state and both are ordinary — it is every
    /// account that has not opened Settings → Sending. What must not happen is a build that
    /// has never written one reporting an empty map as a deliberate answer.
    func testAnUntouchedAccountCarriesNoMapAtAll() {
        UserDefaults.standard.set(false, forKey: DraftsOnly.storageKey)
        XCTAssertNil(UserProfile.capturingLocalSettings().draftsOnlyByAccount)

        DraftsOnly.set(false, for: work)
        DraftsOnly.forget(work)
        XCTAssertEqual(
            UserProfile.capturingLocalSettings().draftsOnlyByAccount, [String: Bool](),
            "an emptied map is still a map — the key exists, so the field travels")
    }
}
