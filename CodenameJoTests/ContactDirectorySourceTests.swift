import GRDB
import XCTest

@testable import CodenameJo

/// The correspondent directory once it has two sources feeding it.
///
/// The case these exist for is the one nothing else would catch: a mail walk runs daily and
/// `replace` used to clear the whole account, so calendar-only people would be added by one
/// pass and silently deleted by the next. The symptom is a lookup that works today and misses
/// tomorrow, which is indistinguishable from a directory that was simply never built.
final class ContactDirectorySourceTests: XCTestCase {

    // MARK: - Calendar attendees

    func testCalendarAttendeeIsFoundByName() async throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let added = await store.absorbCalendar(account: account, people: [tyler])
        XCTAssertEqual(added, 1)

        let found = await store.matches(name: "Tyler Jones", accounts: [account])
        XCTAssertEqual(found.matches.map(\.email), ["tyler.jones@ridge.test"])
    }

    /// Absorbing the same window twice is what every calendar pass does — the rolling window
    /// is re-fetched wholesale, so the same attendees arrive again and must not duplicate or
    /// re-count.
    func testAbsorbingTheSameWindowTwiceAddsNothing() async throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = await store.absorbCalendar(account: account, people: [tyler])
        let again = await store.absorbCalendar(account: account, people: [tyler])
        let rows = await store.all(account: account)

        XCTAssertEqual(again, 0)
        XCTAssertEqual(rows.count, 1)
    }

    /// A person the user actually corresponds with has counts an attendee list cannot
    /// improve on, and an invite's display name is not better than their own mail's.
    func testCalendarNeverOverwritesAMailRow() async throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        await store.replace(account: account, contacts: [
            contact(email: "tyler.jones@ridge.test", name: "Tyler", sentTo: 7, lastSeen: 5_000)
        ])
        _ = await store.absorbCalendar(account: account, people: [tyler])

        let rows = await store.all(account: account)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.displayName, "Tyler")
        XCTAssertEqual(row.sentTo, 7)
        XCTAssertEqual(row.lastSeen, 5_000)
        XCTAssertEqual(row.source, ContactStore.Source.mail)
    }

    /// Plenty of headers carry a bare address, and an invite's name is better than none.
    func testCalendarFillsADisplayNameTheMailWalkNeverGot() async throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        await store.replace(account: account, contacts: [
            contact(email: "tyler.jones@ridge.test", name: "", sentTo: 7, lastSeen: 5_000)
        ])
        _ = await store.absorbCalendar(account: account, people: [tyler])

        let rows = await store.all(account: account)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.displayName, "Tyler Jones")
        XCTAssertEqual(row.sentTo, 7, "filling a name must not disturb the traffic")
    }

    /// The user attends every event they can see and is never the answer to "who is Sarah".
    func testCalendarSkipsTheUsersOwnAddress() async throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let added = await store.absorbCalendar(
            account: account,
            people: [(email: account, name: "Rob Wan", when: Int64(1_000))]
        )
        let rows = await store.all(account: account)

        XCTAssertEqual(added, 0)
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - The mail walk's reach

    /// **The regression this file mainly exists for.** A mail walk is authoritative for the
    /// folders it read and says nothing about the calendar's people; clearing the account
    /// wholesale deleted them once a day, forever.
    func testAMailWalkDropsStaleMailRowsAndKeepsCalendarRows() async throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = await store.absorbCalendar(account: account, people: [tyler])
        await store.replace(account: account, contacts: [
            contact(email: "stale@example.com", name: "Stale", sentTo: 1, lastSeen: 1)
        ])
        // The second walk no longer finds the first walk's correspondent.
        await store.replace(account: account, contacts: [
            contact(email: "fresh@example.com", name: "Fresh", sentTo: 2, lastSeen: 2)
        ])

        let emails = Set(await store.all(account: account).map(\.email))
        XCTAssertEqual(emails, ["fresh@example.com", "tyler.jones@ridge.test"])
    }

    /// A walk that also finds a calendar person should leave one row, upgraded — real traffic
    /// beats an attendee list.
    func testAMailWalkUpgradesACalendarRowRatherThanDuplicatingIt() async throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = await store.absorbCalendar(account: account, people: [tyler])
        await store.replace(account: account, contacts: [
            contact(email: "tyler.jones@ridge.test", name: "Tyler Jones", sentTo: 7, lastSeen: 9)
        ])

        let rows = await store.all(account: account)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.sentTo, 7)
        XCTAssertEqual(rows.first?.source, ContactStore.Source.mail)
    }

    /// A truncated walk covered the newest mail and nothing else. Replacing on it would shrink
    /// the directory to whatever fitted in the deadline.
    func testATruncatedWalkNeverShrinksTheDirectory() async throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        await store.replace(account: account, contacts: [
            contact(email: "one@example.com", name: "One", sentTo: 1, lastSeen: 1),
            contact(email: "two@example.com", name: "Two", sentTo: 2, lastSeen: 2),
        ])
        let held = await store.merge(account: account, contacts: [
            contact(email: "three@example.com", name: "Three", sentTo: 3, lastSeen: 3)
        ])
        let emails = Set(await store.all(account: account).map(\.email))

        XCTAssertEqual(held, 3)
        XCTAssertEqual(emails, ["one@example.com", "two@example.com", "three@example.com"])
    }

    /// The merge takes whichever side saw more, so re-walking the same mail cannot double a
    /// count and a shorter walk cannot lower one.
    func testAMergeKeepsTheLargerCount() async throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        await store.replace(account: account, contacts: [
            contact(email: "one@example.com", name: "One", sentTo: 9, lastSeen: 9)
        ])
        _ = await store.merge(account: account, contacts: [
            contact(email: "one@example.com", name: "One", sentTo: 2, lastSeen: 2)
        ])

        let rows = await store.all(account: account)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.sentTo, 9)
        XCTAssertEqual(row.lastSeen, 9)
    }

    // MARK: - Migration

    /// Every row that predates the column came from a mail walk, which is what the default
    /// says — so a directory built before this change keeps answering, and the first walk
    /// after it still owns those rows.
    func testExistingRowsMigrateToTheMailSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabasePool(path: directory.appendingPathComponent("test.sqlite").path)

        // The schema as it stood before v31, then a row written into it.
        try await database.write { db in
            try ContactStore.createSchema(db)
            try db.execute(
                sql: """
                    INSERT INTO contact (account, email, displayName, sentTo, receivedFrom, lastSeen)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [self.account, "old@example.com", "Old", 4, 1, 7])
        }
        try await database.write { db in try ContactStore.addSource(db) }

        let rows = await ContactStore(database: database).all(account: account)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.source, ContactStore.Source.mail)
        XCTAssertEqual(row.sentTo, 4)
    }

    // MARK: - Helpers

    private let account = "rob@example.com"

    /// An attendee who was only ever met on an invite, never mailed.
    private let tyler = (
        email: "tyler.jones@ridge.test", name: "Tyler Jones", when: Int64(1_000)
    )

    private func makeStore() throws -> (ContactStore, DatabasePool, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try DatabasePool(path: directory.appendingPathComponent("test.sqlite").path)
        try database.write { db in
            try ContactStore.createSchema(db)
            try ContactStore.addSource(db)
        }
        return (ContactStore(database: database), database, directory)
    }

    private func contact(
        email: String, name: String, sentTo: Int, lastSeen: Int64
    ) -> ContactStore.Contact {
        ContactStore.Contact(
            account: account, email: email, displayName: name,
            sentTo: sentTo, receivedFrom: 0, lastSeen: lastSeen)
    }
}
