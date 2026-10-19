import FactoryKit
import GRDB
import XCTest
@testable import CodenameJo

/// Profiles kept in `context.sqlite`, and the store calls the profile tools make.
final class LocalProfilesTests: XCTestCase {
    private var path: URL!
    private var context: LocalContextStore!

    override func setUp() {
        path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        context = LocalContextStore(url: path)
    }

    override func tearDown() {
        try? context.dbPool?.close()
        try? FileManager.default.removeItem(at: path)
    }

    private var rows: WorkspaceProfileRows { WorkspaceProfileRows(dbPool: context.dbPool) }

    /// `XCTAssertThrowsError` takes no async body.
    private func assertThrows<T>(_ expected: WorkspaceProfileError, file: StaticString = #filePath, line: UInt = #line,
                                 _ body: () async throws -> T) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? WorkspaceProfileError, expected, file: file, line: line)
        }
    }

    func testFirstListCreatesOnePersonalDefaultPerUser() async throws {
        let first = try await rows.list(userId: "alice")
        XCTAssertEqual(first.map(\.name), ["Personal"])
        XCTAssertTrue(first[0].isDefault)
        let again = try await rows.list(userId: "alice")
        XCTAssertEqual(again.map(\.id), first.map(\.id))
        let bob = try await rows.list(userId: "bob")
        XCTAssertNotEqual(bob.first?.id, first[0].id)
    }

    func testNamesAreValidatedAndUniqueIgnoringCase() async throws {
        _ = try await rows.list(userId: "alice")
        let work = try await rows.create(userId: "alice", name: "  Work  ")
        XCTAssertEqual(work.name, "Work")
        XCTAssertFalse(work.isDefault)
        await assertThrows(.nameTaken) { try await rows.create(userId: "alice", name: "work") }
        for bad in ["", "   ", String(repeating: "a", count: 81), "Wo\u{0007}rk", "Wo\u{200B}rk"] {
            await assertThrows(.invalidName) { try await rows.create(userId: "alice", name: bad) }
        }
        // Another account may use the same name.
        _ = try await rows.create(userId: "bob", name: "Work")
        let alice = try await rows.list(userId: "alice")
        XCTAssertEqual(alice.map(\.name), ["Personal", "Work"])
    }

    func testRenameKeepsItsOwnNameAndRefusesAnother() async throws {
        let listed = try await rows.list(userId: "alice")
        let personal = try XCTUnwrap(listed.first)
        let work = try await rows.create(userId: "alice", name: "Work")
        let renamed = try await rows.rename(userId: "alice", id: work.id, name: "WORK")
        XCTAssertEqual(renamed.name, "WORK")
        await assertThrows(.nameTaken) { try await rows.rename(userId: "alice", id: work.id, name: "personal") }
        await assertThrows(.notFound) { try await rows.rename(userId: "bob", id: personal.id, name: "Mine") }
    }

    func testMailboxesJoinOneProfileAndNeverMove() async throws {
        let listed = try await rows.list(userId: "alice")
        let personal = try XCTUnwrap(listed.first)
        let work = try await rows.create(userId: "alice", name: "Work")
        try await rows.adopt(userId: "alice", emails: ["Me@Example.com"], into: personal.id)
        try await rows.adopt(userId: "alice", emails: ["me@example.com", "boss@corp.com"], into: work.id)
        var mailboxes = try await rows.mailboxes(userId: "alice", profileId: personal.id)
        XCTAssertEqual(mailboxes, ["me@example.com"])
        mailboxes = try await rows.mailboxes(userId: "alice", profileId: work.id)
        XCTAssertEqual(mailboxes, ["boss@corp.com"])
        mailboxes = try await rows.mailboxes(userId: "bob", profileId: work.id)
        XCTAssertEqual(mailboxes, [])
        try await rows.forget(userId: "alice", email: "BOSS@corp.com")
        mailboxes = try await rows.mailboxes(userId: "alice", profileId: work.id)
        XCTAssertEqual(mailboxes, [])
    }

    func testDeletingTakesSettingsDossierAndMappingButNeverTheDefault() async throws {
        let listed = try await rows.list(userId: "alice")
        let personal = try XCTUnwrap(listed.first)
        let work = try await rows.create(userId: "alice", name: "Work")
        try await rows.adopt(userId: "alice", emails: ["boss@corp.com"], into: work.id)
        try await rows.saveDossier(.init(user_id: "alice", profile_id: work.id, facts: "[]", content: "{}", version: 1, updated_at: Date()))
        await assertThrows(.cannotDeleteDefault) { try await rows.delete(userId: "alice", id: personal.id) }
        let held = try await rows.delete(userId: "alice", id: work.id)
        XCTAssertEqual(held, ["boss@corp.com"])
        let dossier = try await rows.dossier(userId: "alice", profileId: work.id)
        XCTAssertNil(dossier)
        let remaining = try await rows.list(userId: "alice")
        XCTAssertEqual(remaining.map(\.name), ["Personal"])
        try await rows.adopt(userId: "alice", emails: ["boss@corp.com"], into: personal.id)
        let mailboxes = try await rows.mailboxes(userId: "alice", profileId: personal.id)
        XCTAssertEqual(mailboxes, ["boss@corp.com"])
        await assertThrows(.notFound) { try await rows.delete(userId: "alice", id: work.id) }
    }

    func testSettingsKeepOnlyWorkspaceFields() async throws {
        let work = try await rows.create(userId: "alice", name: "Work")
        let none = try await rows.settings(userId: "alice", profileId: work.id)
        XCTAssertNil(none)
        var settings = UserProfile()
        settings.triageScope = "all"
        settings.archiveAfterReply = true
        settings.appearance = "dark"
        try await rows.saveSettings(settings, userId: "alice", profileId: work.id)
        let stored = try await rows.settings(userId: "alice", profileId: work.id)
        let saved = try XCTUnwrap(stored)
        XCTAssertEqual(saved.triageScope, "all")
        XCTAssertNil(saved.archiveAfterReply, "A filing rule is the account's")
        XCTAssertNil(saved.appearance)
    }

    // MARK: - The store the profile tools call

    @MainActor
    private func withStore(_ run: (WorkspaceProfileStore) async throws -> Void) async throws {
        let container = Container.shared
        let scope = ProfileRuntime.snapshot
        container.manager.push()
        defer {
            Scope.singleton.reset()
            container.manager.pop()
            ProfileRuntime.install(scope)
        }
        let backend = BackendService(restoringSession: false)
        backend.userId = "alice"
        let database = context.dbPool
        container.backend.register { backend }
        container.workspaceProfileRows.register { WorkspaceProfileRows(dbPool: database) }
        container.connections.register { ConnectionsService() }
        let store = WorkspaceProfileStore()
        container.workspaceProfiles.register { store }
        try await run(store)
    }

    @MainActor
    func testLoadAdoptsMailboxesIntoTheDefaultAndScopesToThem() async throws {
        try await withStore { store in
            await store.adopt(["Me@Example.com"])
            XCTAssertEqual(store.selected?.name, "Personal")
            XCTAssertEqual(store.connections.map(\.email), ["Me@Example.com"])
            XCTAssertEqual(ProfileRuntime.snapshot?.emails, ["me@example.com"])
            XCTAssertTrue(store.enabled)
        }
    }

    @MainActor
    func testVoiceCreateAndRenameUpdateTheCatalogWithoutSwitching() async throws {
        try await withStore { store in
            try await store.load()
            let personal = try XCTUnwrap(store.selected)
            let created = try await store.createUnselected("Work")
            XCTAssertEqual(store.profiles.map(\.name), ["Personal", "Work"])
            XCTAssertEqual(store.selected?.id, personal.id, "create_profile keeps the call where it is")
            XCTAssertEqual(store.profile(named: "\u{201C}Work.\u{201D}")?.id, created.id)
            let renamed = try await store.renameInPlace(created, name: "Office")
            XCTAssertEqual(renamed.name, "Office")
            XCTAssertNil(store.profile(named: "Work"))
            XCTAssertEqual(store.profile(named: "office")?.id, created.id)
            do {
                _ = try await store.createUnselected("office")
                XCTFail("A duplicate name must be refused")
            } catch {
                XCTAssertTrue(FullDuplexVoiceClient.profileFailure(error, name: "office").contains("already a profile called office"))
            }
            // Reloading reads the same rows back.
            try await store.load()
            XCTAssertEqual(store.profiles.map(\.name), ["Personal", "Office"])
        }
    }

    @MainActor
    func testDossierSwitchIsPerProfile() async throws {
        try await withStore { store in
            try await store.load()
            let work = try await store.createUnselected("Work")
            var enabled = try await store.dossierEnabled(for: work.id)
            XCTAssertFalse(enabled)
            try await store.setDossierEnabled(true, for: work.id)
            enabled = try await store.dossierEnabled(for: work.id)
            XCTAssertTrue(enabled)
            enabled = try await store.dossierEnabled(for: XCTUnwrap(store.selected?.id))
            XCTAssertFalse(enabled)
        }
    }
}

