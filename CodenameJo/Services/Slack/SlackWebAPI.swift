import FactoryKit
import Foundation

/// One connected workspace as the Slack calls need it. The token is fetched per call from
/// `SlackCredentials`, so a rotation mid-sweep is picked up.
struct SlackWorkspace: Sendable, Equatable {
    let teamId: String
    let teamName: String
    let userId: String
    let scopes: String

    init(teamId: String, teamName: String, userId: String, scopes: String = "") {
        self.teamId = teamId
        self.teamName = teamName
        self.userId = userId
        self.scopes = scopes
    }

    init(_ grant: SlackGrant) {
        self.init(teamId: grant.teamId, teamName: grant.teamName, userId: grant.userId, scopes: grant.scopes)
    }

    var canMark: Bool { SlackGrant.grantsMarking(scopes) }

    /// The active profile's workspaces whose grant still works.
    static func served(profileId: String? = ProfileRuntime.snapshot?.profileId) -> [SlackWorkspace] {
        SlackGrantStore.inProfile(profileId).filter { $0.needsReauth != true }.map(SlackWorkspace.init)
    }
}

/// The Slack Web API, called with the user's token. Slack reports failures as HTTP 200 with
/// `ok: false`, so both the status and the body are read.
enum SlackWebAPI {
    /// `slack_<method>_failed: <code>`, the shape `SlackTools.explain` reads.
    struct CallError: Error, CustomStringConvertible {
        let method: String
        let code: String
        let status: Int
        let retryAfterSeconds: Int
        var description: String { "slack_\(method)_failed: \(code)" }
        var isRateLimit: Bool { status == 429 || code == "ratelimited" }
    }

    struct Identity: Equatable, Sendable {
        let teamId: String
        let teamName: String
        let userId: String
    }

    /// A rate-limited write waits once when Slack asks for a wait short enough for a voice turn.
    static let writeRetryCapSeconds = 3

    static func call(_ ws: SlackWorkspace, _ method: String, _ params: [String: String]) async throws -> [String: Any] {
        try await authorized(ws, method) { token in
            var components = URLComponents(string: "https://slack.com/api/\(method)")!
            components.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            return request
        }
    }

    static func post(_ ws: SlackWorkspace, _ method: String, _ body: [String: Any]) async throws -> [String: Any] {
        let attempt = {
            try await authorized(ws, method) { token in
                var request = URLRequest(url: URL(string: "https://slack.com/api/\(method)")!)
                request.httpMethod = "POST"
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                request.timeoutInterval = 15
                return request
            }
        }
        do {
            return try await attempt()
        } catch let error as CallError where error.isRateLimit && error.retryAfterSeconds <= writeRetryCapSeconds {
            RealtimeLog.log("slack \(method): rate-limited, waiting \(error.retryAfterSeconds)s and retrying once")
            try await Task.sleep(for: .seconds(error.retryAfterSeconds))
            return try await attempt()
        }
    }

    /// Who a fresh token belongs to; no stored grant needed.
    static func authTest(token: String) async throws -> Identity {
        var request = URLRequest(url: URL(string: "https://slack.com/api/auth.test")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let json = try await send(request, method: "auth.test")
        guard let team = json["team_id"] as? String, let user = json["user_id"] as? String else {
            throw CallError(method: "auth.test", code: "missing_identity", status: 200, retryAfterSeconds: 0)
        }
        return Identity(teamId: team, teamName: json["team"] as? String ?? team, userId: user)
    }

    /// One request with the workspace's live token; a `token_expired` answer refreshes and retries once.
    private static func authorized(
        _ ws: SlackWorkspace, _ method: String, _ build: (String) throws -> URLRequest
    ) async throws -> [String: Any] {
        let credentials = Container.shared.slackCredentials()
        for attempt in 0..<2 {
            let token: String
            switch await credentials.token(teamId: ws.teamId) {
            case .success(let value): token = value
            case .failure(.needsReauth): throw CallError(method: method, code: "token_expired", status: 401, retryAfterSeconds: 0)
            case .failure(.notConnected): throw CallError(method: method, code: "not_connected", status: 401, retryAfterSeconds: 0)
            case .failure(.transient(let why)): throw CallError(method: method, code: "token_refresh_failed (\(why))", status: 0, retryAfterSeconds: 0)
            }
            do {
                return try await send(try build(token), method: method)
            } catch let error as CallError where error.code == "token_expired" && attempt == 0 {
                await credentials.expire(teamId: ws.teamId)
            }
        }
        throw CallError(method: method, code: "token_expired", status: 401, retryAfterSeconds: 0)
    }

    static func send(_ request: URLRequest, method: String) async throws -> [String: Any] {
        let (data, response) = try await Container.shared.slackHTTP().data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let retry = max(1, Int(http?.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1)
            throw CallError(method: method, code: status == 429 ? "ratelimited" : "http_\(status)",
                            status: status, retryAfterSeconds: retry)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CallError(method: method, code: "unreadable_response", status: status, retryAfterSeconds: 0)
        }
        guard json["ok"] as? Bool == true else {
            throw CallError(method: method, code: json["error"] as? String ?? "not ok", status: 200, retryAfterSeconds: 0)
        }
        return json
    }

    static func formBody(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(form.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
    }

    static func nextCursor(_ json: [String: Any]) -> String {
        (json["response_metadata"] as? [String: Any])?["next_cursor"] as? String ?? ""
    }
}
