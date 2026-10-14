import Combine
import FactoryKit
import Foundation
import UIKit

/// Keeps the signed-in user's settings, which live on this phone in `UserDefaults` and the profile rows.
/// Changes are detected by capturing the whole profile on every `UserDefaults` change and comparing.
@MainActor
final class UserProfileStore: ObservableObject {
    /// What the Settings screen says about where these settings live.
    enum State: Equatable {
        case signedOut
        case loading
        case saving
        /// Held on the account, as of this moment.
        case saved(Date)
        case failed(String)
    }

    @Published private(set) var state: State = .signedOut

    /// Whether a load has finished, failed, or there is no session. Not `state != .loading`,
    /// which is also true between sign-in and `loadOrUpload` setting `.loading`.
    @Published private(set) var hasSettled = false

    /// Set the moment a local change is seen, cleared only by a successful
    /// upload. Persisted because the whole point is surviving a launch.
    private static let unsavedKey = "userProfileHasUnsavedChanges"
    /// Which account the local settings belong to. Never cleared on sign-out, so the same user
    /// signing back in keeps the meaning of their unsaved-change flag.
    private static let ownerKey = "userProfileOwnerUserId"

    @Injected(\.backend) private var backend

    /// The profile as last seen locally — the thing every `UserDefaults` change is
    /// compared against. Seeded in `start()` so a launch doesn't read the unchanged
    /// settings as an edit.
    private var lastKnown: UserProfile?
    private var observers: Set<AnyCancellable> = []
    private var isApplyingLoadedProfile = false

    /// Begin watching. Called once, from the root interactor at launch.
    func start() {
        guard observers.isEmpty else { return }

        // Before the sinks below, so the keys a launch writes for its own reasons are not
        // compared against `nil` and uploaded as edits by a store that has not loaded yet.
        lastKnown = UserProfile.capturingLocalSettings()

        // Sign-in and sign-out are the two events that change whose settings these
        // are. The initial value arrives on subscribe, which is the launch load.
        backend.$isSignedIn
            .removeDuplicates()
            .sink { [weak self] signedIn in
                guard let self else { return }
                if signedIn {
                    self.hasSettled = false
                    Task { await self.loadOrUpload() }
                } else {
                    // Nothing is cleared here — see `ownerKey`.
                    self.state = .signedOut
                    // Nothing to wait for: a signed-out launch settles immediately.
                    self.hasSettled = true
                }
            }
            .store(in: &observers)

        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            // Sliders emit continuously while dragging; one gesture is one write.
            .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveIfChanged() }
            .store(in: &observers)

