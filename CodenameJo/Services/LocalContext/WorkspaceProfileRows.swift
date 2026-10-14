import Foundation
import GRDB

/// Profiles, the mailboxes each one holds, its own workspace settings and its dossier, in
/// `context.sqlite`. Profiles live on this phone only; every row carries `user_id`.
struct WorkspaceProfileRows: Sendable {
    struct Profile: Codable, FetchableRecord, PersistableRecord, Sendable {
        static let databaseTableName = "workspace_profile"
        var user_id: String
        var id: String
        var name: String
        var is_default: Bool
        var created_at: String
        /// The profile's workspace fields (`UserProfile.workspaceFields`) as JSON; nil until first saved.
        var settings: String?
        var dossier_enabled: Bool

        var value: WorkspaceProfile { WorkspaceProfile(id: id, name: name, isDefault: is_default, createdAt: created_at) }
    }

    struct Mailbox: Codable, FetchableRecord, PersistableRecord, Sendable {
        static let databaseTableName = "workspace_profile_mailbox"
        var user_id: String
        /// Lowercased.
        var email: String
        var profile_id: String
    }

    struct Dossier: Codable, FetchableRecord, PersistableRecord, Sendable {
        static let databaseTableName = "profile_dossier"
        var user_id: String
        var profile_id: String
        /// Every reconciled claim, keyed by `claim.key`, as JSON.
        var facts: String
        var content: String
        var version: Int
        var updated_at: Date
    }

    static func createSchema(_ db: Database) throws {
        try db.create(table: Profile.databaseTableName) { t in
            t.column("user_id", .text).notNull()
            t.column("id", .text).notNull()
            t.column("name", .text).notNull()
            t.column("is_default", .boolean).notNull().defaults(to: false)
            t.column("created_at", .text).notNull()
            t.column("settings", .text)
            t.column("dossier_enabled", .boolean).notNull().defaults(to: false)
            t.primaryKey(["user_id", "id"])
        }
        try db.execute(sql: "CREATE UNIQUE INDEX workspace_profile_default ON workspace_profile(user_id) WHERE is_default")
        try db.create(table: Mailbox.databaseTableName) { t in
            t.column("user_id", .text).notNull()
            t.column("email", .text).notNull()
            t.column("profile_id", .text).notNull()
            t.primaryKey(["user_id", "email"])
        }
        try db.create(table: Dossier.databaseTableName) { t in
            t.column("user_id", .text).notNull()
            t.column("profile_id", .text).notNull()
            t.column("facts", .text).notNull()
            t.column("content", .text).notNull()
            t.column("version", .integer).notNull()
            t.column("updated_at", .datetime).notNull()
            t.primaryKey(["user_id", "profile_id"])
        }
    }

    let dbPool: DatabasePool?

