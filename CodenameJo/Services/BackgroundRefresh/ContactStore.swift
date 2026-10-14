import Foundation
import GRDB

/// Who the user corresponds with, held on the phone so `find_person` is a SQLite read
/// instead of a Gmail search. Lives in `context.sqlite` alongside `MailStore`.
struct ContactStore: Sendable {
    /// One correspondent, on one mailbox.
    struct Contact: Codable, FetchableRecord, PersistableRecord, Sendable {
        static let databaseTableName = "contact"

        /// Which mailbox saw them. Part of the key: the same first name is a different
        /// person in a work and a personal account.
        let account: String
        /// Bare, lowercased. The identity that matters — one person with two addresses is
        /// two rows on purpose, since which one they read is what the ranking is for.
        let email: String
        /// Best display name seen. Plenty of headers carry a bare address, and "" is a
        /// worse label than a name from another message on the same person.
        var displayName: String
        /// Messages the user *sent* them. Weighted hardest — see `Match.score`.
        var sentTo: Int
        /// Messages they sent the user.
        var receivedFrom: Int
        /// Milliseconds since epoch, newest message either way.
        var lastSeen: Int64
        /// `Source.mail` or `Source.calendar`, so `replace` deletes only the rows a mail
        /// walk owns and leaves calendar-only people alone.
        var source: String = Source.mail
    }

    /// Where a row came from. Strings rather than an enum because this is a stored column
    /// and a future source must not need a migration to be readable.
    enum Source {
        static let mail = "mail"
        static let calendar = "calendar"
    }

    /// When each mailbox was last walked, so a rebuild happens daily rather than per pass.
    struct ScanState: Codable, FetchableRecord, PersistableRecord, Sendable {
        static let databaseTableName = "contact_scan"

        let account: String
        var scannedAt: Date
        /// How many contacts the last walk produced. Zero is a real answer and is what
        /// separates "never ran" (no row) from "ran and the mailbox is empty".
        var contacts: Int
    }

    /// One candidate, shaped like the server's `PersonMatch`.
    struct Match: Codable, Sendable {
        let account: String
        let name: String
        let email: String
        let messages: Int
        /// `yyyy-MM-dd`, as the server tool returns it.
        let lastSeen: String
    }

    private let dbPool: DatabasePool?

    init(database: DatabasePool?) {
        dbPool = database
    }

    /// Registered from `LocalContextStore.migrator`, which owns the only migrator for this
    /// file. Defined here so the schema lives beside the code that reads it.
    static func createSchema(_ db: Database) throws {
        try db.create(table: Contact.databaseTableName) { t in
            t.column("account", .text).notNull()
            t.column("email", .text).notNull()
            t.column("displayName", .text).notNull()
            t.column("sentTo", .integer).notNull().defaults(to: 0)
            t.column("receivedFrom", .integer).notNull().defaults(to: 0)
            t.column("lastSeen", .integer).notNull().defaults(to: 0)
            t.primaryKey(["account", "email"])
        }
        // `matches(name:)` reads one mailbox whole; this keeps that off a full-table scan.
        try db.create(
            index: "contact_account_idx",
            on: Contact.databaseTableName,
            columns: ["account"]
        )

        try db.create(table: ScanState.databaseTableName) { t in
            t.primaryKey("account", .text)
            t.column("scannedAt", .datetime).notNull()
            t.column("contacts", .integer).notNull().defaults(to: 0)
        }
    }

    /// `v31-contact-source`. Every row that predates the column came from a mail walk, which
    /// is what the default says, so nothing needs backfilling.
    static func addSource(_ db: Database) throws {
        try db.alter(table: Contact.databaseTableName) { t in
            t.add(column: "source", .text).notNull().defaults(to: Source.mail)
        }
    }

    // MARK: - Reading

    /// Candidates plus whether they are `fuzzy`: no token matched, so the caller must
    /// label them as a guess.
    struct Result: Sendable {
        let matches: [Match]
        let fuzzy: Bool
    }

