import FactoryKit
import XCTest
@testable import CodenameJo

/// Slack's Web API, answered from a closure keyed by method name.
final class ScriptedSlack: HTTPDataTransport, @unchecked Sendable {
    struct Call: Sendable {
        let method: String
        let params: [String: String]
        let body: [String: String]
        let token: String
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let respond: @Sendable (Call) -> (status: Int, json: [String: Any])

    init(respond: @escaping @Sendable (Call) -> (Int, [String: Any])) { self.respond = respond }

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        var params: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { params[item.name] = item.value }
        var body: [String: String] = [:]
        if let data = request.httpBody {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                body = json.mapValues { "\($0)" }
            } else {
                for pair in String(decoding: data, as: UTF8.self).split(separator: "&") {
                    let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                    if parts.count == 2 { body[parts[0]] = parts[1] }
                }
            }
        }
        let call = Call(method: url.lastPathComponent, params: params, body: body,
                        token: (request.value(forHTTPHeaderField: "Authorization") ?? "").replacingOccurrences(of: "Bearer ", with: ""))
        lock.withLock { recorded.append(call) }
        let (status, json) = respond(call)
        return (try JSONSerialization.data(withJSONObject: json),
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "1"])!)
    }
}

final class MemorySlackGrants: SlackGrantStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var grants: [String: SlackGrant] = [:]
    func all() -> [SlackGrant] { lock.lock(); defer { lock.unlock() }; return grants.values.sorted { $0.teamId < $1.teamId } }
    func save(_ grant: SlackGrant) -> Bool { lock.lock(); grants[grant.teamId] = grant; lock.unlock(); return true }
    func remove(_ teamId: String) { lock.lock(); grants[teamId] = nil; lock.unlock() }
    func removeAll() { lock.lock(); grants = [:]; lock.unlock() }
}

final class SlackConnectorTests: XCTestCase {
    private var grants: MemorySlackGrants!

    override func setUp() async throws {
        try await super.setUp()
        grants = MemorySlackGrants()
        let grants = grants!
        Container.shared.slackGrantStorage.register { grants }
        Container.shared.slackCredentials.register { SlackCredentials() }
    }

    override func tearDown() async throws {
        Container.shared.slackGrantStorage.reset()
        Container.shared.slackCredentials.reset()
        Container.shared.slackHTTP.reset()
        try await super.tearDown()
    }

    private func grant(access: String = "xoxe.xoxp-old", refresh: String? = "xoxe-1-old",
                       expiresIn: TimeInterval = 3600, issuedDaysAgo: Double = 1,
                       scopes: String = "channels:history,channels:write,groups:write,im:write,mpim:write") -> SlackGrant {
        SlackGrant(teamId: "T1", teamName: "Acme", userId: "U0", accessToken: access, refreshToken: refresh,
                   accessExpiresAt: Date().addingTimeInterval(expiresIn),
                   refreshIssuedAt: Date().addingTimeInterval(-issuedDaysAgo * 86_400),
                   scopes: scopes, profileId: nil, connectedAt: Date())
    }

    private func serve(_ respond: @escaping @Sendable (ScriptedSlack.Call) -> (Int, [String: Any])) -> ScriptedSlack {
        let slack = ScriptedSlack(respond: respond)
        Container.shared.slackHTTP.register { slack }
        return slack
    }

    // MARK: - Sign-in

