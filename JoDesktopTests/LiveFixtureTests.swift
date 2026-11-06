import FactoryKit
import Foundation
import XCTest
@testable import CodenameJo

@MainActor
final class LiveFixtureTests: XCTestCase {
    func testSelfAddressedArchiveReceipts() async throws {
        #if JO_LIVE_QA
        guard let account = ProcessInfo.processInfo.environment["JO_QA_MAILBOX"]?.lowercased(),
              !account.isEmpty else { throw XCTSkip("Set JO_QA_MAILBOX to an authorized self-addressed test mailbox.") }
        let credential = await KeychainTokenProvider().token(for: account, requiredScopes: GoogleCredential.requiredScopes)
        guard case .success(let token) = credential, token.email?.lowercased() == account else {
            XCTFail("The explicitly authorized QA mailbox needs a usable Gmail grant.")
            return
        }
        Container.shared.manager.push()
        let priorScope = ProfileRuntime.snapshot
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("JO-QA-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = LocalContextStore(url: folder.appendingPathComponent("context.sqlite"))
        defer {
            try? context.dbPool?.close()
            Scope.singleton.reset()
            Container.shared.manager.pop()
            ProfileRuntime.install(priorScope)
        }
        let backend = BackendService(restoringSession: false)
        backend.userId = "live-fixture-user"
        Container.shared.backend.register { backend }
        Container.shared.localContext.register { context }
        let rows = WorkspaceProfileRows(dbPool: context.dbPool)
        let profile = try await rows.create(userId: "live-fixture-user", name: "Jo QA")
        try await rows.adopt(userId: "live-fixture-user", emails: [account], into: profile.id)
        ProfileRuntime.install(.init(profileId: profile.id, isDefault: false, emails: [account]))
        let tokens = FixtureTokens(token: token)
        Container.shared.googleTokenProvider.register { tokens }
        let jobs = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        Container.shared.dispatchJobs.register { jobs }
        let transport = FixtureTransport(account: account, token: token.accessToken, namespace: folder.lastPathComponent)
        Container.shared.providerHTTP.register { transport }
        var evidence: [[String: Any]] = []
        for index in 1...2 {
            let raw = "From: \(account)\r\nTo: \(account)\r\nSubject: \(folder.lastPathComponent) fixture \(index)\r\nMessage-ID: <\(UUID().uuidString)@jo-qa.invalid>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nSynthetic Jo archive test \(index). No reply required.\r\n"
            let encoded = Data(raw.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let sent = try await GmailAPI.call("POST", path: "messages/send", body: ["raw": encoded], token: token.accessToken)
            let id = try XCTUnwrap(sent["id"] as? String)
            let thread = try XCTUnwrap(sent["threadId"] as? String)
            // Ensure the synthetic message starts in Inbox, even under account delivery filters.
            _ = try await GmailAPI.call("POST", path: "messages/\(id)/modify", body: ["addLabelIds": ["INBOX"]], token: token.accessToken)
            let before = try await GmailAPI.call("GET", path: "messages/\(id)", query: ["format": "minimal"], token: token.accessToken)
            XCTAssertTrue((before["labelIds"] as? [String] ?? []).contains("INBOX"))
            var job = DispatchWorker.Job(id: UUID(), task: "Archive this email", account: account,
                standingOnJSON: GmailReadTools.json(["id": id, "threadId": thread, "account": account, "from": account]),
                expects: .receipt, profileId: profile.id,
                operation: DispatchMailOperation.archiveRequest("archive this email", account: account, messageID: id))
            let started = Date()
            let outcome = await DispatchWorker.run(job) { _ in
                XCTFail("The live archive must finish from Gmail's receipt without a model round")
                throw URLError(.timedOut)
            }
            XCTAssertEqual(outcome.status, .success, outcome.text)
            let duration = Date().timeIntervalSince(started)
            let after = try await GmailAPI.call("GET", path: "messages/\(id)", query: ["format": "minimal"], token: token.accessToken)
            XCTAssertFalse((after["labelIds"] as? [String] ?? ["INBOX"]).contains("INBOX"))
            let writes = await transport.writes
            job.id = UUID()
            let repeated = await DispatchWorker.run(job) { _ in XCTFail("A duplicate must reuse its receipt"); return [] }
            XCTAssertEqual(repeated.status, .success)
            let finalWrites = await transport.writes
            XCTAssertEqual(finalWrites, writes)
            evidence.append(["message_id": id, "thread_id": thread,
                "before_inbox": (before["labelIds"] as? [String] ?? []).contains("INBOX"),
                "after_inbox": (after["labelIds"] as? [String] ?? []).contains("INBOX"),
                "outcome": outcome.status?.rawValue ?? "unknown", "archive_seconds": duration,
                "duplicate_extra_writes": finalWrites - writes])
        }
        let history = await jobs.history()
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.allSatisfy { $0.isDone && $0.receipts?.first?.outcome == "success" })
        let manifest = try JSONSerialization.data(withJSONObject: ["namespace": folder.lastPathComponent,
            "profile": "Jo QA", "account": account, "fixtures": evidence, "audibility": "not_tested"], options: [.prettyPrinted, .sortedKeys])
        try manifest.write(to: folder.appendingPathComponent("manifest.json"))
        let attachment = XCTAttachment(data: manifest, uniformTypeIdentifier: "public.json")
        attachment.name = "Self-addressed Gmail fixture results"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("JO_QA_MANIFEST " + folder.appendingPathComponent("manifest.json").path)
        #else
        throw XCTSkip("Requires explicit self-addressed fixture authorization and JO_LIVE_QA build flag.")
        #endif
    }
}

#if JO_LIVE_QA
@MainActor
private final class FixtureTokens: GoogleTokenProvider {
    let token: GoogleCredential.Token
    init(token: GoogleCredential.Token) { self.token = token }
    func token(for email: String?, requiredScopes: [String]) async -> Result<GoogleCredential.Token, GoogleCredential.Failure> {
        guard email?.lowercased() == token.email?.lowercased() else { return .failure(.noStoredGrant) }
        return .success(token)
    }
}

private actor FixtureTransport: HTTPDataTransport {
    let account: String, token: String, namespace: String
    var messages = Set<String>(), threads = Set<String>()
    var requests = 0, writes = 0, sends = 0
    init(account: String, token: String, namespace: String) {
        self.account = account; self.token = token; self.namespace = namespace
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        guard requests <= 40, let url = request.url, url.scheme == "https", url.host == "gmail.googleapis.com",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" else { throw URLError(.noPermissionsToReadFile) }
        let path = url.path.replacingOccurrences(of: "/gmail/v1/users/me/", with: "")
        let method = request.httpMethod ?? "GET"
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        let sending = method == "POST" && path == "messages/send"
        if sending {
            guard sends < 2, Set(body.keys) == ["raw"], let raw = body["raw"] as? String,
                  let data = GmailAPI.decodeBase64URL(raw), let mail = String(data: data, encoding: .utf8) else { throw URLError(.noPermissionsToReadFile) }
            let headers = mail.components(separatedBy: "\r\n\r\n")[0].components(separatedBy: "\r\n")
            guard headers.count == 5, headers[0] == "From: \(account)", headers[1] == "To: \(account)",
                  headers[2].hasPrefix("Subject: \(namespace) fixture "), headers[3].hasPrefix("Message-ID: <"),
                  headers[4] == "Content-Type: text/plain; charset=utf-8" else { throw URLError(.noPermissionsToReadFile) }
            sends += 1
        } else {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 2, (parts[0] == "messages" && messages.contains(parts[1])) ||
                    (parts[0] == "threads" && threads.contains(parts[1])) else { throw URLError(.noPermissionsToReadFile) }
            if method == "POST" {
                guard parts.count == 3, parts[2] == "modify", Set(body.keys).isSubset(of: ["addLabelIds", "removeLabelIds"]),
                      Set(body["addLabelIds"] as? [String] ?? []).isSubset(of: ["INBOX"]),
                      Set(body["removeLabelIds"] as? [String] ?? []).isSubset(of: ["INBOX", "UNREAD"]) else { throw URLError(.noPermissionsToReadFile) }
            } else if method != "GET" || parts.count != 2 { throw URLError(.noPermissionsToReadFile) }
        }
        if method != "GET" { writes += 1 }
        let result = try await URLSessionDataTransport().data(for: request)
        if sending, let response = result.1 as? HTTPURLResponse, (200..<300).contains(response.statusCode),
           let json = try JSONSerialization.jsonObject(with: result.0) as? [String: Any],
           let id = json["id"] as? String, let thread = json["threadId"] as? String {
            messages.insert(id); threads.insert(thread)
        }
        return result
    }
}
#endif
