import FactoryKit
import Foundation
import XCTest
@testable import CodenameJo

@MainActor
final class CalendarWorkflowRegressionTests: XCTestCase {
    private var folder: URL!
    private var provider: IssueProvider!
    private var context: LocalContextStore!

    override func setUp() async throws {
        try await super.setUp()
        Container.shared.manager.push()
        ProfileRuntime.install(nil)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        context = LocalContextStore(url: folder.appendingPathComponent("context.sqlite"))
        let context = context!
        let backend = BackendService(restoringSession: false)
        backend.userId = "regression-user"
        Container.shared.backend.register { backend }
        Container.shared.localContext.register { context }
        Container.shared.customCommandRows.register { CustomCommandRows(dbPool: context.dbPool) }
        let jobs = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        Container.shared.dispatchJobs.register { jobs }
        let grants = IssueGrants()
        Container.shared.googleGrantStorage.register { grants }
        Container.shared.googleTokenProvider.register { MainActor.assumeIsolated { IssueTokens() } }
        provider = IssueProvider()
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

    private var create: [String: Any] { ["account": "owner@example.test", "summary": "Project Review",
        "start": "2026-11-02T12:00:00-08:00", "end": "2026-11-02T13:00:00-08:00", "time_zone": "America/Los_Angeles", "online": false] }
    private var accept: [String: Any] { ["event_id": "event-a", "account": "owner@example.test", "response": "accepted",
        "source_message_id": "invite-a", "source_account": "owner@example.test"] }

    private func rsvp(_ args: [String: Any]) async -> FullDuplexBroker.ToolResult {
        await LocalCalendarWrites.run(name: LocalCalendarWrites.respond, argumentsJSON: GmailReadTools.json(args), defer: true)
    }

    func testRepeatedCreationReadsFirstAndCreatesOnlyOnce() async {
        provider.emptyCalendar = true
        let first = await CalendarTools.run(name: CalendarTools.create, argumentsJSON: GmailReadTools.json(create))
        let second = await CalendarTools.run(name: CalendarTools.create, argumentsJSON: GmailReadTools.json(create))
        XCTAssertFalse(first.failed, first.output)
        XCTAssertFalse(second.failed, second.output)
        XCTAssertEqual(provider.creates, 1)
        XCTAssertEqual(provider.calls.first?.httpMethod, "GET")
        XCTAssertTrue(second.output.contains("no event created"))
    }

    func testCalendarReceiptExportsRequestedAndProviderTimesWithoutPrivateContent() async throws {
        provider.emptyCalendar = true
        let log = VoiceDiagnostics(directory: folder.appendingPathComponent("logs"))
        let session = log.begin(engine: "live", userID: "regression-user")
        let result = await CalendarTools.run(name: CalendarTools.create, argumentsJSON: GmailReadTools.json(create), diagnostics: session, callID: "calendar-call")
        XCTAssertFalse(result.failed, result.output)
        let data = String(decoding: try await log.snapshot(userID: "regression-user"), as: UTF8.self)
        XCTAssertTrue(data.contains("calendarReceipt"))
        XCTAssertTrue(data.contains("requested_start"))
        XCTAssertTrue(data.contains("stored_start"))
        XCTAssertTrue(data.contains("2026-11-02T12:00:00-08:00"))
        XCTAssertTrue(data.contains("calendar-call"))
        XCTAssertFalse(data.contains("owner@example.test"))
        XCTAssertFalse(data.contains("Original invitation title"))
        XCTAssertEqual(VoiceDiagnostics.safeFields(["stored_start": "2026-11-02T12:00:00+01:00"]).count, 1)
    }

    func testFailedPreflightAndWrongOffsetNeverCreate() async {
        provider.readFailure = true
        let failed = await CalendarTools.run(name: CalendarTools.create, argumentsJSON: GmailReadTools.json(create))
        XCTAssertTrue(failed.failed)
        XCTAssertEqual(provider.creates, 0)
        provider.readFailure = false
        var wrong = create
        wrong["start"] = "2026-11-02T12:00:00-07:00"
        let offset = await CalendarTools.run(name: CalendarTools.create, argumentsJSON: GmailReadTools.json(wrong))
        XCTAssertTrue(offset.failed)
        XCTAssertEqual(provider.creates, 0)
    }

    func testInvitationResolutionPreservesOriginalDespiteDifferentTitle() async {
        var args = create
        args["ical_uid"] = "original-invite"
        let result = await CalendarTools.run(name: CalendarTools.create, argumentsJSON: GmailReadTools.json(args))
        XCTAssertFalse(result.failed, result.output)
        XCTAssertTrue(result.output.contains("event-a"))
        XCTAssertTrue(result.output.contains("original-meeting-link"))
        XCTAssertEqual(provider.creates, 0)
    }

    func testLookupReadsEveryConnectedAccountAndMarksLiveCoverage() async {
        let result = await CalendarTools.run(name: CalendarTools.list, argumentsJSON: GmailReadTools.json([
            "time_min": "2026-11-02T00:00:00-08:00", "time_max": "2026-11-03T00:00:00-08:00", "ical_uid": "original-invite"]))
        XCTAssertFalse(result.failed)
        let rows = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [[String: Any]]
        XCTAssertEqual(Set(rows?.compactMap { $0["account"] as? String } ?? []), ["owner@example.test", "work@example.test"])
        XCTAssertTrue(rows?.allSatisfy { $0["source"] as? String == "live" && $0["complete"] as? Bool == true } == true)
    }

    func testAcceptArchivesOnlyOriginalInvitationAfterConfirmedRSVPAndRetryIsIdempotent() async {
        let result = await rsvp(accept)
        XCTAssertEqual(result.ok, true, result.text)
        XCTAssertFalse(result.deferred)
        XCTAssertEqual(provider.patches, 1)
        XCTAssertEqual(provider.archived, ["invite-a"])
        XCTAssertTrue(provider.accepted)
        let again = await rsvp(accept)
        XCTAssertEqual(again.ok, true, again.text)
        XCTAssertEqual(provider.patches, 1)
        XCTAssertEqual(provider.archived, ["invite-a"])
    }

    func testRSVPFailureKeepsEmailAndKeepInInboxSkipsArchive() async {
        provider.patchFailure = true
        let failed = await rsvp(accept)
        XCTAssertEqual(failed.ok, false)
        XCTAssertTrue(provider.archived.isEmpty)
        provider.patchFailure = false
        var keep = accept; keep["keep_in_inbox"] = true
        let result = await rsvp(keep)
        XCTAssertEqual(result.ok, true, result.text)
        XCTAssertTrue(provider.archived.isEmpty)
    }

    func testPartialArchiveFailureRetriesOnlyArchiveAndRejectsWrongSource() async {
        provider.archiveFailure = true
        let first = await rsvp(accept)
        XCTAssertEqual(first.ok, false)
        XCTAssertTrue(first.text.contains("event is accepted"))
        XCTAssertEqual(provider.patches, 1)
        provider.archiveFailure = false
        let retry = await rsvp(accept)
        XCTAssertEqual(retry.ok, true, retry.text)
        XCTAssertEqual(provider.patches, 1)
        var other = accept; other["source_message_id"] = "booking-b"
        let mismatch = await rsvp(other)
        XCTAssertEqual(mismatch.ok, false)
        XCTAssertEqual(provider.archived, ["invite-a"])
    }

    private func commandJob(steps: [CommandAction]) -> DispatchWorker.Job {
        .init(id: UUID(), task: "Follow up this email", account: "owner@example.test",
              standingOnJSON: #"{"id":"invite-a","threadId":"thread-a","account":"owner@example.test","from":"sender@example.test"}"#,
              expects: .receipt, commandSteps: steps)
    }

    func testSavedCommandExecutesEveryStoredStepWithoutAnExtraReceiptRound() async {
        let steps: [CommandAction] = [.init(tool: "label_message", detail: "follow up", resolvedLabel: .init(id: "Label_42", name: "#Followup", account: "owner@example.test")), .init(tool: "archive_message", detail: "this")]
        var names: [String] = []
        let result = await DispatchWorker.run(commandJob(steps: steps)) { body in
            let name = (body["tool_choice"] as? [String: Any])?["name"] as? String ?? "unexpected"
            names.append(name)
            return [["type": "function_call", "name": name, "call_id": "step-\(names.count)", "arguments": ##"{"message_id":"invite-a","account":"owner@example.test","label":"wrong name"}"##]]
        }
        XCTAssertEqual(result.ok, true, result.text)
        XCTAssertEqual(names, ["label_message", "archive_message"])
        XCTAssertTrue(provider.calls.contains { String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("Label_42") })
    }

    func testExplicitArchiveFinishesFromProviderReceiptWithoutBrainRound() async throws {
        var job = commandJob(steps: [])
        job.commandSteps = nil
        job.operation = DispatchMailOperation.archiveRequest("Archive it and move on", account: "owner@example.test", messageID: "invite-a")
        let result = await DispatchWorker.run(job) { _ in
            XCTFail("A confirmed single archive must never wait for a model, even if it would time out")
            throw URLError(.timedOut)
        }
        XCTAssertEqual(result.status, .success, result.text)
        XCTAssertEqual(result.ok, true)
        let jobs = await Container.shared.dispatchJobs().history()
        let row = try XCTUnwrap(jobs.first { $0.id == job.id })
        XCTAssertEqual(row.state, "done")
        XCTAssertEqual(row.receipts?.map(\.outcome), ["success"])
        XCTAssertEqual(provider.calls.filter { $0.url?.path.contains("/messages/") == true && $0.url?.path.hasSuffix("/modify") == true }.count, 1)
        XCTAssertEqual(provider.calls.filter { $0.url?.path.contains("/threads/") == true && $0.url?.path.hasSuffix("/modify") == true }.count, 1)
        let writes = provider.calls.filter { $0.httpMethod == "POST" }.count
        job.id = UUID()
        let repeated = await DispatchWorker.run(job) { _ in
            XCTFail("A repeated completed archive must reuse its receipt")
            return []
        }
        XCTAssertEqual(repeated.status, .success)
        XCTAssertEqual(provider.calls.filter { $0.httpMethod == "POST" }.count, writes)
        let finalHistory = await Container.shared.dispatchJobs().history()
        XCTAssertEqual(finalHistory.count, 1, "A repeated archive must not create another stored job")
    }

    func testArchiveContractDoesNotClaimUnrequestedOrMultistepActions() {
        for text in ["Archive it and move on", "You can archive this.", "Go ahead and archive that", "Please archive the email"] {
            XCTAssertNotNil(DispatchMailOperation.archiveRequest(text, account: "a@test.com", messageID: "one"), text)
        }
        for text in ["Don't archive it", "Archive and reply", "Archive all of these", "Did you archive it?", "Yes", "I have feedback: archive it", "Archive it after accepting the invite"] {
            XCTAssertNil(DispatchMailOperation.archiveRequest(text, account: "a@test.com", messageID: "one"), text)
        }
    }

    func testUnknownArchiveIsReconciledWithoutAnotherWrite() async throws {
        var job = commandJob(steps: [])
        job.commandSteps = nil
        let operation = try XCTUnwrap(DispatchMailOperation.archiveRequest("archive it", account: "owner@example.test", messageID: "invite-a"))
        job.operation = operation
        let store = Container.shared.dispatchJobs()
        let priorID = UUID()
        await store.begin(id: priorID, task: "Archive it", profileId: nil, operation: operation)
        await store.finish(priorID, state: "unknown", result: "Provider result was lost")
        let uncertain = await DispatchWorker.run(job) { _ in XCTFail("No model should retry an uncertain write"); return [] }
        XCTAssertEqual(uncertain.status, .unknown)
        XCTAssertFalse(provider.calls.contains { $0.httpMethod == "POST" })
        provider.archived = ["invite-a"]
        let reconciled = await DispatchWorker.run(job) { _ in XCTFail("Use the provider observation"); return [] }
        XCTAssertEqual(reconciled.status, .success)
        XCTAssertFalse(provider.calls.contains { $0.httpMethod == "POST" })
        let history = await store.history()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.id, priorID)
        XCTAssertEqual(history.first?.state, "done")
        XCTAssertEqual(history.first?.receipts?.first?.outcome, "success")
    }

    func testQueuedSavedCommandDoesNotRecordSuccessOrRunLaterSteps() async throws {
        provider.archiveThrottled = true
        let pending = PendingMailWrites(dbPool: context.dbPool,
            perform: { _ in throw PendingMailWrites.Unrecoverable(text: "Synthetic retry stopped") }, settled: { _, _ in })
        Container.shared.pendingMailWrites.register { pending }
        let job = commandJob(steps: [.init(tool: "archive_message", detail: "this"), .init(tool: "mark_spam", detail: "this")])
        var rounds = 0
        let result = await DispatchWorker.run(job) { _ in
            rounds += 1
            return [["type": "function_call", "name": "archive_message", "call_id": "queued-step",
                "arguments": ##"{"message_id":"invite-a","account":"owner@example.test"}"##]]
        }
        XCTAssertEqual(result.status, .pending)
        XCTAssertNil(result.ok)
        XCTAssertEqual(rounds, 1)
        let history = await Container.shared.dispatchJobs().history()
        let row = try XCTUnwrap(history.first { $0.id == job.id })
        XCTAssertEqual(row.state, "unknown")
        XCTAssertTrue(row.receipts?.isEmpty != false, "A queued write is not a success receipt")
        XCTAssertEqual(provider.calls.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testReceiptBearingQueueStepsReachTheRealDesktopProjectionAcrossOneThousandOrders() {
        let queue = LocalTriageQueue(mailAccounts: { [] })
        let client = FullDuplexVoiceClient(localContext: context, localTriage: queue)
        client.sequentialFeed = true
        let model = DesktopWorkspaceModel()
        model.profileID = "work"
        var delivered = Set<UUID>()
        client.onFeedFocus = { model.focus = $0 }
        client.onJobDelivered = { delivered.insert($0) }
        for seed in 0..<1_000 {
            let old = MailSelection(account: "owner@example.test", messageID: "C")
            let next = MailSelection(account: "owner@example.test", messageID: "D")
            func step(_ id: String, served: [UUID]) {
                let output = GmailReadTools.json(["done": false, "position": id == "C" ? 3 : 4,
                    "item": ["id": id, "threadId": "thread-" + id, "account": "owner@example.test",
                             "from": "Same Sender", "subject": "Same Subject", "snippet": id]])
                client.applyStep(output, progress: nil, standing: (id == "C" ? 3 : 4, 12),
                                 served: served, dial: client.dialGeneration)
            }
            step("C", served: [])
            model.queueCurrent = old
            let job = UUID()
            var random = UInt64(seed + 1)
            var events = [0, 1, 2, 3]
            for index in stride(from: events.count - 1, through: 1, by: -1) {
                random = random &* 6364136223846793005 &+ 1442695040888963407
                events.swapAt(index, Int(random % UInt64(index + 1)))
            }
            for event in events {
                switch event {
                case 0: step("D", served: [job])
                case 1: model.queueCurrent = next
                case 2:
                    model.focus = client.feedFocusTracker.refreshEmailProgress(.init(
                        account: "owner@example.test", position: 3, queued: 12, remaining: 10, done: false,
                        messageId: "C", threadId: "thread-C"))
                default:
                    // Duplicate receipt delivery must keep its target and leave the queue alone.
                    if delivered.contains(job) { step("D", served: [job]) }
                }
                if case .email(let email) = model.focus, email.messageId == "D" {
                    XCTAssertEqual(email.position, 4, "seed \(seed): stale C progress must not label D")
                }
                let spoken = LiveEmailPresentation.Key.step(client.standingStep ?? "")?.messageId
                if spoken == "D", model.queueCurrent == old {
                    XCTAssertFalse(model.renderedState.permits(next, profileID: "work"), "seed \(seed): queue still on C")
                } else if spoken == "C", model.queueCurrent == next {
                    XCTAssertFalse(model.renderedState.permits(old, profileID: "work"), "seed \(seed): view still on C")
                }
            }
            XCTAssertTrue(model.renderedState.permits(next, profileID: "work"), "seed \(seed): receipt must not hide D")
            XCTAssertFalse(model.renderedState.permits(next, profileID: "personal"), "seed \(seed)")
            XCTAssertTrue(delivered.contains(job))
            XCTAssertEqual(LiveEmailPresentation.Key.step(client.standingStep ?? "")?.messageId, "D")
        }
    }

    func testSavedCommandStopsAtFailureAndStoresPartialReceipts() async throws {
        provider.archiveFailure = true
        var names: [String] = []
        let job = commandJob(steps: [.init(tool: "label_message", detail: "#Followup"), .init(tool: "archive_message", detail: "this"), .init(tool: "mark_spam", detail: "this")])
        let result = await DispatchWorker.run(job) { body in
            let name = (body["tool_choice"] as? [String: Any])?["name"] as? String ?? "unexpected"
            names.append(name)
            return [["type": "function_call", "name": name, "call_id": "step-\(names.count)", "arguments": ##"{"message_id":"invite-a","account":"owner@example.test","label":"#Followup"}"##]]
        }
        XCTAssertEqual(result.ok, false)
        XCTAssertEqual(names, ["label_message", "archive_message"])
        let history = await Container.shared.dispatchJobs().history()
        let row = try XCTUnwrap(history.first { $0.id == job.id })
        XCTAssertEqual(row.state, "partial")
        XCTAssertEqual(row.receipts?.map(\.outcome), ["success", "failed"])
    }

    func testCorrectedCommandPersistsStableLabelAndPreservesArchiveStepAfterReload() async throws {
        let store = CustomCommandStore()
        guard case .saved = await store.save(keyword: "follow up", label: "Follow up", actions: [
            .init(tool: "label_message", detail: "#follow up"), .init(tool: "archive_message", detail: "this email")]) else { return XCTFail("save failed") }
        guard case .saved = await store.correctLabel(keyword: "follow up", name: "#Followup", account: "owner@example.test") else { return XCTFail("correction failed") }
        let reopened = CustomCommandStore()
        await reopened.refresh()
        let actions = try XCTUnwrap(reopened.commands.first?.actions)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[0].resolvedLabel?.id, "Label_42")
        XCTAssertEqual(actions[0].resolvedLabel?.name, "#Followup")
        XCTAssertEqual(actions[1].tool, "archive_message")
        let cleaned = try CustomCommandRules.clean(actions).get()
        XCTAssertEqual(cleaned[0].resolvedLabel, actions[0].resolvedLabel)
    }
}

private final class IssueProvider: HTTPDataTransport, @unchecked Sendable {
    var calls: [URLRequest] = []
    var creates = 0, patches = 0
    var archived: [String] = []
    var emptyCalendar = false, accepted = false, readFailure = false, patchFailure = false, archiveFailure = false, archiveThrottled = false
    private let lock = NSLock()
    private var created: [String: Any]?
    private var event: [String: Any] { ["id": "event-a", "iCalUID": "original-invite", "summary": "Original invitation title",
        "hangoutLink": "original-meeting-link", "start": ["dateTime": "2026-11-02T12:00:00-08:00"],
        "end": ["dateTime": "2026-11-02T13:00:00-08:00"], "attendees": [["self": true, "email": "owner@example.test", "responseStatus": accepted ? "accepted" : "needsAction"]]] }
    private func answer(_ request: URLRequest) -> (Int, [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        calls.append(request)
        let url = request.url!, method = request.httpMethod ?? "GET"
        if url.path.contains("/calendar/") {
            if method == "GET", readFailure { return (500, [:]) }
            if method == "PATCH" { patches += 1; if patchFailure { return (404, [:]) }; accepted = true; return (200, event) }
            if method == "POST" { creates += 1; created = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]; return (200, created ?? [:]) }
            if url.path.hasSuffix("/events") { return (200, ["items": created.map { [$0] } ?? (emptyCalendar ? [] : [event])]) }
            return (200, created ?? event)
        }
        if url.path.hasSuffix("/labels") { return (200, ["labels": [["id": "Label_42", "name": "#Followup", "type": "user"]]]) }
        let message = url.path.contains("invite-a") ? "invite-a" : "booking-b"
        if method == "POST" {
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            if (body["addLabelIds"] as? [String])?.contains("Label_42") == true {
                return (200, ["id": message, "threadId": "thread-a", "labelIds": ["Label_42", "INBOX"]])
            }
            if archiveFailure { return (500, [:]) }
            if archiveThrottled { return (429, [:]) }
            archived.append(message)
            return (200, ["id": message, "threadId": "thread-a", "labelIds": []])
        }
        let uid = message == "invite-a" ? "original-invite" : "unrelated"
        let encoded = Data("BEGIN:VCALENDAR\r\nUID:\(uid)\r\nEND:VCALENDAR".utf8).base64EncodedString()
        return (200, ["id": message, "threadId": "thread-a", "labelIds": archived.contains(message) ? [] : ["INBOX"],
            "payload": ["mimeType": "text/calendar", "body": ["data": encoded]]])
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (status, body) = answer(request)
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

@MainActor
private final class IssueTokens: GoogleTokenProvider {
    func token(for email: String?, requiredScopes: [String]) async -> Result<GoogleCredential.Token, GoogleCredential.Failure> {
        .success(.init(accessToken: "test-access", email: email ?? "owner@example.test", scopes: requiredScopes))
    }
}
private final class IssueGrants: GoogleGrantStorage, @unchecked Sendable {
    func all() -> [GoogleAccountStore.Grant] {
        ["owner@example.test", "work@example.test"].map { .init(email: $0, refreshToken: "test-refresh", scopes: [
            "https://www.googleapis.com/auth/calendar.readonly", "https://www.googleapis.com/auth/calendar.events", "https://www.googleapis.com/auth/gmail.modify"], grantedAt: Date(), isPrimary: $0.hasPrefix("owner")) }
    }
    func save(_ grant: GoogleAccountStore.Grant) -> Bool { true }
    func remove(_ email: String) {}
    func removeAll() {}
}
