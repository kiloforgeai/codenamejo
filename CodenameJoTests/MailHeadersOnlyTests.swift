import XCTest
@testable import CodenameJo

/// The headers-only setting — the half of it that lives on this phone.
///
/// **It is the mirror of `auth:scripts/grade-headers-only.mts`**, and the pair exists for the
/// reason `DraftsOnlyTests` gives: two ends that store the same key and resolve it differently
/// agree about JSON while disagreeing about what it means. Here that would mean a switch the
/// user has turned on and a broker still fetching bodies, which is the one failure this
/// feature cannot have.
///
/// The guarantee itself is not testable from here — it is the broker refusing `format=full`
/// and this app's `GmailAPI.get` doing the same. What is testable is everything that decides
/// *whether* those refusals happen.
final class MailHeadersOnlyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserProfile.clearLocalSettings()
    }

    override func tearDown() {
        UserProfile.clearLocalSettings()
        super.tearDown()
    }

    // MARK: - Surviving a profile sync

    /// The device bug, as a test. Chosen during onboarding, then a profile load applied an
    /// account copy that had not caught up — and because every other flag reads absent as
    /// "clear it", the answer was deleted and the phone went back to fetching bodies.
    func testAnAccountProfileWithoutTheFieldCannotDeleteTheAnswer() {
        MailHeadersOnly.set(true)
        var stale = UserProfile()
        stale.mailHeadersOnly = nil
        stale.applyToLocalSettings(completingOnboarding: false)
        XCTAssertTrue(
            MailHeadersOnly.isOn,
            "a profile that has not caught up must not resume fetching bodies")
    }

    /// The account may still *change* it, in both directions — this is a guard against
    /// deletion, not a guard against the setting travelling between devices.
    func testAnAccountProfileStillChangesTheAnswerInBothDirections() {
        MailHeadersOnly.set(false)
        var on = UserProfile()
        on.mailHeadersOnly = true
        on.applyToLocalSettings(completingOnboarding: false)
        XCTAssertTrue(MailHeadersOnly.isOn, "an explicit true from the account should arrive")

        var off = UserProfile()
        off.mailHeadersOnly = false
        off.applyToLocalSettings(completingOnboarding: false)
        XCTAssertFalse(MailHeadersOnly.isOn, "an explicit false from the account should arrive")
    }

    /// Sign-out is the one path that may remove it: that means "not your phone any more",
    /// not "the server has not heard yet".
    func testSignOutStillClearsTheAnswer() {
        MailHeadersOnly.set(true)
        UserProfile.clearLocalSettings()
        XCTAssertFalse(MailHeadersOnly.isOn)
    }

    // MARK: - The key and the default

    /// The broker reads `value->>'mailHeadersOnly'` off the profile row by that exact name.
    /// A rename on either side is silent: the read returns null and null means off.
    func testTheStorageKeyIsTheNameTheBrokerQueries() {
        XCTAssertEqual(MailHeadersOnly.storageKey, "mailHeadersOnly")
    }

    /// Matches the broker's `headersOnlyFrom`, which is `raw === "true"`. Every account that
    /// existed before this shipped has no field, and none of them asked for this.
    func testAbsentMeansBodiesAreStillReadable() {
        XCTAssertFalse(MailHeadersOnly.isOn, "silence is not consent to a narrower product")
    }

    func testItAnswersInBothDirectionsOnceChosen() {
        UserDefaults.standard.set(true, forKey: MailHeadersOnly.storageKey)
        XCTAssertTrue(MailHeadersOnly.isOn)

        UserDefaults.standard.set(false, forKey: MailHeadersOnly.storageKey)
        XCTAssertFalse(MailHeadersOnly.isOn, "an explicit false is not the same as absent")
    }

    // MARK: - What the model is handed

    /// Gmail's snippet is the first ~200 characters of the body, so it goes with the body.
    /// Read through here rather than off the row because `MailStore` still holds every
    /// snippet it cached before the switch was turned on.
    func testASnippetIsWithheldEvenWhenTheCacheStillHasOne() {
        UserDefaults.standard.set(true, forKey: MailHeadersOnly.storageKey)
        XCTAssertEqual(MailHeadersOnly.snippet("the indemnity clause is the only open item"), "")
        XCTAssertEqual(MailHeadersOnly.snippet(nil), "")
    }

    func testASnippetIsPassedThroughOtherwise() {
        XCTAssertEqual(MailHeadersOnly.snippet("Sending over the redlines"), "Sending over the redlines")
        XCTAssertEqual(MailHeadersOnly.snippet(nil), "", "absent is still empty, not a crash")
    }

    // MARK: - What it switches off

    /// `search_context` re-serves cached tool results to the model turns later, so a body
    /// read that was cached would outlive the message it came from. These two are the only
    /// cached tools that return one.
    func testTheBodyReadsAreNotCachedForReplay() {
        XCTAssertTrue(LocalContextKeys.cached.contains("gmail_get_message"))
        XCTAssertTrue(LocalContextKeys.cached.contains("gmail_get_thread"))

        UserDefaults.standard.set(true, forKey: MailHeadersOnly.storageKey)
        XCTAssertFalse(
            LocalContextKeys.cached.contains("gmail_get_message"),
            "a body read in turn 3 must not reach the model in turn 40")
        XCTAssertFalse(LocalContextKeys.cached.contains("gmail_get_thread"))
        XCTAssertTrue(
            LocalContextKeys.cached.contains("gmail_search_messages"),
            "the reads that still work stay cached — this is a narrowing, not a purge")
    }

    // MARK: - The round trip through the account

    /// The switch has to survive `UserProfile`, or it is a local preference the broker never
    /// sees and the guarantee is off on every other device.
    func testItTravelsOnTheProfileAndComesBack() {
        UserDefaults.standard.set(true, forKey: MailHeadersOnly.storageKey)
        let captured = UserProfile.capturingLocalSettings()
        XCTAssertEqual(captured.mailHeadersOnly, true)

        UserProfile.clearLocalSettings()
        XCTAssertFalse(MailHeadersOnly.isOn, "cleared, so the apply below is what restores it")

        captured.applyToLocalSettings(completingOnboarding: false)
        XCTAssertTrue(MailHeadersOnly.isOn)
    }
}
