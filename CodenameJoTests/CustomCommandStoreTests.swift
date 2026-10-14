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

    func testAResaveReplacesTheStepsAndKeepsIdAndSwitch() throws {
        let first = try rows.save(userId: "alice", profileId: "", keyword: "research", spoken: "Research",
                                  label: "Research a company", actions: steps)
        _ = try rows.setEnabled(userId: "alice", profileId: "", keyword: "research", enabled: false)
        let again = try rows.save(userId: "alice", profileId: "", keyword: "research", spoken: "research",
                                  label: "", actions: [CommandAction(tool: "summarize", detail: "")])
        XCTAssertEqual(again.id, first.id)
        XCTAssertFalse(again.enabled, "a command switched off stays off")
        XCTAssertEqual(again.actions, [CommandAction(tool: "summarize", detail: "")])
        XCTAssertEqual(again.instruction, "")
        XCTAssertEqual(try rows.all(userId: "alice", profileId: "").count, 1)
    }

    func testCommandsAreScopedToTheUserAndProfile() throws {
        _ = try rows.save(userId: "alice", profileId: "", keyword: "research", spoken: "", label: "", actions: steps)
        _ = try rows.save(userId: "alice", profileId: "work", keyword: "research", spoken: "", label: "", actions: steps)
        _ = try rows.save(userId: "bob", profileId: "", keyword: "standup", spoken: "", label: "", actions: steps)
        XCTAssertEqual(try rows.all(userId: "alice", profileId: "").map(\.keyword), ["research"])
        XCTAssertEqual(try rows.all(userId: "alice", profileId: "work").count, 1)
        XCTAssertNil(try rows.delete(userId: "alice", profileId: "", keyword: "standup"), "bob's is not alice's")

        try rows.purge(userId: "alice", profileId: "work")
        XCTAssertTrue(try rows.all(userId: "alice", profileId: "work").isEmpty)
        XCTAssertEqual(try rows.all(userId: "alice", profileId: "").count, 1)
        try rows.purge(userId: "alice")
        XCTAssertTrue(try rows.all(userId: "alice", profileId: "").isEmpty)
        XCTAssertEqual(try rows.all(userId: "bob", profileId: "").count, 1)
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

        guard case .saved(let saved) = store.save(keyword: " Candidate  Screen ", label: "Screen a candidate",
                                                  actions: steps) else { return XCTFail("not saved") }
        XCTAssertEqual(saved?.keyword, "candidate screen")
        XCTAssertEqual(saved?.spoken, "Candidate  Screen")
        XCTAssertEqual(store.commands.map(\.keyword), ["candidate screen"])

        guard case .refused(let why) = store.save(keyword: "hang up", label: "", actions: steps) else {
            return XCTFail("a reserved keyword saved")
        }
        XCTAssertTrue(why.contains("already how the user asks"))

        guard case .refused(let missing) = store.delete(keyword: "candidate") else { return XCTFail("fuzzy delete") }
        XCTAssertTrue(missing.hasPrefix("There is no command called \"candidate\""))

        guard case .saved = store.setEnabled(keyword: "CANDIDATE screen", to: false) else { return XCTFail("not switched") }
        XCTAssertEqual(store.commands.first?.enabled, false)
        XCTAssertTrue(store.enabledCommands.isEmpty)

        guard case .saved = store.delete(keyword: "candidate screen") else { return XCTFail("not deleted") }
        XCTAssertTrue(store.commands.isEmpty)
    }
}
