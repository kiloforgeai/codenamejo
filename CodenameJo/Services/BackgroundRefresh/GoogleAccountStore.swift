import Foundation
import FactoryKit
import Security

/// Every Google grant this phone holds, one Keychain item per mailbox, readable after first unlock.
/// Only the token server's web client can refresh them (`GoogleTokenServer`). Not `@MainActor`: a `BGTask` uses it.
enum GoogleAccountStore {
    /// One mailbox's long-lived grant — the refresh token, not the access token, which
    /// `GoogleCredential` mints on demand.
    struct Grant: Codable, Sendable, Equatable {
        /// Lowercased. Also the Keychain item's account attribute, so the addresses can be
        /// listed without decoding.
        var email: String
        let refreshToken: String
        /// What Google actually granted — the consent screen lets boxes be unticked.
        var scopes: [String]
        /// When this phone stored the consent. `GrantAlertSweep` bounds its search with it.
        let grantedAt: Date
        /// The account a caller that names none gets. Marked, not "the first one": Keychain order
        /// is undefined and a background pass must not change inbox between launches.
        var isPrimary: Bool
        /// Google's stable account id and profile name, from the consent's `id_token`.
        var sub: String? = nil
        var displayName: String? = nil
        /// Google answered `invalid_grant`: the row stays, so Settings can offer Reconnect.
        var needsReauth: Bool? = nil

        func normalized() -> Grant {
            var grant = self
            grant.email = email.lowercased()
            return grant
        }
    }

    static func all() -> [Grant] { Container.shared.googleGrantStorage().all() }
    static func emails() -> [String] { all().map(\.email) }
    static func mailAccounts() -> [String] {
        all().filter { $0.scopes.contains("https://www.googleapis.com/auth/gmail.modify") }.map(\.email)
    }
    static func grant(for email: String) -> Grant? { all().first { $0.email == email.lowercased() } }
    static func primary() -> Grant? { all().first { $0.isPrimary } ?? all().first }
    @discardableResult static func save(_ grant: Grant) -> Bool { Container.shared.googleGrantStorage().save(grant) }
    static func makePrimary(_ email: String) {
        for var grant in all() {
            grant.isPrimary = grant.email == email.lowercased()
            _ = save(grant)
        }
    }
    /// Mailboxes whose refresh Google has refused.
    static func needsReauth() -> [String] { all().filter { $0.needsReauth == true }.map(\.email) }
    static func markNeedsReauth(_ email: String) {
        guard var grant = grant(for: email), grant.needsReauth != true else { return }
        grant.needsReauth = true
        save(grant)
    }
    static func remove(_ email: String) { Container.shared.googleGrantStorage().remove(email) }
    static func removeAll() { Container.shared.googleGrantStorage().removeAll() }
}

enum KeychainGoogleGrantStore {
    typealias Grant = GoogleAccountStore.Grant
    /// Shared by every item, which is what makes listing them one query.
    private static let service = "kiloforge.google.grant"

    private static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    // MARK: - Read

    /// Every stored grant, primary first then by address — sorted because Keychain order
    /// is undefined.
    static func all() -> [Grant] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let rows = item as? [[String: Any]] else {
            // `errSecItemNotFound` is "nothing connected"; anything else (`errSecInteractionNotAllowed`
            // above all) is a grant that exists and could not be read.
            if status != errSecItemNotFound {
                RealtimeLog.log("google store: read failed — OSStatus \(status)")
            }
            return []
        }
        let decoder = JSONDecoder()
        return rows
            .compactMap { $0[kSecValueData as String] as? Data }
            .compactMap { try? decoder.decode(Grant.self, from: $0) }
            .sorted { lhs, rhs in
                if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
                return lhs.email < rhs.email
            }
    }

    // MARK: - Write

    /// Insert or replace one mailbox's grant. Delete-then-add, not `SecItemUpdate`:
    /// `kSecAttrAccessible` is fixed at insert.
    @discardableResult
    static func save(_ grant: Grant) -> Bool {
        let grant = grant.normalized()
        guard let data = try? JSONEncoder().encode(grant) else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: grant.email,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = accessibility
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            RealtimeLog.log("google store: save failed — OSStatus \(status)")
            return false
        }
        return true
    }

    /// Make `email` the primary and demote whatever held it. Rewritten into the Keychain
    /// rather than tracked in `UserDefaults`, which a locked-phone reader can't reach.
    static func makePrimary(_ email: String) {
        let wanted = email.lowercased()
        for var grant in all() where grant.isPrimary != (grant.email == wanted) {
            grant.isPrimary = grant.email == wanted
            save(grant)
        }
    }

    // MARK: - Delete

    static func remove(_ email: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email.lowercased(),
        ]
        SecItemDelete(base as CFDictionary)
        // Removing the primary would otherwise leave every mailbox unmarked, and then
        // "the default account" would shift as accounts come and go.
        let remaining = all()
        if !remaining.isEmpty, !remaining.contains(where: \.isPrimary) {
            makePrimary(remaining[0].email)
        }
    }

    /// Drop every grant. Sign-out calls it: a live `gmail.modify` credential outliving the
    /// session is the next account on this handset reading the last one's mail.
    static func removeAll() {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(base as CFDictionary)
        switch status {
        case errSecSuccess:
            RealtimeLog.log("credential cleanup: Google grants — deleted")
        case errSecItemNotFound:
            RealtimeLog.log("credential cleanup: Google grants — already absent")
        default:
            RealtimeLog.log("credential cleanup: Google grants — deletion failed; OSStatus \(status)")
        }
    }
}
