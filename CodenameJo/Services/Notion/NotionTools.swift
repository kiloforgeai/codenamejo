import FactoryKit
import Foundation

extension RemoteMCPService {
    /// Notion's hosted MCP. Its token is good against `mcp.notion.com` only (Notion's REST API
    /// refuses it), and it authorizes at user level, so the whole workspace is reachable.
    static let notion = RemoteMCPService(id: "notion", displayName: "Notion",
                                         endpoint: URL(string: "https://mcp.notion.com/mcp")!)
}

/// Notion's tools on this phone: seven verbs with our compact schemas (`LiveToolSchemas`), dispatch worker only.
/// Nothing here can remove what is on a page: Notion has no delete tool and only additive commands are carried.
enum NotionTools {
    static let names: [String] = [
        "notion-search", "notion-fetch", "notion-list-recent-pages",
        "notion-query-data-sources", "notion-create-pages", "notion-update-page",
    ]
    static let writes: Set<String> = ["notion-create-pages", "notion-update-page"]
    static let updateCommands = ["update_properties", "insert_content"]
    /// Questions about the whole workspace rather than one id fan out across every grant.
    static let fansOut: Set<String> = ["notion-search", "notion-list-recent-pages"]

    static let searchMax = 25
    static let recentMax = 50
    static let queryPageMax = 100

    // MARK: - Connections

    /// The profile's Notion grants. The worker runs a job on the profile it was dispatched from.
    static func grants(profileId: String?) -> [RemoteMCPGrant] {
        RemoteMCPGrantStore.grants(.notion, profileId: profileId)
    }

    /// Workspace labels the user must reconnect, for the prompt and Settings.
    static func needsReauth(profileId: String?) -> [String] {
        grants(profileId: profileId).filter(\.needsReauth).map(\.label)
    }

    /// Whether a working grant exists for the profile.
    static func isConnected(profileId: String?) -> Bool {
        grants(profileId: profileId).contains { !$0.needsReauth }
    }

    // MARK: - Running