    func testTheConsentURLIsAUserOnlyPKCERequestToTheAppRedirect() throws {
        let pkce = GoogleSignInFlow.PKCE(verifier: "secretpassword")
        let url = try XCTUnwrap(SlackOAuth.authorizeURL(pkce: pkce, state: "s1"))
        XCTAssertEqual(url.host, "slack.com")
        XCTAssertEqual(url.path, "/oauth/v2_user/authorize")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["redirect_uri"], "com.kiloforge.codenamejo://oauth/callback")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        // Slack's own example pair, from its PKCE guide.
        XCTAssertEqual(items["code_challenge"], "ldMBaaWcQYtSATMV_IG8mf3wp7A6EW80arYoSW80ntU")
        XCTAssertEqual(items["state"], "s1")
        XCTAssertNil(items["user_scope"], "user scopes go in `scope` on the v2_user endpoint")
        let scopes = Set(items["scope"]?.split(separator: ",").map(String.init) ?? [])
        XCTAssertTrue(scopes.isSuperset(of: ["channels:history", "im:read", "chat:write", "im:write", "search:read"]))
        XCTAssertNil(items["client_secret"])
    }

    func testBothTokenResponseShapesParse() {
        let top: [String: Any] = ["ok": true, "access_token": "xoxe.xoxp-1", "refresh_token": "xoxe-1-r",
                                  "expires_in": 43200, "scope": "chat:write", "team": ["id": "T1"],
                                  "authed_user": ["id": "U9"]]
        XCTAssertEqual(try? SlackOAuth.parse(top).get(),
                       .init(accessToken: "xoxe.xoxp-1", refreshToken: "xoxe-1-r", expiresIn: 43200,
                             scope: "chat:write", teamId: "T1", userId: "U9"))
        let nested: [String: Any] = ["ok": true, "team": ["id": "T1"],
                                     "authed_user": ["id": "U9", "access_token": "xoxp-2", "scope": "im:read",
                                                     "refresh_token": "xoxe-1-n", "expires_in": 100]]
        XCTAssertEqual(try? SlackOAuth.parse(nested).get().refreshToken, "xoxe-1-n")
        XCTAssertEqual(try? SlackOAuth.parse(nested).get().accessToken, "xoxp-2")
        guard case .failure(.revoked("invalid_refresh_token")) = SlackOAuth.parse(["ok": false, "error": "invalid_refresh_token"]) else {
            return XCTFail("a dead refresh token is a revocation")
        }
        guard case .failure(.failed("ratelimited")) = SlackOAuth.parse(["ok": false, "error": "ratelimited"]) else {
            return XCTFail("a rate limit is not a revocation")
        }
    }

    func testMarkingNeedsAllFourWriteScopesWhicheverSeparator() {
        XCTAssertTrue(SlackGrant.grantsMarking("channels:write,groups:write,im:write,mpim:write,chat:write"))
        XCTAssertTrue(SlackGrant.grantsMarking("channels:write groups:write im:write mpim:write"))
        XCTAssertFalse(SlackGrant.grantsMarking("channels:write,groups:write,im:write"))
        XCTAssertTrue(SlackGrant.grantsMarking(""), "an unrecorded grant is unknown, not missing")
    }

    // MARK: - Rotation and the 30-day expiry

    func testAFreshAccessTokenIsServedWithoutACall() async {
        grants.save(grant())
        let slack = serve { _ in (500, [:]) }
        let token = await SlackCredentials().token(teamId: "T1")
        XCTAssertEqual(try? token.get(), "xoxe.xoxp-old")
        XCTAssertTrue(slack.calls.isEmpty)
    }

    func testAnExpiringTokenRefreshesWithoutASecretAndStoresTheRotatedPair() async {
        grants.save(grant(expiresIn: 30))
        let slack = serve { call in
            XCTAssertEqual(call.method, "oauth.v2.user.access")
            return (200, ["ok": true, "access_token": "xoxe.xoxp-new", "refresh_token": "xoxe-1-new",
                          "expires_in": 43200, "token_type": "user"])
        }
        let credentials = SlackCredentials()
        async let first = credentials.token(teamId: "T1")
        async let second = credentials.token(teamId: "T1")
        let tokens = await [first, second]
        XCTAssertEqual(tokens.compactMap { try? $0.get() }, ["xoxe.xoxp-new", "xoxe.xoxp-new"])
        XCTAssertEqual(slack.calls.count, 1, "a rotated refresh token is single-use: one refresh at a time")
        let call = slack.calls[0]
        XCTAssertEqual(call.body["grant_type"], "refresh_token")
        XCTAssertEqual(call.body["refresh_token"], "xoxe-1-old")
        XCTAssertNil(call.body["client_secret"])
        let stored = SlackGrantStore.grant(teamId: "T1")
        XCTAssertEqual(stored?.refreshToken, "xoxe-1-new")
        XCTAssertEqual(stored?.accessToken, "xoxe.xoxp-new")
        XCTAssertGreaterThan(stored?.refreshIssuedAt ?? .distantPast, Date().addingTimeInterval(-60))
    }

    func testARefusedRefreshNeedsTheUser() async {
        grants.save(grant(expiresIn: -10))
        _ = serve { _ in (200, ["ok": false, "error": "invalid_refresh_token"]) }
        let token = await SlackCredentials().token(teamId: "T1")
        XCTAssertEqual(token, .failure(.needsReauth))
        XCTAssertEqual(SlackGrantStore.grant(teamId: "T1")?.needsReauth, true)
        XCTAssertEqual(SlackWorkspace.served(profileId: nil), [], "a broken workspace serves no tools")
    }

    func testARefreshTokenPastThirtyDaysNeedsTheUserWithoutAskingSlack() async {
        grants.save(grant(expiresIn: -10, issuedDaysAgo: 31))
        let slack = serve { _ in (200, ["ok": true, "access_token": "x"]) }
        let token = await SlackCredentials().token(teamId: "T1")
        XCTAssertEqual(token, .failure(.needsReauth))
        XCTAssertTrue(slack.calls.isEmpty)
    }

    func testANetworkFailureIsTransientAndKeepsTheGrant() async {
        grants.save(grant(expiresIn: -10))
        _ = serve { _ in (503, [:]) }
        let token = await SlackCredentials().token(teamId: "T1")
        XCTAssertEqual(token, .failure(.transient("http_503")))
        XCTAssertNil(SlackGrantStore.grant(teamId: "T1")?.needsReauth)
    }

    func testAWorkspaceIsServedOnlyInTheProfileItWasConnectedUnder() {
        var work = grant()
        work.profileId = "work"
        grants.save(work)
        XCTAssertEqual(SlackWorkspace.served(profileId: "work").map(\.teamId), ["T1"])
        XCTAssertEqual(SlackWorkspace.served(profileId: "personal"), [])
    }

    // MARK: - Ranking and bands

    private func signals(kind: String = "channel", unread: Int = 1, latestMs: Double = 0, mentions: Bool = false,
                         asks: Bool = false, bots: Bool = false, broadcast: Bool = false) -> SlackRank.Signals {
        .init(kind: kind, unread: unread, more: false, latestMs: latestMs, mentionsUser: mentions, broadcast: broadcast,
              userPosted: false, replyInUserThread: false, allBots: bots, asksSomething: asks)
    }

    func testAMentionAndADirectQuestionOutrankAVolumeOfChatter() {
        let now = Date().timeIntervalSince1970 * 1000
        let rooms = [("random", signals(unread: 240, latestMs: now)),
                     ("dm", signals(kind: "dm", latestMs: now - 7_200_000, asks: true)),
                     ("eng", signals(latestMs: now - 3_600_000 * 3, mentions: true)),
                     ("alerts", signals(unread: 50, latestMs: now, bots: true))]
        let ranked = SlackRank.rank(rooms, signals: \.1, now: now).map(\.item.0)
        XCTAssertEqual(ranked, ["dm", "eng", "random", "alerts"])
        XCTAssertTrue(SlackRank.score(rooms[2].1, now: now).why.contains("they mentioned you"))
    }

    func testBandsAreBoundedByWhatThePageProves() {
        let now = Date().timeIntervalSince1970 * 1000
        XCTAssertEqual(SlackImportance.bandFor(signals(bots: true), verdict: "high", now: now), "normal")
        XCTAssertEqual(SlackImportance.bandFor(signals(kind: "dm"), verdict: "low", now: now), "normal")
        XCTAssertEqual(SlackImportance.bandFor(signals(latestMs: now - 8 * 86_400_000), verdict: "high", now: now), "normal")
        XCTAssertEqual(SlackImportance.bandFor(signals(mentions: true), verdict: nil, now: now), "high", "the prior when unscored")
        XCTAssertEqual(SlackImportance.parse(#"{"verdicts":[{"n":1,"band":"high"},{"n":2,"band":"urgent"},{"n":9,"band":"low"}]}"#, count: 2),
                       [0: "high"])
    }

    func testTheModelsVerdictsBandTheQueueAndAFailureFallsBackToPriors() async {
        let now = Date().timeIntervalSince1970 * 1000
        let batch = [SlackImportance.Scorable(label: "a", messages: [("Sam", "ok")], signals: signals()),
                     SlackImportance.Scorable(label: "b", messages: [], signals: signals(mentions: true))]
        let said = await SlackImportance.bands(batch, now: now) { prompt, _ in
            XCTAssertTrue(prompt.contains("untrusted data"))
            return #"{"verdicts":[{"n":1,"band":"high"},{"n":2,"band":"low"}]}"#
        }
        XCTAssertEqual(said, ["high", "normal"])
        struct Down: Error {}
        let fallback = await SlackImportance.bands(batch, now: now) { _, _ in throw Down() }
        XCTAssertEqual(fallback, ["normal", "high"])
    }

    func testSlackMarkupBecomesSpeakable() {
        let text = "<@U1> asked in <#C1|eng> about <https://x.test|the deploy> &amp; <!here> <#C2>"
        XCTAssertEqual(SlackSweep.speakable(text, users: ["U1": "Sam"], channels: ["C2": "the ops channel"]),
                       "@Sam asked in the eng channel about the deploy & @here the ops channel")
        XCTAssertTrue(SlackSweep.mentions("hey <@U0|me> look", user: "U0"))
        XCTAssertFalse(SlackSweep.mentions("hey <@U01> look", user: "U0"))
    }

    // MARK: - The sweep

    func testTheSweepQueuesUnreadConversationsAndReportsWhatItCouldNotSee() async {
        grants.save(grant())
        let now = Date().timeIntervalSince1970
        _ = serve { call in
            switch call.method {
            case "users.conversations":
                return (200, ["ok": true, "channels": [
                    ["id": "C1", "name": "eng"], ["id": "D1", "is_im": true, "user": "U2"],
                    ["id": "C2", "name": "quiet"]]])
            case "conversations.info":
                switch call.params["channel"] {
                case "C1": return (200, ["ok": true, "channel": ["id": "C1", "name": "eng", "last_read": "100.000001"]])
                case "C2": return (200, ["ok": true, "channel": ["id": "C2", "name": "quiet", "last_read": "100.000001"]])
                default: return (200, ["ok": true, "channel": ["id": "D1", "is_im": true, "user": "U2", "last_read": "0000000000.000000"]])
                }
            case "conversations.history":
                if call.params["channel"] == "C2" { return (200, ["ok": true, "messages": [["user": "U3", "subtype": "channel_join", "ts": "\(now)"]]]) }
                return (200, ["ok": true, "messages": [
                    ["user": "U2", "text": "<@U0> can you review?", "ts": "\(now)"],
                    ["user": "U0", "text": "on it", "ts": "\(now - 10)"]]])
            case "users.info":
                return (200, ["ok": true, "user": ["id": call.params["user"] ?? "", "name": "sam", "profile": ["display_name": "Sam"]]])
            default:
                return (200, ["ok": false, "error": "unknown_method"])
            }
        }
        let queue = await SlackSweep.buildQueue([SlackWorkspace(grant())], model: nil)
        XCTAssertEqual(queue.items.map(\.channelId), ["C1"], "a join is not unread and DMs withheld their bookmark")
        let item = queue.items[0]
        XCTAssertEqual(item.label, "the eng channel")
        XCTAssertEqual(item.unread, 1, "the user's own message is not unread")
        XCTAssertEqual(item.messages.first?.text, "@Sam can you review?")
        XCTAssertEqual(item.band, "high")
        XCTAssertEqual(queue.report.readStateUnknown, 1)
        XCTAssertEqual(queue.report.unchecked, 0)
        XCTAssertNil(queue.report.markUnavailable)
        XCTAssertEqual(queue.workspaces, ["Acme"])
    }

    func testDMsAreProbedBeforeTheBudgetRunsOutOnChannels() async {
        grants.save(grant())
        let now = Date().timeIntervalSince1970
        let channels = (1...60).map { ["id": "C\($0)", "name": "chan\($0)"] as [String: Any] }
        let slack = serve { call in
            switch call.method {
            case "users.conversations":
                return (200, ["ok": true, "channels": channels + [["id": "D1", "is_im": true, "user": "U2"]]])
            case "conversations.info":
                let id = call.params["channel"] ?? ""
                return id == "D1"
                    ? (200, ["ok": true, "channel": ["id": "D1", "is_im": true, "user": "U2", "last_read": "100.000001"]])
                    : (200, ["ok": true, "channel": ["id": id, "name": id, "last_read": "100.000001"]])
            case "conversations.history":
                if call.params["channel"] != "D1" { return (200, ["ok": true, "messages": []]) }
                return (200, ["ok": true, "messages": [["user": "U2", "text": "got a sec?", "ts": "\(now)"]]])
            case "users.info":
                return (200, ["ok": true, "user": ["id": "U2", "name": "sam", "profile": ["display_name": "Sam"]]])
            default:
                return (200, ["ok": false, "error": "unknown_method"])
            }
        }
        let queue = await SlackSweep.buildQueue([SlackWorkspace(grant())], model: nil)
        XCTAssertEqual(queue.items.map(\.channelId), ["D1"], "a DM listed after 60 channels is still asked about")
        XCTAssertEqual(queue.items.first?.label, "Sam")
        XCTAssertEqual(queue.report.unchecked, 11)
        XCTAssertEqual(slack.calls.filter { $0.method == "conversations.history" }.count, SlackSweep.maxProbes)
    }

    func testADMWithoutABookmarkFallsBackToItsUnreadCount() async {
        grants.save(grant())
        let now = Date().timeIntervalSince1970
        let slack = serve { call in
            switch call.method {
            case "users.conversations":
                return (200, ["ok": true, "channels": [
                    ["id": "D1", "is_im": true, "user": "U2"], ["id": "D2", "is_im": true, "user": "U3"]]])
            case "conversations.info":
                return call.params["channel"] == "D1"
                    ? (200, ["ok": true, "channel": ["id": "D1", "is_im": true, "user": "U2",
                                                     "last_read": "0000000000.000000", "unread_count_display": 2]])
                    : (200, ["ok": true, "channel": ["id": "D2", "is_im": true, "user": "U3",
                                                     "last_read": "0000000000.000000", "unread_count_display": 0]])
            case "conversations.history":
                return (200, ["ok": true, "has_more": true, "messages": [
                    ["user": "U2", "text": "are you around?", "ts": "\(now)"],
                    ["user": "U2", "text": "quick one", "ts": "\(now - 5)"]]])
            case "users.info":
                return (200, ["ok": true, "user": ["id": "U2", "name": "sam", "profile": ["display_name": "Sam"]]])
            default:
                return (200, ["ok": false, "error": "unknown_method"])
            }
        }
        let queue = await SlackSweep.buildQueue([SlackWorkspace(grant())], model: nil)
        XCTAssertEqual(queue.items.map(\.channelId), ["D1"])
        XCTAssertEqual(queue.items.first?.unread, 2)
        XCTAssertEqual(queue.items.first?.more, false, "older history is not more unread")
        XCTAssertEqual(queue.report.readStateUnknown, 0, "a zero count is known: nothing unread")
        let history = slack.calls.filter { $0.method == "conversations.history" }
        XCTAssertEqual(history.map { $0.params["channel"] }, ["D1"], "a DM with nothing unread costs no history call")
        XCTAssertEqual(history.first?.params["limit"], "2")
        XCTAssertNil(history.first?.params["oldest"])
    }

    func testDMsSkippedForWithheldBookmarksLeaveTheBudgetToChannels() async {
        grants.save(grant())
        let dms = (1...60).map { ["id": "D\($0)", "is_im": true, "user": "U\($0)"] as [String: Any] }
        _ = serve { call in
            switch call.method {
            case "users.conversations":
                return (200, ["ok": true, "channels": dms + [["id": "C1", "name": "eng"]]])
            case "conversations.info":
                let id = call.params["channel"] ?? ""
                return id == "C1"
                    ? (200, ["ok": true, "channel": ["id": "C1", "name": "eng", "last_read": "100.000001"]])
                    : (200, ["ok": true, "channel": ["id": id, "is_im": true, "last_read": "0000000000.000000"]])
            case "conversations.history":
                return (200, ["ok": true, "messages": [["user": "U9", "text": "ship it", "ts": "\(Date().timeIntervalSince1970)"]]])
            default:
                return (200, ["ok": false, "error": "unknown_method"])
            }
        }
        let queue = await SlackSweep.buildQueue([SlackWorkspace(grant())], model: nil)
        XCTAssertEqual(queue.items.map(\.channelId), ["C1"], "skipping DMs spends no probes, so the channel is reached")
        XCTAssertEqual(queue.report.readStateUnknown, 60)
        XCTAssertEqual(queue.report.unchecked, 0)
    }

    func testAWorkspaceThatCannotBeListedIsNamedNotEmpty() async {
        grants.save(grant())
        _ = serve { _ in (200, ["ok": false, "error": "invalid_auth"]) }
        let queue = await SlackSweep.buildQueue([SlackWorkspace(grant())], model: nil)
        XCTAssertEqual(queue.report.workspacesUnavailable, ["Acme"])
        XCTAssertEqual(queue.workspaces, [])
    }

    // MARK: - Tools

    func testAReplyInTheQueuedConversationAlsoMarksItRead() async {
        grants.save(grant())
        let slack = serve { call in
            switch call.method {
            case "chat.postMessage": return (200, ["ok": true, "channel": "C0ENG01", "ts": "200.1"])
            case "conversations.mark": return (200, ["ok": true])
            case "conversations.info": return (200, ["ok": true, "channel": ["id": "C0ENG01", "name": "eng"]])
            default: return (200, ["ok": false, "error": "unknown_method"])
            }
        }
        let result = await SlackTools.run(
            name: "slack_send_message", input: ["channel_id": "C0ENG01", "message": "on it", "thread_ts": "150.0"],
            markTarget: .init(teamId: "T1", channelId: "C0ENG01", ts: "199.0", label: "the eng channel"), workspaces: [SlackWorkspace(grant())])
        XCTAssertTrue(result.written)
        XCTAssertEqual(result.markedRead, true)
        XCTAssertEqual(result.text, "Sent in the thread in the eng channel on Acme.")
        XCTAssertEqual(slack.calls.first { $0.method == "conversations.mark" }?.body["ts"], "199.0")
        XCTAssertEqual(slack.calls.first { $0.method == "chat.postMessage" }?.token, "xoxe.xoxp-old")
        XCTAssertNil(slack.calls.first { $0.method == "conversations.info" }, "the queue's label needs no lookup")
    }

    func testRefusalsAreSpokenAndWriteNothing() async {
        XCTAssertEqual(SlackTools.refusal("slack_read_channel", [:], []),
                       "No Slack workspace is connected. Ask the user to connect Slack in Settings.")
        let ws = SlackWorkspace(teamId: "T1", teamName: "Acme", userId: "U0", scopes: "chat:write")
        XCTAssertTrue(SlackTools.refusal("slack_add_reaction", ["channel_id": "#eng"], [ws])?.hasPrefix("NOT REACTED") == true)
        XCTAssertTrue(SlackTools.refusal("slack_mark_read", ["channel_id": "C123456"], [ws])?.contains("reconnect Slack") == true)
        XCTAssertNil(SlackTools.refusal("slack_send_message", ["channel_id": "C123456", "message": "hi"], [ws]))
        XCTAssertEqual(SlackTools.refusal("slack_send_message", ["channel_id": "C123456"], [ws]),
                       "NOT SENT — there was no message text.")
        let expired = SlackWebAPI.CallError(method: "chat.postMessage", code: "token_expired", status: 401, retryAfterSeconds: 0)
        XCTAssertTrue(SlackTools.explain(expired).contains("reconnect Slack in Settings"))
    }

    func testAnIdFromAnotherWorkspaceIsTriedInTheNext() async throws {
        let a = SlackWorkspace(teamId: "TA", teamName: "A", userId: "U0")
        let b = SlackWorkspace(teamId: "TB", teamName: "B", userId: "U0")
        let answer = try await SlackTools.whichever([a, b]) { ws -> String in
            if ws.teamId == "TA" { throw SlackWebAPI.CallError(method: "x", code: "channel_not_found", status: 200, retryAfterSeconds: 0) }
            return ws.teamName
        }
        XCTAssertEqual(answer, "B")
        do {
            _ = try await SlackTools.whichever([a, b]) { _ -> String in
                throw SlackWebAPI.CallError(method: "x", code: "ratelimited", status: 429, retryAfterSeconds: 30)
            }
            XCTFail("a real failure is not retried elsewhere")
        } catch let error as SlackWebAPI.CallError {
            XCTAssertEqual(error.code, "ratelimited")
        }
    }

    // MARK: - Session setup

    func testSlackToolsSkillAndStagesAreDeclaredOnlyWithAWorkspace() throws {
        let catalog = LiveSessionSetup.Catalog.bundled
        var request = LiveSessionSetup.Request()
        request.opening = .emailQueue
        request.sequentialFeed = true
        var state = LiveSessionSetup.State(inboxes: ["a@x.test"])
        let without = LiveSessionSetup.resolve(request, state, catalog: catalog)
        XCTAssertFalse(without.tools.contains { ($0["name"] as? String)?.hasPrefix("slack_") == true })
        XCTAssertNil(without.prompt["localSlackTriage"])
        XCTAssertFalse(without.localSlackTriage)

        state.slackWorkspaces = ["Acme"]
        let with = LiveSessionSetup.resolve(request, state, catalog: catalog)
        let names = with.tools.compactMap { $0["name"] as? String }.filter { $0.hasPrefix("slack_") }
        XCTAssertEqual(names, SlackTools.catalogOrder)
        XCTAssertEqual(with.prompt["skills"] as? [String], ["email", "slack"])
        XCTAssertEqual(with.prompt["slackFeedStage"] as? Bool, true)
        XCTAssertTrue(with.localSlackTriage && with.slackFeedStage && with.importantSlackStage)
        XCTAssertEqual(Set(names), SlackTools.readNames.union(SlackTools.writeNames).union([SlackTools.queueName]))
    }

    func testALapsedWorkspaceGetsTheReconnectNoteAndNoTools() throws {
        let catalog = LiveSessionSetup.Catalog.bundled
        var state = LiveSessionSetup.State(inboxes: ["a@x.test"])
        state.slackNeedsReauth = ["Acme"]
        let setup = LiveSessionSetup.resolve(.init(), state, catalog: catalog)
        XCTAssertFalse(setup.tools.contains { ($0["name"] as? String)?.hasPrefix("slack_") == true })
        let brain = try LivePrompt.brainInstructions(LivePrompt.Facts(setup.prompt), timeZone: "UTC")
        XCTAssertTrue(brain.contains("Slack access has stopped working: their Slack connection (Acme) expired"))
        XCTAssertFalse(brain.contains("# The Slack queue — you drive it"))
    }

    func testTheSlackSkillAndAddendaReachTheBrain() throws {
        var facts = LivePrompt.Facts()
        facts.skills = ["email", "slack"]
        facts.localSlackTriage = true
        facts.slackFeedStage = true
        facts.importantSlackStage = true
        let brain = try LivePrompt.brainInstructions(facts, timeZone: "UTC")
        XCTAssertTrue(brain.contains("# The Slack queue — you drive it"))
        XCTAssertTrue(brain.contains("# The Slack queue, on the device"))
        XCTAssertTrue(brain.contains("# The Feed's Slack stage"))
        XCTAssertTrue(brain.contains("`interstitial: \"slack\"`"))
    }

    func testTheConnectLessonIsOfferedOnlyWhileSlackCanBeConnected() {
        let catalog = [CoachingRotation.Lesson(capability: "slack_connect", copy: "c")]
        let defaults = UserDefaults(suiteName: "slack-coaching-\(UUID().uuidString)")!
        XCTAssertEqual(CoachingRotation.plan(.init(slackConnectable: true), catalog: catalog, defaults: defaults)
            .lessons.map(\.capability), ["slack_connect"])
        XCTAssertTrue(CoachingRotation.plan(.init(), catalog: catalog, defaults: defaults).lessons.isEmpty)
        XCTAssertNotNil(CoachingRotation.copy(for: "slack_connect"))
    }
}
