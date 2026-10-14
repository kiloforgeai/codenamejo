import FactoryKit
import Foundation

/// Fresh access tokens for remote MCP grants, and tool calls made with them. Renewal is serialized
/// per grant: a rotating server invalidates the old refresh token, so concurrent refreshes would fail.
actor RemoteMCPCredentials {
    enum Failure: Error, Equatable {
        case noGrant
        /// The server refused the refresh: the grant is flagged and only the user can fix it.
        case needsReauth
        /// The network or the server; the next call may succeed.
        case transient(String)
    }

    /// How long before expiry a token is renewed rather than used.
    static let margin: TimeInterval = 60

    private let transport: any HTTPDataTransport
    private var renewing: [String: Task<Result<String, Failure>, Never>] = [:]

    init(transport: any HTTPDataTransport = Container.shared.providerHTTP()) {
        self.transport = transport
    }

    /// The grant's access token, renewed first when it is within `margin` of expiring (or `force`).
    func accessToken(_ service: RemoteMCPService, grantId: String, force: Bool = false,
                     now: Date = Date()) async -> Result<String, Failure> {
        guard let grant = RemoteMCPGrantStore.grant(service, id: grantId) else { return .failure(.noGrant) }
        if grant.needsReauth { return .failure(.needsReauth) }
        if !force, grant.expiresAt.timeIntervalSince(now) > Self.margin { return .success(grant.accessToken) }
        if let inFlight = renewing[grantId] { return await inFlight.value }
        let transport = self.transport
        let task = Task { await Self.renew(service, grant, transport: transport) }
        renewing[grantId] = task
        let result = await task.value
        renewing[grantId] = nil
        return result
    }

    private static func renew(_ service: RemoteMCPService, _ grant: RemoteMCPGrant,
                              transport: any HTTPDataTransport) async -> Result<String, Failure> {
        guard grant.refreshToken != nil else {
            RemoteMCPGrantStore.markNeedsReauth(grant.id, service)
            return .failure(.needsReauth)
        }
        switch await RemoteMCPAuth.refresh(grant, transport: transport) {
        case .success(let tokens):
            var renewed = grant
            renewed.accessToken = tokens.access_token
            if let rotated = tokens.refresh_token, !rotated.isEmpty { renewed.refreshToken = rotated }
            renewed.expiresAt = RemoteMCPAuth.expiry(tokens)
            RemoteMCPGrantStore.save(renewed, service)
            return .success(renewed.accessToken)
        case .failure(.revoked):
            RemoteMCPGrantStore.markNeedsReauth(grant.id, service)
            return .failure(.needsReauth)
        case .failure(.failed(let reason)):
            RealtimeLog.log("\(service.id): refresh failed — \(reason)")
            return .failure(.transient(reason))
        }
    }

    /// Call one tool with the grant's credential. A refused bearer is renewed once and retried;
    /// refused again, the grant is flagged for reconnecting.
    func callTool(_ service: RemoteMCPService, grantId: String, name: String,
                  arguments: [String: Any]) async throws -> RemoteMCPToolResult {
        try await withClient(service, grantId: grantId) { try await $0.callTool(name, arguments: arguments) }
    }

    /// Every tool the server lists, with the grant's credential, renewed and retried as `callTool` is.
    func listTools(_ service: RemoteMCPService, grantId: String) async throws -> [[String: Any]] {
        try await withClient(service, grantId: grantId) { try await $0.listTools() }
    }

    private func withClient<T>(_ service: RemoteMCPService, grantId: String,
                               _ work: (RemoteMCPClient) async throws -> T) async throws -> T {
        var forced = false
        while true {
            let token: String
            switch await accessToken(service, grantId: grantId, force: forced) {
            case .success(let value): token = value
            case .failure(.needsReauth), .failure(.noGrant): throw RemoteMCPError.unauthorized(status: 401)
            case .failure(.transient(let reason)): throw RemoteMCPError.transport(reason)
            }
            let client = RemoteMCPClient(endpoint: service.endpoint, accessToken: token,
                                         clientName: service.clientName, transport: transport)
            do {
                return try await work(client)
            } catch RemoteMCPError.unauthorized(let status) {
                let canRenew = RemoteMCPGrantStore.grant(service, id: grantId)?.refreshToken != nil
                if forced || !canRenew {
                    RemoteMCPGrantStore.markNeedsReauth(grantId, service)
                    throw RemoteMCPError.unauthorized(status: status)
                }
                forced = true
            }
        }
    }
}
