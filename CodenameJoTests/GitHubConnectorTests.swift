import FactoryKit
import XCTest
@testable import CodenameJo

/// Answers each request with the next canned response, and keeps what was asked.
final class StubGitHubHTTP: HTTPDataTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Int, String)]
    private(set) var requests: [URLRequest] = []
    var failNext: Error?

    init(_ responses: [(Int, String)]) { self.responses = responses }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try lock.withLock {
            requests.append(request)
            if let error = failNext { failNext = nil; throw error }
            let (status, body) = responses.isEmpty ? (500, "{}") : responses.removeFirst()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }
}

final class MemoryGitHubTokenStorage: GitHubTokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: GitHubAccountStore.Account] = [:]
    func all() -> [GitHubAccountStore.Account] { lock.withLock { items.values.sorted { $0.connectedAt < $1.connectedAt } } }
    func save(_ account: GitHubAccountStore.Account) -> Bool { lock.withLock { items[account.id] = account }; return true }
    func remove(id: String) { lock.withLock { _ = items.removeValue(forKey: id) } }
    func removeAll() { lock.withLock { items = [:] } }
}

final class GitHubDeviceFlowTests: XCTestCase {
    private let code = GitHubDeviceFlow.Code(deviceCode: "dev", userCode: "ABCD-1234",
                                             verificationURL: URL(string: "https://github.com/login/device")!,
                                             expiresIn: 900, interval: 5)

