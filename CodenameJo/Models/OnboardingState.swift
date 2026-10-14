import Foundation

/// Whether this person has been through onboarding; the only owner of the key. It rides the
/// account, but only the onboarding flow may set it (`UserProfileStore.completesOnboarding`).
enum OnboardingState {
    static let storageKey = "hasCompletedOnboarding"

    static var isComplete: Bool {
        UserDefaults.standard.bool(forKey: storageKey)
    }

    /// Record that onboarding finished. `UserProfileStore` sees the write and uploads
    /// it, which is the same path every other setting takes.
    static func complete() {
        UserDefaults.standard.set(true, forKey: storageKey)
    }

    /// Back to never-onboarded, so `RootView` shows the flow from its first screen.
    /// Removed rather than set false, so this reads identically to a fresh install.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
