import Foundation
import Security

/// The user's own OpenAI key, kept in this phone's Keychain. This app pays for its calls with
/// it, and it goes only to OpenAI.
enum OpenAIKeyService {
    struct Status: Decodable, Equatable {
        let set: Bool
        let last4: String?
    }

    enum Failure: LocalizedError {
        case rejected, unavailable

        var errorDescription: String? {
            switch self {
            case .rejected: "OpenAI didn't accept that key. Check it and try again."
            case .unavailable: "Couldn't reach OpenAI. Try again."
            }
        }
    }

    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "kiloforge.openai.key",
        kSecAttrAccount as String: "default",
    ]

    /// Written with the key and wiped with the app's container. iOS keeps Keychain items across a
    /// delete and reinstall, so the key counts as this install's only when this note is also set —
    /// `SignedInFlag`'s rule for the Google grant.
    static let savedHereKey = "openAIKeySavedHere"

    /// Launch, before anything reads the key: a key a deleted install left behind is dropped, so
    /// the reinstall asks for it again. A signed-in install from before this note existed keeps its
    /// key and takes the note, so the update doesn't ask either.
    @discardableResult
    static func dropIfLeftByDeletedInstall(
        defaults: UserDefaults = .standard, signedIn: Bool = SignedInFlag.isSet,
        drop: () -> Bool = { SecItemDelete(base as CFDictionary) == errSecSuccess }
    ) -> Bool {
        guard !defaults.bool(forKey: savedHereKey) else { return false }
        if signedIn {
            defaults.set(true, forKey: savedHereKey)
            return false
        }
        let dropped = drop()
        if dropped { RealtimeLog.log("credential cleanup: OpenAI key — deleted, left by a deleted install") }
        return dropped
    }

    /// The saved key, or nil.
    static var current: String? {
        var query = base
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func status() async throws -> Status {
        guard let key = current else { return Status(set: false, last4: nil) }
        return Status(set: true, last4: String(key.suffix(4)))
    }

    /// Checks the key with one cheap call, so a typo fails here rather than on the first dial.
    static func save(_ key: String) async throws -> Status {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let response: URLResponse
        do { (_, response) = try await URLSession.shared.data(for: request) } catch { throw Failure.unavailable }
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        if code == 401 || code == 403 { throw Failure.rejected }
        guard (200..<300).contains(code) else { throw Failure.unavailable }

        // Delete-then-add: `kSecAttrAccessible` is fixed at insert.
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
        UserDefaults.standard.set(true, forKey: savedHereKey)
        return try await status()
    }

    static func remove() async throws -> Status {
        SecItemDelete(base as CFDictionary)
        return Status(set: false, last4: nil)
    }
}
