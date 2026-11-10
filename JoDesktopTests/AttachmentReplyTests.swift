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
                        StandingRule.archiveAfterReply.storageKey, StandingRule.archiveAfterForward.storageKey, MailHeadersOnly.storageKey]

    override func setUp() async throws {
        try await super.setUp()
        Container.shared.manager.push()
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(false, forKey: StandingRule.archiveAfterReply.storageKey)
        UserDefaults.standard.set(false, forKey: StandingRule.archiveAfterForward.storageKey)
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

    @MainActor private final class SessionFeedback: UserFeedback {
        var session = UUID()
        var notes: [String] = []
        override func capture() -> Submission {
            .init(userID: "attachment-user", context: .init(sessionID: session,
                conversationID: session, profileID: "attachment-profile"))
        }
        override func save(_ message: String, source: FeedbackSource, submission: Submission) async throws -> UUID {
            notes.append(message)
            return submission.noteID ?? UUID()
        }
    }

    func testExtendedFeedUseKeepsReplyExecutionAfterFeedbackAndRefusals() async throws {
        for variant in ["none", "saved", "unfinished", "cancelled"] {
            let feedback = SessionFeedback()
            feedback.voiceSaveDelay = .milliseconds(5)
            var offset = 0
            var accepted: [String] = []
            var wire: [[String: Any]] = []
            var adapter: LiveSessionAdapter!
            adapter = LiveSessionAdapter(wire: { wire.append($0) }, emit: { signal in
                if case .liveInputFinished(let text) = signal {
                    if feedback.voiceInput(text, turnID: "turn-\(offset)", reply: { _ in }, transition: { _ in }) {
                        adapter.resolveLocalInput(applicationResult: "Handled as feedback", allowPresentation: false)
                    } else if let action = LiveFastAction.parse(text) {
                        let id = "voice-\(offset)"
                        if adapter.beginFastAction(callId: id, action: action) { accepted.append(id) }
                    }
                }
                if case .liveButtonAction(let id, _) = signal { accepted.append(id) }
            })
            defer { adapter.close() }
            adapter.enableClientDelegation { _ in
                XCTFail("Local actions must not need a model round trip")
                return ["output": []]
            }
            func receive(_ event: [String: Any]) throws { adapter.receive(try JSONSerialization.data(withJSONObject: event)) }
            func result(_ id: String, _ text: String) {
                adapter.outbound(["type": "conversation.item.create", "item": [
                    "type": "function_call_output", "call_id": id, "output": text]])
            }
            try receive(["type": "session.started"])
            for event in wire where event["type"] as? String == "session.instructions.append" {
                try receive(["type": "session.instructions.appended", "client_event_id": event["event_id"]!])
            }
            if variant != "none" {
                XCTAssertTrue(feedback.voiceInput("Record feedback: workspace search did not start", turnID: "feedback",
                    reply: { _ in }, transition: { _ in }))
                if variant != "unfinished" {
                    XCTAssertTrue(feedback.voiceInput(variant == "saved" ? "save it" : "cancel feedback", turnID: "finish",
                        reply: { _ in }, transition: { _ in }))
                }
                try await Task.sleep(for: .milliseconds(40))
            }
            let before = await provider.requests.filter { $0.url?.path.hasSuffix("/messages/send") == true }.count
            var replyCount = 0
            for session in 0..<2 {
                for index in 0..<30 {
                    offset += 3000
                    let action: LiveFastAction = index.isMultiple(of: 2) ? .archive : .next
                    let id: String
                    if index.isMultiple(of: 3) {
                        id = "voice-\(offset)"
                        try receive(["type": "session.input_transcript.delta", "delta": action.requestText,
                            "start_ms": offset, "end_ms": offset + 100])
                        for _ in 0..<150 where !accepted.contains(id) { try await Task.sleep(for: .milliseconds(5)) }
                    } else {
                        id = "click-\(offset)"
                        XCTAssertTrue(adapter.beginButtonAction(callId: id, action: action))
                    }
                    XCTAssertEqual(accepted.filter { $0 == id }.count, 1)
                    XCTAssertFalse(adapter.beginButtonAction(callId: "duplicate-\(offset)", action: action))
                    try await Task.sleep(for: .milliseconds(2))
                    result(id, "The application is presenting the action result.")
                    if index % 10 == 9 {
                        let request = "Reply to this email: thanks, received"
                        XCTAssertFalse(feedback.voiceInput(request, turnID: "reply-\(offset)", reply: { _ in }, transition: { _ in }))
                        let call = "\(variant)-\(session)-\(index)"
                        let reply = await LocalCompose.run(name: "send_email", argumentsJSON: #"{"body":"Thanks, received."}"#,
                            defer: false, conversationId: feedback.session.uuidString, callID: call, replySource: selectedReply())
                        XCTAssertEqual(reply.ok, true, reply.text)
                        replyCount += 1
                        let duplicate = await LocalCompose.run(name: "send_email", argumentsJSON: #"{"body":"Thanks, received."}"#,
                            defer: false, conversationId: feedback.session.uuidString, callID: call, replySource: selectedReply())
                        XCTAssertEqual(duplicate.ok, true)
                    }
                }
                // A locally refused background attempt must not hold subsequent replies.
                XCTAssertNotNil(LiveRequestRecovery.dispatchRefusal("[sniffing]"))
                XCTAssertFalse(feedback.voiceInput("Reply: thank you", turnID: "after-refusal-\(session)", reply: { _ in }, transition: { _ in }))
                let recovered = await LocalCompose.run(name: "send_email", argumentsJSON: #"{"body":"Thank you."}"#,
                    defer: false, conversationId: feedback.session.uuidString, callID: "\(variant)-recovered-\(session)", replySource: selectedReply())
                XCTAssertEqual(recovered.ok, true, recovered.text)
                replyCount += 1
                feedback.suspendVoiceCapture(endingSession: true)
                feedback.session = UUID()
            }
            let after = await provider.requests.filter { $0.url?.path.hasSuffix("/messages/send") == true }.count
            XCTAssertEqual(after - before, replyCount, "One provider send per authorized request; no replay")
            XCTAssertEqual(accepted.count, 60)
            XCTAssertTrue(feedback.notes.allSatisfy { $0 == "workspace search did not start" })
            let receipts = await actions()
            XCTAssertTrue(receipts.filter { $0.mailAction?.requestKey?.contains(variant) == true }
                .allSatisfy { $0.mailAction?.state == .sent && $0.origin?.messageID == "reply-mail" })
        }
    }

    private var refs: [[String: String]] { [["account": "source@example.test", "message_id": "source-mail",
        "filename": "deck.pptx", "attachment_id": "deck-bytes"]] }
    private func compose(_ files: [[String: String]]? = nil, name: String = "send_email") async -> FullDuplexBroker.ToolResult {
        await LocalCompose.run(name: name, argumentsJSON: GmailReadTools.json([
            "account": "reply@example.test", "thread_id": "reply-thread", "reply_message_id": "reply-mail",
            "body": "Here is the deck you asked for.", "user_request": "Reply with the deck.", "attachments": files ?? refs]),
            defer: true, conversationId: "attachment-conversation")
    }

    private func approveDraft(_ result: FullDuplexBroker.ToolResult) async throws -> DispatchJob {
        let id = try XCTUnwrap(result.localDraftID)
        let job = try XCTUnwrap(Container.shared.dispatchJobs().existing(id))
        let review = try XCTUnwrap(job.draftReview)
        let writes = await provider.requests.filter { $0.httpMethod == "POST" }
        XCTAssertTrue(writes.isEmpty, "Preparing a preview cannot create a Gmail draft or archive its source")
        XCTAssertEqual(job.mailAction?.state, .review)
        XCTAssertFalse(result.deferred)
        return try await LocalDraftReview.save(id, revision: review.revision,
            subject: review.message.subject, body: review.message.body)
    }

    private func selectedReply(current: @escaping @MainActor @Sendable () -> Bool = { true }) -> LocalCompose.ReplySource {
        .init(selection: .init(account: "reply@example.test", threadId: "reply-thread", messageId: "reply-mail",
            exchangeId: "", messageIDs: ["reply-mail"], selectedIDs: ["reply-mail"]),
            ownerID: "attachment-user", profileID: "attachment-profile", isCurrent: current)
    }

    func testSelectedReplyBindsOneTupleAndRepairsOnlyItsExactMetadata() async throws {
        for mode in ["reply-incomplete", "reply-absent"] {
            await provider.configure(mode)
            let reply = await LocalCompose.run(name: "send_email", argumentsJSON: #"{"body":"Keep every word of this dictated reply."}"#,
                defer: true, callID: mode, replySource: selectedReply())
            XCTAssertEqual(reply.ok, true, reply.text)
            XCTAssertFalse(reply.deferred, "A current-source send waits for its confirmed receipt")
            let requests = await provider.requests
            XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/reply-mail") == true }.count, 1)
            let writes = requests.filter { $0.httpMethod == "POST" }
            XCTAssertEqual(writes.count, 1)
            let request = try XCTUnwrap(writes.first)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertEqual(json["threadId"] as? String, "reply-thread")
            let mime = String(decoding: try XCTUnwrap(GmailAPI.decodeBase64URL(json["raw"] as! String)), as: UTF8.self)
            XCTAssertTrue(mime.contains("<reply-rfc@example.test>"))
            XCTAssertTrue(mime.hasSuffix("\r\n\r\nKeep every word of this dictated reply."), mime)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer reply@example.test")
        }
    }

    func testRefusedReplyPreservesBodyAndExplicitCorrectedRetrySendsOnce() async throws {
        let body = String(repeating: "A long dictated reply. ", count: 100)
        let source = selectedReply()
        let failed = await LocalCompose.run(name: "send_email", argumentsJSON: GmailReadTools.json([
            "account": "source@example.test", "thread_id": "other-thread", "reply_message_id": "reply-mail", "body": body]),
            defer: false, callID: "wrong-tuple", replySource: source)
        XCTAssertEqual(failed.ok, false)
        XCTAssertTrue(failed.text.contains("IDs do not match"))
        XCTAssertTrue(failed.text.contains("retained locally"))
        var rows = await Container.shared.dispatchJobs().history()
        XCTAssertEqual(rows.first?.mailAction?.body, body)
        XCTAssertEqual(rows.first?.origin?.messageID, "reply-mail")
        let before = await provider.requests
        XCTAssertTrue(before.isEmpty)
        let sent = await LocalCompose.run(name: "send_email", argumentsJSON: GmailReadTools.json(["body": body]),
            defer: false, callID: "corrected-tuple", replySource: source)
        XCTAssertEqual(sent.ok, true, sent.text)
        rows = await Container.shared.dispatchJobs().history()
        XCTAssertEqual(rows.filter { $0.mailAction?.confirmed == true }.count, 1)
        let requests = await provider.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testReplyRecoveryDistinguishesMissingMessageWrongThreadAndMissingRecipient() async throws {
        for (mode, expected) in [("reply-missing", "could not find the exact selected message"),
                                 ("reply-wrong-thread", "does not belong to the requested thread"),
                                 ("reply-noaddress", "no usable reply address")] {
            await provider.configure(mode)
            let reply = await LocalCompose.run(name: "send_email", argumentsJSON: #"{"body":"Preserve this reply"}"#,
                defer: false, callID: mode, replySource: selectedReply())
            XCTAssertEqual(reply.ok, false)
            XCTAssertTrue(reply.text.contains(expected), reply.text)
            let requests = await provider.requests
            XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
        }
    }

    func testReplySelectionChangeBeforeCommitNeverSendsOrAdvances() async throws {
        var checks = 0
        let source = selectedReply { checks += 1; return checks < 3 }
        let result = await LocalCompose.run(name: "send_email", argumentsJSON: #"{"body":"A preserved reply"}"#,
            defer: false, callID: "selection-change", replySource: source)
        XCTAssertEqual(result.ok, false)
        let requests = await provider.requests
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
        let rows = await Container.shared.dispatchJobs().history()
        XCTAssertEqual(rows.first?.mailAction?.body, "A preserved reply")
        XCTAssertEqual(rows.first?.mailAction?.state, .failed)
    }

    func testUnknownReplyCannotResendUnderANewCallID() async throws {
        await provider.configure("reply-timeout")
        let first = await LocalCompose.run(name: "send_email", argumentsJSON: #"{"body":"One intended reply"}"#,
            defer: false, callID: "first-attempt", replySource: selectedReply())
        XCTAssertTrue(first.outcomeUnknown)
        let firstRequests = await provider.requests
        XCTAssertEqual(firstRequests.filter { $0.httpMethod == "POST" }.count, 1)
        await provider.configure("")
        let retry = await LocalCompose.run(name: "send_email", argumentsJSON: #"{"body":"One intended reply, lightly reworded by the model"}"#,
            defer: false, callID: "new-model-call", replySource: selectedReply())
        XCTAssertTrue(retry.outcomeUnknown, retry.text)
        let retried = await provider.requests
        XCTAssertFalse(retried.contains { $0.httpMethod == "POST" })
    }

    func testReplyBindingHandlesMessageThreadAliasWithoutSubstitutingAnotherMember() throws {
        let source = selectedReply()
        let bound = try source.binding(["thread_id": "reply-mail", "body": "Original"])
        XCTAssertEqual(bound["thread_id"] as? String, "reply-thread")
        XCTAssertEqual(bound["reply_message_id"] as? String, "reply-mail")
        XCTAssertEqual(bound["body"] as? String, "Original")
        XCTAssertThrowsError(try source.binding(["reply_message_id": "newly-arrived", "thread_id": "reply-thread"]))
        XCTAssertThrowsError(try source.binding(["thread_id": "different-thread-with-same-subject"]))
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

    func testDraftModeRetainsAttachmentsWithoutSending() async throws {
        DraftsOnly.set(true, for: "reply@example.test")
        let result = await compose()
        XCTAssertEqual(result.ok, true, result.text)
        XCTAssertEqual(result.performedTool, "create_draft")
        let saved = try await approveDraft(result)
        let writes = await provider.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(writes[0].url?.path.hasSuffix("/drafts") == true)
        XCTAssertTrue(saved.result?.contains("Nothing was sent") == true)
    }

    func testDraftPreviewPersistsFullContentAndOpensCenterWithoutMovingFeed() async throws {
        UserDefaults.standard.set(true, forKey: StandingRule.archiveAfterReply.storageKey)
        let result = await compose(name: "create_draft")
        let id = try XCTUnwrap(result.localDraftID)
        let store = Container.shared.dispatchJobs()
        let row = try XCTUnwrap(store.existing(id))
        XCTAssertEqual(row.mailAction?.state, .review)
        XCTAssertEqual(row.draftReview?.message.attachments?.first?.bytes, AttachmentReplyProvider.bytes)
        XCTAssertEqual(row.draftReview?.message.cc, ["colleague@example.test"])
        XCTAssertTrue(row.draftReview?.archiveAfterSave == true)
        XCTAssertTrue(row.needsReview)
        XCTAssertFalse(row.belongsInWorkQueue)
        let reads = await provider.requests
        XCTAssertFalse(reads.contains { $0.httpMethod == "POST" })
        let restored = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        XCTAssertEqual(restored.existing(id)?.draftReview, row.draftReview)
        XCTAssertEqual(restored.existing(id)?.mailAction?.state, .review)
        let model = DesktopWorkspaceModel()
        let before = model.sessionFeed
        model.applyJobs(await store.history())
        XCTAssertEqual(model.selectedJob?.id, id)
        XCTAssertEqual(model.sessionFeed, before)
        model.selectedJob = nil
        model.applyJobs(await store.history())
        XCTAssertNil(model.selectedJob, "Refreshing history must not keep reopening a dismissed preview")
    }

    func testEditedDraftSavesExactReviewedBodyAndOriginalReplyWithOneConcurrentWrite() async throws {
        let result = await compose(name: "create_draft")
        let id = try XCTUnwrap(result.localDraftID)
        let store = Container.shared.dispatchJobs()
        let body = "Revised reply.\n\n" + String(repeating: "Keep all of my words. ", count: 120) + "END OF REVIEW"
        let edited = try await store.editDraftReview(id, revision: 1, subject: "Reviewed subject", body: body)
        let revision = try XCTUnwrap(edited.draftReview?.revision)
        XCTAssertEqual(edited.mailAction?.body, body)
        XCTAssertNil(edited.draftReview?.originalRaw)
        let restored = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        XCTAssertEqual(restored.existing(id)?.draftReview?.message.body, body)
        await provider.configure("delay")
        let first = Task { try await LocalDraftReview.save(id, revision: revision, subject: "Reviewed subject", body: body) }
        let second = Task { try await LocalDraftReview.save(id, revision: revision, subject: "Reviewed subject", body: body) }
        var successes = 0
        for task in [first, second] { do { _ = try await task.value; successes += 1 } catch {} }
        XCTAssertEqual(successes, 1)
        let writes = await provider.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(writes.count, 1)
        let request = try XCTUnwrap(writes.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer reply@example.test")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        let message = try XCTUnwrap(root["message"] as? [String: Any])
        XCTAssertEqual(message["threadId"] as? String, "reply-thread")
        let mime = String(decoding: try XCTUnwrap(GmailAPI.decodeBase64URL(message["raw"] as! String)), as: UTF8.self)
        XCTAssertTrue(mime.contains("Subject: Reviewed subject"))
        XCTAssertTrue(mime.contains("In-Reply-To: <reply-rfc@example.test>"))
        XCTAssertTrue(mime.contains("To: Recipient <recipient@example.test>"))
        XCTAssertTrue(mime.contains(MailMIME.base64Lines(Data(body.utf8))))
        XCTAssertTrue(mime.contains(MailMIME.base64Lines(AttachmentReplyProvider.bytes)))
        XCTAssertEqual(store.existing(id)?.mailAction?.state, .draft)
        XCTAssertNil(store.existing(id)?.draftReview)
    }

    func testDiscardedPreviewNeverWritesAndCannotBeSavedAfterRestart() async throws {
        let result = await compose(name: "create_draft")
        let id = try XCTUnwrap(result.localDraftID)
        let store = Container.shared.dispatchJobs()
        try await store.discardDraftReview(id, revision: 1)
        let restored = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        Container.shared.dispatchJobs.register { MainActor.assumeIsolated { restored } }
        XCTAssertEqual(restored.existing(id)?.mailAction?.state, .discarded)
        XCTAssertNil(restored.existing(id)?.draftReview)
        XCTAssertFalse(restored.existing(id)?.needsReview == true)
        do { _ = try await LocalDraftReview.save(id, revision: 1, subject: "Old", body: "Old"); XCTFail("Discarded") } catch {}
        let requests = await provider.requests
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
    }

    func testPreviewRefusesChangedProfileAccountAndAttachmentPermissions() async throws {
        let result = await compose(name: "create_draft")
        let id = try XCTUnwrap(result.localDraftID)
        let review = try XCTUnwrap(Container.shared.dispatchJobs().existing(id)?.draftReview)
        for (profile, emails, headersOnly) in [
            ("other-profile", ["source@example.test", "reply@example.test"], false),
            ("attachment-profile", ["reply@example.test"], false),
            ("attachment-profile", ["source@example.test"], false),
            ("attachment-profile", ["source@example.test", "reply@example.test"], true)
        ] {
            ProfileRuntime.install(.init(profileId: profile, isDefault: true, emails: emails, mailHeadersOnly: headersOnly))
            do {
                _ = try await LocalDraftReview.save(id, revision: review.revision, subject: review.message.subject, body: review.message.body)
                XCTFail("Access changed")
            } catch {}
        }
        let requests = await provider.requests
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
        ProfileRuntime.install(.init(profileId: "attachment-profile", isDefault: true, emails: ["source@example.test", "reply@example.test"]))
        _ = try await approveDraft(result)
    }

    func testDraftProviderFailureCannotRetryUnknownButCanRetryDefiniteRejection() async throws {
        for mode in ["reject", "no-id", "reply-timeout"] {
            let result = await plainReply(callID: "preview-" + mode, name: "create_draft")
            let id = try XCTUnwrap(result.localDraftID)
            let store = Container.shared.dispatchJobs()
            let preview = try XCTUnwrap(store.existing(id)?.draftReview)
            await provider.configure(mode)
            do {
                _ = try await LocalDraftReview.save(id, revision: preview.revision, subject: preview.message.subject, body: preview.message.body)
                XCTFail("Provider failed")
            } catch {}
            let restored = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
            Container.shared.dispatchJobs.register { MainActor.assumeIsolated { restored } }
            let persisted = try XCTUnwrap(restored.existing(id))
            XCTAssertEqual(persisted.mailAction?.state, mode == "reject" ? .failed : .unknown)
            let review = try XCTUnwrap(persisted.draftReview)
            await provider.configure("")
            do {
                _ = try await LocalDraftReview.save(id, revision: review.revision, subject: review.message.subject, body: review.message.body)
                XCTAssertEqual(mode, "reject")
            } catch { XCTAssertNotEqual(mode, "reject") }
            let writes = await provider.requests.filter { $0.httpMethod == "POST" }
            XCTAssertEqual(writes.count, mode == "reject" ? 1 : 0)
        }
    }

    func testDraftFilingRuleWaitsForApprovalAndProviderConfirmation() async throws {
        UserDefaults.standard.set(true, forKey: StandingRule.archiveAfterReply.storageKey)
        let result = await plainReply(name: "create_draft")
        let saved = try await approveDraft(result)
        let writes = await provider.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(writes.map { $0.url!.lastPathComponent }, ["drafts", "modify"])
        XCTAssertTrue(writes.last?.url?.path.contains("reply-thread") == true)
        XCTAssertEqual(saved.mailAction?.archiveState, "confirmed")
    }

    func testBackgroundDraftStopsBeforeLaterCommandSteps() async throws {
        let steps = [CommandAction(tool: "create_draft", detail: "Draft a reply saying thanks."),
                     CommandAction(tool: "archive_message", detail: "Archive the original.")]
        let job = DispatchWorker.Job(id: UUID(), task: "Draft a reply then archive.", account: "reply@example.test",
            standingOnJSON: GmailReadTools.json(["account": "reply@example.test", "id": "reply-mail", "threadId": "reply-thread",
                "from": "recipient@example.test", "subject": "Destination request"]),
            expects: .receipt, commandSteps: steps, command: .init(keyword: "draft", actions: steps), profileId: "attachment-profile")
        var rounds = 0
        let result = await DispatchWorker.run(job) { _ in
            rounds += 1
            if rounds == 1 {
                return [["type": "function_call", "name": "create_draft", "call_id": "draft-command",
                    "arguments": #"{"account":"reply@example.test","thread_id":"reply-thread","reply_message_id":"reply-mail","body":"Thanks!"}"#]]
            }
            return [["type": "function_call", "name": "archive_message", "call_id": "must-not-run",
                "arguments": #"{"account":"reply@example.test","message_id":"reply-mail"}"#]]
        }
        XCTAssertEqual(rounds, 1)
        XCTAssertEqual(result.status, .pending)
        let store = Container.shared.dispatchJobs()
        XCTAssertEqual(store.existing(job.id)?.state, "awaiting_input")
        let actions = await actions()
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.mailAction?.state, .review)
        XCTAssertEqual(actions.first?.mailAction?.parentJobID, job.id)
        let requests = await provider.requests
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
        let preview = try XCTUnwrap(actions.first)
        let review = try XCTUnwrap(preview.draftReview)
        _ = try await LocalDraftReview.save(preview.id, revision: review.revision, subject: review.message.subject, body: review.message.body)
        XCTAssertEqual(store.existing(job.id)?.state, "partial")
        XCTAssertEqual(store.existing(job.id)?.command?.completedSteps, 1)
        XCTAssertTrue(store.existing(job.id)?.result?.contains("remaining steps have not run") == true)
        let writes = await provider.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(writes.map { $0.url!.lastPathComponent }, ["drafts"])
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
        _ = try await approveDraft(result)
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

    private func plainReply(deferred: Bool = false, callID: String = "reply-call", name: String = "send_email", body: String = "Thanks, here are the details.") async -> FullDuplexBroker.ToolResult {
        await LocalCompose.run(name: name, argumentsJSON: GmailReadTools.json([
            "account": "reply@example.test", "thread_id": "reply-thread", "reply_message_id": "reply-mail",
            "body": body, "user_request": "Reply with these details."]),
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
        await assertUnknownReplyCannotReplay("timeout")
    }

    func testMissingConfirmationRemainsUnknownAndCannotReplay() async {
        await assertUnknownReplyCannotReplay("no-id")
    }

    private func assertUnknownReplyCannotReplay(_ failure: String) async {
            await provider.configure(failure)
            let result = await plainReply(callID: failure, body: "Separate fixture for " + failure)
            XCTAssertEqual(result.ok, false)
            XCTAssertTrue(result.outcomeUnknown)
            XCTAssertTrue(result.text.contains("unknown"))
            let retry = await plainReply(callID: failure, body: "Separate fixture for " + failure)
            XCTAssertTrue(retry.outcomeUnknown)
            let writes = await provider.requests.filter { $0.httpMethod == "POST" }
            XCTAssertEqual(writes.count, 1)
        let history = await actions()
        XCTAssertEqual(history.count, 1)
        XCTAssertTrue(history.allSatisfy { $0.mailAction?.state == .unknown })
    }

    func testProviderRejectionIsFailedAndExplicitDraftIsNotSent() async throws {
        await provider.configure("reject")
        let refused = await plainReply(callID: "refused")
        XCTAssertEqual(refused.ok, false)
        XCTAssertFalse(refused.outcomeUnknown)
        await provider.configure("")
        let draft = await plainReply(callID: "draft", name: "create_draft")
        XCTAssertEqual(draft.ok, true, draft.text)
        _ = try await approveDraft(draft)
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

    func testForwardRejectsNotificationIdentityBeforeDraftOrSendAndKeepsAttachmentBytes() async throws {
        for draftsOnly in [false, true] {
            DraftsOnly.set(draftsOnly, for: "source@example.test")
            await provider.configure("forward")
            let args: [String: Any] = ["account": "source@example.test", "message_id": "source-mail",
                "to": "notifications@billing.example", "recipient_confirmed": true]
            let refused = await LocalForward.run(argumentsJSON: GmailReadTools.json(args), defer: false,
                userRequest: "Forward this to Vendor Person whose email is here.")
            XCTAssertEqual(refused.ok, false)
            XCTAssertTrue(refused.text.contains("Reply-To"))
            let reads = await provider.requests
            XCTAssertFalse(reads.contains { $0.httpMethod == "POST" })
            XCTAssertFalse(reads.contains { $0.url?.path.contains("/attachments/") == true })
            var resolved = args
            resolved["to"] = "vendor@example.test"
            let result = await LocalForward.run(argumentsJSON: GmailReadTools.json(resolved), defer: false)
            XCTAssertEqual(result.ok, true, result.text)
            if draftsOnly { _ = try await approveDraft(result) }
            let requests = await provider.requests
            let writes = requests.filter { $0.httpMethod == "POST" }
            XCTAssertEqual(writes.count, 1)
            let write = try XCTUnwrap(writes.first)
            XCTAssertEqual(write.value(forHTTPHeaderField: "Authorization"), "Bearer source@example.test")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: write.httpBody!) as? [String: Any])
            let raw = try XCTUnwrap((body["message"] as? [String: Any] ?? body)["raw"] as? String)
            let mime = String(decoding: try XCTUnwrap(GmailAPI.decodeBase64URL(raw)), as: UTF8.self)
            XCTAssertTrue(mime.hasPrefix("To: vendor@example.test\r\n"))
            XCTAssertTrue(mime.contains(MailMIME.base64Lines(AttachmentReplyProvider.bytes)))
        }
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

    func testForwardReceiptMatchesMIMEPersistsAndDoesNotResendDuplicateCallback() async throws {
        await provider.configure("forward")
        let args = GmailReadTools.json(["account": "source@example.test", "message_id": "source-mail",
            "to": "vendor@example.test", "note": "Please review this.", "recipient_confirmed": true])
        let parent = UUID()
        let result = await FullDuplexBroker.runTool(name: "forward_email", argumentsJSON: args,
            deferSend: true, mailJobID: parent, mailCallID: "forward-once")
        XCTAssertEqual(result.ok, true, result.text)
        XCTAssertFalse(result.deferred)
        let store = Container.shared.dispatchJobs()
        let history = await store.history()
        let row = try XCTUnwrap(history.first { $0.mailAction?.kind == .forward })
        let action = try XCTUnwrap(row.mailAction)
        XCTAssertEqual(action.state, .sent)
        XCTAssertEqual(action.to, "vendor@example.test")
        XCTAssertEqual(action.forwardResolution?.basis, "source_reply_to")
        XCTAssertEqual(action.forwardNote, "Please review this.")
        XCTAssertEqual(action.subject, "Fwd: Attached invoice")
        XCTAssertEqual(action.providerMessageID, "sent-1")
        XCTAssertEqual(action.parentJobID, parent)
        XCTAssertEqual(row.origin?.messageID, "source-mail")
        XCTAssertTrue(row.activityTitle.hasPrefix("Forwarded"))
        let writes = await provider.requests.filter { $0.httpMethod == "POST" }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(writes.first?.httpBody)) as? [String: Any])
        let mime = String(decoding: try XCTUnwrap(GmailAPI.decodeBase64URL(body["raw"] as! String)), as: UTF8.self)
        XCTAssertTrue(mime.contains(MailMIME.base64Lines(Data(action.body.utf8))))
        XCTAssertEqual(action.attachments.map(\.filename), ["deck.pptx", "other.pdf"])
        XCTAssertTrue(action.attachments.allSatisfy { $0.size == AttachmentReplyProvider.bytes.count && $0.sha256.count == 64 })
        let restored = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        XCTAssertEqual(restored.mailAction(row.id)?.mailAction, action)
        let repeated = await FullDuplexBroker.runTool(name: "forward_email", argumentsJSON: args,
            mailJobID: parent, mailCallID: "forward-once")
        XCTAssertEqual(repeated.ok, true)
        let requests = await provider.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testForwardUnknownOutcomeSurvivesRestartAndCannotRetry() async throws {
        await provider.configure("forward-timeout")
        let args = GmailReadTools.json(["account": "source@example.test", "message_id": "source-mail",
            "to": "vendor@example.test", "recipient_confirmed": true])
        let result = await FullDuplexBroker.runTool(name: "forward_email", argumentsJSON: args, mailCallID: "unknown-forward")
        XCTAssertEqual(result.ok, false)
        XCTAssertTrue(result.outcomeUnknown)
        XCTAssertTrue(result.text.contains("unknown"))
        let restored = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        let rows = await restored.history()
        XCTAssertEqual(rows.first?.mailAction?.state, .unknown)
        Container.shared.dispatchJobs.register { MainActor.assumeIsolated { restored } }
        let repeated = await FullDuplexBroker.runTool(name: "forward_email", argumentsJSON: args, mailCallID: "unknown-forward")
        XCTAssertTrue(repeated.outcomeUnknown)
        let requests = await provider.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testDraftForwardStoresDraftMessageIDAndOmittedAttachmentManifest() async throws {
        DraftsOnly.set(true, for: "source@example.test")
        await provider.configure("oversized")
        let result = await FullDuplexBroker.runTool(name: "forward_email", argumentsJSON: GmailReadTools.json([
            "account": "source@example.test", "message_id": "source-mail", "to": "vendor@example.test"]),
            mailCallID: "draft-forward")
        XCTAssertEqual(result.ok, true, result.text)
        _ = try await approveDraft(result)
        let rows = await Container.shared.dispatchJobs().history()
        let action = try XCTUnwrap(rows.first?.mailAction)
        XCTAssertEqual(action.kind, .draftForward)
        XCTAssertEqual(action.state, .draft)
        XCTAssertEqual(action.providerID, "draft-1")
        XCTAssertEqual(action.providerMessageID, "draft-message-1")
        XCTAssertEqual(action.omittedAttachments?.map(\.filename), ["deck.pptx"])
        XCTAssertEqual(action.attachments.map(\.filename), ["other.pdf"])
    }

    func testForwardSuccessIsSeparateFromFailedArchive() async throws {
        UserDefaults.standard.set(true, forKey: StandingRule.archiveAfterForward.storageKey)
        await provider.configure("forward-archive")
        let result = await FullDuplexBroker.runTool(name: "forward_email", argumentsJSON: GmailReadTools.json([
            "account": "source@example.test", "message_id": "source-mail", "to": "vendor@example.test", "recipient_confirmed": true]),
            mailCallID: "archive-forward")
        XCTAssertEqual(result.ok, true, result.text)
        XCTAssertTrue(result.text.contains(LocalCompose.archiveUnconfirmed))
        let rows = await Container.shared.dispatchJobs().history()
        let action = try XCTUnwrap(rows.first?.mailAction)
        XCTAssertEqual(action.state, .sent)
        XCTAssertEqual(action.archiveState, "unconfirmed")
        XCTAssertTrue(rows.first?.activityNeedsAttention == true)
    }

    func testWorkerPublishesOnlyConfirmedForwardArchiveAndNeverRepeatsSend() async throws {
        for mode in ["forward", "forward-archive", "forward-timeout", "archive-off", "draft-only"] {
            let jobs = DispatchJobStore(url: folder.appendingPathComponent(mode + "-jobs.json"))
            Container.shared.dispatchJobs.register { jobs }
            let database = try DatabasePool(path: folder.appendingPathComponent(mode + ".sqlite").path)
            try await database.write { try MailStore.createUserScopedSchema($0) }
            let mail = MailStore(database: database, userId: "attachment-user")
            Container.shared.mailStore.register { mail }
            await mail.cache([.init(detail: .init(id: "source-mail", threadId: "source-thread", labelIds: ["INBOX", "UNREAD"],
                snippet: "Source", internalDate: "1000", payload: nil),
                account: "source@example.test")])
            await provider.configure(mode)
            UserDefaults.standard.set(mode != "archive-off", forKey: StandingRule.archiveAfterForward.storageKey)
            DraftsOnly.set(mode == "draft-only", for: "source@example.test")
            let args = GmailReadTools.json(["account": "source@example.test", "message_id": "source-mail",
                "to": "vendor@example.test", "recipient_confirmed": true] as [String: Any])
            let parent = UUID()
            let result = await DispatchWorker.execute("forward_email", args, relayNames: ["forward_email"],
                cursor: nil, standingOn: nil, profileId: "attachment-profile", callID: mode,
                ownerID: "attachment-user", parentJobID: parent)
            XCTAssertEqual(result.failed, mode == "forward-timeout", result.output)
            let inbox = await mail.inboxIds(among: ["source-mail"], account: "source@example.test")
            XCTAssertEqual(inbox?.isEmpty, mode == "forward", mode)
            let before = await provider.requests.filter { $0.url?.path.hasSuffix("/send") == true }.count
            _ = await DispatchWorker.execute("forward_email", args, relayNames: ["forward_email"],
                cursor: nil, standingOn: nil, profileId: "attachment-profile", callID: mode,
                ownerID: "attachment-user", parentJobID: parent)
            let after = await provider.requests.filter { $0.url?.path.hasSuffix("/send") == true }.count
            XCTAssertEqual(after, before, mode)
            try database.close()
        }
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
            if failure.hasSuffix("timeout") { throw URLError(.timedOut) }
            if failure.hasSuffix("archive"), path.hasSuffix("/modify") { status = 500 }
            if failure == "reject" { status = 403 }
            body = path.hasSuffix("/source-thread/modify") ? ["id": "source-thread", "messages": [["id": "source-mail", "threadId": "source-thread", "labelIds": [] as [String]]]]
                : failure == "no-id" ? [:] : path.hasSuffix("/drafts")
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
                    "payload": ["mimeType": "multipart/mixed", "parts": parts,
                        "headers": failure.hasPrefix("forward") ? [
                            ["name": "From", "value": "Vendor Person <notifications@billing.example>"],
                            ["name": "Reply-To", "value": "Vendor Person <vendor@example.test>"],
                            ["name": "Subject", "value": "Attached invoice"]] : []]]
        } else if path.hasSuffix("/source-thread") {
            body = ["id": "source-thread", "messages": [["id": "source-mail", "threadId": "source-thread", "labelIds": ["INBOX"]]]]
        } else if path.hasSuffix("/sendAs") { body = ["sendAs": [["sendAsEmail": "reply@example.test"]]] }
        else if path.hasSuffix("/reply-mail") {
            if failure == "reply-missing" { status = 404 }
            let headers = [("From", "Recipient <recipient@example.test>"), ("To", "reply@example.test"),
                ("Subject", "Destination request"), ("Message-ID", "<reply-rfc@example.test>")]
            body = ["id": "reply-mail", "threadId": failure == "reply-wrong-thread" ? "other-thread" : "reply-thread",
                    "labelIds": ["INBOX"], "payload": ["headers": failure == "reply-noaddress" ? [] : headers.map { ["name": $0.0, "value": $0.1] }]]
        }
        else {
            let headers = [("From", "Recipient <recipient@example.test>"), ("To", "reply@example.test"),
                ("Cc", "colleague@example.test"), ("Subject", "Destination request"), ("Message-ID", "<reply-rfc@example.test>")]
            let incomplete = failure.hasPrefix("reply-") && failure != "reply-timeout"
            body = ["id": "reply-thread", "messages": [["id": failure == "reply-absent" ? "earlier-mail" : "reply-mail", "threadId": "reply-thread", "labelIds": ["INBOX"],
                "payload": ["headers": incomplete ? [] : headers.map { ["name": $0.0, "value": $0.1] }]]]]
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
