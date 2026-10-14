import FactoryKit
import Foundation

/// A transport or protocol failure from a remote MCP server. A tool that fails *inside* MCP
/// (`isError`) is not one of these: that is the vendor's own sentence and goes to the model as is.
enum RemoteMCPError: Error, Equatable {
    /// 401 or 403: the bearer was refused.
    case unauthorized(status: Int)
    /// 404 on a request carrying a session id: the server forgot the session.
    case sessionExpired
    case http(status: Int, body: String)
    case rpc(code: Int, message: String)
    case badResponse(String)
    case transport(String)
}

/// What one `tools/call` came back with: the text content joined, and the server's own `isError`.
struct RemoteMCPToolResult: Equatable, Sendable {
    let text: String
    let isError: Bool
}

/// JSON-RPC over MCP's streamable HTTP transport, for one bearer token. Requests carry any
/// `Mcp-Session-Id` and the negotiated version; responses may be JSON or `text/event-stream`.
actor RemoteMCPClient {
    static let protocolVersion = "2025-06-18"

    private let endpoint: URL
    private let accessToken: String
    private let transport: any HTTPDataTransport
    private let clientName: String
    private var sessionId: String?
    private var negotiatedVersion: String?
    private var nextId = 1
    private(set) var isInitialized = false

    init(endpoint: URL, accessToken: String, clientName: String = "Codename Jo",
         transport: any HTTPDataTransport = Container.shared.providerHTTP()) {
        self.endpoint = endpoint
        self.accessToken = accessToken
        self.clientName = clientName
        self.transport = transport
    }

    /// The handshake: `initialize`, then the `notifications/initialized` the spec requires.
    func initialize() async throws {
        sessionId = nil
        negotiatedVersion = nil
        let result = try await request("initialize", [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": clientName, "version": AppInfo.shortVersion],
        ])
        negotiatedVersion = result["protocolVersion"] as? String ?? Self.protocolVersion
        try await notify("notifications/initialized")
        isInitialized = true
    }

    /// Every tool the server lists, following `nextCursor`.
    func listTools() async throws -> [[String: Any]] {
        try await ensureInitialized()
        var tools: [[String: Any]] = []
        var cursor: String?
        repeat {
            let result = try await request("tools/list", cursor.map { ["cursor": $0] } ?? [:])
            tools += result["tools"] as? [[String: Any]] ?? []
            cursor = result["nextCursor"] as? String
        } while cursor != nil && tools.count < 1_000
        return tools
    }

    /// Call one tool. A forgotten session is re-initialized once and the call retried.
    func callTool(_ name: String, arguments: [String: Any]) async throws -> RemoteMCPToolResult {
        try await ensureInitialized()
        let result: [String: Any]
        do {
            result = try await request("tools/call", ["name": name, "arguments": arguments])
        } catch RemoteMCPError.sessionExpired {
            try await initialize()
            result = try await request("tools/call", ["name": name, "arguments": arguments])
        }
        return Self.toolResult(result)
    }

    private func ensureInitialized() async throws {
        if !isInitialized { try await initialize() }
    }

    // MARK: - Wire

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextId
        nextId += 1
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let (data, response) = try await post(body)
        guard (200..<300).contains(response.statusCode) else { throw Self.failure(response, data, sessionId) }
        if method == "initialize", let session = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !session.isEmpty {
            sessionId = session
        }
        let message = try Self.message(in: data, contentType: response.value(forHTTPHeaderField: "Content-Type"), id: id)
        if let error = message["error"] as? [String: Any] {
            throw RemoteMCPError.rpc(code: error["code"] as? Int ?? 0, message: error["message"] as? String ?? "")
        }
        guard let result = message["result"] as? [String: Any] else {
            throw RemoteMCPError.badResponse("no result for \(method)")
        }
        return result
    }

    private func notify(_ method: String) async throws {
        let (data, response) = try await post(["jsonrpc": "2.0", "method": method])
        guard (200..<300).contains(response.statusCode) else { throw Self.failure(response, data, sessionId) }
    }

    private func post(_ body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        // A user's own server may take no credential; an empty bearer is a refusal on some of them.
        if !accessToken.isEmpty { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionId { request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        if let negotiatedVersion { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw RemoteMCPError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw RemoteMCPError.badResponse("not HTTP") }
        return (data, http)
    }

    static func failure(_ response: HTTPURLResponse, _ data: Data, _ sessionId: String?) -> RemoteMCPError {
        switch response.statusCode {
        case 401, 403: return .unauthorized(status: response.statusCode)
        case 404 where sessionId != nil: return .sessionExpired
        default: return .http(status: response.statusCode, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    // MARK: - Parsing

    /// The JSON-RPC response for `id`, from a JSON body or an SSE stream. In a stream, server
    /// requests and notifications may come first; the one carrying our id is the answer.
    static func message(in data: Data, contentType: String?, id: Int) throws -> [String: Any] {
        let text = String(decoding: data, as: UTF8.self)
        let isStream = contentType?.lowercased().contains("text/event-stream") == true
            || text.hasPrefix("event:") || text.hasPrefix("data:")
        let candidates: [Data] = isStream ? events(text).map { Data($0.utf8) } : [data]
        var parsed: [[String: Any]] = []
        for candidate in candidates {
            guard let json = try? JSONSerialization.jsonObject(with: candidate) else { continue }
            if let one = json as? [String: Any] { parsed.append(one) }
            if let batch = json as? [[String: Any]] { parsed += batch }
        }
        if let match = parsed.first(where: { ($0["id"] as? Int) == id || ($0["id"] as? String) == String(id) }) {
            return match
        }
        throw RemoteMCPError.badResponse("unparseable output: \(text.prefix(200))")
    }

    /// Each SSE event's `data:` lines, joined as the spec joins them.
    static func events(_ text: String) -> [String] {
        var out: [String] = []
        var current: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty {
                if !current.isEmpty { out.append(current.joined(separator: "\n")); current = [] }
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                current.append(value)
            }
        }
        if !current.isEmpty { out.append(current.joined(separator: "\n")) }
        return out
    }

    static func toolResult(_ result: [String: Any]) -> RemoteMCPToolResult {
        let content = result["content"] as? [[String: Any]] ?? []
        var text = content.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured) {
            text = String(decoding: data, as: UTF8.self)
        }
        return RemoteMCPToolResult(text: text, isError: result["isError"] as? Bool == true)
    }
}
