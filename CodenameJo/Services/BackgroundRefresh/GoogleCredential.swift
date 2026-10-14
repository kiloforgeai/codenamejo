import Foundation
import FactoryKit

/// A usable Google access token for a mailbox this phone holds a grant for, read without
/// showing anything.
///
/// Reads `GoogleAccountStore`, one grant per mailbox, and refreshes through the token server
/// (`GoogleTokenServer`). Refreshing is a plain POST so it can never want UI.
@MainActor
enum GoogleCredential {
    /// Why a non-interactive read couldn't produce a usable token. Typed because the cases
    /// want different responses and only `transient` is worth retrying.
    enum Failure: Error {
        /// Never connected, or signed out. The honest answer for an Apple-only account.
        case noStoredGrant

        /// Google refused to renew it (`invalid_grant`). Nobody can re-consent in the background,
        /// so stop rescheduling.
        case grantRevoked

        /// Valid credential, no mail scope — the consent screen lets boxes be unticked.
        case scopesMissing(granted: [String])

        /// Anything else — almost always the network. The one case worth retrying.
        case transient(String)
    }

    /// What a successful read hands back.
    struct Token {
        let accessToken: String
        /// Always populated: grants are keyed by address.
        let email: String?
        /// What was granted, not what was asked for — so a check can name what's missing.
        let scopes: [String]
    }

    /// What a mail prefetch cannot proceed without. Deliberately narrower than what the consent
    /// asks for: someone who unticked calendar should still get their mail.
    static let requiredScopes = ["https://www.googleapis.com/auth/gmail.modify"]

    /// What a calendar sync cannot proceed without. Kept separate from `requiredScopes` so
    /// unticking one service at consent doesn't block the other.
    static let calendarScopes = ["https://www.googleapis.com/auth/calendar.readonly"]

    /// Which mailboxes this phone can act on.
    static func storedAccounts() -> [String] { GoogleAccountStore.emails() }

    // MARK: - Tokens

    /// A fresh access token for one mailbox (omit `email` for the primary), or a typed reason there isn't one.
    /// Cached in memory until a minute before expiry; calendar callers pass `calendarScopes`.
    static func token(
        for email: String? = nil, requiredScopes: [String] = Self.requiredScopes
    ) async -> Result<Token, Failure> {
        await Container.shared.googleTokenProvider().token(for: email, requiredScopes: requiredScopes)
    }

    static func liveToken(for email: String?, requiredScopes: [String]) async -> Result<Token, Failure> {
        let grant: GoogleAccountStore.Grant?
        if let email {
            grant = GoogleAccountStore.grant(for: email)
        } else {
            grant = GoogleAccountStore.primary()
        }
        guard let grant else { return .failure(.noStoredGrant) }
        // Refused once is refused until the user reconnects, which replaces the grant.
        if grant.needsReauth == true { return .failure(.grantRevoked) }

        if let cached = cachedAccessTokens[grant.email], cached.expiry > Date().addingTimeInterval(60) {
            return finish(
                accessToken: cached.token, grant: grant, scopes: grant.scopes,
                requiredScopes: requiredScopes)
        }

        switch await refresh(grant) {
        case .success(let refreshed):
            cachedAccessTokens[grant.email] = (refreshed.accessToken, refreshed.expiry)
            // Trust Google's echoed scope over the stored copy — a grant can be narrowed
            // outside this app, and the stale copy would claim a capability that 403s.
            let scopes = refreshed.scopes ?? grant.scopes
            if scopes != grant.scopes {
                var narrowed = grant
                narrowed.scopes = scopes
                GoogleAccountStore.save(narrowed)
            }
            return finish(
                accessToken: refreshed.accessToken, grant: grant, scopes: scopes,
                requiredScopes: requiredScopes)
        case .failure(let failure):
            // Dead for good: marked rather than removed, so Settings still has a row to reconnect.
            if case .grantRevoked = failure {
                cachedAccessTokens[grant.email] = nil
                GoogleAccountStore.markNeedsReauth(grant.email)
            }
            return .failure(failure)
        }
    }