    /// Candidates for a spoken name, best first, from every local store at once; each is
    /// read under its own `try?` so a missing or broken table never sinks the lookup.
    /// - Parameter accounts: mailboxes still connected, so a row that outlived a purge
    ///   cannot answer. Empty means no filter.
    func matches(
        name: String, account: String? = nil, accounts: [String] = [], limit: Int = 5
    ) async -> Result {
        let tokens = NameMatch.tokens(of: name)
        guard !tokens.isEmpty, let dbPool else { return Result(matches: [], fuzzy: false) }

        let scope = account.map { [$0] } ?? accounts
        var rows: [Contact] = (try? await dbPool.read { db in
            if let account {
                return try Contact
                    .filter(Column("account") == account)
                    .fetchAll(db)
            }
            guard !accounts.isEmpty else { return try Contact.fetchAll(db) }
            return try Contact.filter(accounts.contains(Column("account"))).fetchAll(db)
        }) ?? []

        // Cached people carry zero traffic; `score` only uses traffic to break ties.
        let known = Set(rows.map(\.email))
        rows += await cachedCalendarPeople(scope: scope, excluding: known)
        rows += await cachedMailPeople(scope: scope, excluding: known.union(rows.map(\.email)))
        rows += await contextPeople(tokens: tokens, excluding: Set(rows.map(\.email)))

        // Match quality first, traffic second, so a loose hit on a short token never
        // outranks a full surname match.
        let ranked = rows
            .compactMap { c -> (Contact, Double, NameMatch.Tier)? in
                let hit = NameMatch.quality(
                    name: c.displayName, email: c.email, tokens: tokens)
                return hit.score > 0 ? (c, hit.score, hit.tier) : nil
            }
            .sorted {
                $0.1 == $1.1 ? Self.score($0.0) > Self.score($1.0) : $0.1 > $1.1
            }
            .prefix(limit)
        // A sound-alike is a guess and has to be labelled as one, or the model
        // reads a near miss as the clear leader and mails a stranger.
        return Result(
            matches: ranked.map { Self.asMatch($0.0) },
            fuzzy: ranked.contains { $0.2 != .name })
    }

    /// Every correspondent on one mailbox, best first, by the same weighting the resolver uses.
    func all(account: String, limit: Int = 2_000) async -> [Contact] {
        guard let dbPool else { return [] }
        let rows = (try? await dbPool.read { db in
            try Contact.filter(Column("account") == account).fetchAll(db)
        }) ?? []
        return rows.sorted { Self.score($0) > Self.score($1) }.prefix(limit).map { $0 }
    }

    /// Attendees of the cached calendar window, as contacts. Scoped through
    /// `calendar_event` because `calendar_event_attendee` has no account column.
    private func cachedCalendarPeople(
        scope: [String], excluding seen: Set<String>
    ) async -> [Contact] {
        guard let dbPool else { return [] }
        let rows: [Row] = (try? await dbPool.read { db in
            let filter = scope.isEmpty
                ? ""
                : "WHERE e.account IN (\(scope.map { _ in "?" }.joined(separator: ", ")))"
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT a.email AS email, a.displayName AS displayName,
                           max(e.startEpochMs) AS lastSeen, e.account AS account
                      FROM calendar_event_attendee a
                      JOIN calendar_event e
                        ON e.id = a.eventId AND e.calendarId = a.calendarId
                    \(filter)
                     GROUP BY a.email, e.account
                    """,
                arguments: StatementArguments(scope))
        }) ?? []

        return rows.compactMap { row in
            let email = (row["email"] as String? ?? "").lowercased()
            guard !email.isEmpty, !seen.contains(email) else { return nil }
            return Contact(
                account: row["account"] as String? ?? "",
                email: email,
                displayName: row["displayName"] as String? ?? "",
                sentTo: 0,
                receivedFrom: 0,
                lastSeen: row["lastSeen"] as Int64? ?? 0,
                source: Source.calendar)
        }
    }

    /// Senders and recipients of cached mail, as contacts. Reaches first-time
    /// correspondents before the daily `ContactScan` does.
    private func cachedMailPeople(
        scope: [String], excluding seen: Set<String>
    ) async -> [Contact] {
        guard let dbPool else { return [] }
        let rows: [Row] = (try? await dbPool.read { db in
            let filter = scope.isEmpty
                ? ""
                : "WHERE account IN (\(scope.map { _ in "?" }.joined(separator: ", ")))"
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT sender, recipient, account, internalDate
                      FROM mail_message
                    \(filter)
                    """,
                arguments: StatementArguments(scope))
        }) ?? []

