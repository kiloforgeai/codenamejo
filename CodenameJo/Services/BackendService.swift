import FactoryKit
import Foundation
import GRDB

enum BackendError: LocalizedError, Equatable {
    case notSignedIn
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn:     return "Sign in required."
        case .invalidResponse: return "Something went wrong. Please try again."
        }
    }
}

/// Who is signed in on this phone. There is no account server: the identity is
/// `InstallIdentity`, and being signed in means a Google grant from the first consent is in the
/// Keychain (`GoogleAccountStore`).
@MainActor
class BackendService: ObservableObject {
    static let shared = BackendService()

    /// The install id while signed in, nil while signed out — the `user_id` on every local row.
    @Published var userId: String?

    /// Whether someone is signed in. Seeded at launch from both the `UserDefaults` flag and the
    /// Keychain grant — see `SignedInFlag` for why either alone is wrong.
    @Published var isSignedIn = false

    /// The previous account's local Google-data teardown. The next sign-in awaits it, so a new
    /// session cannot read or refill a cache that belongs to the account that left.
    private var cachedMailPurgeTask: Task<Void, Never>?

    init(restoringSession: Bool = true) {
        guard restoringSession, SignedInFlag.isSet, !GoogleAccountStore.all().isEmpty,
              let id = InstallIdentity.current else { return }
        userId = id
        isSignedIn = true
    }

    /// Who is signed in, from the grant the first consent stored.
    func sessionUser() -> SessionUser {
        guard isSignedIn, let grant = GoogleAccountStore.primary() else { return .none }
        let user = SessionUser(name: grant.displayName, email: grant.email)
        if let userId { VoiceNotesDefault.claim(for: userId) }
        return user
    }

    // MARK: - Sign in

    /// Finish signing in once the first Google consent is stored.
    func completeSignIn() async throws {
        // `isSignedIn = true` starts a refresh; before this barrier it would race the old purge
        // and either restore departed mail or delete the new account's first cache rows.
        await cachedMailPurgeTask?.value
        cachedMailPurgeTask = nil
        guard let id = InstallIdentity.current else { throw BackendError.notSignedIn }
        SignedInFlag.set(true)
        userId = id
        _ = sessionUser()
        isSignedIn = true
    }

    /// Clear any stored session and every local trace of the account. Onboarding is reset too,
    /// so sign-out lands on the first onboarding screen.
    func signOut() {
        Container.shared.workspaceProfiles().resetForSignOut()
        OnboardingMailModeReplay.request()
        // Google's API Services User Data Policy requires deleting the mail cache on sign-out.
        // Non-blocking; a purge interrupted by app termination is repeated on next launch.
        purgeCachedMail()
        // Both go: the cache alone leaves a phone that can refill it, the grant alone leaves mail on disk.
        forgetGoogleGrant()
        GitHubAccountStore.removeAll()
        GranolaConnector.forget()
        CustomMCPConnector.forget()
        forgetSlackGrants()
        // Notion's grants and its client registration are this account's too.
        RemoteMCPGrantStore.removeAll(.notion)
        // The detached purges below must delete this account's rows, not whatever is on disk when they run.
        let signedOutOwner = userId
        userId = nil
        SignedInFlag.clear()
        // Before `isSignedIn` flips, so `RootView` doesn't flash the sign-in screen for a frame.
        OnboardingState.reset()
        OnboardingResume.finish()
        isSignedIn = false
        // Profile-backed settings are removed now, not left for the next sign-in to overwrite.
        UserProfile.clearLocalSettings()
        // The trace flag is per-handset, not on the profile, but a staff tool must not stay armed.
        FullDuplexTrace.clearLocal()
        UserDefaults.standard.removeObject(forKey: SuggestedActions.accountDefaultKey)
        VoiceNotesDefault.clear()
        // Here, not at the Settings button, because account deletion and an expired-session 401
        // also end here. Detached: a failed delete must not hold up the UI.
        let outbox = Container.shared.turnSaveOutbox()
        let profileRows = Container.shared.workspaceProfileRows()
        let categoryRows = Container.shared.emailCategoryRows()
        let commandRows = Container.shared.customCommandRows()
        Task.detached(priority: .utility) {
            guard let signedOutOwner else { return }
            await outbox.purge(owner: signedOutOwner)
            do { try await profileRows.purgeDossiers(userId: signedOutOwner) }
            catch { print("profileDossier: sign-out purge failed: \(error.localizedDescription)") }
            do { try await categoryRows.purge(userId: signedOutOwner) }
            catch { print("emailCategory: sign-out purge failed: \(error.localizedDescription)") }
            do { try await commandRows.purge(userId: signedOutOwner) }
            catch { print("customCommand: sign-out purge failed: \(error.localizedDescription)") }
        }
        Task.detached(priority: .utility) {
            let store = Container.shared.localContext()
            await store.purge(userId: signedOutOwner)
            // Scoped to the account that signed out, so a quick next sign-in keeps its own turns.
            await TurnStore(database: store.dbPool).purge(userId: signedOutOwner)
        }
        // Synchronous: a live service holds this queue and would drain it into the next session.
        Container.shared.memoQueue().discardEverything()
        // The dispatch log is on this phone now, and its answers are the previous account's mail.
        Container.shared.dispatchJobs().removeAll()
        // The in-memory history; `refresh` stands down while signed out, so nothing else clears it.
        Container.shared.commandStore().commands = []
        Container.shared.customCommands().commands = []
    }

