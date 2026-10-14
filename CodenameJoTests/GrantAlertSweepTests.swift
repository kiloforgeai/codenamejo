// coverage-target: CodenameJo/Services/BackgroundRefresh/GrantAlertSweep.swift

import FactoryKit
import Foundation
import XCTest

@testable import CodenameJo

/// The sweep that archives Google's own "a new app has access" notice so onboarding's queue
/// opens on the mail Jo put there rather than on an alert about Jo.
///
/// Three things here can only be wrong quietly. The **search is bounded** — one sender, one
/// mailbox, nothing older than the grant and never more than an hour back — and a sweep that
/// widened would archive somebody else's security alert, which is the one piece of mail this
/// app must never touch. The **refusal is a distinct answer**: a throttled search that read as
/// "nothing found" would spend the watch's attempts on a question Gmail never answered. And a
/// **sweep runs per account with that account's own token**, because a notice in one mailbox
/// must not be archived with another mailbox's grant.
///
/// Every boundary below is stubbed at the container: `googleGrantStorage` for the grant,
/// `googleTokenProvider` for the token, `providerHTTP` for Gmail. Nothing here reaches the
/// Keychain or the network.
@MainActor
final class GrantAlertSweepTests: XCTestCase {

    // MARK: - Harness

    private var grants: SweepGrantStorage!
    private var tokens: SweepTokenProvider!

    override func setUp() async throws {
        try await super.setUp()
        grants = SweepGrantStorage()
        tokens = SweepTokenProvider()
        let grants = grants!
        let tokens = tokens!
        Container.shared.googleGrantStorage.register { grants }
        Container.shared.googleTokenProvider.register { MainActor.assumeIsolated { tokens } }
        // A no-op store: `dropUnread` must not reach the app's own SQLite file from a test.
        Container.shared.mailStore.register { MailStore(database: nil, userId: "sweep-tests") }
    }

    override func tearDown() async throws {
        Container.shared.googleGrantStorage.reset()
        Container.shared.googleTokenProvider.reset()
        Container.shared.mailStore.reset()
        Container.shared.providerHTTP.reset()
        grants = nil
        tokens = nil
        try await super.tearDown()
    }

    /// Connect `email`, granted `secondsAgo` ago, with a working token.
    @discardableResult
    private func connect(_ email: String, secondsAgo: TimeInterval = 60) -> Date {
        let grantedAt = Date().addingTimeInterval(-secondsAgo)
        grants.store(
            GoogleAccountStore.Grant(
                email: email, refreshToken: "refresh-\(email)",
                scopes: ["https://www.googleapis.com/auth/gmail.modify"],
                grantedAt: grantedAt, isPrimary: grants.all().isEmpty))
        tokens.tokens[email] = "access-\(email)"
        return grantedAt
    }

    /// A Gmail that lists `notices` for every search and accepts every archive.
    @discardableResult
    private func serveNotices(_ notices: [String: [String]], searchStatus: Int = 200) -> ScriptedGmail {
        install { call in
            if call.method == "POST", call.path.hasSuffix("/modify") { return (200, "application/json", "{}") }
            guard searchStatus == 200 else { return (searchStatus, "application/json", "{}") }
            let ids = notices[call.bearerToken] ?? []
            return (200, "application/json", ScriptedGmail.messageList(ids))
        }
    }

    @discardableResult
    private func install(
        _ respond: @escaping @Sendable (ScriptedGmail.Call) -> (Int, String, String)
    ) -> ScriptedGmail {
        let gmail = ScriptedGmail(respond: respond)
        Container.shared.providerHTTP.register { gmail }
        return gmail
    }

    private func archivedCount(_ pass: GrantAlertSweep.Pass) -> Int? {
        if case .archived(let count) = pass { return count }
        return nil
    }

    // MARK: - Nothing to sweep

    /// The phone may hold no Google grant at all — an Apple-only account, or a sign-in that
    /// never reached the connect step. The sweep has to answer "nothing" without spending a
    /// request, because a request without a grant is a request with no token behind it.
    func testAPhoneWithNoGoogleGrantSweepsNothingAndAsksGmailNothing() async {
        let gmail = serveNotices([:])

        let pass = await GrantAlertSweep.run()

        guard case .empty = pass else { return XCTFail("expected empty, got \(pass)") }
        XCTAssertTrue(gmail.calls.isEmpty, "no grant means no Gmail request at all")
    }

    /// A grant whose token cannot be refreshed is the revoked case. It must stop at the token,
    /// not send an unauthenticated search that Gmail would answer with a 401.
    func testAGrantWithNoUsableTokenNeverReachesGmail() async {
        connect("sam@example.com")
        tokens.tokens.removeAll()
        let gmail = serveNotices([:])

        let pass = await GrantAlertSweep.run()

        guard case .empty = pass else { return XCTFail("expected empty, got \(pass)") }
        XCTAssertTrue(gmail.calls.isEmpty, "a sweep with no token must not call Gmail")
    }

