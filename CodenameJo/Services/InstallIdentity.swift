import Foundation
import GRDB
import Security

/// Who owns this phone's rows: a random id made on first launch and kept in the Keychain.
/// It is the `user_id` on every user-scoped local row (PRINCIPLES 16).
enum InstallIdentity {
    private static let account = "kiloforge.install.id"
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: String?

    /// The id, created on first read. Nil only when the Keychain can't be read (a locked phone
    /// before first unlock); a new id is never minted over one that exists but is unreadable.
    static var current: String? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        switch read() {
        case .found(let id):
            cached = id
        case .missing:
            let id = UUID().uuidString.lowercased()
            guard write(id) else { return nil }
            cached = id
        case .unreadable(let status):
            RealtimeLog.log("installIdentity: Keychain read failed — OSStatus \(status)")
        }
        return cached
    }

    /// Forget this install's id, so the next sign-in starts as someone new. Account deletion only.
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        cached = nil
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrAccount as String: account] as CFDictionary)
    }

    private enum Read { case found(String), missing, unreadable(OSStatus) }

    private static func read() -> Read {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &item)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = item as? Data,
              let id = String(data: data, encoding: .utf8), !id.isEmpty else { return .unreadable(status) }
        return .found(id)
    }

    private static func write(_ id: String) -> Bool {
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(id.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        if status != errSecSuccess { RealtimeLog.log("installIdentity: Keychain write failed — OSStatus \(status)") }
        return status == errSecSuccess
    }

    // MARK: - Local rows

    /// Every table with an owner column, and that column's name.
    static func ownedTables(_ db: Database) throws -> [(table: String, column: String)] {
        let tables = try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master WHERE type = 'table'
            AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%' AND sql NOT LIKE 'CREATE VIRTUAL%'
            """)
        return try tables.compactMap { table in
            let columns = try db.columns(in: table).map(\.name)
            return columns.contains("user_id") ? (table, "user_id")
                : columns.contains("userId") ? (table, "userId") : nil
        }
    }

    /// Re-owns every row a previous account id wrote — `<old>` and `<old>:profile:<id>` alike — to
    /// `installId`, and renames the `UserDefaults` keys and values that carried the old id. Empty
    /// owners stay empty: they predate the column and nothing reads them.
    static func adopt(_ installId: String, in db: Database, defaults: UserDefaults = .standard) throws {
        let owned = try ownedTables(db)
        var previous = Set<String>()
        for (table, column) in owned {
            let owners = try String.fetchAll(db, sql: "SELECT DISTINCT \(column) FROM \(table)")
            for owner in owners {
                let base = owner.components(separatedBy: ":profile:")[0]
                if !base.isEmpty, base != installId { previous.insert(base) }
            }
        }
        guard !previous.isEmpty else { return }
        for old in previous {
            DealtWithLog.move(from: old, to: installId)
            for (table, column) in owned {
                // On a key collision the re-owned row replaces the other, so the update cannot fail.
                try db.execute(sql: """
                    UPDATE OR REPLACE \(table) SET \(column) = ? || substr(\(column), ?)
                    WHERE \(column) = ? OR substr(\(column), 1, ?) = ?
                    """, arguments: [installId, old.count + 1, old, old.count + 9, old + ":profile:"])
            }
            for (key, value) in defaults.dictionaryRepresentation() {
                var newKey = key
                if key.contains(old) { newKey = key.replacingOccurrences(of: old, with: installId) }
                var newValue: Any = value
                if let text = value as? String, text.contains(old) {
                    newValue = text.replacingOccurrences(of: old, with: installId)
                }
                guard newKey != key || (value as? String) != (newValue as? String) else { continue }
                if newKey != key { defaults.removeObject(forKey: key) }
                defaults.set(newValue, forKey: newKey)
            }
        }
        RealtimeLog.log("installIdentity: re-owned local rows from \(previous.count) earlier account id(s)")
    }
}
