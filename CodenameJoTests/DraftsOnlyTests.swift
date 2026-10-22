import XCTest
@testable import CodenameJo

/// The per-inbox Drafts-only safeguard — `DraftsOnly`, and the half of it that is arithmetic.
///
/// **Every way of getting this wrong produces working software that sends mail from an inbox
/// the user locked to drafts.** A map keyed in the wrong case misses and reads as off, and a
/// stale entry left by a disconnect must not describe a mailbox that has been reconnected.
/// None of those throws, and none of them shows up in a build.
final class DraftsOnlyTests: XCTestCase {
    private let work = "work@kiloforge.test"
    private let personal = "personal@kiloforge.test"

    override func setUp() {
        super.setUp()
        UserProfile.clearLocalSettings()
        UserDefaults.standard.removeObject(forKey: "draftsOnlyByAccount")
    }

    override func tearDown() {
        UserProfile.clearLocalSettings()
        UserDefaults.standard.removeObject(forKey: "draftsOnlyByAccount")
        super.tearDown()
    }

    // MARK: - Resolution

    func testAnUnansweredInboxHasTheSafeguardOff() {
        XCTAssertFalse(DraftsOnly.isOn(for: work), "off by default: Jo sends or drafts as asked")
    }

    /// The reset: the old map gave every inbox `true` by default, so it must not be read.
    func testTheOldDraftsByDefaultMapIsIgnored() throws {
        UserDefaults.standard.set(true, forKey: "draftsOnly")
        UserDefaults.standard.set(try JSONEncoder().encode([work: true]), forKey: "draftsOnlyByAccount")
        XCTAssertFalse(DraftsOnly.isOn(for: work))
        UserDefaults.standard.removeObject(forKey: "draftsOnly")
    }

    func testAnInboxAnswerCoversOnlyThatInbox() {
        DraftsOnly.set(true, for: work)

        XCTAssertTrue(DraftsOnly.isOn(for: work), "the named inbox only drafts")
        XCTAssertFalse(DraftsOnly.isOn(for: personal), "and answers for no other inbox")
    }

    /// A miss here does not throw — it reads as off, and that is mail leaving a mailbox the
    /// user locked to drafts.
    func testAddressesMatchWithoutRegardToCaseOrPadding() {
        DraftsOnly.set(true, for: "  WORK@Kiloforge.TEST ")

        XCTAssertTrue(DraftsOnly.isOn(for: work))
        XCTAssertTrue(DraftsOnly.isOn(for: "Work@KILOFORGE.test"))
    }

    func testForgettingAnInboxTurnsTheSafeguardOff() {
        DraftsOnly.set(true, for: work)
        XCTAssertTrue(DraftsOnly.isOn(for: work))

        // Disconnect drops the entry, so reconnecting the same address is a new mailbox.
        DraftsOnly.forget(work)
        XCTAssertFalse(DraftsOnly.isOn(for: work), "with the entry gone the default applies")
    }

    // MARK: - What the account looks like as a whole

    func testSummaryTellsTheThreeCasesApart() {
        XCTAssertEqual(DraftsOnly.summary(for: [work, personal]), .allSend)

        DraftsOnly.set(true, for: work)
        XCTAssertEqual(
            DraftsOnly.summary(for: [work, personal]), .mixed,
            "one dissenter is what the Mail chip has to describe differently")

        DraftsOnly.set(true, for: personal)
        XCTAssertEqual(DraftsOnly.summary(for: [work, personal]), .allDraft)
    }

    func testAStaleEntryForADisconnectedInboxDoesNotMakeTheAccountMixed() {
        DraftsOnly.set(true, for: work)

        XCTAssertEqual(
            DraftsOnly.summary(for: [personal]), .allSend,
            "an answer about an inbox that is not connected describes nothing on screen")
    }

    func testNoInboxesReadsAsDrafting() {
        XCTAssertEqual(
            DraftsOnly.summary(for: []), .allDraft,
            "unobservable, so answer safely")
    }

    // MARK: - The profile round trip

    /// What matters is that a value written here survives being captured, applied and read
    /// back — the shape that breaks silently when local storage and the profile field drift apart.
    func testTheMapTravelsOnTheProfileAndComesBackTheSame() {
        DraftsOnly.set(true, for: work)

        let captured = UserProfile.capturingLocalSettings()
        XCTAssertEqual(captured.draftsOnlySafeguardByAccount, [work: true])

        UserProfile.clearLocalSettings()
        XCTAssertFalse(DraftsOnly.isOn(for: work), "cleared, it is back to the default")

        captured.applyToLocalSettings()
        XCTAssertTrue(DraftsOnly.isOn(for: work), "and applying the profile restores it")
    }

    /// A profile saved under the old field must not bring drafts-by-default back on sign-in.
    func testAProfileWithOnlyTheOldFieldLeavesTheSafeguardOff() throws {
        let old = try JSONDecoder().decode(
            UserProfile.self, from: Data(#"{"draftsOnly":true,"draftsOnlyByAccount":{"work@kiloforge.test":true}}"#.utf8))
        old.applyToLocalSettings()
        XCTAssertFalse(DraftsOnly.isOn(for: work))
    }

    /// `nil` and an empty map are the same state and both are ordinary — it is every
    /// account that has not opened Settings → Safeguards. What must not happen is a build that
    /// has never written one reporting an empty map as a deliberate answer.
    func testAnUntouchedAccountCarriesNoMapAtAll() {
        XCTAssertNil(UserProfile.capturingLocalSettings().draftsOnlySafeguardByAccount)

        DraftsOnly.set(true, for: work)
        DraftsOnly.forget(work)
        XCTAssertEqual(
            UserProfile.capturingLocalSettings().draftsOnlySafeguardByAccount, [String: Bool](),
            "an emptied map is still a map — the key exists, so the field travels")
    }
}
