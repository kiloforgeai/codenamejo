import Foundation

/// GitHub on this phone: the REST API on the user's token, one connection for every profile.
struct GitHubConnector: Connector {
    static let id = "github"
    var id: String { Self.id }
    var displayName: String { "GitHub" }
    var historyIcon: String? { "chevron.left.forwardslash.chevron.right" }
    var toolIcon: String { "chevron.left.forwardslash.chevron.right" }
    var skill: String? { "github" }
    var reauthNote: String? { "github-reauth" }
    /// `pr ` with a trailing space: bare `contains("pr")` hits "approve", "print" and "surprise".
    var inferenceKeywords: [String] { ["github", "pull request", "pr ", "issue", "repo", "merge", "workflow"] }
    var toolPrefix: String? { GitHubTools.prefix }
    var schemas: [[String: Any]] { LiveToolSchemas.github }
    var toolNames: [String] { GitHubTools.readTools + GitHubTools.writeTools }

    /// Every `github_` name, so one outside ALLOWED_TOOLS is refused by `GitHubTools.run`, not reported as unknown.
    func owns(_ tool: String) -> Bool { GitHubTools.isGitHubTool(tool) }
    func writes(_ tool: String) -> Bool { GitHubTools.writeTools.contains(tool) }
    func isFeedIndependent(_ tool: String) -> Bool { GitHubTools.readTools.contains(tool) }

    /// With an `account` parameter only when more than one login is connected.
    func sessionTools(_ status: ConnectorStatus, catalog: LiveSessionSetup.Catalog) -> [[String: Any]] {
        GitHubTools.definitions(logins: status.working, catalog: catalog)
    }

    func workerTools(_ status: ConnectorStatus, catalog: LiveSessionSetup.Catalog) -> [[String: Any]] {
        GitHubTools.definitions(logins: status.working, catalog: catalog)
    }

    /// Not per profile: one GitHub connection serves every profile.
    func status(profileId: String?) -> ConnectorStatus {
        let accounts = GitHubAccountStore.all()
        return ConnectorStatus(accounts: accounts.map(\.login),
                               needsReauth: accounts.filter { $0.needsReauth == true }.map(\.login),
                               available: !AppHosts.githubClientID.isEmpty)
    }

    func run(_ name: String, argumentsJSON: String, profileId: String?) async -> FullDuplexBroker.ToolResult {
        await GitHubTools.run(name: name, argumentsJSON: argumentsJSON)
    }

    /// Keychain items outlive deleting the app; a GitHub token must not outlive the account.
    func forget() { GitHubAccountStore.removeAll() }

    /// Revoking needs the OAuth App's secret, which the app does not ship, so the grant survives under
    /// GitHub → Settings → Applications until the user removes it.
    func revokeAll() async {}

    func forgetProfile(_ profileId: String) async {}
}
