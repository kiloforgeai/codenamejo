import Foundation

/// Notion on this phone: dispatch-only, so the live call hands every Notion ask to the second agent.
struct NotionConnector: Connector {
    static let id = "notion"
    var id: String { Self.id }
    var displayName: String { "Notion" }
    var historyIcon: String? { "doc.text.fill" }
    var toolIcon: String { "note.text" }
    var skill: String? { "notion" }
    var reauthNote: String? { "notion-reauth" }
    var dispatchOnly: Bool { true }
    var dispatchNote: String? {
        " Notion is the exception: only the second agent has it, so anything in their Notion — "
            + "finding or reading a page or database, filing a note, marking something done — goes here, even a single lookup."
    }
    var inferenceKeywords: [String] { ["notion", "page", "doc", "note", "database"] }
    var schemas: [[String: Any]] { LiveToolSchemas.notion }
    var toolNames: [String] { NotionTools.names }

    /// Every `notion-` name, so a retired verb is refused by `NotionTools.run` rather than reported as unknown.
    func owns(_ tool: String) -> Bool { tool.hasPrefix("notion-") }
    func writes(_ tool: String) -> Bool { NotionTools.writes.contains(tool) }

    func status(profileId: String?) -> ConnectorStatus {
        let grants = NotionTools.grants(profileId: profileId)
        return ConnectorStatus(accounts: grants.map(\.label), needsReauth: grants.filter(\.needsReauth).map(\.label),
                               available: true)
    }

    func run(_ name: String, argumentsJSON: String, profileId: String?) async -> FullDuplexBroker.ToolResult {
        await NotionTools.run(name: name, argumentsJSON: argumentsJSON, profileId: profileId)
    }

    /// The grants and the client registration are this account's too.
    func forget() { RemoteMCPGrantStore.removeAll(.notion) }

    func revokeAll() async {
        for grant in RemoteMCPGrantStore.grants(.notion) { await RemoteMCPAuth.revoke(grant) }
    }

    func forgetProfile(_ profileId: String) async {
        for grant in NotionTools.grants(profileId: profileId) {
            await RemoteMCPAuth.revoke(grant)
            RemoteMCPGrantStore.remove(grant.id, .notion)
        }
    }
}
