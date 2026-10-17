import FactoryKit
import XCTest
@testable import CodenameJo

/// Saved commands in `context.sqlite`, through the store the Settings toggle and the voice tool share.
final class CustomCommandStoreTests: XCTestCase {
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

    private var rows: CustomCommandRows { CustomCommandRows(dbPool: context.dbPool) }
    private let steps = [CommandAction(tool: "web_search", detail: "the company")]

    func testAResaveReplacesTheStepsAndKeepsIdAndSwitch() async throws {
        let first = try await rows.save(userId: "alice", profileId: "", keyword: "research", spoken: "Research",
                                        label: "Research a company", actions: steps)
        _ = try await rows.setEnabled(userId: "alice", profileId: "", keyword: "research", enabled: false)
        let again = try await rows.save(userId: "alice", profileId: "", keyword: "research", spoken: "research",
                                        label: "", actions: [CommandAction(tool: "summarize", detail: "")])
        XCTAssertEqual(again.id, first.id)
        XCTAssertFalse(again.enabled, "a command switched off stays off")
        XCTAssertEqual(again.actions, [CommandAction(tool: "summarize", detail: "")])
        XCTAssertEqual(again.instruction, "")
        let all = try await rows.all(userId: "alice", profileId: "")
        XCTAssertEqual(all.count, 1)
    }

    func testCommandsAreScopedToTheUserAndProfile() async throws {
        _ = try await rows.save(userId: "alice", profileId: "", keyword: "research", spoken: "", label: "", actions: steps)
        _ = try await rows.save(userId: "alice", profileId: "work", keyword: "research", spoken: "", label: "", actions: steps)
        _ = try await rows.save(userId: "bob", profileId: "", keyword: "standup", spoken: "", label: "", actions: steps)
        var aliceDefault = try await rows.all(userId: "alice", profileId: "")
        XCTAssertEqual(aliceDefault.map(\.keyword), ["research"])
        var aliceWork = try await rows.all(userId: "alice", profileId: "work")
        XCTAssertEqual(aliceWork.count, 1)
        let notBobs = try await rows.delete(userId: "alice", profileId: "", keyword: "standup")
        XCTAssertNil(notBobs, "bob's is not alice's")

        try await rows.purge(userId: "alice", profileId: "work")
        aliceWork = try await rows.all(userId: "alice", profileId: "work")
        XCTAssertTrue(aliceWork.isEmpty)
        aliceDefault = try await rows.all(userId: "alice", profileId: "")
        XCTAssertEqual(aliceDefault.count, 1)
        try await rows.purge(userId: "alice")
        aliceDefault = try await rows.all(userId: "alice", profileId: "")
        XCTAssertTrue(aliceDefault.isEmpty)
        let bob = try await rows.all(userId: "bob", profileId: "")
        XCTAssertEqual(bob.count, 1)
    }

    @MainActor
    func testTheStoreRefusesByNameAndListsOnlyWhatIsOn() async throws {
        let container = Container.shared
        let scope = ProfileRuntime.snapshot
        container.manager.push()
        defer {
            Scope.singleton.reset()
            container.manager.pop()
            ProfileRuntime.install(scope)
        }
        ProfileRuntime.install(nil)
        let backend = BackendService(restoringSession: false)
        backend.userId = "alice"
        let database = context.dbPool
        container.backend.register { backend }
        container.customCommandRows.register { CustomCommandRows(dbPool: database) }
        let store = CustomCommandStore()

        guard case .saved(let saved) = await store.save(keyword: " Candidate  Screen ", label: "Screen a candidate",
                                                        actions: steps) else { return XCTFail("not saved") }
        XCTAssertEqual(saved?.keyword, "candidate screen")
        XCTAssertEqual(saved?.spoken, "Candidate  Screen")
        XCTAssertEqual(store.commands.map(\.keyword), ["candidate screen"])

        guard case .refused(let why) = await store.save(keyword: "hang up", label: "", actions: steps) else {
            return XCTFail("a reserved keyword saved")
        }
        XCTAssertTrue(why.contains("already how the user asks"))

        guard case .refused(let missing) = await store.delete(keyword: "candidate") else { return XCTFail("fuzzy delete") }
        XCTAssertTrue(missing.hasPrefix("There is no command called \"candidate\""))

        guard case .saved = await store.setEnabled(keyword: "CANDIDATE screen", to: false) else { return XCTFail("not switched") }
        XCTAssertEqual(store.commands.first?.enabled, false)
        XCTAssertTrue(store.enabledCommands.isEmpty)

        guard case .saved = await store.delete(keyword: "candidate screen") else { return XCTFail("not deleted") }
        XCTAssertTrue(store.commands.isEmpty)
    }
}
