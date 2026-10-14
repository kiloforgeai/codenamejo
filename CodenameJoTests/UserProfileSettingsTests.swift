import XCTest
@testable import CodenameJo

/// Settings belong to the account, and this is the pair of functions that moves them between
/// the account and `UserDefaults`. Two invariants are load-bearing: a value the account does
/// not carry is cleared locally, and the one privacy answer that must never be cleared that
/// way isn't. A third is the sign-out wipe, so one person's settings are not the next
/// person's starting point.
final class UserProfileSettingsTests: XCTestCase {

    private static let touchedKeys = [
        MailFooter.storageKey,
        MailHeadersOnly.storageKey,
        StandingRule.archiveAfterReply.storageKey,
        StandingRule.archiveAfterForward.storageKey,
        StandingRule.archiveAfterLabel.storageKey,
        DraftsOnly.storageKey, DraftsOnly.byAccountStorageKey,
        EmailOnboardingContract.mailModeAccountKey, ThreadQueue.storageKey,
        TriageScope.storageKey,
        AgentLedEmailSettings.key, DailyMailNotifications.storageKey,
        DailyMailNotifications.minuteOfDayStorageKey, DailyMailNotifications.timeZoneStorageKey,
        OnboardingState.storageKey,
        AppearanceSetting.storageKey,
    ]

    /// These tests write the real `UserDefaults` the production code reads, so whatever this
    /// device already had is put back afterwards.
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        saved = [:]
        for key in Self.touchedKeys {
            if let value = defaults.object(forKey: key) { saved[key] = value }
            defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for key in Self.touchedKeys { defaults.removeObject(forKey: key) }
        for (key, value) in saved { defaults.set(value, forKey: key) }
        saved = [:]
        super.tearDown()
    }

    func testCapturingReadsWhetherASettingWasChosenNotWhatItSaysNow() {
        XCTAssertNil(UserProfile.capturingLocalSettings().threadQueue)

        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        // `bool(forKey:)` answers false for a missing key too, which would make "off" and
        // "never chosen" the same profile.
        XCTAssertEqual(UserProfile.capturingLocalSettings().threadQueue, false)
    }

    func testAnEmptyStringIsNotAChoice() {
        UserDefaults.standard.set("", forKey: TriageScope.storageKey)
        XCTAssertNil(UserProfile.capturingLocalSettings().triageScope)

        UserDefaults.standard.set("unread", forKey: TriageScope.storageKey)
        XCTAssertEqual(UserProfile.capturingLocalSettings().triageScope, "unread")
    }

    func testApplyingAProfileClearsTheSettingsItDoesNotCarry() {
        UserDefaults.standard.set(true, forKey: ThreadQueue.storageKey)
        UserDefaults.standard.set(true, forKey: MailFooter.storageKey)

        UserProfile().applyToLocalSettings()

        XCTAssertNil(UserDefaults.standard.object(forKey: ThreadQueue.storageKey))
        XCTAssertNil(UserDefaults.standard.object(forKey: MailFooter.storageKey))
    }

    func testApplyingThenCapturingReturnsTheSameChoices() {
        var profile = UserProfile()
        profile.threadQueue = true
        profile.draftsOnly = false
        profile.triageScope = "unread"
        profile.appearance = "dark"

        profile.applyToLocalSettings()
        let captured = UserProfile.capturingLocalSettings()

        XCTAssertEqual(captured.threadQueue, true)
        XCTAssertEqual(captured.draftsOnly, false)
        XCTAssertEqual(captured.triageScope, "unread")
        XCTAssertEqual(captured.appearance, "dark")
    }

    /// The account not carrying an answer means it has not caught up, not that the user
    /// withdrew it — and resuming body fetches is the one direction this setting must never
    /// fail in.
    func testAnAbsentHeadersOnlyAnswerDoesNotRevokeThePrivacyChoice() {
        UserDefaults.standard.set(true, forKey: MailHeadersOnly.storageKey)

        UserProfile().applyToLocalSettings()
        XCTAssertEqual(UserDefaults.standard.object(forKey: MailHeadersOnly.storageKey) as? Bool, true)

        // An account that says otherwise still wins; only absence is ignored.
        var changed = UserProfile()
        changed.mailHeadersOnly = false
        changed.applyToLocalSettings()
        XCTAssertEqual(UserDefaults.standard.object(forKey: MailHeadersOnly.storageKey) as? Bool, false)
    }

    func testSigningOutWipesTheSettingsThatBelongedToTheAccount() {
        UserDefaults.standard.set(true, forKey: MailHeadersOnly.storageKey)
        UserDefaults.standard.set(true, forKey: ThreadQueue.storageKey)
        UserDefaults.standard.set("dark", forKey: AppearanceSetting.storageKey)
        UserDefaults.standard.set(false, forKey: DraftsOnly.storageKey)

        UserProfile.clearLocalSettings()

        for key in [MailHeadersOnly.storageKey, ThreadQueue.storageKey,
                    AppearanceSetting.storageKey, DraftsOnly.storageKey] {
            XCTAssertNil(UserDefaults.standard.object(forKey: key), "\(key) survived sign-out")
        }
    }

    func testTheOnboardingGateIsNotWrittenWhileTheFlowIsOnScreen() {
        var profile = UserProfile()
        profile.hasCompletedOnboarding = true
        profile.threadQueue = true

        profile.applyToLocalSettings(completingOnboarding: false)
        XCTAssertNil(UserDefaults.standard.object(forKey: OnboardingState.storageKey))
        // Every other setting still arrives during the flow.
        XCTAssertEqual(UserDefaults.standard.object(forKey: ThreadQueue.storageKey) as? Bool, true)

        profile.applyToLocalSettings(completingOnboarding: true)
        XCTAssertEqual(UserDefaults.standard.object(forKey: OnboardingState.storageKey) as? Bool, true)
    }

    func testOnlyANeverChosenProfileIsEmpty() {
        XCTAssertTrue(UserProfile().isEmpty)

        var off = UserProfile()
        off.threadQueue = false
        XCTAssertFalse(off.isEmpty, "An explicit off is a choice, not an empty profile")
    }

    func testAWorkspaceReplacesItsOwnFieldsAndClearsTheOnesItOmits() throws {
        var account = UserProfile()
        account.draftsOnly = false
        account.mailFooterEnabled = true
        account.triageScope = "unread"
        account.threadQueue = true
        account.appearance = "dark"

        var workspace = UserProfile()
        workspace.draftsOnly = true
        workspace.threadQueue = false      // not a workspace field — must be ignored

        let effective = try account.replacingWorkspaceSettings(with: workspace)

        XCTAssertEqual(effective.draftsOnly, true)
        XCTAssertNil(effective.mailFooterEnabled, "A workspace the field is absent from clears it")
        XCTAssertNil(effective.triageScope)
        XCTAssertEqual(effective.threadQueue, true)
        XCTAssertEqual(effective.appearance, "dark")
    }
}
