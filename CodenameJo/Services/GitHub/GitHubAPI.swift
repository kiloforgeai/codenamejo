import FactoryKit
import Foundation

/// GitHub's REST API (and the one GraphQL mutation the draft toggle needs), with the user's token.
/// Without `allowWrites` it refuses any mutating method; only `GitHubTools.writeTools` get it.
struct GitHubAPI {
    static let base = URL(string: "https://api.github.com")!

    struct Failure: Error, Equatable {
        let status: Int
        let message: String
    }

    let token: String
    let allowWrites: Bool
    var transport: any HTTPDataTransport = Container.shared.githubHTTP()

    // MARK: - Calls

    func object(_ path: String, _ query: [String: Any?] = [:]) async throws -> [String: Any] {
        try await json(path, query) as? [String: Any] ?? [:]
    }

    func list(_ path: String, _ query: [String: Any?] = [:]) async throws -> [[String: Any]] {
        try await json(path, query) as? [[String: Any]] ?? []
    }

    func json(_ path: String, _ query: [String: Any?] = [:], method: String = "GET",
              body: [String: Any]? = nil) async throws -> Any? {
        let data = try await send(path, query, method: method, body: body, accept: "application/vnd.github+json")
        guard !data.isEmpty else { return nil }
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    /// A diff or a job log: plain text rather than JSON.
    func text(_ path: String, accept: String) async throws -> String {
        String(decoding: try await send(path, [:], method: "GET", body: nil, accept: accept), as: UTF8.self)
    }

    func graphql(_ query: String, variables: [String: Any]) async throws {
        let data = try await send("/graphql", [:], method: "POST", body: ["query": query, "variables": variables],
                                  accept: "application/vnd.github+json")
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let first = (parsed?["errors"] as? [[String: Any]])?.first {
            throw Failure(status: 200, message: first["message"] as? String ?? "graphql_failed")
        }
    }

    private func send(_ path: String, _ query: [String: Any?], method: String, body: [String: Any]?,
                      accept: String) async throws -> Data {
        guard method == "GET" || allowWrites else {
            throw Failure(status: 405, message: "A read tool tried to change something on GitHub, and was stopped.")
        }
        guard var components = URLComponents(url: Self.base, resolvingAgainstBaseURL: false) else {
            throw Failure(status: 400, message: "Bad path.")
        }
        components.percentEncodedPath = path
        let items = query.compactMap { key, value -> URLQueryItem? in
            guard let value, let text = Self.queryValue(value) else { return nil }
            return URLQueryItem(name: key, value: text)
        }.sorted { $0.name < $1.name }
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url else { throw Failure(status: 400, message: "Bad path.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub 403s a request without one, saying nothing about the header.
        request.setValue("CodenameJo-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await transport.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else { throw Failure(status: status, message: Self.detail(data)) }
        return data
    }

    static func queryValue(_ value: Any) -> String? {
        switch value {
        case let s as String: return s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s
        // Before any `as Bool`, which would also match the numbers 0 and 1.
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        default: return nil
        }
    }

    /// GitHub's `message`, plus the first validation error's field and code when it gave one.
    static func detail(_ data: Data) -> String {
        guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let message = parsed["message"] as? String
        else { return String(decoding: data.prefix(300), as: UTF8.self) }
        guard let first = (parsed["errors"] as? [[String: Any]])?.first else { return message }
        let extra = ["field", "code", "message"].compactMap { first[$0] as? String }.joined(separator: " ")
        return extra.isEmpty ? message : "\(message) (\(extra))"
    }

    /// A path segment, percent-encoded so an owner, repo or workflow file can't step out of its slot.
    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }

    // MARK: - Errors, as something the model can say

    /// Each status needs a different person to fix it, so each says so.
    static func explain(_ error: Error) -> String {
        guard let failure = error as? Failure else {
            return "GitHub could not be reached: \(error.localizedDescription)"
        }
        switch failure.status {
        case 400, 405, 415: return failure.message
        case 401:
            return "GitHub rejected the connection. Ask the user to reconnect GitHub in Settings. (\(failure.message))"
        case 403:
            if failure.message.range(of: "rate limit", options: .caseInsensitive) != nil {
                return "GitHub is rate-limiting us. Say so and try again in a moment."
            }
            return "GitHub refused that — this connection does not have permission. (\(failure.message))"
        case 404:
            return "GitHub found nothing there. Check the owner and repo with github_search_repositories, "
                + "and the number against a list — never guess an owner. (\(failure.message))"
        case 409: return "GitHub could not do that as asked: \(failure.message)"
        case 422: return "GitHub rejected the request: \(failure.message)"
        case 429: return "GitHub is rate-limiting us. Say so and try again in a moment."
        default: return "GitHub failed (\(failure.status)): \(failure.message)"
        }
    }
}