    /// A mailbox Google has not written to yet. Empty and throttled are different answers and
    /// only one of them is worth another attempt.
    func testAMailboxWithNoNoticeIsEmptyRatherThanThrottled() async {
        connect("sam@example.com")
        serveNotices(["access-sam@example.com": []])

        let pass = await GrantAlertSweep.run()

        guard case .empty = pass else { return XCTFail("expected empty, got \(pass)") }
    }

    // MARK: - The search

    /// One sender, this mailbox's inbox, and a cap. Each clause is what keeps the sweep off
    /// mail it has no business archiving.
    func testTheSearchIsBoundedToGooglesOwnNoticesInTheInbox() async {
        connect("sam@example.com")
        let gmail = serveNotices(["access-sam@example.com": []])

        _ = await GrantAlertSweep.run()

        let search = try? XCTUnwrap(gmail.calls.first)
        let query = search?.query["q"] ?? ""
        XCTAssertTrue(query.contains("from:no-reply@accounts.google.com"), "got \(query)")
        XCTAssertTrue(query.contains("in:inbox"), "got \(query)")
        XCTAssertEqual(search?.query["maxResults"], "5", "one consent makes one or two notices")
    }

    /// `grantedAt` is the floor for a fresh consent: a notice older than the consent cannot
    /// be about it.
    func testARecentGrantBoundsTheSearchAtTheMomentOfConsent() async {
        let grantedAt = connect("sam@example.com", secondsAgo: 120)
        let gmail = serveNotices(["access-sam@example.com": []])

        _ = await GrantAlertSweep.run()

        XCTAssertEqual(
            after(in: gmail.calls.first), Int(grantedAt.timeIntervalSince1970),
            "a consent two minutes ago bounds the search at that consent")
    }

    /// And an old grant does not let the search reach back over the user's whole history —
    /// an hour is the furthest it may go, whatever the stored consent says.
    func testAnOldGrantIsStillBoundedToTheLastHour() async {
        let grantedAt = connect("sam@example.com", secondsAgo: 86_400)
        let before = Date()
        let gmail = serveNotices(["access-sam@example.com": []])

        _ = await GrantAlertSweep.run()

        let bound = try? XCTUnwrap(after(in: gmail.calls.first))
        XCTAssertNotNil(bound)
        XCTAssertGreaterThan(
            Double(bound ?? 0), grantedAt.timeIntervalSince1970,
            "a day-old consent must not open a day-wide search")
        XCTAssertEqual(
            Double(bound ?? 0), before.addingTimeInterval(-3600).timeIntervalSince1970,
            accuracy: 5, "the window is an hour")
    }

    // MARK: - Archiving

    func testTheNoticeFoundIsTheMessageArchived() async {
        connect("sam@example.com")
        let gmail = serveNotices(["access-sam@example.com": ["notice-1"]])

        let pass = await GrantAlertSweep.run()

        XCTAssertEqual(archivedCount(pass), 1)
        XCTAssertEqual(
            gmail.calls.filter { $0.method == "POST" }.map(\.path),
            ["messages/notice-1/modify"])
    }

    /// Two mailboxes, two notices, and the token that archives each one has to be that
    /// mailbox's own — archiving with the wrong grant is a 404 at best and the wrong
    /// mailbox's mail at worst.
    func testEachMailboxIsSweptWithItsOwnToken() async {
        connect("sam@example.com")
        connect("dana@example.com")
        let gmail = serveNotices([
            "access-sam@example.com": ["sam-notice"],
            "access-dana@example.com": ["dana-notice"],
        ])

        let pass = await GrantAlertSweep.run()

        XCTAssertEqual(archivedCount(pass), 2)
        let archives = gmail.calls.filter { $0.method == "POST" }
        XCTAssertEqual(
            Set(archives.map { "\($0.bearerToken)→\($0.path)" }),
            ["access-sam@example.com→messages/sam-notice/modify",
             "access-dana@example.com→messages/dana-notice/modify"])
    }

    // MARK: - Refusals

    /// A refused search is not an empty mailbox. The caller rides out a refusal and backs off
    /// the shared bucket; reading it as empty would burn one of six attempts on a question
    /// Gmail never answered.
    func testARefusedSearchIsThrottledRatherThanEmpty() async {
        connect("sam@example.com")
        serveNotices([:], searchStatus: 429)

        let pass = await GrantAlertSweep.run()

        guard case .throttled = pass else { return XCTFail("expected throttled, got \(pass)") }
    }

