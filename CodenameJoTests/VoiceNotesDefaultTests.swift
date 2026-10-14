import XCTest
@testable import CodenameJo

/// The voice-notes default is the account's column, read once per launch.
final class VoiceNotesDefaultTests: XCTestCase {

    override func setUp() {
        super.setUp()
        VoiceNotesDefault.clear()
    }

    override func tearDown() {
        VoiceNotesDefault.clear()
        UserDefaults.standard.removeObject(forKey: VoiceNotesDefault.ownerKey)
        UserDefaults.standard.removeObject(forKey: VoiceSettings.Key.voiceNotes)
        super.tearDown()
    }

    func testAbsentIsOff() {
        XCTAssertNil(UserDefaults.standard.object(forKey: VoiceNotesDefault.storageKey))
        XCTAssertFalse(VoiceNotesDefault.isOn)
    }

    func testAnAnswerIsStoredButWaitsForTheNextLaunch() {
        UserDefaults.standard.set(true, forKey: VoiceNotesDefault.storageKey)

        XCTAssertTrue(UserDefaults.standard.bool(forKey: VoiceNotesDefault.storageKey))
        XCTAssertFalse(VoiceNotesDefault.isOn, "the note pipeline was gated at launch")
    }

    func testSignOutRemovesTheStoredAnswer() {
        UserDefaults.standard.set(true, forKey: VoiceNotesDefault.storageKey)
        VoiceNotesDefault.clear()

        XCTAssertNil(UserDefaults.standard.object(forKey: VoiceNotesDefault.storageKey))
        XCTAssertFalse(VoiceNotesDefault.isOn)
    }

    func testANewAccountDoesNotInheritAnotherAccountsSwitch() {
        UserDefaults.standard.set("staff", forKey: VoiceNotesDefault.ownerKey)
        UserDefaults.standard.set(true, forKey: VoiceSettings.Key.voiceNotes)

        VoiceNotesDefault.claim(for: "new-user")

        XCTAssertNil(UserDefaults.standard.object(forKey: VoiceSettings.Key.voiceNotes))
        XCTAssertFalse(VoiceSettings.voiceNotes)
    }

    func testAnUnownedSwitchIsDropped() {
        UserDefaults.standard.removeObject(forKey: VoiceNotesDefault.ownerKey)
        UserDefaults.standard.set(true, forKey: VoiceSettings.Key.voiceNotes)

        VoiceNotesDefault.claim(for: "new-user")

        XCTAssertNil(UserDefaults.standard.object(forKey: VoiceSettings.Key.voiceNotes))
    }

    func testAnUnownedOffIsKeptSoNotesNeverTurnOnMidLaunch() {
        UserDefaults.standard.removeObject(forKey: VoiceNotesDefault.ownerKey)
        UserDefaults.standard.set(false, forKey: VoiceSettings.Key.voiceNotes)

        VoiceNotesDefault.claim(for: "staff")

        XCTAssertEqual(UserDefaults.standard.object(forKey: VoiceSettings.Key.voiceNotes) as? Bool, false)
    }

    func testStaffDoNotInheritAnotherAccountsOff() {
        UserDefaults.standard.set("external", forKey: VoiceNotesDefault.ownerKey)
        UserDefaults.standard.set(false, forKey: VoiceSettings.Key.voiceNotes)

        VoiceNotesDefault.claim(for: "staff")

        XCTAssertNil(UserDefaults.standard.object(forKey: VoiceSettings.Key.voiceNotes))
    }

    func testAnOptInMadeBeforeTheLookupSurvivesIt() {
        UserDefaults.standard.set("staff", forKey: VoiceNotesDefault.ownerKey)
        UserDefaults.standard.set(true, forKey: VoiceSettings.Key.voiceNotes)
        VoiceNotesDefault.stamp("user")

        VoiceNotesDefault.claim(for: "user")

        XCTAssertTrue(VoiceSettings.voiceNotes)
    }

    func testAnOptInMadeBeforeTheIdIsKnownSurvivesTheLookup() {
        UserDefaults.standard.set("staff", forKey: VoiceNotesDefault.ownerKey)
        UserDefaults.standard.set(true, forKey: VoiceSettings.Key.voiceNotes)
        VoiceNotesDefault.stamp(nil)

        VoiceNotesDefault.claim(for: "user")

        XCTAssertTrue(VoiceSettings.voiceNotes)
        XCTAssertEqual(UserDefaults.standard.string(forKey: VoiceNotesDefault.ownerKey), "user")
    }

    func testSignOutForgetsAnUnclaimedFlip() {
        VoiceNotesDefault.stamp(nil)
        VoiceNotesDefault.clear()

        XCTAssertNil(UserDefaults.standard.string(forKey: VoiceNotesDefault.ownerKey))
    }

    func testAnUnownedOnReadsAsTheAccountDefaultBeforeAnyLookup() {
        UserDefaults.standard.removeObject(forKey: VoiceNotesDefault.ownerKey)
        UserDefaults.standard.set(true, forKey: VoiceSettings.Key.voiceNotes)

        XCTAssertFalse(VoiceSettings.voiceNotes)
        XCTAssertFalse(VoiceNotesDefault.effective(true, owner: nil))
        XCTAssertTrue(VoiceNotesDefault.effective(true, owner: "user"))
        XCTAssertFalse(VoiceNotesDefault.effective(false, owner: nil))
    }

    func testTheSameAccountKeepsItsSwitch() {
        VoiceNotesDefault.claim(for: "user")
        UserDefaults.standard.set(true, forKey: VoiceSettings.Key.voiceNotes)

        VoiceNotesDefault.claim(for: "user")

        XCTAssertTrue(VoiceSettings.voiceNotes)
    }
}
