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
        let mail = MailStore(database: context.dbPool, userId: "live-fixture-user")
        Container.shared.mailStore.register { mail }
        let transport = FixtureTransport(account: account, token: token.accessToken, namespace: folder.lastPathComponent)
        Container.shared.providerHTTP.register { transport }
        var evidence: [[String: Any]] = []
        var fixtures: [MailStore.Ingest] = []
        for index in 1...2 {
            let raw = "From: \(account)\r\nTo: \(account)\r\nSubject: \(folder.lastPathComponent) fixture same subject\r\nMessage-ID: <\(UUID().uuidString)@jo-qa.invalid>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nSynthetic Jo archive test \(index). No reply required.\r\n"
            let encoded = Data(raw.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let sent = try await GmailAPI.call("POST", path: "messages/send", body: ["raw": encoded], token: token.accessToken)
            let id = try XCTUnwrap(sent["id"] as? String)
            let thread = try XCTUnwrap(sent["threadId"] as? String)
            // Ensure the synthetic message starts in Inbox, even under account delivery filters.
            _ = try await GmailAPI.call("POST", path: "messages/\(id)/modify", body: ["addLabelIds": ["INBOX"]], token: token.accessToken)
            let before = try await GmailAPI.call("GET", path: "messages/\(id)", query: ["format": "metadata"], token: token.accessToken)
            XCTAssertTrue((before["labelIds"] as? [String] ?? []).contains("INBOX"))
            let detail = try JSONDecoder().decode(GmailAPI.MessageDetail.self, from: JSONSerialization.data(withJSONObject: before))
            XCTAssertEqual(detail.threadId, thread)
            fixtures.append(.init(detail: detail, account: account))
        }
        fixtures.sort { ($0.message.internalDate ?? 0) > ($1.message.internalDate ?? 0) }
        XCTAssertEqual(fixtures[0].message.subject, fixtures[1].message.subject)
        XCTAssertNotEqual(fixtures[0].message.id, fixtures[1].message.id)
        await mail.cache(fixtures)
        let queue = LocalTriageQueue(mailAccounts: { [account] }, unreadOpeningLoader: { _ in nil })
        await queue.adopt(fixtures.map(\.message), store: mail)
        let moved = await queue.step(.init(direction: "next"), store: mail, dealtWith: false)
        XCTAssertEqual(LiveEmailPresentation.Key.selection(moved.output)?.messageId, fixtures[1].message.id, moved.output)
        var center = FeedFocusTracker()
        _ = center.applyTriage(output: moved.output)
        for (index, fixture) in fixtures.enumerated() {
            let id = fixture.message.id, thread = fixture.message.threadId
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
            _ = await queue.applyConfirmedEffects([.init(account: account, scope: "message", threadId: thread,
                messageIds: [id], messageIdsComplete: true, operation: "modify", removeLabelIds: ["INBOX"])], store: mail)
            if index == 0 {
                let nextID = fixtures[1].message.id
                let remaining = try await GmailAPI.call("GET", path: "messages/\(nextID)", query: ["format": "minimal"], token: token.accessToken)
                XCTAssertTrue((remaining["labelIds"] as? [String] ?? []).contains("INBOX"))
                let feed = DesktopSessionFeed(mail: await queue.desktopSnapshot())
                XCTAssertEqual(feed.current?.messageID, nextID)
                XCTAssertFalse(feed.rows.contains { $0.selection?.messageID == id })
                guard case .email(let focused) = center.focus else { XCTFail("The center lost the selected email"); return }
                XCTAssertEqual(focused.messageId, nextID)
                let held = await queue.hold(.init(jobId: job.id, task: "Archive this email", text: "Archive receipt already reported",
                    ok: true, expects: .answer, about: .init(account: account, id: id, threadId: thread, from: account, subject: "Same fixture subject")))
                XCTAssertTrue(held)
                await jobs.settle(job.id)
                let finished = await queue.step(.init(direction: "next"), store: mail, dealtWith: false)
                XCTAssertFalse(finished.output.contains("Archive receipt already reported"), finished.output)
                XCTAssertFalse(finished.output.contains("presentedForOutcome"), finished.output)
                XCTAssertTrue(finished.output.contains("inbox is NOT clear"), finished.output)
                let served = await queue.takeServedOutcomes()
                XCTAssertTrue(served.isEmpty)
                _ = center.applyTriage(output: finished.output)
                XCTAssertNil(center.focus, "A finished search batch must clear its old email card")
            }
            await jobs.settle(job.id)
            let writes = await transport.writes
            job.id = UUID()
            let repeated = await DispatchWorker.run(job) { _ in XCTFail("A duplicate must reuse its receipt"); return [] }
            XCTAssertEqual(repeated.status, .success)
            let finalWrites = await transport.writes
            XCTAssertEqual(finalWrites, writes)
            evidence.append(["message_id": id, "thread_id": thread,
                "before_inbox": fixture.labels.contains("INBOX"),
                "after_inbox": (after["labelIds"] as? [String] ?? []).contains("INBOX"),
                "outcome": outcome.status?.rawValue ?? "unknown", "archive_seconds": duration,
                "duplicate_extra_writes": finalWrites - writes])
        }
        await queue.end()
        let history = await jobs.history()
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.allSatisfy { $0.isDone && $0.receipts?.first?.outcome == "success" })
        let restored = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        let recovered = await restored.recover()
        XCTAssertTrue(recovered.isEmpty, "Restart must not replay delivered archive results")
        let manifest = try JSONSerialization.data(withJSONObject: ["namespace": folder.lastPathComponent,
            "profile": "Jo QA", "account": account, "fixtures": evidence, "audibility": "not_tested",
            "assertion_failures": testRun?.failureCount ?? -1,
            "checks": ["equal_subject_identity", "off_cursor_archive", "sidebar_and_center_model", "held_result_delivery", "scoped_completion", "restart_receipts"]], options: [.prettyPrinted, .sortedKeys])
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
