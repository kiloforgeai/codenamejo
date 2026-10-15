import AuthenticationServices
import CryptoKit
import FactoryKit
import Foundation
import UIKit

/// The hosted token server: it adds the web client's secret to Google's token calls, which an
/// open-source app cannot ship. It records each signed-in account's email and nothing else; every
/// grant lives in this Keychain.
enum GoogleTokenServer {
    static var baseURL: URL? {
        AppHosts.tokenServer.isEmpty ? nil : URL(string: "https://\(AppHosts.tokenServer)")
    }
    static var isConfigured: Bool { baseURL != nil }

    /// Google's token response, passed through unchanged by the server.
    struct Tokens: Decodable, Sendable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
        let scope: String?
        let id_token: String?

        var scopes: [String]? {
            let list = (scope ?? "").split(separator: " ").map(String.init)
            return list.isEmpty ? nil : list
        }
    }

    enum Failure: Error, Equatable {
        /// `invalid_grant`, or `unauthorized_client` for a token another client issued.
        case revoked
        case failed(String)
    }

    static func exchange(code: String, verifier: String) async -> Result<Tokens, Failure> {
        await post("api/google/exchange", ["code": code, "verifier": verifier])
    }

    static func refresh(_ refreshToken: String) async -> Result<Tokens, Failure> {
        await post("api/google/refresh", ["refresh_token": refreshToken])
    }

    /// Straight to Google: revoking needs no secret.
    static func revoke(_ token: String) async {
        var components = URLComponents(string: "https://oauth2.googleapis.com/revoke")
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        do {
            let (_, response) = try await Container.shared.tokenServerHTTP().data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            RealtimeLog.log("google revoke: HTTP \(status)")
        } catch {
            RealtimeLog.log("google revoke: unavailable — \(error.localizedDescription)")
        }
    }

    /// Reads a token response. Only Google's own refusal of the grant is `revoked`; anything else
    /// (the network, a 5xx, the kill switch, a rate limit) may answer differently next time.
    static func classify(status: Int, body: Data) -> Result<Tokens, Failure> {
        if status == 200, let tokens = try? JSONDecoder().decode(Tokens.self, from: body) {
            return .success(tokens)
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let code = json?["error"] as? String ?? "http_\(status)"
        if status == 400 || status == 401, code == "invalid_grant" || code == "unauthorized_client" {
            return .failure(.revoked)
        }
        return .failure(.failed(code))
    }

    private static func post(_ path: String, _ body: [String: String]) async -> Result<Tokens, Failure> {
        guard let base = baseURL else { return .failure(.failed("token_server_not_configured")) }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await Container.shared.tokenServerHTTP().data(for: request)
            return classify(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data)
        } catch {
            return .failure(.failed((error as NSError).localizedDescription))
        }
    }
}

/// One Google consent in `ASWebAuthenticationSession`, through the token server. The PKCE verifier
/// stays on the phone until the exchange; the grant goes straight into `GoogleAccountStore`.
@MainActor
enum GoogleSignInFlow {
    /// The scheme the token server's callback page returns to (`aurex://google-auth`).
    static let callbackScheme = "aurex"

    struct Outcome {
        /// The address that consented, lowercased — not necessarily the one hinted at.
        let email: String
        let scopes: [String]
        /// Google's profile name, for the greeting and for knowing who "you" is in a summary.
        let displayName: String?
    }

    enum Failure: Error {
        /// Dismissed the sheet or declined on Google's screen. Not an error to surface.
        case cancelled
        case failed(String)
    }

    /// A PKCE pair: a 43-character base64url verifier and its S256 challenge.
    struct PKCE {
        let verifier: String
        let challenge: String

        init(verifier: String = randomToken()) {
            self.verifier = verifier
            challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }
    }

    /// The claims read from the `id_token`. It came straight from Google over TLS in the
    /// exchange response, so it is decoded, not verified.
    struct Identity: Equatable {
        let email: String
        let sub: String?
        let name: String?

