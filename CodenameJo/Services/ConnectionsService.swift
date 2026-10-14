import FactoryKit
import Foundation

/// Per-user connector state for Settings → Connections, read from this phone: an account is
/// connected when its grant is in the Keychain (`GoogleAccountStore`) and needs reconnecting when
/// Google refused its refresh (`invalid_grant`). Consent runs through `GoogleSignInFlow`.
/// One Google consent grants mail and calendar; calendar is a capability of an account, not a connector.
@MainActor
final class ConnectionsService: ObservableObject {
    @Published var gmailAccounts: [String] = []   // connected Google account emails
    /// Subset of `gmailAccounts` whose grant also covers Calendar. Not a separate
    /// connector — see the type doc.
    @Published var calendarAccounts: [String] = []
    /// Subset of `gmailAccounts` whose grant also covers writing Gmail filters
    /// (`gmail.settings.basic`, which `gmail.modify` does not cover).
    @Published var filterAccounts: [String] = []
    /// Connected accounts Google has stopped honouring; they stay in `gmailAccounts` so the row
    /// can offer Reconnect. A refresh that failed on a Google 5xx is not here: it repairs itself.
    @Published var gmailNeedsReauth: [String] = []
    /// `gmailNeedsReauth` across every profile; the lists above are the active profile's.
    var allNeedsReauth: [String] = []
    /// Every account this phone holds a grant for, across profiles.
    @Published var deviceGrantAccounts: [String] = []
    @Published var gmailAvailable = false
    /// Connected GitHub logins. What the token may do is `GitHubTools.allowedTools`.
    @Published var githubAccounts: [String] = []
    @Published var githubAvailable = false
    /// Logins whose token GitHub answered 401 to. They stay in `githubAccounts` so the row can offer Reconnect.
    @Published var githubNeedsReauth: [String] = []
    /// The code the user types at github.com/login/device while a sign-in waits on it.
    @Published var githubPendingCode: GitHubDeviceFlow.Code?
    private var githubSignIn: Task<Void, Never>?
    /// Connected Notion workspace names: one Notion connection is one workspace.
    @Published var notionMcpAccounts: [String] = []
    @Published var notionMcpAvailable = false
    /// Workspaces whose MCP credential has been rejected. An expired access token is not here:
    /// it renews on use.
    @Published var notionMcpNeedsReauth: [String] = []
    /// The active profile's Granola accounts, by email, read from `RemoteMCPGrantStore`.
    @Published var granolaAccounts: [String] = []
    @Published var granolaAvailable = false
    /// Accounts whose refresh Granola refused. An expired access token is not here: it renews on use.
    @Published var granolaNeedsReauth: [String] = []
    /// The active profile's own MCP servers, from `CustomMCPServerStore`, each with whether its
    /// credential still works. Always available: there is nothing to configure in the build.
    @Published var customMCPServers: [CustomMCPServerStatus] = []
    @Published var customMCPAvailable = false
    /// The active profile's Slack workspaces, by name, from the Keychain. `slackAvailable` is
    /// whether this build has a Slack app at all (`JO_SLACK_CLIENT_ID`).
    @Published var slackAccounts: [String] = []
    @Published var slackAvailable = false
    /// Workspaces whose refresh Slack refused, or whose refresh token passed its 30 days.
    @Published var slackNeedsReauth: [String] = []

    /// Whether the status has been read yet. Before it has, "nothing is connected" is unknown,
    /// and must not gate the mic.
    @Published var hasLoadedStatus = false
    /// True only when the current profile's status read failed. A profile switch clears
    /// the previous scope before requesting the new one, so account names and counts can
    /// never bleed across profiles while this flag is shown.
    @Published var statusLoadFailed = false
    /// Which connector is mid-request (`"gmail"`, `"github"`, `"notion"` or `"slack"`) — nil when idle.
    @Published var busyConnector: String?
    @Published var errorMessage: String?
    /// Which connector `errorMessage` belongs to, same vocabulary as
    /// `busyConnector`. Set together with it, cleared together with it.
    @Published var errorConnector: String?