    private static func finish(
        accessToken: String,
        grant: GoogleAccountStore.Grant,
        scopes: [String],
        requiredScopes: [String]
    ) -> Result<Token, Failure> {
        guard requiredScopes.allSatisfy(scopes.contains) else {
            return .failure(.scopesMissing(granted: scopes))
        }
        return .success(Token(accessToken: accessToken, email: grant.email, scopes: scopes))
    }

    /// Access tokens by mailbox, with the moment they stop being usable.
    private static var cachedAccessTokens: [String: (token: String, expiry: Date)] = [:]

    /// The access token a consent's exchange already returned, so the first read needs no refresh.
    static func cache(accessToken: String, for email: String, expiresIn: Double) {
        cachedAccessTokens[email.lowercased()] = (accessToken, Date().addingTimeInterval(expiresIn))
    }

    /// Called when a grant is replaced, so a scope-widening reconnect doesn't keep serving
    /// the narrow token for another hour.
    static func invalidateCache(for email: String? = nil) {
        if let email {
            cachedAccessTokens[email.lowercased()] = nil
        } else {
            cachedAccessTokens.removeAll()
        }
    }

    // MARK: - Permission

    /// Can this phone read mail, and for whom — without fetching any. Separate from a sync's
    /// own failure, which can't distinguish a missing grant from an empty inbox.
    struct Permission {
        /// The only field to branch on.
        let canReadMail: Bool
        /// One diagnostics line — who, and what is missing.
        let summary: String
    }

    static func permission(for email: String? = nil) async -> Permission {
        switch await token(for: email) {
        case .success(let token):
            let account = token.email ?? "the signed-in account"
            // Named, not counted: "4 scopes" says nothing about which.
            let hasCalendar = token.scopes.contains {
                $0.hasPrefix("https://www.googleapis.com/auth/calendar")
            }
            return Permission(
                canReadMail: true,
                summary: "\(account) — mail\(hasCalendar ? " + calendar" : "")"
            )
        case .failure(let failure):
            let who = email.map { "\($0): " } ?? ""
            let summary: String
            switch failure {
            case .noStoredGrant:
                summary = "No Google grant on this device — connect an account"
            case .grantRevoked:
                summary = "Google revoked the grant — reconnect"
            case .scopesMissing:
                // A choice, not a fault — mail can be unticked at consent.
                summary = "Connected, but mail was not granted"
            case .transient(let detail):
                summary = "Couldn't check — \(detail)"
            }
            return Permission(canReadMail: false, summary: who + summary)
        }
    }

    /// One line per mailbox, for the diagnostics section. Never empty — with no grant it
    /// falls through to the primary check, whose failure summary is the answer.
    static func permissions() async -> [Permission] {
        let primary = await permission()
        let others = storedAccounts().filter { $0 != GoogleAccountStore.primary()?.email }
        guard !others.isEmpty else { return [primary] }
        var results = [primary]
        for email in others {
            results.append(await permission(for: email))
        }
        return results
    }

    // MARK: - Refresh

    private struct Refreshed {
        let accessToken: String
        let expiry: Date
        let scopes: [String]?
    }

    /// Trade a refresh token for an access token through the token server, which adds the web
    /// client's secret. Going direct rather than through a session is what lets any mailbox refresh.
    private static func refresh(_ grant: GoogleAccountStore.Grant) async -> Result<Refreshed, Failure> {
        switch await GoogleTokenServer.refresh(grant.refreshToken) {
        case .success(let tokens):
            return .success(Refreshed(
                accessToken: tokens.access_token,
                expiry: Date().addingTimeInterval(tokens.expires_in ?? 3_600),
                scopes: tokens.scopes))
        case .failure(.revoked):
            return .failure(.grantRevoked)
        case .failure(.failed(let code)):
            return .failure(.transient(code))
        }
    }
}

extension GoogleCredential.Failure {
    /// Whether waking again could produce a different answer. Drives rescheduling.
    var isWorthRetrying: Bool {
        switch self {
        case .transient: return true
        case .noStoredGrant, .grantRevoked, .scopesMissing: return false
        }
    }

    /// Safe to persist — no token material, no mail, no address.
    var logLabel: String {
        switch self {
        case .noStoredGrant: return "no_stored_grant"
        case .grantRevoked: return "grant_revoked"
        case .scopesMissing: return "scopes_missing"
        case .transient(let detail): return "transient(\(detail))"
        }
    }
}
