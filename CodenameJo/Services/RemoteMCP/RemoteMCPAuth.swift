import AuthenticationServices
import FactoryKit
import Foundation
import UIKit

/// OAuth for a remote MCP server, entirely on the phone: discovery, dynamic registration as a
/// public client, PKCE sign-in, exchange, refresh and revocation. There is no client secret anywhere.
enum RemoteMCPAuth {
    /// What discovery learned about a server.
    struct Metadata: Equatable, Sendable {
        let resource: String
        let issuer: String
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let registrationEndpoint: URL?
        let revocationEndpoint: URL?
        let scopes: [String]
    }

    /// A token endpoint's answer.
    struct Tokens: Decodable, Equatable, Sendable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
        let scope: String?
    }

    enum Failure: Error, Equatable {
        /// `invalid_grant` or an unknown client: only a new sign-in fixes it.
        case revoked
        case failed(String)
    }

    enum SignInFailure: Error, Equatable {
        case cancelled
        case failed(String)
    }

    /// Assumed lifetime when a token response omits `expires_in`, short so renewal comes early.
    static let assumedLifetime: TimeInterval = 45 * 60

    // MARK: - Discovery

    /// The protected-resource document (path-suffixed first, then the origin's), then its first
    /// authorization server's metadata (RFC 8414, then OpenID's location).
    static func discover(_ service: RemoteMCPService,
                         transport: any HTTPDataTransport = Container.shared.providerHTTP()) async throws -> Metadata {
        var resource = service.endpoint.absoluteString
        var issuer = origin(of: service.endpoint)
        var scopes: [String] = []
        for url in wellKnown("oauth-protected-resource", for: service.endpoint) {
            guard let doc = try? await getJSON(url, transport) else { continue }
            if let value = doc["resource"] as? String { resource = value }
            if let server = (doc["authorization_servers"] as? [String])?.first { issuer = server }
            scopes = doc["scopes_supported"] as? [String] ?? []
            break
        }
        guard let issuerURL = URL(string: issuer) else { throw Failure.failed("bad issuer \(issuer)") }
        let candidates = wellKnown("oauth-authorization-server", for: issuerURL)
            + wellKnown("openid-configuration", for: issuerURL)
        for url in candidates {
            guard let doc = try? await getJSON(url, transport),
                  let authorize = (doc["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
                  let token = (doc["token_endpoint"] as? String).flatMap(URL.init(string:)) else { continue }
            return Metadata(
                resource: resource, issuer: doc["issuer"] as? String ?? issuer,
                authorizationEndpoint: authorize, tokenEndpoint: token,
                registrationEndpoint: (doc["registration_endpoint"] as? String).flatMap(URL.init(string:)),
                revocationEndpoint: (doc["revocation_endpoint"] as? String).flatMap(URL.init(string:)),
                scopes: scopes.isEmpty ? doc["scopes_supported"] as? [String] ?? [] : scopes)
        }
        throw Failure.failed("no authorization server metadata for \(service.id)")
    }

    /// `/.well-known/<name><path>` then `/.well-known/<name>`, per RFC 9728 and RFC 8414.
    static func wellKnown(_ name: String, for url: URL) -> [URL] {
        let base = origin(of: url)
        let path = url.path == "/" ? "" : url.path
        let candidates = (path.isEmpty ? [] : ["\(base)/.well-known/\(name)\(path)"]) + ["\(base)/.well-known/\(name)"]
        return candidates.compactMap(URL.init(string:))
    }

    private static func origin(of url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        return components.string ?? ""
    }

    private static func getJSON(_ url: URL, _ transport: any HTTPDataTransport) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.failed("no document at \(url.absoluteString)")
        }
        return json
    }

    // MARK: - Registration

    /// The stored client id when it was registered with this server and redirect, otherwise a new
    /// RFC 7591 registration as a public client.
    static func clientId(_ service: RemoteMCPService, metadata: Metadata,
                         transport: any HTTPDataTransport = Container.shared.providerHTTP()) async throws -> String {
        if let stored = RemoteMCPGrantStore.registration(service),
           stored.redirectURI == RemoteMCPService.redirectURI, stored.authorizationServer == metadata.issuer {
            return stored.clientId
        }
        guard let endpoint = metadata.registrationEndpoint else {
            throw Failure.failed("\(service.id) offers no dynamic client registration")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": service.clientName,
            "redirect_uris": [RemoteMCPService.redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "application_type": "native",
        ])
        let (data, response) = try await transport.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientId = json["client_id"] as? String, !clientId.isEmpty else {
            throw Failure.failed("registration answered \(status): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        RemoteMCPGrantStore.saveRegistration(.init(clientId: clientId, redirectURI: RemoteMCPService.redirectURI,
                                                   authorizationServer: metadata.issuer), service)
        RealtimeLog.log("\(service.id): registered client \(clientId)")
        return clientId
    }

    // MARK: - Authorize

    static func authorizeURL(_ metadata: Metadata, service: RemoteMCPService, clientId: String,
                             pkce: GoogleSignInFlow.PKCE, state: String) -> URL? {
        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)
        var items = (components?.queryItems ?? []) + [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: RemoteMCPService.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: metadata.resource),
        ]
        if let scope = service.scope ?? (metadata.scopes.isEmpty ? nil : metadata.scopes.joined(separator: " ")) {
            items.append(URLQueryItem(name: "scope", value: scope))
        }
        components?.queryItems = items
        return components?.url
    }

    /// What came back on the redirect: the code, or why there is none. `iss` is checked when the
    /// server sends it (RFC 9207), so a code from another server is never exchanged here.
    static func readCallback(_ url: URL, state: String, issuer: String) -> Result<String, SignInFailure> {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard item("state") == state else { return .failure(.failed("The sign-in didn't complete. Try again.")) }
        if let error = item("error") {
            return error == "access_denied" ? .failure(.cancelled) : .failure(.failed("The sign-in was refused (\(error))."))
        }
        if let iss = item("iss"), iss != issuer { return .failure(.failed("The sign-in came back from the wrong server.")) }
        guard let code = item("code"), !code.isEmpty else { return .failure(.failed("The sign-in returned no code.")) }
        return .success(code)
    }

    // MARK: - Tokens

    static func exchange(code: String, verifier: String, clientId: String, metadata: Metadata,
                         transport: any HTTPDataTransport = Container.shared.providerHTTP()) async -> Result<Tokens, Failure> {
        await token(metadata.tokenEndpoint, [
            "grant_type": "authorization_code", "code": code, "redirect_uri": RemoteMCPService.redirectURI,
            "client_id": clientId, "code_verifier": verifier, "resource": metadata.resource,
        ], transport)
    }

    static func refresh(_ grant: RemoteMCPGrant,
                        transport: any HTTPDataTransport = Container.shared.providerHTTP()) async -> Result<Tokens, Failure> {
        guard let refreshToken = grant.refreshToken, let endpoint = URL(string: grant.tokenEndpoint) else {
            return .failure(.revoked)
        }
        return await token(endpoint, [
            "grant_type": "refresh_token", "refresh_token": refreshToken,
            "client_id": grant.clientId, "resource": grant.resource,
        ], transport)
    }

    /// Best effort (RFC 7009): a failure leaves only a token the server will expire on its own.
    static func revoke(_ grant: RemoteMCPGrant, transport: any HTTPDataTransport = Container.shared.providerHTTP()) async {
        guard let endpoint = grant.revocationEndpoint.flatMap(URL.init(string:)) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(["token": grant.refreshToken ?? grant.accessToken,
                                     "token_type_hint": grant.refreshToken == nil ? "access_token" : "refresh_token",
                                     "client_id": grant.clientId])
        do {
            let (_, response) = try await transport.data(for: request)
            RealtimeLog.log("mcp revoke: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        } catch {
            RealtimeLog.log("mcp revoke: unavailable — \(error.localizedDescription)")
        }
    }

    /// Form-encoded with no Basic header: a public client proves itself with PKCE alone.
    private static func token(_ endpoint: URL, _ body: [String: String],
                              _ transport: any HTTPDataTransport) async -> Result<Tokens, Failure> {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formBody(body)
        do {
            let (data, response) = try await transport.data(for: request)
            return classify(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    static func classify(status: Int, body: Data) -> Result<Tokens, Failure> {
        if (200..<300).contains(status), let tokens = try? JSONDecoder().decode(Tokens.self, from: body),
           !tokens.access_token.isEmpty {
            return .success(tokens)
        }
        let code = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? String ?? "http_\(status)"
        if status == 400 || status == 401,
           ["invalid_grant", "invalid_client", "unauthorized_client"].contains(code) {
            return .failure(.revoked)
        }
        return .failure(.failed(code))
    }

    static func expiry(_ tokens: Tokens, now: Date = Date()) -> Date {
        let seconds = tokens.expires_in ?? 0
        return now.addingTimeInterval(seconds > 0 ? seconds : assumedLifetime)
    }

    static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
    }

    // MARK: - Sign-in

    /// Discover, register if needed, consent in the sheet, exchange; the caller stores the grant.
    /// An unknown client at the exchange drops the stored registration, so the next attempt re-registers.
    @MainActor
    static func signIn(_ service: RemoteMCPService, label: String, profileId: String?,
                       transport: any HTTPDataTransport = Container.shared.providerHTTP())
        async -> Result<RemoteMCPGrant, SignInFailure> {
        let metadata: Metadata, clientId: String
        do {
            metadata = try await discover(service, transport: transport)
            clientId = try await self.clientId(service, metadata: metadata, transport: transport)
        } catch {
            RealtimeLog.log("\(service.id) sign-in: setup failed — \(error)")
            return .failure(.failed("Couldn't reach \(service.displayName). Try again."))
        }
        let pkce = GoogleSignInFlow.PKCE()
        let state = GoogleSignInFlow.randomToken()
        guard let url = authorizeURL(metadata, service: service, clientId: clientId, pkce: pkce, state: state) else {
            return .failure(.failed("Couldn't start \(service.displayName) sign-in."))
        }
        let callback: URL
        do {
            callback = try await WebAuthSheet.present(url, callbackScheme: RemoteMCPService.callbackScheme)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return .failure(.cancelled)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
        let code: String
        switch readCallback(callback, state: state, issuer: metadata.issuer) {
        case .success(let value): code = value
        case .failure(let failure):
            RealtimeLog.log("\(service.id) sign-in: callback refused — \(failure)")
            return .failure(failure)
        }
        switch await exchange(code: code, verifier: pkce.verifier, clientId: clientId, metadata: metadata,
                              transport: transport) {
        case .failure(let failure):
            if failure == .revoked { RemoteMCPGrantStore.clearRegistration(service) }
            RealtimeLog.log("\(service.id) sign-in: exchange failed — \(failure)")
            return .failure(.failed("Couldn't finish connecting \(service.displayName). Try again."))
        case .success(let tokens):
            RealtimeLog.log("\(service.id) sign-in: connected — refresh token "
                + (tokens.refresh_token == nil ? "NOT issued" : "issued")
                + ", expires_in \(tokens.expires_in.map { String(Int($0)) } ?? "absent")")
            return .success(RemoteMCPGrant(
                id: UUID().uuidString, label: label, profileId: profileId,
                accessToken: tokens.access_token, refreshToken: tokens.refresh_token,
                expiresAt: expiry(tokens), clientId: clientId,
                tokenEndpoint: metadata.tokenEndpoint.absoluteString,
                revocationEndpoint: metadata.revocationEndpoint?.absoluteString,
                resource: metadata.resource, grantedAt: Date()))
        }
    }
}

/// `ASWebAuthenticationSession`, presented over the key window and awaited.
@MainActor
enum WebAuthSheet {
    private static var active: ASWebAuthenticationSession?
    private static let anchor = Anchor()

    static func present(_ url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
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

    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            MainActor.assumeIsolated {
                UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                    .first ?? ASPresentationAnchor()
            }
        }
    }
}