    func testTheCodeResponseIsReadAsGitHubSendsIt() throws {
        let body = #"{"device_code":"3584d83530557fdd1f46af8289938c8ef79f9dc5","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
        let issued = try GitHubDeviceFlow.classifyCode(status: 200, body: Data(body.utf8)).get()
        XCTAssertEqual(issued.userCode, "WDJB-MJHT")
        XCTAssertEqual(issued.verificationURL.absoluteString, "https://github.com/login/device")
        XCTAssertEqual(issued.interval, 5)
        XCTAssertEqual(GitHubDeviceFlow.classifyCode(status: 200, body: Data(#"{"error":"device_flow_disabled"}"#.utf8)),
                       .failure(.disabled))
        // An unknown client id is a 404 with no device code.
        XCTAssertEqual(GitHubDeviceFlow.classifyCode(status: 404, body: Data(#"{"error":"Not Found"}"#.utf8)),
                       .failure(.failed("Not Found")))
    }

    func testThePollAsksForJSONWithTheDeviceGrant() async throws {
        let http = StubGitHubHTTP([(200, #"{"access_token":"gho_x","token_type":"bearer","scope":"notifications,read:org,read:user,repo"}"#)])
        let result = await GitHubDeviceFlow.waitForToken(code, clientID: "Ov23client", transport: http, sleep: { _ in })
        XCTAssertEqual(try result.get().token, "gho_x")
        XCTAssertEqual(try result.get().scopes, ["notifications", "read:org", "read:user", "repo"])
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url, GitHubDeviceFlow.tokenURL)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("grant_type=urn:ietf:params:oauth:grant-type:device_code"))
        XCTAssertTrue(body.contains("device_code=dev"))
        XCTAssertFalse(body.contains("client_secret"))
    }

    func testPendingWaitsTheIntervalAndSlowDownTakesGitHubsNewOne() async throws {
        let http = StubGitHubHTTP([
            (200, #"{"error":"authorization_pending"}"#),
            (200, #"{"error":"slow_down","interval":10}"#),
            (200, #"{"error":"slow_down"}"#),
            (200, #"{"access_token":"gho_y","scope":"repo"}"#),
        ])
        var sleeps: [TimeInterval] = []
        let result = await GitHubDeviceFlow.waitForToken(code, clientID: "c", transport: http, sleep: { sleeps.append($0) })
        XCTAssertEqual(try result.get().token, "gho_y")
        // A slow_down without an interval adds GitHub's five seconds itself.
        XCTAssertEqual(sleeps, [5, 5, 10, 15])
    }

    func testRefusalsEndThePollWithTheirOwnReason() async {
        for (error, failure) in [("access_denied", GitHubDeviceFlow.Failure.denied), ("expired_token", .expired),
                                 ("device_flow_disabled", .disabled), ("incorrect_device_code", .failed("incorrect_device_code"))] {
            let http = StubGitHubHTTP([(200, "{\"error\":\"\(error)\"}")])
            let result = await GitHubDeviceFlow.waitForToken(code, clientID: "c", transport: http, sleep: { _ in })
            XCTAssertEqual(result.failure, failure, error)
        }
    }

    func testANetworkBlipIsRetriedAndTheCodesExpiryEndsTheWait() async {
        let http = StubGitHubHTTP([(200, #"{"access_token":"gho_z"}"#)])
        http.failNext = URLError(.notConnectedToInternet)
        let ok = await GitHubDeviceFlow.waitForToken(code, clientID: "c", transport: http, sleep: { _ in })
        XCTAssertEqual(ok.success?.token, "gho_z")
        XCTAssertEqual(http.requests.count, 2)

        var clock = Date(timeIntervalSince1970: 0)
        let pending = StubGitHubHTTP(Array(repeating: (200, #"{"error":"authorization_pending"}"#), count: 500))
        let expired = await GitHubDeviceFlow.waitForToken(code, clientID: "c", transport: pending,
                                                          now: { clock }, sleep: { clock.addTimeInterval($0) })
        XCTAssertEqual(expired.failure, .expired)
    }

    func testCancellingTheSleepCancelsTheSignIn() async {
        let http = StubGitHubHTTP([])
        let result = await GitHubDeviceFlow.waitForToken(code, clientID: "c", transport: http,
                                                         sleep: { _ in throw CancellationError() })
        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertNil(GitHubDeviceFlow.Failure.cancelled.message, "a cancel shows no error")
    }
}

final class GitHubToolsTests: XCTestCase {
    private let account = GitHubAccountStore.Account(id: "1", login: "octo", token: "gho_ok", scopes: ["repo"],
                                                     connectedAt: Date())

    override func tearDown() {
        Container.shared.githubTokenStorage.reset()
        super.tearDown()
    }

    private func run(_ name: String, _ args: String, _ http: StubGitHubHTTP,
                     accounts: [GitHubAccountStore.Account]? = nil) async -> FullDuplexBroker.ToolResult {
        await GitHubTools.run(name: name, argumentsJSON: args, accounts: accounts ?? [account],
                              makeAPI: { GitHubAPI(token: $0, allowWrites: $1, transport: http) })
    }

    func testTheAllowlistIsExactlyTheCatalogsGitHubTools() throws {
        let catalog = LiveSessionSetup.Catalog.bundled
        let declared = Set(catalog.tools.keys.filter { $0.hasPrefix("github_") })
        XCTAssertEqual(declared, GitHubTools.allowedTools)
        XCTAssertEqual(Set(GitHubTools.handlers.keys), GitHubTools.allowedTools)
        XCTAssertEqual(Set(GitHubTools.writeTools), ["github_merge_pull_request", "github_issue_write",
            "github_add_issue_comment", "github_update_pull_request", "github_actions_run_trigger"])
        XCTAssertTrue(Set(GitHubTools.readTools).isDisjoint(with: GitHubTools.writeTools))
    }

    func testANameOutsideTheAllowlistNeverReachesGitHub() async {
        let http = StubGitHubHTTP([])
        for name in ["github_delete_repository", "github_create_pull_request", "github_push_files"] {
            let result = await run(name, #"{"owner":"o","repo":"r"}"#, http)
            XCTAssertEqual(result.ok, false)
            XCTAssertTrue(result.text.contains("not a GitHub tool this app allows"))
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testAReadCannotSendAWrite() async {
        let api = GitHubAPI(token: "t", allowWrites: false, transport: StubGitHubHTTP([(200, "{}")]))
        do {
            _ = try await api.json("/repos/o/r/pulls/1/merge", method: "PUT", body: [:])
            XCTFail("a read client sent a PUT")
        } catch {
            XCTAssertEqual((error as? GitHubAPI.Failure)?.status, 405)
        }
    }

    func testAReadSendsTheHeadersGitHubRequiresAndDropsPullRequestsFromIssues() async throws {
        let http = StubGitHubHTTP([(200, #"[{"number":3,"title":"Crash","user":{"login":"ana"},"state":"open","labels":[{"name":"bug"}],"assignees":[],"comments":1,"updated_at":"2026-10-01T00:00:00Z"},{"number":4,"title":"A PR","pull_request":{}}]"#)])
        let result = await run("github_list_issues", #"{"owner":"kiloforgeai","repo":"codename-jo","per_page":1}"#, http)
        XCTAssertEqual(result.ok, true)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/repos/kiloforgeai/codename-jo/issues")
        XCTAssertTrue(request.url?.query?.contains("per_page=1") == true, "a 1 stays a number, not true")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gho_ok")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
        let issues = try XCTUnwrap(json["issues"] as? [[String: Any]])
        XCTAssertEqual(issues.map { $0["number"] as? Int }, [3])
        XCTAssertEqual(issues.first?["labels"] as? [String], ["bug"])
    }

    func testAMissingOwnerIsRefusedBeforeAnyRequest() async {
        let http = StubGitHubHTTP([])
        let result = await run("github_list_pull_requests", #"{"repo":"codename-jo"}"#, http)
        XCTAssertEqual(result.ok, false)
        XCTAssertTrue(result.text.contains("github_search_repositories"))
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testSearchesAddTheirKindAndMergeIsAPut() async throws {
        let http = StubGitHubHTTP([(200, #"{"total_count":0,"items":[]}"#),
                                   (200, #"{"merged":true,"sha":"abcdef1234","message":"Merged"}"#)])
        _ = await run("github_search_pull_requests", #"{"query":"review-requested:@me is:open"}"#, http)
        let search = try XCTUnwrap(URLComponents(url: http.requests[0].url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(search.queryItems?.first { $0.name == "q" }?.value, "review-requested:@me is:open is:pr")

        let merged = await run("github_merge_pull_request", #"{"owner":"o","repo":"r","pull_number":7,"merge_method":"squash"}"#, http)
        XCTAssertEqual(http.requests[1].httpMethod, "PUT")
        XCTAssertEqual(http.requests[1].url?.path, "/repos/o/r/pulls/7/merge")
        XCTAssertEqual(merged.text, "Merged o/r #7 as abcdef1.")
        XCTAssertEqual(merged.performedTool, "github_merge_pull_request")
    }

    func testADeclinedMergeIsNotReportedAsDone() {
        let receipt = GitHubTools.receipt("github_merge_pull_request", ["merged": false, "repo": "o/r", "message": "Base branch was modified"])
        XCTAssertFalse(receipt.ok)
        XCTAssertTrue(receipt.text.hasPrefix("NOT MERGED"))
    }

    func testARevokedTokenMarksTheAccountForReconnecting() async {
        let storage = MemoryGitHubTokenStorage()
        Container.shared.githubTokenStorage.register { storage }
        _ = storage.save(account)
        let http = StubGitHubHTTP([(401, #"{"message":"Bad credentials"}"#)])
        let result = await run("github_get_me", "{}", http)
        XCTAssertEqual(result.ok, false)
        XCTAssertTrue(result.text.contains("reconnect GitHub in Settings"))
        XCTAssertEqual(GitHubAccountStore.needsReauth(), ["octo"])
        XCTAssertTrue(GitHubAccountStore.usable().isEmpty)
    }

    func testNoAccountMeansNoCall() async {
        let http = StubGitHubHTTP([])
        let result = await run("github_get_me", "{}", http, accounts: [])
        XCTAssertTrue(result.text.contains("No GitHub account is connected"))
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testTheAccountParameterAppearsOnlyWithASecondLogin() throws {
        let catalog = LiveSessionSetup.Catalog.bundled
        XCTAssertTrue(GitHubTools.definitions(logins: [], catalog: catalog).isEmpty)
        let one = GitHubTools.definitions(logins: ["octo"], catalog: catalog)
        XCTAssertEqual(one.count, GitHubTools.allowedTools.count)
        XCTAssertFalse(one.contains { (($0["parameters"] as? [String: Any])?["properties"] as? [String: Any])?["account"] != nil })
        let two = GitHubTools.definitions(logins: ["octo", "work"], catalog: catalog)
        XCTAssertTrue(two.allSatisfy { (($0["parameters"] as? [String: Any])?["properties"] as? [String: Any])?["account"] != nil })
        let second = GitHubTools.accountFor([account, .init(id: "2", login: "work", token: "w", scopes: [], connectedAt: Date())],
                                            ["account": "Work"])
        XCTAssertEqual(second.login, "work")
    }

    func testTheSessionCarriesGitHubOnlyWhenConnected() throws {
        let catalog = LiveSessionSetup.Catalog.bundled
        let without = LiveSessionSetup.resolve(.init(), .init(inboxes: ["a@x.test"]), catalog: catalog)
        XCTAssertFalse(without.tools.contains { ($0["name"] as? String)?.hasPrefix("github_") == true })
        XCTAssertEqual(without.prompt["githubNeedsReauth"] as? [String], [])

        let with = LiveSessionSetup.resolve(.init(), .init(inboxes: ["a@x.test"], githubAccounts: ["octo"],
                                                           githubNeedsReauth: ["old"]), catalog: catalog)
        XCTAssertEqual(Set(with.tools.compactMap { $0["name"] as? String }.filter { $0.hasPrefix("github_") }),
                       GitHubTools.allowedTools)
        XCTAssertEqual(with.prompt["skills"] as? [String], ["email", "github"])
        XCTAssertEqual(with.prompt["githubNeedsReauth"] as? [String], ["old"])
    }

    func testThePromptCarriesTheSkillAndTheReconnectNote() throws {
        var facts = LivePrompt.Facts()
        facts.skills = ["github"]
        facts.githubNeedsReauth = ["octo"]
        let brain = try LivePrompt.brainInstructions(facts, timeZone: "UTC")
        XCTAssertTrue(brain.contains("github_search_repositories first"))
        XCTAssertTrue(brain.contains("require a read-back and an explicit yes"))
        XCTAssertTrue(brain.contains("GitHub needs reconnecting in Settings"))
        XCTAssertTrue(brain.contains("their GitHub connection (octo)"))
        XCTAssertFalse(try LivePrompt.brainInstructions(LivePrompt.Facts(), timeZone: "UTC").contains("# Code"))
    }

    func testTheGitHubLessonsFollowTheConnection() {
        XCTAssertFalse(CoachingRotation.available("github_connect", .init()))
        XCTAssertTrue(CoachingRotation.available("github_connect", .init(githubAvailable: true)))
        XCTAssertFalse(CoachingRotation.available("github_connect", .init(githubAvailable: true, githubConnected: true)))
        XCTAssertTrue(CoachingRotation.available("github_reviews", .init(githubAvailable: true, githubConnected: true)))
        XCTAssertFalse(CoachingRotation.available("github_reviews", .init(githubAvailable: true)))
        XCTAssertNotNil(CoachingRotation.copy(for: "github_connect"))
        XCTAssertNotNil(CoachingRotation.copy(for: "github_reviews"))
    }

    func testRemovingOneLoginKeepsTheOther() {
        let storage = MemoryGitHubTokenStorage()
        Container.shared.githubTokenStorage.register { storage }
        GitHubAccountStore.save(account)
        GitHubAccountStore.save(.init(id: "2", login: "work", token: "w", scopes: [], connectedAt: Date().addingTimeInterval(1)))
        GitHubAccountStore.remove(login: "OCTO")
        XCTAssertEqual(GitHubAccountStore.all().map(\.login), ["work"])
        GitHubAccountStore.removeAll()
        XCTAssertTrue(GitHubAccountStore.all().isEmpty)
    }
}

private extension Result {
    var success: Success? { if case .success(let value) = self { value } else { nil } }
    var failure: Failure? { if case .failure(let error) = self { error } else { nil } }
}