    /// Run one Notion tool for `profileId` and hand back the text the model reads.
    static func run(name: String, argumentsJSON: String, profileId: String?,
                    credentials: RemoteMCPCredentials = Container.shared.remoteMCPCredentials())
        async -> FullDuplexBroker.ToolResult {
        guard names.contains(name) else { return .init(text: "\(name) is not a Notion tool.", ok: false) }
        let workspaces = grants(profileId: profileId).filter { !$0.needsReauth }
        guard !workspaces.isEmpty else {
            let broken = !grants(profileId: profileId).isEmpty
            return .init(text: broken
                ? "Notion needs reconnecting. Ask the user to reconnect Notion in Settings."
                : "No Notion workspace is connected. Ask the user to connect Notion in Settings.", ok: false)
        }
        let input = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        if let refusal = refuse(name, input) { return .init(text: refusal, ok: false) }
        let arguments = vendorArguments(name, input)
        let started = Date()
        defer {
            RealtimeLog.log("notion: \(name) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        }

        if fansOut.contains(name), workspaces.count > 1 {
            // Tagged by workspace: a flat merge could not say which workspace a page is in.
            var all: [[String: String]] = []
            for grant in workspaces {
                do {
                    let result = try await credentials.callTool(.notion, grantId: grant.id, name: name, arguments: arguments)
                    all.append(["workspace": grant.label, "result": result.text])
                } catch {
                    all.append(["workspace": grant.label, "error": explain(error)])
                }
            }
            let data = (try? JSONSerialization.data(withJSONObject: all)) ?? Data()
            return .init(text: String(decoding: data, as: UTF8.self), ok: true)
        }

        // An id belongs to one workspace and nothing says which: the first that does not refuse.
        // Safe for a write, because a refused Notion write has created nothing.
        var last: RemoteMCPToolResult?
        for grant in workspaces {
            do {
                let result = try await credentials.callTool(.notion, grantId: grant.id, name: name, arguments: arguments)
                if !result.isError {
                    return .init(text: result.text.isEmpty ? "Notion returned nothing for that." : result.text,
                                 ok: !result.text.isEmpty, performedTool: writes.contains(name) ? name : nil)
                }
                last = result
            } catch {
                RealtimeLog.log("notion: \(name) on \(grant.label) failed — \(error)")
                if workspaces.count == 1 { return .init(text: explain(error), ok: false) }
            }
        }
        return .init(text: last?.text ?? "That Notion request failed before it finished.", ok: false)
    }

    /// Transport and auth failures in words the model can act on. A tool that failed inside Notion
    /// never reaches here: its own sentence is more specific.
    static func explain(_ error: Error) -> String {
        switch error as? RemoteMCPError {
        case .unauthorized?:
            return "Notion rejected the connection. Ask the user to reconnect Notion in Settings."
        case .badResponse?:
            return "Notion returned something unreadable. Say so and try again in a moment."
        case .http(let status, _)? where status == 429:
            return "Notion is rate-limiting us. Say so and try again in a moment."
        case .http(let status, _)? where status >= 500:
            return "Notion is having trouble right now. Say so and try again in a moment."
        case .http(let status, _)?:
            return "Notion refused the request (HTTP \(status))."
        case .rpc(_, let message)?:
            return "Notion refused the request: \(message)"
        case .transport?, .sessionExpired?, nil:
            return "That Notion request failed before it finished. Say so and try again in a moment."
        }
    }

    // MARK: - Arguments

    /// What is wrong with a call before Notion sees it, or nil. Anything Notion itself would refuse
    /// is Notion's to say.
    static func refuse(_ name: String, _ input: [String: Any]) -> String? {
        switch name {
        case "notion-search":
            if text(input["query"]) == nil { return "Say what to search Notion for — the query is empty." }
            if bounded(input["page_size"], searchMax) == .invalid { return "page_size must be a whole number from 1 to \(searchMax)." }
        case "notion-fetch":
            if text(input["id"]) == nil { return "Give the page or database id or URL to read." }
        case "notion-list-recent-pages":
            if bounded(input["limit"], recentMax) == .invalid { return "limit must be a whole number from 1 to \(recentMax)." }
        case "notion-query-data-sources":
            if text(input["view_url"]) != nil {
                if bounded(input["page_size"], queryPageMax) == .invalid {
                    return "page_size must be a whole number from 1 to \(queryPageMax)."
                }
            } else if dataSourceURL(input["data_source_url"]) == nil || text(input["query"]) == nil {
                return "Give view_url, or data_source_url and a query. notion-fetch the database first to get its collection:// URL."
            }
        case "notion-create-pages":
            if text(input["title"]) == nil && (input["properties"] as? [String: Any] ?? [:]).isEmpty {
                return "NOT CREATED — the page needs a title."
            }
            if input["parent_page_id"] != nil && notionId(input["parent_page_id"]) == nil {
                return "NOT CREATED — parent_page_id is not a Notion page id or URL. Find the page with notion-search first."
            }
            if input["parent_database_id"] != nil && databaseParent(input["parent_database_id"]) == nil {
                return "NOT CREATED — parent_database_id is not a Notion database id or URL. Find it with notion-search first."
            }
            if input["parent_page_id"] != nil && input["parent_database_id"] != nil {
                return "NOT CREATED — give a parent page or a parent database, not both."
            }
            if let content = input["content"], !(content is String) { return "NOT CREATED — content must be Markdown text." }
        case "notion-update-page":
            if notionId(input["page_id"]) == nil {
                return "NOT UPDATED — page_id is not a Notion page id or URL. Find the page with notion-search or notion-list-recent-pages first."
            }
            let command = input["command"] as? String ?? ""
            if !updateCommands.contains(command) { return "NOT UPDATED — command must be update_properties or insert_content." }
            if command == "update_properties" && (input["properties"] as? [String: Any] ?? [:]).isEmpty {
                return "NOT UPDATED — update_properties needs properties: which property, set to what."
            }
            if command == "insert_content" && text(input["content"]) == nil {
                return "NOT UPDATED — insert_content needs content to add."
            }
            if let position = input["position"], position as? String != "start" && position as? String != "end" {
                return "NOT UPDATED — position must be start or end."
            }
        default:
            return "\(name) is not a Notion tool."
        }
        return nil
    }

    /// Our arguments into Notion's. Never emits `allow_async` (no task id to chase), never
    /// `allow_deleting_content`, and never a command this surface does not carry.
    static func vendorArguments(_ name: String, _ input: [String: Any]) -> [String: Any] {
        switch name {
        case "notion-search":
            var out: [String: Any] = ["query": text(input["query"]) ?? ""]
            if case .value(let size) = bounded(input["page_size"], searchMax) { out["page_size"] = size }
            return out
        case "notion-fetch":
            // A data source keeps its scheme: stripped to a bare id, it reads as a page id.
            if let id = text(input["id"]), id.hasPrefix("collection://") { return ["id": id] }
            return ["id": notionId(input["id"]) ?? text(input["id"]) ?? ""]
        case "notion-list-recent-pages":
            if case .value(let limit) = bounded(input["limit"], recentMax) { return ["limit": limit] }
            return [:]
        case "notion-query-data-sources":
            if let view = text(input["view_url"]) {
                var data: [String: Any] = ["mode": "view", "view_url": view]
                if case .value(let size) = bounded(input["page_size"], queryPageMax) { data["page_size"] = size }
                return ["data": data]
            }
            return ["data": ["mode": "sql", "data_source_urls": [dataSourceURL(input["data_source_url"]) ?? ""],
                             "query": text(input["query"]) ?? ""]]
        case "notion-create-pages":
            var properties: [String: Any] = text(input["title"]).map { ["title": $0] } ?? [:]
            for (key, value) in input["properties"] as? [String: Any] ?? [:] { properties[key] = value }
            var page: [String: Any] = ["properties": properties]
            if let content = text(input["content"]) { page["content"] = content }
            var out: [String: Any] = ["pages": [page]]
            if let parent = notionId(input["parent_page_id"]) {
                out["parent"] = ["type": "page_id", "page_id": parent]
            } else if let parent = databaseParent(input["parent_database_id"]) {
                out["parent"] = parent
            }
            return out
        case "notion-update-page":
            let command = input["command"] as? String ?? ""
            var out: [String: Any] = ["page_id": notionId(input["page_id"]) ?? "", "command": command]
            if command == "update_properties" { out["properties"] = input["properties"] as? [String: Any] ?? [:] }
            if command == "insert_content" {
                out["content"] = text(input["content"]) ?? ""
                if let position = input["position"] as? String, ["start", "end"].contains(position) {
                    out["position"] = ["type": position]
                }
            }
            return out
        default:
            return input
        }
    }

    /// A Notion id out of a bare UUID (dashed or not) or a URL that ends in one, dashed.
    /// The last id-shaped run is the page: fragments and `?p=` can carry block ids ahead of it.
    static func notionId(_ value: Any?) -> String? {
        guard let raw = text(value) else { return nil }
        let pattern = "[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).last,
              let range = Range(match.range, in: raw) else { return nil }
        let hex = raw[range].replacingOccurrences(of: "-", with: "").lowercased()
        let chars = Array(hex)
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }.joined(separator: "-")
    }

    /// A data source as Notion names it, `collection://<uuid>`, from that URL or a bare id.
    static func dataSourceURL(_ value: Any?) -> String? {
        guard let raw = text(value) else { return nil }
        if raw.hasPrefix("collection://") { return raw }
        let bare = raw.replacingOccurrences(of: "-", with: "")
        guard bare.count == 32, bare.allSatisfy(\.isHexDigit) else { return nil }
        return notionId(raw).map { "collection://\($0)" }
    }

    /// A database parent: a `collection://` URL is a data source, anything else a database id.
    private static func databaseParent(_ value: Any?) -> [String: Any]? {
        if let raw = text(value), raw.hasPrefix("collection://"), let id = notionId(raw) {
            return ["type": "data_source_id", "data_source_id": id]
        }
        return notionId(value).map { ["type": "database_id", "database_id": $0] }
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private enum Bound: Equatable { case absent, invalid, value(Int) }

    private static func bounded(_ value: Any?, _ max: Int) -> Bound {
        guard let value, !(value is NSNull) else { return .absent }
        let number: Int?
        if let int = value as? Int { number = int }
        else if let double = value as? Double, double == double.rounded() { number = Int(double) }
        else if let string = value as? String { number = Int(string) }
        else { number = nil }
        guard let number, (1...max).contains(number) else { return .invalid }
        return .value(number)
    }
}
