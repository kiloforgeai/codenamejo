// coverage-target: CodenameJo/Services/BackgroundRefresh/ContactScan.swift

import GRDB
import XCTest

@testable import CodenameJo

/// The two guards on the correspondent walk, both of which are about not spending Gmail
/// requests and not losing people the last walk found. Neither case lets the walk reach
/// the network: the daily interval stops one before it starts, and an already-elapsed
/// deadline stops the other on its first page.
final class ContactScanGuardTests: XCTestCase {

    private var database: DatabasePool!
    private var directory: URL!
    private var store: ContactStore!

    private let account = "work@example.test"
    private let other = "personal@example.test"
    private let seen: Int64 = 1_700_000_000_000

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try DatabasePool(path: directory.appendingPathComponent("test.sqlite").path)
        try database.write { db in
            try ContactStore.createSchema(db)
            try ContactStore.addSource(db)
        }
        store = ContactStore(database: database)
    }

    override func tearDownWithError() throws {
        store = nil
        try? database.close()
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Seeds one mailbox and, with it, the `ScanState` stamp a finished walk leaves.
    private func seedWalkedDirectory() async {
        await store.replace(account: account, contacts: [
            ContactStore.Contact(
                account: account, email: "sam.hart@work.test", displayName: "Sam Hart",
                sentTo: 5, receivedFrom: 2, lastSeen: seen),
            ContactStore.Contact(
                account: account, email: "nate@work.test", displayName: "Nate Ford",
                sentTo: 1, receivedFrom: 0, lastSeen: seen),
        ])
    }

    func testAMailboxWalkedTodayIsSkippedWithoutRestampingTheInterval() async throws {
        await seedWalkedDirectory()
        let stamped = await store.scanState(account: account)
        let before = try XCTUnwrap(stamped)

        // `force` is off and the stamp is seconds old, so the walk must decline entirely.
        // The deadline is already past as a backstop: if the interval guard ever stopped
        // holding, the walk still cannot reach Gmail from this test.
        let held = await ContactScan.run(
            token: "not-a-token", account: account, store: store,
            deadline: Date().addingTimeInterval(-1), force: false)

        // nil is "skipped", which is not the same answer as "walked and found nobody".
        XCTAssertNil(held)

        let restamped = await store.scanState(account: account)
        let after = try XCTUnwrap(restamped)
        // A skip that restamped would push the daily interval out on every pass, so the
        // rebuild would never come round again.
        XCTAssertEqual(after.scannedAt, before.scannedAt)
        XCTAssertEqual(after.contacts, before.contacts)

        let people = await store.all(account: account)
        XCTAssertEqual(Set(people.map(\.email)), ["sam.hart@work.test", "nate@work.test"])
    }

    func testAForcedWalkThatRunsOutOfDeadlineKeepsTheDirectoryItFoundNothingToReplace() async throws {
        await seedWalkedDirectory()
        await store.replace(account: other, contacts: [
            ContactStore.Contact(
                account: other, email: "mum@family.test", displayName: "Mum",
                sentTo: 9, receivedFrom: 9, lastSeen: seen),
        ])
        let stamped = await store.scanState(account: account)
        let before = try XCTUnwrap(stamped)

        // Forced past the interval, but with no time left to read a single page. A walk
        // that read nothing must not be mistaken for a mailbox with nobody in it —
        // treating the two alike is what deleted 24 real correspondents once already.
        let held = await ContactScan.run(
            token: "not-a-token", account: account, store: store,
            deadline: Date().addingTimeInterval(-1), force: true)

        XCTAssertNil(held)

        let people = await store.all(account: account)
        XCTAssertEqual(Set(people.map(\.email)), ["sam.hart@work.test", "nate@work.test"])
        let afterForced = await store.scanState(account: account)
        XCTAssertEqual(try XCTUnwrap(afterForced).scannedAt, before.scannedAt)

        // And the walk is scoped to the mailbox it was given: the other account's people
        // are not this walk's to keep or to drop.
        let elsewhere = await store.all(account: other)
        XCTAssertEqual(elsewhere.map(\.email), ["mum@family.test"])
    }
}