    private func pool() throws -> DatabasePool {
        guard let dbPool else { throw WorkspaceProfileError.unavailable }
        return dbPool
    }

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// `profileName` from the server: trimmed, NFC, 1–80 scalars, no control or format characters.
    static func validName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        let forbidden: Set<Unicode.GeneralCategory> = [.control, .format]
        guard !name.isEmpty, name.unicodeScalars.count <= 80,
              !name.unicodeScalars.contains(where: { forbidden.contains($0.properties.generalCategory) }) else {
            throw WorkspaceProfileError.invalidName
        }
        return name
    }

    /// Every profile, default first. A user with none gets "Personal" as the default.
    func list(userId: String) throws -> [WorkspaceProfile] {
        try pool().write { db in
            if try Profile.filter(Column("user_id") == userId).fetchCount(db) == 0 {
                try Profile(user_id: userId, id: UUID().uuidString.lowercased(), name: "Personal", is_default: true,
                            created_at: Self.stamp.string(from: Date()), settings: nil, dossier_enabled: false).insert(db)
            }
            return try Profile.fetchAll(db, sql: """
                SELECT * FROM workspace_profile WHERE user_id = ? ORDER BY is_default DESC, created_at, id
                """, arguments: [userId]).map(\.value)
        }
    }

    func create(userId: String, name raw: String) throws -> WorkspaceProfile {
        let name = try Self.validName(raw)
        return try pool().write { db in
            try Self.requireFreeName(name, userId: userId, except: nil, db: db)
            let row = Profile(user_id: userId, id: UUID().uuidString.lowercased(), name: name, is_default: false,
                              created_at: Self.stamp.string(from: Date()), settings: nil, dossier_enabled: false)
            try row.insert(db)
            return row.value
        }
    }

    func rename(userId: String, id: String, name raw: String) throws -> WorkspaceProfile {
        let name = try Self.validName(raw)
        return try pool().write { db in
            guard var row = try Profile.fetchOne(db, key: ["user_id": userId, "id": id]) else { throw WorkspaceProfileError.notFound }
            try Self.requireFreeName(name, userId: userId, except: id, db: db)
            row.name = name
            try row.update(db)
            return row.value
        }
    }

    private static func requireFreeName(_ name: String, userId: String, except id: String?, db: Database) throws {
        let taken = try Profile.filter(Column("user_id") == userId).fetchAll(db)
            .contains { $0.id != id && $0.name.lowercased() == name.lowercased() }
        if taken { throw WorkspaceProfileError.nameTaken }
    }

    /// Removes a named profile with its settings, dossier and mailbox mapping. Returns the mailboxes it held.
    @discardableResult
    func delete(userId: String, id: String) throws -> [String] {
        try pool().write { db in
            guard let row = try Profile.fetchOne(db, key: ["user_id": userId, "id": id]) else { throw WorkspaceProfileError.notFound }
            if row.is_default { throw WorkspaceProfileError.cannotDeleteDefault }
            let held = try String.fetchAll(db, sql: "SELECT email FROM workspace_profile_mailbox WHERE user_id = ? AND profile_id = ? ORDER BY email",
                                           arguments: [userId, id])
            try db.execute(sql: "DELETE FROM workspace_profile_mailbox WHERE user_id = ? AND profile_id = ?", arguments: [userId, id])
            try db.execute(sql: "DELETE FROM profile_dossier WHERE user_id = ? AND profile_id = ?", arguments: [userId, id])
            try row.delete(db)
            return held
        }
    }

    func mailboxes(userId: String, profileId: String) throws -> [String] {
        try pool().read { db in
            try String.fetchAll(db, sql: "SELECT email FROM workspace_profile_mailbox WHERE user_id = ? AND profile_id = ? ORDER BY email",
                                arguments: [userId, profileId])
        }
    }

    /// Places each mailbox no profile holds yet into `profileId`. Mapped mailboxes never move.
    func adopt(userId: String, emails: [String], into profileId: String) throws {
        try pool().write { db in
            for email in Set(emails.map { $0.lowercased() }) {
                try db.execute(sql: "INSERT OR IGNORE INTO workspace_profile_mailbox(user_id, email, profile_id) VALUES (?, ?, ?)",
                               arguments: [userId, email, profileId])
            }
        }
    }

    /// A disconnected mailbox leaves its profile, so reconnecting it lands where the user is.
    func forget(userId: String, email: String) throws {
        try pool().write { db in
            try db.execute(sql: "DELETE FROM workspace_profile_mailbox WHERE user_id = ? AND email = ?", arguments: [userId, email.lowercased()])
        }
    }

    func settings(userId: String, profileId: String) throws -> UserProfile? {
        let json = try pool().read { db in
            try String.fetchOne(db, sql: "SELECT settings FROM workspace_profile WHERE user_id = ? AND id = ?", arguments: [userId, profileId])
        }
        return try json.map { try JSONDecoder().decode(UserProfile.self, from: Data($0.utf8)) }
    }

    /// Keeps only the workspace fields of `settings`.
    func saveSettings(_ settings: UserProfile, userId: String, profileId: String) throws {
        let scoped = try UserProfile().replacingWorkspaceSettings(with: settings)
        let json = String(decoding: try JSONEncoder().encode(scoped), as: UTF8.self)
        try pool().write { db in
            try db.execute(sql: "UPDATE workspace_profile SET settings = ? WHERE user_id = ? AND id = ?", arguments: [json, userId, profileId])
        }
    }

    func dossierEnabled(userId: String, profileId: String) throws -> Bool {
        try pool().read { db in
            try Bool.fetchOne(db, sql: "SELECT dossier_enabled FROM workspace_profile WHERE user_id = ? AND id = ?",
                              arguments: [userId, profileId]) ?? false
        }
    }

    func setDossierEnabled(_ enabled: Bool, userId: String, profileId: String) throws {
        try pool().write { db in
            try db.execute(sql: "UPDATE workspace_profile SET dossier_enabled = ? WHERE user_id = ? AND id = ?",
                           arguments: [enabled, userId, profileId])
            if db.changesCount == 0 { throw WorkspaceProfileError.notFound }
        }
    }

    func dossier(userId: String, profileId: String) throws -> Dossier? {
        try pool().read { db in try Dossier.fetchOne(db, key: ["user_id": userId, "profile_id": profileId]) }
    }

    /// Writes only while the profile still exists.
    func saveDossier(_ dossier: Dossier) throws {
        try pool().write { db in
            guard try Profile.fetchOne(db, key: ["user_id": dossier.user_id, "id": dossier.profile_id]) != nil else { return }
            try dossier.save(db)
        }
    }

    /// Dossiers are built from transcripts, so they leave with the account's turns at sign-out.
    func purgeDossiers(userId: String) throws {
        try pool().write { db in try db.execute(sql: "DELETE FROM profile_dossier WHERE user_id = ?", arguments: [userId]) }
    }
}