    /// Provider name for each Settings account row that needs reconnecting.
    var attentionProviderNames: [String] {
        let gmailAttention = gmailAccounts.filter { email in
            gmailNeedsReauth.contains(email)
                || !hasCalendar(email)
                || !hasFilters(email)
                || !hasDeviceGrant(email)
        }.map { _ in "Gmail" }
        let notionAttention = notionMcpAccounts.filter {
            notionMcpNeedsReauth.contains($0)
        }.map { _ in "Notion" }
        let granolaAttention = granolaAccounts.filter {
            granolaNeedsReauth.contains($0)
        }.map { _ in "Granola" }
        let slackAttention = slackAccounts.filter { slackNeedsReauth.contains($0) }.map { _ in "Slack" }
        let githubAttention = githubNeedsReauth.map { _ in "GitHub" }
        let customAttention = customMCPServers.filter(\.needsReauth).map { _ in "Custom MCP" }
        return gmailAttention + notionAttention + granolaAttention + slackAttention + githubAttention + customAttention
    }

    var attentionCount: Int {
        attentionProviderNames.count
    }

    /// Home can be specific only when one Settings row needs repair.
    var singleAttentionProviderName: String? {
        let names = attentionProviderNames
        return names.count == 1 ? names[0] : nil
    }

    @Injected(\.backend) private var backend

    private var loadedStatusScope: String?

    /// Whether the assistant has anything to act on; the home screen refuses the mic without it.
    /// Unknown counts as yes — see `hasLoadedStatus`.
    var hasAnyConnector: Bool {
        !hasLoadedStatus
            || !gmailAccounts.isEmpty
            || !notionMcpAccounts.isEmpty
            || !granolaAccounts.isEmpty
            || !slackAccounts.isEmpty
            || !githubAccounts.isEmpty
            || !customMCPServers.isEmpty
    }

    /// The `CommandRecord.serviceName` values this account can reach now, for History's filter
    /// chips. `General` is where turns that touched no service land.
    var connectedServices: [String] {
        var names: [String] = []
        if !gmailAccounts.isEmpty { names.append("Gmail") }
        if !calendarAccounts.isEmpty { names.append("Calendar") }
        if !slackAccounts.isEmpty { names.append("Slack") }
        if !notionMcpAccounts.isEmpty { names.append("Notion") }
        if !granolaAccounts.isEmpty { names.append("Granola") }
        if !githubAccounts.isEmpty { names.append("GitHub") }
        names.append("General")
        return names
    }

    /// Whether this account's grant covers Calendar.
    func hasCalendar(_ email: String) -> Bool { calendarAccounts.contains(email) }

    /// Whether this account's grant covers writing standing mail rules.
    func hasFilters(_ email: String) -> Bool { filterAccounts.contains(email) }

    // MARK: - Status