    /// A 403 that names a rate limit is the same refusal wearing a different code — Gmail
    /// sends both for a per-user limit, and reading this one as a revoked grant would stop
    /// the watch rather than slow it.
    func testARateLimitedForbiddenIsAlsoARefusal() async {
        connect("sam@example.com")
        install { _ in (403, "application/json", #"{"error":{"message":"rateLimitExceeded"}}"#) }

        let pass = await GrantAlertSweep.run()

        guard case .throttled = pass else { return XCTFail("expected throttled, got \(pass)") }
    }

    /// Anything else — a 500, a shape change — is a failure the watch should not treat as a
    /// rate limit, because backing off the shared Gmail bucket for it would slow the rest of
    /// the phone's mail work for no reason.
    func testAServerErrorIsNotReadAsARefusal() async {
        connect("sam@example.com")
        install { _ in (500, "application/json", "{}") }

        let pass = await GrantAlertSweep.run()

        guard case .empty = pass else { return XCTFail("expected empty, got \(pass)") }
    }

    /// A refusal partway through still reports the notices that did get archived — those
    /// writes happened, and a `.throttled` here would have the caller retry an archive that
    /// already landed.
    func testARefusalAfterOneArchiveStillReportsTheArchiveThatLanded() async {
        connect("sam@example.com")
        let gmail = install { call in
            if call.method == "POST" {
                return call.path.contains("notice-2")
                    ? (429, "application/json", "{}")
                    : (200, "application/json", "{}")
            }
            return (200, "application/json", ScriptedGmail.messageList(["notice-1", "notice-2"]))
        }

        let pass = await GrantAlertSweep.run()

        XCTAssertEqual(archivedCount(pass), 1, "one of the two archives landed")
        XCTAssertEqual(
            gmail.calls.filter { $0.method == "POST" }.count, 2,
            "the refusal ends the pass rather than retrying inside it")
    }

    // MARK: - Bits

    /// Gmail's `after:` clause as epoch seconds, out of the recorded search.
    private func after(in call: ScriptedGmail.Call?) -> Int? {
        guard let query = call?.query["q"],
              let range = query.range(of: "after:") else { return nil }
        return Int(query[range.upperBound...].prefix { $0.isNumber })
    }
}

// MARK: - Stubs

/// In-memory stand-in for the Keychain-backed grant store.
private final class SweepGrantStorage: GoogleGrantStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var grants: [GoogleAccountStore.Grant] = []

    func store(_ grant: GoogleAccountStore.Grant) {
        lock.lock()
        grants.append(grant)
        lock.unlock()
    }

    func all() -> [GoogleAccountStore.Grant] {
        lock.lock()
        defer { lock.unlock() }
        return grants
    }

    func save(_ grant: GoogleAccountStore.Grant) -> Bool {
        store(grant)
        return true
    }

    func remove(_ email: String) {
        lock.lock()
        grants.removeAll { $0.email == email }
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        grants.removeAll()
        lock.unlock()
    }
}

/// Hands out a predictable access token per mailbox, or refuses.
private final class SweepTokenProvider: GoogleTokenProvider {
    var tokens: [String: String] = [:]


    func token(
        for email: String?, requiredScopes: [String]
    ) async -> Result<GoogleCredential.Token, GoogleCredential.Failure> {
        guard let email, let access = tokens[email] else { return .failure(.noStoredGrant) }
        return .success(.init(accessToken: access, email: email, scopes: requiredScopes))
    }
}

/// A Gmail that answers from a closure and records what it was asked.
final class ScriptedGmail: HTTPDataTransport, @unchecked Sendable {
    struct Call: Sendable {
        let method: String
        /// The path under `users/me`, or the raw path for the batch endpoint.
        let path: String
        let query: [String: String]
        /// The `Authorization` header with `Bearer ` taken off.
        let bearerToken: String
        let body: String
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let respond: @Sendable (Call) -> (status: Int, contentType: String, body: String)

    init(respond: @escaping @Sendable (Call) -> (Int, String, String)) {
        self.respond = respond
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value }
        let call = Call(
            method: request.httpMethod ?? "GET",
            path: url.path.replacingOccurrences(of: "/gmail/v1/users/me/", with: ""),
            query: query,
            bearerToken: (request.value(forHTTPHeaderField: "Authorization") ?? "")
                .replacingOccurrences(of: "Bearer ", with: ""),
            body: String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        lock.lock()
        recorded.append(call)
        lock.unlock()

        let answer = respond(call)
        let response = HTTPURLResponse(
            url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": answer.contentType])!
        return (Data(answer.body.utf8), response)
    }

    /// `messages.list` as Gmail answers it, with the field mask these callers ask for.
    static func messageList(_ ids: [String], nextPageToken: String? = nil) -> String {
        let messages = ids
            .map { #"{"id":"\#($0)","threadId":"\#($0)-thread"}"# }
            .joined(separator: ",")
        let cursor = nextPageToken.map { #","nextPageToken":"\#($0)""# } ?? ""
        return #"{"messages":[\#(messages)]\#(cursor)}"#
    }
}
