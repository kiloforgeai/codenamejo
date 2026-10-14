import FactoryKit
import Foundation

/// The user's own MCP servers as Live function tools named `mcp_<server>_<tool>`, relayed from
/// this phone with the Keychain grant. Only the result text reaches the model.
enum CustomMCPTools {
    static let prefix = "mcp_"
    /// OpenAI's limit on a function name.
    static let maxFunctionName = 64
    static let slugLength = 12
    static let descriptionLimit = 600
    /// A result longer than this is cut, with a note, so one tool cannot flood the turn.
    static let resultLimit = 24_000

    // MARK: - Names

    /// The server's name as a function-name segment: ASCII letters and digits, lowercased, short.
    /// A name with none of those falls back to the record id.
    static func slug(_ server: CustomMCPServer) -> String {
        let letters = server.name.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if !letters.isEmpty { return String(letters.prefix(slugLength)) }
        return String(server.id.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(6))
    }

    /// The vendor's tool name with anything outside `[A-Za-z0-9_-]` replaced.
    static func sanitized(_ tool: String) -> String {
        String(tool.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" || $0 == "-" ? $0 : "_" })
    }

    static func functionName(server: CustomMCPServer, tool: String) -> String {
        String((prefix + slug(server) + "_" + sanitized(tool)).prefix(maxFunctionName))
    }

    static func isCustomTool(_ name: String) -> Bool { name.hasPrefix(prefix) }

    /// `mcp_mvp_file_issue` → `file_issue`, for narration. Unknown shapes come back as given.
    static func bareName(_ function: String) -> String {
        guard function.hasPrefix(prefix) else { return function }
        let rest = function.dropFirst(prefix.count)
        guard let cut = rest.firstIndex(of: "_"), cut < rest.index(before: rest.endIndex) else { return String(rest) }
        return String(rest[rest.index(after: cut)...])
    }

    /// `file_issue` → `File issue`, for Settings.
    static func humanized(_ tool: String) -> String {
        let words = tool.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").map(String.init)
        guard let first = words.first else { return tool }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    // MARK: - Definitions

    /// One listed tool as a Responses function tool. The server's `inputSchema` is passed through,
    /// made an object when it is not one, under `strict: false`.
    static func definition(server: CustomMCPServer, tool: CustomMCPServer.Tool) -> [String: Any] {
        var parameters = tool.inputSchema
        parameters["type"] = "object"
        if parameters["properties"] == nil { parameters["properties"] = [String: Any]() }
        parameters["$schema"] = nil
        let described = tool.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = "[\(server.name)] " + (described.isEmpty ? "A tool from \(server.name)." : String(described.prefix(descriptionLimit)))
        return ["type": "function", "name": functionName(server: server, tool: tool.name),
                "description": description, "parameters": parameters, "strict": false]
    }

    /// Every tool of every usable server, in the order they were added. A name that two tools
    /// would share after truncation is declared once, for the first.
    static func definitions(servers: [CustomMCPServer],
                            usable: (CustomMCPServer) -> Bool = CustomMCPConnector.isUsable) -> [[String: Any]] {
        var seen = Set<String>()
        var out: [[String: Any]] = []
        for server in servers where usable(server) {
            for tool in server.tools {
                let definition = definition(server: server, tool: tool)
                let name = definition["name"] as? String ?? ""
                guard seen.insert(name).inserted else {
                    RealtimeLog.log("mcp \(server.name): \(tool.name) collides with another tool as \(name); not declared")
                    continue
                }
                out.append(definition)
            }
        }
        return out
    }

    /// Which server and listed tool a function name stands for.
    static func resolve(_ name: String, servers: [CustomMCPServer]) -> (server: CustomMCPServer, tool: CustomMCPServer.Tool)? {
        for server in servers {
            if let tool = server.tools.first(where: { functionName(server: server, tool: $0.name) == name }) {
                return (server, tool)
            }
        }
        return nil
    }

    // MARK: - Run

    /// One tool call on one server's grant. Tests swap it for canned answers.
    typealias Call = (_ server: CustomMCPServer, _ grant: RemoteMCPGrant, _ tool: String,
                      _ arguments: [String: Any]) async throws -> RemoteMCPToolResult

    static let liveCall: Call = { server, grant, tool, arguments in
        try await Container.shared.remoteMCPCredentials().callTool(server.service, grantId: grant.id, name: tool,
                                                                    arguments: arguments)
    }

    /// Never throws: a refusal or failure comes back as text the model can say.
    static func run(name: String, argumentsJSON: String,
                    servers: [CustomMCPServer] = CustomMCPConnector.servers(),
                    grant: (CustomMCPServer) -> RemoteMCPGrant? = CustomMCPConnector.grant,
                    call: Call = liveCall) async -> FullDuplexBroker.ToolResult {
        guard let (server, tool) = resolve(name, servers: servers) else {
            RealtimeLog.log("mcp: \(name) matches no connected server's tool")
            return .init(text: "There is no tool called \(name). Use only the tools you were given.", ok: false)
        }
        guard let grant = grant(server), !grant.needsReauth else {
            return .init(text: "\(server.name) needs reconnecting. Ask the user to reconnect it under Custom MCP in Settings.",
                         ok: false)
        }
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let started = Date()
        do {
            let result = try await call(server, grant, tool.name, arguments)
            RealtimeLog.log("mcp \(server.name): \(tool.name) — \(result.isError ? "failed" : "ok") in "
                + "\(Int(Date().timeIntervalSince(started) * 1000))ms, \(result.text.utf8.count) bytes")
            if result.text.isEmpty { return .init(text: "\(server.name) returned nothing for that.", ok: !result.isError) }
            return .init(text: clipped(result.text, server: server.name), ok: !result.isError)
        } catch {
            RealtimeLog.log("mcp \(server.name): \(tool.name) — \(error)")
            return .init(text: explain(error, server: server.name), ok: false)
        }
    }

    static func clipped(_ text: String, server: String) -> String {
        guard text.utf8.count > resultLimit else { return text }
        return String(text.prefix(resultLimit)) + "\n[\(server) returned more than this; the rest was cut. Ask for something narrower.]"
    }

    /// Transport and auth failures in words the model can act on. A tool that failed inside the
    /// server comes back as its own text instead, which is more specific than anything here.
    static func explain(_ error: Error, server: String) -> String {
        switch error as? RemoteMCPError {
        case .unauthorized?:
            return "\(server) rejected the connection. Ask the user to reconnect it under Custom MCP in Settings."
        case .badResponse?:
            return "\(server) returned something unreadable. Say so and try again in a moment."
        case .http(let status, _)? where status == 429:
            return "\(server) is rate-limiting us. Say so and try again in a moment."
        case .http(let status, _)? where status >= 500:
            return "\(server) is having trouble right now. Say so and try again in a moment."
        case .http(let status, _)?:
            return "\(server) refused the request (HTTP \(status))."
        case .rpc(_, let message)?:
            return "\(server) refused the request (\(message))."
        case .sessionExpired?, .transport?, nil:
            return "Couldn't reach \(server). Say so and try again in a moment."
        }
    }
}
