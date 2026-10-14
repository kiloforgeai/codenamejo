import XCTest
@testable import CodenameJo

/// The `UserDefaults` flag that describes the session rather than a setting: whether this
/// install believes it is signed in.
///
/// It is clearable because iOS keeps Keychain
/// items across a delete, so a reinstall that read "signed in" came back as somebody who had
/// just removed the app. Clearing therefore has to *remove* the key rather than write `false`,
/// so that a sign-out and a fresh install look identical to every reader.
final class SessionFlagsTests: XCTestCase {

    private var savedSignedIn: Any?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedSignedIn = defaults.object(forKey: SignedInFlag.storageKey)
        SignedInFlag.clear()
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        SignedInFlag.clear()
        if let savedSignedIn { defaults.set(savedSignedIn, forKey: SignedInFlag.storageKey) }
        super.tearDown()
    }

    // MARK: - Signed in

    func testAFreshInstallIsNotSignedIn() {
        XCTAssertFalse(SignedInFlag.isSet)
        XCTAssertNil(UserDefaults.standard.object(forKey: SignedInFlag.storageKey))
    }

    func testSigningInAndBackOutAgainRoundTrips() {
        SignedInFlag.set(true)
        XCTAssertTrue(SignedInFlag.isSet)

        SignedInFlag.set(false)
        XCTAssertFalse(SignedInFlag.isSet)
    }

    /// The distinction the reinstall bug turns on: an explicit `false` is a value, and a sign-out
    /// has to leave no value at all.
    func testSigningOutRemovesTheNoteRatherThanWritingItFalse() {
        SignedInFlag.set(true)

        SignedInFlag.clear()

        XCTAssertFalse(SignedInFlag.isSet)
        XCTAssertNil(
            UserDefaults.standard.object(forKey: SignedInFlag.storageKey),
            "a reinstall and a sign-out must look the same to every reader")
    }

    // MARK: - Not a setting

    func testTheFlagDoesNotTravelOnTheAccountProfile() throws {
        SignedInFlag.set(true)

        let encoded = try JSONEncoder().encode(UserProfile.capturingLocalSettings())
        let fields = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertNil(fields[SignedInFlag.storageKey])
    }

    /// Renaming the key reads as absent on every install that already has one — which is
    /// "signed out", so a tidier name costs the flag on exactly the phones that have it.
    func testTheStoredKeyIsTheOneShippedBuildsAlreadyWrote() {
        XCTAssertEqual(SignedInFlag.storageKey, "isLoggedIn")
    }
}