    // MARK: - Local data

    /// Delete every cached message and its sync state — the whole table, since the Google
    /// address `MailStore.purge(account:)` needs is already gone by sign-out.
    private func purgeCachedMail() {
        let dbPool = Container.shared.localContext().dbPool
        let mail = Container.shared.mailStore()
        // Calendar and contacts: same restricted-scope data, same deletion obligation.
        let calendar = CalendarStore(database: dbPool)
        let contacts = ContactStore(database: dbPool)
        let dailyQueue = Container.shared.localTriage()
        let cleanup = Container.shared.emailCleanup()
        let openingSummary = Container.shared.liveEmailOpening()
        let previous = cachedMailPurgeTask
        cachedMailPurgeTask = Task.detached(priority: .utility) {
            // Chain rather than replace: both orphan cleanup and sign-out request teardown.
            await previous?.value
            await BackgroundMailRefresh.waitUntilIdle()
            await cleanup.cancelAll()
            await openingSummary.discard()
            await dailyQueue.end()
            await mail.purgeAll()
            await calendar.purgeAll()
            await contacts.purgeAll()
            await MailStore.logCleanupCounts(database: dbPool)
        }
    }

    /// Drop every Google grant this device holds, and the access tokens minted from them.
    /// Local only: Google still honours the grant until it is revoked (`deleteAccount`) or the
    /// user removes the app from their Google Account.
    private func forgetGoogleGrant() {
        GoogleAccountStore.removeAll()
        GoogleCredential.invalidateCache()
    }

    /// Slack tokens and the Slack queue go with the account, same as Google's grants.
    private func forgetSlackGrants() {
        SlackGrantStore.removeAll()
        let slackQueue = Container.shared.localSlack()
        let cache = Container.shared.slackQueueCache()
        Task.detached(priority: .utility) {
            await slackQueue.end()
            await cache.purgeAll()
        }
    }

    /// Signed-out launches discard both app and Google credentials left in Keychain.
    func dropOrphanedGoogleGrant() {
        guard !isSignedIn else { return }
        RealtimeLog.log("credential cleanup: signed-out launch")
        forgetGoogleGrant()
        // Keychain items outlive deleting the app; a GitHub token must not outlive the account.
        GitHubAccountStore.removeAll()
        GranolaConnector.forget()
        CustomMCPConnector.forget()
        forgetSlackGrants()
        RemoteMCPGrantStore.removeAll(.notion)
        purgeCachedMail()
    }

    /// Deletes everything held for the signed-in user, revokes grants, then signs out (App Store
    /// Guideline 5.1.1(v)). Throws without signing out if the local delete fails, so they can retry.
    func deleteAccount() async throws {
        guard let owner = userId else { throw BackendError.notSignedIn }
        guard let dbPool = Container.shared.localContext().dbPool else { throw BackendError.invalidResponse }
        try await dbPool.write { db in
            for (table, column) in try InstallIdentity.ownedTables(db) {
                try db.execute(sql: "DELETE FROM \(table) WHERE \(column) = ? OR substr(\(column), 1, ?) = ?",
                               arguments: [owner, owner.count + 9, owner + ":profile:"])
            }
        }
        for grant in GoogleAccountStore.all() { await GoogleTokenServer.revoke(grant.refreshToken) }
        for grant in RemoteMCPGrantStore.grants(.granola) { await RemoteMCPAuth.revoke(grant) }
        for grant in SlackGrantStore.all() { await SlackOAuth.revoke(grant) }
        for grant in RemoteMCPGrantStore.grants(.notion) { await RemoteMCPAuth.revoke(grant) }
        for server in CustomMCPServerStore.all() { await CustomMCPConnector.remove(server) }
        signOut()
        // The next sign-in on this phone is somebody new.
        InstallIdentity.reset()
    }
}

// MARK: - Session

/// The signed-in user, as `BackendService.sessionUser()` describes them.
struct SessionUser: Sendable {
    let name: String?
    let email: String?

    /// Nobody is signed in. Draws no half-filled header.
    static let none = SessionUser(name: nil, email: nil)
}
