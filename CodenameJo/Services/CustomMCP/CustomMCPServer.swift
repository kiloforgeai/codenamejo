import FactoryKit
import Foundation

/// One MCP server the user added: its endpoint, how it is signed in to, and the tools it last
/// listed. The credential is a `RemoteMCPGrant` in the Keychain; this record holds nothing secret.
struct CustomMCPServer: Codable, Identifiable, Equatable, Sendable {
    enum Auth: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Discovery, dynamic registration and PKCE in the sign-in sheet, like Notion and Granola.
        case oauth
        /// A token the user pasted, sent as the bearer on every call.
        case bearer
        /// No `Authorization` header at all.
        case none

        var id: String { rawValue }
        var title: String {
            switch self {
            case .oauth: "Sign in"
            case .bearer: "Paste a token"
            case .none: "No credential"
            }
        }
    }

    /// One tool the server listed, as MCP describes it.
    struct Tool: Codable, Equatable, Sendable {
        let name: String
        var description: String
        /// The tool's `inputSchema`, kept as JSON text so the record stays `Codable`.
        var inputSchemaJSON: String

        var inputSchema: [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(inputSchemaJSON.utf8))) as? [String: Any] ?? [:]
        }

        /// From one entry of a `tools/list` answer.
        init?(listed: [String: Any]) {
            guard let name = listed["name"] as? String, !name.isEmpty else { return nil }
            self.name = name
            description = listed["description"] as? String ?? ""
            let schema = listed["inputSchema"] as? [String: Any] ?? [:]
            let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data("{}".utf8)
            inputSchemaJSON = String(decoding: data, as: UTF8.self)
        }

        init(name: String, description: String, inputSchemaJSON: String) {
            self.name = name
            self.description = description
            self.inputSchemaJSON = inputSchemaJSON
        }
    }

    let id: String
    var name: String
    var endpoint: URL
    var auth: Auth
    /// The profile it was added under; its tools serve only that profile.
    var profileId: String?
    /// Who added it, so the sign-out purge is not the only boundary between users.
    var ownerId: String?
    var tools: [Tool] = []
    var toolsListedAt: Date? = nil
    let addedAt: Date

    /// The Keychain namespace and the identity the MCP transport signs in with.
    var service: RemoteMCPService {
        RemoteMCPService(id: "custom-" + id, displayName: name, endpoint: endpoint)
    }
}

protocol CustomMCPServerStorage: Sendable {
    func all() -> [CustomMCPServer]
    func save(_ servers: [CustomMCPServer])
}

/// The user's servers, through the container's storage.
enum CustomMCPServerStore {
    private static var storage: any CustomMCPServerStorage { Container.shared.customMCPServerStorage() }

    static func all() -> [CustomMCPServer] { storage.all() }
    /// The servers added under `profileId`.
    static func servers(profileId: String?) -> [CustomMCPServer] { all().filter { $0.profileId == profileId } }
    static func server(id: String) -> CustomMCPServer? { all().first { $0.id == id } }

    static func save(_ server: CustomMCPServer) {
        var servers = all().filter { $0.id != server.id }
        servers.append(server)
        storage.save(servers.sorted { $0.addedAt < $1.addedAt })
    }

    static func remove(id: String) { storage.save(all().filter { $0.id != id }) }
    static func removeAll() { storage.save([]) }
}

/// The records in `UserDefaults`, like `FeedItems`; the credentials are the Keychain's.
struct DefaultsCustomMCPServerStorage: CustomMCPServerStorage {
    static let storageKey = "customMCPServers"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func all() -> [CustomMCPServer] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        do {
            return try JSONDecoder().decode([CustomMCPServer].self, from: data)
        } catch {
            RealtimeLog.log("mcp servers: unreadable store — \(error)")
            return []
        }
    }

    func save(_ servers: [CustomMCPServer]) {
        do {
            defaults.set(try JSONEncoder().encode(servers), forKey: Self.storageKey)
        } catch {
            RealtimeLog.log("mcp servers: save failed — \(error)")
        }
    }
}

/// An in-memory store, for tests and previews.
final class InMemoryCustomMCPServerStorage: CustomMCPServerStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [CustomMCPServer] = []

    init() {}

    func all() -> [CustomMCPServer] { lock.withLock { servers } }
    func save(_ servers: [CustomMCPServer]) { lock.withLock { self.servers = servers } }
}
