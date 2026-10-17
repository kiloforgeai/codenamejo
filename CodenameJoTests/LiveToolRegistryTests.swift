import XCTest
@testable import CodenameJo

/// The session's tool list and `runFunctionTool`'s routing are one table, so they cannot drift apart.
final class LiveToolRegistryTests: XCTestCase {
    private let catalog = LiveSessionSetup.Catalog.bundled
    private let registry = LiveSessionSetup.tools
    /// Still answered for an old name, and declared by nothing.
    private let undeclared: Set<String> = ["search_unread"]

    private func names(_ tools: [[String: Any]]) -> Set<String> { Set(tools.compactMap { $0["name"] as? String }) }

    func testEveryToolIsFiledUnderTheNameItsSchemaGives() {
        for (key, tool) in registry {
            XCTAssertEqual(tool.name, key)
            if let schema = tool.schema(.init()) { XCTAssertEqual(schema["name"] as? String, key) }
        }
        // A variant is a second wording of a registered tool, never a tool of its own.
        for key in catalog.tools.keys {
            let base = String(key.prefix { $0 != "." })
            XCTAssertEqual(catalog.tool(key)["name"] as? String, base, key)
        }
    }

    func testEveryDeclaredToolHasAnEntryAndEveryEntryIsDeclared() {
        let declared = Set(catalog.tools.keys.map { String($0.prefix { $0 != "." }) })
        let withSchemas = Set(registry.filter { $0.value.schema(.init()) != nil }.keys)
        XCTAssertEqual(declared, withSchemas)
        XCTAssertEqual(Set(registry.keys).subtracting(withSchemas), undeclared)
    }

    func testEverythingASessionOrJobIsGivenIsRoutedOnce() {
        var state = LiveSessionSetup.State(inboxes: ["a@x.test"], calendars: ["a@x.test"])
        state.githubAccounts = ["octo"]
        state.granola = true
        state.slackWorkspaces = ["T1"]
        state.notion = true
        var offered = Set<String>()
        for opening in [SessionOpening.emailQueue, .none] {
            var request = LiveSessionSetup.Request(opening: opening, dispatch: true, shortcutText: true, shortcutRead: true)
            request.cachedMailboxes = ["a@x.test"]
            request.sequentialFeed = opening == .emailQueue
            let tools = LiveSessionSetup.resolve(request, state, catalog: catalog).tools
            offered.formUnion(names(LiveSessionSetup.addingCommands(to: tools, keywords: ["standup"], dispatch: true,
                                                                    catalog: catalog)))
        }
        offered.formUnion(names(LiveSessionSetup.workerTools(inboxes: ["a@x.test"], calendars: ["a@x.test"],
                                                             draftsOnly: { _ in false }, notion: true, catalog: catalog)))
        XCTAssertEqual(offered.subtracting(registry.keys), [])
        XCTAssertEqual(Set(registry.keys).subtracting(offered).subtracting(undeclared), [],
                       "registered but never offered")

        // The phone's own Gmail and Calendar tools are routed before the registry, so none may be in it.
        let device = GmailReadTools.names.union(GmailManageTools.names).union(CalendarTools.names)
            .union([EmailLinkTool.name])
        XCTAssertTrue(device.isDisjoint(with: registry.keys))
    }

    func testAccountScopedSchemasNameTheSessionsAccounts() throws {
        let tool = catalog.tool("send_email", .init(inboxes: ["a@x.test", "b@x.test"]))
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: tool), encoding: .utf8))
        XCTAssertTrue(json.contains("a@x.test, b@x.test"))
        XCTAssertFalse(json.contains("{{accounts}}"))
    }
}
