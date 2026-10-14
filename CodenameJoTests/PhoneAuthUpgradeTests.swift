import XCTest
@testable import CodenameJo

final class PhoneAuthUpgradeTests: XCTestCase {
    func testUpgradeClearsLegacySessionBeforeMarkingCompletion() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("legacy-session", forKey: "session")
        XCTAssertTrue(PhoneAuthUpgrade.runIfNeeded(defaults: defaults) {
            XCTAssertFalse(defaults.bool(forKey: PhoneAuthUpgrade.storageKey))
            defaults.removeObject(forKey: "session")
        })
        XCTAssertNil(defaults.string(forKey: "session"))
        XCTAssertTrue(defaults.bool(forKey: PhoneAuthUpgrade.storageKey))
    }

    func testRelaunchPreservesNewPhoneSession() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        PhoneAuthUpgrade.runIfNeeded(defaults: defaults) {}
        defaults.set("new-phone-session", forKey: "session")
        let relaunchedDefaults = UserDefaults(suiteName: name)!
        XCTAssertFalse(PhoneAuthUpgrade.runIfNeeded(defaults: relaunchedDefaults) {
            XCTFail("Upgrade must not sign out the new phone session")
        })
        XCTAssertEqual(relaunchedDefaults.string(forKey: "session"), "new-phone-session")
    }

    func testFreshInstallMarksUpgradeEvenWithoutSession() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var resets = 0
        PhoneAuthUpgrade.runIfNeeded(defaults: defaults) { resets += 1 }
        PhoneAuthUpgrade.runIfNeeded(defaults: defaults) { resets += 1 }
        XCTAssertEqual(resets, 1)
    }
}