    /// Re-read every list from the Keychain.
    func refresh() async {
        let grants = GoogleAccountStore.all()
        let everyMailbox = grants.map(\.email)
        // First: on a first sign-in this creates the default profile every list below is narrowed to.
        await Container.shared.workspaceProfiles().adopt(everyMailbox)
        let requestedProfile = ProfileRuntime.snapshot?.profileId
        let requestedOwner = backend.userId
        let requestedScope = (requestedOwner ?? "signed-out") + ":" + (requestedProfile ?? "legacy")
        if requestedScope != loadedStatusScope {
            clearPublishedStatus()
        }
        deviceGrantAccounts = everyMailbox
        allNeedsReauth = grants.filter { $0.needsReauth == true }.map(\.email)
        guard requestedProfile == ProfileRuntime.snapshot?.profileId, requestedOwner == backend.userId else { return }
        gmailAccounts = ProfileRuntime.allowedMailAccounts(everyMailbox)
        calendarAccounts = ProfileRuntime.allowedMailAccounts(grants.filter { grant in
            grant.scopes.contains { $0.hasPrefix("https://www.googleapis.com/auth/calendar") }
        }.map(\.email))
        filterAccounts = ProfileRuntime.allowedMailAccounts(grants.filter {
            $0.scopes.contains(GmailManageTools.filterScope)
        }.map(\.email))
        gmailNeedsReauth = ProfileRuntime.allowedMailAccounts(allNeedsReauth)
        gmailAvailable = GoogleTokenServer.isConfigured
        let granola = GranolaConnector.grants(profileId: requestedProfile)
        granolaAccounts = granola.map(\.label)
        granolaNeedsReauth = granola.filter(\.needsReauth).map(\.label)
        granolaAvailable = true
        customMCPServers = CustomMCPConnector.servers(profileId: requestedProfile).map(CustomMCPConnector.status)
        customMCPAvailable = true
        refreshSlack()
        let notion = NotionTools.grants(profileId: requestedProfile)
        notionMcpAccounts = notion.map(\.label)
        notionMcpNeedsReauth = notion.filter(\.needsReauth).map(\.label)
        notionMcpAvailable = true
        let github = GitHubAccountStore.all()
        githubAccounts = github.map(\.login)
        githubNeedsReauth = github.filter { $0.needsReauth == true }.map(\.login)
        githubAvailable = !AppHosts.githubClientID.isEmpty
        hasLoadedStatus = true
        statusLoadFailed = false
        loadedStatusScope = requestedScope
        RealtimeLog.log(
            "connections: refresh applied — \(connectedServices) · "
            + "inboxes \(gmailAccounts.joined(separator: ", "))"
            + (gmailNeedsReauth.isEmpty ? "" : " · needs reauth \(gmailNeedsReauth.joined(separator: ", "))"))
    }

    private func clearPublishedStatus() {
        gmailAccounts = []
        calendarAccounts = []
        filterAccounts = []
        gmailNeedsReauth = []
        allNeedsReauth = []
        gmailAvailable = false
        notionMcpAccounts = []
        notionMcpAvailable = false
        notionMcpNeedsReauth = []
        granolaAccounts = []
        granolaAvailable = false
        granolaNeedsReauth = []
        customMCPServers = []
        customMCPAvailable = false
        slackAccounts = []
        slackAvailable = false
        slackNeedsReauth = []
        githubAccounts = []
        githubNeedsReauth = []
        githubAvailable = false
        hasLoadedStatus = false
        statusLoadFailed = false
        loadedStatusScope = nil
    }

    // MARK: - Disconnect (one account)

    /// Give every newly connected inbox its own send/draft answer, Drafts, so it never inherits the
    /// account-wide fallback. A reconnect of an existing inbox keeps its setting.
    private func claimNewInboxes(knownBefore: [String]) {
        for email in gmailAccounts where !knownBefore.contains(where: {
            $0.caseInsensitiveCompare(email) == .orderedSame
        }) {
            DraftsOnly.set(true, for: email)
            RealtimeLog.log("connect: \(email) — new inbox, set to drafts only")
        }
    }

    /// Revokes the grant with Google and drops this phone's copy and cached mail — "Remove"
    /// reads as one thing.
    func disconnectGmail(_ email: String) async {
        // The signed-in account is not disconnectable; refused here as well as in the Settings menu.
        let signedIn = backend.sessionUser().email
        if let signedIn, signedIn.caseInsensitiveCompare(email) == .orderedSame {
            RealtimeLog.log("disconnect: \(email) refused — it is the signed-in account")
            fail("gmail", "That's the account you're signed in with. Sign out to remove it.")
            return
        }
        let grant = GoogleAccountStore.grant(for: email)
        if let grant {
            RealtimeLog.log("disconnect: \(email) — revoking the grant with Google")
            await GoogleTokenServer.revoke(grant.refreshToken)
        }
        let hadGrant = grant != nil
        GoogleAccountStore.remove(email)
        GoogleCredential.invalidateCache(for: email)
        await Container.shared.emailCleanup().cancel(account: email)
        RealtimeLog.log(
            "disconnect: \(email) — device grant \(hadGrant ? "removed" : "was not held")")
        // Drop the in-memory cursor with the snapshot so another account cannot inherit it.
        await Container.shared.localTriage().end()
        // The mail goes with the grant: the same deletion obligation sign-out meets.
        let purged = await Container.shared.mailStore()
            .purge(account: email)
        RealtimeLog.log("disconnect: \(email) — purged \(purged) cached message(s)")
        // The send/draft answer goes too, so reconnecting the same address starts in Drafts.
        DraftsOnly.forget(email)
        Container.shared.workspaceProfiles().forget(email)
        // Calendar is a capability of the same account; its cache goes with the mail cache.
        let calendarPurged = await CalendarStore(database: Container.shared.localContext().dbPool)
            .purge(account: email)
        RealtimeLog.log("disconnect: \(email) — purged \(calendarPurged) cached event(s)")
        // Recount now: the next pass is throttled, and `.manual` is the trigger with no floor.
        await BackgroundMailRefresh.run(trigger: .manual)
        await BackgroundCalendarRefresh.run(trigger: .manual)
        await refresh()
        RealtimeLog.log(
            "disconnect: \(email) — done. \(gmailAccounts.count) inbox(es) left: "
            + "\(gmailAccounts.joined(separator: ", "))")
    }

