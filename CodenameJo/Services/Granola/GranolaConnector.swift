import FactoryKit
import Foundation

extension RemoteMCPService {
    /// Granola's hosted MCP. `offline_access` is what makes its authorization server issue a
    /// refresh token; the protected resource's own `mcp` scope is not needed for one.
    static let granola = RemoteMCPService(
        id: "granola", displayName: "Granola",
        endpoint: URL(string: "https://mcp.granola.ai/mcp")!,
        scope: "openid profile email offline_access")
}

/// Granola sign-in, sign-out and the grants a dial serves, all on this phone. Read-only meeting notes.
struct GranolaConnector: Connector {
    static let id = "granola"
    var id: String { Self.id }
    var displayName: String { "Granola" }
    var historyIcon: String? { "text.bubble.fill" }
    var toolIcon: String { "text.bubble.fill" }
    var skill: String? { "granola" }
    var reauthNote: String? { "granola-reauth" }
    var inferenceKeywords: [String] { ["granola"] }
    var schemas: [[String: Any]] { LiveToolSchemas.granola }
    var toolNames: [String] { GranolaTools.names }

    func writes(_ tool: String) -> Bool { false }

    func status(profileId: String?) -> ConnectorStatus {
        let grants = Self.grants(profileId: profileId)
        return ConnectorStatus(accounts: grants.map(\.label), needsReauth: grants.filter(\.needsReauth).map(\.label),
                               available: true)
    }

    func run(_ name: String, argumentsJSON: String, profileId: String?) async -> FullDuplexBroker.ToolResult {
        await GranolaTools.run(name: name, argumentsJSON: argumentsJSON,
                               grants: Self.grants(profileId: profileId).filter { !$0.needsReauth })
    }

    func forget() { Self.forget() }

    func revokeAll() async {
        for grant in RemoteMCPGrantStore.grants(.granola) { await RemoteMCPAuth.revoke(grant) }
    }

    func forgetProfile(_ profileId: String) async {
        for grant in Self.grants(profileId: profileId) {
            await RemoteMCPAuth.revoke(grant)
            RemoteMCPGrantStore.remove(grant.id, .granola)
        }
    }

    // MARK: - Sign-in

    /// The grants connected under the active profile.
    static func grants(profileId: String? = ProfileRuntime.snapshot?.profileId) -> [RemoteMCPGrant] {
        RemoteMCPGrantStore.grants(.granola, profileId: profileId)
    }

    /// Sign in, label the grant with the Granola account's email, and store it. A grant for the
    /// same account, or the one being reconnected, is replaced rather than kept alongside.
    @MainActor
    static func connect(profileId: String?, replacing: String? = nil,
                        transport: any HTTPDataTransport = Container.shared.providerHTTP())
        async -> Result<RemoteMCPGrant, RemoteMCPAuth.SignInFailure> {
        switch await RemoteMCPAuth.signIn(.granola, label: "Granola", profileId: profileId, transport: transport) {
        case .failure(let failure):
            return .failure(failure)
        case .success(var grant):
            if let email = await accountEmail(token: grant.accessToken, transport: transport) {
                grant.label = email
            } else {
                RealtimeLog.log("granola connect: get_account_info named no account; labelled \"Granola\"")
            }
            let label = grant.label
            for old in grants(profileId: profileId) where old.label == label || old.label == replacing {
                RemoteMCPGrantStore.remove(old.id, .granola)
            }
            guard RemoteMCPGrantStore.save(grant, .granola) else {
                return .failure(.failed("Couldn't save the Granola connection on this phone."))
            }
            RealtimeLog.log("granola connect: \(label) connected")
            return .success(grant)
        }
    }

    /// Remove the account's grants from this profile. Granola publishes no revocation endpoint,
    /// so `revoke` is a no-op today; it runs in case one appears.
    static func disconnect(_ label: String, profileId: String? = ProfileRuntime.snapshot?.profileId) async {
        for grant in grants(profileId: profileId) where grant.label == label {
            await RemoteMCPAuth.revoke(grant)
            RemoteMCPGrantStore.remove(grant.id, .granola)
        }
        RealtimeLog.log("granola disconnect: \(label) removed")
    }

    /// Every Granola grant and the client registration, for sign-out.
    static func forget() {
        RemoteMCPGrantStore.removeAll(.granola)
    }

    /// The signed-in account's email, from Granola's `get_account_info`.
    static func accountEmail(token: String, transport: any HTTPDataTransport) async -> String? {
        let client = RemoteMCPClient(endpoint: RemoteMCPService.granola.endpoint, accessToken: token,
                                     clientName: RemoteMCPService.granola.clientName, transport: transport)
        do {
            let result = try await client.callTool("get_account_info", arguments: [:])
            return result.isError ? nil : email(in: result.text)
        } catch {
            RealtimeLog.log("granola connect: get_account_info failed — \(error)")
            return nil
        }
    }

    /// `email` or `account.email` in a JSON answer, else the first address in the text.
    static func email(in text: String) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            let value = json["email"] ?? (json["account"] as? [String: Any])?["email"]
            if let email = value as? String, email.contains("@") { return email }
        }
        guard let range = text.range(of: #"[\w.+-]+@[\w-]+\.[\w.-]+"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }
}
