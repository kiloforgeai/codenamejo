import FactoryKit
import XCTest
@testable import CodenameJo

/// The launch window, where the store is watching `UserDefaults` but has not yet heard
/// from the account. A key written in it must not read as an edit — an upload started
/// there runs before the profile scope resolves and lands in the wrong row.
@MainActor
final class UserProfileStoreLaunchTests: XCTestCase {

    /// `UserProfileStore.unsavedKey`, which is private. Named here rather than widened:
    /// the test is about the behaviour that flag drives, not about reaching it.
    private let unsavedKey = "userProfileHasUnsavedChanges"
    private let scratchKey = "userProfileStoreLaunchTestsScratch"

    /// These write the real `UserDefaults` the production code reads.
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in [unsavedKey, ThreadQueue.storageKey] {
            if let value = defaults.object(forKey: key) { saved[key] = value }
            defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for key in [unsavedKey, ThreadQueue.storageKey, scratchKey] {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in saved { defaults.set(value, forKey: key) }
        saved = [:]
        super.tearDown()
    }

    /// Signed out, so `upload` returns before it makes a request. What is under test is
    /// whether the store believes there is anything to upload at all.
    private func makeStartedStore() -> UserProfileStore {
        XCTAssertFalse(Container.shared.backend().isSignedIn,
                       "the test host must be signed out, or this exercises the network")
        let store = UserProfileStore()
        store.start()
        return store
    }

    func testAKeyWrittenDuringTheLaunchLoadIsNotAnEdit() async {
        let store = makeStartedStore()

        // Nothing a profile carries — the shape of what a launch writes for its own
        // reasons before the account has answered.
        UserDefaults.standard.set(1, forKey: scratchKey)

        let clean = await store.flush()
        XCTAssertTrue(clean)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: unsavedKey))
    }

    func testARealEditInTheSameWindowIsStillSeen() async {
        let store = makeStartedStore()

        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)

        // Signed out, so the upload cannot succeed and the flag survives for the next
        // launch — which is the whole point of persisting it.
        let clean = await store.flush()
        XCTAssertFalse(clean)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: unsavedKey))
    }
}
