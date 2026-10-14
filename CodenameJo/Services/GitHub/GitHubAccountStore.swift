import FactoryKit
import Foundation
import Security

/// Every GitHub login this phone holds a token for, one Keychain item per login. Tokens never
/// expire; a 401 marks the row rather than deleting it, so Settings can offer Reconnect.
enum GitHubAccountStore {
    struct Account: Codable, Sendable, Equatable {
        /// GitHub's stable numeric id. The Keychain account attribute, so a renamed login
        /// replaces its own item instead of adding a second one.
        let id: String
        var login: String
        let token: String
        var scopes: [String]
        let connectedAt: Date
        var needsReauth: Bool? = nil
    }

    static func all() -> [Account] { Container.shared.githubTokenStorage().all() }
    /// The accounts the tools may run against: connected and still honoured.
    static func usable() -> [Account] { all().filter { $0.needsReauth != true } }
    static func needsReauth() -> [String] { all().filter { $0.needsReauth == true }.map(\.login) }
    static func account(login: String) -> Account? {
        all().first { $0.login.caseInsensitiveCompare(login) == .orderedSame }
    }
    @discardableResult static func save(_ account: Account) -> Bool { Container.shared.githubTokenStorage().save(account) }
    static func remove(login: String) {
        guard let account = account(login: login) else { return }
        Container.shared.githubTokenStorage().remove(id: account.id)
    }
    static func removeAll() { Container.shared.githubTokenStorage().removeAll() }

    /// The token was refused. Keyed on the token, not the login: a reconnect between the call and
    /// this mark must not flag the fresh token.
    static func markNeedsReauth(token: String) {
        guard var account = all().first(where: { $0.token == token }), account.needsReauth != true else { return }
        account.needsReauth = true
        save(account)
        RealtimeLog.log("github: @\(account.login) token refused — needs reconnecting")
    }
}

protocol GitHubTokenStorage: Sendable {
    func all() -> [GitHubAccountStore.Account]
    func save(_ account: GitHubAccountStore.Account) -> Bool
    func remove(id: String)
    func removeAll()
}

/// `AfterFirstUnlockThisDeviceOnly`, like the Google grants: never in a backup, never on another phone.
struct KeychainGitHubTokenStorage: GitHubTokenStorage {
    private static let service = "kiloforge.github.token"

    func all() -> [GitHubAccountStore.Account] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let rows = item as? [Data] else {
            if status != errSecItemNotFound { RealtimeLog.log("github store: read failed — OSStatus \(status)") }
            return []
        }
        return rows.compactMap { try? JSONDecoder().decode(GitHubAccountStore.Account.self, from: $0) }
            .sorted { $0.connectedAt < $1.connectedAt }
    }

    func save(_ account: GitHubAccountStore.Account) -> Bool {
        guard let data = try? JSONEncoder().encode(account) else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account.id,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { RealtimeLog.log("github store: save failed — OSStatus \(status)") }
        return status == errSecSuccess
    }

    func remove(id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            RealtimeLog.log("github store: remove failed — OSStatus \(status)")
        }
    }

    func removeAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess: RealtimeLog.log("credential cleanup: GitHub tokens — deleted")
        case errSecItemNotFound: RealtimeLog.log("credential cleanup: GitHub tokens — already absent")
        default: RealtimeLog.log("credential cleanup: GitHub tokens — deletion failed; OSStatus \(status)")
        }
    }
}
