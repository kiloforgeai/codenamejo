import FactoryKit
import Foundation
import GRDB
import XCTest
@testable import CodenameJo

@MainActor
final class AttachmentReplyTests: XCTestCase {
    private var provider: AttachmentReplyProvider!
    private var context: LocalContextStore!
    private var folder: URL!
    private var saved: [String: Any] = [:]
    private let keys = [DraftsOnly.byAccountStorageKey, MailFooter.storageKey,
                        StandingRule.archiveAfterReply.storageKey, MailHeadersOnly.storageKey]

    override func setUp() async throws {
        try await super.setUp()
        Container.shared.manager.push()
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(false, forKey: StandingRule.archiveAfterReply.storageKey)
        UserDefaults.standard.set(false, forKey: MailFooter.storageKey)
        ProfileRuntime.install(.init(profileId: "attachment-profile", isDefault: true,
                                     emails: ["source@example.test", "reply@example.test"]))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        context = LocalContextStore(url: folder.appendingPathComponent("context.sqlite"))
        let context = context!
        Container.shared.localContext.register { context }
        let backend = BackendService(restoringSession: false)
        backend.userId = "attachment-user"
        Container.shared.backend.register { backend }
        let jobs = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        Container.shared.dispatchJobs.register { MainActor.assumeIsolated { jobs } }
        Container.shared.contactStore.register { ContactStore(database: nil) }
        Container.shared.localTriage.register { LocalTriageQueue() }
        Container.shared.googleGrantStorage.register { AttachmentReplyGrants() }
        Container.shared.googleTokenProvider.register { MainActor.assumeIsolated { AttachmentReplyTokens() } }
        provider = AttachmentReplyProvider()
        let provider = provider!
        Container.shared.providerHTTP.register { provider }
    }

