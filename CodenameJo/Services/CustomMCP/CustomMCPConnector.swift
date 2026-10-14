import FactoryKit
import Foundation

/// What Settings shows for one of the user's servers.
struct CustomMCPServerStatus: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let host: String
    let auth: CustomMCPServer.Auth
    let tools: [CustomMCPServer.Tool]
    /// The credential was refused, or there is none: only the user can fix it.
    let needsReauth: Bool

    init(_ server: CustomMCPServer, needsReauth: Bool) {
        id = server.id
        name = server.name
        host = server.endpoint.host ?? server.endpoint.absoluteString
        auth = server.auth
        tools = server.tools
        self.needsReauth = needsReauth
    }

    var toolCount: Int { tools.count }

    var subtitle: String {
        if needsReauth { return "Needs reconnecting" }
        return (toolCount == 1 ? "1 tool" : "\(toolCount) tools") + " · " + host
    }

    /// One row per listed tool on the connector detail screen.
    var capabilities: [ConnectorCapability] {
        tools.map { tool in
            let detail = tool.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return ConnectorCapability(
                scope: tool.name,
                label: CustomMCPTools.humanized(tool.name),
                icon: "function",
                detail: detail.isEmpty ? "The server gave no description." : String(detail.prefix(240)))
        }
    }
}

/// Adding, reconnecting, refreshing and removing the user's own MCP servers, all on this phone.
/// A pasted token, or no credential at all, becomes a grant that never expires and is never renewed.
enum CustomMCPConnector {
    enum Failure: Error, Equatable {
        case cancelled
        case failed(String)
    }

    /// The servers added under the active profile.
    static func servers(profileId: String? = ProfileRuntime.snapshot?.profileId) -> [CustomMCPServer] {
        CustomMCPServerStore.servers(profileId: profileId)
    }

    static func grant(_ server: CustomMCPServer) -> RemoteMCPGrant? {
        RemoteMCPGrantStore.grants(server.service).last
    }

    /// Whether the server's tools may be offered: it has a credential the server has not refused.
    static func isUsable(_ server: CustomMCPServer) -> Bool {
        grant(server).map { !$0.needsReauth } ?? false
    }

    static func status(_ server: CustomMCPServer) -> CustomMCPServerStatus {
        CustomMCPServerStatus(server, needsReauth: !isUsable(server))
    }

