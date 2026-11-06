import FactoryKit
import Foundation
import XCTest
@testable import CodenameJo

@MainActor
final class MailboxSearchIdentityTests: XCTestCase {
    private let accounts = ["a@example.test", "b@example.test", "c@example.test"]
    private var provider: SearchIdentityProvider!
    private var tokens: SearchIdentityTokens!
    private var folder: URL!
    private var context: LocalContextStore!

    override func setUp() async throws {
        try await super.setUp()
        Container.shared.manager.push()
        ProfileRuntime.install(.init(profileId: "search-profile", isDefault: true, emails: accounts))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        context = LocalContextStore(url: folder.appendingPathComponent("context.sqlite"))
        let context = context!
        Container.shared.localContext.register { context }
        let backend = BackendService(restoringSession: false)
        backend.userId = "search-user"
        Container.shared.backend.register { backend }
        let grants = SearchIdentityGrants(accounts: accounts)
        Container.shared.googleGrantStorage.register { grants }
        tokens = SearchIdentityTokens()
        let tokens = tokens!
        Container.shared.googleTokenProvider.register { tokens }
        provider = SearchIdentityProvider()
        let provider = provider!
        Container.shared.providerHTTP.register { provider }
    }

    override func tearDown() async throws {
        try? context.dbPool?.close()
        Scope.singleton.reset()
        Container.shared.manager.pop()
        ProfileRuntime.install(nil)
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    private func search(_ args: [String: Any] = ["query": "company"]) async -> (output: String, failed: Bool, effects: [GmailWriteEffect]?) {
        await GmailReadTools.run(name: GmailReadTools.search, argumentsJSON: GmailReadTools.json(args))
    }

    private func groups(_ output: String) throws -> [[String: Any]] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        return try XCTUnwrap(root["accounts"] as? [[String: Any]])
    }

    private func assertOwnership(_ output: String, counts: [Int?], file: StaticString = #filePath, line: UInt = #line) throws {
        let entries = try groups(output)
        XCTAssertEqual(entries.compactMap { $0["account"] as? String }, accounts, file: file, line: line)
        for (index, group) in entries.enumerated() {
            let hits = group["result"] as? [[String: Any]]
            XCTAssertEqual(hits?.count, counts[index], file: file, line: line)
            for hit in hits ?? [] {
                XCTAssertEqual(hit["account"] as? String, accounts[index], file: file, line: line)
                XCTAssertTrue((hit["id"] as? String)?.hasPrefix(String(accounts[index].prefix(1))) == true, file: file, line: line)
            }
        }
    }

    func testProviderThroughStoredContextAndFollowupRetainsMailboxIdentity() async throws {
        let first = await search()
        XCTAssertFalse(first.failed, first.output)
        try assertOwnership(first.output, counts: [0, 2, 1])
        try assertOwnership(LiveCompactContext.bounded(first.output, bytes: 2000), counts: [0, 2, 1])
        await context.record(tool: GmailReadTools.search, serverLabel: "aurex", argumentsJSON: "{\"query\":\"company\"}",
                             itemJSON: GmailReadTools.json(["output": first.output]), userId: "search-user", conversationId: "search-call")
        let stored = await context.row(key: "m_1", in: "search-call")
        XCTAssertEqual(stored?.result, first.output)
        let hit = try XCTUnwrap((groups(try XCTUnwrap(stored?.result))[1]["result"] as? [[String: Any]])?.first)
        let read = await GmailReadTools.run(name: GmailReadTools.getMessage,
            argumentsJSON: GmailReadTools.json(["account": hit["account"]!, "message_id": hit["id"]!]))
        XCTAssertFalse(read.failed, read.output)
        let requests = await provider.requests
        let readRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(readRequest.value(forHTTPHeaderField: "Authorization"), "Bearer b@example.test")
        XCTAssertTrue(readRequest.url?.path.hasSuffix("/b-0") == true)
        XCTAssertEqual(Set(tokens.requested), Set(accounts))
    }

    func testEveryCompletionPermutationKeepsEmptyAccountAndDuplicateSubjectsSeparate() async throws {
        for order in [[0, 1, 2], [2, 1, 0], [1, 2, 0], [1, 0, 2], [2, 0, 1], [0, 2, 1]] {
            let accounts = accounts
            let output = try await GmailReadTools.searchAccounts(accounts, query: "company", size: 10, before: nil) { account, _, _ in
                let index = accounts.firstIndex(of: account)!
                try await Task.sleep(nanoseconds: UInt64(order.firstIndex(of: index)!) * 10_000_000)
                let hits: [[String: Any]] = (0..<index).map { ["account": account, "id": "\(account.prefix(1))-\($0)", "subject": "Same subject"] }
                return .init(account: account, hits: hits, floor: nil)
            }
            try assertOwnership(output, counts: [0, 1, 2])
        }
    }

