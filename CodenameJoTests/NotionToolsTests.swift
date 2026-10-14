import FactoryKit
import XCTest
@testable import CodenameJo

final class NotionToolsTests: XCTestCase {
    private let pageId = "1f8d872b-594c-80a4-b2f4-00370af2b13f"

    override func setUp() {
        super.setUp()
        let storage = InMemoryRemoteMCPGrantStorage()
        Container.shared.remoteMCPGrantStorage.register { storage }
    }

    override func tearDown() {
        Container.shared.remoteMCPGrantStorage.reset()
        super.tearDown()
    }

    private func save(_ id: String, label: String = "Notion", profile: String? = "p1", needsReauth: Bool = false) {
        RemoteMCPGrantStore.save(RemoteMCPGrant(
            id: id, label: label, profileId: profile, accessToken: "tok-\(id)", refreshToken: "r",
            expiresAt: Date().addingTimeInterval(3600), needsReauth: needsReauth, clientId: "c",
            tokenEndpoint: "https://mcp.notion.com/token", resource: "https://mcp.notion.com/mcp", grantedAt: Date()),
            .notion)
    }

    /// Notion's MCP: answers each `tools/call` with the bearer it was called with.
    private func notion(isError: @escaping (String) -> Bool = { _ in false }) -> ScriptedMCPServer {
        ScriptedMCPServer { call in
            let id = call.json["id"] ?? NSNull()
            switch call.json["method"] as? String {
            case "initialize": return ScriptedMCPServer.sse(id: id, result: #"{"protocolVersion":"2025-06-18"}"#)
            case "notifications/initialized": return .init(status: 202, body: "")
            default:
                let bearer = (call.headers["Authorization"] ?? "").replacingOccurrences(of: "Bearer ", with: "")
                return ScriptedMCPServer.sse(id: id, result:
                    #"{"isError":\#(isError(bearer)),"content":[{"type":"text","text":"from \#(bearer)"}]}"#)
            }
        }
    }

    private func run(_ name: String, _ args: [String: Any], profile: String? = "p1",
                     server: ScriptedMCPServer) async -> FullDuplexBroker.ToolResult {
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        return await NotionTools.run(name: name, argumentsJSON: json, profileId: profile,
                                     credentials: RemoteMCPCredentials(transport: server))
    }

    // MARK: - Arguments

    func testIdsAreReadOutOfURLsAndDashed() {
        XCTAssertEqual(NotionTools.notionId("https://www.notion.so/team/Ideas-1f8d872b594c80a4b2f400370af2b13f"), pageId)
        XCTAssertEqual(NotionTools.notionId(pageId.uppercased()), pageId)
        XCTAssertNil(NotionTools.notionId("Ideas"))
        XCTAssertEqual(NotionTools.dataSourceURL(pageId), "collection://\(pageId)")
        XCTAssertEqual(NotionTools.dataSourceURL("collection://abc"), "collection://abc")
        XCTAssertNil(NotionTools.dataSourceURL("Recruiting"))
    }

    func testWritesAreWidenedIntoNotionsShapesAndNothingDestructive() {
        let create = NotionTools.vendorArguments("notion-create-pages",
            ["title": "Pricing", "content": "Try annual", "parent_page_id": pageId])
        XCTAssertEqual(create["parent"] as? [String: String], ["type": "page_id", "page_id": pageId])
        let page = (create["pages"] as? [[String: Any]])?.first
        XCTAssertEqual((page?["properties"] as? [String: String])?["title"], "Pricing")
        XCTAssertEqual(page?["content"] as? String, "Try annual")
        XCTAssertNil(create["allow_async"])

        let row = NotionTools.vendorArguments("notion-create-pages",
            ["title": "Task", "parent_database_id": "collection://\(pageId)"])
        XCTAssertEqual(row["parent"] as? [String: String], ["type": "data_source_id", "data_source_id": pageId])

        let update = NotionTools.vendorArguments("notion-update-page",
            ["page_id": pageId, "command": "insert_content", "content": "- done", "position": "start"])
        XCTAssertEqual(update["position"] as? [String: String], ["type": "start"])
        XCTAssertNil(update["allow_deleting_content"])

        let query = NotionTools.vendorArguments("notion-query-data-sources",
            ["data_source_url": pageId, "query": "SELECT 1"])
        XCTAssertEqual((query["data"] as? [String: Any])?["data_source_urls"] as? [String], ["collection://\(pageId)"])
        XCTAssertEqual((query["data"] as? [String: Any])?["mode"] as? String, "sql")
        XCTAssertEqual(NotionTools.vendorArguments("notion-fetch", ["id": "collection://\(pageId)"])["id"] as? String,
                       "collection://\(pageId)")
    }

    func testRefusalsNeedNoRoundTrip() {
        XCTAssertNotNil(NotionTools.refuse("notion-search", ["query": " "]))
        XCTAssertNotNil(NotionTools.refuse("notion-search", ["query": "x", "page_size": 26]))
        XCTAssertNotNil(NotionTools.refuse("notion-update-page", ["page_id": pageId, "command": "replace_content"]))
        XCTAssertNotNil(NotionTools.refuse("notion-update-page", ["page_id": pageId, "command": "update_properties"]))
        XCTAssertNotNil(NotionTools.refuse("notion-create-pages", ["title": "T", "parent_page_id": "Ideas"]))
        XCTAssertNotNil(NotionTools.refuse("notion-create-pages", ["title": "T", "parent_page_id": pageId,
                                                                   "parent_database_id": pageId]))
        XCTAssertNotNil(NotionTools.refuse("notion-query-data-sources", ["query": "SELECT 1"]))
        XCTAssertNil(NotionTools.refuse("notion-update-page", ["page_id": pageId, "command": "update_properties",
                                                              "properties": ["Status": "Done"]]))
        XCTAssertNil(NotionTools.refuse("notion-list-recent-pages", [:]))
    }

    func testEveryToolHasABundledSchema() throws {
        let catalog = LiveSessionSetup.Catalog.bundled
        for name in NotionTools.names {
            XCTAssertEqual(catalog.tool(name)["name"] as? String, name)
        }
        let update = catalog.tool("notion-update-page")
        let command = ((update["parameters"] as? [String: Any])?["properties"] as? [String: Any])?["command"] as? [String: Any]
        XCTAssertEqual(command?["enum"] as? [String], NotionTools.updateCommands)
    }

    // MARK: - Running

    func testAToolRunsOnTheProfilesOwnGrant() async {
        save("mine", profile: "p1")
        save("theirs", profile: "p2")
        let server = notion()
        let result = await run("notion-fetch", ["id": pageId], server: server)
        XCTAssertEqual(result.text, "from tok-mine")
        XCTAssertEqual(result.ok, true)
        let call = server.calls.first { $0.json["method"] as? String == "tools/call" }
        let params = call?.json["params"] as? [String: Any]
        XCTAssertEqual(params?["name"] as? String, "notion-fetch")
        XCTAssertEqual((params?["arguments"] as? [String: Any])?["id"] as? String, pageId)
    }

    func testNoGrantAsksForAConnection() async {
        let result = await run("notion-search", ["query": "x"], server: notion())
        XCTAssertEqual(result.ok, false)
        XCTAssertTrue(result.text.contains("connect Notion in Settings"))
    }

    func testABrokenGrantAsksForAReconnect() async {
        save("mine", needsReauth: true)
        let result = await run("notion-search", ["query": "x"], server: notion())
        XCTAssertEqual(result.ok, false)
        XCTAssertTrue(result.text.contains("reconnect"))
        XCTAssertEqual(NotionTools.needsReauth(profileId: "p1"), ["Notion"])
        XCTAssertFalse(NotionTools.isConnected(profileId: "p1"))
    }

    func testAWorkspaceQuestionFansOutTaggedByWorkspace() async throws {
        save("a", label: "Work")
        save("b", label: "Home")
        let result = await run("notion-search", ["query": "pricing"], server: notion())
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [[String: String]])
        XCTAssertEqual(Set(rows.compactMap { $0["workspace"] }), ["Work", "Home"])
    }

    func testAnIdIsTriedInEachWorkspaceUntilOneAnswers() async {
        save("a", label: "Work")
        save("b", label: "Home")
        let result = await run("notion-update-page",
            ["page_id": pageId, "command": "update_properties", "properties": ["Status": "Done"]],
            server: notion(isError: { $0 == "tok-a" }))
        XCTAssertEqual(result.text, "from tok-b")
        XCTAssertEqual(result.ok, true)
        XCTAssertEqual(result.performedTool, "notion-update-page")
    }

    func testARefusedBearerIsExplainedAndFlagsTheGrant() async {
        save("mine")
        let server = ScriptedMCPServer { call in
            call.url.path == "/token" ? .init(status: 400, body: #"{"error":"invalid_grant"}"#) : .init(status: 401, body: "")
        }
        let result = await run("notion-search", ["query": "x"], server: server)
        XCTAssertEqual(result.ok, false)
        XCTAssertTrue(result.text.contains("reconnect Notion"))
        XCTAssertEqual(RemoteMCPGrantStore.grant(.notion, id: "mine")?.needsReauth, true)
    }
}
