import XCTest
@testable import CodenameJo

/// The OpenAI key outlives a delete in the Keychain, like the Google grant, so it counts only with
/// the note `save` writes to the container — `SessionFlagsTests` has the rule.
final class OpenAIKeyReinstallTests: XCTestCase {
    private let suite = "OpenAIKeyReinstallTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testAFreshInstallDropsTheKeyADeletedOneLeft() {
        var dropped = false
        let result = OpenAIKeyService.dropIfLeftByDeletedInstall(defaults: defaults, signedIn: false) {
            dropped = true
            return true
        }
        XCTAssertTrue(result)
        XCTAssertTrue(dropped)
        XCTAssertFalse(defaults.bool(forKey: OpenAIKeyService.savedHereKey), "only `save` writes the note")
    }

    func testAnInstallThatSavedItsKeyKeepsIt() {
        defaults.set(true, forKey: OpenAIKeyService.savedHereKey)
        var dropped = false
        OpenAIKeyService.dropIfLeftByDeletedInstall(defaults: defaults, signedIn: false) {
            dropped = true
            return true
        }
        XCTAssertFalse(dropped)
    }

    /// Signed out and not deleted is the same container, so sign-out keeps the phone's key.
    func testASignedOutInstallThatSavedItsKeyKeepsIt() {
        defaults.set(true, forKey: OpenAIKeyService.savedHereKey)
        var dropped = false
        OpenAIKeyService.dropIfLeftByDeletedInstall(defaults: defaults, signedIn: false) {
            dropped = true
            return true
        }
        XCTAssertFalse(dropped)
        XCTAssertTrue(defaults.bool(forKey: OpenAIKeyService.savedHereKey))
    }

    func testASignedInInstallFromBeforeTheNoteKeepsItsKeyAndTakesTheNote() {
        var dropped = false
        OpenAIKeyService.dropIfLeftByDeletedInstall(defaults: defaults, signedIn: true) {
            dropped = true
            return true
        }
        XCTAssertFalse(dropped)
        XCTAssertTrue(defaults.bool(forKey: OpenAIKeyService.savedHereKey), "adopted, so the next launch doesn't ask")
    }

    /// A phone with nothing left in the Keychain is the common fresh install.
    func testAFreshInstallWithNoLeftoverIsQuiet() {
        let result = OpenAIKeyService.dropIfLeftByDeletedInstall(defaults: defaults, signedIn: false) { false }
        XCTAssertFalse(result)
        XCTAssertFalse(defaults.bool(forKey: OpenAIKeyService.savedHereKey))
    }
}
