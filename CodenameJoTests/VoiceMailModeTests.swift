import FactoryKit
import XCTest
@testable import CodenameJo

@MainActor
final class VoiceMailModeTests: XCTestCase {
    private func withStore(_ run: (UserProfileStore, BackendService) async throws -> Void) async rethrows {
        let container = Container.shared
        let domain = Bundle.main.bundleIdentifier!
        let defaults = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        let scope = ProfileRuntime.snapshot
        container.manager.push()
        let backend = BackendService(restoringSession: false)
        backend.userId = "voice-mode-test"
        backend.isSignedIn = true
        container.backend.register { backend }
        container.workspaceProfiles.register { WorkspaceProfileStore() }
        container.connections.register { ConnectionsService() }
        container.connections().gmailAccounts = ["work@example.test", "team@example.test", "personal@example.test"]
        ProfileRuntime.install(.init(profileId: "work", isDefault: true, emails: ["work@example.test", "team@example.test"]))
        UserDefaults.standard.removeObject(forKey: "userProfileHasUnsavedChanges")
        DraftsOnly.replace(with: ["work@example.test": true, "team@example.test": true, "personal@example.test": true])
        defer {
            Scope.singleton.reset()
            container.manager.pop()
            ProfileRuntime.install(scope)
            UserDefaults.standard.setPersistentDomain(defaults, forName: domain)
        }
        try await run(UserProfileStore(), backend)
    }

    func testSwitchingBothWaysPersistsOnlyTheNamedInbox() async throws {
        try await withStore { store, _ in
            let send = await store.setMailMode(mode: "send", account: "work@example.test")
            XCTAssertTrue(send.saved)
            XCTAssertFalse(DraftsOnly.isOn(for: "work@example.test"))
            XCTAssertTrue(DraftsOnly.isOn(for: "team@example.test"))
            XCTAssertTrue(DraftsOnly.isOn(for: "personal@example.test"))
            XCTAssertFalse(UserDefaults.standard.bool(forKey: "userProfileHasUnsavedChanges"))
            let draft = await store.setMailMode(mode: "drafts", account: "work@example.test")
            XCTAssertTrue(draft.saved)
            XCTAssertTrue(DraftsOnly.isOn(for: "work@example.test"))
            XCTAssertTrue(DraftsOnly.isOn(for: "team@example.test"))
            XCTAssertTrue(DraftsOnly.isOn(for: "personal@example.test"))
        }
    }

    func testMultipleInboxesRequireAChoiceBeforeAnyWrite() async {
        await withStore { store, _ in
            _ = await store.flush()
            for account: String? in [nil, "", "personal@example.test", "unknown@example.test"] {
                let result = await store.setMailMode(mode: "send", account: account)
                XCTAssertFalse(result.saved)
                XCTAssertTrue(result.output.contains("work@example.test"))
                XCTAssertTrue(DraftsOnly.isOn(for: "work@example.test"))
                XCTAssertTrue(DraftsOnly.isOn(for: "team@example.test"))
            }
            let chosen = await store.setMailMode(mode: "send", account: " WORK@EXAMPLE.TEST ")
            XCTAssertTrue(chosen.saved)
            XCTAssertFalse(DraftsOnly.isOn(for: "work@example.test"))
            XCTAssertTrue(DraftsOnly.isOn(for: "team@example.test"))
        }
    }

    func testSingleInboxNeedsNoAccountArgument() async {
        await withStore { store, _ in
            ProfileRuntime.install(.init(profileId: "personal", isDefault: false, emails: ["personal@example.test"]))
            let result = await store.setMailMode(mode: "send")
            XCTAssertTrue(result.saved)
            XCTAssertFalse(DraftsOnly.isOn(for: "personal@example.test"))
            XCTAssertTrue(DraftsOnly.isOn(for: "work@example.test"))
        }
    }

    func testUnknownModeOrUnresolvedProfileCannotChangePolicy() async {
        await withStore { store, _ in
            let invalid = await store.setMailMode(mode: "yes")
            XCTAssertFalse(invalid.saved)
            for emails: [String]? in [nil, []] {
                ProfileRuntime.install(.init(profileId: "work", isDefault: true, emails: emails))
                let result = await store.setMailMode(mode: "send", account: "work@example.test")
                XCTAssertFalse(result.saved)
                XCTAssertTrue(DraftsOnly.isOn(for: "work@example.test"))
                XCTAssertTrue(DraftsOnly.isOn(for: "personal@example.test"))
            }
        }
    }

    func testModeChangeFollowsTheSelectedProfile() async {
        await withStore { store, _ in
            _ = await store.setMailMode(mode: "send", account: "work@example.test")
            ProfileRuntime.install(.init(profileId: "personal", isDefault: false, emails: ["personal@example.test"]))
            let changed = await store.setMailMode(mode: "drafts")
            XCTAssertTrue(changed.saved)
            XCTAssertFalse(DraftsOnly.isOn(for: "work@example.test"))
            XCTAssertTrue(DraftsOnly.isOn(for: "team@example.test"))
            XCTAssertTrue(DraftsOnly.isOn(for: "personal@example.test"))
        }
    }
}
