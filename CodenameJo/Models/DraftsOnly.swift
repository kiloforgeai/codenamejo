import Foundation

/// Whether Jo may send mail, or only write drafts. Per inbox (`draftsOnlyByAccount`), falling
/// back to the account flag; every absence reads as on, matching `mailSendPolicy` in the broker.
enum DraftsOnly {
    static let storageKey = "draftsOnly"

    /// The per-inbox answers, stored as encoded JSON `Data` so `@AppStorage` can observe them.
    static let byAccountStorageKey = "draftsOnlyByAccount"

    /// The account-wide answer. **The fallback now, not the setting** — see the type doc.
    static var isOn: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true
    }

    /// What this inbox does: its own answer if it has one, the account's otherwise.
    static func isOn(for email: String) -> Bool {
        isOn(
            for: email,
            in: UserDefaults.standard.data(forKey: byAccountStorageKey),
            fallback: isOn)
    }

    /// The resolution against the caller's `@AppStorage` value; Settings binds through this so its
    /// rows redraw (a `Binding` reading `UserDefaults` directly registers no dependency).
    static func isOn(for email: String, in encoded: Data?, fallback: Bool) -> Bool {
        decode(encoded)[key(email)] ?? fallback
    }

    /// That map with one address answered, encoded to store again.
    static func setting(_ draftsOnly: Bool, for email: String, in encoded: Data?) -> Data {
        var map = decode(encoded)
        map[key(email)] = draftsOnly
        return encode(map)
    }

    /// Answer for one address, straight to `UserDefaults`, for paths with no view in hand.
    static func set(_ draftsOnly: Bool, for email: String) {
        UserDefaults.standard.set(
            setting(draftsOnly, for: email, in: stored()), forKey: byAccountStorageKey)
    }

    /// Drop an address's answer on Disconnect, so a reconnected mailbox starts in Drafts.
    static func forget(_ email: String) {
        var map = decode(stored())
        map[key(email)] = nil
        UserDefaults.standard.set(encode(map), forKey: byAccountStorageKey)
    }

    /// What the inboxes say collectively — for copy that has to describe the account.
    enum Summary: Equatable {
        case allDraft
        case allSend
        case mixed
    }

    /// No inboxes reads as `allDraft`, matching `mailWriteMode` server-side.
    static func summary(for inboxes: [String]) -> Summary {
        let drafting = inboxes.filter { isOn(for: $0) }.count
        if drafting == inboxes.count { return .allDraft }
        if drafting == 0 { return .allSend }
        return .mixed
    }

    // MARK: - Storage

    /// Lowercased and trimmed both ways, because the broker keys the same map the same way and a
    /// mismatch falls back, which can send from a mailbox set to draft.
    static func key(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static var current: [String: Bool] { decode(stored()) }

    /// Replace the whole map — how a profile arriving from the account lands locally.
    /// `nil` clears it, so "never set" survives a sign-in the way every other field's does.
    static func replace(with map: [String: Bool]?) {
        guard let map else {
            UserDefaults.standard.removeObject(forKey: byAccountStorageKey)
            return
        }
        UserDefaults.standard.set(
            encode(Dictionary(uniqueKeysWithValues: map.map { (key($0.key), $0.value) })),
            forKey: byAccountStorageKey)
    }

    private static func stored() -> Data? {
        UserDefaults.standard.data(forKey: byAccountStorageKey)
    }

    private static func decode(_ data: Data?) -> [String: Bool] {
        guard let data, let map = try? JSONDecoder().decode([String: Bool].self, from: data)
        else { return [:] }
        return map
    }

    private static func encode(_ map: [String: Bool]) -> Data {
        (try? JSONEncoder().encode(map)) ?? Data()
    }
}
