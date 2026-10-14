import FactoryKit
import Foundation

/// GitHub's OAuth device flow: no client secret or redirect, so the token server stays Google-only.
/// GitHub answers its errors with a 200 and an `error` field; `slow_down` carries the new interval.
enum GitHubDeviceFlow {
    /// `repo` is the only scope that reaches private repos, and it carries write; `ALLOWED_TOOLS`
    /// in `GitHubTools` is what bounds the writes. `notifications` is separately scoped.
    static let scopes = "repo read:org read:user notifications"
    static let codeURL = URL(string: "https://github.com/login/device/code")!
    static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    static let grantType = "urn:ietf:params:oauth:grant-type:device_code"

    struct Code: Equatable, Sendable {
        let deviceCode: String
        let userCode: String
        let verificationURL: URL
        let expiresIn: TimeInterval
        let interval: TimeInterval
    }

    enum Failure: Error, Equatable {
        case cancelled
        /// The code ran out before the user entered it.
        case expired
        /// The user pressed Cancel on GitHub's page.
        case denied
        /// The OAuth App does not have "Enable Device Flow" ticked.
        case disabled
        case failed(String)

        var message: String? {
            switch self {
            case .cancelled: nil
            case .expired: "The GitHub code expired before it was entered. Try again."
            case .denied: "GitHub sign-in was cancelled."
            case .disabled: "This GitHub app doesn't allow device sign-in yet."
            case .failed(let reason): "GitHub sign-in failed (\(reason))."
            }
        }
    }

    enum Poll: Equatable {
        case token(String, scopes: [String])
        case pending
        case slowDown(interval: TimeInterval?)
        case failure(Failure)
    }

    struct Identity: Equatable {
        let id: String
        let login: String
    }

    // MARK: - Step 1: the code

    static func requestCode(clientID: String,
                            transport: any HTTPDataTransport = Container.shared.githubHTTP()) async -> Result<Code, Failure> {
        guard !clientID.isEmpty else { return .failure(.failed("no_client_id")) }
        do {
            let (data, response) = try await transport.data(for: form(codeURL, ["client_id": clientID, "scope": scopes]))
            return classifyCode(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    static func classifyCode(status: Int, body: Data) -> Result<Code, Failure> {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        if let error = json["error"] as? String {
            return .failure(error == "device_flow_disabled" ? .disabled : .failed(error))
        }
        guard status == 200,
              let device = json["device_code"] as? String, let user = json["user_code"] as? String,
              let uri = (json["verification_uri"] as? String).flatMap(URL.init(string:))
        else { return .failure(.failed(status == 404 ? "unknown_client_id" : "http_\(status)")) }
        return .success(Code(deviceCode: device, userCode: user, verificationURL: uri,
                             expiresIn: number(json["expires_in"]) ?? 900, interval: max(number(json["interval"]) ?? 5, 1)))
    }

    // MARK: - Step 3: polling

    static func classifyPoll(status: Int, body: Data) -> Poll {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        if let token = json["access_token"] as? String, !token.isEmpty {
            let scopes = (json["scope"] as? String ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            return .token(token, scopes: scopes)
        }
        switch json["error"] as? String {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown(interval: number(json["interval"]))
        case "expired_token": return .failure(.expired)
        case "access_denied": return .failure(.denied)
        case "device_flow_disabled": return .failure(.disabled)
        case let error?: return .failure(.failed(error))
        case nil: return .failure(.failed("http_\(status)"))
        }
    }

    /// Polls no faster than GitHub's interval until a token, refusal, expiry or cancellation.
    /// A network error is retried: the phone may simply be switching to Safari and back.
    static func waitForToken(
        _ code: Code, clientID: String,
        transport: any HTTPDataTransport = Container.shared.githubHTTP(),
        now: () -> Date = Date.init,
        sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) async -> Result<(token: String, scopes: [String]), Failure> {
        let deadline = now().addingTimeInterval(code.expiresIn)
        var interval = code.interval
        let request = form(tokenURL, ["client_id": clientID, "device_code": code.deviceCode, "grant_type": grantType])
        while true {
            do { try await sleep(interval) } catch { return .failure(.cancelled) }
            if Task.isCancelled { return .failure(.cancelled) }
            if now() >= deadline { return .failure(.expired) }
            let poll: Poll
            do {
                let (data, response) = try await transport.data(for: request)
                poll = classifyPoll(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data)
            } catch {
                if Task.isCancelled { return .failure(.cancelled) }
                RealtimeLog.log("github device flow: poll unavailable — \(error.localizedDescription)")
                continue
            }
            switch poll {
            case .token(let token, let scopes): return .success((token, scopes))
            case .pending: continue
            case .slowDown(let next):
                interval = next ?? interval + 5
                RealtimeLog.log("github device flow: slow_down — polling every \(Int(interval))s")
            case .failure(let failure): return .failure(failure)
            }
        }
    }

    // MARK: - Who signed in

    static func identify(token: String,
                         transport: any HTTPDataTransport = Container.shared.githubHTTP()) async -> Result<Identity, Failure> {
        do {
            let user = try await GitHubAPI(token: token, allowWrites: false, transport: transport).object("/user")
            guard let login = user["login"] as? String, let id = number(user["id"]) else {
                return .failure(.failed("no_login"))
            }
            return .success(Identity(id: String(Int(id)), login: login))
        } catch {
            return .failure(.failed(GitHubAPI.explain(error)))
        }
    }

    // MARK: -

    private static func form(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Without it GitHub answers form-encoded.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        return request
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }
}
