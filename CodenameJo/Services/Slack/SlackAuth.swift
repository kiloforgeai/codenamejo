import AuthenticationServices
import FactoryKit
import Foundation
import Security
import UIKit

/// The Slack app this build signs in with, from `JO_SLACK_CLIENT_ID` in the xcconfig. Empty hides
/// the connector: a public client needs only its id, and there is no secret anywhere.
enum SlackConfig {
    static let clientId = (Bundle.main.object(forInfoDictionaryKey: "JoSlackClientId") as? String ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    static var isConfigured: Bool { !clientId.isEmpty }

    /// The app's own redirect. Slack accepts a custom scheme only with PKCE, as a desktop redirect.
    static let redirectURI = "com.kiloforge.codenamejo://oauth/callback"
    static let callbackScheme = "com.kiloforge.codenamejo"

    static let authorizeURL = URL(string: "https://slack.com/oauth/v2_user/authorize")!
    static let tokenURL = URL(string: "https://slack.com/api/oauth.v2.user.access")!

    /// User scopes only (a desktop redirect may not ask for bot scopes). The four `*:write` are
    /// what `conversations.mark` needs; nothing here creates or archives a channel.
    static let scopes = [
        "channels:history", "groups:history", "im:history", "mpim:history",
        "channels:read", "groups:read", "im:read", "mpim:read",
        "users:read", "users:read.email",
        "search:read",
        "chat:write", "reactions:write",
        "channels:write", "groups:write", "im:write", "mpim:write",
    ]

    /// With PKCE on, every refresh token Slack issues dies 30 days after it was issued.
    static let refreshTokenLifetime: TimeInterval = 30 * 86_400
}

/// One connected Slack workspace: a user token that rotates every 12 hours, and the refresh
/// token that renews it. Lives in the Keychain, never on a server.
struct SlackGrant: Codable, Sendable, Equatable {
    let teamId: String
    var teamName: String
    let userId: String
    var accessToken: String
    var refreshToken: String?
    var accessExpiresAt: Date?
    /// When the current refresh token was issued; the 30-day clock runs from here.
    var refreshIssuedAt: Date?
    /// Comma- or space-separated, exactly as Slack granted it.
    var scopes: String
    /// The profile it was connected under; nil serves every profile.
    var profileId: String?
    let connectedAt: Date
    /// Slack refused the refresh, or the refresh token outlived its 30 days.
    var needsReauth: Bool? = nil

    /// Whether this grant may move a read cursor. An empty grant is unknown, treated as yes.
    var canMark: Bool { SlackGrant.grantsMarking(scopes) }

    static let markScopes = ["channels:write", "groups:write", "im:write", "mpim:write"]

    static func grantsMarking(_ scopes: String) -> Bool {
        guard !scopes.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        let granted = Set(scopes.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init))
        return markScopes.allSatisfy(granted.contains)
    }

    func refreshExpired(now: Date = Date()) -> Bool {
        guard refreshToken != nil, let issued = refreshIssuedAt else { return false }
        return now.timeIntervalSince(issued) >= SlackConfig.refreshTokenLifetime
    }

    func served(in profileId: String?) -> Bool {
        guard let mine = self.profileId, let profileId else { return true }
        return mine == profileId
    }
}

protocol SlackGrantStorage: Sendable {
    func all() -> [SlackGrant]
    @discardableResult func save(_ grant: SlackGrant) -> Bool
    func remove(_ teamId: String)
    func removeAll()
}

/// Every Slack grant on this phone, one Keychain item per workspace.
enum SlackGrantStore {
    static func all() -> [SlackGrant] { Container.shared.slackGrantStorage().all() }
    static func grant(teamId: String) -> SlackGrant? { all().first { $0.teamId == teamId } }
    @discardableResult static func save(_ grant: SlackGrant) -> Bool { Container.shared.slackGrantStorage().save(grant) }
    static func remove(_ teamId: String) { Container.shared.slackGrantStorage().remove(teamId) }
    static func removeAll() { Container.shared.slackGrantStorage().removeAll() }