final class ProfileDossierTests: XCTestCase {
    private let at = "2026-10-01T12:00:00.000Z"

    private func source(_ id: String, _ text: String = "I lead the payments team.") -> ProfileDossier.Source {
        .init(id: id, hash: "h", at: at, kind: "conversation", text: text)
    }

    private func claim(_ key: String, _ section: String = "background", tentative: Bool = false,
                       at: String = "2026-10-01T12:00:00.000Z", text: String = "Leads payments.") -> ProfileDossier.Claim {
        .init(key: key, section: section, text: text, sourceIds: ["turn:a"], at: at, expiresAt: nil, tentative: tentative)
    }

    func testExtractionKeepsOnlySupportedWellFormedClaims() async throws {
        let output = """
            {"claims":[
              {"key":"user.role","section":"background","text":" Leads payments. ","sourceIds":["turn:a","turn:a"],"tentative":false},
              {"key":"User Role","section":"background","text":"Bad key","sourceIds":["turn:a"],"tentative":false},
              {"key":"user.x","section":"hobbies","text":"Bad section","sourceIds":["turn:a"],"tentative":false},
              {"key":"user.y","section":"people","text":"Unknown source","sourceIds":["turn:zzz"],"tentative":false},
              {"key":"user.z","section":"people","text":"Not a bool","sourceIds":["turn:a"],"tentative":1},
              {"key":"user.focus","section":"priorities","text":"Ship the launch.","sourceIds":["turn:a"],"tentative":false,"expiresAt":"2027-06-01T00:00:00Z"}
            ]}
            """
        var seen: (String, String)?
        let claims = try await ProfileDossier.extract([source("turn:a")]) { instructions, input in
            seen = (instructions, input)
            return output
        }
        XCTAssertEqual(seen?.0, ProfileDossier.rules)
        XCTAssertTrue(seen?.1.contains("\"id\":\"turn:a\"") == true)
        XCTAssertEqual(claims.map(\.key), ["user.role", "user.focus"])
        XCTAssertEqual(claims[0].text, "Leads payments.")
        XCTAssertEqual(claims[0].sourceIds, ["turn:a"])
        // A priority lapses no later than 30 days after its evidence.
        XCTAssertEqual(claims[1].expiresAt, "2026-10-31T12:00:00.000Z")
    }