    /// The URL the user typed, when it is one this app will call: `https` only, since App
    /// Transport Security refuses plain HTTP, and a host it can name.
    static func endpoint(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    // MARK: - Add

    /// Save the credential, list the server's tools once, and keep the record. A server that
    /// refuses the first listing is not kept, so the user never reconnects a row that never worked.
    @MainActor
    static func add(name: String, endpoint: URL, auth: CustomMCPServer.Auth, token: String,
                    profileId: String?, ownerId: String?,
                    transport: any HTTPDataTransport = Container.shared.providerHTTP(),
                    credentials: RemoteMCPCredentials = Container.shared.remoteMCPCredentials())
        async -> Result<CustomMCPServer, Failure> {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.failed("Give the server a name.")) }
        var server = CustomMCPServer(id: UUID().uuidString, name: name, endpoint: endpoint, auth: auth,
                                     profileId: profileId, ownerId: ownerId, addedAt: Date())
        let grant: RemoteMCPGrant
        switch await credential(for: server, token: token, transport: transport) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): grant = value
        }
        guard RemoteMCPGrantStore.save(grant, server.service) else {
            return .failure(.failed("Couldn't save the \(name) connection on this phone."))
        }
        do {
            server.tools = try await listTools(server, grantId: grant.id, credentials: credentials)
        } catch {
            RemoteMCPGrantStore.removeAll(server.service)
            RealtimeLog.log("mcp \(name): first tools/list failed — \(error)")
            return .failure(.failed(CustomMCPTools.explain(error, server: name)))
        }
        server.toolsListedAt = Date()
        CustomMCPServerStore.save(server)
        RealtimeLog.log("mcp \(name): added \(server.endpoint.host ?? "") with \(server.tools.count) tool(s), auth \(auth.rawValue)")
        return .success(server)
    }

    /// Replace the credential and list the tools again. `token` is read for a bearer server only.
    @MainActor
    static func reconnect(_ server: CustomMCPServer, token: String,
                          transport: any HTTPDataTransport = Container.shared.providerHTTP(),
                          credentials: RemoteMCPCredentials = Container.shared.remoteMCPCredentials())
        async -> Result<CustomMCPServer, Failure> {
        let grant: RemoteMCPGrant
        switch await credential(for: server, token: token, transport: transport) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): grant = value
        }
        let old = RemoteMCPGrantStore.grants(server.service)
        guard RemoteMCPGrantStore.save(grant, server.service) else {
            return .failure(.failed("Couldn't save the \(server.name) connection on this phone."))
        }
        for stale in old { RemoteMCPGrantStore.remove(stale.id, server.service) }
        switch await refreshTools(server, credentials: credentials) {
        case .success(let refreshed):
            RealtimeLog.log("mcp \(server.name): reconnected")
            return .success(refreshed)
        case .failure(let failure):
            RemoteMCPGrantStore.markNeedsReauth(grant.id, server.service)
            return .failure(failure)
        }
    }

    /// List the tools again with the stored credential and keep what came back.
    static func refreshTools(_ server: CustomMCPServer,
                             credentials: RemoteMCPCredentials = Container.shared.remoteMCPCredentials())
        async -> Result<CustomMCPServer, Failure> {
        guard let grant = grant(server) else { return .failure(.failed("\(server.name) has no connection on this phone.")) }
        var refreshed = server
        do {
            refreshed.tools = try await listTools(server, grantId: grant.id, credentials: credentials)
        } catch {
            RealtimeLog.log("mcp \(server.name): tools/list failed — \(error)")
            return .failure(.failed(CustomMCPTools.explain(error, server: server.name)))
        }
        refreshed.toolsListedAt = Date()
        // A server removed while the listing ran stays removed.
        guard CustomMCPServerStore.server(id: server.id) != nil else { return .success(refreshed) }
        CustomMCPServerStore.save(refreshed)
        RealtimeLog.log("mcp \(server.name): \(refreshed.tools.count) tool(s) listed")
        return .success(refreshed)
    }

    /// Fresh tool lists for the next dial, without holding this one up.
    static func refreshToolsInBackground(_ servers: [CustomMCPServer],
                                         credentials: RemoteMCPCredentials = Container.shared.remoteMCPCredentials()) {
        let usable = servers.filter(isUsable)
        guard !usable.isEmpty else { return }
        Task.detached(priority: .utility) {
            for server in usable { _ = await refreshTools(server, credentials: credentials) }
        }
    }

    /// Revoke an OAuth grant where the server allows it, then drop the credential and the record.
    static func remove(_ server: CustomMCPServer) async {
        for grant in RemoteMCPGrantStore.grants(server.service) where server.auth == .oauth {
            await RemoteMCPAuth.revoke(grant)
        }
        RemoteMCPGrantStore.removeAll(server.service)
        CustomMCPServerStore.remove(id: server.id)
        RealtimeLog.log("mcp \(server.name): removed")
    }

    /// Every server, its credential and its registration, for sign-out.
    static func forget() {
        for server in CustomMCPServerStore.all() { RemoteMCPGrantStore.removeAll(server.service) }
        CustomMCPServerStore.removeAll()
    }

    // MARK: - Credentials

    /// A grant that never expires, for a pasted token or for no credential at all.
    static func staticGrant(token: String, server: CustomMCPServer) -> RemoteMCPGrant {
        RemoteMCPGrant(id: UUID().uuidString, label: server.name, profileId: server.profileId,
                       accessToken: token, refreshToken: nil, expiresAt: .distantFuture,
                       clientId: "", tokenEndpoint: "", resource: server.endpoint.absoluteString, grantedAt: Date())
    }

    @MainActor
    private static func credential(for server: CustomMCPServer, token: String,
                                   transport: any HTTPDataTransport) async -> Result<RemoteMCPGrant, Failure> {
        switch server.auth {
        case .oauth:
            switch await RemoteMCPAuth.signIn(server.service, label: server.name, profileId: server.profileId,
                                              transport: transport) {
            case .success(let grant): return .success(grant)
            case .failure(.cancelled): return .failure(.cancelled)
            case .failure(.failed(let message)): return .failure(.failed(message))
            }
        case .bearer:
            let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return .failure(.failed("Paste the server's token.")) }
            return .success(staticGrant(token: token, server: server))
        case .none:
            return .success(staticGrant(token: "", server: server))
        }
    }

    static func listTools(_ server: CustomMCPServer, grantId: String,
                          credentials: RemoteMCPCredentials) async throws -> [CustomMCPServer.Tool] {
        try await credentials.listTools(server.service, grantId: grantId).compactMap(CustomMCPServer.Tool.init(listed:))
    }
}
