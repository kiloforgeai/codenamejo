import Combine
import FactoryKit
import Foundation

/// Profiles live on this phone (`WorkspaceProfileRows`): each one holds a set of mailboxes, its
/// own workspace settings and its dossier.
@MainActor
class WorkspaceProfileStore: ObservableObject {
    @Injected(\.backend) private var backend
    @Injected(\.workspaceProfileRows) private var rows
    @Published var profiles: [WorkspaceProfile] = []
    @Published var selected: WorkspaceProfile?
    @Published var connections: [WorkspaceProfileConnection] = []
    @Published var capabilities = WorkspaceProfileCapabilities.unavailable
    @Published var isSwitching = false
    @Published var error: String?
    @Published var needsConnection = false
    private var owner: String?
    private var loaded = false
    private var revision = 0
    private var openingPreparation: Task<Void, Never>?
    private var openingPreparationID = UUID()
    /// Which profile `connections` was read for — so the published scope only carries
    /// an email filter that actually belongs to the selected profile.
    private var connectionsProfileId: String?
    /// The addresses last seen connected, in their own spelling, for display.
    private var knownAccounts: [String] = []
    var enabled: Bool { capabilities.management }
    var contextOwner: String {
        guard let owner = backend.userId else { return "" }
        guard let selected, !selected.isDefault else { return owner }
        return owner + ":profile:" + selected.id
    }

    func resetForSignOut() {
        openingPreparationID = UUID()
        openingPreparation?.cancel()
        openingPreparation = nil
        revision += 1
        selected = nil; owner = nil; loaded = false; connectionsProfileId = nil; knownAccounts = []
        profiles = []; connections = []; capabilities = .unavailable; error = nil; needsConnection = false
        publishScope()
    }

    private func publishScope() {
        ProfileRuntime.install(selected.map { .init(
            profileId: $0.id, isDefault: $0.isDefault,
            emails: connectionsProfileId == $0.id ? connections.map { $0.email.lowercased() } : nil,
            canSwitch: capabilities.liveSwitch && profiles.count > 1,
            membershipRevision: $0.revision) })
    }

    /// One profile's mailboxes, spelled as connected, with the reconnect state Connections last read.
    func connections(of profileId: String) throws -> [WorkspaceProfileConnection] {
        guard let owner = backend.userId else { throw BackendError.notSignedIn }
        let reauth = Set(Container.shared.connections().allNeedsReauth.map { $0.lowercased() })
        return try rows.mailboxes(userId: owner, profileId: profileId).map { email in
            let spelled = knownAccounts.first { $0.lowercased() == email } ?? email
            return WorkspaceProfileConnection(id: email, email: spelled, profileId: profileId, needsReauth: reauth.contains(email))
        }
    }

    /// Re-read the selected profile's mailboxes and republish the scope.
    func refreshConnections() async {
        guard loaded, let selected else { return }
        do {
            connections = try connections(of: selected.id)
            connectionsProfileId = selected.id
            publishScope()
        } catch {
            RealtimeLog.log("profiles: connection refresh failed — \(error.localizedDescription)")
        }
    }

    /// Every mailbox the account has connected. One that no profile holds yet joins the profile
    /// the user is in when it first appears — the one they connected it from.
    func adopt(_ accounts: [String]) async {
        knownAccounts = accounts
        guard let owner = backend.userId else { return }
        do {
            if !loaded || self.owner != owner { try await load() }
            guard let destination = selected ?? profiles.first(where: \.isDefault) else { return }
            try rows.adopt(userId: owner, emails: accounts, into: destination.id)
        } catch {
            RealtimeLog.log("profiles: mailbox adoption failed — \(error.localizedDescription)")
            return
        }
        await refreshConnections()
    }

    /// A removed mailbox leaves its profile.
    func forget(_ email: String) {
        guard let owner = backend.userId else { return }
        do { try rows.forget(userId: owner, email: email) }
        catch { RealtimeLog.log("profiles: could not unmap \(email) — \(error.localizedDescription)") }
    }

    private func syncFeedProfiles() async {
        await Container.shared.localTriage().updateProfileCatalog(
            current: selected, profiles: profiles, enabled: capabilities.liveSwitch)
    }

    private var selectionKey: String { "workspaceProfile.selected." + (backend.userId ?? "") }

    func load() async throws {
        guard let owner = backend.userId else { throw BackendError.notSignedIn }
        let version = revision
        let catalog = try rows.list(userId: owner)
        guard version == revision, backend.userId == owner else { throw BackendError.notSignedIn }
        if self.owner != owner { selected = nil; connectionsProfileId = nil }
        self.owner = owner
        profiles = catalog
        capabilities = WorkspaceProfileCapabilities(management: true, liveSwitch: true, deletion: true)
        selected = profiles.first { $0.id == (selected?.id ?? UserDefaults.standard.string(forKey: selectionKey)) }
            ?? profiles.first(where: \.isDefault)
        loaded = true
        if let selected {
            // A profile with no saved settings yet keeps the ones in effect.
            if try rows.settings(userId: owner, profileId: selected.id) == nil {
                try rows.saveSettings(UserProfile.capturingLocalSettings(), userId: owner, profileId: selected.id)
            }
            connections = try connections(of: selected.id)
            connectionsProfileId = selected.id
        }
        publishScope()
        await syncFeedProfiles()
        prepareProfileOpenings(store: Container.shared.mailStore())
    }