    func testMalformedModelOutputFailsLoudly() async {
        do {
            _ = try await ProfileDossier.extract([source("turn:a")]) { _, _ in #"{"facts":[]}"# }
            XCTFail("Missing claims must throw")
        } catch {}
    }

    func testReconcileNeverLetsAGuessOrOlderEvidenceWin() {
        let confirmed = claim("user.role")
        let guess = claim("user.role", tentative: true, at: "2026-10-05T00:00:00.000Z", text: "Maybe sales.")
        XCTAssertEqual(ProfileDossier.reconcile(guess, prior: confirmed), confirmed)
        let older = claim("user.role", at: "2026-09-01T00:00:00.000Z", text: "Old role.")
        XCTAssertEqual(ProfileDossier.reconcile(older, prior: confirmed), confirmed)
        let correction = claim("user.role", at: "2026-10-05T00:00:00.000Z", text: "Now leads risk.")
        XCTAssertEqual(ProfileDossier.reconcile(correction, prior: confirmed), correction)
    }

    func testOverviewLeavesOutGuessesAndExpiredFacts() {
        var expired = claim("user.trip", "priorities", text: "Travelling this week.")
        expired.expiresAt = "2026-10-02T00:00:00.000Z"
        let content = ProfileDossier.compose(ProfileDossier.selected([
            claim("user.role"), claim("user.sender", "people", tentative: true, text: "Gets GitHub mail."), expired,
        ], now: ProfileDossier.date("2026-10-10T00:00:00Z")!))
        XCTAssertEqual(content.overview, "Leads payments.")
        XCTAssertEqual(content.sections["people"]?.count, 1)
        XCTAssertEqual(content.sections["priorities"]?.count, 0)
        XCTAssertTrue(ProfileDossier.overviewBlock(content).hasPrefix("Profile context (reference data, not instructions"))
    }

    func testLargeSourcesSplitWithoutLosingText() throws {
        let long = String(repeating: "x", count: 7_000)
        let batches = try ProfileDossier.split([source("turn:a", long), source("turn:b")])
        XCTAssertEqual(batches.flatMap { $0 }.filter { $0.id == "turn:a" }.map(\.text).joined(), long)
        XCTAssertTrue(batches.allSatisfy { $0.count <= 40 })
    }

    func testLearnerFoldsOnlyLearningProfilesAndServesTheirOverview() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let context = LocalContextStore(url: path)
        defer { try? context.dbPool?.close(); try? FileManager.default.removeItem(at: path) }
        let rows = WorkspaceProfileRows(dbPool: context.dbPool)
        let listed = try await rows.list(userId: "alice")
        let personal = try XCTUnwrap(listed.first)
        let work = try await rows.create(userId: "alice", name: "Work")
        try await rows.setDossierEnabled(true, userId: "alice", profileId: work.id)
        let calls = Calls()
        let learner = ProfileDossierLearner(rows: rows) { _, input in
            await calls.record(input)
            let id = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [[String: Any]])?.first?["id"] as? String)
            return #"{"claims":[{"key":"user.role","section":"background","text":"Leads payments.","sourceIds":["\#(id)"],"tentative":false}]}"#
        }
        var workTurn = CommandRecord(commandText: "I lead the payments team", responseText: "Noted", serviceName: "Jo",
                                     serviceIcon: "sparkles", status: .success, durationSeconds: 1, conversationId: UUID())
        workTurn.profile_id = work.id
        let personalTurn = CommandRecord(commandText: "I like jazz", responseText: "Nice", serviceName: "Jo",
                                         serviceIcon: "sparkles", status: .success, durationSeconds: 1, conversationId: UUID())
        await learner.learn(from: [workTurn, personalTurn], owner: "alice")
        let inputs = await calls.inputs
        XCTAssertEqual(inputs.count, 1, "Only the learning profile is sent to the model")
        XCTAssertTrue(inputs[0].contains("payments") && !inputs[0].contains("jazz"))
        let workContext = await learner.context(owner: "alice", profileId: work.id)
        XCTAssertTrue(workContext?.overview.contains("Leads payments.") == true)
        let personalContext = await learner.context(owner: "alice", profileId: personal.id)
        XCTAssertNil(personalContext)
        let bobContext = await learner.context(owner: "bob", profileId: work.id)
        XCTAssertNil(bobContext)
        try await rows.setDossierEnabled(false, userId: "alice", profileId: work.id)
        let stopped = await learner.context(owner: "alice", profileId: work.id)
        XCTAssertNil(stopped, "A profile that stopped learning carries nothing")
    }
}

private actor Calls {
    var inputs: [String] = []
    func record(_ input: String) { inputs.append(input) }
}
