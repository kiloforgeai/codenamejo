import FactoryKit
import Foundation

/// Slack on this phone: the Web API on the user's token, and a Feed stage of its own (`LocalSlackQueue`).
struct SlackConnector: Connector {
    static let id = "slack"
    var id: String { Self.id }
    var displayName: String { "Slack" }
    var historyIcon: String? { "bubble.left.and.bubble.right.fill" }
    var toolIcon: String { "number" }
    var skill: String? { "slack" }
    var reauthNote: String? { "slack-reauth" }
    var inferenceKeywords: [String] { ["slack"] }
    var schemas: [[String: Any]] { LiveToolSchemas.slack }
    var toolNames: [String] { SlackTools.catalogOrder }

    func writes(_ tool: String) -> Bool { SlackTools.writeNames.contains(tool) }
    /// The Slack queue is a Feed stage, so its tools follow the step the way mail's do.
    func isFeedIndependent(_ tool: String) -> Bool { false }

    /// The queue stays with the live call.
    func workerTools(_ status: ConnectorStatus, catalog: LiveSessionSetup.Catalog) -> [[String: Any]] {
        guard status.isConnected else { return [] }
        return SlackTools.catalogOrder.filter { $0 != SlackTools.queueName }.map { catalog.tool($0) }
    }

    /// A refresh token past its 30 days is marked here, so the reconnect shows before anything tries to use it.
    func status(profileId: String?) -> ConnectorStatus {
        for grant in SlackGrantStore.all() where grant.needsReauth != true && grant.refreshExpired() {
            SlackGrantStore.markNeedsReauth(grant.teamId)
        }
        let grants = SlackGrantStore.inProfile(profileId)
        return ConnectorStatus(accounts: grants.map(\.teamName),
                               needsReauth: grants.filter { $0.needsReauth == true }.map(\.teamName),
                               available: SlackConfig.isConfigured)
    }

    /// Each token renewed if due: a refused renewal or a refresh token past its 30 days needs the user;
    /// a transient failure still serves the tools.
    func dialStatus(profileId: String?) async -> ConnectorStatus {
        var accounts: [String] = [], needsReauth: [String] = []
        for grant in SlackGrantStore.inProfile(profileId) {
            switch await Container.shared.slackCredentials().token(teamId: grant.teamId) {
            case .success:
                accounts.append(grant.teamName)
            case .failure(.needsReauth):
                accounts.append(grant.teamName)
                needsReauth.append(grant.teamName)
            case .failure(.transient(let why)):
                RealtimeLog.log("slack: \(grant.teamName) token unavailable at dial — \(why)")
                accounts.append(grant.teamName)
            case .failure(.notConnected):
                break
            }
        }
        return ConnectorStatus(accounts: accounts, needsReauth: needsReauth, available: SlackConfig.isConfigured)
    }

    func run(_ name: String, argumentsJSON: String, profileId: String?) async -> FullDuplexBroker.ToolResult {
        let result = await SlackTools.run(name: name, argumentsJSON: argumentsJSON,
                                          workspaces: SlackWorkspace.served(profileId: profileId))
        return FullDuplexBroker.ToolResult(text: result.text, ok: result.ok, performedTool: result.written ? name : nil)
    }

    /// Slack tokens and the Slack queue go with the account, same as Google's grants.
    func forget() {
        SlackGrantStore.removeAll()
        let queue = Container.shared.localSlack()
        let cache = Container.shared.slackQueueCache()
        Task.detached(priority: .utility) {
            await queue.end()
            await cache.purgeAll()
        }
    }

    func revokeAll() async {
        for grant in SlackGrantStore.all() { await SlackOAuth.revoke(grant) }
    }

    func forgetProfile(_ profileId: String) async {
        for grant in SlackGrantStore.all() where grant.profileId == profileId {
            await SlackOAuth.revoke(grant)
            SlackGrantStore.remove(grant.teamId)
        }
    }
}
