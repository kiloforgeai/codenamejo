import FactoryKit
import XCTest
@testable import CodenameJo

/// Adding, refreshing and removing a server against a scripted MCP endpoint, with the Keychain
/// and the server records swapped for memory.
final class CustomMCPConnectorTests: XCTestCase {
    private let endpoint = URL(string: "https://mcp.example.test/mcp")!
    private var grants: InMemoryRemoteMCPGrantStorage!
    private var records: InMemoryCustomMCPServerStorage!

    override func setUp() {
        super.setUp()
        grants = InMemoryRemoteMCPGrantStorage()
        records = InMemoryCustomMCPServerStorage()
        Container.shared.remoteMCPGrantStorage.register { [grants] in grants! }
        Container.shared.customMCPServerStorage.register { [records] in records! }
    }

    override func tearDown() {
        Container.shared.remoteMCPGrantStorage.reset()
        Container.shared.customMCPServerStorage.reset()
        super.tearDown()
    }

    /// Initialize, then `tools/list` answering `tools` unless `listStatus` says otherwise.
    private func server(tools: String = #"[{"name":"file_issue","description":"File an issue","inputSchema":{"type":"object","properties":{"title":{"type":"string"}}}}]"#,
                        listStatus: Int = 200) -> ScriptedMCPServer {
        ScriptedMCPServer { call in
            let method = call.json["method"] as? String ?? ""
            let id = call.json["id"] ?? NSNull()
            switch method {
            case "initialize":
                return ScriptedMCPServer.sse(id: id, result: #"{"protocolVersion":"2025-06-18","capabilities":{}}"#)
            case "notifications/initialized":
                return .init(status: 202, body: "")
            case "tools/list":
                if listStatus != 200 { return .init(status: listStatus, body: "") }
                return .init(body: #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":\#(tools)}}"#)
            default:
                return .init(status: 404, body: "")
            }
        }
    }

    @MainActor
    private func add(_ transport: ScriptedMCPServer, auth: CustomMCPServer.Auth = .bearer, token: String = "secret")
        async -> Result<CustomMCPServer, CustomMCPConnector.Failure> {
        await CustomMCPConnector.add(name: "MVP", endpoint: endpoint, auth: auth, token: token, profileId: "p1",
                                     ownerId: "u1", transport: transport, credentials: RemoteMCPCredentials(transport: transport))
    }

    func testEndpointsAreHttpsWithAHost() {
        XCTAssertEqual(CustomMCPConnector.endpoint(from: " mcp.example.test/mcp ")?.absoluteString, "https://mcp.example.test/mcp")
        XCTAssertEqual(CustomMCPConnector.endpoint(from: "https://mcp.example.test:8443/mcp")?.port, 8443)
        XCTAssertNil(CustomMCPConnector.endpoint(from: "http://mcp.example.test/mcp"))
        XCTAssertNil(CustomMCPConnector.endpoint(from: "https://"))
        XCTAssertNil(CustomMCPConnector.endpoint(from: ""))
    }

    @MainActor
    func testAddingABearerServerStoresTheTokenAndTheListedTools() async throws {
        let transport = server()
        let added = try await add(transport).get()
        XCTAssertEqual(added.tools.map(\.name), ["file_issue"])
        XCTAssertEqual(added.tools[0].description, "File an issue")
        XCTAssertNotNil(added.toolsListedAt)
        XCTAssertEqual(CustomMCPServerStore.servers(profileId: "p1").map(\.id), [added.id])
        XCTAssertEqual(CustomMCPServerStore.servers(profileId: "p2"), [])

        let grant = try XCTUnwrap(CustomMCPConnector.grant(added))
        XCTAssertEqual(grant.accessToken, "secret")
        XCTAssertNil(grant.refreshToken)
        XCTAssertEqual(grant.expiresAt, .distantFuture)
        XCTAssertTrue(CustomMCPConnector.isUsable(added))
        XCTAssertEqual(transport.calls.first?.headers["Authorization"], "Bearer secret")
        XCTAssertEqual(transport.calls.map { $0.json["method"] as? String }, ["initialize", "notifications/initialized", "tools/list"])

        let status = CustomMCPConnector.status(added)
        XCTAssertEqual(status.subtitle, "1 tool · mcp.example.test")
        XCTAssertEqual(status.capabilities.map(\.label), ["File issue"])
    }

    @MainActor
    func testAServerWithNoCredentialGetsNoAuthorizationHeader() async throws {
        let transport = server()
        let added = try await add(transport, auth: .none, token: "").get()
        XCTAssertTrue(CustomMCPConnector.isUsable(added))
        XCTAssertNil(transport.calls.first?.headers["Authorization"])
    }

    @MainActor
    func testABearerServerNeedsATokenAndANameBeforeAnythingIsCalled() async {
        let transport = server()
        guard case .failure(.failed(let message)) = await add(transport, token: "  ") else { return XCTFail("added") }
        XCTAssertEqual(message, "Paste the server's token.")
        let unnamed = await CustomMCPConnector.add(name: " ", endpoint: endpoint, auth: .none, token: "", profileId: "p1",
                                                  ownerId: "u1", transport: transport, credentials: RemoteMCPCredentials(transport: transport))
        guard case .failure(.failed(let reason)) = unnamed else { return XCTFail("added") }
        XCTAssertEqual(reason, "Give the server a name.")
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertTrue(CustomMCPServerStore.all().isEmpty)
    }

    @MainActor
    func testAServerThatRefusesTheFirstListingIsNotKept() async {
        let transport = server(listStatus: 401)
        guard case .failure(.failed(let message)) = await add(transport) else { return XCTFail("added") }
        XCTAssertTrue(message.contains("MVP rejected the connection"))
        XCTAssertTrue(CustomMCPServerStore.all().isEmpty)
        XCTAssertTrue(grants.grants(for: "custom-" + (CustomMCPServerStore.all().first?.id ?? "")).isEmpty)
        XCTAssertTrue(transport.calls.allSatisfy { $0.headers["Authorization"] == "Bearer secret" })
    }

    @MainActor
    func testRefreshingKeepsTheNewListAndReconnectingReplacesTheToken() async throws {
        let added = try await add(server()).get()
        let credentials = RemoteMCPCredentials(transport: server(tools: #"[{"name":"ping"},{"name":"file_issue"}]"#))
        let refreshed = try await CustomMCPConnector.refreshTools(added, credentials: credentials).get()
        XCTAssertEqual(refreshed.tools.map(\.name), ["ping", "file_issue"])
        XCTAssertEqual(CustomMCPServerStore.server(id: added.id)?.tools.map(\.name), ["ping", "file_issue"])

        let transport = server()
        let reconnected = try await CustomMCPConnector.reconnect(refreshed, token: "fresh", transport: transport,
                                                                 credentials: RemoteMCPCredentials(transport: transport)).get()
        XCTAssertEqual(grants.grants(for: added.service.id).map(\.accessToken), ["fresh"])
        XCTAssertEqual(reconnected.tools.map(\.name), ["file_issue"])
    }

    @MainActor
    func testARefusedRefreshFlagsTheServerAndRunRefusesIt() async throws {
        let added = try await add(server()).get()
        let refused = await CustomMCPConnector.refreshTools(added, credentials: RemoteMCPCredentials(transport: server(listStatus: 403)))
        guard case .failure(.failed(let message)) = refused else { return XCTFail("refreshed") }
        XCTAssertTrue(message.contains("rejected"))
        XCTAssertFalse(CustomMCPConnector.isUsable(added))
        XCTAssertEqual(CustomMCPConnector.status(added).subtitle, "Needs reconnecting")
        XCTAssertTrue(CustomMCPTools.definitions(servers: [added]).isEmpty)
        let result = await CustomMCPTools.run(name: "mcp_mvp_file_issue", argumentsJSON: "{}", servers: [added])
        XCTAssertEqual(result.ok, false)
    }

    @MainActor
    func testRemovingAndForgettingDropTheRecordAndTheGrant() async throws {
        let first = try await add(server()).get()
        let second = try await add(server()).get()
        await CustomMCPConnector.remove(first)
        XCTAssertEqual(CustomMCPServerStore.all().map(\.id), [second.id])
        XCTAssertTrue(grants.grants(for: first.service.id).isEmpty)
        XCTAssertFalse(grants.grants(for: second.service.id).isEmpty)
        CustomMCPConnector.forget()
        XCTAssertTrue(CustomMCPServerStore.all().isEmpty)
        XCTAssertTrue(grants.grants(for: second.service.id).isEmpty)
    }

    func testRecordsSurviveARoundTripThroughDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CustomMCPConnectorTests"))
        defaults.removePersistentDomain(forName: "CustomMCPConnectorTests")
        let storage = DefaultsCustomMCPServerStorage(defaults: defaults)
        let server = CustomMCPServer(id: "s1", name: "MVP", endpoint: endpoint, auth: .oauth, profileId: "p1", ownerId: "u1",
                                     tools: [.init(name: "ping", description: "", inputSchemaJSON: "{}")], addedAt: Date())
        storage.save([server])
        XCTAssertEqual(storage.all(), [server])
        XCTAssertEqual(server.service.id, "custom-s1")
    }
}
