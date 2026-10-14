import FactoryKit
import XCTest
@testable import CodenameJo

/// A server that answers from a closure and records every request.
final class ScriptedMCPServer: HTTPDataTransport, @unchecked Sendable {
    struct Call {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: String
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:] }
        var form: [String: String] {
            Dictionary(uniqueKeysWithValues: body.split(separator: "&").map { pair -> (String, String) in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                return (parts[0], (parts.count > 1 ? parts[1] : "").removingPercentEncoding ?? "")
            })
        }
    }
    struct Answer {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body = "{}"
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let respond: (Call) -> Answer

    init(_ respond: @escaping (Call) -> Answer) { self.respond = respond }

    var calls: [Call] { lock.withLock { recorded } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let call = Call(url: request.url!, method: request.httpMethod ?? "GET",
                        headers: request.allHTTPHeaderFields ?? [:],
                        body: String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        lock.withLock { recorded.append(call) }
        let answer = respond(call)
        let response = HTTPURLResponse(url: call.url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                       headerFields: answer.headers)!
        return (Data(answer.body.utf8), response)
    }

    /// An SSE body carrying one JSON-RPC result for `id`.
    static func sse(id: Any, result: String) -> Answer {
        Answer(headers: ["Content-Type": "text/event-stream"],
               body: "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":\(result)}\n\n")
    }
}

final class RemoteMCPClientTests: XCTestCase {
    private let endpoint = URL(string: "https://mcp.example.test/mcp")!

    /// A minimal MCP server: initialize hands out a session, tools/call echoes the tool name.
    private func server(session: String? = "s-1", callStatus: Int = 200) -> ScriptedMCPServer {
        ScriptedMCPServer { call in
            let method = call.json["method"] as? String ?? ""
            let id = call.json["id"] ?? NSNull()
            switch method {
            case "initialize":
                var answer = ScriptedMCPServer.sse(id: id, result: #"{"protocolVersion":"2025-06-18","capabilities":{}}"#)
                if let session { answer.headers["Mcp-Session-Id"] = session }
                return answer
            case "notifications/initialized":
                return .init(status: 202, body: "")
            case "tools/call":
                if callStatus != 200 { return .init(status: callStatus, body: "") }
                let name = (call.json["params"] as? [String: Any])?["name"] as? String ?? ""
                return .init(body: #"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[{"type":"text","text":"ran \#(name)"}]}}"#)
            case "tools/list":
                let cursor = (call.json["params"] as? [String: Any])?["cursor"] as? String
                return cursor == nil
                    ? .init(body: #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[{"name":"a"}],"nextCursor":"2"}}"#)
                    : .init(body: #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[{"name":"b"}]}}"#)
            default:
                return .init(status: 400)
            }
        }
    }

    func testHandshakeCarriesTheSessionAndVersionOnLaterRequests() async throws {
        let server = server()
        let client = RemoteMCPClient(endpoint: endpoint, accessToken: "tok", transport: server)
        let result = try await client.callTool("notion-search", arguments: ["query": "x"])
        XCTAssertEqual(result, RemoteMCPToolResult(text: "ran notion-search", isError: false))
        let methods = server.calls.map { $0.json["method"] as? String ?? "" }
        XCTAssertEqual(methods, ["initialize", "notifications/initialized", "tools/call"])
        XCTAssertNil(server.calls[0].headers["Mcp-Session-Id"])
        XCTAssertEqual(server.calls[2].headers["Mcp-Session-Id"], "s-1")
        XCTAssertEqual(server.calls[2].headers["MCP-Protocol-Version"], "2025-06-18")
        XCTAssertEqual(server.calls[2].headers["Authorization"], "Bearer tok")
        XCTAssertEqual(server.calls[2].headers["Accept"], "application/json, text/event-stream")
    }

    func testAStatelessServerSendsNoSessionHeader() async throws {
        let server = server(session: nil)
        let client = RemoteMCPClient(endpoint: endpoint, accessToken: "tok", transport: server)
        _ = try await client.callTool("x", arguments: [:])
        XCTAssertNil(server.calls.last?.headers["Mcp-Session-Id"])
    }

    func testARefusedBearerIsUnauthorized() async {
        let client = RemoteMCPClient(endpoint: endpoint, accessToken: "tok", transport: server(callStatus: 401))
        do {
            _ = try await client.callTool("x", arguments: [:])
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? RemoteMCPError, .unauthorized(status: 401))
        }
    }

    func testListToolsFollowsTheCursor() async throws {
        let client = RemoteMCPClient(endpoint: endpoint, accessToken: "tok", transport: server())
        let names = try await client.listTools().compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["a", "b"])
    }

    func testTheAnswerIsPickedOutOfAStreamByItsId() throws {
        let body = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n"
            + "data: {\"jsonrpc\":\"2.0\",\n"
            + "data: \"id\":7,\"result\":{\"ok\":true}}\n\n"
        let message = try RemoteMCPClient.message(in: Data(body.utf8), contentType: "text/event-stream", id: 7)
        XCTAssertEqual((message["result"] as? [String: Any])?["ok"] as? Bool, true)
    }

    func testAToolErrorIsCarriedNotThrown() {
        let result = RemoteMCPClient.toolResult(["isError": true, "content": [["type": "text", "text": "not shared"]]])
        XCTAssertEqual(result, RemoteMCPToolResult(text: "not shared", isError: true))
    }

    func testAnRPCErrorThrows() async {
        let server = ScriptedMCPServer { call in
            let id = call.json["id"] ?? NSNull()
            if call.json["method"] as? String == "notifications/initialized" { return .init(status: 202, body: "") }
            if call.json["method"] as? String == "initialize" { return ScriptedMCPServer.sse(id: id, result: "{}") }
            return .init(body: #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32602,"message":"bad args"}}"#)
        }
        let client = RemoteMCPClient(endpoint: endpoint, accessToken: "tok", transport: server)
        do {
            _ = try await client.callTool("x", arguments: [:])
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? RemoteMCPError, .rpc(code: -32602, message: "bad args"))
        }
    }
}

final class RemoteMCPAuthTests: XCTestCase {
    private let service = RemoteMCPService(id: "test", displayName: "Test",
                                           endpoint: URL(string: "https://mcp.example.test/mcp")!)
    private var storage: InMemoryRemoteMCPGrantStorage!

    override func setUp() {
        super.setUp()
        storage = InMemoryRemoteMCPGrantStorage()
        let storage = storage!
        Container.shared.remoteMCPGrantStorage.register { storage }
    }

    override func tearDown() {
        Container.shared.remoteMCPGrantStorage.reset()
        super.tearDown()
    }

    private func grant(expiresIn: TimeInterval, refresh: String? = "r-1") -> RemoteMCPGrant {
        RemoteMCPGrant(id: "g1", label: "Test", profileId: "p1", accessToken: "old", refreshToken: refresh,
                       expiresAt: Date().addingTimeInterval(expiresIn), clientId: "c1",
                       tokenEndpoint: "https://mcp.example.test/token",
                       revocationEndpoint: "https://mcp.example.test/token",
                       resource: "https://mcp.example.test/mcp", grantedAt: Date())
    }

    func testWellKnownTriesThePathSuffixedDocumentFirst() {
        XCTAssertEqual(RemoteMCPAuth.wellKnown("oauth-protected-resource", for: service.endpoint).map(\.absoluteString), [
            "https://mcp.example.test/.well-known/oauth-protected-resource/mcp",
            "https://mcp.example.test/.well-known/oauth-protected-resource",
        ])
        XCTAssertEqual(RemoteMCPAuth.wellKnown("oauth-authorization-server", for: URL(string: "https://a.test")!)
            .map(\.absoluteString), ["https://a.test/.well-known/oauth-authorization-server"])
    }

    func testDiscoveryReadsTheResourceAndItsAuthorizationServer() async throws {
        let server = ScriptedMCPServer { call in
            switch call.url.path {
            case "/.well-known/oauth-protected-resource/mcp":
                return .init(body: #"{"resource":"https://mcp.example.test/mcp","authorization_servers":["https://auth.example.test"],"scopes_supported":["default"]}"#)
            case "/.well-known/oauth-authorization-server":
                return .init(body: #"{"issuer":"https://auth.example.test","authorization_endpoint":"https://auth.example.test/authorize","token_endpoint":"https://auth.example.test/token","registration_endpoint":"https://auth.example.test/register","revocation_endpoint":"https://auth.example.test/token"}"#)
            default:
                return .init(status: 404, body: "")
            }
        }
        let metadata = try await RemoteMCPAuth.discover(service, transport: server)
        XCTAssertEqual(metadata.resource, "https://mcp.example.test/mcp")
        XCTAssertEqual(metadata.issuer, "https://auth.example.test")
        XCTAssertEqual(metadata.tokenEndpoint.absoluteString, "https://auth.example.test/token")
        XCTAssertEqual(metadata.registrationEndpoint?.absoluteString, "https://auth.example.test/register")
        XCTAssertEqual(metadata.scopes, ["default"])
        XCTAssertEqual(server.calls.first?.url.host, "mcp.example.test")
    }

    func testRegistrationIsAPublicClientAndIsKept() async throws {
        let server = ScriptedMCPServer { _ in .init(status: 201, body: #"{"client_id":"new-client"}"#) }
        let metadata = RemoteMCPAuth.Metadata(
            resource: "r", issuer: "https://auth.example.test",
            authorizationEndpoint: URL(string: "https://auth.example.test/authorize")!,
            tokenEndpoint: URL(string: "https://auth.example.test/token")!,
            registrationEndpoint: URL(string: "https://auth.example.test/register")!, revocationEndpoint: nil, scopes: [])
        let first = try await RemoteMCPAuth.clientId(service, metadata: metadata, transport: server)
        let second = try await RemoteMCPAuth.clientId(service, metadata: metadata, transport: server)
        XCTAssertEqual(first, "new-client")
        XCTAssertEqual(second, "new-client")
        XCTAssertEqual(server.calls.count, 1, "a stored registration is reused")
        let body = try XCTUnwrap(server.calls.first?.json)
        XCTAssertEqual(body["token_endpoint_auth_method"] as? String, "none")
        XCTAssertEqual(body["redirect_uris"] as? [String], ["com.kiloforge.codenamejo:/oauth/callback"])
    }

    func testTheAuthorizeURLCarriesPKCEAndTheResource() throws {
        let metadata = RemoteMCPAuth.Metadata(
            resource: "https://mcp.example.test/mcp", issuer: "https://auth.example.test",
            authorizationEndpoint: URL(string: "https://auth.example.test/authorize")!,
            tokenEndpoint: URL(string: "https://auth.example.test/token")!,
            registrationEndpoint: nil, revocationEndpoint: nil, scopes: ["default"])
        let pkce = GoogleSignInFlow.PKCE(verifier: "v")
        let url = try XCTUnwrap(RemoteMCPAuth.authorizeURL(metadata, service: service, clientId: "c", pkce: pkce, state: "s"))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["code_challenge"], pkce.challenge)
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["resource"], "https://mcp.example.test/mcp")
        XCTAssertEqual(items["redirect_uri"], "com.kiloforge.codenamejo:/oauth/callback")
        XCTAssertEqual(items["scope"], "default")
        XCTAssertNil(items["client_secret"])
    }

    func testTheCallbackMustMatchStateAndIssuer() {
        let ok = URL(string: "com.kiloforge.codenamejo:/oauth/callback?code=abc&state=s&iss=https://auth.example.test")!
        XCTAssertEqual(RemoteMCPAuth.readCallback(ok, state: "s", issuer: "https://auth.example.test"), .success("abc"))
        XCTAssertEqual(RemoteMCPAuth.readCallback(ok, state: "other", issuer: "https://auth.example.test"),
                       .failure(.failed("The sign-in didn't complete. Try again.")))
        XCTAssertEqual(RemoteMCPAuth.readCallback(ok, state: "s", issuer: "https://evil.test"),
                       .failure(.failed("The sign-in came back from the wrong server.")))
        let denied = URL(string: "com.kiloforge.codenamejo:/oauth/callback?error=access_denied&state=s")!
        XCTAssertEqual(RemoteMCPAuth.readCallback(denied, state: "s", issuer: "x"), .failure(.cancelled))
    }

    func testOnlyARefusedGrantIsRevoked() {
        XCTAssertEqual(RemoteMCPAuth.classify(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)), .failure(.revoked))
        XCTAssertEqual(RemoteMCPAuth.classify(status: 503, body: Data()), .failure(.failed("http_503")))
        XCTAssertEqual(RemoteMCPAuth.classify(status: 200, body: Data(#"{"access_token":"a","expires_in":3600}"#.utf8)),
                       .success(.init(access_token: "a", refresh_token: nil, expires_in: 3600, scope: nil)))
    }

    func testAFreshTokenIsUsedWithoutARefresh() async {
        RemoteMCPGrantStore.save(grant(expiresIn: 3600), service)
        let server = ScriptedMCPServer { _ in XCTFail("no request expected"); return .init() }
        let credentials = RemoteMCPCredentials(transport: server)
        let result = await credentials.accessToken(service, grantId: "g1")
        XCTAssertEqual(result, .success("old"))
    }

    func testAnExpiringTokenIsRenewedAndTheRotatedRefreshTokenKept() async throws {
        RemoteMCPGrantStore.save(grant(expiresIn: 10), service)
        let server = ScriptedMCPServer { _ in
            .init(body: #"{"access_token":"new","refresh_token":"r-2","expires_in":3600}"#)
        }
        let credentials = RemoteMCPCredentials(transport: server)
        async let a = credentials.accessToken(service, grantId: "g1")
        async let b = credentials.accessToken(service, grantId: "g1")
        let results = await [a, b]
        XCTAssertEqual(results, [.success("new"), .success("new")])
        XCTAssertEqual(server.calls.count, 1, "concurrent renewals share one refresh")
        let form = try XCTUnwrap(server.calls.first?.form)
        XCTAssertEqual(form["grant_type"], "refresh_token")
        XCTAssertEqual(form["refresh_token"], "r-1")
        XCTAssertEqual(form["client_id"], "c1")
        XCTAssertEqual(form["resource"], "https://mcp.example.test/mcp")
        XCTAssertEqual(RemoteMCPGrantStore.grant(service, id: "g1")?.refreshToken, "r-2")
    }

    func testARefusedRefreshFlagsTheGrant() async {
        RemoteMCPGrantStore.save(grant(expiresIn: -10), service)
        let server = ScriptedMCPServer { _ in .init(status: 400, body: #"{"error":"invalid_grant"}"#) }
        let result = await RemoteMCPCredentials(transport: server).accessToken(service, grantId: "g1")
        XCTAssertEqual(result, .failure(.needsReauth))
        XCTAssertEqual(RemoteMCPGrantStore.grant(service, id: "g1")?.needsReauth, true)
    }

    func testATransientRefreshFailureLeavesTheGrantAlone() async {
        RemoteMCPGrantStore.save(grant(expiresIn: -10), service)
        let server = ScriptedMCPServer { _ in .init(status: 503, body: "") }
        let result = await RemoteMCPCredentials(transport: server).accessToken(service, grantId: "g1")
        XCTAssertEqual(result, .failure(.transient("http_503")))
        XCTAssertEqual(RemoteMCPGrantStore.grant(service, id: "g1")?.needsReauth, false)
    }

    func testARefusedCallRenewsOnceThenFlags() async {
        RemoteMCPGrantStore.save(grant(expiresIn: 3600), service)
        let server = ScriptedMCPServer { call in
            if call.url.path == "/token" { return .init(body: #"{"access_token":"new","expires_in":3600}"#) }
            return .init(status: 401, body: "")
        }
        let credentials = RemoteMCPCredentials(transport: server)
        do {
            _ = try await credentials.callTool(service, grantId: "g1", name: "x", arguments: [:])
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? RemoteMCPError, .unauthorized(status: 401))
        }
        XCTAssertEqual(server.calls.filter { $0.url.path == "/token" }.count, 1)
        XCTAssertEqual(RemoteMCPGrantStore.grant(service, id: "g1")?.needsReauth, true)
    }

    func testRemoveAllForgetsGrantsAndTheRegistration() {
        RemoteMCPGrantStore.save(grant(expiresIn: 3600), service)
        RemoteMCPGrantStore.saveRegistration(.init(clientId: "c", redirectURI: "r", authorizationServer: "a"), service)
        RemoteMCPGrantStore.removeAll(service)
        XCTAssertTrue(RemoteMCPGrantStore.grants(service).isEmpty)
        XCTAssertNil(RemoteMCPGrantStore.registration(service))
    }
}