    override func tearDown() async throws {
        try? context.dbPool?.close()
        Scope.singleton.reset()
        Container.shared.manager.pop()
        ProfileRuntime.install(nil)
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    private var refs: [[String: String]] { [["account": "source@example.test", "message_id": "source-mail",
        "filename": "deck.pptx", "attachment_id": "deck-bytes"]] }
    private func compose(_ files: [[String: String]]? = nil, name: String = "send_email") async -> FullDuplexBroker.ToolResult {
        await LocalCompose.run(name: name, argumentsJSON: GmailReadTools.json([
            "account": "reply@example.test", "thread_id": "reply-thread", "reply_message_id": "reply-mail",
            "body": "Here is the deck you asked for.", "user_request": "Reply with the deck.", "attachments": files ?? refs]),
            defer: true, conversationId: "attachment-conversation")
    }

    func testReadReferenceToCrossAccountReplyKeepsOnlySelectedBytesAndDestination() async throws {
        let read = await GmailReadTools.run(name: GmailReadTools.getMessage,
            argumentsJSON: GmailReadTools.json(["account": "source@example.test", "message_id": "source-mail"]))
        XCTAssertFalse(read.failed, read.output)
        let row = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(read.output.utf8)) as? [[String: Any]])?.first)
        let result = try XCTUnwrap(row["result"] as? [String: Any])
        var file = try XCTUnwrap((result["attachments"] as? [[String: Any]])?.first)
        file["account"] = row["account"]
        file["message_id"] = result["id"]
        let reply = await LocalCompose.run(name: "send_email", argumentsJSON: GmailReadTools.json([
            "account": "reply@example.test", "thread_id": "reply-thread", "reply_message_id": "reply-mail",
            "body": "Here is the deck you asked for.", "attachments": [file]]), defer: true)
        XCTAssertEqual(reply.ok, true, reply.text)
        XCTAssertFalse(reply.deferred)
        let requests = await provider.requests
        let writes = requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(writes.count, 1)
        let request = try XCTUnwrap(writes.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer reply@example.test")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["threadId"] as? String, "reply-thread")
        let mime = String(decoding: try XCTUnwrap(GmailAPI.decodeBase64URL(body["raw"] as! String)), as: UTF8.self)
        XCTAssertTrue(mime.contains("To: Recipient <recipient@example.test>"), mime)
        XCTAssertTrue(mime.contains("Cc: colleague@example.test"), mime)
        XCTAssertTrue(mime.contains("Subject: Re: Destination request"), mime)
        XCTAssertTrue(mime.contains("In-Reply-To: <reply-rfc@example.test>\r\nReferences: <reply-rfc@example.test>"))
        XCTAssertFalse(mime.contains("Bcc:"))
        XCTAssertFalse(mime.contains("private source correspondence"))
        XCTAssertFalse(mime.contains("other.pdf"))
        XCTAssertFalse(mime.contains("Forwarded message"))
        XCTAssertTrue(mime.contains(Data("Here is the deck you asked for.".utf8).base64EncodedString()))
        XCTAssertTrue(mime.contains("filename=\"deck.pptx\""))
        XCTAssertTrue(mime.contains(MailMIME.base64Lines(AttachmentReplyProvider.bytes)))
        XCTAssertTrue(requests.filter { $0.url?.path.contains("source-mail") == true }.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer source@example.test"
        })
    }

    func testCompleteSelectedReadEnforcesIdentityAndDropsChangedSelectionOrProfile() async throws {
        Container.shared.mailStore.register { MailStore(database: nil, userId: "attachment-user") }
        let key = LiveEmailPresentation.Key(account: "source@example.test", threadId: "source-thread", messageId: "source-mail",
            exchangeId: "", messageIDs: ["source-mail"], selectedIDs: ["source-mail"])
        let args = GmailReadTools.json(["account": "source@example.test", "message_id": "source-mail"])
        for wrong in [["account": "reply@example.test", "message_id": "source-mail"],
                      ["account": "source@example.test", "message_id": "other-mail"]] {
            let refused = await GmailReadTools.readSelectedMessage(argumentsJSON: GmailReadTools.json(wrong), selection: key) { true }
            XCTAssertTrue(refused.failed)
        }
        let absent = await GmailReadTools.readSelectedMessage(argumentsJSON: args, selection: key) { false }
        XCTAssertTrue(absent.failed)
        let noRequests = await provider.requests
        XCTAssertTrue(noRequests.isEmpty)
        await provider.configure("long-source")
        let full = await GmailReadTools.readSelectedMessage(argumentsJSON: args, selection: key) { true }
        XCTAssertFalse(full.failed, full.output)
        XCTAssertTrue(full.output.contains("LATE QUALIFICATION: prefer B only under X"))
        let ordinary = await GmailReadTools.run(name: GmailReadTools.getMessage, argumentsJSON:
            GmailReadTools.json(["account": "source@example.test", "message_id": "source-mail", "complete_selected_source": true]))
        XCTAssertFalse(ordinary.output.contains("LATE QUALIFICATION"), "Tool arguments cannot grant expanded access")
        var checks = 0
        let changed = await GmailReadTools.readSelectedMessage(argumentsJSON: args, selection: key) {
            checks += 1
            return checks == 1
        }
        XCTAssertTrue(changed.failed)
        XCTAssertFalse(changed.output.contains("LATE QUALIFICATION"))
        await provider.configure("read-scope")
        let profile = await GmailReadTools.readSelectedMessage(argumentsJSON: args, selection: key) { true }
        XCTAssertTrue(profile.failed)
        XCTAssertFalse(profile.output.contains("private source correspondence"))
    }

    func testBackgroundReplyPersistsConfirmedReceiptAndRetryDoesNotResend() async throws {
        let job = DispatchWorker.Job(id: UUID(), task: "Reply with the selected deck attachment.",
            account: "reply@example.test", standingOnJSON: GmailReadTools.json([
                "account": "reply@example.test", "id": "reply-mail", "threadId": "reply-thread",
                "from": "recipient@example.test", "subject": "Destination request"]), expects: .receipt,
            profileId: "attachment-profile")
        var rounds = 0
        let result = await DispatchWorker.run(job) { _ in
            rounds += 1
            if rounds == 1 {
                return [["type": "function_call", "name": "send_email", "call_id": "attachment-send",
                    "arguments": GmailReadTools.json(["account": "reply@example.test", "thread_id": "reply-thread",
                        "reply_message_id": "reply-mail", "body": "Here is the deck.", "attachments": self.refs])]]
            }
            return [["type": "message", "content": [["type": "output_text", "text":
                #"{"completed":true,"remaining_work":"none","report":"Sent the requested deck reply."}"#]]]]
        }
        XCTAssertEqual(result.status, .success, result.text)
        let restored = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        let saved = await restored.history().first { $0.id == job.id }
        XCTAssertEqual(saved?.receipts?.first?.tool, "send_email")
        XCTAssertEqual(saved?.receipts?.first?.outcome, "success")
        Container.shared.dispatchJobs.register { restored }
        let retry = await DispatchWorker.run(job) { _ in XCTFail("A confirmed send must not run twice"); return [] }
        XCTAssertEqual(retry.status, .success)
        let writes = await provider.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(writes.count, 1)
    }

    func testDraftModeRetainsAttachmentsWithoutSending() async {
        DraftsOnly.set(true, for: "reply@example.test")
        let result = await compose()
        XCTAssertEqual(result.ok, true, result.text)
        XCTAssertEqual(result.performedTool, "create_draft")
        let writes = await provider.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(writes[0].url?.path.hasSuffix("/drafts") == true)
        XCTAssertTrue(result.text.contains("Nothing was sent"))
    }

    func testMissingWrongAmbiguousOversizedAndFailedDownloadsNeverWrite() async {
        for failure in ["missing", "wrong-message", "ambiguous", "oversized", "download", "truncated", "scope"] {
            await provider.configure(failure)
            let result = await compose()
            XCTAssertEqual(result.ok, false, "\(failure): \(result.text)")
            let writes = await provider.requests.filter { $0.httpMethod == "POST" }
            XCTAssertTrue(writes.isEmpty, failure)
            ProfileRuntime.install(.init(profileId: "attachment-profile", isDefault: true,
                                         emails: ["source@example.test", "reply@example.test"]))
        }
    }

    func testUnavailableSourceAndHeadersOnlyNeverDownloadOrWrite() async {
        for headersOnly in [false, true] {
            ProfileRuntime.install(.init(profileId: "attachment-profile", isDefault: true,
                emails: headersOnly ? ["source@example.test", "reply@example.test"] : ["reply@example.test"],
                mailHeadersOnly: headersOnly))
            let result = await compose()
            XCTAssertEqual(result.ok, false)
            let writes = await provider.requests.filter { $0.httpMethod == "POST" || $0.url?.path.contains("attachments") == true }
            XCTAssertTrue(writes.isEmpty)
        }
    }

    func testCancelledRequestAndStaleFileIDNeverSend() async {
        let task = Task { await self.compose() }
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled.ok, false)
        var stale = refs
        stale[0]["attachment_id"] = "different-file"
        let rejected = await compose(stale)
        XCTAssertEqual(rejected.ok, false)
        let writes = await provider.requests.filter { $0.httpMethod == "POST" }
        XCTAssertTrue(writes.isEmpty)
    }

    func testMultipleAttachmentsAndBrandedBodyHaveCompleteMIME() async throws {
        UserDefaults.standard.set(true, forKey: MailFooter.storageKey)
        let files = refs + [["account": "source@example.test", "message_id": "source-mail", "filename": "other.pdf", "attachment_id": "other-bytes"]]
        let result = await compose(files, name: "create_draft")
        XCTAssertEqual(result.ok, true, result.text)
        let last = await provider.requests.last
        let request = try XCTUnwrap(last)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let message = try XCTUnwrap(root["message"] as? [String: Any])
        let mime = String(decoding: GmailAPI.decodeBase64URL(message["raw"] as! String)!, as: UTF8.self)
        XCTAssertTrue(mime.contains("multipart/mixed"))
        XCTAssertTrue(mime.contains("multipart/alternative"))
        XCTAssertTrue(mime.contains("filename=\"deck.pptx\""))
        XCTAssertTrue(mime.contains("filename=\"other.pdf\""))
        let requests = await provider.requests
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/source-mail") == true }.count, 1)
    }

    func testMalformedAndDuplicateReferencesAreRefused() {
        for value: Any in ["base64-data", refs + refs, [["filename": "deck.pptx"]],
                           [["account": "source@example.test", "message_id": "source-mail", "filename": "bad\r\nfile"]]] {
            XCTAssertThrowsError(try ReplyAttachments.references(value))
        }
        XCTAssertEqual(try ReplyAttachments.references(nil).count, 0)
    }

    func testPlainMailGoldenAndUnicodeAttachmentNames() {
        let raw = MailMIME.plain(.init(to: "a@b.co", subject: "x", body: "ab"))
        XCTAssertEqual(raw, "VG86IGFAYi5jbw0KU3ViamVjdDogeA0KQ29udGVudC1UeXBlOiB0ZXh0L3BsYWluOyBjaGFyc2V0PVVURi04DQoNCmFi")
        let file = ReplyAttachments.File(filename: "資料.pdf", mimeType: "application/pdf", bytes: Data([0, 255, 128]))
        let mime = String(decoding: GmailAPI.decodeBase64URL(MailMIME.plain(.init(to: "a@b.co", subject: "x", body: "ab", attachments: [file])))!, as: UTF8.self)
        XCTAssertTrue(mime.contains(MailMIME.encodeHeader(file.filename)))
        XCTAssertTrue(mime.contains("AP+A"))
    }

    private func plainReply(deferred: Bool = false, callID: String = "reply-call", name: String = "send_email") async -> FullDuplexBroker.ToolResult {
        await LocalCompose.run(name: name, argumentsJSON: GmailReadTools.json([
            "account": "reply@example.test", "thread_id": "reply-thread", "reply_message_id": "reply-mail",
            "body": "Thanks, here are the details.", "user_request": "Reply with these details."]),
            defer: deferred, conversationId: "receipt-conversation", callID: callID)
    }

    private func actions() async -> [DispatchJob] { await Container.shared.dispatchJobs().history().filter { $0.mailAction != nil } }

    func testForegroundReplyPersistsActualContentAndProviderIdentityAcrossRestart() async throws {
        let sent = await plainReply()
        XCTAssertEqual(sent.ok, true, sent.text)
        let restored = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        let history = await restored.history()
        let action = try XCTUnwrap(history.first?.mailAction)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(action.state, .sent)
        XCTAssertEqual(action.account, "reply@example.test")
        XCTAssertEqual(action.to, "Recipient <recipient@example.test>")
        XCTAssertEqual(action.cc, ["colleague@example.test"])
        XCTAssertEqual(action.bcc, [])
        XCTAssertEqual(action.body, "Thanks, here are the details.")
        XCTAssertEqual(action.threadID, "reply-thread")
        XCTAssertEqual(action.replyMessageID, "reply-mail")
        XCTAssertEqual(action.providerMessageID, "sent-1")
        XCTAssertTrue(action.providerURL?.absoluteString.contains("authuser=reply@example.test") == true)
        XCTAssertEqual(history.first?.activityTitle, "Replied to Recipient <recipient@example.test>")
        let repeated = await plainReply()
        XCTAssertEqual(repeated.ok, true)
        let writes = await provider.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(writes.count, 1)
    }

    func testDeferredSendRemainsPendingUntilProviderConfirmsAndQuietReceiptStaysVisible() async throws {
        await provider.configure("delay")
        let result = await plainReply(deferred: true)
        XCTAssertTrue(result.deferred)
        XCTAssertTrue(result.text.contains("not confirmed"))
        let pending = await actions()
        XCTAssertEqual(pending.first?.mailAction?.state, .pending)
        for _ in 0..<100 {
            if await actions().first?.mailAction?.confirmed == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let completed = await actions()
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.mailAction?.state, .sent)
        XCTAssertEqual(completed.first?.reportBack, false)
        XCTAssertNotNil(completed.first?.deliveredAt)
    }

    func testConfirmedSendSurvivesAutomaticArchiveFailure() async {
        UserDefaults.standard.set(true, forKey: StandingRule.archiveAfterReply.storageKey)
        await provider.configure("archive")
        let result = await plainReply()
        XCTAssertEqual(result.ok, true, result.text)
        XCTAssertTrue(result.text.contains("archive was not confirmed"))
        let history = await actions()
        XCTAssertEqual(history.first?.mailAction?.state, .sent)
        XCTAssertEqual(history.first?.mailAction?.providerMessageID, "sent-1")
        XCTAssertEqual(history.first?.activityNeedsAttention, true)
        XCTAssertTrue(history.first?.activityTitle.hasPrefix("Replied to") == true)
    }

    func testTimeoutAndMissingConfirmationRemainUnknownAndCannotReplay() async {
        for failure in ["timeout", "no-id"] {
            await provider.configure(failure)
            let result = await plainReply(callID: failure)
            XCTAssertEqual(result.ok, false)
            XCTAssertTrue(result.outcomeUnknown)
            XCTAssertTrue(result.text.contains("unknown"))
            let retry = await plainReply(callID: failure)
            XCTAssertTrue(retry.outcomeUnknown)
            let writes = await provider.requests.filter { $0.httpMethod == "POST" }
            XCTAssertEqual(writes.count, 1)
        }
        let history = await actions()
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.allSatisfy { $0.mailAction?.state == .unknown })
    }

    func testProviderRejectionIsFailedAndExplicitDraftIsNotSent() async {
        await provider.configure("reject")
        let refused = await plainReply(callID: "refused")
        XCTAssertEqual(refused.ok, false)
        XCTAssertFalse(refused.outcomeUnknown)
        await provider.configure("")
        let draft = await plainReply(callID: "draft", name: "create_draft")
        XCTAssertEqual(draft.ok, true, draft.text)
        let history = await actions()
        XCTAssertEqual(Set(history.compactMap { $0.mailAction?.state }), [.failed, .draft])
        XCTAssertEqual(history.first?.mailAction?.providerMessageID, "draft-message-1")
    }

    func testSavedCommandSendGetsOneReceiptWithoutDuplicateParent() async throws {
        let step = CommandAction(tool: "send_email", detail: "Reply saying thanks.")
        let job = DispatchWorker.Job(id: UUID(), task: "Reply saying thanks.", account: "reply@example.test",
            standingOnJSON: GmailReadTools.json(["account": "reply@example.test", "id": "reply-mail", "threadId": "reply-thread",
                                               "from": "recipient@example.test", "subject": "Destination request"]),
            expects: .receipt, commandSteps: [step], command: .init(keyword: "thanks", actions: [step]), profileId: "attachment-profile")
        var round = 0
        let result = await DispatchWorker.run(job) { _ in
            round += 1
            if round == 1 {
                return [["type": "function_call", "name": "send_email", "call_id": "command-reply",
                    "arguments": #"{"account":"reply@example.test","thread_id":"reply-thread","reply_message_id":"reply-mail","body":"Thanks!"}"#]]
            }
            return [["type": "message", "content": [["type": "output_text", "text":
                #"{"completed":true,"remaining_work":"none","report":"Reply sent."}"#]]]]
        }
        XCTAssertEqual(result.status, .success)
        let history = await actions()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.mailAction?.state, .sent)
        XCTAssertEqual(history.first?.mailAction?.body, "Thanks!")
        XCTAssertEqual(history.first?.mailAction?.parentJobID, job.id)
        let model = DesktopWorkspaceModel()
        model.jobs = await Container.shared.dispatchJobs().history()
        XCTAssertEqual(model.activityJobs.count, 1)
    }

    func testBackgroundSendRemainsVisibleAfterActualReadFailure() async throws {
        let job = DispatchWorker.Job(id: UUID(), task: "Reply, then inspect the missing message.",
            account: "reply@example.test", expects: .receipt, profileId: "attachment-profile")
        var round = 0
        _ = await DispatchWorker.run(job) { _ in
            round += 1
            if round == 1 {
                return [["type": "function_call", "name": "send_email", "call_id": "send-before-read",
                    "arguments": #"{"account":"reply@example.test","thread_id":"reply-thread","reply_message_id":"reply-mail","body":"Thanks!"}"#]]
            }
            if round == 2 {
                return [["type": "function_call", "name": GmailReadTools.getMessage, "call_id": "read-failed",
                    "arguments": #"{"account":"reply@example.test","message_id":"missing-read"}"#]]
            }
            return [["type": "message", "content": [["type": "output_text", "text":
                #"{"completed":false,"remaining_work":"input","report":"The reply sent; the later read failed."}"#]]]]
        }
        let history = await actions()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.mailAction?.state, .sent)
        let requests = await provider.requests
        XCTAssertTrue(requests.contains { $0.url?.path.hasSuffix("/missing-read") == true })
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testUnknownBackgroundSendStopsTheWorkerWithoutAFalseFailedReceipt() async {
        await provider.configure("timeout")
        let job = DispatchWorker.Job(id: UUID(), task: "Reply saying thanks.",
            account: "reply@example.test", expects: .receipt, profileId: "attachment-profile")
        let result = await DispatchWorker.run(job) { _ in
            [["type": "function_call", "name": "send_email", "call_id": "unknown-send",
                "arguments": #"{"account":"reply@example.test","thread_id":"reply-thread","reply_message_id":"reply-mail","body":"Thanks!"}"#]]
        }
        XCTAssertEqual(result.status, .pending)
        XCTAssertEqual(Container.shared.dispatchJobs().existing(job.id)?.state, "unknown")
        let history = await actions()
        XCTAssertEqual(history.first?.mailAction?.state, .unknown)
        let requests = await provider.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testReceiptScopeAndContentFreeExport() async throws {
        _ = await plainReply()
        let history = await actions()
        let redacted = String(decoding: try SessionExport.append(records: [], jobs: history, to: Data(), includeContent: false), as: UTF8.self)
        for privateText in ["reply@example.test", "recipient@example.test", "Thanks, here", "reply-thread", "sent-1"] {
            XCTAssertFalse(redacted.contains(privateText))
        }
        ProfileRuntime.install(.init(profileId: "other", isDefault: false, emails: ["reply@example.test"]))
        let otherProfile = await actions()
        XCTAssertTrue(otherProfile.isEmpty)
        ProfileRuntime.install(.init(profileId: "attachment-profile", isDefault: true, emails: ["reply@example.test"]))
        Container.shared.backend().userId = "another-user"
        let otherUser = await actions()
        XCTAssertTrue(otherUser.isEmpty)
    }

    func testInterruptedAttemptRestoresAsUnknownAndProviderReceiptDeduplicates() async throws {
        let store = Container.shared.dispatchJobs()
        let action = MailActionReceipt(kind: .send, account: "reply@example.test",
            message: .init(to: "recipient@example.test", subject: "Synthetic receipt", body: "Private fixture body"), replyMessageID: nil)
        let (first, _) = try await store.beginMailAction(action, ownerID: "attachment-user", profileID: "attachment-profile", conversationID: nil, origin: nil)
        let restored = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        XCTAssertEqual(restored.mailAction(first.id)?.mailAction?.state, .unknown)
        await store.recordMailAction(first.id, state: .sent, result: "Confirmed", provider: ["id": "same-message"])
        let (second, _) = try await store.beginMailAction(action, ownerID: "attachment-user", profileID: "attachment-profile", conversationID: nil, origin: nil)
        await store.recordMailAction(second.id, state: .sent, result: "Confirmed again", provider: ["id": "same-message"])
        let history = await store.history()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.id, first.id)
    }

    func testQueuedDraftKeepsOneReceiptThroughRetryAndDoesNotRepeatConfirmedWrite() async throws {
        let message = MailMIME.Outgoing(to: "recipient@example.test", subject: "Queued draft", body: "Draft fixture")
        let action = MailActionReceipt(kind: .draft, account: "reply@example.test", message: message, replyMessageID: nil)
        let store = Container.shared.dispatchJobs()
        let (receipt, _) = try await store.beginMailAction(action, ownerID: "attachment-user", profileID: "attachment-profile", conversationID: nil, origin: nil)
        await store.recordMailAction(receipt.id, state: .queued, result: "Rate limited")
        let queued = PendingMailWrite.QueuedDraft(raw: MailMIME.plain(message), to: message.to, threadId: nil, mailActionID: receipt.id)
        let pending = PendingMailWrite(id: UUID().uuidString, user_id: "attachment-user", operation: "create_draft", account: action.account,
            messageId: "draft-digest", threadId: nil, conversationId: nil, attempts: 1, dueAt: Date(), createdAt: Date(),
            completedAt: nil, state: .pending, lastError: nil, payload: String(decoding: try JSONEncoder().encode(queued), as: UTF8.self))
        _ = try await PendingMailWrites.gmail(pending)
        _ = try await PendingMailWrites.gmail(pending)
        XCTAssertEqual(store.mailAction(receipt.id)?.mailAction?.state, .draft)
        let requests = await provider.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testDuplicateQueuedDraftKeepsOriginalReceiptWithoutLeavingAnotherPending() async throws {
        let pool = try DatabasePool(path: folder.appendingPathComponent("pending.sqlite").path)
        defer { try? pool.close() }
        try await pool.write { try PendingMailWrite.createSchema($0); try PendingMailWrite.addPayload($0) }
        let queue = PendingMailWrites(dbPool: pool)
        let store = Container.shared.dispatchJobs()
        let message = MailMIME.Outgoing(to: "recipient@example.test", subject: "Queued draft", body: "Draft fixture")
        let action = MailActionReceipt(kind: .draft, account: "reply@example.test", message: message, replyMessageID: nil)
        let (first, _) = try await store.beginMailAction(action, ownerID: "attachment-user", profileID: "attachment-profile", conversationID: nil, origin: nil)
        let (second, _) = try await store.beginMailAction(action, ownerID: "attachment-user", profileID: "attachment-profile", conversationID: nil, origin: nil)
        let queued = PendingMailWrite.QueuedDraft(raw: MailMIME.plain(message), to: message.to, threadId: nil, mailActionID: first.id)
        _ = try await queue.enqueueDraft(userId: "attachment-user", account: action.account, draft: queued, conversationId: nil, delay: 60)
        await store.recordMailAction(first.id, state: .queued, result: "Awaiting retry")
        var duplicate = queued
        duplicate.mailActionID = second.id
        do {
            _ = try await queue.enqueueDraft(userId: "attachment-user", account: action.account, draft: duplicate, conversationId: nil, delay: 60)
            XCTFail("The duplicate must not leave a pending receipt")
        } catch { XCTAssertTrue(error is PendingMailWrites.Unrecoverable) }
        XCTAssertEqual(store.mailAction(first.id)?.mailAction?.state, .queued)
        XCTAssertEqual(store.mailAction(second.id)?.mailAction?.state, .failed)
        let rows = try await pool.read { try PendingMailWrite.fetchAll($0) }
        XCTAssertEqual(rows.count, 1)
    }

    func testQueuedDraftWithUnknownOutcomeCannotBeRetried() async throws {
        await provider.configure("timeout")
        let message = MailMIME.Outgoing(to: "recipient@example.test", subject: "Queued draft", body: "Draft fixture")
        let store = Container.shared.dispatchJobs()
        let (receipt, _) = try await store.beginMailAction(.init(kind: .draft, account: "reply@example.test", message: message, replyMessageID: nil),
            ownerID: "attachment-user", profileID: "attachment-profile", conversationID: nil, origin: nil)
        await store.recordMailAction(receipt.id, state: .queued, result: "Rate limited")
        let queued = PendingMailWrite.QueuedDraft(raw: MailMIME.plain(message), to: message.to, threadId: nil, mailActionID: receipt.id)
        let pending = PendingMailWrite(id: UUID().uuidString, user_id: "attachment-user", operation: "create_draft", account: "reply@example.test",
            messageId: "draft-digest", threadId: nil, conversationId: nil, attempts: 1, dueAt: Date(), createdAt: Date(),
            completedAt: nil, state: .pending, lastError: nil, payload: String(decoding: try JSONEncoder().encode(queued), as: UTF8.self))
        for _ in 0..<2 {
            do { _ = try await PendingMailWrites.gmail(pending); XCTFail("Unknown draft must remain stopped") }
            catch { XCTAssertTrue(error is PendingMailWrites.Unrecoverable) }
        }
        XCTAssertEqual(store.mailAction(receipt.id)?.mailAction?.state, .unknown)
        let requests = await provider.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testActivityProjectionKeepsOlderRepliesAndOmitsDuplicateSuccessfulParent() {
        let parent = UUID()
        let action = MailActionReceipt(kind: .send, account: "reply@example.test",
            message: .init(to: "recipient@example.test", subject: "Old reply", body: "Thanks"), replyMessageID: nil, parentJobID: parent)
        let reply = DispatchJob(id: UUID(), task: "Reply", state: "done", deliveredAt: Date(), mailAction: action)
        let model = DesktopWorkspaceModel()
        model.jobs = (0..<18).map { DispatchJob(id: UUID(), task: "Archive \($0)", state: "done", deliveredAt: Date()) }
            + [DispatchJob(id: parent, task: "Reply", state: "done", deliveredAt: Date(),
                           receipts: [.init(callId: "send", tool: "send_email", outcome: "success")]), reply]
        XCTAssertEqual(model.activityJobs.count, 19)
        XCTAssertEqual(model.activityJobs.last?.id, reply.id)
        XCTAssertFalse(model.activityJobs.contains { $0.id == parent })
    }
}

private actor AttachmentReplyProvider: HTTPDataTransport {
    static let bytes = Data((0..<1024).map { UInt8($0 % 256) })
    var requests: [URLRequest] = []
    private var failure = ""
    func configure(_ value: String) { failure = value; requests = [] }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url!.path
        var status = 200
        let body: [String: Any]
        if request.httpMethod == "POST" {
            let index = requests.filter { $0.httpMethod == "POST" }.count
            if failure == "delay" { try await Task.sleep(for: .milliseconds(150)) }
            if failure == "timeout" { throw URLError(.timedOut) }
            if failure == "archive", path.hasSuffix("/modify") { status = 500 }
            if failure == "reject" { status = 403 }
            body = failure == "no-id" ? [:] : path.hasSuffix("/drafts")
                ? ["id": "draft-\(index)", "message": ["id": "draft-message-\(index)", "threadId": "reply-thread"]]
                : ["id": "sent-\(index)", "threadId": "reply-thread"]
        }
        else if path.contains("/attachments/") {
            if failure == "download" { status = 404 }
            if failure == "scope" { ProfileRuntime.install(.init(profileId: "other", isDefault: false, emails: [])) }
            let bytes = failure == "truncated" ? Data([1]) : Self.bytes
            body = ["size": bytes.count, "data": bytes.base64EncodedString()]
        } else if path.hasSuffix("/source-mail") {
            if failure == "read-scope" { ProfileRuntime.install(.init(profileId: "other", isDefault: false, emails: [])) }
            let file: [String: Any] = ["filename": "deck.pptx", "mimeType": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
                "body": ["size": failure == "oversized" ? LocalForward.attachmentCap + 1 : Self.bytes.count, "attachmentId": "deck-bytes"]]
            var parts = failure == "missing" ? [] : [file]
            if failure == "ambiguous" { parts.append(file) }
            parts += [["filename": "other.pdf", "mimeType": "application/pdf", "body": ["size": Self.bytes.count, "attachmentId": "other-bytes"]],
                      ["mimeType": "text/plain", "body": ["data": Data((failure == "long-source"
                        ? String(repeating: "Earlier discussion. ", count: 1500) + "LATE QUALIFICATION: prefer B only under X"
                        : "private source correspondence").utf8).base64EncodedString()]]]
            body = ["id": failure == "wrong-message" ? "different-mail" : "source-mail", "threadId": "source-thread", "labelIds": [],
                    "payload": ["mimeType": "multipart/mixed", "parts": parts]]
        } else if path.hasSuffix("/sendAs") { body = ["sendAs": [["sendAsEmail": "reply@example.test"]]] }
        else {
            let headers = [("From", "Recipient <recipient@example.test>"), ("To", "reply@example.test"),
                ("Cc", "colleague@example.test"), ("Subject", "Destination request"), ("Message-ID", "<reply-rfc@example.test>")]
            body = ["id": "reply-thread", "messages": [["id": "reply-mail", "threadId": "reply-thread", "labelIds": ["INBOX"],
                "payload": ["headers": headers.map { ["name": $0.0, "value": $0.1] }]]]]
        }
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
private final class AttachmentReplyTokens: GoogleTokenProvider {
    func token(for email: String?, requiredScopes: [String]) async -> Result<GoogleCredential.Token, GoogleCredential.Failure> {
        .success(.init(accessToken: email!, email: email!, scopes: requiredScopes))
    }
}
private final class AttachmentReplyGrants: GoogleGrantStorage, @unchecked Sendable {
    func all() -> [GoogleAccountStore.Grant] {
        ["source@example.test", "reply@example.test"].map { .init(email: $0, refreshToken: "fixture", scopes: [
            "https://www.googleapis.com/auth/gmail.modify"], grantedAt: Date(), isPrimary: $0.hasPrefix("reply")) }
    }
    func save(_ grant: GoogleAccountStore.Grant) -> Bool { true }
    func remove(_ email: String) {}
    func removeAll() {}
}
