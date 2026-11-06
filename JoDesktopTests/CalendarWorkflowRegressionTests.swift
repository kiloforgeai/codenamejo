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

    func testProviderTimeShiftIsNotReportedAsRequestedTimeSaved() async {
        provider.emptyCalendar = true
        provider.shiftCreatedTime = true
        let result = await CalendarTools.run(name: CalendarTools.create, argumentsJSON: GmailReadTools.json(create))
        XCTAssertTrue(result.failed)
        XCTAssertTrue(result.output.contains("does not match"), result.output)
        XCTAssertTrue(result.output.contains("11:00:00-08:00"), result.output)
        let retry = await CalendarTools.run(name: CalendarTools.create, argumentsJSON: GmailReadTools.json(create))
        XCTAssertTrue(retry.failed)
        XCTAssertTrue(retry.output.contains("does not match"), retry.output)
        XCTAssertEqual(provider.creates, 1, "A committed event must not be silently recreated")
    }

    func testProviderIgnoringAnUpdateDoesNotProduceAChangedReceipt() async throws {
        provider.patchStartOnly = true
        let diagnostics = VoiceDiagnostics(directory: folder.appendingPathComponent("time-diagnostics"))
        let session = diagnostics.begin(engine: "live", userID: "timing-user")
        let result = await CalendarTools.run(name: CalendarTools.update, argumentsJSON: GmailReadTools.json([
            "event_id": "event-a", "account": "owner@example.test", "start": "2026-11-02T14:00:00-08:00",
            "time_zone": "America/Los_Angeles"]), diagnostics: session, callID: "timing-update")
        XCTAssertTrue(result.failed)
        XCTAssertTrue(result.output.contains("does not match"), result.output)
        XCTAssertEqual(provider.patches, 1)
        let exported = String(decoding: try await diagnostics.snapshot(userID: "timing-user"), as: UTF8.self)
        XCTAssertTrue(exported.contains("time_mismatch"))
        XCTAssertTrue(exported.contains("2026-11-02T15:00:00-08:00"), "The derived requested end must be recorded")
        XCTAssertFalse(exported.contains("owner@example.test"))
    }

    func testStoredTimeVerificationAcceptsEquivalentInstantsAndRejectsMissingTimes() {
        let request: [String: Any] = ["start": "2026-11-02T12:00:00-08:00", "end": "2026-11-02T13:00:00-08:00"]
        XCTAssertTrue(CalendarWriteTiming.matches(request: request, event: [
            "start": ["dateTime": "2026-11-02T15:00:00-05:00"], "end": ["dateTime": "2026-11-02T16:00:00-05:00"]]))
        XCTAssertFalse(CalendarWriteTiming.matches(request: request, event: [:]))
        XCTAssertFalse(CalendarWriteTiming.matches(request: request, event: [
            "start": ["dateTime": "2026-11-02T12:00:00-07:00"], "end": ["dateTime": "2026-11-02T13:00:00-07:00"]]))
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

    func testInvitationOnSecondPageIsFoundAndNeverRecreated() async throws {
        provider.emptyFirstCalendarPage = true
        let result = await CalendarTools.run(name: CalendarTools.list, argumentsJSON: GmailReadTools.json([
            "time_min": "2026-11-02T00:00:00-08:00", "time_max": "2026-11-03T00:00:00-08:00", "ical_uid": "original-invite"]))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertEqual(row["complete"] as? Bool, true)
            XCTAssertEqual((row["events"] as? [[String: Any]])?.first?["id"] as? String, "event-a")
        }
        var args = create; args["ical_uid"] = "original-invite"
        let repeated = await CalendarTools.run(name: CalendarTools.create, argumentsJSON: GmailReadTools.json(args))
        XCTAssertFalse(repeated.failed, repeated.output)
        XCTAssertTrue(repeated.output.contains("original-meeting-link"))
        XCTAssertEqual(provider.creates, 0)
        XCTAssertTrue(provider.calls.filter { $0.url?.path.hasSuffix("/events") == true }.allSatisfy {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .contains { $0.name == "showHiddenInvitations" && $0.value == "true" } == true
        })
    }

    func testIncompleteCalendarPaginationCannotClaimAbsenceOrCreate() async throws {
        provider.repeatedCalendarPage = true
        let result = await CalendarTools.run(name: CalendarTools.list, argumentsJSON: GmailReadTools.json([
            "time_min": "2026-11-02T00:00:00-08:00", "time_max": "2026-11-03T00:00:00-08:00", "ical_uid": "original-invite"]))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]])
        XCTAssertTrue(rows.allSatisfy { $0["complete"] as? Bool == false })
        let invitationReads = provider.calls.filter {
            $0.httpMethod == "GET" && $0.url?.path.hasSuffix("/events") == true
                && URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?
                    .contains { $0.name == "iCalUID" && $0.value == "original-invite" } == true
        }
        XCTAssertEqual(invitationReads.count, 4, "A repeated continuation token must stop both invitation searches")
        let write = await CalendarTools.run(name: CalendarTools.create, argumentsJSON: GmailReadTools.json(create))
        XCTAssertTrue(write.failed)
        XCTAssertEqual(provider.creates, 0)
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
        XCTAssertEqual(again.effects?.first?.messageIds, ["invite-a"])
        XCTAssertEqual(again.effects?.first?.account, "owner@example.test")
        XCTAssertEqual(again.effects?.first?.removeLabelIds, ["INBOX"])
    }

    func testCalendarOnlyAcceptanceDoesNotGuessAnEmailToArchive() async {
        var args = accept
        args.removeValue(forKey: "source_message_id")
        args.removeValue(forKey: "source_account")
        let result = await rsvp(args)
        XCTAssertEqual(result.ok, true)
        XCTAssertTrue(provider.archived.isEmpty)
        XCTAssertFalse(provider.calls.contains { $0.url?.path.contains("/gmail/") == true })
    }

    func testCancelledAcceptanceDoesNotPatchOrArchive() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await rsvp(accept)
        }
        let result = await task.value
        XCTAssertEqual(result.ok, false)
        XCTAssertEqual(provider.patches, 0)
        XCTAssertTrue(provider.archived.isEmpty)
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

    private func foregroundInOtherInbox() async -> LocalTriageQueue {
        let mail = MailStore(database: context.dbPool, userId: "regression-user")
        Container.shared.mailStore.register { mail }
        let queue = LocalTriageQueue(mailAccounts: { ["owner@example.test", "work@example.test"] }, unreadOpeningLoader: { _ in nil })
        Container.shared.localTriage.register { queue }
        await queue.adopt([.init(user_id: "regression-user", id: "booking-b", account: "work@example.test",
            threadId: "thread-b", sender: "Other sender", recipient: nil, subject: "Foreground", snippet: "Other email",
            internalDate: 1, cachedAt: Date())], store: mail)
        return queue
    }

    func testSavedFollowupFinishesOnOriginalAccountAfterForegroundInboxChanges() async throws {
        let queue = await foregroundInOtherInbox()
        let label = CommandAction(tool: "label_message", detail: "#Followup",
            resolvedLabel: .init(id: "Label_42", name: "#Followup", account: "owner@example.test"))
        let steps = [label, CommandAction(tool: "archive_message", detail: "this email")]
        _ = await Container.shared.customCommands().save(keyword: "follow up", label: "Follow up", actions: steps)
        var job = commandJob(steps: steps)
        job.command = .init(keyword: "follow up", actions: steps)
        var names: [String] = []
        let result = await DispatchWorker.run(job) { body in
            let name = (body["tool_choice"] as? [String: Any])?["name"] as? String ?? "unexpected"
            names.append(name)
            return [["type": "function_call", "name": name, "call_id": "pinned-\(names.count)", "arguments": "{}"]]
        }
        XCTAssertEqual(result.status, .success, result.text)
        XCTAssertEqual(names, ["label_message", "archive_message"])
        let writes = provider.calls.filter { $0.httpMethod == "POST" }
        XCTAssertFalse(writes.isEmpty)
        XCTAssertTrue(writes.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer owner@example.test" })
        XCTAssertFalse(writes.contains { $0.url?.path.contains("booking-b") == true })
        let foreground = await queue.currentMailbox
        XCTAssertEqual(foreground, "work@example.test")
        let history = await Container.shared.dispatchJobs().history()
        let row = try XCTUnwrap(history.first { $0.id == job.id })
        XCTAssertEqual(row.receipts?.map(\.outcome), ["success", "success"])
        _ = await DispatchWorker.run(job) { _ in XCTFail("Completed command must not run twice"); return [] }
        XCTAssertEqual(provider.calls.filter { $0.httpMethod == "POST" }.count, writes.count)
    }

    func testTaskSourceRejectsForeignTargetsAndProfileChangesBeforeLabelWrite() async {
        _ = await foregroundInOtherInbox()
        let source = GmailManageTools.WriteSource(cursor: .init(messageId: "invite-a", account: "owner@example.test", senders: []),
            ownerID: "regression-user", profileID: nil)
        for args in [["message_id": "booking-b", "account": "owner@example.test"],
                     ["message_id": "invite-a", "account": "work@example.test"]] {
            let result = await LocalMailWrites.run(name: "archive_message", argumentsJSON: GmailReadTools.json(args), defer: false, source: source)
            XCTAssertEqual(result.ok, false)
        }
        provider.onLabelsRead = {
            ProfileRuntime.install(.init(profileId: "other-profile", isDefault: false, emails: ["owner@example.test"]))
        }
        let result = await LocalMailWrites.run(name: "label_message",
            argumentsJSON: ##"{"message_id":"invite-a","account":"owner@example.test","label":"#Followup"}"##,
            defer: false, source: source)
        XCTAssertEqual(result.ok, false)
        XCTAssertFalse(provider.calls.contains { $0.httpMethod == "POST" })
    }

    func testFailedCommandRestoresItsPinnedSourceAndRetriesOnlyUnfinishedSteps() async throws {
        let label = CommandAction(tool: "label_message", detail: "follow up",
            resolvedLabel: .init(id: "Label_42", name: "#Followup", account: "owner@example.test"))
        let archive = CommandAction(tool: "archive_message", detail: "this")
        for partial in [false, true] {
            let initial = [partial ? label : .init(tool: "label_message", detail: "wrong name"), archive]
            var job = commandJob(steps: initial)
            job.command = .init(keyword: "follow up", actions: initial)
            _ = await Container.shared.customCommands().save(keyword: "follow up", label: "", actions: initial)
            let failed = await DispatchWorker.run(job) { body in
                let name = (body["tool_choice"] as? [String: Any])?["name"] as? String ?? "unknown"
                let id = name == "archive_message" ? "booking-b" : "invite-a"
                return [["type": "function_call", "name": name, "call_id": UUID().uuidString,
                    "arguments": GmailReadTools.json(["message_id": id, "account": "owner@example.test", "label": "wrong name"])]]
            }
            XCTAssertEqual(failed.ok, false)
            let store = Container.shared.dispatchJobs()
            let stopped = try XCTUnwrap(store.commandResult(job.id))
            XCTAssertEqual(stopped.origin?.messageID, "invite-a")
            XCTAssertEqual(stopped.command?.completedSteps, partial ? 1 : 0)
            let saved = CustomCommand(id: "follow", keyword: "follow up", spoken: "Follow up", instruction: "", actions: [label, archive], enabled: true)
            _ = await Container.shared.customCommands().save(keyword: "follow up", label: "", actions: saved.actions)
            let plan = try stopped.commandRetry(using: saved, profileID: nil, accounts: ["owner@example.test"])
            var resumed = commandJob(steps: Array(saved.actions.dropFirst(plan.completedSteps)))
            resumed.command = plan
            var names: [String] = []
            let result = await DispatchWorker.run(resumed) { body in
                let name = (body["tool_choice"] as? [String: Any])?["name"] as? String ?? "unknown"
                names.append(name)
                return [["type": "function_call", "name": name, "call_id": UUID().uuidString,
                    "arguments": GmailReadTools.json(["message_id": "invite-a", "account": "owner@example.test"])]]
            }
            XCTAssertEqual(result.ok, true, result.text)
            XCTAssertEqual(names, partial ? ["archive_message"] : ["label_message", "archive_message"])
            let completed = try XCTUnwrap(store.commandResult(resumed.id))
            XCTAssertEqual(completed.command?.completedSteps, 2)
            XCTAssertEqual(completed.command?.retryOf, job.id)
            XCTAssertEqual(store.latestCommandAttempt(from: job.id)?.id, resumed.id)
            XCTAssertThrowsError(try completed.commandRetry(using: saved, profileID: nil, accounts: ["owner@example.test"]))
            resumed.id = UUID()
            let duplicate = await DispatchWorker.run(resumed) { _ in
                XCTFail("Selecting the original failed result must not repeat an already completed retry")
                return []
            }
            XCTAssertEqual(duplicate.ok, false)
        }
        let labels = provider.calls.filter { String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("Label_42") }
        XCTAssertEqual(labels.count, 2, "Each scenario labels once, including a partial-success retry")
        XCTAssertFalse(provider.calls.contains { $0.httpMethod == "POST" && $0.url?.path.contains("/messages/booking-b/") == true },
            "Retry cannot write to a newer foreground email; the fixture also records thread requests separately")
    }

    func testCommandRetryRefusesUncertainWritesChangedPrefixesAndForeignScopes() async throws {
        let steps: [CommandAction] = [.init(tool: "label_message", detail: "original"), .init(tool: "archive_message", detail: "this")]
        let saved = CustomCommand(id: "follow", keyword: "follow up", spoken: "Follow up", instruction: "", actions: steps, enabled: true)
        let origin = DispatchJob.MailOrigin(account: "owner@example.test", messageID: "original", threadID: "t", sender: "same", subject: "same")
        var job = DispatchJob(id: UUID(), task: "follow up", state: "partial", profileId: "work", origin: origin,
            command: .init(keyword: "follow up", actions: steps, completedSteps: 1, completedResults: ["Label applied"]))
        job.receipts = [.init(callId: "label", tool: "label_message", outcome: "success", commandStep: 0)]
        XCTAssertEqual(try job.commandRetry(using: saved, profileID: "work", accounts: [origin.account]).completedSteps, 1)
        XCTAssertThrowsError(try job.commandRetry(using: saved, profileID: "personal", accounts: [origin.account]))
        XCTAssertThrowsError(try job.commandRetry(using: saved, profileID: "work", accounts: []))
        var changed = saved; changed.actions[0].detail = "different label"
        XCTAssertThrowsError(try job.commandRetry(using: changed, profileID: "work", accounts: [origin.account]))
        job.receipts?[0].commandStep = nil
        XCTAssertThrowsError(try job.commandRetry(using: saved, profileID: "work", accounts: [origin.account]))
        job.receipts = []; job.state = "unknown"
        XCTAssertThrowsError(try job.commandRetry(using: saved, profileID: "work", accounts: [origin.account]))
        for phrase in ["Run it again", "Run command follow up again", "Please retry command follow up"] {
            XCTAssertTrue(CommandRetryText.matches(phrase, keyword: "follow up"))
        }
        for phrase in ["Yes", "Don't run it again", "Run command research again", "Did you run it again?"] {
            XCTAssertFalse(CommandRetryText.matches(phrase, keyword: "follow up"))
        }
    }

    func testBackgroundInvitationCannotReplaceConfirmedBookingInWorker() async {
        var job = commandJob(steps: [.init(tool: "archive_message", detail: "Archive the confirmed booking")])
        job.standingOnJSON = #"{"id":"booking-b","threadId":"thread-b","account":"owner@example.test"}"#
        let wrong = await DispatchWorker.run(job) { _ in
            [["type": "function_call", "name": "archive_message", "call_id": "stale-invitation",
              "arguments": #"{"message_id":"invite-a","account":"owner@example.test"}"#]]
        }
        XCTAssertEqual(wrong.status, .failed)
        XCTAssertFalse(provider.calls.contains { $0.httpMethod == "POST" })
        job.id = UUID()
        job.standingOnJSON = #"{"id":"booking-b","threadId":"thread-b","account":"owner@example.test","from":"booking@example.test"}"#
        let stale = await DispatchWorker.run(job) { _ in
            [["type": "function_call", "name": "archive_message", "call_id": "stale-with-valid-context",
              "arguments": #"{"message_id":"invite-a","account":"owner@example.test"}"#]]
        }
        XCTAssertEqual(stale.status, .failed)
        XCTAssertFalse(provider.calls.contains { $0.httpMethod == "POST" })
        job.id = UUID()
        let confirmed = await DispatchWorker.run(job) { _ in
            [["type": "function_call", "name": "archive_message", "call_id": "confirmed-booking",
              "arguments": #"{"message_id":"booking-b","account":"owner@example.test"}"#]]
        }
        XCTAssertEqual(confirmed.status, .success, confirmed.text)
        XCTAssertEqual(Set(provider.archived), ["booking-b"])
        let history = await Container.shared.dispatchJobs().history()
        XCTAssertEqual(history.first { $0.id == job.id }?.receipts?.map(\.outcome), ["success"])
    }

    func testSavedCommandExecutesEveryStoredStepWithoutAnExtraReceiptRound() async {
        let steps: [CommandAction] = [.init(tool: "label_message", detail: "follow up", resolvedLabel: .init(id: "Label_42", name: "#Followup", account: "owner@example.test")), .init(tool: "archive_message", detail: "this")]
        var names: [String] = []
        _ = await Container.shared.customCommands().save(keyword: "follow up", label: "", actions: steps)
        var job = commandJob(steps: steps)
        job.command = .init(keyword: "follow up", actions: steps)
        let result = await DispatchWorker.run(job) { body in
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
            model.sessionFeed = .init(current: old)
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
                case 1: model.sessionFeed = .init(current: next)
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
                if spoken == "D", model.sessionFeed.current == old {
                    XCTAssertFalse(model.renderedState.permits(next, profileID: "work"), "seed \(seed): queue still on C")
                } else if spoken == "C", model.sessionFeed.current == next {
                    XCTAssertFalse(model.renderedState.permits(old, profileID: "work"), "seed \(seed): view still on C")
                }
            }
            XCTAssertTrue(model.renderedState.permits(next, profileID: "work"), "seed \(seed): receipt must not hide D")
            XCTAssertFalse(model.renderedState.permits(next, profileID: "personal"), "seed \(seed)")
            XCTAssertTrue(delivered.contains(job))
            XCTAssertEqual(LiveEmailPresentation.Key.step(client.standingStep ?? "")?.messageId, "D")
        }
    }

    func testReleaseExportCorrelatesConfirmedArchiveWithoutExposingItsTarget() async throws {
        let log = VoiceDiagnostics(directory: folder.appendingPathComponent("logs"))
        let conversation = UUID(), turn = UUID()
        let trace = log.begin(conversationID: conversation, engine: "live", userID: "regression-user")
        var job = commandJob(steps: [])
        job.commandSteps = nil
        job.operation = .init(tool: "archive_message", account: "owner@example.test", messageID: "invite-a")
        job.diagnostics = trace
        job.turnID = turn.uuidString
        let result = await DispatchWorker.run(job) { _ in XCTFail("The direct archive needs no reasoning round"); return [] }
        XCTAssertEqual(result.status, .success)
        let logs = try await log.snapshot(userID: "regression-user")
        let jobs = await Container.shared.dispatchJobs().history()
        let data = try SessionExport.append(records: [.init(id: turn, commandText: "Archive this email",
            status: .success, conversationId: conversation)], jobs: jobs, to: logs, includeContent: false)
        let text = String(decoding: data, as: UTF8.self)
        let rows = try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        for event in ["jobStarted", "toolStarted", "toolFinished", "jobFinished", "history_metadata", "job_metadata"] {
            XCTAssertTrue(rows.contains { $0["event"] as? String == event }, event)
        }
        let tool = try XCTUnwrap(rows.first { $0["event"] as? String == "toolStarted" }?["fields"] as? [String: String])
        XCTAssertEqual(tool["target_hash"], jobs.first?.receipts?.first?.targetHash)
        XCTAssertTrue(text.contains(turn.uuidString))
        XCTAssertTrue(text.contains(conversation.uuidString))
        XCTAssertTrue(text.contains(job.id.uuidString))
        XCTAssertFalse(text.contains("owner@example.test"))
        XCTAssertFalse(text.contains("invite-a"))
        XCTAssertFalse(text.contains("Archive this email"))
    }

    func testConfirmedArchiveWithForegroundContinuationIsSuccessfulAndReceiptIsIdempotent() async throws {
        var job = commandJob(steps: [])
        job.commandSteps = nil
        var rounds = 0
        let result = await DispatchWorker.run(job) { _ in
            rounds += 1
            if rounds == 1 {
                return [["type": "function_call", "name": "archive_message", "call_id": "confirmed-archive",
                         "arguments": #"{"message_id":"invite-a","account":"owner@example.test"}"#]]
            }
            return [["type": "message", "content": [["type": "output_text",
                "text": #"{"completed":false,"remaining_work":"foreground_queue","report":"Archived; queue advance remains."}"#]]]]
        }
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.ok, true)
        let store = Container.shared.dispatchJobs()
        await store.receipt(job.id, callId: "confirmed-archive", tool: "archive_message", failed: true)
        await store.settle(job.id)
        let firstDelivery = await store.history().first { $0.id == job.id }?.deliveredAt
        await store.settle(job.id)
        let history = await store.history()
        let saved = try XCTUnwrap(history.first { $0.id == job.id })
        XCTAssertEqual(saved.state, "done")
        XCTAssertEqual(saved.foregroundContinuation, true)
        XCTAssertEqual(saved.receipts?.count, 1)
        XCTAssertEqual(saved.receipts?.first?.outcome, "success")
        XCTAssertEqual(saved.receipts?.first?.targetHash?.count, 64)
        XCTAssertEqual(saved.deliveredAt, firstDelivery)
        let writes = provider.calls.filter { $0.httpMethod == "POST" }.count
        let replay = await DispatchWorker.run(job) { _ in XCTFail("Do not repeat a receipt-bearing job"); return [] }
        XCTAssertEqual(replay.status, .success)
        XCTAssertEqual(provider.calls.filter { $0.httpMethod == "POST" }.count, writes)
    }

    func testAbandonedJobWithCommittedReceiptIsPartialRatherThanStillRunning() async throws {
        var job = commandJob(steps: [])
        job.commandSteps = nil
        let row = DispatchJob(id: job.id, task: job.task, state: "running",
            startedAt: Date().addingTimeInterval(-DispatchJob.runningTolerance - 1),
            profileId: job.profileId, userId: "regression-user",
            receipts: [.init(callId: "committed", tool: "archive_message", outcome: "success")])
        let file = folder.appendingPathComponent("abandoned.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([row]).write(to: file)
        let restored = DispatchJobStore(url: file)
        Container.shared.dispatchJobs.register { restored }
        let result = await DispatchWorker.run(job) { _ in XCTFail("Never replay a committed archive"); return [] }
        XCTAssertEqual(result.status, .partial)
        XCTAssertFalse(provider.calls.contains { $0.httpMethod == "POST" })
    }

    func testCancellationAfterCommittedArchivePreservesReceiptAndDoesNotRepeatIt() async throws {
        var job = commandJob(steps: [])
        job.commandSteps = nil
        var rounds = 0
        let result = await DispatchWorker.run(job) { _ in
            rounds += 1
            if rounds > 1 { throw CancellationError() }
            return [["type": "function_call", "name": "archive_message", "call_id": "before-cancel",
                     "arguments": #"{"message_id":"invite-a","account":"owner@example.test"}"#]]
        }
        XCTAssertEqual(result.status, .partial)
        let history = await Container.shared.dispatchJobs().history()
        let saved = try XCTUnwrap(history.first { $0.id == job.id })
        XCTAssertEqual(saved.state, "partial")
        XCTAssertEqual(saved.receipts?.map(\.outcome), ["success"])
        let writes = provider.calls.filter { $0.httpMethod == "POST" }.count
        let replay = await DispatchWorker.run(job) { _ in XCTFail("A cancelled job must preserve its committed write"); return [] }
        XCTAssertEqual(replay.status, .partial)
        XCTAssertEqual(provider.calls.filter { $0.httpMethod == "POST" }.count, writes)
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
        for message in ["invite-a", "booking-b"] {
            let restarted = CustomCommandStore()
            await restarted.refresh()
            var job = commandJob(steps: try XCTUnwrap(restarted.commands.first?.actions))
            job.command = .init(keyword: "follow up", actions: job.commandSteps ?? [])
            job.standingOnJSON = GmailReadTools.json(["id": message, "account": "owner@example.test",
                                                    "from": "sender@example.test", "threadId": message])
            var names: [String] = []
            let result = await DispatchWorker.run(job) { body in
                let name = (body["tool_choice"] as? [String: Any])?["name"] as? String ?? "unexpected"
                names.append(name)
                return [["type": "function_call", "name": name, "call_id": UUID().uuidString,
                    "arguments": GmailReadTools.json(["message_id": message, "account": "owner@example.test", "label": "#follow up"])]]
            }
            XCTAssertEqual(result.status, .success, result.text)
            XCTAssertEqual(names, ["label_message", "archive_message"])
            let history = await Container.shared.dispatchJobs().history()
            XCTAssertEqual(history.first { $0.id == job.id }?.receipts?.map(\.outcome), ["success", "success"])
        }
        XCTAssertFalse(provider.calls.contains { $0.url?.path.hasSuffix("/labels") == true && $0.httpMethod == "POST" },
                       "A corrected command must reuse the existing label instead of creating another")
    }

    func testLabelCorrectionCannotFollowAProfileSwitch() async throws {
        let store = CustomCommandStore()
        guard case .saved = await store.save(keyword: "follow up", label: "Follow up", actions: [
            .init(tool: "label_message", detail: "#follow up"), .init(tool: "archive_message", detail: "this")]) else { return XCTFail("save failed") }
        provider.onLabelsRead = {
            ProfileRuntime.install(.init(profileId: "other-profile", isDefault: false, emails: ["owner@example.test"]))
        }
        guard case .refused = await store.correctLabel(keyword: "follow up", name: "#Followup", account: "owner@example.test") else {
            return XCTFail("A profile change must not save a correction")
        }
        let rows = Container.shared.customCommandRows()
        let original = try await rows.all(userId: "regression-user", profileId: "")
        let other = try await rows.all(userId: "regression-user", profileId: "other-profile")
        XCTAssertNil(original.first?.actions.first?.resolvedLabel)
        XCTAssertTrue(other.isEmpty)
    }

    func testLabelCorrectionDoesNotOverwriteANewerCommandOrRecreateADeletedOne() async throws {
        let rows = Container.shared.customCommandRows()
        let original = try await rows.save(userId: "regression-user", profileId: "", keyword: "follow up",
            spoken: "Follow up", label: "Follow up", actions: [.init(tool: "label_message", detail: "old")])
        let changed = try await rows.save(userId: "regression-user", profileId: "", keyword: "follow up",
            spoken: "Follow up", label: "New meaning", actions: [.init(tool: "archive_message", detail: "this")])
        let stale = try await rows.correctLabel(userId: "regression-user", profileId: "", expected: original,
                                               actions: [.init(tool: "label_message", detail: "corrected")])
        XCTAssertNil(stale)
        _ = try await rows.delete(userId: "regression-user", profileId: "", keyword: "follow up")
        let deleted = try await rows.correctLabel(userId: "regression-user", profileId: "", expected: changed,
                                                 actions: original.actions)
        XCTAssertNil(deleted)
        let remaining = try await rows.all(userId: "regression-user", profileId: "")
        XCTAssertTrue(remaining.isEmpty)
    }
}

private final class IssueProvider: HTTPDataTransport, @unchecked Sendable {
    var calls: [URLRequest] = []
    var creates = 0, patches = 0
    var archived: [String] = []
    var onLabelsRead: (() -> Void)?
    var emptyFirstCalendarPage = false, repeatedCalendarPage = false
    var shiftCreatedTime = false, patchStartOnly = false
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
            if method == "PATCH" {
                patches += 1
                if patchFailure { return (404, [:]) }
                accepted = true
                var result = event
                if patchStartOnly {
                    let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                    result["start"] = body?["start"]
                }
                return (200, result)
            }
            if method == "POST" {
                if created != nil { return (409, [:]) }
                creates += 1
                created = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                if shiftCreatedTime { created?["start"] = ["dateTime": "2026-11-02T11:00:00-08:00"] }
                return (200, created ?? [:])
            }
            if url.path.hasSuffix("/events") {
                let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageToken" }?.value
                if repeatedCalendarPage || (emptyFirstCalendarPage && page == nil) {
                    return (200, ["items": [], "nextPageToken": "next-page"])
                }
                return (200, ["items": created.map { [$0] } ?? (emptyCalendar ? [] : [event])])
            }
            return (200, created ?? event)
        }
        if url.path.hasSuffix("/labels") {
            onLabelsRead?()
            return (200, ["labels": [["id": "Label_42", "name": "#Followup", "type": "user"]]])
        }
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
        .success(.init(accessToken: email ?? "owner@example.test", email: email ?? "owner@example.test", scopes: requiredScopes))
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