        var found: [String: Contact] = [:]
        for row in rows {
            let account = row["account"] as String? ?? ""
            let when = row["internalDate"] as Int64? ?? 0
            let people = MailAddress.list(row["sender"] as String?)
                + MailAddress.list(row["recipient"] as String?)
            for person in people where !seen.contains(person.email) {
                if var existing = found[person.email] {
                    if existing.displayName.isEmpty { existing.displayName = person.name }
                    existing.lastSeen = max(existing.lastSeen, when)
                    found[person.email] = existing
                } else {
                    found[person.email] = Contact(
                        account: account,
                        email: person.email,
                        displayName: person.name,
                        sentTo: 0,
                        receivedFrom: 0,
                        lastSeen: when,
                        source: Source.mail)
                }
            }
        }
        return Array(found.values)
    }

    /// Addresses seen in this device's tool history (`context_rows`). A row must mention a
    /// spoken token before its addresses count, or strangers would rank alongside the match.
    private func contextPeople(
        tokens: [String], excluding seen: Set<String>
    ) async -> [Contact] {
        guard let dbPool, !tokens.isEmpty else { return [] }
        let rows: [Row] = (try? await dbPool.read { db in
            // `LIKE` rather than FTS: the table is one device's tool history, not a corpus.
            let clause = tokens
                .map { _ in "(lower(request) LIKE ? OR lower(result) LIKE ?)" }
                .joined(separator: " OR ")
            let arguments = tokens.flatMap { ["%\($0)%", "%\($0)%"] }
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT request, result FROM context_rows
                     WHERE \(clause)
                     ORDER BY id DESC
                     LIMIT 50
                    """,
                arguments: StatementArguments(arguments))
        }) ?? []

        var found: [String: Contact] = [:]
        for row in rows {
            let text = ((row["request"] as String? ?? "") + " " + (row["result"] as String? ?? ""))
            for email in Self.addresses(in: text) where !seen.contains(email) {
                // No name: surrounding prose is not a display name, and a guess would
                // outrank the caches that know the real one.
                found[email] = Contact(
                    account: "", email: email, displayName: "",
                    sentTo: 0, receivedFrom: 0, lastSeen: 0, source: Source.mail)
            }
        }
        return Array(found.values)
    }

    /// Every email address in a piece of free text, bare and lowercased.
    private static func addresses(in text: String) -> Set<String> {
        var found: Set<String> = []
        for field in text.lowercased().split(whereSeparator: { " \t\n\r\"'<>(),;[]{}".contains($0) }) {
            let candidate = field.trimmingCharacters(in: CharacterSet(charactersIn: ".:!?"))
            guard candidate.contains("@"),
                  let at = candidate.firstIndex(of: "@"),
                  candidate[candidate.index(after: at)...].contains("."),
                  candidate.firstIndex(of: "@") == candidate.lastIndex(of: "@")
            else { continue }
            found.insert(String(candidate))
        }
        return found
    }

    /// Whether this mailbox has ever been walked, and when.
    func scanState(account: String) async -> ScanState? {
        guard let dbPool else { return nil }
        return try? await dbPool.read { db in
            try ScanState.fetchOne(db, key: account)
        }
    }

    /// How many correspondents are held, all mailboxes. For the diagnostics screen.
    func count() async -> Int {
        guard let dbPool else { return 0 }
        return (try? await dbPool.read { db in try Contact.fetchCount(db) }) ?? 0
    }

    /// Whether this exact address has any correspondence recorded, on any account.
    func hasCorresponded(email: String) async -> Bool {
        guard let dbPool else { return false }
        let bare = email.lowercased()
        return (try? await dbPool.read { db in
            try Contact.filter(Column("email") == bare).fetchCount(db)
        }).map { $0 > 0 } ?? false
    }

    /// The same check counting only these mailboxes. Empty `accounts` counts none.
    func hasCorresponded(email: String, accounts: [String]) async -> Bool {
        guard let dbPool, !accounts.isEmpty else { return false }
        let bare = email.lowercased()
        let mailboxes = accounts.map { $0.lowercased() }
        return (try? await dbPool.read { db in
            try Contact.filter(Column("email") == bare && mailboxes.contains(Column("account").lowercased))
                .fetchCount(db)
        }).map { $0 > 0 } ?? false
    }

    /// One more message sent to `email` from `account`, so a confirmed first-time address is not
    /// asked about again (`rememberSentRecipient`).
    func recordSent(account: String, email: String, at: Date = Date()) async {
        guard let dbPool else { return }
        let bare = email.lowercased()
        let when = Int64(at.timeIntervalSince1970 * 1000)
        try? await dbPool.write { db in
            if var row = try Contact.filter(Column("account") == account && Column("email") == bare).fetchOne(db) {
                row.sentTo += 1
                row.lastSeen = max(row.lastSeen, when)
                try row.update(db)
            } else {
                try Contact(account: account, email: bare, displayName: "", sentTo: 1, receivedFrom: 0,
                            lastSeen: when).insert(db)
            }
        }
    }

    // MARK: - Writing

    /// Merge the broker's directory into this device's table. A merge, not a replace: the
    /// mirror is not authoritative, so counts take the larger side and blank names never win.
    func merge(_ mirrored: [Contact]) async {
        guard let dbPool, !mirrored.isEmpty else { return }
        try? await dbPool.write { db in
            for row in mirrored {
                let existing = try Contact
                    .filter(Column("account") == row.account)
                    .filter(Column("email") == row.email)
                    .fetchOne(db)
                var merged = row
                if let existing {
                    merged.displayName = row.displayName.isEmpty
                        ? existing.displayName : row.displayName
                    merged.sentTo = max(existing.sentTo, row.sentTo)
                    merged.receivedFrom = max(existing.receivedFrom, row.receivedFrom)
                    merged.lastSeen = max(existing.lastSeen, row.lastSeen)
                }
                try merged.save(db)
            }
        }
    }

    /// Replace one mailbox's mail-sourced rows with what a walk found. A replace, not an
    /// accumulate, so re-running never double-counts; calendar rows are left alone.
    func replace(account: String, contacts: [Contact]) async {
        guard let dbPool else { return }
        try? await dbPool.write { db in
            try Contact
                .filter(Column("account") == account)
                .filter(Column("source") == Source.mail)
                .deleteAll(db)
            // `save`, not `insert`: a calendar row for the same person is upgraded to mail.
            for contact in contacts { try contact.save(db) }
            let total = try Contact.filter(Column("account") == account).fetchCount(db)
            try ScanState(account: account, scannedAt: Date(), contacts: total).save(db)
        }
    }

    /// What a walk that ran out of deadline writes instead of `replace`: adds and refreshes,
    /// never deletes. Still stamps `ScanState` so the daily interval measures from it.
    /// - Returns: how many correspondents the mailbox holds once the merge has landed.
    @discardableResult
    func merge(account: String, contacts: [Contact]) async -> Int {
        guard let dbPool else { return 0 }
        let held = try? await dbPool.write { db -> Int in
            for row in contacts {
                let existing = try Contact
                    .filter(Column("account") == account)
                    .filter(Column("email") == row.email)
                    .fetchOne(db)
                var merged = row
                if let existing {
                    merged.displayName = row.displayName.isEmpty
                        ? existing.displayName : row.displayName
                    merged.sentTo = max(existing.sentTo, row.sentTo)
                    merged.receivedFrom = max(existing.receivedFrom, row.receivedFrom)
                    merged.lastSeen = max(existing.lastSeen, row.lastSeen)
                }
                try merged.save(db)
            }
            let total = try Contact.filter(Column("account") == account).fetchCount(db)
            try ScanState(account: account, scannedAt: Date(), contacts: total).save(db)
            return total
        }
        return held ?? 0
    }

    /// Fold cached calendar attendees into the directory. An existing row only gains a missing
    /// name; new rows get zero counts so they sort below people the user writes to.
    /// - Returns: how many rows this added.
    @discardableResult
    func absorbCalendar(account: String, people: [(email: String, name: String, when: Int64)]) async -> Int {
        guard let dbPool, !people.isEmpty else { return 0 }
        let own = account.lowercased()
        let added = try? await dbPool.write { db -> Int in
            var count = 0
            for person in people {
                let email = person.email.lowercased()
                // The user is on every event and is never the answer to "who is Sarah".
                guard email.contains("@"), email != own else { continue }
                let existing = try Contact
                    .filter(Column("account") == account)
                    .filter(Column("email") == email)
                    .fetchOne(db)
                if var row = existing {
                    guard row.displayName.isEmpty, !person.name.isEmpty else { continue }
                    row.displayName = person.name
                    try row.save(db)
                    continue
                }
                try Contact(
                    account: account,
                    email: email,
                    displayName: person.name,
                    sentTo: 0,
                    receivedFrom: 0,
                    lastSeen: person.when,
                    source: Source.calendar
                ).save(db)
                count += 1
            }
            return count
        }
        return added ?? 0
    }

    /// Everything, for sign-out. Google-derived data under the restricted scope, so it is
    /// purged with `MailStore.purgeAll`.
    func purgeAll() async {
        guard let dbPool else { return }
        try? await dbPool.write { db in
            try Contact.deleteAll(db)
            try ScanState.deleteAll(db)
        }
    }

    /// Drop everything for a mailbox whose grant has gone.
    func forget(account: String) async {
        guard let dbPool else { return }
        try? await dbPool.write { db in
            try Contact.filter(Column("account") == account).deleteAll(db)
            try ScanState.deleteOne(db, key: account)
        }
    }

    // MARK: - Ranking

    /// Sent mail counts triple: someone the user writes to is who they usually mean.
    private static func score(_ c: Contact) -> Double {
        Double(c.sentTo * 3 + c.receivedFrom) + recencyBonus(c.lastSeen)
    }

    /// A tie-break, not a ranking. Worth at most one message, so it separates two people
    /// with the same traffic and never outweighs someone the user actually writes to.
    private static func recencyBonus(_ lastSeen: Int64) -> Double {
        guard lastSeen > 0 else { return 0 }
        let days = Date().timeIntervalSince1970 / 86_400 - Double(lastSeen) / 86_400_000
        return days < 0 ? 1 : max(0, 1 - days / 365)
    }

    private static func asMatch(_ c: Contact) -> Match {
        Match(
            account: c.account,
            name: c.displayName,
            email: c.email,
            messages: c.sentTo + c.receivedFrom,
            lastSeen: c.lastSeen > 0 ? Self.day.string(
                from: Date(timeIntervalSince1970: Double(c.lastSeen) / 1000)) : ""
        )
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

}

/// `"Sarah Chen" <sarah@x.com>, bob@y.com` → the pairs. Display names can contain commas
/// ("Chen, Sarah"), so splitting ignores commas inside quotes and angle brackets.
enum MailAddress {
    struct Parsed: Sendable {
        let name: String
        /// Bare and lowercased.
        let email: String
    }

    static func list(_ header: String?) -> [Parsed] {
        guard let header, !header.isEmpty else { return [] }
        return split(header).compactMap(one)
    }

    private static func split(_ header: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var inAngles = false
        for ch in header {
            switch ch {
            case "\"": inQuotes.toggle(); current.append(ch)
            case "<" where !inQuotes: inAngles = true; current.append(ch)
            case ">" where !inQuotes: inAngles = false; current.append(ch)
            case "," where !inQuotes && !inAngles:
                parts.append(current); current = ""
            default: current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    private static func one(_ raw: String) -> Parsed? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"),
           open < close {
            let email = String(trimmed[trimmed.index(after: open)..<close])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard email.contains("@") else { return nil }
            let name = trimmed[trimmed.startIndex..<open]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
            return Parsed(name: name, email: email)
        }

        let email = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: " <>\""))
            .lowercased()
        guard email.contains("@") else { return nil }
        return Parsed(name: "", email: email)
    }
}
