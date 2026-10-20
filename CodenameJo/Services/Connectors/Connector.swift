import Foundation

/// What one profile has of a connector, read from this phone.
struct ConnectorStatus {
    /// The accounts connected under the profile, as Settings labels them: an email, a workspace, a
    /// login, a server name.
    var accounts: [String] = []
    /// The subset whose credential the service refused. Settings offers Reconnect; the prompt gets a note.
    var needsReauth: [String] = []
    /// Whether this build can sign in to the service at all (`JO_SLACK_CLIENT_ID`, `JO_GITHUB_CLIENT_ID`).
    var available = false
    /// Tool definitions the service listed itself, for a connector whose tools are not in `LiveToolSchemas`.
    var dynamicTools: [[String: Any]] = []

    init(accounts: [String] = [], needsReauth: [String] = [], available: Bool = false,
         dynamicTools: [[String: Any]] = []) {
        self.accounts = accounts
        self.needsReauth = needsReauth
        self.available = available
        self.dynamicTools = dynamicTools
    }

    /// The accounts a call can act from.
    var working: [String] { accounts.filter { !needsReauth.contains($0) } }
    var isConnected: Bool { !working.isEmpty }
}

/// A service Jo signs in to and calls from this phone. One value per service in `ConnectorRegistry.all`,
/// and everything that once named each connector in turn — session setup, prompt facts, tool routing,
/// sign-out, History, coaching — iterates that list instead. A new connector is a new value there.
protocol Connector: Sendable {
    /// Keys prompt facts (`<id>NeedsReauth`), coaching lessons (`<id>_connect`, `<id>_…`) and fixtures.
    /// Never changes once shipped.
    var id: String { get }
    var displayName: String { get }
    /// The History chip's glyph. Nil keeps the connector out of History's service list.
    var historyIcon: String? { get }
    /// The glyph on a running tool's step row.
    var toolIcon: String { get }
    /// `prompts/skills/<skill>.md`; nil when the connector has no skill text.
    var skill: String? { get }
    /// `prompts/notes/<reauthNote>.md`, containing `{{which}}`.
    var reauthNote: String? { get }
    /// Only the dispatch worker gets the tools; the live call hands every ask over.
    var dispatchOnly: Bool { get }
    /// Appended to `dispatch`'s description while connected.
    var dispatchNote: String? { get }
    /// Words in the user's turn that file it under this service in History.
    var inferenceKeywords: [String] { get }
    /// The wire prefix narration strips to reach the table's bare name (`github_`).
    var toolPrefix: String? { get }
    /// The bundled schemas (`LiveToolSchemas`), in the order a session declares them.
    var schemas: [[String: Any]] { get }
    /// Every tool name, in that order.
    var toolNames: [String] { get }

    func owns(_ tool: String) -> Bool
    func writes(_ tool: String) -> Bool
    /// A tool that reads no mail step, so a feed that moved mid-turn is no reason to refuse it.
    func isFeedIndependent(_ tool: String) -> Bool

    /// The definitions a live session declares for this standing, in order.
    func sessionTools(_ status: ConnectorStatus, catalog: LiveSessionSetup.Catalog) -> [[String: Any]]
    /// The definitions a dispatched job declares.
    func workerTools(_ status: ConnectorStatus, catalog: LiveSessionSetup.Catalog) -> [[String: Any]]
    /// Facts for `LivePrompt.Facts`; `<id>NeedsReauth` when anything needs reconnecting.
    func promptFacts(_ status: ConnectorStatus) -> [String: Any]
    /// The prompt's note for the accounts whose credential was refused; empty for none.
    func reauthText(_ accounts: [String], text: LivePrompt.Text) throws -> String

    /// What the profile has, from the Keychain. Never the network.
    func status(profileId: String?) -> ConnectorStatus
    /// The same at dial, where a token may be renewed or a tool list refreshed.
    func dialStatus(profileId: String?) async -> ConnectorStatus

    /// Run one of this connector's tools on the profile's own grant. Failures come back as text.
    func run(_ name: String, argumentsJSON: String, profileId: String?) async -> FullDuplexBroker.ToolResult

    /// Sign-out: every grant on this phone goes.
    func forget()
    /// Account deletion: revoke every grant with the service. `forget` follows.
    func revokeAll() async
    /// Profile deletion: revoke and drop what was connected under it.
    func forgetProfile(_ profileId: String) async
}

extension Connector {
    var dispatchOnly: Bool { false }
    var dispatchNote: String? { nil }
    var toolPrefix: String? { nil }
    var toolNames: [String] { schemas.compactMap { $0["name"] as? String } }

    func owns(_ tool: String) -> Bool { toolNames.contains(tool) }
    func isFeedIndependent(_ tool: String) -> Bool { owns(tool) && !writes(tool) }

    func sessionTools(_ status: ConnectorStatus, catalog: LiveSessionSetup.Catalog) -> [[String: Any]] {
        dispatchOnly || !status.isConnected ? [] : toolNames.map { catalog.tool($0) }
    }

    func workerTools(_ status: ConnectorStatus, catalog: LiveSessionSetup.Catalog) -> [[String: Any]] {
        status.isConnected ? toolNames.map { catalog.tool($0) } : []
    }

    func promptFacts(_ status: ConnectorStatus) -> [String: Any] {
        status.needsReauth.isEmpty ? [:] : [id + "NeedsReauth": status.needsReauth]
    }

    func reauthText(_ accounts: [String], text: LivePrompt.Text) throws -> String {
        guard let reauthNote else { return "" }
        return try LivePrompt.reauthNote(reauthNote, displayName, accounts, text: text)
    }

    func dialStatus(profileId: String?) async -> ConnectorStatus { status(profileId: profileId) }
}