    /// Drops this phone's token. Revoking it needs the OAuth App's secret, which the app does not
    /// ship, so the grant survives under GitHub → Settings → Applications until the user removes it.
    func disconnectGithub(_ login: String) async {
        GitHubAccountStore.remove(login: login)
        RealtimeLog.log("disconnect: github @\(login) — token removed from this phone")
        await refresh()
    }

    // MARK: - Slack

    /// The active profile's workspaces; one whose refresh token outlived its 30 days is marked now,
    /// so the reconnect shows before anything tries to use it.
    private func refreshSlack() {
        for grant in SlackGrantStore.all() where grant.needsReauth != true && grant.refreshExpired() {
            SlackGrantStore.markNeedsReauth(grant.teamId)
        }
        let grants = SlackGrantStore.inProfile()
        slackAvailable = SlackConfig.isConfigured
        slackAccounts = grants.map(\.teamName)
        slackNeedsReauth = grants.filter { $0.needsReauth == true }.map(\.teamName)
    }

    /// Connect or reconnect a workspace: one PKCE consent straight to Slack. Bound to the active
    /// profile; a reconnect of the same workspace replaces its grant.
    func connectSlack() {
        Task { await connectSlackNow() }
    }

    private func connectSlackNow() async {
        busyConnector = "slack"
        clearError()
        switch await SlackSignInFlow.run(profileId: ProfileRuntime.snapshot?.profileId) {
        case .failure(.cancelled):
            busyConnector = nil
        case .failure(.failed(let message)):
            busyConnector = nil
            fail("slack", message)
        case .success(let grant):
            RealtimeLog.log("slack connect: \(grant.teamName) — scopes \(grant.scopes)")
            await Container.shared.slackQueueCache().purgeAll()
            await refresh()
            busyConnector = nil
        }
    }

    /// Revokes the token with Slack and drops this phone's copy.
    func disconnectSlack(_ workspace: String) async {
        for grant in SlackGrantStore.inProfile() where grant.teamName == workspace {
            await SlackOAuth.revoke(grant)
            SlackGrantStore.remove(grant.teamId)
            RealtimeLog.log("disconnect: Slack \(workspace) — grant removed")
        }
        await Container.shared.localSlack().end()
        await Container.shared.slackQueueCache().purgeAll()
        await refresh()
    }

    /// Revokes the active profile's Notion grant with Notion (best effort) and forgets it here.
    func disconnectNotionMcp(_ workspace: String) async {
        let profileId = ProfileRuntime.snapshot?.profileId
        for grant in NotionTools.grants(profileId: profileId) where grant.label == workspace {
            await RemoteMCPAuth.revoke(grant)
            RemoteMCPGrantStore.remove(grant.id, .notion)
            RealtimeLog.log("disconnect: Notion \(workspace) — grant removed")
        }
        await refresh()
    }

    /// Record an error against the connector that produced it, so Settings can
    /// show it next to that connector's button rather than in a shared footer.
    private func fail(_ connector: String, _ message: String) {
        errorMessage = message
        errorConnector = connector
    }

