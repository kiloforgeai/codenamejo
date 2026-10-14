import XCTest
import GRDB
@testable import CodenameJo

/// The on-device correspondent directory is keyed on the mailbox that saw each person,
/// and the same first name is a different person in a work and a personal account. These
/// are the reads and the deletes that have to respect that key.
final class ContactDirectoryTests: XCTestCase {
    private var database: DatabasePool!
    private var directory: URL!
    private var store: ContactStore!

    private let work = "work@example.test"
    private let personal = "personal@example.test"
    /// Fixed rather than `Date()`: `Match.lastSeen` is formatted from it in UTC.
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

    private func contact(
        _ account: String, _ email: String, _ name: String,
        sentTo: Int = 1, receivedFrom: Int = 0
    ) -> ContactStore.Contact {
        ContactStore.Contact(
            account: account, email: email, displayName: name,
            sentTo: sentTo, receivedFrom: receivedFrom, lastSeen: seen)
    }

    private func seedTwoMailboxes() async {
        await store.replace(account: work, contacts: [
            contact(work, "sam.hart@work.test", "Sam Hart", sentTo: 5),
            contact(work, "nate@work.test", "Nate Ford"),
        ])
        await store.replace(account: personal, contacts: [
            contact(personal, "sam@family.test", "Sam Delgado", sentTo: 9),
        ])
    }

    func testALookupScopedToOneMailboxNeverAnswersWithAnother() async {
        await seedTwoMailboxes()

        let onWork = await store.matches(name: "Sam", account: work)
        XCTAssertEqual(onWork.matches.map(\.email), ["sam.hart@work.test"])
        XCTAssertEqual(onWork.matches.first?.account, work)
        XCTAssertFalse(onWork.fuzzy)
        // The date the model reads is formatted in UTC from the stored millisecond.
        XCTAssertEqual(onWork.matches.first?.lastSeen, "2023-11-14")
        XCTAssertEqual(onWork.matches.first?.messages, 5)

        let onPersonal = await store.matches(name: "Sam", account: personal)
        XCTAssertEqual(onPersonal.matches.map(\.email), ["sam@family.test"])
    }

    func testTheConnectedListIsABackstopWhenARowOutlivesItsAccount() async {
        await seedTwoMailboxes()

        // Only the work mailbox is still connected: the personal row must not answer,
        // even though it is in the table and scores higher.
        let connected = await store.matches(name: "Sam", accounts: [work])
        XCTAssertEqual(connected.matches.map(\.email), ["sam.hart@work.test"])

        // No filter at all is the documented reading of "nothing connected".
        let unfiltered = await store.matches(name: "Sam")
        XCTAssertEqual(Set(unfiltered.matches.map(\.email)),
                       ["sam.hart@work.test", "sam@family.test"])

        // An account filter beats the connected list rather than intersecting with it.
        let scoped = await store.matches(name: "Sam", account: personal, accounts: [work])
        XCTAssertEqual(scoped.matches.map(\.email), ["sam@family.test"])

        let nobody = await store.matches(name: "Sam", accounts: ["gone@example.test"])
        XCTAssertTrue(nobody.matches.isEmpty)
        // Nothing to search on is not a search.
        let blank = await store.matches(name: "   ", account: work)
        XCTAssertTrue(blank.matches.isEmpty)
    }

    func testForgettingOneMailboxLeavesTheOtherDirectoryIntact() async {
        await seedTwoMailboxes()
        let before = await store.count()
        XCTAssertEqual(before, 3)

        await store.forget(account: work)

        let after = await store.count()
        let forgotten = await store.scanState(account: work)
        let kept = await store.scanState(account: personal)
        let lookup = await store.matches(name: "Sam", account: work)
        let personalRows = await store.all(account: personal)
        XCTAssertEqual(after, 1)
        XCTAssertNil(forgotten)
        XCTAssertEqual(kept?.contacts, 1)
        XCTAssertTrue(lookup.matches.isEmpty)
        XCTAssertEqual(personalRows.count, 1)
    }