        init?(idToken: String) {
            let parts = idToken.split(separator: ".")
            guard parts.count >= 2 else { return nil }
            var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            guard let data = Data(base64Encoded: b64),
                  let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let email = claims["email"] as? String, !email.isEmpty else { return nil }
            self.email = email.lowercased()
            sub = claims["sub"] as? String
            let name = (claims["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.name = name?.isEmpty == false ? name : nil
        }
    }

    static func startURL(base: URL, pkce: PKCE, state: String, hint: String?) -> URL? {
        var components = URLComponents(url: base.appendingPathComponent("api/google/start"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "challenge", value: pkce.challenge),
                                  URLQueryItem(name: "state", value: state)]
            + (hint.map { [URLQueryItem(name: "login_hint", value: $0)] } ?? [])
        return components?.url
    }

    /// Run the consent and store the grant. A later account never displaces the primary.
    static func run(hint: String?, isPrimary: Bool) async -> Result<Outcome, Failure> {
        guard let base = GoogleTokenServer.baseURL else {
            return .failure(.failed("Google sign-in isn't set up in this build."))
        }
        let pkce = PKCE()
        let state = randomToken()
        guard let url = startURL(base: base, pkce: pkce, state: state, hint: hint) else {
            return .failure(.failed("Couldn't start Google sign-in."))
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
            RealtimeLog.log("google sign-in: callback state did not match")
            return .failure(.failed("Google sign-in didn't complete. Try again."))
        }
        if let error = item("error") {
            RealtimeLog.log("google sign-in: Google returned \(error)")
            return error == "access_denied" ? .failure(.cancelled)
                : .failure(.failed("Google sign-in didn't complete. Try again."))
        }
        guard let code = item("code") else { return .failure(.failed("Google didn't return a code.")) }

        let tokens: GoogleTokenServer.Tokens
        switch await GoogleTokenServer.exchange(code: code, verifier: pkce.verifier) {
        case .success(let value): tokens = value
        case .failure(let failure):
            RealtimeLog.log("google sign-in: exchange failed — \(failure)")
            return .failure(.failed("Couldn't finish connecting Google. Try again."))
        }
        guard let refreshToken = tokens.refresh_token, !refreshToken.isEmpty,
              let identity = tokens.id_token.flatMap(Identity.init(idToken:)) else {
            RealtimeLog.log("google sign-in: exchange carried no refresh token or identity")
            return .failure(.failed("Google didn't return a usable grant. Try again."))
        }

        let scopes = tokens.scopes ?? []
        // Reconnecting the primary keeps it primary.
        let isPrimary = isPrimary || GoogleAccountStore.grant(for: identity.email)?.isPrimary == true
        let grant = GoogleAccountStore.Grant(
            email: identity.email, refreshToken: refreshToken, scopes: scopes, grantedAt: Date(),
            isPrimary: isPrimary, sub: identity.sub, displayName: identity.name)
        guard GoogleAccountStore.save(grant) else {
            return .failure(.failed("Couldn't save the Google grant on this phone."))
        }
        if isPrimary { GoogleAccountStore.makePrimary(identity.email) }
        GoogleCredential.cache(accessToken: tokens.access_token, for: identity.email,
                               expiresIn: tokens.expires_in ?? 3_600)
        RealtimeLog.log("google sign-in: saved grant for \(identity.email) (primary: \(isPrimary))")
        // The one place a consent's `grantedAt` is written, so the one place to start
        // watching for Google's notice about it.
        GrantAlertSweep.arm()
        return .success(Outcome(email: identity.email, scopes: scopes, displayName: identity.name))
    }

    // MARK: - Presenting

    private static var active: ASWebAuthenticationSession?
    private static let anchor = PresentationAnchor()

    private static func present(_ url: URL) async throws -> URL {
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

    private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            MainActor.assumeIsolated {
                UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                    .first ?? ASPresentationAnchor()
            }
        }
    }

    // MARK: - Randomness

    nonisolated static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