    func prepareProfileOpenings(store: MailStore) {
        guard openingPreparation == nil, loaded, let userId = backend.userId else { return }
        let destinations = profiles
        guard !destinations.isEmpty else { return }
        let preparationID = UUID()
        openingPreparationID = preparationID
        let accountSettings = UserProfile.capturingLocalSettings()
        let activeId = selected?.id
        openingPreparation = Task { [weak self] in
            guard let self else { return }
            defer { if self.openingPreparationID == preparationID { self.openingPreparation = nil } }
            for profile in destinations {
                guard !Task.isCancelled, self.backend.userId == userId else { return }
                do {
                    let mailboxes = try self.connections(of: profile.id)
                    let overrides = profile.id == activeId ? accountSettings
                        : try self.rows.settings(userId: userId, profileId: profile.id) ?? UserProfile()
                    let preferences = try accountSettings.replacingWorkspaceSettings(with: overrides)
                    guard preferences.mailHeadersOnly != true else { continue }
                    let ownedMailboxes = mailboxes.filter { !$0.needsReauth }
                    var keys: [LiveEmailPresentation.Key] = []
                    for mailbox in ownedMailboxes {
                        keys += await LocalTriageQueue.openingPreparationCandidates(
                            account: mailbox.email.lowercased(), store: store, grouping: preferences.threadQueue ?? ThreadQueue.defaultValue,
                            preferred: preferences.triageScope.flatMap(LocalTriageQueue.Scope.init(rawValue:)) ?? .unread)
                    }
                    guard !Task.isCancelled, self.backend.userId == userId else { return }
                    await Container.shared.liveEmailOpening().warm(
                        keys,
                        scope: .init(profileId: profile.id, isDefault: profile.isDefault,
                                     emails: ownedMailboxes.map { $0.email.lowercased() },
                                     mailHeadersOnly: preferences.mailHeadersOnly ?? false,
                                     suggestedActions: preferences.suggestedActions ?? SuggestedActions.accountDefault), userId: userId)
                    RealtimeLog.log("openingSummary: warming \(keys.count) destination candidate(s) for \(profile.id)")
                } catch { RealtimeLog.log("openingSummary: destination unavailable — \(error.localizedDescription)") }
            }
        }
    }