    func testSignOutPurgeLeavesNoRowAndNoScanState() async {
        await seedTwoMailboxes()
        await store.purgeAll()
        let remaining = await store.count()
        let workScan = await store.scanState(account: work)
        let personalScan = await store.scanState(account: personal)
        let known = await store.hasCorresponded(email: "sam.hart@work.test")
        XCTAssertEqual(remaining, 0)
        XCTAssertNil(workScan)
        XCTAssertNil(personalScan)
        XCTAssertFalse(known)
    }

    func testAScanReplacesOnlyItsOwnMailboxAndRecordsAnEmptyWalk() async {
        await seedTwoMailboxes()

        await store.replace(account: work, contacts: [contact(work, "kim@work.test", "Kim Lee")])
        let workRows = await store.all(account: work)
        let personalRows = await store.all(account: personal)
        let scan = await store.scanState(account: work)
        XCTAssertEqual(workRows.map(\.email), ["kim@work.test"])
        XCTAssertEqual(personalRows.count, 1)
        XCTAssertEqual(scan?.contacts, 1)

        // Zero is a real answer — it separates "ran and found nobody" from "never ran".
        await store.replace(account: work, contacts: [])
        let emptyScan = await store.scanState(account: work)
        let emptyRows = await store.all(account: work)
        let total = await store.count()
        XCTAssertEqual(emptyScan?.contacts, 0)
        XCTAssertTrue(emptyRows.isEmpty)
        XCTAssertEqual(total, 1)
    }

    func testAMirrorMergesRatherThanReplacingAndNeverLosesTheBetterFact() async {
        await store.replace(account: work, contacts: [
            contact(work, "sam.hart@work.test", "Sam Hart", sentTo: 5, receivedFrom: 2),
            contact(work, "nate@work.test", "Nate Ford"),
        ])

        await store.merge([
            // A blank name must not overwrite one this phone already has, and the
            // larger count wins whichever side holds it.
            ContactStore.Contact(
                account: work, email: "sam.hart@work.test", displayName: "",
                sentTo: 1, receivedFrom: 7, lastSeen: seen - 1_000),
            contact(work, "remote@other.test", "Remote Person"),
        ])

        let rows = await store.all(account: work)
        let sam = rows.first { $0.email == "sam.hart@work.test" }
        XCTAssertEqual(sam?.displayName, "Sam Hart")
        XCTAssertEqual(sam?.sentTo, 5)
        XCTAssertEqual(sam?.receivedFrom, 7)
        XCTAssertEqual(sam?.lastSeen, seen)
        // The merge adds, and takes nothing away: the scanned row survives it.
        XCTAssertEqual(Set(rows.map(\.email)),
                       ["sam.hart@work.test", "nate@work.test", "remote@other.test"])
    }

    /// Confirming one specific address is deliberately not scoped to a mailbox — it
    /// answers "has this person ever been written to", from any account.
    func testCorrespondenceCheckIsAddressExactAndSpansAccounts() async {
        await seedTwoMailboxes()
        let otherMailbox = await store.hasCorresponded(email: "SAM@Family.test")
        let exact = await store.hasCorresponded(email: "nate@work.test")
        let nearMiss = await store.hasCorresponded(email: "nate@work.test.uk")
        let stranger = await store.hasCorresponded(email: "stranger@example.test")
        XCTAssertTrue(otherMailbox)
        XCTAssertTrue(exact)
        XCTAssertFalse(nearMiss)
        XCTAssertFalse(stranger)
    }

    func testAStoreWithNoDatabaseAnswersEmptyRatherThanTrapping() async {
        let none = ContactStore(database: nil)
        await none.merge([contact(work, "a@b.test", "A B")])
        await none.replace(account: work, contacts: [contact(work, "a@b.test", "A B")])
        let count = await none.count()
        let lookup = await none.matches(name: "A")
        let known = await none.hasCorresponded(email: "a@b.test")
        let scan = await none.scanState(account: work)
        XCTAssertEqual(count, 0)
        XCTAssertTrue(lookup.matches.isEmpty)
        XCTAssertFalse(known)
        XCTAssertNil(scan)
    }
}