        // Backgrounding inside the debounce window would lose the write, so check immediately.
        NotificationCenter.default
            .publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in self?.saveIfChanged() }
            .store(in: &observers)
    }

    /// Whether an applied profile may end onboarding. In memory only; `OnboardingFlow` holds it
    /// false while it runs.
    var completesOnboarding = true

    // MARK: - Loading

    /// Load the profiles, then save this device's settings as the profile.
    func loadOrUpload() async {
        guard backend.isSignedIn else {
            state = .signedOut
            hasSettled = true
            return
        }
        state = .loading
        defer { hasSettled = true }
        do {
            try await Container.shared.workspaceProfiles().load()
            // This device's settings are the profile, so tuning done during onboarding survives sign-in.
            lastKnown = nil
            UserDefaults.standard.set(backend.userId, forKey: Self.ownerKey)
            await upload(UserProfile.capturingLocalSettings())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Merge the broker's saved first-mailbox choice before another whole-profile upload.
    func applyOnboardingMailPreference(_ preference: OnboardingMailPreference, for owner: String?) async {
        guard backend.isSignedIn, owner != nil, backend.userId == owner,
              UserDefaults.standard.string(forKey: EmailOnboardingContract.mailModeAccountKey) != preference.account
        else { return }
        await inFlightUpload?.value
        guard backend.isSignedIn, backend.userId == owner,
              UserDefaults.standard.string(forKey: EmailOnboardingContract.mailModeAccountKey) != preference.account
        else { return }
        UserDefaults.standard.set(preference.account, forKey: EmailOnboardingContract.mailModeAccountKey)
        if let draftsOnly = preference.draftsOnly {
            DraftsOnly.set(draftsOnly, for: preference.account)
        }
        if !(await flush()) {
            RealtimeLog.log("onboarding: saved mail preference is pending local profile synchronization")
        }
    }

    private var isChangingMailMode = false

    /// Save a spoken mode choice through the same account synchronization as Settings.
    func setMailMode(mode: String, account: String? = nil) async -> (output: String, saved: Bool) {
        guard !isChangingMailMode else {
            return ("A mail mode change is still being saved. Wait for its result before changing it again.", false)
        }
        isChangingMailMode = true
        defer { isChangingMailMode = false }
        let profiles = Container.shared.workspaceProfiles()
        let owner = backend.userId
        let snapshot = ProfileRuntime.snapshot
        let scope = snapshot?.profileId
        guard let scope, let accounts = snapshot?.emails, !accounts.isEmpty,
              backend.isSignedIn, owner != nil, !profiles.isSwitching,
              mode == "send" || mode == "drafts" else {
            return ("Mail mode was not changed. Choose send or drafts in the active profile.", false)
        }
        let requested = account?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let mailbox: String
        if !requested.isEmpty {
            guard let matched = accounts.first(where: { $0.lowercased() == requested }) else {
                return ("Mail mode was not changed. Choose an email account in the active profile: \(accounts.joined(separator: ", ")).", false)
            }
            mailbox = matched
        } else {
            guard accounts.count == 1, let only = accounts.first else {
                return ("Mail mode was not changed. This profile has multiple inboxes. Ask which email account to change: \(accounts.joined(separator: ", ")).", false)
            }
            mailbox = only
        }
        guard await flush(), backend.userId == owner,
              ProfileRuntime.snapshot?.profileId == scope,
              ProfileRuntime.snapshot?.emails == accounts, !profiles.isSwitching else {
            return ("Mail mode was not changed because the current settings could not be saved or the profile changed.", false)
        }
        DraftsOnly.set(mode == "drafts", for: mailbox)
        guard await flush(), backend.userId == owner,
              ProfileRuntime.snapshot?.profileId == scope, !profiles.isSwitching else {
            return ("The mail mode change is not confirmed saved. Do not claim it took effect; settings synchronization needs a retry.", false)
        }
        return ("Saved for \(mailbox): \(mode == "drafts" ? "future mail stays in Drafts" : "future requested mail can be sent"). This applies during this call. Existing drafts were not sent.", true)
    }

    // MARK: - Saving

    /// Upload the current settings if they differ from the last profile seen.
    private func saveIfChanged() {
        guard let pending = pendingChange() else { return }
        track(pending)
    }

    /// The same write, awaited, for callers that cannot wait out the debounce. Returns whether the
    /// row is now current; on failure `unsavedKey` survives and the next launch retries.
    func flush() async -> Bool {
        if let pending = pendingChange() {
            let task = track(pending)
            await task.value
        } else {
            // The debounced path claims `lastKnown` before its write completes, so await that write.
            await inFlightUpload?.value
            if UserDefaults.standard.bool(forKey: Self.unsavedKey) {
                // A failed upload claimed lastKnown already; explicitly retry its saved edit.
                await track(UserProfile.capturingLocalSettings()).value
            }
        }
        // A read failure does not mean there are unflushed writes. Let reload retry.
        return !UserDefaults.standard.bool(forKey: Self.unsavedKey)
    }

    /// The tail of the upload chain, so `flush()` can wait on a write it did not start. Never cleared.
    private var inFlightUpload: Task<Void, Never>?

    /// Chain rather than replace: two overlapping writes to one row would race, and the
    /// later one is the one the user meant.
    @discardableResult
    private func track(_ profile: UserProfile) -> Task<Void, Never> {
        let previous = inFlightUpload
        let owner = backend.userId
        let scope = ProfileRuntime.snapshot?.profileId
        let task = Task {
            await previous?.value
            guard self.backend.isSignedIn, self.backend.userId == owner,
                  ProfileRuntime.snapshot?.profileId == scope else { return }
            await self.upload(profile)
        }
        inFlightUpload = task
        return task
    }

    /// Capture the local settings and mark them unsaved if they differ; `nil` when there is nothing to write.
    private func pendingChange() -> UserProfile? {
        guard !isApplyingLoadedProfile else { return nil }
        let current = UserProfile.capturingLocalSettings()
        guard current != lastKnown else { return nil }
        lastKnown = current
        // Before the write, so a failed one is still known about at next launch.
        UserDefaults.standard.set(true, forKey: Self.unsavedKey)
        return current
    }

    /// Installs a profile's own settings. Left unclaimed, so the next save mirrors them to the account.
    func applyWorkspaceSettings(_ scoped: UserProfile) throws {
        let merged = try UserProfile.capturingLocalSettings().replacingWorkspaceSettings(with: scoped)
        isApplyingLoadedProfile = true
        defer { isApplyingLoadedProfile = false }
        merged.applyToLocalSettings(completingOnboarding: false)
    }

    private func upload(_ profile: UserProfile) async {
        guard backend.isSignedIn else {
            state = .signedOut
            return
        }
        // The settings already live in `UserDefaults` and the profile rows; nothing leaves the phone.
        lastKnown = profile
        UserDefaults.standard.set(false, forKey: Self.unsavedKey)
        state = .saved(Date())
    }
}
