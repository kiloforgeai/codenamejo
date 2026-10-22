import FactoryKit
import XCTest
@testable import CodenameJo

@MainActor
final class GmailUnsubscribeTests: XCTestCase {
    private let owner = "owner@example.test"

    override func setUp() async throws {
        try await super.setUp()
        Container.shared.googleGrantStorage.register { UnsubscribeGrants() }
        Container.shared.googleTokenProvider.register { MainActor.assumeIsolated { UnsubscribeToken() } }
        Container.shared.localTriage.register { LocalTriageQueue(mailAccounts: { [] }) }
    }

    override func tearDown() async throws {
        Container.shared.googleGrantStorage.reset()
        Container.shared.googleTokenProvider.reset()
        Container.shared.localTriage.reset()
        Container.shared.providerHTTP.reset()
        Container.shared.unsubscribeHTTP.reset()
        try await super.tearDown()
    }

    private func gmail(header: String = "", oneClick: Bool = false, signed: Bool = true,
                       sendStatus: Int = 200, archiveStatus: Int = 200) throws -> ScriptedGmail {
        var headers = [["name": "From", "value": "News <news@list.example>"]]
        if !header.isEmpty { headers.append(["name": "List-Unsubscribe", "value": header]) }
        if oneClick { headers.append(["name": "List-Unsubscribe-Post", "value": "List-Unsubscribe=One-Click"]) }
        if signed { headers.append(["name": "Authentication-Results", "value": "mx; dkim=pass header.d=list.example"]) }
        let metadata = String(decoding: try JSONSerialization.data(withJSONObject: ["payload": ["headers": headers]]), as: UTF8.self)
        let http = ScriptedGmail { call in
            switch (call.method, call.path) {
            case ("GET", "messages/m1"): return (200, "application/json", metadata)
            case ("POST", "messages/send"): return (sendStatus, "application/json", "{}")
            case ("GET", "messages"): return (200, "application/json", #"{"messages":[{"id":"m1","threadId":"t1"}]}"#)
            case ("POST", "messages/batchModify"): return (archiveStatus, "application/json", "{}")
            default: return (500, "application/json", "{}")
            }
        }
        Container.shared.providerHTTP.register { http }
        return http
    }

    private func endpoint(_ code: Int) -> ScriptedGmail {
        let http = ScriptedGmail { _ in (code, "text/plain", "") }
        Container.shared.unsubscribeHTTP.register { http }
        return http
    }

    private func run(clear: Bool? = nil) async -> (output: String, failed: Bool, effects: [GmailWriteEffect]?) {
        var args: [String: Any] = ["message_id": "m1", "account": owner]
        if let clear { args["clear_existing"] = clear }
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        return await GmailManageTools.run(name: GmailManageTools.unsubscribe, argumentsJSON: json)
    }

    func testMissingUnsignedAndManualRoutesNeverFilterOrArchiveEvenWhenClearWasRequested() async throws {
        for (header, oneClick, signed) in [("", false, true),
            ("<https://list.example/unsubscribe>", true, false),
            ("<https://list.example/preferences>", false, true)] {
            let mail = try gmail(header: header, oneClick: oneClick, signed: signed)
            let post = endpoint(200)
            let result = await run(clear: true)
            XCTAssertTrue(result.failed)
            XCTAssertTrue(result.output.hasPrefix("Not unsubscribed"))
            XCTAssertTrue(ToolNarration.isRefusal(result.output))
            XCTAssertNil(result.effects)
            XCTAssertTrue(mail.calls.allSatisfy { $0.method == "GET" })
            XCTAssertTrue(post.calls.isEmpty)
        }
    }

    func testRejectedRedirectedAndUnsafeOneClickRequestsLeaveTheInboxAlone() async throws {
        for (url, status) in [("https://list.example/unsubscribe", 500),
                              ("https://list.example/unsubscribe", 302),
                              ("https://printer.local/unsubscribe", 200)] {
            let mail = try gmail(header: "<\(url)>", oneClick: true)
            let post = endpoint(status)
            let result = await run(clear: true)
            XCTAssertTrue(result.failed)
            XCTAssertTrue(result.output.hasPrefix("Not unsubscribed"))
            XCTAssertNil(result.effects)
            XCTAssertTrue(mail.calls.allSatisfy { $0.method == "GET" })
            XCTAssertEqual(post.calls.count, url.contains("printer.local") ? 0 : 1)
        }
    }

    func testNetworkFailureLeavesTheInboxAlone() async throws {
        let mail = try gmail(header: "<https://list.example/unsubscribe>", oneClick: true)
        Container.shared.unsubscribeHTTP.register { UnsubscribeNetworkFailure() }
        let result = await run(clear: true)
        XCTAssertTrue(result.failed)
        XCTAssertTrue(result.output.hasPrefix("Not unsubscribed"))
        XCTAssertNil(result.effects)
        XCTAssertTrue(mail.calls.allSatisfy { $0.method == "GET" })
    }

    func testMailtoAndFallbackRequestsNeverClaimConfirmedUnsubscribeOrClearMail() async throws {
        for oneClick in [false, true] {
            for sendStatus in [200, 403] {
                let header = "<mailto:leave@list.example>" + (oneClick ? ", <https://list.example/unsubscribe>" : "")
                let mail = try gmail(header: header, oneClick: oneClick, sendStatus: sendStatus)
                _ = endpoint(500)
                let result = await run(clear: true)
                XCTAssertTrue(result.failed)
                XCTAssertTrue(ToolNarration.isRefusal(result.output))
                XCTAssertTrue(result.output.hasPrefix(sendStatus == 200 ? "Not confirmed unsubscribed" : "Not unsubscribed"))
                XCTAssertNil(result.effects)
                XCTAssertEqual(mail.calls.filter { $0.method == "POST" }.map(\.path), ["messages/send"])
            }
        }
    }

    func testConfirmedUnsubscribeDoesNotFilterOrArchiveByDefault() async throws {
        let mail = try gmail(header: "<https://list.example/unsubscribe>", oneClick: true)
        let post = endpoint(204)
        let result = await run()
        XCTAssertFalse(result.failed)
        XCTAssertEqual(result.output, "Unsubscribed from list.example.")
        XCTAssertNil(result.effects)
        XCTAssertTrue(mail.calls.allSatisfy { $0.method == "GET" })
        XCTAssertEqual(post.calls.map(\.method), ["POST"])
        XCTAssertEqual(post.calls.first?.body, "List-Unsubscribe=One-Click")
        XCTAssertEqual(post.calls.first?.bearerToken, "")
    }

    func testConfirmedUnsubscribeCanArchiveAnExplicitlyApprovedBacklogWithoutAFilter() async throws {
        let mail = try gmail(header: "<https://list.example/unsubscribe>", oneClick: true)
        _ = endpoint(200)
        let result = await run(clear: true)
        XCTAssertFalse(result.failed, result.output)
        XCTAssertTrue(result.output.hasPrefix("Unsubscribed from list.example."))
        XCTAssertEqual(mail.calls.filter { $0.method == "POST" }.map(\.path), ["messages/batchModify"])
        XCTAssertTrue(result.effects?.contains { $0.removed.contains("INBOX") } == true)
    }

    func testArchiveFailurePreservesTheConfirmedUnsubscribeInTheReceipt() async throws {
        let mail = try gmail(header: "<https://list.example/unsubscribe>", oneClick: true, archiveStatus: 403)
        _ = endpoint(200)
        let result = await run(clear: true)
        XCTAssertTrue(result.failed)
        XCTAssertTrue(result.output.hasPrefix("Unsubscribed from list.example."), result.output)
        XCTAssertTrue(result.output.contains("archive was not completed"), result.output)
        XCTAssertNil(result.effects)
        XCTAssertFalse(mail.calls.contains { $0.path == "settings/filters" })
    }

    func testUnsubscribeAloneDoesNotPruneTheSendersQueue() {
        XCTAssertFalse(TriageDispatchReconciler.sweepsTheSender("Unsubscribe from this sender"))
        XCTAssertFalse(TriageDispatchReconciler.sweepsTheSender("Use unsubscribe_sender with clear_existing false."))
        XCTAssertTrue(TriageDispatchReconciler.sweepsTheSender("Use unsubscribe_sender with clear_existing true."))
        XCTAssertTrue(TriageDispatchReconciler.sweepsTheSender("Unsubscribe and archive all mail from this sender"))
    }
}

private struct UnsubscribeNetworkFailure: HTTPDataTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw URLError(.timedOut) }
}

private struct UnsubscribeGrants: GoogleGrantStorage {
    func all() -> [GoogleAccountStore.Grant] {
        [.init(email: "owner@example.test", refreshToken: "test", scopes:
            ["https://www.googleapis.com/auth/gmail.modify", GmailManageTools.filterScope], grantedAt: Date(), isPrimary: true)]
    }
    func save(_ grant: GoogleAccountStore.Grant) -> Bool { false }
    func remove(_ email: String) {}
    func removeAll() {}
}

@MainActor private struct UnsubscribeToken: GoogleTokenProvider {
    func token(for email: String?, requiredScopes: [String]) async -> Result<GoogleCredential.Token, GoogleCredential.Failure> {
        .success(.init(accessToken: "test", email: email ?? "owner@example.test", scopes: requiredScopes))
    }
}