    private func clearError() {
        errorMessage = nil
        errorConnector = nil
    }

    // MARK: - Google connect

    /// Connect or reconnect a Google account: one consent through the token server, its grant
    /// stored in the Keychain.
    ///
    /// - Parameter reconnecting: an already-connected address, preselected on Google's picker.
    ///   Omit to add a new account.
    func connectGmail(reconnecting email: String? = nil) {
        Task { await connectGoogle(hint: email) }
    }

    private func connectGoogle(hint: String?) async {
        busyConnector = "gmail"
        clearError()
        // A later account never displaces the primary — adding one is not a request to
        // change which inbox syncs.
        let isPrimary = GoogleCredential.storedAccounts().isEmpty
        let knownBefore = gmailAccounts

        switch await GoogleSignInFlow.run(hint: hint, isPrimary: isPrimary) {
        case .failure(.cancelled):
            busyConnector = nil
        case .failure(.failed(let message)):
            busyConnector = nil
            fail("gmail", message)
        case .success(let outcome):
            let already = knownBefore.contains { $0.caseInsensitiveCompare(outcome.email) == .orderedSame }
            RealtimeLog.log("google connect: consent returned \(outcome.email) — "
                + (hint.map { "reconnect of \($0)" } ?? (already ? "an inbox already connected" : "a new inbox"))
                + " · scopes \(outcome.scopes.count)")
            await refresh()
            await Container.shared.workspaceProfiles().connectedEmail()
            claimNewInboxes(knownBefore: knownBefore)
            busyConnector = nil
            // Fetch the new mailbox now; `.manual` is the trigger with no floor.
            await BackgroundMailRefresh.run(trigger: .manual)
        }
    }

    /// Whether this phone holds a grant for `email`.
    func hasDeviceGrant(_ email: String) -> Bool {
        deviceGrantAccounts.contains { $0.caseInsensitiveCompare(email) == .orderedSame }
    }

    /// Connect or reconnect GitHub through the device flow: show the code, wait for the user to
    /// enter it on GitHub, then store the token. Reconnecting the same login replaces its token.
    func connectGithub() {
        githubSignIn?.cancel()
        githubSignIn = Task { await runGithubDeviceFlow() }
    }

    func cancelGithubConnect() {
        githubSignIn?.cancel()
    }

    private func runGithubDeviceFlow() async {
        let clientID = AppHosts.githubClientID
        busyConnector = "github"
        clearError()
        defer {
            githubPendingCode = nil
            if busyConnector == "github" { busyConnector = nil }
        }
        let code: GitHubDeviceFlow.Code
        switch await GitHubDeviceFlow.requestCode(clientID: clientID) {
        case .failure(let failure):
            RealtimeLog.log("github connect: no device code — \(failure)")
            if let message = failure.message { fail("github", message) }
            return
        case .success(let issued): code = issued
        }
        githubPendingCode = code
        RealtimeLog.log("github connect: waiting for the code to be entered (every \(Int(code.interval))s, "
            + "expires in \(Int(code.expiresIn))s)")
        let token: String, scopes: [String]
        switch await GitHubDeviceFlow.waitForToken(code, clientID: clientID) {
        case .failure(let failure):
            RealtimeLog.log("github connect: ended — \(failure)")
            if let message = failure.message { fail("github", message) }
            return
        case .success(let granted): (token, scopes) = granted
        }
        githubPendingCode = nil
        switch await GitHubDeviceFlow.identify(token: token) {
        case .failure(let failure):
            fail("github", failure.message ?? "GitHub sign-in failed.")
        case .success(let identity):
            let saved = GitHubAccountStore.save(.init(id: identity.id, login: identity.login, token: token,
                                                      scopes: scopes, connectedAt: Date()))
            RealtimeLog.log("github connect: @\(identity.login) — scopes \(scopes.joined(separator: " "))"
                + (saved ? "" : " · KEYCHAIN SAVE FAILED"))
            if !saved { fail("github", "GitHub connected, but this phone couldn't store the token.") }
        }
        await refresh()
    }

