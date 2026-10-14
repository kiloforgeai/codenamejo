// coverage-target: CodenameJo/Models/OnboardingState.swift

import XCTest

@testable import CodenameJo

/// The one flag that decides whether the app shows the onboarding flow or the voice
/// screen.
///
/// `RootView` reads it on every launch, so the two ways it can be wrong are both whole-app
/// failures: a default of true on a fresh install skips the flow for somebody who has
/// never seen it, and a reset that leaves a stored `false` behind has to read exactly like
/// a device that was never onboarded or the next sign-in decides from the wrong shape.
/// `UserProfileStore` mirrors this key onto the account, which is why `reset()` removes it
/// rather than writing the opposite.
///
/// These write the real `UserDefaults` the production code reads, so whatever this device
/// already had is put back afterwards.
final class OnboardingGateStateTests: XCTestCase {

    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: OnboardingState.storageKey)
        UserDefaults.standard.removeObject(forKey: OnboardingState.storageKey)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: OnboardingState.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: OnboardingState.storageKey)
        }
        saved = nil
        super.tearDown()
    }

    // MARK: - A device that has never been through it

    /// A fresh install has no key, and that has to mean *not yet onboarded*.
    func testAFreshInstallHasNotBeenOnboarded() {
        XCTAssertNil(UserDefaults.standard.object(forKey: OnboardingState.storageKey))
        XCTAssertFalse(OnboardingState.isComplete)
    }

    /// The account can carry the field as an explicit `false`; it means the same thing as
    /// no key, not "decided, and the answer was yes".
    func testAStoredFalseAlsoMeansNotOnboarded() {
        UserDefaults.standard.set(false, forKey: OnboardingState.storageKey)
        XCTAssertFalse(OnboardingState.isComplete)
    }

    // MARK: - Finishing the flow

    func testFinishingTheFlowStoresTrue() {
        OnboardingState.complete()

        XCTAssertEqual(
            UserDefaults.standard.object(forKey: OnboardingState.storageKey) as? Bool, true)
        XCTAssertTrue(OnboardingState.isComplete)
    }

    /// The last step can be reached twice — a profile landing mid-flow re-renders it — so
    /// completing again must not undo the answer.
    func testCompletingTwiceStaysComplete() {
        OnboardingState.complete()
        OnboardingState.complete()
        XCTAssertTrue(OnboardingState.isComplete)
    }

    func testCompletingOverwritesAnEarlierFalse() {
        UserDefaults.standard.set(false, forKey: OnboardingState.storageKey)
        OnboardingState.complete()
        XCTAssertTrue(OnboardingState.isComplete)
    }

    // MARK: - Walking it again

    /// **Removed, not set to false.** A stored `false` and an absent key read the same
    /// through `isComplete`, but they are different rows once `UserProfileStore` mirrors
    /// one of them — so the reset has to leave the device in the shape a fresh install is
    /// in, which is no key at all.
    func testResettingLeavesNoKeyBehindRatherThanAStoredFalse() {
        OnboardingState.complete()
        OnboardingState.reset()

        XCTAssertNil(UserDefaults.standard.object(forKey: OnboardingState.storageKey),
                     "A reset that stores false is not the same state as a fresh install")
        XCTAssertFalse(OnboardingState.isComplete)
    }

    /// Resetting a device that was never onboarded is a no-op rather than a write.
    func testResettingAnUntouchedDeviceChangesNothing() {
        OnboardingState.reset()

        XCTAssertNil(UserDefaults.standard.object(forKey: OnboardingState.storageKey))
        XCTAssertFalse(OnboardingState.isComplete)
    }

    /// The round trip, because that is the sequence a re-walk actually takes.
    func testTheFlowCanBeFinishedAgainAfterAReset() {
        OnboardingState.complete()
        OnboardingState.reset()
        XCTAssertFalse(OnboardingState.isComplete)

        OnboardingState.complete()
        XCTAssertTrue(OnboardingState.isComplete)
    }
}
