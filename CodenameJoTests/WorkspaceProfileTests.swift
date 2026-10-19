import XCTest
import GRDB
@testable import CodenameJo

final class WorkspaceProfileTests: XCTestCase {
    @MainActor
    func testSpokenProfileNameSurvivesDictatedPunctuation() {
        XCTAssertEqual(WorkspaceProfileStore.spokenName("  Work.  "), "Work")
        XCTAssertEqual(WorkspaceProfileStore.spokenName("\u{201C}Work\u{201D}"), "Work")
        XCTAssertEqual(WorkspaceProfileStore.spokenName("Work?"), "Work")
        XCTAssertEqual(WorkspaceProfileStore.spokenName("Side Project"), "Side Project")
        XCTAssertEqual(WorkspaceProfileStore.spokenName("   "), "")
    }

    @MainActor
    func testProfileLookupIsCaseBlindAndRefusesAMiss() {
        let store = WorkspaceProfileStore()
        store.profiles = [
            WorkspaceProfile(id: "personal", name: "Personal", isDefault: true, createdAt: "2026-09-10 00:00:00+00"),
            WorkspaceProfile(id: "work", name: "Work", isDefault: false, createdAt: "2026-09-11 00:00:00+00"),
        ]
        XCTAssertEqual(store.profile(named: "work")?.id, "work")
        XCTAssertEqual(store.profile(named: "\"Work.\"")?.id, "work")
        XCTAssertNil(store.profile(named: "Investments"))
    }

    @MainActor
    func testProfileWriteFailuresAreSpokenNotSheetCopy() {
        // The switch is over an `Error` existential: if the case patterns did not match,
        // every failure would collapse to the generic sentence and "name taken" — the one
        // the user actually hits — would never be said.
        let taken = FullDuplexVoiceClient.profileFailure(WorkspaceProfileError.nameTaken, name: "Work")
        XCTAssertTrue(taken.contains("already a profile called Work"))
        XCTAssertTrue(FullDuplexVoiceClient.profileFailure(WorkspaceProfileError.invalidName, name: "Work")
            .contains("ordinary words"))
        XCTAssertTrue(FullDuplexVoiceClient.profileFailure(BackendError.notSignedIn, name: "Work")
            .contains("session expired"))
        XCTAssertTrue(FullDuplexVoiceClient.profileFailure(URLError(.timedOut), name: "Work")
            .contains("did not go through"))
        // None of the sheet's own wording reaches the ear.
        for error in [WorkspaceProfileError.nameTaken, .invalidName, .notFound, .unavailable] {
            XCTAssertFalse(FullDuplexVoiceClient.profileFailure(error, name: "Work")
                .contains("control characters"))
        }
    }

    func testProfileScopeFiltersDeviceMailAccounts() {
        defer { ProfileRuntime.install(nil) }
        let grants = ["work@example.com", "Personal@Example.com", "other@example.com"]
        // Connections not fetched yet: nil emails filters nothing.
        ProfileRuntime.install(.init(profileId: "work", isDefault: false))
        XCTAssertEqual(ProfileRuntime.allowedMailAccounts(grants), grants)
        // A fetched profile narrows the device's grants to its own inboxes, case-blind.
        ProfileRuntime.install(.init(profileId: "work", isDefault: false, emails: ["work@example.com", "personal@example.com"]))
        XCTAssertEqual(ProfileRuntime.allowedMailAccounts(grants), ["work@example.com", "Personal@Example.com"])
        // An empty profile filters everything.
        ProfileRuntime.install(.init(profileId: "empty", isDefault: false, emails: []))
        XCTAssertEqual(ProfileRuntime.allowedMailAccounts(grants), [])
        // No profile scope at all — an older broker — filters nothing.
        ProfileRuntime.install(nil)
        XCTAssertEqual(ProfileRuntime.allowedMailAccounts(grants), grants)
    }

    func testSwitchingSettingsClearsWorkspaceValuesAndKeepsAccountOnes() throws {
        var outgoing = UserProfile()
        outgoing.appearance = "dark"
        outgoing.archiveAfterReply = true
        outgoing.draftsOnlySafeguardByAccount = ["personal@example.test": true]
        let incoming = try outgoing.replacingWorkspaceSettings(with: UserProfile())
        XCTAssertEqual(incoming.appearance, "dark")
        // A filing rule answers for the account, so a switch must not clear it (#798).
        XCTAssertEqual(incoming.archiveAfterReply, true)
        XCTAssertNil(incoming.draftsOnlySafeguardByAccount)
    }

    func testPreparationCombinesAccountSettingsWithDestinationOverrides() throws {
        var account = UserProfile()
        account.threadQueue = true
        account.mailHeadersOnly = true
        account.agentLedEmailSessions = false
        var work = UserProfile()
        work.triageScope = "all"
        let effective = try account.replacingWorkspaceSettings(with: work)
        XCTAssertEqual(effective.threadQueue, true)
        XCTAssertEqual(effective.mailHeadersOnly, true)
        XCTAssertEqual(effective.agentLedEmailSessions, false)
        XCTAssertEqual(effective.triageScope, "all")
    }

    func testSettlingDispatchPreservesOriginalProfile() throws {
        let json = #"{"id":"12345678-1234-1234-1234-123456789012","task":"look up","state":"done","profile_id":"work"}"#
        var job = try JSONDecoder().decode(DispatchJob.self, from: Data(json.utf8))
        job.deliveredAt = Date()
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
        XCTAssertEqual(saved["profile_id"] as? String, "work")
    }

    func testSignOutPurgesEveryProfileWithoutPurgingAnotherAccount() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let context = LocalContextStore(url: path)
        guard let db = await context.dbPool else { XCTFail("Database unavailable"); return }
        defer { try? db.close(); try? FileManager.default.removeItem(at: path) }
        let owners = ["owner_%", "owner_%:profile:work", "owner_%:profile:personal", "ownerXX", "other:profile:work"]
        for owner in owners {
            _ = await context.save(request: "note", result: "private note", summary: "", kind: "note",
                conversationId: UUID().uuidString, userId: owner)
            try await db.write { database in
                try database.execute(sql: "INSERT INTO turn_row(id,user_id,command_text,response_text,issued_at,mirrored_at) VALUES(?,?,?,?,?,?)",
                    arguments: [UUID().uuidString, owner, "question", "answer", Date(), Date()])
            }
        }
        await context.purge(userId: "owner_%")
        await TurnStore(database: db).purge(userId: "owner_%")
        let retained = try await db.read { database in
            [try String.fetchAll(database, sql: "SELECT user_id FROM context_rows ORDER BY user_id"),
             try String.fetchAll(database, sql: "SELECT user_id FROM turn_row ORDER BY user_id")]
        }
        XCTAssertEqual(retained, [["other:profile:work", "ownerXX"], ["other:profile:work", "ownerXX"]])
    }

    func testDeferredMemoRetainsOriginAfterProfileSwitch() throws {
        defer { ProfileRuntime.install(nil) }
        let memo = QueuedMemo(id: UUID(), filename: "memo.m4a", transcript: "Check my email", state: .ready, profileId: "personal")
        let restored = try JSONDecoder().decode(QueuedMemo.self, from: JSONEncoder().encode(memo))
        ProfileRuntime.install(.init(profileId: "work", isDefault: false))
        let job = DispatchWorker.Job(id: restored.id, task: restored.transcript, profileId: restored.profileId)
        XCTAssertEqual(job.profileId, "personal")
    }
}