    func testPartialFailureAndPaginationKeepTheirAccount() async throws {
        await provider.configure(failure: "b@example.test", paginated: true)
        let first = await search()
        XCTAssertFalse(first.failed, first.output)
        try assertOwnership(first.output, counts: [0, nil, 1])
        XCTAssertNotNil(try groups(first.output)[1]["error"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.output.utf8)) as? [String: Any])
        let before = try XCTUnwrap(json["before"] as? Int)
        let next = await search(["query": "company", "before": before])
        try assertOwnership(next.output, counts: [0, nil, 1])
        let queries = await provider.requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value }
        XCTAssertEqual(queries.filter { $0.contains("before:\(before)") }.count, 3)
    }

    func testWrongPageOrNestedIdentityIsWithheld() async throws {
        for wrongPage in [true, false] {
            do {
                _ = try await GmailReadTools.searchAccounts([accounts[0]], query: "company", size: 10, before: nil) { account, _, _ in
                    .init(account: wrongPage ? "other@example.test" : account,
                          hits: [["account": "other@example.test", "id": "private-id"]], floor: nil)
                }
                XCTFail("Inconsistent identity must not be serialized")
            } catch let error as GmailReadTools.Refusal {
                XCTAssertTrue(error.text.contains("identity"))
                XCTAssertFalse(error.text.contains("private-id"))
            }
        }
    }

    func testWrongCredentialIdentityNeverReachesProvider() async throws {
        tokens.wrongIdentity = true
        let result = await search()
        XCTAssertTrue(result.failed)
        XCTAssertTrue(result.output.contains("different mailbox"))
        let count = await provider.requests.count
        XCTAssertEqual(count, 0)
    }

    func testProfileChangeDuringTokenRefreshDiscardsResults() async {
        tokens.onRefresh = {
            ProfileRuntime.install(.init(profileId: "other-profile", isDefault: false, emails: ["c@example.test"]))
        }
        let result = await search()
        XCTAssertTrue(result.failed)
        XCTAssertTrue(result.output.contains("discarded"), result.output)
        XCTAssertFalse(result.output.contains("Same subject"))
    }

    func testSearchContinuesAfterSameDelegationStopsFeedButWritesStayStale() async throws {
        let client = FullDuplexVoiceClient()
        client.activateFeedForTesting(transport: FullDuplexTransport())
        client.liveConfiguration = .init()
        client.liveQueueRevision = 5
        client.standingStep = GmailReadTools.json(["item": ["account": accounts[0], "id": "previous"]])
        client.handle(.liveDelegation("stop-and-search", userTurn: 0))
        client.liveQueueRevision = 6
        client.standingStep = nil
        var refusals: [String] = []
        client.onToolRefused = { _, receipt in refusals.append(receipt.reason ?? "") }
        let done = expectation(description: "Search completed after stop")
        client.onToolDone = { if $0 == GmailReadTools.search { done.fulfill() } }
        client.handle(.liveFunction(.init(id: "lookup", name: GmailReadTools.search,
            arguments: #"{"query":"from:sender@example.test has:attachment"}"#, delegation: "stop-and-search")))
        await fulfillment(of: [done], timeout: 5)
        XCTAssertTrue(refusals.isEmpty)
        let count = await provider.requests.filter { $0.url?.path.hasSuffix("/messages") == true }.count
        XCTAssertEqual(count, 3)
        let requestsBeforeRefusals = await provider.requests.count
        for name in ["archive_message", "triage_next", "gmail_get_message"] {
            client.handle(.liveFunction(.init(id: name, name: name, arguments: "{}", delegation: "stop-and-search")))
        }
        XCTAssertEqual(refusals.count, 3)
        XCTAssertTrue(["missing_voice_selection", "stale_feed"].contains(refusals.first ?? ""))
        XCTAssertEqual(Array(refusals.dropFirst()), ["stale_feed", "stale_feed"])
        let requestsAfterRefusals = await provider.requests.count
        XCTAssertEqual(requestsAfterRefusals, requestsBeforeRefusals, "Stale attempts must not make another provider request")
    }

    func testIndependentSearchCannotCrossProfileOrOwnerChange() async {
        for changeOwner in [false, true] {
            ProfileRuntime.install(.init(profileId: "search-profile", isDefault: true, emails: accounts))
            let client = FullDuplexVoiceClient()
            client.activateFeedForTesting(transport: FullDuplexTransport())
            client.liveConfiguration = .init()
            client.handle(.liveDelegation("old-scope", userTurn: 0))
            if changeOwner { Container.shared.backend().userId = "other-user" }
            else { ProfileRuntime.install(.init(profileId: "other-profile", isDefault: false, emails: accounts)) }
            var reasons: [String] = []
            client.onToolRefused = { _, receipt in reasons.append(receipt.reason ?? "") }
            client.handle(.liveFunction(.init(id: "blocked", name: GmailReadTools.search,
                arguments: #"{"query":"company"}"#, delegation: "old-scope")))
            XCTAssertEqual(reasons, ["stale_profile"])
        }
        let count = await provider.requests.count
        XCTAssertEqual(count, 0)
    }

    func testOnlyExplicitSearchIsIndependentOfCurrentMessage() {
        XCTAssertTrue(LiveFastAction.allowsFollowup(name: GmailReadTools.search, arguments: #"{"query":"company"}"#, step: nil))
        for arguments in ["{}", #"{"query":" "}"#, "invalid"] {
            XCTAssertFalse(LiveFastAction.allowsFollowup(name: GmailReadTools.search, arguments: arguments, step: nil))
        }
        for tool in ["list_calendar_events", "search_context"] {
            XCTAssertTrue(LiveFastAction.allowsFollowup(name: tool, arguments: #"{"query":"company"}"#, step: nil))
        }
    }
}

@MainActor
private final class SearchIdentityTokens: GoogleTokenProvider {
    var wrongIdentity = false
    var requested: [String] = []
    var onRefresh: (() -> Void)?
    func token(for email: String?, requiredScopes: [String]) async -> Result<GoogleCredential.Token, GoogleCredential.Failure> {
        requested.append(email ?? "")
        await Task.yield()
        onRefresh?()
        return .success(.init(accessToken: email ?? "", email: wrongIdentity ? "other@example.test" : email, scopes: requiredScopes))
    }
}

private struct SearchIdentityGrants: GoogleGrantStorage {
    let accounts: [String]
    func all() -> [GoogleAccountStore.Grant] {
        accounts.map { .init(email: $0, refreshToken: "fixture", scopes: ["https://www.googleapis.com/auth/gmail.modify"],
                             grantedAt: Date(), isPrimary: $0 == accounts.first) }
    }
    func save(_ grant: GoogleAccountStore.Grant) -> Bool { true }
    func remove(_ email: String) {}
    func removeAll() {}
}

private actor SearchIdentityProvider: HTTPDataTransport {
    var requests: [URLRequest] = []
    private var failure: String?
    private var paginated = false
    func configure(failure: String?, paginated: Bool) { self.failure = failure; self.paginated = paginated }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let account = (request.value(forHTTPHeaderField: "Authorization") ?? "").replacingOccurrences(of: "Bearer ", with: "")
        let prefix = String(account.prefix(1)), count = prefix == "a" ? 0 : prefix == "b" ? 2 : 1
        try await Task.sleep(nanoseconds: prefix == "b" ? 30_000_000 : 1_000_000)
        let status = account == failure ? 503 : 200
        let ids = (0..<count).map { "\(prefix)-\($0)" }
        func message(_ id: String) -> [String: Any] {
            ["id": id, "threadId": "thread-" + id, "internalDate": "1757000000000",
             "payload": ["mimeType": "text/plain", "headers": [["name": "Subject", "value": "Same subject"]]]]
        }
        let body: String
        var headers = ["Content-Type": "application/json"]
        if request.url!.path.contains("/batch/") {
            headers["Content-Type"] = "multipart/mixed; boundary=fixture"
            body = ids.reversed().map { "--fixture\r\nContent-Type: application/http\r\n\r\nHTTP/1.1 200 OK\r\n\r\n\(GmailReadTools.json(message($0)))\r\n" }.joined() + "--fixture--\r\n"
        } else if request.url!.path.hasSuffix("/messages") {
            var page: [String: Any] = ["messages": ids.map { ["id": $0, "threadId": "thread-" + $0] }]
            if paginated && count > 0 { page["nextPageToken"] = "older" }
            body = GmailReadTools.json(page)
        } else { body = GmailReadTools.json(message(request.url!.lastPathComponent)) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}
