import FactoryKit
import GRDB
import XCTest
@testable import CodenameJo

@MainActor
final class WorkspaceProfileRefreshTests: XCTestCase {
    private final class Store: WorkspaceProfileStore {
        var holdNextRead = false
        var pendingRead: CheckedContinuation<[WorkspaceProfileConnection], Never>?

        override func connections(of profileId: String) async throws -> [WorkspaceProfileConnection] {
            if holdNextRead {
                holdNextRead = false
                return await withCheckedContinuation { pendingRead = $0 }
            }
            return [.init(id: profileId, email: profileId + "@example.test", profileId: profileId, needsReauth: false)]
        }

        override func prepareProfileOpenings(store: MailStore, restart: Bool = false) {}
    }

    func testStaleRefreshCannotReplaceTheNewProfilesMailboxFilter() async throws {
        try await withStore { store, _ in
            let personal = try XCTUnwrap(store.selected)
            store.holdNextRead = true
            let refresh = Task { await store.refreshConnections() }
            while store.pendingRead == nil { await Task.yield() }
            let work = try XCTUnwrap(store.profiles.first { !$0.isDefault })
            store.selected = work
            await store.refreshConnections()
            let expected = ProfileRuntime.snapshot?.emails
            XCTAssertEqual(expected, [work.id + "@example.test"])
            store.pendingRead?.resume(returning: [.init(id: personal.id, email: "personal@example.test",
                                                       profileId: personal.id, needsReauth: false)])
            await refresh.value
            XCTAssertEqual(store.connections.map(\.email), expected)
            XCTAssertEqual(ProfileRuntime.snapshot?.profileId, work.id)
            XCTAssertEqual(ProfileRuntime.snapshot?.emails, expected)
        }
    }

    func testRefreshCannotPublishAfterSignOut() async throws {
        try await withStore { store, backend in
            store.holdNextRead = true
            let refresh = Task { await store.refreshConnections() }
            while store.pendingRead == nil { await Task.yield() }
            backend.userId = nil
            store.resetForSignOut()
            store.pendingRead?.resume(returning: [.init(id: "old", email: "old@example.test",
                                                       profileId: "old", needsReauth: false)])
            await refresh.value
            XCTAssertTrue(store.connections.isEmpty)
            XCTAssertNil(ProfileRuntime.snapshot)
        }
    }

    private func withStore(_ run: (Store, BackendService) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try DatabasePool(path: url.path)
        try await database.write { try WorkspaceProfileRows.createSchema($0) }
        let container = Container.shared
        let scope = ProfileRuntime.snapshot
        container.manager.push()
        defer {
            Scope.singleton.reset()
            container.manager.pop()
            ProfileRuntime.install(scope)
            try? database.close()
            try? FileManager.default.removeItem(at: url)
        }
        let backend = BackendService(restoringSession: false)
        backend.userId = "refresh-test"
        let rows = WorkspaceProfileRows(dbPool: database)
        _ = try await rows.list(userId: "refresh-test")
        _ = try await rows.create(userId: "refresh-test", name: "Work")
        container.backend.register { backend }
        container.workspaceProfileRows.register { rows }
        let store = Store()
        container.workspaceProfiles.register { store }
        try await store.load()
        try await run(store, backend)
    }
}