    /// Switch the active profile in place; a live call re-scopes without teardown. A failed
    /// switch leaves the old scope fully installed.
    func choose(_ profile: WorkspaceProfile) async {
        guard !isSwitching, profile.id != selected?.id || error != nil else { return }
        isSwitching = true
        revision += 1
        error = nil
        defer { isSwitching = false }
        let started = Date()
        let mark = { (phase: String) in
            RealtimeLog.log("profileSwitch: choose \(phase) +\(Int(Date().timeIntervalSince(started) * 1000))ms")
        }
        do {
            if !loaded || owner != backend.userId { try await load(); mark("loaded") }
            guard let owner, profiles.contains(where: { $0.id == profile.id }) else { throw WorkspaceProfileError.notFound }
            // The outgoing profile keeps the settings it had; the destination brings its own.
            if let outgoing = selected {
                try rows.saveSettings(UserProfile.capturingLocalSettings(), userId: owner, profileId: outgoing.id)
            }
            let destination = try connections(of: profile.id)
            let settings = try rows.settings(userId: owner, profileId: profile.id) ?? UserProfile()
            let dossier = Container.shared.profileDossier().context(owner: owner, profileId: profile.id)
            mark("destination read")
            try Container.shared.userProfile().applyWorkspaceSettings(settings)
            selected = profile
            connections = destination
            connectionsProfileId = profile.id
            needsConnection = destination.isEmpty
            publishScope()
            Container.shared.realtimeService().installProfileDossier(dossier, profileId: profile.id)
            // Synchronous, so a call that reads them next sees the destination's commands.
            Container.shared.customCommands().refresh()
            UserDefaults.standard.set(profile.id, forKey: selectionKey)
            // The account's settings row mirrors the active profile, which the server still reads.
            Task {
                if !(await Container.shared.userProfile().flush()) {
                    RealtimeLog.log("profileSwitch: \(profile.id) settings not yet saved to the account")
                }
            }
            // Beside the queue teardown, not after; both stores drop results whose scope has moved on.
            Task {
                await Container.shared.connections().refresh()
                await Container.shared.commandStore().refresh()
            }
            // The local queue drops its list and cursor synchronously; the next opening
            // step walks the destination's accounts and resumes their own day snapshot.
            await Container.shared.localTriage().end()
            // The Slack cursor belongs to the old profile's workspaces.
            await Container.shared.localSlack().end()
            mark("queues ended")
            // Background scoring covers only the active profile's mailboxes, so a profile first
            // reached by switching mid-call walks unbanded. Score it now, off the switch's turn.
            let store = Container.shared.mailStore()
            Task.detached(priority: .utility) {
                for account in ProfileRuntime.allowedMailAccounts(GoogleAccountStore.mailAccounts()) {
                    await Container.shared.mailImportance().score(account: account, store: store)
                }
            }
            await Container.shared.localTriage().configureProfileHandoff(
                current: selected, profiles: profiles, enabled: capabilities.liveSwitch)
            mark("handoff configured")
        } catch {
            mark("failed — \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    /// Delete a profile, disconnecting its inboxes. Deleting the active profile switches
    /// to the default first, so the live scope never points at a profile that is gone.
    func delete(_ profile: WorkspaceProfile) async {
        guard !profile.isDefault else { error = WorkspaceProfileError.cannotDeleteDefault.errorDescription; return }
        error = nil
        if profile.id == selected?.id, let fallback = profiles.first(where: \.isDefault) {
            await choose(fallback)
            guard error == nil else { return }
        }
        do {
            guard let owner = backend.userId else { throw BackendError.notSignedIn }
            let held = try connections(of: profile.id)
            for mailbox in held { await Container.shared.connections().disconnectGmail(mailbox.email) }
            for grant in NotionTools.grants(profileId: profile.id) {
                await RemoteMCPAuth.revoke(grant)
                RemoteMCPGrantStore.remove(grant.id, .notion)
            }
            do { try rows.delete(userId: owner, id: profile.id) }
            catch WorkspaceProfileError.notFound { /* Already gone — deletion is idempotent. */ }
            // Queued voice notes attributed to the deleted profile have nowhere to run; drop them with it.
            Container.shared.memoQueue().purge(profileId: profile.id)
            do { try Container.shared.customCommandRows().purge(userId: owner, profileId: profile.id) }
            catch { RealtimeLog.log("commands: profile purge failed — \(error.localizedDescription)") }
            try await load()
        } catch { self.error = error.localizedDescription }
    }

    func connectedEmail() async {
        do {
            try await load()
            if !connections.isEmpty { needsConnection = false }
        } catch { self.error = error.localizedDescription }
    }

    func create(_ name: String) async throws {
        guard let owner = backend.userId else { throw BackendError.notSignedIn }
        let profile = try rows.create(userId: owner, name: name)
        try await load()
        await choose(profile)
    }
    func rename(_ profile: WorkspaceProfile, name: String) async throws {
        guard let owner = backend.userId else { throw BackendError.notSignedIn }
        _ = try rows.rename(userId: owner, id: profile.id, name: name)
        try await load()
    }

    /// Create without activating and without `load()`, which mid-call can re-resolve `selected`
    /// to the default. Used by the voice create.
    func createUnselected(_ name: String) async throws -> WorkspaceProfile {
        guard let owner = backend.userId else { throw BackendError.notSignedIn }
        let profile = try rows.create(userId: owner, name: name)
        guard loaded, self.owner == owner, !profiles.contains(where: { $0.id == profile.id }) else { return profile }
        profiles.append(profile)
        publishScope()
        await syncFeedProfiles()
        return profile
    }

    /// Rename in place without `load()`. Both `profiles` and `selected` must move, or
    /// `switch_profile` and the picker keep the old name.
    func renameInPlace(_ profile: WorkspaceProfile, name: String) async throws -> WorkspaceProfile {
        guard let owner = backend.userId else { throw BackendError.notSignedIn }
        let renamed = try rows.rename(userId: owner, id: profile.id, name: name)
        if let index = profiles.firstIndex(where: { $0.id == renamed.id }) { profiles[index] = renamed }
        if selected?.id == renamed.id { selected = renamed }
        publishScope()
        await syncFeedProfiles()
        return renamed
    }

    func dossierEnabled(for profileId: String) throws -> Bool {
        guard let owner = backend.userId else { throw BackendError.notSignedIn }
        return try rows.dossierEnabled(userId: owner, profileId: profileId)
    }

    func setDossierEnabled(_ enabled: Bool, for profileId: String) throws {
        guard let owner = backend.userId else { throw BackendError.notSignedIn }
        try rows.setDossierEnabled(enabled, userId: owner, profileId: profileId)
    }

    /// Resolve a spoken profile name. Exact but case-blind, after the punctuation a model
    /// leaves on a dictated name — an unmatched `Work.` would be unreachable by voice for good.
    func profile(named spoken: String) -> WorkspaceProfile? {
        let wanted = WorkspaceProfileStore.spokenName(spoken)
        return profiles.first { $0.name.compare(wanted, options: [.caseInsensitive]) == .orderedSame }
    }

    static func spokenName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D}'\u{2018}\u{2019}.!?"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