    /// The active profile's workspaces.
    static func inProfile(_ profileId: String? = ProfileRuntime.snapshot?.profileId) -> [SlackGrant] {
        all().filter { $0.served(in: profileId) }
    }

    static func markNeedsReauth(_ teamId: String) {
        guard var grant = grant(teamId: teamId), grant.needsReauth != true else { return }
        grant.needsReauth = true
        save(grant)
        RealtimeLog.log("slack: \(grant.teamName) needs reconnecting")
    }
}

struct KeychainSlackGrantStorage: SlackGrantStorage {
    private static let service = "kiloforge.slack.grant"

    func all() -> [SlackGrant] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let rows = item as? [Data] else {
            if status != errSecItemNotFound { RealtimeLog.log("slack store: read failed — OSStatus \(status)") }
            return []
        }
        return rows.compactMap { try? JSONDecoder().decode(SlackGrant.self, from: $0) }
            .sorted { $0.teamName.localizedCaseInsensitiveCompare($1.teamName) == .orderedAscending }
    }

    @discardableResult
    func save(_ grant: SlackGrant) -> Bool {
        guard let data = try? JSONEncoder().encode(grant) else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: grant.teamId,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { RealtimeLog.log("slack store: save failed — OSStatus \(status)") }
        return status == errSecSuccess
    }

    func remove(_ teamId: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: teamId,
        ] as CFDictionary)
    }

    func removeAll() {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ] as CFDictionary)
        switch status {
        case errSecSuccess: RealtimeLog.log("credential cleanup: Slack grants — deleted")
        case errSecItemNotFound: RealtimeLog.log("credential cleanup: Slack grants — already absent")
        default: RealtimeLog.log("credential cleanup: Slack grants — deletion failed; OSStatus \(status)")
        }
    }
}

