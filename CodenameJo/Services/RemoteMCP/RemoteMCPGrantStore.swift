import FactoryKit
import Foundation
import Security

/// One sign-in to a remote MCP server, as kept in the Keychain. It carries everything a refresh
/// needs, so renewal never depends on a cached registration or a fresh discovery.
struct RemoteMCPGrant: Codable, Sendable, Equatable, Identifiable {
    /// The Keychain item's account attribute.
    let id: String
    /// What Settings shows for the row, e.g. the workspace name.
    var label: String
    /// The profile it was connected under; its tools serve only that profile.
    var profileId: String?
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    /// The server refused the refresh token: only a new sign-in brings this back.
    var needsReauth: Bool = false
    let clientId: String
    let tokenEndpoint: String
    var revocationEndpoint: String? = nil
    /// The RFC 8707 resource the token was minted for, sent again on refresh.
    let resource: String
    let grantedAt: Date
}

/// The dynamic client registration for one service, kept so reconnecting does not register again.
struct RemoteMCPRegistration: Codable, Sendable, Equatable {
    let clientId: String
    let redirectURI: String
    let authorizationServer: String
}

protocol RemoteMCPGrantStorage: Sendable {
    func grants(for service: String) -> [RemoteMCPGrant]
    @discardableResult func save(_ grant: RemoteMCPGrant, for service: String) -> Bool
    func remove(_ id: String, for service: String)
    func removeAll(for service: String)
    func registration(for service: String) -> RemoteMCPRegistration?
    func saveRegistration(_ registration: RemoteMCPRegistration, for service: String)
    func clearRegistration(for service: String)
}

/// The grants of every remote MCP service, through the container's storage.
enum RemoteMCPGrantStore {
    private static var storage: any RemoteMCPGrantStorage { Container.shared.remoteMCPGrantStorage() }

    static func grants(_ service: RemoteMCPService) -> [RemoteMCPGrant] { storage.grants(for: service.id) }
    /// The grants connected under `profileId`.
    static func grants(_ service: RemoteMCPService, profileId: String?) -> [RemoteMCPGrant] {
        grants(service).filter { $0.profileId == profileId }
    }
    static func grant(_ service: RemoteMCPService, id: String) -> RemoteMCPGrant? {
        grants(service).first { $0.id == id }
    }
    @discardableResult static func save(_ grant: RemoteMCPGrant, _ service: RemoteMCPService) -> Bool {
        storage.save(grant, for: service.id)
    }
    static func markNeedsReauth(_ id: String, _ service: RemoteMCPService) {
        guard var grant = grant(service, id: id), !grant.needsReauth else { return }
        grant.needsReauth = true
        save(grant, service)
        RealtimeLog.log("\(service.id): grant \(grant.label) needs reconnecting")
    }
    static func remove(_ id: String, _ service: RemoteMCPService) { storage.remove(id, for: service.id) }
    /// Every grant and the registration. Sign-out calls it for each service.
    static func removeAll(_ service: RemoteMCPService) {
        storage.removeAll(for: service.id)
        storage.clearRegistration(for: service.id)
    }
    static func registration(_ service: RemoteMCPService) -> RemoteMCPRegistration? { storage.registration(for: service.id) }
    static func saveRegistration(_ registration: RemoteMCPRegistration, _ service: RemoteMCPService) {
        storage.saveRegistration(registration, for: service.id)
    }
    static func clearRegistration(_ service: RemoteMCPService) { storage.clearRegistration(for: service.id) }
}

/// One generic-password item per grant under `kiloforge.mcp.<service>.grant`, and the registration
/// under `kiloforge.mcp.<service>.client`. `AfterFirstUnlockThisDeviceOnly`, like Google's grants.
struct KeychainRemoteMCPGrantStorage: RemoteMCPGrantStorage {
    private static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    private func grantService(_ service: String) -> String { "kiloforge.mcp.\(service).grant" }
    private func clientService(_ service: String) -> String { "kiloforge.mcp.\(service).client" }

    func grants(for service: String) -> [RemoteMCPGrant] {
        let decoder = JSONDecoder()
        return items(grantService(service))
            .compactMap { try? decoder.decode(RemoteMCPGrant.self, from: $0) }
            .sorted { $0.grantedAt < $1.grantedAt }
    }

    @discardableResult
    func save(_ grant: RemoteMCPGrant, for service: String) -> Bool {
        guard let data = try? JSONEncoder().encode(grant) else { return false }
        return write(data, service: grantService(service), account: grant.id)
    }

    func remove(_ id: String, for service: String) { delete(grantService(service), account: id) }
    func removeAll(for service: String) { delete(grantService(service), account: nil) }

    func registration(for service: String) -> RemoteMCPRegistration? {
        items(clientService(service)).first.flatMap { try? JSONDecoder().decode(RemoteMCPRegistration.self, from: $0) }
    }

    func saveRegistration(_ registration: RemoteMCPRegistration, for service: String) {
        guard let data = try? JSONEncoder().encode(registration) else { return }
        write(data, service: clientService(service), account: "client")
    }

    func clearRegistration(for service: String) { delete(clientService(service), account: nil) }

    // MARK: - Keychain

    private func items(_ service: String) -> [Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound { RealtimeLog.log("mcp store: \(service) read failed — OSStatus \(status)") }
            return []
        }
        return item as? [Data] ?? (item as? Data).map { [$0] } ?? []
    }

    /// Delete-then-add, so the item always carries the current protection class.
    @discardableResult
    private func write(_ data: Data, service: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = Self.accessibility
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { RealtimeLog.log("mcp store: \(service) save failed — OSStatus \(status)") }
        return status == errSecSuccess
    }

    private func delete(_ service: String, account: String?) {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            RealtimeLog.log("mcp store: \(service) delete failed — OSStatus \(status)")
        }
    }
}

/// An in-memory store, for tests and previews.
final class InMemoryRemoteMCPGrantStorage: RemoteMCPGrantStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var grantsByService: [String: [String: RemoteMCPGrant]] = [:]
    private var registrations: [String: RemoteMCPRegistration] = [:]

    init() {}

    func grants(for service: String) -> [RemoteMCPGrant] {
        lock.withLock { Array((grantsByService[service] ?? [:]).values).sorted { $0.grantedAt < $1.grantedAt } }
    }
    func save(_ grant: RemoteMCPGrant, for service: String) -> Bool {
        lock.withLock { grantsByService[service, default: [:]][grant.id] = grant }
        return true
    }
    func remove(_ id: String, for service: String) { lock.withLock { _ = grantsByService[service]?.removeValue(forKey: id) } }
    func removeAll(for service: String) { lock.withLock { grantsByService[service] = nil } }
    func registration(for service: String) -> RemoteMCPRegistration? { lock.withLock { registrations[service] } }
    func saveRegistration(_ registration: RemoteMCPRegistration, for service: String) {
        lock.withLock { registrations[service] = registration }
    }
    func clearRegistration(for service: String) { lock.withLock { registrations[service] = nil } }
}