    /// Connect Notion to the active profile: PKCE sign-in against Notion's MCP, the grant kept in
    /// the Keychain. One workspace per profile: a reconnect replaces the profile's grant.
    func connectNotionMcp() {
        Task { await connectNotion() }
    }

    private func connectNotion() async {
        busyConnector = "notion-mcp"
        clearError()
        let profileId = ProfileRuntime.snapshot?.profileId
        switch await RemoteMCPAuth.signIn(.notion, label: "Notion", profileId: profileId) {
        case .failure(.cancelled):
            busyConnector = nil
        case .failure(.failed(let message)):
            busyConnector = nil
            fail("notion-mcp", message)
        case .success(let grant):
            let replaced = NotionTools.grants(profileId: profileId)
            guard RemoteMCPGrantStore.save(grant, .notion) else {
                busyConnector = nil
                fail("notion-mcp", "Couldn't save the Notion connection on this phone.")
                return
            }
            for old in replaced where old.id != grant.id { RemoteMCPGrantStore.remove(old.id, .notion) }
            RealtimeLog.log("notion connect: saved for profile \(profileId ?? "none")"
                + (replaced.isEmpty ? "" : ", replacing \(replaced.count)"))
            busyConnector = nil
            await refresh()
        }
    }

    // MARK: - Granola

    /// Sign in to Granola for the active profile. `replacing` is the row being reconnected.
    func connectGranola(replacing account: String? = nil) {
        Task { await connectGranolaNow(replacing: account) }
    }

    private func connectGranolaNow(replacing account: String?) async {
        busyConnector = "granola"
        clearError()
        switch await GranolaConnector.connect(profileId: ProfileRuntime.snapshot?.profileId, replacing: account) {
        case .success, .failure(.cancelled):
            break
        case .failure(.failed(let message)):
            fail("granola", message)
        }
        busyConnector = nil
        await refresh()
    }

    func disconnectGranola(_ account: String) async {
        clearError()
        await GranolaConnector.disconnect(account)
        await refresh()
    }

    // MARK: - Custom MCP

    /// Add a server to the active profile. True once it is saved with its tools listed; false
    /// leaves the reason in `errorMessage` under `"custom-mcp"`.
    func addCustomMCP(name: String, endpoint: String, auth: CustomMCPServer.Auth, token: String) async -> Bool {
        busyConnector = "custom-mcp"
        clearError()
        defer { busyConnector = nil }
        guard let url = CustomMCPConnector.endpoint(from: endpoint) else {
            fail("custom-mcp", "Enter the server's full https:// address.")
            return false
        }
        switch await CustomMCPConnector.add(name: name, endpoint: url, auth: auth, token: token,
                                            profileId: ProfileRuntime.snapshot?.profileId, ownerId: backend.userId) {
        case .success:
            await refresh()
            return true
        case .failure(.cancelled):
            return false
        case .failure(.failed(let message)):
            fail("custom-mcp", message)
            return false
        }
    }

    /// Replace the server's credential and list its tools again. `token` is read for a bearer server.
    func reconnectCustomMCP(_ id: String, token: String) async -> Bool {
        guard let server = CustomMCPServerStore.server(id: id) else { return false }
        busyConnector = "custom-mcp"
        clearError()
        defer { busyConnector = nil }
        let outcome = await CustomMCPConnector.reconnect(server, token: token)
        await refresh()
        switch outcome {
        case .success: return true
        case .failure(.cancelled): return false
        case .failure(.failed(let message)):
            fail("custom-mcp", message)
            return false
        }
    }

    func refreshCustomMCPTools(_ id: String) async {
        guard let server = CustomMCPServerStore.server(id: id) else { return }
        busyConnector = "custom-mcp"
        clearError()
        if case .failure(.failed(let message)) = await CustomMCPConnector.refreshTools(server) {
            fail("custom-mcp", message)
        }
        busyConnector = nil
        await refresh()
    }

    func removeCustomMCP(_ id: String) async {
        guard let server = CustomMCPServerStore.server(id: id) else { return }
        clearError()
        await CustomMCPConnector.remove(server)
        await refresh()
    }
}