/// Slack's token endpoint, called straight from the phone with no secret (PKCE public client).
enum SlackOAuth {
    /// What `oauth.v2.user.access` answers, for a code or a refresh.
    struct Tokens: Equatable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?
        let scope: String
        let teamId: String?
        let userId: String?
    }

    enum Failure: Error, Equatable {
        /// The refresh token is dead or revoked; only a new consent fixes it.
        case revoked(String)
        case failed(String)
    }

    /// Slack's codes for a refresh token it will never honour again.
    static let revokedCodes: Set<String> = [
        "invalid_refresh_token", "invalid_grant", "token_expired", "token_revoked", "invalid_auth",
        "refresh_token_expired", "account_inactive",
    ]

    static func authorizeURL(pkce: GoogleSignInFlow.PKCE, state: String) -> URL? {
        var components = URLComponents(url: SlackConfig.authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: SlackConfig.clientId),
            URLQueryItem(name: "scope", value: SlackConfig.scopes.joined(separator: ",")),
            URLQueryItem(name: "redirect_uri", value: SlackConfig.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components?.url
    }

    static func exchange(code: String, verifier: String) async -> Result<Tokens, Failure> {
        await post(["grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                    "redirect_uri": SlackConfig.redirectURI, "client_id": SlackConfig.clientId])
    }

    static func refresh(_ refreshToken: String) async -> Result<Tokens, Failure> {
        await post(["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": SlackConfig.clientId])
    }

    /// Both response shapes: `oauth.v2.user.access` puts the user token at the top level,
    /// `oauth.v2.access` nests it under `authed_user`.
    static func parse(_ json: [String: Any]) -> Result<Tokens, Failure> {
        guard json["ok"] as? Bool == true else {
            let code = json["error"] as? String ?? "not_ok"
            return .failure(revokedCodes.contains(code) ? .revoked(code) : .failed(code))
        }
        let user = json["authed_user"] as? [String: Any] ?? [:]
        func field(_ key: String) -> Any? { json[key] ?? user[key] }
        guard let access = (json["access_token"] as? String) ?? (user["access_token"] as? String),
              !access.isEmpty else { return .failure(.failed("no_access_token")) }
        let expires = (field("expires_in") as? NSNumber)?.doubleValue
        return .success(Tokens(
            accessToken: access, refreshToken: field("refresh_token") as? String, expiresIn: expires,
            scope: (json["scope"] as? String) ?? (user["scope"] as? String) ?? "",
            teamId: (json["team"] as? [String: Any])?["id"] as? String,
            userId: (user["id"] as? String) ?? (json["user_id"] as? String)))
    }

    private static func post(_ form: [String: String]) async -> Result<Tokens, Failure> {
        var request = URLRequest(url: SlackConfig.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = SlackWebAPI.formBody(form)
        request.timeoutInterval = 20
        do {
            let (data, response) = try await Container.shared.slackHTTP().data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .failure(.failed("http_\(status)"))
            }
            return parse(json)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    /// Best effort; a failed revoke still drops this phone's copy.
    static func revoke(_ grant: SlackGrant) async {
        var request = URLRequest(url: URL(string: "https://slack.com/api/auth.revoke")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(grant.accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        do {
            let (data, _) = try await Container.shared.slackHTTP().data(for: request)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            RealtimeLog.log("slack revoke: \(grant.teamName) — \(json?["ok"] as? Bool == true ? "revoked" : (json?["error"] as? String ?? "unknown"))")
        } catch {
            RealtimeLog.log("slack revoke: unavailable — \(error.localizedDescription)")
        }
    }
}

/// Hands out a live access token per workspace, refreshing (and rotating) it when it is near
/// expiry. One refresh per workspace at a time: a rotated refresh token is single-use.
actor SlackCredentials {
    enum Failure: Error, Equatable {
        case notConnected
        case needsReauth
        case transient(String)
    }

    private var inFlight: [String: Task<Result<String, Failure>, Never>] = [:]

    func token(teamId: String, now: Date = Date()) async -> Result<String, Failure> {
        if let running = inFlight[teamId] { return await running.value }
        guard let grant = SlackGrantStore.grant(teamId: teamId) else { return .failure(.notConnected) }
        if grant.needsReauth == true { return .failure(.needsReauth) }
        guard let refreshToken = grant.refreshToken else { return .success(grant.accessToken) }
        if let expiry = grant.accessExpiresAt, expiry.timeIntervalSince(now) > 120 {
            return .success(grant.accessToken)
        }
        if grant.refreshExpired(now: now) {
            SlackGrantStore.markNeedsReauth(teamId)
            return .failure(.needsReauth)
        }
        let task = Task { await Self.refresh(grant, refreshToken: refreshToken) }
        inFlight[teamId] = task
        let result = await task.value
        inFlight[teamId] = nil
        return result
    }

    /// Forget the access token's expiry so the next `token` refreshes. For a `token_expired` answer.
    func expire(teamId: String) {
        guard var grant = SlackGrantStore.grant(teamId: teamId), grant.refreshToken != nil else { return }
        grant.accessExpiresAt = .distantPast
        SlackGrantStore.save(grant)
    }

    private static func refresh(_ grant: SlackGrant, refreshToken: String) async -> Result<String, Failure> {
        switch await SlackOAuth.refresh(refreshToken) {
        case .success(let tokens):
            var renewed = grant
            renewed.accessToken = tokens.accessToken
            renewed.refreshToken = tokens.refreshToken ?? refreshToken
            if tokens.refreshToken != nil { renewed.refreshIssuedAt = Date() }
            renewed.accessExpiresAt = tokens.expiresIn.map { Date().addingTimeInterval($0) }
            if !tokens.scope.isEmpty { renewed.scopes = tokens.scope }
            guard SlackGrantStore.save(renewed) else { return .failure(.transient("keychain_save_failed")) }
            RealtimeLog.log("slack: refreshed \(grant.teamName)")
            return .success(tokens.accessToken)
        case .failure(.revoked(let code)):
            RealtimeLog.log("slack: refresh refused for \(grant.teamName) — \(code)")
            SlackGrantStore.markNeedsReauth(grant.teamId)
            return .failure(.needsReauth)
        case .failure(.failed(let code)):
            RealtimeLog.log("slack: refresh failed for \(grant.teamName) — \(code)")
            return .failure(.transient(code))
        }
    }
}

/// One Slack consent in `ASWebAuthenticationSession`, PKCE with no secret, straight to Slack.
@MainActor
enum SlackSignInFlow {
    enum Failure: Error, Equatable {
        case cancelled
        case failed(String)
    }

    static func run(profileId: String?) async -> Result<SlackGrant, Failure> {
        guard SlackConfig.isConfigured else { return .failure(.failed("Slack isn't set up in this build.")) }
        let pkce = GoogleSignInFlow.PKCE()
        let state = GoogleSignInFlow.randomToken()
        guard let url = SlackOAuth.authorizeURL(pkce: pkce, state: state) else {
            return .failure(.failed("Couldn't start Slack sign-in."))
        }
        let callback: URL
        do {
            callback = try await present(url)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return .failure(.cancelled)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard item("state") == state else {
            RealtimeLog.log("slack sign-in: callback state did not match")
            return .failure(.failed("Slack sign-in didn't complete. Try again."))
        }
        if let error = item("error") {
            RealtimeLog.log("slack sign-in: Slack returned \(error)")
            return error == "access_denied" ? .failure(.cancelled)
                : .failure(.failed("Slack sign-in didn't complete. Try again."))
        }
        guard let code = item("code") else { return .failure(.failed("Slack didn't return a code.")) }

        let tokens: SlackOAuth.Tokens
        switch await SlackOAuth.exchange(code: code, verifier: pkce.verifier) {
        case .success(let value): tokens = value
        case .failure(let failure):
            RealtimeLog.log("slack sign-in: exchange failed — \(failure)")
            return .failure(.failed("Couldn't finish connecting Slack. Try again."))
        }
        let identity: SlackWebAPI.Identity
        do {
            identity = try await SlackWebAPI.authTest(token: tokens.accessToken)
        } catch {
            RealtimeLog.log("slack sign-in: auth.test failed — \(error)")
            return .failure(.failed("Slack didn't say which workspace this is. Try again."))
        }
        let now = Date()
        let grant = SlackGrant(
            teamId: identity.teamId, teamName: identity.teamName, userId: identity.userId,
            accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
            accessExpiresAt: tokens.expiresIn.map { now.addingTimeInterval($0) },
            refreshIssuedAt: tokens.refreshToken == nil ? nil : now, scopes: tokens.scope,
            profileId: profileId, connectedAt: now)
        guard SlackGrantStore.save(grant) else { return .failure(.failed("Couldn't save the Slack grant on this phone.")) }
        RealtimeLog.log("slack sign-in: saved \(identity.teamName) (rotating: \(tokens.refreshToken != nil))")
        return .success(grant)
    }

    private static var active: ASWebAuthenticationSession?
    private static let anchor = PresentationAnchor()

    private static func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: SlackConfig.callbackScheme) { callback, error in
                MainActor.assumeIsolated {
                    active = nil
                    if let callback { continuation.resume(returning: callback) }
                    else { continuation.resume(throwing: error ?? URLError(.badServerResponse)) }
                }
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = false
            active = session
            if !session.start() {
                active = nil
                continuation.resume(throwing: URLError(.cannotOpenFile))
            }
        }
    }

    private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            MainActor.assumeIsolated {
                UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                    .first ?? ASPresentationAnchor()
            }
        }
    }
}
