import FactoryKit
import XCTest
@testable import CodenameJo

@MainActor
final class ApplicationTasksTests: XCTestCase {
    private var folder: URL!
    private var backend: BackendService!
    private var store: DispatchJobStore!
    private var provider: TaskMailProvider!
    private var context: LocalContextStore!

    override func setUp() async throws {
        Container.shared.manager.push()
        ProfileRuntime.install(nil)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        backend = BackendService(restoringSession: false)
        backend.userId = "task-user"
        let backend = backend!
        Container.shared.backend.register { backend }
        context = LocalContextStore(url: folder.appendingPathComponent("context.sqlite"))
        let context = context!
        Container.shared.localContext.register { context }
        Container.shared.mailStore.register { MailStore(database: context.dbPool, userId: "task-user") }
        Container.shared.customCommandRows.register { CustomCommandRows(dbPool: context.dbPool) }
        store = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        let store = store!
        Container.shared.dispatchJobs.register { store }
        provider = TaskMailProvider()
        let provider = provider!
        Container.shared.providerHTTP.register { provider }
        Container.shared.googleGrantStorage.register { TaskGrants() }
        Container.shared.googleTokenProvider.register { MainActor.assumeIsolated { TaskTokens() } }
    }

    override func tearDown() async throws {
        try? context.dbPool?.close()
        Scope.singleton.reset()
        Container.shared.manager.pop()
        ProfileRuntime.install(nil)
        try? FileManager.default.removeItem(at: folder)
    }

    private func origin(_ id: String, account: String = "one@example.test") -> DispatchJob.MailOrigin {
        .init(account: account, messageID: id, threadID: "thread-" + id, sender: "Same sender", subject: "Same subject")
    }

    func testCompletedForwardCannotAuthorizeAnotherSourceFromNoiseOrPartialInput() async throws {
        var requests = 0
        let tasks = ApplicationTasks(request: { _ in requests += 1; return self.answer("Accepted explicit request") })
        Container.shared.applicationTasks.register { tasks }
        Container.shared.realtimeService.register { RealtimeService() }
        let client = FullDuplexVoiceClient(localContext: context, localTriage: LocalTriageQueue(), dispatchJobs: store)
        let earlier = try tasks.job(request: "Forward update A to trusted@example.test", commandID: nil, origin: origin("A"), profile: nil)
        _ = await tasks.run(earlier)
        let receipt = MailActionReceipt(kind: .forward, account: "one@example.test",
            message: .init(to: "trusted@example.test", subject: "Fwd: Update", body: "Original note"),
            replyMessageID: "A", parentJobID: earlier.id, requestKey: "original-forward")
        let (sent, _) = try await store.beginMailAction(receipt, ownerID: backend.userId!, profileID: nil,
            conversationID: nil, origin: origin("A"))
        _ = await store.recordMailAction(sent.id, state: .sent, result: "Forward sent", provider: ["id": "confirmed-original"])
        let originalCount = requests
        client.standingStep = #"{"done":false,"item":{"id":"B","account":"two@example.test","threadId":"thread-B"}}"#
        var accepted: [UUID] = []
        client.onDispatchStarted = { id, _ in accepted.append(id) }
        for (index, speech) in ["sniffing", "[sniff", "[sighs]", "forward, an", "go ahead"].enumerated() {
            client.latestCompletedUserUtterance = speech
            client.startDispatch(callId: "noise-\(index)", argumentsJSON: #"{"task":"Forward this to trusted@example.test with the old investment note","scope":"current_email","expects":"receipt"}"#)
            XCTAssertTrue(accepted.isEmpty, speech)
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(accepted.isEmpty)
        XCTAssertEqual(requests, originalCount, "No worker, contact lookup or write may start, even with a trusted destination")
        let history = await store.history()
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.allSatisfy { $0.origin?.messageID == "A" })
        XCTAssertEqual(history.filter { $0.mailAction?.state == .sent }.count, 1)
        client.latestCompletedUserUtterance = "Forward this one to the same person too"
        client.startDispatch(callId: "explicit-B", argumentsJSON: #"{"task":"Forward this to trusted@example.test","scope":"current_email","expects":"receipt"}"#)
        await waitFor { !accepted.isEmpty }
        let next = try XCTUnwrap(accepted.first)
        _ = await tasks.result(next)
        XCTAssertEqual(store.existing(next)?.origin?.messageID, "B")
        XCTAssertEqual(store.existing(next)?.origin?.account, "two@example.test")
    }

    func testRelatedDependencyRetainsSourceAndDecisionPolicyAcrossDelayedResultAndRestart() async throws {
        var continuation: CheckedContinuation<[[String: Any]], Never>?
        let tasks = ApplicationTasks(request: { _ in await withCheckedContinuation { continuation = $0 } })
        var job = try tasks.job(request: "Find the Notion database for this email", commandID: nil, origin: origin("A"), profile: nil)
        job.parksSource = false
        job.holdsDecision = true
        await tasks.submit(job)
        await waitFor { continuation != nil }
        XCTAssertEqual(store.decisionDependencies.first?.origin?.messageID, "A")
        XCTAssertFalse(try XCTUnwrap(store.existing(job.id)).ownsFeedSource)
        let writes = await provider.writes()
        XCTAssertTrue(writes.isEmpty, "A lookup has not authorized a write")
        continuation?.resume(returning: answer("Investor Updates database id DB-A"))
        _ = await tasks.result(job.id)
        let restored = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        let dependency = try XCTUnwrap(restored.decisionDependencies.first)
        XCTAssertEqual(dependency.id, job.id)
        XCTAssertEqual(dependency.origin?.messageID, "A")
        XCTAssertEqual(dependency.context?.holdsDecision, true)
        XCTAssertEqual(dependency.result, "Investor Updates database id DB-A")
        Container.shared.dispatchJobs.register { restored }
        let brain = LiveClientBrain(request: { _ in [:] }, deliver: { _ in }, speak: { _, _ in }, failed: { _ in })
        brain.updateState(#"{"done":false,"item":{"id":"A","threadId":"thread-A","account":"one@example.test"}}"#, scope: nil)
        XCTAssertTrue(brain.holdsFeedDecision, "A reconnect restores the source decision hold")
        brain.updateState(#"{"done":false,"item":{"id":"B","threadId":"thread-B","account":"one@example.test"}}"#, scope: nil)
        XCTAssertFalse(brain.holdsFeedDecision, "The dependency must not hold an unrelated selected email")
        await restored.releaseDecisionHold(.init(account: "one@example.test", messageID: "A"))
        brain.updateState(#"{"done":false,"item":{"id":"A","threadId":"thread-A","account":"one@example.test"}}"#, scope: nil)
        XCTAssertFalse(brain.holdsFeedDecision)
        brain.close()
        backend.userId = "another-owner"
        XCTAssertTrue(restored.decisionDependencies.isEmpty)
    }

    func testVoiceGroupLookupAndFirstFollowupKeepCommittedSourceAndDestination() async throws {
        var requests: [String] = []
        var pending: CheckedContinuation<[[String: Any]], Never>?
        let tasks = ApplicationTasks(request: { body in
            requests.append(GmailReadTools.json(body))
            if requests.count == 1 { return await withCheckedContinuation { pending = $0 } }
            return self.answer("Used the verified destination DB-A for the original source.")
        })
        Container.shared.applicationTasks.register { tasks }
        Container.shared.realtimeService.register { RealtimeService() }
        let client = FullDuplexVoiceClient(localContext: context, localTriage: LocalTriageQueue(), dispatchJobs: store)
        client.standingStep = #"{"done":false,"item":{"id":"A","account":"one@example.test","from":"Sender A","subject":"Same topic","threadId":"thread-A","messages":[{"id":"A","from":"Sender A"},{"id":"earlier-A","from":"Owner"}]}}"#
        client.latestCompletedUserUtterance = "Where should this email go in Notion?"
        var accepted: [UUID] = []
        client.onDispatchStarted = { id, _ in accepted.append(id) }
        client.startDispatch(callId: "lookup", argumentsJSON: #"{"task":"Find the Notion destination for this email","scope":"current_email","expects":"answer"}"#)
        await waitFor { pending != nil }
        let lookup = try XCTUnwrap(accepted.first)
        XCTAssertEqual(store.existing(lookup)?.origin?.messageID, "A")
        XCTAssertEqual(store.existing(lookup)?.context?.holdsDecision, true)
        XCTAssertEqual(store.decisionDependencies.map(\.id), [lookup])
        XCTAssertTrue(requests.first?.contains("earlier-A") == true, "Keep the complete captured group for the worker")
        client.standingStep = #"{"done":false,"item":{"id":"B","account":"two@example.test","from":"Sender B","subject":"Same topic","threadId":"thread-B"}}"#
        pending?.resume(returning: answer("The destination is DB-A in Notion.")); pending = nil
        _ = await tasks.result(lookup)
        client.latestCompletedUserUtterance = "Put that email there and archive it."
        client.startDispatch(callId: "followup", argumentsJSON: GmailReadTools.json([
            "task": "File the source email in the verified Notion destination and archive it", "scope": "current_email",
            "expects": "answer", "source_task_id": lookup.uuidString]))
        await waitFor { requests.count == 2 }
        let followup = try XCTUnwrap(accepted.last)
        _ = await tasks.result(followup)
        let row = try XCTUnwrap(store.existing(followup))
        XCTAssertEqual(accepted.count, 2, "One task for the first complete follow-up")
        XCTAssertEqual(row.origin?.messageID, "A")
        XCTAssertEqual(row.origin?.account, "one@example.test")
        XCTAssertEqual(row.context?.dependencyID, lookup)
        XCTAssertTrue(row.context?.facts.contains(where: { $0.contains("DB-A") }) == true)
        XCTAssertFalse(requests.last?.contains("thread-B") == true)
    }

    func testCurrentEmailTasksRefuseMissingSourceAndConflictingAccountsBeforeExecution() async throws {
        var requests = 0
        let tasks = ApplicationTasks(request: { _ in requests += 1; return self.answer("Unexpected") })
        for source in [nil, "{}", #"{"account":"one@example.test","id":"A"}"#] as [String?] {
            let job = DispatchWorker.Job(id: UUID(), task: "Find the Notion destination", facts: ["The source is A in one@example.test"],
                standingOnJSON: source, expects: .answer, scope: .currentEmail, holdsDecision: true)
            let result = await tasks.run(job)
            XCTAssertEqual(result.status, .failed)
            XCTAssertNil(store.existing(job.id), "Never persist an unbound related task")
        }
        let mismatched = DispatchWorker.Job(id: UUID(), task: "Research this source", account: "two@example.test",
            standingOnJSON: #"{"account":"one@example.test","id":"A","threadId":"thread-A"}"#, scope: .currentEmail)
        let mismatch = await tasks.run(mismatched)
        XCTAssertEqual(mismatch.status, .failed)
        XCTAssertEqual(requests, 0)
    }

    func testResearchRowsKeepIdentityThroughEveryStateWhileRoutineReceiptsStayInActivity() {
        let model = DesktopWorkspaceModel()
        var research = DispatchJob(id: UUID(), task: "Research A", state: "queued", startedAt: Date(),
            origin: origin("A"), context: .init(scope: "current_email", expects: "answer", authoredAt: Date(), timeZone: "UTC", input: "voice"))
        let second = DispatchJob(id: UUID(), task: "Research B", state: "running", startedAt: Date().addingTimeInterval(1),
            origin: origin("B"), context: .init(scope: "current_email", expects: "answer", authoredAt: Date(), timeZone: "UTC", input: "voice"))
        var receipt = DispatchJob(id: UUID(), task: "Reply sent", state: "done", startedAt: Date(), reportBack: false,
            origin: origin("C"), context: .init(scope: "current_email", expects: "receipt", authoredAt: Date(), timeZone: "UTC", input: "button"))
        for state in ["queued", "running", "done", "awaiting_input", "failed", "partial", "unknown", "cancelled"] {
            research.state = state
            model.jobs = [second, receipt, research]
            XCTAssertEqual(model.workQueueTasks.map(\.id), [research.id, second.id])
            XCTAssertEqual(model.activityJobs.map(\.id), [receipt.id])
            XCTAssertNil(model.selectedJob, "Progress must not steal the selected email")
            XCTAssertEqual(model.feedCountLabel, "≥2")
        }
        model.selectedJob = research
        research.state = "done"
        model.jobs = [research, second, receipt]
        XCTAssertEqual(model.selectedJob?.id, research.id)
        research.deliveredAt = Date()
        receipt.state = "failed"
        model.jobs = [research, second, receipt]
        XCTAssertFalse(model.workQueueTasks.contains { $0.id == research.id })
        XCTAssertTrue(model.workQueueTasks.contains { $0.id == receipt.id }, "A failed routine action can need attention in the feed")
    }

    private func browserStore() -> BackgroundBrowserStore {
        let browsers = BackgroundBrowserStore()
        browsers.makeBrowser = { job, current in
            let browser = BackgroundBrowser(job: job, current: current)
            browser.allowLocalFixture = true
            return browser
        }
        Container.shared.backgroundBrowsers.register { browsers }
        return browsers
    }

    func testActualBrowserKeepsSourceAcrossForegroundTurnsQuickActionAndCallerDisconnect() async throws {
        let browsers = browserStore(), fixture = BackgroundBrowserFixture()
        defer { browsers.purge(); fixture.server.stop() }
        var finished: [[String: Any]] = []
        var continuation: CheckedContinuation<Void, Never>?
        var hold = true
        let tasks = ApplicationTasks(request: { body in
            let result = try await fixture.respond(body)
            if hold, result.first?["type"] as? String == "message" {
                finished = result
                await withCheckedContinuation { continuation = $0 }
            }
            return result
        })
        Container.shared.applicationTasks.register { tasks }
        let mail = Container.shared.mailStore()
        let queue = LocalTriageQueue(mailAccounts: { ["one@example.test"] }, unreadOpeningLoader: { _ in nil })
        await queue.adopt([feedMessage("A"), feedMessage("B"), feedMessage("C"), feedMessage("D")], store: mail)
        let job = try tasks.job(request: "browser fixture: bring back the options", commandID: nil, origin: origin("A"), profile: nil)
        let caller = Task { await tasks.run(job) }
        for _ in 0..<1000 { if continuation != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(continuation)
        XCTAssertFalse(finished.isEmpty)
        let browser = try XCTUnwrap(browsers.sessions[job.id])
        let browserIdentity = browser.jobID
        _ = await queue.parkTaskSource(try XCTUnwrap(store.existing(job.id)), store: mail)
        let first = await queue.currentId
        XCTAssertEqual(first, "B")
        _ = await queue.step(.init(direction: "next"), store: mail, dealtWith: false)
        let second = await queue.currentId
        XCTAssertEqual(second, "C")
        caller.cancel()
        let archive = await tasks.perform(name: "archive_message", arguments: #"{"account":"one@example.test","message_id":"D"}"#,
            profile: nil, origin: origin("D"), inputSource: "button")
        XCTAssertEqual(archive.ok, true)
        XCTAssertEqual(browser.origin?.messageID, "A")
        XCTAssertEqual(browser.jobID, browserIdentity)
        hold = false; continuation?.resume(); continuation = nil
        _ = await caller.value
        XCTAssertEqual(store.existing(job.id)?.state, "done")
        XCTAssertEqual(store.existing(job.id)?.origin?.messageID, "A")
        XCTAssertNil(browser.webView)
        let writes = await provider.writes()
        XCTAssertEqual(writes, ["D", "thread-D"])
        let returned = await queue.step(.init(direction: "next"), store: mail, dealtWith: false)
        XCTAssertTrue(returned.output.contains("Tuesday 10 am"), returned.output)
        let delivered = await queue.takeServedOutcomes()
        XCTAssertEqual(delivered, [job.id])
        let next = await queue.step(.init(direction: "next"), store: mail, dealtWith: false)
        XCTAssertFalse(next.output.contains("Tuesday 10 am"))
        tasks.select(job.id)
        XCTAssertTrue((tasks.selectedContext["result"] as? String)?.contains("Tuesday 10 am") == true)
        let quiet = try tasks.job(request: "browser fixture quiet. No need to tell me when it succeeds", commandID: nil, origin: origin("E"), profile: nil)
        _ = await tasks.run(quiet)
        XCTAssertEqual(store.existing(quiet.id)?.state, "done")
        XCTAssertFalse(store.shouldPresent(quiet.id, revision: 1))
        await queue.end()
    }

    func testBrowserApprovalResumesSameApplicationTaskAndPersistsOneReceipt() async throws {
        let browsers = browserStore(), fixture = BackgroundBrowserFixture()
        defer { browsers.purge(); fixture.server.stop() }
        let tasks = ApplicationTasks(request: { try await fixture.respond($0) })
        let job = try tasks.job(request: "browser form fixture", commandID: nil, origin: origin("A"), profile: nil)
        _ = await tasks.run(job)
        let browser = try XCTUnwrap(browsers.sessions[job.id])
        XCTAssertEqual(store.existing(job.id)?.state, "awaiting_input")
        XCTAssertNil(store.existing(job.id)?.inFlightOperation)
        let key = try XCTUnwrap(browser.url?.query)
        let before = await fixture.server.count(key)
        XCTAssertEqual(before, 0)
        try await tasks.resumeBrowser(job.id, version: 1, approval: try XCTUnwrap(browser.approval).id)
        _ = await tasks.result(job.id)
        XCTAssertEqual(store.existing(job.id)?.taskRevision, 2)
        XCTAssertEqual(store.existing(job.id)?.task, job.task, "Internal continuation must not replace the visible request")
        XCTAssertEqual(store.existing(job.id)?.state, "done")
        XCTAssertTrue(store.existing(job.id)?.hasCommittedWrites == true)
        XCTAssertNil(store.existing(job.id)?.inFlightOperation)
        XCTAssertEqual(store.existing(job.id)?.origin?.messageID, "A")
        XCTAssertTrue(browsers.sessions[job.id] === browser)
        let after = await fixture.server.count(key)
        XCTAssertEqual(after, 1)
        do { try await tasks.correct(job.id, version: 2, instruction: "Try again"); XCTFail("Committed browser form replayed") } catch {}
        let restored = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        XCTAssertTrue(restored.existing(job.id)?.hasCommittedWrites == true)
    }

    func testShowingPendingFormRetainsBrowserValuesWithoutSubmissionInFocusMode() async throws {
        let browsers = browserStore(), fixture = BackgroundBrowserFixture()
        defer { browsers.purge(); fixture.server.stop() }
        let tasks = ApplicationTasks(request: { try await fixture.respond($0) })
        Container.shared.applicationTasks.register { tasks }
        let job = try tasks.job(request: "browser form fixture", commandID: nil, origin: origin("A"), profile: nil)
        _ = await tasks.run(job)
        let browser = try XCTUnwrap(browsers.sessions[job.id])
        let page = try XCTUnwrap(browser.webView)
        let key = try XCTUnwrap(browser.url?.query)
        let values = try await page.evaluateJavaScript("document.querySelector('input').value") as? String
        let model = DesktopWorkspaceModel()
        model.focusMode = true
        model.jobs = await store.history()
        model.browserTasks = browsers.sessions
        let binding = tasks.$selectedTaskID.sink { id in model.applyTaskSelection(id.flatMap { self.store.existing($0) }) }
        defer { binding.cancel() }
        let selected = await TaskManagementTool.run(GmailReadTools.json(["action": "select", "reference": job.id.uuidString]))
        XCTAssertFalse(selected.1)
        XCTAssertEqual(model.selectedJob?.id, job.id)
        XCTAssertEqual(model.pendingBrowserJobs.map(\.id), [job.id])
        XCTAssertTrue(model.focusMode, "Opening a browser must also work with the sidebar hidden")
        XCTAssertTrue(browsers.sessions[job.id]?.webView === page)
        let retained = try await page.evaluateJavaScript("document.querySelector('input').value") as? String
        XCTAssertEqual(values, retained)
        let count = await fixture.server.count(key)
        XCTAssertEqual(count, 0, "Showing the form never approves or submits it")
        browser.takeOver()
        XCTAssertTrue(page.isUserInteractionEnabled)
        XCTAssertEqual(browser.phase, .takeover)
        model.applyTaskSelection(nil)
        XCTAssertNil(model.selectedJob)
        XCTAssertTrue(browsers.sessions[job.id]?.webView === page)
    }

    func testSpokenBrowserApprovalUsesSameTaskAndRejectsStaleDuplicateAndAmbiguousApprovals() async throws {
        let browsers = browserStore(), fixture = BackgroundBrowserFixture()
        defer { browsers.purge(); fixture.server.stop() }
        let tasks = ApplicationTasks(request: { try await fixture.respond($0) })
        Container.shared.applicationTasks.register { tasks }
        let first = try tasks.job(request: "browser form fixture", commandID: nil, origin: origin("A"), profile: nil)
        _ = await tasks.run(first)
        let browser = try XCTUnwrap(browsers.sessions[first.id])
        let approval = try XCTUnwrap(browser.approval)
        let key = try XCTUnwrap(browser.url?.query)
        let second = try tasks.job(request: "browser form fixture second", commandID: nil, origin: origin("B"), profile: nil)
        _ = await tasks.run(second)
        tasks.select(nil)
        let args: [String: Any] = ["action": "resume_browser", "reference": first.id.uuidString,
            "revision": 1, "approval_id": approval.id.uuidString]
        let ambiguous = await TaskManagementTool.run(GmailReadTools.json(args), userRequest: "Go ahead and submit it")
        XCTAssertTrue(ambiguous.1)
        XCTAssertTrue(ambiguous.0.contains("More than one form"))
        let inspect = await TaskManagementTool.run(GmailReadTools.json(["action": "browser", "reference": first.id.uuidString]))
        XCTAssertTrue(inspect.0.contains(approval.id.uuidString))
        let refusal = await TaskManagementTool.run(GmailReadTools.json(args), userRequest: "Don't submit it yet")
        XCTAssertTrue(refusal.1)
        let before = await fixture.server.count(key)
        XCTAssertEqual(before, 0)
        var stale = args; stale["approval_id"] = UUID().uuidString
        let staleResult = await TaskManagementTool.run(GmailReadTools.json(stale), userRequest: "Submit it")
        XCTAssertTrue(staleResult.1)
        let resumed = await TaskManagementTool.run(GmailReadTools.json(args), userRequest: "Go ahead and submit it")
        XCTAssertFalse(resumed.1, resumed.0)
        _ = await tasks.result(first.id)
        XCTAssertEqual(store.existing(first.id)?.state, "done")
        XCTAssertEqual(store.existing(first.id)?.taskRevision, 2)
        XCTAssertTrue(browsers.sessions[first.id] === browser)
        let duplicate = await TaskManagementTool.run(GmailReadTools.json(args), userRequest: "Submit it")
        XCTAssertTrue(duplicate.1)
        let count = await fixture.server.count(key)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.existing(second.id)?.state, "awaiting_input")
        let history = await store.history()
        XCTAssertEqual(history.filter { $0.context != nil }.count, 2, "No redispatched task")
    }

    func testBrowserCapacityQueuesThirdContextAndRejectsAnotherOwner() async throws {
        let browsers = browserStore()
        defer { browsers.purge() }
        let ids = [UUID(), UUID(), UUID()]
        for (index, id) in ids.enumerated() { await store.begin(id: id, task: "Browser \(index)", profileId: nil, origin: origin(String(index))) }
        let first = try await browsers.session(ids[0])
        let second = try await browsers.session(ids[1])
        let waiting = Task { try await browsers.session(ids[2]) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(browsers.sessions.count, 2)
        XCTAssertFalse(first.webView === second.webView)
        first.finish()
        let third = try await waiting.value
        XCTAssertEqual(third.origin?.messageID, "2")
        XCTAssertEqual(browsers.sessions.values.filter { $0.webView != nil }.count, 2)
        let pending = UUID()
        await store.begin(id: pending, task: "Fourth browser", profileId: nil)
        let capacity = await browsers.run(#"{"action":"inspect"}"#, jobID: pending, callID: "capacity", diagnostics: nil)
        XCTAssertTrue(capacity.output.contains("needs_input"))
        XCTAssertFalse(capacity.write)
        backend.userId = "different-owner"
        do { _ = try await browsers.session(ids[2]); XCTFail("Another owner accessed this browser") } catch {}
        XCTAssertFalse(third.current())
    }

    func testExpiredBrowserRecoversSameTaskWithNewApprovalAndOneSubmission() async throws {
        let browsers = browserStore(), fixture = BackgroundBrowserFixture()
        defer { browsers.purge(); fixture.server.stop() }
        let tasks = ApplicationTasks(request: { try await fixture.respond($0) })
        let job = try tasks.job(request: "browser form fixture", commandID: nil, origin: origin("A"), profile: nil)
        _ = await tasks.run(job)
        let old = try XCTUnwrap(browsers.sessions[job.id])
        let oldApproval = try XCTUnwrap(old.approval).id
        let oldKey = try XCTUnwrap(old.url?.query)
        XCTAssertEqual(store.existing(job.id)?.browserState, .unsubmitted)
        browsers.purge()
        let restarted = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        Container.shared.dispatchJobs.register { restarted }
        let resumed = ApplicationTasks(request: { try await fixture.respond($0) })
        Container.shared.applicationTasks.register { resumed }
        let saved = try XCTUnwrap(restarted.existing(job.id))
        XCTAssertEqual(browsers.availability(saved), "expired")
        XCTAssertTrue(saved.result?.contains("expired") == true)
        let shown = await TaskManagementTool.run(GmailReadTools.json(["action": "browser", "reference": job.id.uuidString]))
        XCTAssertTrue(shown.0.contains("inspection"))
        XCTAssertTrue(browsers.sessions[job.id]?.inspectionOnly == true)
        XCTAssertFalse(shown.0.contains(oldApproval.uuidString))
        var approval: [String: Any] = ["action": "resume_browser", "reference": job.id.uuidString,
            "revision": 1, "approval_id": oldApproval.uuidString]
        let rejected = await TaskManagementTool.run(GmailReadTools.json(approval), userRequest: "I approve it")
        XCTAssertTrue(rejected.1)
        XCTAssertTrue(rejected.0.contains("inspection"))
        let recovered = await TaskManagementTool.run(GmailReadTools.json(["action": "restart_browser",
            "reference": job.id.uuidString, "revision": 1]), userRequest: "Reopen the form")
        XCTAssertFalse(recovered.1, recovered.0)
        _ = await resumed.result(job.id)
        let fresh = try XCTUnwrap(browsers.sessions[job.id])
        XCTAssertFalse(fresh === old)
        XCTAssertEqual(restarted.existing(job.id)?.origin, origin("A"))
        XCTAssertEqual(restarted.existing(job.id)?.task, job.task)
        XCTAssertEqual(restarted.existing(job.id)?.taskRevision, 2)
        let freshApproval = try XCTUnwrap(fresh.approval).id
        XCTAssertNotEqual(freshApproval, oldApproval)
        approval["revision"] = 2
        let stale = await TaskManagementTool.run(GmailReadTools.json(approval), userRequest: "I approve it")
        XCTAssertTrue(stale.1)
        approval["approval_id"] = freshApproval.uuidString
        let approved = await TaskManagementTool.run(GmailReadTools.json(approval), userRequest: "I approve this form")
        XCTAssertFalse(approved.1, approved.0)
        _ = await resumed.result(job.id)
        let oldCount = await fixture.server.count(oldKey)
        let newCount = await fixture.server.count(try XCTUnwrap(fresh.url?.query))
        XCTAssertEqual(oldCount, 0)
        XCTAssertEqual(newCount, 1)
        XCTAssertEqual(restarted.existing(job.id)?.browserState, .confirmed)
        browsers.purge()
        do { try await resumed.restartBrowser(job.id, version: 3); XCTFail("Committed submission replayed") } catch {}
    }

    func testBrowserRecoveryRejectsUnknownManualAndForeignProfileAndRequiresLegacyVerification() async throws {
        let browsers = browserStore()
        defer { browsers.purge() }
        let tasks = ApplicationTasks(request: { _ in self.answer("Reopened without submitting") })
        Container.shared.applicationTasks.register { tasks }
        for state in [DispatchJob.BrowserState.submitting, .unknown, .userControlled] {
            let id = UUID()
            await store.begin(id: id, task: "Browser", profileId: nil, origin: origin("A"))
            _ = await store.acceptContext(id, context: .init(scope: "current_email", expects: "answer",
                authoredAt: Date(), timeZone: "UTC", input: "voice"))
            _ = await store.recordBrowserState(id, state: state)
            await store.finish(id, state: "awaiting_input", result: "Old form open")
            do { try await tasks.restartBrowser(id, version: 1, verifiedUnsubmitted: true); XCTFail("Uncertain browser replayed") } catch {}
            XCTAssertEqual(browsers.availability(try XCTUnwrap(store.existing(id))), "unknown")
        }
        let legacy = UUID()
        await store.begin(id: legacy, task: "Browser", profileId: nil, origin: origin("B"))
        _ = await store.acceptContext(legacy, context: .init(scope: "current_email", expects: "answer",
            authoredAt: Date(), timeZone: "UTC", input: "voice"))
        await store.finish(legacy, state: "awaiting_input", result: "The form is filled and open")
        do { try await tasks.restartBrowser(legacy, version: 1); XCTFail("Legacy state needs verification") } catch {}
        let speech = try XCTUnwrap(store.existing(legacy)?.recoveredAnswer())
        XCTAssertFalse(speech.contains("filled"))
        ProfileRuntime.install(.init(profileId: "different", isDefault: false, emails: ["one@example.test"]))
        do { try await tasks.restartBrowser(legacy, version: 1, verifiedUnsubmitted: true); XCTFail("Wrong profile") } catch {}
        ProfileRuntime.install(nil)
        try await tasks.restartBrowser(legacy, version: 1, verifiedUnsubmitted: true)
        _ = await tasks.result(legacy)
        XCTAssertEqual(store.existing(legacy)?.taskRevision, 2)
        XCTAssertEqual(store.existing(legacy)?.origin, origin("B"))
    }

    func testLegacyUnknownAndConfirmedBrowsersCanBeInspectedWithoutReplayingOrChangingOutcome() async throws {
        let browsers = browserStore(), server = BrowserHTTPFixture()
        let base = try await server.start()
        defer { browsers.purge(); server.stop() }
        browsers.inspectionDestination = { job in base.appendingPathComponent("event").appending(queryItems: [.init(name: job.id.uuidString, value: nil)]) }
        let tasks = ApplicationTasks(request: { _ in XCTFail("Inspection must not redispatch the task"); return [] })
        Container.shared.applicationTasks.register { tasks }
        for state in [DispatchJob.BrowserState.unavailable, .unknown, .confirmed] {
            let id = UUID()
            await store.begin(id: id, task: "Inspect registration", profileId: nil, origin: origin("A"))
            _ = await store.acceptContext(id, context: .init(scope: "current_email", expects: "answer",
                authoredAt: Date(), timeZone: "UTC", input: "voice"))
            _ = await store.recordBrowserState(id, state: state)
            await store.finish(id, state: "awaiting_input", result: "Historical form report")
            let result = await TaskManagementTool.run(GmailReadTools.json(["action": "browser", "reference": id.uuidString]),
                userRequest: "Click the link and fill in the details")
            XCTAssertFalse(result.1, result.0)
            let browser = try XCTUnwrap(browsers.sessions[id])
            XCTAssertEqual(tasks.selectedTaskID, id)
            XCTAssertTrue(browser.inspectionOnly)
            XCTAssertTrue(browser.text.contains("Controlled Jo browser fixture"))
            XCTAssertNotNil(browser.webView)
            XCTAssertEqual(store.existing(id)?.browserState, state)
            XCTAssertEqual(store.existing(id)?.taskRevision, 1)
            let field = try XCTUnwrap(browser.controls.first { $0.kind == "field" })
            do { _ = try await browser.fill(field.id, revision: browser.revision, value: "Guest"); XCTFail("Inspection filled a form") } catch {}
            let submit = try XCTUnwrap(browser.controls.first { $0.kind == "submit" })
            do { _ = try await browser.click(submit.id, revision: browser.revision, receipt: "Registered"); XCTFail("Inspection submitted") } catch {}
            XCTAssertThrowsError(try browser.approve(UUID()))
            do { try await tasks.resumeBrowser(id, version: 1); XCTFail("Inspection resumed a write") } catch {}
            let count = await server.count(id.uuidString)
            XCTAssertEqual(count, 0)
            browsers.purge()
        }
        XCTAssertTrue(TaskManagementTool.requestsBrowser("Click the link and fill in the details"))
        XCTAssertTrue(TaskManagementTool.requestsBrowser("View the registration website"))
    }

    func testVerifiedManualInspectionCanRebuildButProviderUnknownStillCannot() async throws {
        let browsers = browserStore(), server = BrowserHTTPFixture()
        let base = try await server.start()
        defer { browsers.purge(); server.stop() }
        browsers.inspectionDestination = { _ in base.appendingPathComponent("event") }
        let tasks = ApplicationTasks(request: { _ in self.answer("Fresh inspection; approval still required") })
        for state in [DispatchJob.BrowserState.userControlled, .unknown] {
            let id = UUID()
            await store.begin(id: id, task: "Inspect registration", profileId: nil, origin: origin("A"))
            _ = await store.acceptContext(id, context: .init(scope: "current_email", expects: "answer", authoredAt: Date(), timeZone: "UTC", input: "voice"))
            _ = await store.recordBrowserState(id, state: state)
            await store.finish(id, state: "awaiting_input", result: "Historical outcome")
            try await tasks.inspectBrowser(id, version: 1)
            do {
                try await tasks.restartBrowser(id, version: 1, verifiedUnsubmitted: true)
                XCTAssertEqual(state, .userControlled)
                _ = await tasks.result(id)
                XCTAssertEqual(store.existing(id)?.taskRevision, 2)
                XCTAssertEqual(store.existing(id)?.browserState, .unsubmitted)
            } catch { XCTAssertEqual(state, .unknown) }
            browsers.purge()
        }
    }

    func testSelectedActivitySuppliesItsResultAndClearsWithoutReplayingWork() async throws {
        let tasks = ApplicationTasks(request: { _ in XCTFail("Selection must not start a task"); return [] })
        let id = UUID()
        await store.begin(id: id, task: "Research the event", profileId: nil, origin: origin("A"))
        await store.finish(id, state: "done", result: "The event is on November 12, not November 14.")
        tasks.select(id)
        XCTAssertEqual(tasks.selectedContext["id"] as? String, id.uuidString)
        XCTAssertEqual(tasks.selectedContext["message_id"] as? String, "A")
        XCTAssertEqual(tasks.selectedContext["result"] as? String, "The event is on November 12, not November 14.")
        XCTAssertEqual(tasks.selectedContext["result_truncated"] as? Bool, false)
        backend.userId = "another-owner"
        XCTAssertTrue(tasks.selectedContext.isEmpty)
        backend.userId = "task-user"
        tasks.select(nil)
        XCTAssertTrue(tasks.selectedContext.isEmpty)
        let writes = await provider.writes()
        XCTAssertTrue(writes.isEmpty)
    }

    func testFeedbackArchivePersistsWithoutWriteAndResumesOriginalTargetOnce() async throws {
        let tasks = ApplicationTasks(request: { _ in XCTFail("Saved archive must not ask the model to choose a target"); return [] })
        let id = UUID()
        try await tasks.deferFeedbackArchive(id: id, owner: backend.userId, profile: nil, origin: origin("A"), conversation: nil)
        try await tasks.deferFeedbackArchive(id: id, owner: backend.userId, profile: nil, origin: origin("B"), conversation: nil)
        let writesBefore = await provider.writes()
        XCTAssertTrue(writesBefore.isEmpty)
        XCTAssertEqual(store.existing(id)?.origin?.messageID, "A")
        XCTAssertEqual(store.existing(id)?.state, "awaiting_input")
        XCTAssertEqual(store.existing(id)?.context?.deferredFeedbackArchive, true)
        let restored = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        XCTAssertEqual(restored.existing(id)?.origin?.messageID, "A")
        XCTAssertEqual(restored.existing(id)?.state, "awaiting_input")
        try await tasks.resumeFeedbackArchive(id, version: 1)
        do { try await tasks.resumeFeedbackArchive(id, version: 1); XCTFail("Duplicate resume must be refused") } catch {}
        _ = await tasks.result(id)
        XCTAssertEqual(store.existing(id)?.state, "done")
        do { try await tasks.resumeFeedbackArchive(id, version: 2); XCTFail("Completed action cannot repeat") } catch {}
        let writesAfter = await provider.writes()
        XCTAssertEqual(writesAfter, ["A", "thread-A"])
        XCTAssertEqual(store.existing(id)?.taskRevision, 2)
    }

    func testMixedFeedbackFinalTranscriptRetainsActionAndLaterFragmentsStayFeedback() async throws {
        ProfileRuntime.install(.init(profileId: "work", isDefault: false, emails: ["one@example.test"]))
        let tasks = ApplicationTasks()
        Container.shared.applicationTasks.register { tasks }
        let feedback = UserFeedback()
        feedback.voiceSaveDelay = .seconds(60)
        Container.shared.userFeedback.register { feedback }
        let realtime = RealtimeService()
        Container.shared.realtimeService.register { realtime }
        let client = FullDuplexVoiceClient()
        client.standingStep = GmailReadTools.json(["item": ["account": "one@example.test", "id": "A", "threadId": "thread-A", "from": "Sender", "subject": "Original"]])
        client.handle(.liveUserActivity)
        let turn = client.historyTurnID
        client.handle(.liveInputText("Great. You can archive it."))
        XCTAssertFalse(store.contains(turn), "Partial captions cannot authorize anything")
        client.handle(.liveInputFinished("Great. You can archive it. I want to give some feedback."))
        await waitFor { self.store.existing(turn)?.state == "awaiting_input" }
        XCTAssertEqual(store.existing(turn)?.origin?.messageID, "A")
        XCTAssertEqual(feedback.pendingVoiceText, "")
        client.standingStep = GmailReadTools.json(["item": ["account": "one@example.test", "id": "B", "threadId": "thread-B"]])
        client.handle(.liveUserActivity)
        let noteTurn = client.historyTurnID
        client.handle(.liveInputFinished("Archive it. I want to give feedback: the wrong email was archived"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(store.contains(noteTurn), "An archive clause inside a solicited note is only feedback")
        XCTAssertTrue(feedback.pendingVoiceText?.contains("wrong email") == true)
        _ = feedback.takeVoiceDraft()
        let writes = await provider.writes()
        XCTAssertTrue(writes.isEmpty)
    }

    func testFeedbackArchiveRejectsChangedScopeAndCancellation() async throws {
        let tasks = ApplicationTasks()
        let id = UUID()
        try await tasks.deferFeedbackArchive(id: id, owner: backend.userId, profile: nil, origin: origin("A"), conversation: nil)
        backend.userId = "another-owner"
        do { try await tasks.resumeFeedbackArchive(id, version: 1); XCTFail("Wrong owner") } catch {}
        backend.userId = "task-user"
        ProfileRuntime.install(.init(profileId: "other", isDefault: false, emails: []))
        do { try await tasks.resumeFeedbackArchive(id, version: 1); XCTFail("Wrong profile") } catch {}
        ProfileRuntime.install(nil)
        try await tasks.cancel(id, version: 1)
        XCTAssertEqual(store.existing(id)?.state, "cancelled")
        do { try await tasks.resumeFeedbackArchive(id, version: 1); XCTFail("Cancelled action") } catch {}
        let writes = await provider.writes()
        XCTAssertTrue(writes.isEmpty)
    }

    func testFeedbackArchiveDoesNotRepeatAnUncertainWrite() async throws {
        let tasks = ApplicationTasks()
        let id = UUID()
        try await tasks.deferFeedbackArchive(id: id, owner: backend.userId, profile: nil, origin: origin("A"), conversation: nil)
        await provider.pauseWrites()
        try await tasks.resumeFeedbackArchive(id, version: 1)
        for _ in 0..<1000 { if await provider.isWaiting() { break }; try await Task.sleep(for: .milliseconds(1)) }
        await provider.releaseWrite()
        _ = await tasks.result(id)
        do { try await tasks.resumeFeedbackArchive(id, version: 2); XCTFail("An uncertain write cannot replay") } catch {}
        let writes = await provider.writes()
        XCTAssertEqual(writes, ["A"])
    }
    private func answer(_ text: String) -> [[String: Any]] {
        [["type": "message", "content": [["type": "output_text", "text": text]]]]
    }
    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<1000 { if condition() { return }; try? await Task.sleep(for: .milliseconds(1)) }
        XCTFail("The operation did not reach its expected boundary")
    }

    private func feedMessage(_ id: String, account: String = "one@example.test") -> MailStore.Message {
        .init(user_id: "task-user", id: id, account: account, threadId: "thread-" + id,
              sender: "Same sender", recipient: nil, subject: "Same subject", snippet: "Body " + id,
              internalDate: 1, cachedAt: Date())
    }

    func testAcceptedTaskParksSourceWithoutWriteAndReturnsOnceAtBoundary() async throws {
        for finishesBeforeHandoff in [false, true] {
            var continuation: CheckedContinuation<[[String: Any]], Never>?
            var requests = 0
            let tasks = ApplicationTasks(request: { _ in
                requests += 1
                return await withCheckedContinuation { continuation = $0 }
            })
            let sourceID = UUID().uuidString
            let job = try tasks.job(request: "Research source", commandID: nil, origin: origin(sourceID), profile: nil)
            let mail = Container.shared.mailStore()
            let queue = LocalTriageQueue(mailAccounts: { ["one@example.test"] }, unreadOpeningLoader: { _ in nil })
            await queue.adopt([feedMessage(sourceID), feedMessage("B"), feedMessage("C"), feedMessage("D")], store: mail)
            await tasks.submit(job)
            await waitFor { continuation != nil }
            if finishesBeforeHandoff {
                continuation?.resume(returning: answer("Research complete"))
                _ = await tasks.result(job.id)
            }
            let parked = await queue.parkTaskSource(try XCTUnwrap(store.existing(job.id)), store: mail)
            XCTAssertNotNil(parked)
            let nextID = await queue.currentId
            XCTAssertEqual(nextID, "B")
            XCTAssertFalse(parked?.contains("presentedForOutcome") == true)
            if !finishesBeforeHandoff {
                continuation?.resume(returning: answer("Research complete"))
                _ = await tasks.result(job.id)
            }
            let unchanged = await queue.currentId
            XCTAssertEqual(unchanged, "B", "Completion cannot interrupt the foreground")
            let returned = await queue.step(.init(direction: "next"), store: mail, dealtWith: false)
            XCTAssertTrue(returned.output.contains("presentedForOutcome"), returned.output)
            XCTAssertTrue(returned.output.contains("Research complete"))
            let served = await queue.takeServedOutcomes()
            XCTAssertEqual(served, [job.id])
            let continued = await queue.step(.init(direction: "next"), store: mail, dealtWith: false)
            XCTAssertFalse(continued.output.contains("presentedForOutcome"), continued.output)
            let continuedID = await queue.currentId
            XCTAssertEqual(continuedID, "C")
            let backwards = await queue.step(.init(direction: "back"), store: mail, dealtWith: false)
            XCTAssertFalse(backwards.output.contains("Research complete"))
            let writes = await provider.writes()
            XCTAssertTrue(writes.isEmpty)
            XCTAssertEqual(requests, 1)
            await store.settle(job.id)
            await queue.end()
        }
    }

    func testVoiceAttachmentQuestionHoldsSourceUnlessBackgroundWasRequested() async throws {
        for background in [false, true] {
            for fast in [false, true] {
                var continuation: CheckedContinuation<[[String: Any]], Never>?
                let tasks = ApplicationTasks(request: { _ in
                    if fast { return self.answer("The candidate has five years of experience.") }
                    return await withCheckedContinuation { continuation = $0 }
                })
                Container.shared.applicationTasks.register { tasks }
                let source = UUID().uuidString
                let mail = Container.shared.mailStore()
                let queue = LocalTriageQueue(mailAccounts: { ["one@example.test"] }, unreadOpeningLoader: { _ in nil })
                await queue.adopt([feedMessage(source), feedMessage("B"), feedMessage("C")], store: mail)
                let realtime = RealtimeService()
                Container.shared.realtimeService.register { realtime }
                realtime.isConversing = true
                let selected = MailSelection(account: "one@example.test", messageID: source)
                realtime.renderedWorkspace = .init(profileID: nil, conversationID: nil, focus: selected, queueCurrent: selected)
                let client = FullDuplexVoiceClient(queueStanding: {
                    .init(account: "one@example.test", position: 1, queued: 3, remaining: 3, done: false)
                }, localContext: context, localTriage: queue, dispatchJobs: store)
                client.activateFeedForTesting(transport: FullDuplexTransport())
                client.userSpeaking = true
                client.standingStep = GmailReadTools.json(["done": false, "item": ["id": source,
                    "threadId": "thread-" + source, "account": "one@example.test", "from": "Candidate", "subject": "Resume"]])
                client.latestCompletedUserUtterance = background ? "Read the resume in the background and keep going" : "What does the resume say?"
                var id: UUID?
                client.onDispatchStarted = { started, _ in id = started }
                client.startDispatch(callId: "attachment", argumentsJSON: GmailReadTools.json([
                    "task": "Read the attached resume and summarize the candidate's experience", "scope": "current_email",
                    "expects": "answer", "requested_background": background]))
                let accepted = try XCTUnwrap(id)
                await waitFor { self.store.existing(accepted)?.context != nil && (fast || continuation != nil) }
                if background {
                    await waitFor { client.standingStep.flatMap(LiveEmailPresentation.Key.selection)?.messageId == "B" }
                }
                let job = try XCTUnwrap(store.existing(accepted))
                XCTAssertEqual(job.origin?.messageID, source)
                XCTAssertEqual(job.context?.parksSource, background)
                XCTAssertEqual(job.ownsFeedSource, background)
                if !fast {
                    let waiting = await queue.currentId
                    XCTAssertEqual(waiting, background ? "B" : source)
                    continuation?.resume(returning: answer("The candidate has five years of experience."))
                }
                _ = await tasks.result(accepted)
                await waitFor { client.dispatchTasks["attachment"] == nil }
                let after = await queue.currentId
                XCTAssertEqual(after, background ? "B" : source)
                XCTAssertEqual(store.existing(accepted)?.state, "done")
                XCTAssertTrue(store.existing(accepted)?.result?.contains("five years") == true)
                let writes = await provider.writes()
                XCTAssertTrue(writes.isEmpty)
                client.reportDrain?.cancel()
                client.reportDrain = nil
                client.pendingReports = []
                client.cancelDispatchesForTesting()
                realtime.isConversing = false
                await store.settle(accepted)
                await queue.end()
            }
        }
    }

    func testQuietSuccessStaysInActivitiesButFailureAndInputReturnWithState() async throws {
        let mail = Container.shared.mailStore()
        for state in ["done", "failed", "partial", "awaiting_input"] {
            var continuation: CheckedContinuation<[[String: Any]], Never>?
            let tasks = ApplicationTasks(request: { _ in await withCheckedContinuation { continuation = $0 } })
            let job = try tasks.job(request: "Research", commandID: nil, origin: origin(state), profile: nil)
            await tasks.submit(job)
            await waitFor { continuation != nil }
            _ = await store.setPreference(job.id, revision: 1, preference: .quiet)
            continuation?.resume(returning: answer(state == "done" ? "Saved result"
                : #"{"status":"needs_input","report":"Concrete blocker"}"#))
            _ = await tasks.result(job.id)
            if state != "done" { await store.finish(job.id, state: state, result: "Concrete blocker", revision: 1) }
            let queue = LocalTriageQueue(mailAccounts: { ["one@example.test"] }, unreadOpeningLoader: { _ in nil })
            await queue.adopt([feedMessage(state), feedMessage("B"), feedMessage("C")], store: mail)
            _ = await queue.parkTaskSource(try XCTUnwrap(store.existing(job.id)), store: mail)
            let result = await queue.step(.init(direction: "next"), store: mail, dealtWith: false)
            XCTAssertEqual(result.output.contains("presentedForOutcome"), state != "done", result.output)
            if state != "done" { XCTAssertTrue(result.output.contains("Concrete blocker")); XCTAssertTrue(result.output.contains(state)) }
            await store.settle(job.id)
            await queue.end()
        }
    }

    func testStoppingFeedKeepsCompletedResultsUnreadAcrossRestartAndProfiles() async throws {
        let ids = [UUID(), UUID()]
        for (index, id) in ids.enumerated() {
            await store.begin(id: id, task: "Inspect attachment \(index)", profileId: nil,
                origin: origin("source-\(index)", account: index == 0 ? "one@example.test" : "two@example.test"))
            let accepted = await store.acceptContext(id, context: .init(scope: "current_email", expects: "answer",
                authoredAt: Date(), timeZone: "UTC", input: "voice", parksSource: true))
            XCTAssertTrue(accepted)
            await store.finish(id, state: "done", result: "Requested finding \(index)", reportBack: true)
        }
        let quiet = UUID()
        await store.begin(id: quiet, task: "Archive quietly", profileId: nil, origin: origin("quiet"))
        await store.finish(quiet, state: "done", result: "Archived", reportBack: false)
        let mail = Container.shared.mailStore()
        let queue = LocalTriageQueue(mailAccounts: { ["one@example.test", "two@example.test"] }, unreadOpeningLoader: { _ in nil })
        await queue.adopt([feedMessage("foreground"), feedMessage("next")], store: mail)
        let stopped = await queue.step(.init(stop: true), store: mail)
        XCTAssertTrue(stopped.output.contains("stopped"))
        XCTAssertFalse(stopped.output.contains("Requested finding"))
        let delivered = await queue.takeServedOutcomes()
        XCTAssertTrue(delivered.isEmpty, "Closing a reader is not a delivery acknowledgment")
        for id in ids { XCTAssertNil(store.existing(id)?.deliveredAt) }
        XCTAssertNotNil(store.existing(quiet)?.deliveredAt)
        await queue.end()

        let restored = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        Container.shared.dispatchJobs.register { restored }
        let unread = await restored.recover()
        XCTAssertEqual(Set(unread.map(\.id)), Set(ids))
        ProfileRuntime.install(.init(profileId: "another", isDefault: false, emails: ["one@example.test"]))
        let foreign = await restored.recover()
        XCTAssertTrue(foreign.isEmpty)
        ProfileRuntime.install(nil)
        let resumed = LocalTriageQueue(mailAccounts: { ["one@example.test", "two@example.test"] }, unreadOpeningLoader: { _ in nil })
        await resumed.adopt([feedMessage("foreground"), feedMessage("next")], store: mail)
        var presented = Set<UUID>()
        for _ in ids {
            let step = await resumed.step(.init(direction: "next"), store: mail, dealtWith: false)
            XCTAssertTrue(step.output.contains("Requested finding"))
            let served = await resumed.takeServedOutcomes()
            XCTAssertEqual(served.count, 1)
            for id in served {
                XCTAssertTrue(presented.insert(id).inserted)
                await restored.settle(id)
            }
        }
        XCTAssertEqual(presented, Set(ids))
        let remaining = await restored.recover()
        XCTAssertTrue(remaining.isEmpty)
        await resumed.end()
    }

    func testLegacyHeldResultDoesNotReplayAfterDeliveryOrCancellation() async throws {
        for cancelled in [false, true] {
            let mail = Container.shared.mailStore()
            let queue = LocalTriageQueue(mailAccounts: { ["one@example.test"] }, unreadOpeningLoader: { _ in nil })
            await queue.adopt([feedMessage("A"), feedMessage("B"), feedMessage("C")], store: mail)
            let id = UUID()
            await store.begin(id: id, task: "Research A", profileId: nil, origin: origin("A"))
            await store.finish(id, state: "done", result: "Previously delivered answer", reportBack: true)
            let held = await queue.hold(.init(jobId: id, task: "Research A", text: "Previously delivered answer",
                ok: true, expects: .answer, about: origin("A").about))
            XCTAssertTrue(held)
            if cancelled {
                await store.finish(id, state: "cancelled", result: "Cancelled", reportBack: false)
            } else {
                await store.settle(id)
            }
            let next = await queue.step(.init(direction: "next"), store: mail, dealtWith: false)
            XCTAssertEqual(LiveEmailPresentation.Key.selection(next.output)?.messageId, "B", next.output)
            XCTAssertFalse(next.output.contains("Previously delivered answer"), next.output)
            XCTAssertFalse(next.output.contains("presentedForOutcome"), next.output)
            let served = await queue.takeServedOutcomes()
            XCTAssertTrue(served.isEmpty)
            await queue.end()
        }
    }

    func testWhatsNextDismissesCompletedArchiveResultWithoutReintroducingSource() async throws {
        let mail = Container.shared.mailStore()
        let queue = LocalTriageQueue(mailAccounts: { ["one@example.test"] }, unreadOpeningLoader: { _ in nil })
        await queue.adopt([feedMessage("A"), feedMessage("B"), feedMessage("C")], store: mail)
        let id = UUID()
        await store.begin(id: id, task: "Archive A and report back", profileId: nil, origin: origin("A"))
        _ = await store.acceptContext(id, context: .init(scope: "current_email", expects: "receipt", authoredAt: Date(),
            timeZone: "UTC", input: "voice", parksSource: true))
        _ = await queue.parkTaskSource(try XCTUnwrap(store.existing(id)), store: mail)
        await queue.markActed(id: "A", as: "archive_message")
        await store.receipt(id, callId: "archive-A", tool: "archive_message", failed: false)
        await store.finish(id, state: "done", result: "A was archived.", reportBack: true)
        await queue.markActed(id: "B", as: "archive_message")
        let returned = await queue.step(.init(direction: "next"), store: mail, dealtWith: false)
        XCTAssertTrue(returned.output.contains("presentedForOutcome"), returned.output)
        XCTAssertEqual(LiveEmailPresentation.Key.selection(returned.output)?.messageId, "A")
        XCTAssertNil(LiveEmailPresentation.Key.step(returned.output), "A task result must not prepare the original email introduction")
        let plain = GmailReadTools.json(["done": false, "item": ["id": "A", "threadId": "thread-A", "account": "one@example.test"]])
        XCTAssertNotEqual(LiveSelectionGrounding.selection(returned.output), LiveSelectionGrounding.selection(plain))
        let served = await queue.takeServedOutcomes()
        XCTAssertEqual(served, [id])
        await store.settle(id)
        let writesBefore = await provider.writes()
        XCTAssertEqual(LiveFastAction.parse("Okay, what's next."), .next)
        XCTAssertTrue(LiveRequestRecovery.requiresQueueAction("Okay, what's next."))
        let next = await queue.step(.init(direction: "next"), store: mail, dealtWith: false)
        XCTAssertEqual(LiveEmailPresentation.Key.selection(next.output)?.messageId, "C")
        XCTAssertFalse(next.output.contains("presentedForOutcome"))
        let repeated = await queue.takeServedOutcomes()
        XCTAssertTrue(repeated.isEmpty)
        let writesAfter = await provider.writes()
        XCTAssertEqual(writesAfter, writesBefore, "Dismissing a receipt is navigation, not another provider write")
        await queue.end()
    }

    func testRestartReturnsUnreviewedResultAndKeepsSameSubjectAccountIdentity() async throws {
        let tasks = ApplicationTasks(request: { _ in self.answer("Result for account one") })
        let job = try tasks.job(request: "Research", commandID: nil, origin: origin("same-id"), profile: nil)
        _ = await tasks.run(job)
        let recovered = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        Container.shared.dispatchJobs.register { recovered }
        let mail = Container.shared.mailStore()
        let queue = LocalTriageQueue(mailAccounts: { ["one@example.test", "two@example.test"] }, unreadOpeningLoader: { _ in nil })
        await queue.adopt([feedMessage("same-id", account: "two@example.test"), feedMessage("B", account: "two@example.test")], store: mail)
        let result = await queue.step(.init(direction: "next"), store: mail, dealtWith: false)
        XCTAssertTrue(result.output.contains("presentedForOutcome"))
        XCTAssertTrue(result.output.contains("one@example.test"))
        await recovered.settle(job.id)
        await queue.end()
        let again = LocalTriageQueue(mailAccounts: { ["two@example.test"] }, unreadOpeningLoader: { _ in nil })
        await again.adopt([feedMessage("same-id", account: "two@example.test"), feedMessage("B", account: "two@example.test")], store: mail)
        let ordinary = await again.step(.init(direction: "back"), store: mail, dealtWith: false)
        XCTAssertFalse(ordinary.output.contains("presentedForOutcome"))
        let current = await again.currentId
        XCTAssertEqual(current, "same-id", "Ownership is keyed by account as well as message")
        await again.end()
    }

    func testAmbiguousLinkPersistsChoicesAndResumesOneTaskWithoutObsoleteResult() async throws {
        await provider.setHTML(#"<a href="https://events.example.test/one">Morning workshop</a><a href="https://events.example.test/two">Evening workshop</a><a href="https://events.example.test/confirm">Confirm RSVP</a>"#)
        let sourceID = UUID().uuidString
        var calls = 0
        let tasks = ApplicationTasks(request: { body in
            calls += 1
            if calls == 1 {
                return [["type": "function_call", "name": "read_email_link", "call_id": "choice-read",
                    "arguments": GmailReadTools.json(["account": "one@example.test", "message_id": sourceID, "question": "When is the event?", "link_hint": "workshop"])]]
            }
            XCTAssertTrue(String(describing: body).contains(sourceID))
            return self.answer("The evening workshop starts at six.")
        })
        Container.shared.applicationTasks.register { tasks }
        let job = try tasks.job(request: "Read the event link for its time", commandID: nil, origin: origin(sourceID), profile: nil)
        let pending = await tasks.run(job)
        XCTAssertEqual(pending.status, .pending)
        let row = try XCTUnwrap(store.existing(job.id))
        XCTAssertEqual(row.state, "awaiting_input")
        let choices = try XCTUnwrap(row.inputChoices)
        XCTAssertEqual(choices.count, 2)
        XCTAssertTrue(row.result?.contains("Which page") == true)
        let duplicate = try tasks.job(request: "Read the event link again", commandID: nil, origin: origin(sourceID), profile: nil)
        let refusal = await tasks.run(duplicate)
        XCTAssertTrue(refusal.text.contains(job.id.uuidString))
        XCTAssertNil(store.existing(duplicate.id))
        let recovered = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        XCTAssertEqual(recovered.existing(job.id)?.inputChoices, choices)
        let chosen = await TaskManagementTool.run(GmailReadTools.json(["action": "choose", "reference": job.id.uuidString,
            "revision": 1, "choice": choices[1].id]))
        XCTAssertFalse(chosen.1, chosen.0)
        _ = await tasks.result(job.id)
        XCTAssertEqual(store.existing(job.id)?.state, "done")
        XCTAssertEqual(store.existing(job.id)?.taskRevision, 2)
        XCTAssertEqual(store.existing(job.id)?.context?.linkChoice, choices[1].id)
        XCTAssertNil(store.existing(job.id)?.inputChoices)
        XCTAssertEqual(store.existing(job.id)?.origin, origin(sourceID))
        let rows = await store.history()
        XCTAssertEqual(rows.count, 1)
        do { try await tasks.choose(job.id, version: 1, choice: choices[0].id); XCTFail("Stale choice must fail") } catch { }
        let writes = await provider.writes()
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(calls, 2)
    }

    func testLinkChoiceRejectsOwnerChangeWritesAndSupportsCancellation() async throws {
        await provider.setHTML(#"<a href="https://events.example.test/one">One</a><a href="https://events.example.test/two">Two</a>"#)
        let sourceID = UUID().uuidString
        var calls = 0
        let tasks = ApplicationTasks(request: { _ in
            calls += 1
            return [["type": "function_call", "name": calls == 1 ? "read_email_link" : "archive_message", "call_id": UUID().uuidString,
                "arguments": GmailReadTools.json(["account": "one@example.test", "message_id": sourceID, "question": "Time?"])]]
        })
        let job = try tasks.job(request: "Read event link", commandID: nil, origin: origin(sourceID), profile: nil)
        _ = await tasks.run(job)
        let choice = try XCTUnwrap(store.existing(job.id)?.inputChoices?.first)
        backend.userId = "different-user"
        do { try await tasks.choose(job.id, version: 1, choice: choice.id); XCTFail("Owner changed") } catch { }
        backend.userId = "task-user"
        try await tasks.choose(job.id, version: 1, choice: choice.id)
        _ = await tasks.result(job.id)
        XCTAssertEqual(store.existing(job.id)?.state, "failed")
        let writes = await provider.writes()
        XCTAssertTrue(writes.isEmpty)
        await store.finish(job.id, state: "awaiting_input", result: "Choose", revision: 2)
        try await tasks.cancel(job.id, version: 2)
        XCTAssertEqual(store.existing(job.id)?.state, "cancelled")
        XCTAssertFalse(store.existing(job.id)?.needsReview == true)
    }

    func testNoVoiceTaskOnAAllowsArchiveOnBAndKeepsBothOrigins() async throws {
        var continuation: CheckedContinuation<[[String: Any]], Never>?
        var requests = 0
        let tasks = ApplicationTasks(request: { _ in
            requests += 1
            return await withCheckedContinuation { continuation = $0 }
        })
        let job = try tasks.job(request: "Research A", commandID: nil, origin: origin("A"), profile: nil)
        await tasks.submit(job)
        await tasks.submit(job)
        await waitFor { continuation != nil }
        let result = await tasks.perform(name: "archive_message", arguments: #"{"account":"one@example.test","message_id":"B"}"#,
            profile: nil, origin: origin("B"), inputSource: "voice")
        XCTAssertEqual(result.ok, true, result.text)
        let writes = await provider.writes()
        XCTAssertEqual(writes, ["B", "thread-B"])
        continuation?.resume(returning: answer("A researched"))
        _ = await tasks.result(job.id)
        let jobs = await store.history()
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(jobs.first(where: { $0.id == job.id })?.origin?.messageID, "A")
        XCTAssertEqual(jobs.first(where: { $0.id != job.id })?.origin?.messageID, "B")
        XCTAssertEqual(jobs.first(where: { $0.id != job.id })?.context?.input, "voice")
        XCTAssertTrue(jobs.allSatisfy(\.isDone))
        XCTAssertEqual(requests, 1)
    }

    func testConfirmedQuickActionResolvesExactOlderFailureAcrossRestartWithoutMovingSelection() async throws {
        let source = origin("A")
        let failure = UUID()
        await store.begin(id: failure, task: "Archive", profileId: nil, origin: source)
        _ = await store.acceptContext(failure, context: .init(scope: "current_email", expects: "receipt",
            authoredAt: Date(), timeZone: "UTC", input: "button"), preference: .quiet)
        await store.receipt(failure, callId: "failed", tool: "archive_message", failed: true)
        await store.finish(failure, state: "failed", result: "Nothing changed: mailbox mismatch.", reportBack: true)
        let model = DesktopWorkspaceModel()
        model.applyJobs(await store.history())
        XCTAssertEqual(model.workQueueTasks.count, 1)
        let tasks = ApplicationTasks()
        tasks.select(failure)
        let success = UUID()
        let args = #"{"account":"one@example.test","message_id":"A"}"#
        let result = await tasks.perform(id: success, name: "archive_message", arguments: args,
            profile: nil, origin: source, inputSource: "button")
        XCTAssertEqual(result.ok, true, result.text)
        _ = await tasks.perform(id: success, name: "archive_message", arguments: args,
            profile: nil, origin: source, inputSource: "button")
        let resolved = try XCTUnwrap(store.existing(failure))
        XCTAssertEqual(resolved.state, "failed")
        XCTAssertEqual(resolved.receipts?.first?.outcome, "failed")
        XCTAssertEqual(resolved.resolution?.jobID, success)
        XCTAssertFalse(resolved.activityNeedsAttention)
        XCTAssertFalse(store.shouldPresent(failure))
        model.applyJobs(await store.history())
        XCTAssertEqual(model.workQueueTasks.count, 0)
        XCTAssertEqual(model.activityReviewCount, 0)
        XCTAssertEqual(model.activityJobs.count, 2)
        XCTAssertEqual(tasks.selectedTaskID, failure, "Resolution must not steal focus")
        let restarted = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        XCTAssertEqual(restarted.existing(failure)?.resolution?.jobID, success)
        let recovered = await restarted.recover()
        XCTAssertTrue(recovered.isEmpty)
        let writes = await provider.writes()
        XCTAssertEqual(writes, ["A", "thread-A"])
    }

    func testRetryResolutionExcludesOtherScopesArgumentsAndUncertainOrCompoundOutcomes() async throws {
        let source = origin("A")
        let action = DispatchJob.QuickMailAction.captured(tool: "archive_message", arguments: [:], origin: source)!
        func row(_ state: String = "failed") -> DispatchJob {
            .init(id: UUID(), task: "Archive", state: state, result: "Original result",
                startedAt: Date(timeIntervalSince1970: 100), completedAt: Date(timeIntervalSince1970: 110),
                userId: "task-user", receipts: [.init(callId: UUID().uuidString, tool: "archive_message", outcome: "failed")],
                origin: source, quickMailAction: action)
        }
        let matching = row()
        var variants = [row("unknown"), row("partial"), row(), row(), row(), row(), row(), row()]
        variants[2].profileId = "other"
        variants[3].userId = "other"
        variants[4].origin = origin("B")
        variants[5].quickMailAction = .captured(tool: "trash_message", arguments: [:], origin: source)
        variants[6].quickMailAction = .captured(tool: "archive_message", arguments: ["extra": "different"], origin: source)
        variants[7].inFlightOperation = "uncertain"
        var compound = row()
        compound.command = .init(keyword: "compound", actions: [.init(tool: "archive_message", detail: "Archive")])
        var otherAccount = row()
        otherAccount.origin = origin("A", account: "two@example.test")
        var success = row("done")
        success.startedAt = Date(timeIntervalSince1970: 120)
        success.receipts = [.init(callId: "success", tool: "archive_message", outcome: "success")]
        let url = folder.appendingPathComponent("reconcile.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([matching] + variants + [compound, otherAccount, success]).write(to: url)
        let restarted = DispatchJobStore(url: url)
        XCTAssertEqual(restarted.existing(matching.id)?.resolution?.jobID, success.id)
        for candidate in variants + [compound, otherAccount] {
            XCTAssertNil(restarted.existing(candidate.id)?.resolution)
        }
        let recovered = await restarted.recover()
        XCTAssertFalse(recovered.contains { $0.id == matching.id })
        XCTAssertTrue(recovered.contains { $0.id == compound.id })
        XCTAssertTrue(recovered.contains { $0.id == variants[0].id })
        XCTAssertTrue(recovered.contains { $0.id == variants[1].id })
        XCTAssertTrue(recovered.contains { $0.id == otherAccount.id })
    }

    func testSameTargetWaitsAndCallerCancellationDoesNotCancelAcceptedWork() async throws {
        var continuation: CheckedContinuation<[[String: Any]], Never>?
        let tasks = ApplicationTasks(request: { _ in await withCheckedContinuation { continuation = $0 } })
        let job = try tasks.job(request: "Research A", commandID: nil, origin: origin("A"), profile: nil)
        let caller = Task { await tasks.run(job) }
        await waitFor { continuation != nil }
        caller.cancel()
        let archive = Task { await tasks.perform(name: "archive_message", arguments: #"{"account":"one@example.test","message_id":"A"}"#,
            profile: nil, origin: self.origin("A"), inputSource: "button") }
        for _ in 0..<100 { await Task.yield() }
        let before = await provider.writes()
        XCTAssertTrue(before.isEmpty)
        continuation?.resume(returning: answer("Done for A"))
        let result = await caller.value
        XCTAssertEqual(result.text, "Done for A")
        let archived = await archive.value
        let after = await provider.writes()
        XCTAssertEqual(archived.ok, true)
        XCTAssertEqual(after, ["A", "thread-A"])
        let rows = await store.history()
        XCTAssertEqual(rows.first(where: { $0.id != job.id })?.context?.input, "button")
    }

    func testPermissionChangeBeforeToolExecutionRefusesWrite() async throws {
        var continuation: CheckedContinuation<[[String: Any]], Never>?
        let tasks = ApplicationTasks(request: { _ in await withCheckedContinuation { continuation = $0 } })
        let job = try tasks.job(request: "Archive A", commandID: nil, origin: origin("A"), profile: nil)
        await tasks.submit(job)
        await waitFor { continuation != nil }
        backend.userId = "another-owner"
        continuation?.resume(returning: [["type": "function_call", "name": "archive_message", "call_id": "write-A",
            "arguments": #"{"account":"one@example.test","message_id":"A"}"#]])
        guard case .task(let result) = await tasks.result(job.id) else { return XCTFail("Expected task") }
        XCTAssertEqual(result.ok, false)
        let writes = await provider.writes()
        let history = await store.history()
        XCTAssertTrue(writes.isEmpty)
        XCTAssertTrue(history.isEmpty)
    }

    func testExplicitSavedCommandUsesStoredStepsAndDisabledCommandIsRefused() async throws {
        let saved = Container.shared.customCommands()
        _ = await saved.save(keyword: "summarize test", label: "Summarize this email", actions: [.init(tool: "summarize", detail: "Summarize this source")])
        let command = try XCTUnwrap(saved.commands.first { $0.keyword == "summarize test" })
        let tasks = ApplicationTasks(request: { _ in self.answer("Summary for A") })
        let job = try tasks.job(request: command.title, commandID: command.id, origin: origin("A"), profile: nil)
        XCTAssertEqual(job.commandSteps, command.actions)
        _ = await tasks.run(job)
        let history = await store.history()
        XCTAssertEqual(history.first?.command?.keyword, command.keyword)
        XCTAssertThrowsError(try tasks.job(request: "Missing", commandID: "missing", origin: origin("A"), profile: nil))
    }

    func testCorrectionKeepsSourceAndRejectsLateRevisionResults() async throws {
        var continuation: CheckedContinuation<[[String: Any]], Never>?
        var count = 0
        let tasks = ApplicationTasks(request: { _ in
            count += 1
            if count == 1 { return await withCheckedContinuation { continuation = $0 } }
            return self.answer("Corrected result for A")
        })
        let job = try tasks.job(request: "Research A", commandID: nil, origin: origin("A"), profile: nil)
        await tasks.submit(job)
        await waitFor { continuation != nil }
        tasks.select(job.id)
        let correction = Task { try await tasks.correct(job.id, version: 1, instruction: "Use next week") }
        await waitFor { self.store.existing(job.id)?.state == "cancel_requested" }
        continuation?.resume(returning: answer("Obsolete result"))
        try await correction.value
        _ = await tasks.result(job.id)
        await store.finish(job.id, state: "done", result: "Late old result", revision: 1)
        let row = try XCTUnwrap(store.existing(job.id))
        XCTAssertEqual(row.taskRevision, 2)
        XCTAssertEqual(row.origin, origin("A"))
        XCTAssertEqual(row.result, "Corrected result for A")
        XCTAssertEqual(count, 2)
    }

    func testAmbiguousReferenceDoesNotModifyEitherTask() async throws {
        let tasks = ApplicationTasks(request: { _ in self.answer("Done") })
        let a = try tasks.job(request: "Research same subject", commandID: nil, origin: origin("A"), profile: nil)
        let b = try tasks.job(request: "Research same subject", commandID: nil, origin: origin("B", account: "two@example.test"), profile: nil)
        _ = await tasks.run(a); _ = await tasks.run(b)
        do { _ = try await tasks.resolve("Research same subject"); XCTFail("Must ask which task") }
        catch { XCTAssertTrue(error.localizedDescription.contains(String(a.id.uuidString.prefix(8)))) }
        let selected = try await tasks.resolve(String(b.id.uuidString.prefix(8)))
        XCTAssertEqual(selected.origin?.account, "two@example.test")
        XCTAssertEqual(store.existing(a.id)?.taskRevision, 1)
        XCTAssertEqual(store.existing(b.id)?.taskRevision, 1)
    }

    func testQueuedCancellationNeverExecutesAndRestartDoesNotRestartWork() async throws {
        var continuation: CheckedContinuation<[[String: Any]], Never>?
        let tasks = ApplicationTasks(capacity: 1, request: { _ in await withCheckedContinuation { continuation = $0 } })
        let a = try tasks.job(request: "Research A", commandID: nil, origin: origin("A"), profile: nil)
        let b = try tasks.job(request: "Research B", commandID: nil, origin: origin("B"), profile: nil)
        await tasks.submit(a); await tasks.submit(b)
        await waitFor { continuation != nil }
        let recovered = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        XCTAssertEqual(recovered.existing(a.id)?.state, "unknown")
        XCTAssertEqual(recovered.existing(b.id)?.state, "awaiting_input")
        try await tasks.cancel(b.id, version: 1)
        XCTAssertEqual(store.existing(b.id)?.state, "cancelled")
        continuation?.resume(returning: answer("Done A"))
        _ = await tasks.result(a.id)
        XCTAssertEqual(store.existing(b.id)?.state, "cancelled")
    }

    func testCommittedOrUncertainTaskCannotBeReplayedByCorrection() async throws {
        let tasks = ApplicationTasks(request: { _ in self.answer("Done") })
        let job = try tasks.job(request: "Research A", commandID: nil, origin: origin("A"), profile: nil)
        _ = await tasks.run(job)
        await store.receipt(job.id, callId: "confirmed-write", tool: "send_email", failed: false, revision: 1)
        do { try await tasks.correct(job.id, version: 1, instruction: "Change the time"); XCTFail("Must not repeat committed writes") }
        catch { XCTAssertTrue(error.localizedDescription.contains("committed")) }
        XCTAssertEqual(store.existing(job.id)?.taskRevision, 1)
        let other = try tasks.job(request: "Research B", commandID: nil, origin: origin("B"), profile: nil)
        _ = await tasks.run(other)
        await store.finish(other.id, state: "unknown", result: "Timeout", revision: 1)
        do { try await tasks.correct(other.id, version: 1, instruction: "Retry"); XCTFail("Must reconcile") }
        catch { XCTAssertTrue(error.localizedDescription.contains("reconcile")) }
    }

    func testCancellationAfterConfirmedWriteKeepsReceiptAndNeverRepeatsIt() async throws {
        var continuation: CheckedContinuation<[[String: Any]], Never>?
        var requests = 0
        let tasks = ApplicationTasks(request: { _ in
            requests += 1
            if requests == 1 { return [["type": "function_call", "name": "archive_message", "call_id": "write-A",
                "arguments": #"{"account":"one@example.test","message_id":"A"}"#]] }
            return await withCheckedContinuation { continuation = $0 }
        })
        let job = try tasks.job(request: "Archive A then research", commandID: nil, origin: origin("A"), profile: nil)
        await tasks.submit(job)
        await waitFor { continuation != nil }
        try await tasks.cancel(job.id, version: 1)
        XCTAssertEqual(store.existing(job.id)?.state, "cancel_requested")
        continuation?.resume(returning: answer("Obsolete completion"))
        _ = await tasks.result(job.id)
        XCTAssertEqual(store.existing(job.id)?.state, "partial")
        XCTAssertTrue(store.existing(job.id)?.hasCommittedWrites == true)
        XCTAssertNil(store.existing(job.id)?.inFlightOperation)
        let writes = await provider.writes()
        XCTAssertEqual(writes, ["A", "thread-A"])
        do { try await tasks.correct(job.id, version: 1, instruction: "Try again"); XCTFail("Must not repeat") } catch { XCTAssertTrue(error.localizedDescription.contains("committed")) }
        XCTAssertEqual(requests, 2)
    }

    func testStaleRevisionCannotChangeStateOrCheckpointAndReceiptIsRetained() async throws {
        let tasks = ApplicationTasks(request: { _ in self.answer("Done") })
        let job = try tasks.job(request: "Research A", commandID: nil, origin: origin("A"), profile: nil)
        _ = await tasks.run(job)
        try await tasks.correct(job.id, version: 1, instruction: "More detail")
        _ = await tasks.result(job.id)
        await store.setState(job.id, state: "running", revision: 1)
        await store.finish(job.id, state: "failed", result: "Old failure", revision: 1)
        await store.receipt(job.id, callId: "late-write", tool: "send_email", failed: false, revision: 1)
        XCTAssertEqual(store.existing(job.id)?.state, "done")
        XCTAssertEqual(store.existing(job.id)?.receipts?.first?.revision, 1)
        XCTAssertEqual(store.existing(job.id)?.taskRevision, 2)
    }

    func testCancellationDuringExternalOperationStaysUnknown() async throws {
        await provider.pauseWrites()
        let tasks = ApplicationTasks(request: { _ in [["type": "function_call", "name": "archive_message", "call_id": "uncertain-A",
            "arguments": #"{"account":"one@example.test","message_id":"A"}"#]] })
        let job = try tasks.job(request: "Archive A", commandID: nil, origin: origin("A"), profile: nil)
        await tasks.submit(job)
        for _ in 0..<1000 {
            if await provider.isWaiting() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNotNil(store.existing(job.id)?.inFlightOperation)
        try await tasks.cancel(job.id, version: 1)
        await provider.releaseWrite()
        _ = await tasks.result(job.id)
        XCTAssertEqual(store.existing(job.id)?.state, "unknown")
        do { try await tasks.correct(job.id, version: 1, instruction: "Retry"); XCTFail("Must reconcile") }
        catch { XCTAssertTrue(error.localizedDescription.contains("reconcile")) }
    }

    func testContextualRoutineCompletionStaysInHistoryWithoutReturningToFeed() async throws {
        var requests = 0
        let tasks = ApplicationTasks(request: { body in
            requests += 1
            let format = (body["text"] as? [String: Any])?["format"] as? [String: Any]
            let schema = format?["schema"] as? [String: Any]
            XCTAssertTrue((schema?["required"] as? [String])?.contains("report_back") == true)
            XCTAssertTrue((body["instructions"] as? String)?.contains("Infer report_back from the user's request") == true)
            if requests == 1 {
                return [["type": "function_call", "name": "archive_message", "call_id": "archive-A",
                    "arguments": #"{"account":"one@example.test","message_id":"A"}"#]]
            }
            return self.answer(#"{"status":"completed","report":"Archived the selected email.","report_back":false}"#)
        })
        let job = try tasks.job(request: "Archive this email", commandID: nil, origin: origin("A"), profile: nil)
        XCTAssertNil(job.completionPreference)
        let outcome = await tasks.run(job)
        let row = try XCTUnwrap(store.existing(job.id))
        XCTAssertEqual(requests, 2, "Reporting is inferred in the existing worker response")
        XCTAssertFalse(outcome.reportBack)
        XCTAssertNil(row.completionPreference)
        XCTAssertEqual(row.result, "Archived the selected email.")
        XCTAssertFalse(row.needsReview)
        XCTAssertNotNil(row.deliveredAt)
        XCTAssertTrue(row.hasCommittedWrites)
        XCTAssertFalse(store.shouldPresent(job.id, revision: 1))
        let restored = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        XCTAssertEqual(restored.existing(job.id)?.reportBack, false)
        XCTAssertFalse(restored.existing(job.id)?.needsReview ?? true)
    }

    func testContextualFindingsAndUncertainReportingRemainVisible() async throws {
        for response in [
            #"{"status":"completed","report":"The workshop starts at six.","report_back":true}"#,
            #"{"status":"completed","report":"The workshop starts at six."}"#,
            #"{"report":"Incomplete response metadata","report_back":false}"#,
            #"{"status":"needs_input","report":"Which workshop should I use?","report_back":false}"#
        ] {
            let tasks = ApplicationTasks(request: { _ in self.answer(response) })
            let job = try tasks.job(request: "Find the workshop time in this email", commandID: nil, origin: origin("A"), profile: nil)
            let outcome = await tasks.run(job)
            let row = try XCTUnwrap(store.existing(job.id))
            XCTAssertNil(row.completionPreference)
            XCTAssertTrue(outcome.reportBack)
            XCTAssertTrue(row.needsReview)
            XCTAssertTrue(store.shouldPresent(job.id, revision: 1))
            XCTAssertNil(row.deliveredAt)
        }
        let tasks = ApplicationTasks(request: { _ in throw DispatchWorker.StepFailure(message: "Could not complete the lookup") })
        let job = try tasks.job(request: "Find the workshop time", commandID: nil, origin: origin("B"), profile: nil)
        let outcome = await tasks.run(job)
        XCTAssertTrue(outcome.reportBack)
        XCTAssertTrue(store.existing(job.id)?.needsReview == true)
        let writes = await provider.writes()
        XCTAssertTrue(writes.isEmpty)
    }

    func testExplicitRequestToReportOverridesInferredQuietSuccess() async throws {
        let tasks = ApplicationTasks(request: { _ in
            self.answer(#"{"status":"completed","report":"The work is done.","report_back":false}"#)
        })
        let job = try tasks.job(request: "Do this and bring me the result when it's ready", commandID: nil, origin: origin("A"), profile: nil)
        let outcome = await tasks.run(job)
        XCTAssertTrue(outcome.reportBack)
        XCTAssertEqual(store.existing(job.id)?.completionPreference, .bringBack)
        XCTAssertTrue(store.existing(job.id)?.needsReview == true)
    }

    func testQuietSuccessHasNoReturnedItemOrSpeechAndPersistsPreference() async throws {
        let tasks = ApplicationTasks(request: { _ in self.answer("Done") })
        let job = try tasks.job(request: "Research A. No need to tell me when it succeeds", commandID: nil, origin: origin("A"), profile: nil)
        let outcome = await tasks.run(job)
        let row = try XCTUnwrap(store.existing(job.id))
        XCTAssertFalse(outcome.reportBack)
        XCTAssertFalse(row.needsReview)
        XCTAssertEqual(row.desktopStatusLabel, "Completed")
        XCTAssertFalse(store.shouldPresent(job.id, revision: 1))
        let restored = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        XCTAssertEqual(restored.existing(job.id)?.completionPreference, .quiet)
        XCTAssertFalse(restored.existing(job.id)?.needsReview ?? true)
        let archive = await tasks.perform(name: "archive_message", arguments: #"{"account":"one@example.test","message_id":"B"}"#,
            profile: nil, origin: origin("B"))
        XCTAssertEqual(archive.ok, true)
        let archived = await store.history().first { $0.id != job.id }
        XCTAssertEqual(archived?.desktopStatusLabel, "Completed")
        XCTAssertFalse(archived?.needsReview ?? true)
    }

    func testPreferenceChangesBeforeAndAfterCompletionNeverRerun() async throws {
        var continuation: CheckedContinuation<[[String: Any]], Never>?
        var requests = 0
        let tasks = ApplicationTasks(request: { _ in requests += 1; return await withCheckedContinuation { continuation = $0 } })
        let job = try tasks.job(request: "Research A", commandID: nil, origin: origin("A"), profile: nil)
        await tasks.submit(job)
        await waitFor { continuation != nil }
        XCTAssertEqual(store.existing(job.id)?.state, "running")
        let beforeStateChange = tasks.revision
        await store.setState(job.id, state: "running", revision: 1)
        XCTAssertGreaterThan(tasks.revision, beforeStateChange, "Persisted progress must refresh the desktop while work runs")
        try await tasks.setPreference(job.id, version: 1, preference: .quiet)
        continuation?.resume(returning: answer("Result A"))
        _ = await tasks.result(job.id)
        XCTAssertFalse(store.existing(job.id)?.needsReview ?? true)
        try await tasks.setPreference(job.id, version: 1, preference: .bringBack)
        XCTAssertTrue(store.existing(job.id)?.needsReview == true)
        let model = DesktopWorkspaceModel()
        model.jobs = await store.history()
        XCTAssertEqual(model.returnedTasks.map(\.id), [job.id])
        try await tasks.setPreference(job.id, version: 1, preference: .quiet)
        XCTAssertFalse(store.shouldPresent(job.id, revision: 1))
        try await tasks.setPreference(job.id, version: 1, preference: .bringBack)
        try await tasks.reviewed(job.id, version: 1)
        XCTAssertFalse(store.existing(job.id)?.needsReview ?? true)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(store.existing(job.id)?.origin, origin("A"))
    }

    func testQuietNeedsInputAndFailuresRemainActionableWithoutApproval() async throws {
        var requests = 0
        let tasks = ApplicationTasks(request: { _ in
            requests += 1
            return self.answer(#"{"status":"needs_input","report":"Which date should I use?"}"#)
        })
        let job = try tasks.job(request: "Find a time. No need to tell me when it succeeds", commandID: nil, origin: origin("A"), profile: nil)
        let outcome = await tasks.run(job)
        XCTAssertTrue(outcome.reportBack)
        XCTAssertEqual(store.existing(job.id)?.state, "awaiting_input")
        XCTAssertTrue(store.existing(job.id)?.needsReview == true)
        try await tasks.setPreference(job.id, version: 1, preference: .bringBack)
        XCTAssertEqual(requests, 1)
        let writes = await provider.writes()
        XCTAssertTrue(writes.isEmpty)
        for state in ["failed", "partial", "unknown"] {
            await store.finish(job.id, state: state, result: "Provider needs checking", revision: 1)
            try await tasks.setPreference(job.id, version: 1, preference: .quiet)
            XCTAssertTrue(store.existing(job.id)?.needsReview == true)
            XCTAssertTrue(store.shouldPresent(job.id, revision: 1))
        }
    }

    func testCompletionVoicePhrasesAndConservativeLegacyMigration() {
        XCTAssertEqual(DispatchJob.CompletionPreference.requested(in: "No need to tell me when it succeeds"), .quiet)
        XCTAssertEqual(DispatchJob.CompletionPreference.requested(in: "Bring me the result when it's ready"), .bringBack)
        XCTAssertNil(DispatchJob.CompletionPreference.requested(in: "Do this in the background"))
        let legacy = DispatchJob(id: UUID(), task: "Old success", state: "done", result: "Done", reportBack: true)
        XCTAssertFalse(legacy.needsReview)
    }

    func testExplicitVoiceBackgroundRequestPinsSourceBeforeSelectionChanges() async throws {
        var submitted: String?
        let tasks = ApplicationTasks(request: { body in
            submitted = GmailReadTools.json(body)
            return self.answer("Done A")
        })
        Container.shared.applicationTasks.register { tasks }
        let realtime = RealtimeService()
        Container.shared.realtimeService.register { realtime }
        let queue = LocalTriageQueue()
        let client = FullDuplexVoiceClient(localContext: context, localTriage: queue)
        client.standingStep = #"{"done":false,"item":{"id":"A","account":"one@example.test","from":"Same sender","subject":"Same subject","threadId":"thread-A"}}"#
        client.latestCompletedUserUtterance = "Research this source in the background"
        client.startDispatch(callId: "background-A", argumentsJSON: #"{"task":"Research this source","scope":"current_email","expects":"answer","requested_background":true,"completion_preference":"quiet"}"#)
        client.standingStep = #"{"done":false,"item":{"id":"B","account":"two@example.test","from":"Same sender","subject":"Same subject","threadId":"thread-B"}}"#
        await waitFor { submitted != nil }
        let rows = await store.history()
        let row = try XCTUnwrap(rows.first)
        _ = await tasks.result(row.id)
        XCTAssertEqual(row.origin?.messageID, "A")
        XCTAssertEqual(row.origin?.account, "one@example.test")
        XCTAssertEqual(row.completionPreference, .quiet)
        XCTAssertTrue(submitted?.contains("thread-A") == true)
        XCTAssertEqual(client.standingStep.flatMap(LiveEmailPresentation.Key.step)?.messageId, "B")
    }

    func testVoiceEndPreservesVisibleTasksButProfileChangeClearsThem() {
        let model = DesktopWorkspaceModel()
        model.conversationID = UUID()
        let job = DispatchJob(id: UUID(), task: "Research A", state: "running")
        model.jobs = [job]
        model.selectedJob = job
        model.conversationID = nil
        XCTAssertEqual(model.jobs.map(\.id), [job.id])
        XCTAssertEqual(model.selectedJob?.id, job.id)
        model.profileID = "different-profile"
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertNil(model.selectedJob)
    }

    func testKeyboardActionsAcceptImmediatelyDeduplicateAndRetainSourceDuringFailure() async throws {
        let tasks = ApplicationTasks(request: { _ in XCTFail("Keyboard actions need no model round trip"); return [] })
        Container.shared.applicationTasks.register { tasks }
        let realtime = RealtimeService()
        Container.shared.realtimeService.register { realtime }
        let model = DesktopWorkspaceModel()
        let interactor = DesktopWorkspaceInteractor(hasMicrophone: { false })
        let subscriptions = interactor.onLoad(viewModel: model)
        subscriptions.forEach { $0.cancel() }
        for _ in 0..<30 { await Task.yield() }
        model.scopeHydrating = false
        model.startingFeedRows = nil
        let rows = ["A", "B", "C"].map { DesktopFeedRow.email(account: "one@example.test", messageID: $0, subject: $0, sender: "Sender") }
        model.feedPreview = .init(mail: .init(rows: rows, count: 3), slack: .init())
        model.previewSelection = rows[0]
        let a = try XCTUnwrap(model.feedActionContext)
        await provider.pauseWrites()
        let acceptedAt = Date()
        interactor.performFeedShortcut(.archive, context: a)
        XCTAssertTrue(model.pendingFeedActions.contains(a.selection))
        XCTAssertEqual(model.requestedActionContext, a)
        XCTAssertLessThan(Date().timeIntervalSince(acceptedAt), 0.1, "Visual acceptance is synchronous, before the provider runs")
        interactor.performFeedAction(.archive, context: a)
        interactor.performFeedShortcut(.next, context: a)
        for _ in 0..<200 where !(await provider.isWaiting()) { try await Task.sleep(for: .milliseconds(5)) }
        let waiting = await provider.isWaiting()
        XCTAssertTrue(waiting)
        model.feedPreview = .init(mail: .init(rows: Array(rows.dropFirst()), count: 2), slack: .init())
        model.previewSelection = rows[1]
        let b = try XCTUnwrap(model.feedActionContext)
        interactor.performFeedShortcut(.next, context: b)
        await waitFor { model.previewSelection?.selection?.messageID == "C" }
        XCTAssertEqual(model.previewSelection?.selection?.messageID, "C")
        await provider.releaseWrite()
        await waitFor { model.pendingFeedActions.isEmpty }
        let writes = await provider.writes()
        XCTAssertEqual(writes, ["A"], "A held shortcut or alternating action must not create a second provider mutation")
        XCTAssertNotNil(model.feedActionError, "An uncertain provider outcome must remain visible")
        XCTAssertEqual(model.previewSelection?.selection?.messageID, "C", "A late result cannot advance the replacement email")
        let history = await store.history()
        let receipt = try XCTUnwrap(history.first { $0.origin?.messageID == "A" })
        XCTAssertEqual(receipt.origin?.account, "one@example.test")
    }

    func testDesktopSelectionAuthorizesActionsWithoutInventingAConversation() throws {
        let model = DesktopWorkspaceModel()
        let a = DesktopFeedRow.email(account: "one@example.test", messageID: "A", subject: "Same", sender: "Same")
        model.feedPreview = .init(mail: .init(rows: [a], count: 1), slack: .init())
        model.previewSelection = a
        let context = try XCTUnwrap(model.feedActionContext)
        XCTAssertNil(context.conversationID)
        XCTAssertEqual(model.taskOrigin(context)?.messageID, "A")
        model.previewSelection = .email(account: "two@example.test", messageID: "C", subject: "Same", sender: "Same")
        XCTAssertNil(model.taskOrigin(context))
    }

    private var notionFilingSteps: [CommandAction] { [
        .init(tool: "gmail_get_message", detail: "Read this invocation's email and identify company and period"),
        .init(tool: "notion-search", detail: "Find that company's existing Investor Updates destination; clarify if missing or ambiguous"),
        .init(tool: "notion-fetch", detail: "Read the matching destination and its schema"),
        .init(tool: "notion-create-pages", detail: "File this update using that schema and retain its link"),
        .init(tool: "archive_message", detail: "Archive this invocation's source only after the filing is confirmed")
    ] }

    private func notionFixture(failure: String? = nil) -> ScriptedMCPServer {
        let storage = InMemoryRemoteMCPGrantStorage()
        Container.shared.remoteMCPGrantStorage.register { storage }
        for id in failure == "timeout" ? ["workspace", "other"] : ["workspace"] {
            RemoteMCPGrantStore.save(.init(id: id, label: id, profileId: nil, accessToken: "synthetic", refreshToken: "r",
                expiresAt: Date().addingTimeInterval(3600), needsReauth: false, clientId: "c",
                tokenEndpoint: "https://mcp.notion.com/token", resource: "https://mcp.notion.com/mcp", grantedAt: Date()), .notion)
        }
        let server = ScriptedMCPServer { call in
            let id = call.json["id"] ?? NSNull()
            switch call.json["method"] as? String {
            case "initialize": return ScriptedMCPServer.sse(id: id, result: #"{"protocolVersion":"2025-06-18"}"#)
            case "notifications/initialized": return .init(status: 202, body: "")
            default:
                let name = (call.json["params"] as? [String: Any])?["name"] as? String
                if name == "notion-create-pages", failure == "timeout" { return .init(status: 504) }
                let failed = name == "notion-create-pages" && failure != nil
                let text = failed ? failure! : "Verified destination/schema; receipt https://notion.so/synthetic-update"
                return ScriptedMCPServer.sse(id: id, result: GmailReadTools.json([
                    "isError": failed, "content": [["type": "text", "text": text]]]))
            }
        }
        Container.shared.remoteMCPCredentials.register { RemoteMCPCredentials(transport: server) }
        return server
    }

    private func notionStep(_ body: [String: Any], source: DispatchJob.MailOrigin, needsInput: Bool = false) -> [[String: Any]] {
        let instruction = (body["input"] as? [[String: Any]])?.last?["content"] as? String ?? ""
        guard let suffix = instruction.components(separatedBy: "You must call ").dropFirst().first,
              let name = suffix.split(separator: " ").first.map(String.init) else {
            return answer(#"{"status":"completed","report":"Filed the update: https://notion.so/synthetic-update","report_back":true}"#)
        }
        if name == "notion-fetch", needsInput {
            return answer(#"{"status":"needs_input","report":"Which Investor Updates database should I use?","report_back":true}"#)
        }
        let database = source.messageID == "A" ? "1f8d872b-594c-80a4-b2f4-00370af2b13f" : "2f8d872b-594c-80a4-b2f4-00370af2b13f"
        let args: [String: Any]
        switch name {
        case "notion-search": args = ["query": "Company \(source.messageID) Investor Updates"]
        case "notion-fetch": args = ["id": database]
        case "notion-create-pages": args = ["parent_database_id": database, "title": "Company \(source.messageID) October update", "content": "Synthetic source \(source.messageID)"]
        default: args = ["message_id": source.messageID, "account": source.account]
        }
        return [["type": "function_call", "name": name, "call_id": UUID().uuidString, "arguments": GmailReadTools.json(args)]]
    }

    func testSavedNotionCommandRestartsAndFilesTwoSourcesIntoSeparateDestinations() async throws {
        let server = notionFixture()
        let commands = Container.shared.customCommands()
        _ = await commands.save(keyword: "file investor update", label: "File investor update", actions: notionFilingSteps)
        let reopened = CustomCommandStore()
        await reopened.refresh()
        let command = try XCTUnwrap(reopened.commands.first)
        XCTAssertEqual(command.actions, notionFilingSteps)
        for source in [origin("A"), origin("B", account: "two@example.test")] {
            let tasks = ApplicationTasks(request: { self.notionStep($0, source: source) })
            let job = try tasks.job(request: command.title, commandID: command.id, origin: source, profile: nil)
            let result = await tasks.run(job)
            let row = try XCTUnwrap(store.existing(job.id))
            XCTAssertTrue(row.isDone, result.text)
            XCTAssertEqual(row.command?.completedSteps, 5)
            XCTAssertEqual(row.receipts?.filter { $0.outcome == "success" }.map(\.tool), ["notion-create-pages", "archive_message"])
            XCTAssertTrue(row.command?.completedResults.contains { $0.contains("https://notion.so/synthetic-update") } == true)
        }
        let creates = server.calls.compactMap { $0.json["params"] as? [String: Any] }.filter { $0["name"] as? String == "notion-create-pages" }
        XCTAssertEqual(creates.count, 2)
        XCTAssertTrue(GmailReadTools.json(creates[0]).contains("1f8d872b"))
        XCTAssertTrue(GmailReadTools.json(creates[1]).contains("2f8d872b"))
        let writes = await provider.writes()
        XCTAssertEqual(writes.filter { $0.hasPrefix("thread-") }, ["thread-A", "thread-B"])
    }

    func testAmbiguousNotionCommandClarifiesWithoutLosingSourceOrRepeatingFinishedSteps() async throws {
        let server = notionFixture()
        let commands = Container.shared.customCommands()
        _ = await commands.save(keyword: "file investor update", label: "", actions: notionFilingSteps)
        let command = try XCTUnwrap(commands.commands.first)
        var ambiguous = true
        let tasks = ApplicationTasks(request: { self.notionStep($0, source: self.origin("A"), needsInput: ambiguous) })
        let job = try tasks.job(request: command.title, commandID: command.id, origin: origin("A"), profile: nil)
        _ = await tasks.run(job)
        XCTAssertEqual(store.existing(job.id)?.state, "awaiting_input")
        XCTAssertEqual(store.existing(job.id)?.command?.completedSteps, 2)
        let before = await provider.writes()
        XCTAssertTrue(before.isEmpty)
        ambiguous = false
        try await tasks.correct(job.id, version: 1, instruction: "Use the Company A database under Published.")
        let result = await tasks.result(job.id)
        XCTAssertTrue(store.existing(job.id)?.isDone == true, result.text)
        XCTAssertEqual(store.existing(job.id)?.origin?.messageID, "A")
        XCTAssertEqual(store.existing(job.id)?.command?.completedSteps, 5)
        let names = server.calls.compactMap { ($0.json["params"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(names, ["notion-search", "notion-fetch", "notion-create-pages"])
        let writes = await provider.writes()
        XCTAssertEqual(writes.filter { $0.hasPrefix("thread-") }, ["thread-A"])
    }

    func testNotionCommandDoesNotArchiveFailedOrUncertainWritesOrRepeatUnknownPages() async throws {
        let commands = Container.shared.customCommands()
        _ = await commands.save(keyword: "file investor update", label: "", actions: notionFilingSteps)
        let command = try XCTUnwrap(commands.commands.first)
        for failure in ["Schema mismatch", "Permission denied", "timeout"] {
            let server = notionFixture(failure: failure)
            let tasks = ApplicationTasks(request: { self.notionStep($0, source: self.origin("A")) })
            let job = try tasks.job(request: command.title, commandID: command.id, origin: origin("A"), profile: nil)
            let result = await tasks.run(job)
            XCTAssertNotEqual(result.ok, true)
            let row = try XCTUnwrap(store.existing(job.id))
            XCTAssertEqual(row.command?.completedSteps, 3)
            if failure == "timeout" {
                XCTAssertEqual(row.state, "unknown")
                XCTAssertThrowsError(try row.commandRetry(using: command, profileID: nil, accounts: ["one@example.test"]))
                do { try await tasks.correct(job.id, version: 1, instruction: "Try again"); XCTFail("Unknown write replayed") } catch {}
            }
            let writes = server.calls.filter { ($0.json["params"] as? [String: Any])?["name"] as? String == "notion-create-pages" }
            XCTAssertEqual(writes.count, 1, "Never fall through to a second workspace after an uncertain write")
        }
        let writes = await provider.writes()
        XCTAssertTrue(writes.filter { $0.hasPrefix("thread-") }.isEmpty)
    }

    func testSavedLabelResolvesPerInboxAndPersistsMappingsAcrossRestart() async throws {
        let commands = Container.shared.customCommands()
        let actions: [CommandAction] = [.init(tool: "label_message", detail: "Apply Followup",
            resolvedLabel: .init(id: "one-label", name: "Followup", account: "one@example.test")),
            .init(tool: "archive_message", detail: "Archive this email")]
        _ = await commands.save(keyword: "follow up", label: "Follow up", actions: actions)
        for (index, account) in ["two@example.test", "one@example.test", "two@example.test"].enumerated() {
            let selected = origin("source-\(index)", account: account)
            let command = try XCTUnwrap(commands.commands.first)
            let tasks = ApplicationTasks(request: { body in
                let name = (body["tool_choice"] as? [String: Any])?["name"] as? String ?? "unexpected"
                return [["type": "function_call", "name": name, "call_id": UUID().uuidString,
                    "arguments": GmailReadTools.json(["message_id": selected.messageID, "account": selected.account])]]
            })
            let job = try tasks.job(request: "follow up", commandID: command.id, origin: selected, profile: nil)
            let result = await tasks.run(job)
            XCTAssertEqual(result.ok, true, result.text)
            XCTAssertFalse(result.reportBack, "An action-only saved command infers quiet completion")
            XCTAssertNil(store.existing(job.id)?.completionPreference)
            XCTAssertFalse(store.existing(job.id)?.needsReview ?? true)
            XCTAssertEqual(store.existing(job.id)?.command?.completedSteps, 2)
        }
        let reopened = CustomCommandStore()
        await reopened.refresh()
        XCTAssertEqual(reopened.commands.first?.actions.first?.resolvedLabel?.mappings,
                       ["one@example.test": "one-label", "two@example.test": "two-label"])
        let labels = await provider.labelWrites()
        XCTAssertEqual(labels, ["two@example.test:two-label", "one@example.test:one-label", "two@example.test:two-label"])
        let writes = await provider.writes()
        for index in 0..<3 { XCTAssertEqual(writes.filter { $0 == "thread-source-\(index)" }.count, 1) }
    }

    func testMissingAmbiguousOrDisconnectedLabelCannotReachAnyCommandStep() async throws {
        let commands = Container.shared.customCommands()
        let actions: [CommandAction] = [.init(tool: "label_message", detail: "Apply Followup",
            resolvedLabel: .init(id: "stale", name: "Followup", account: "one@example.test")),
            .init(tool: "archive_message", detail: "Archive")]
        _ = await commands.save(keyword: "follow up", label: "", actions: actions)
        let command = try XCTUnwrap(commands.commands.first)
        for ambiguous in [false, true] {
            commands.labelLoader = { _ in ambiguous ? [.init(id: "a", name: "Followup", user: true), .init(id: "b", name: "FOLLOWUP", user: true)] : [] }
            let tasks = ApplicationTasks(request: { _ in XCTFail("No command step may start"); return [] })
            let job = try tasks.job(request: "follow up", commandID: command.id, origin: origin(UUID().uuidString), profile: nil)
            let result = await tasks.run(job)
            XCTAssertEqual(result.ok, false)
            XCTAssertTrue(result.text.contains(ambiguous ? "Ambiguous" : "Missing"), result.text)
            XCTAssertEqual(store.existing(job.id)?.command?.completedSteps, 0)
            XCTAssertNotNil(store.existing(job.id)?.origin)
        }
        let writes = await provider.writes()
        XCTAssertTrue(writes.isEmpty)
        XCTAssertThrowsError(try ApplicationTasks().job(request: "follow up", commandID: command.id,
            origin: origin("disconnected", account: "gone@example.test"), profile: nil))
    }

    func testScopedCommandRejectsWrongInboxAndMappingUpdatesDoNotInvalidateCheckpoints() async throws {
        let commands = Container.shared.customCommands()
        let action = CommandAction(tool: "label_message", detail: "Apply Followup",
            resolvedLabel: .init(id: "one-label", name: "Followup", account: "one@example.test", scope: .savedAccount))
        _ = await commands.save(keyword: "follow up", label: "", actions: [action])
        let command = try XCTUnwrap(commands.commands.first)
        XCTAssertThrowsError(try ApplicationTasks().job(request: "follow up", commandID: command.id,
            origin: origin("B", account: "two@example.test"), profile: nil))
        var mapped = action
        mapped.resolvedLabel?.mappings = ["one@example.test": "replacement"]
        XCTAssertEqual(mapped.definition, action.definition)
        let legacy = try JSONDecoder().decode(CommandAction.ResolvedLabel.self,
            from: Data(#"{"id":"old","name":"Followup","account":"one@example.test"}"#.utf8))
        XCTAssertEqual(legacy.effectiveScope, .allInboxes)
    }

    func testLabelVerificationRejectsAProfileSwitchAndAProviderRenameBeforeWriting() async throws {
        let commands = Container.shared.customCommands()
        let actions: [CommandAction] = [.init(tool: "label_message", detail: "Apply Followup",
            resolvedLabel: .init(id: "old-id", name: "Followup", account: "one@example.test")),
            .init(tool: "archive_message", detail: "Archive")]
        _ = await commands.save(keyword: "follow up", label: "", actions: actions)
        let command = try XCTUnwrap(commands.commands.first)
        commands.labelLoader = { _ in
            ProfileRuntime.install(.init(profileId: "other", isDefault: false, emails: []))
            return [.init(id: "one-label", name: "Followup", user: true)]
        }
        let tasks = ApplicationTasks(request: { _ in XCTFail("Profile switch must stop before model execution"); return [] })
        let job = try tasks.job(request: "follow up", commandID: command.id, origin: origin("A"), profile: nil)
        let switched = await tasks.run(job)
        XCTAssertEqual(switched.ok, false)
        ProfileRuntime.install(nil)
        commands.labelLoader = { _ in [.init(id: "one-label", name: "Followup", user: true)] }
        await provider.renameLabel()
        let next = ApplicationTasks(request: { _ in
            [["type": "function_call", "name": "label_message", "call_id": UUID().uuidString,
              "arguments": #"{"message_id":"B","account":"one@example.test"}"#]]
        })
        let other = try next.job(request: "follow up", commandID: command.id, origin: origin("B"), profile: nil)
        let result = await next.run(other)
        XCTAssertEqual(result.ok, false)
        XCTAssertTrue(result.text.contains("renamed"), result.text)
        let writes = await provider.writes()
        XCTAssertTrue(writes.isEmpty)
    }
}

private actor TaskMailProvider: HTTPDataTransport {
    private var html: String?
    func setHTML(_ value: String) { html = value }
    private var posted: [String] = []
    private var appliedLabels: [String] = []
    private var labelName = "Followup"
    func renameLabel() { labelName = "Other label" }
    func labelWrites() -> [String] { appliedLabels }
    private var shouldHold = false
    private var held: CheckedContinuation<Void, Never>?
    func pauseWrites() { shouldHold = true }
    func isWaiting() -> Bool { held != nil }
    func releaseWrite() { held?.resume(); held = nil }
    func writes() -> [String] { posted }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let account = (request.value(forHTTPHeaderField: "Authorization") ?? "").replacingOccurrences(of: "Bearer ", with: "")
        if url.path.hasSuffix("/labels") {
            let labelID = account.hasPrefix("two") ? "two-label" : "one-label"
            return (try JSONSerialization.data(withJSONObject: ["labels": [["id": labelID, "name": labelName, "type": "user"]]]),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let parts = url.path.split(separator: "/")
        let id = String(parts.last == "modify" ? parts.dropLast().last! : parts.last!)
        if request.httpMethod == "POST" {
            posted.append(id)
            let args = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            for label in args?["addLabelIds"] as? [String] ?? [] { appliedLabels.append(account + ":" + label) }
            if shouldHold {
                shouldHold = false
                await withCheckedContinuation { held = $0 }
                throw URLError(.cancelled)
            }
        }
        let messageID = id.replacingOccurrences(of: "thread-", with: "")
        var message: [String: Any] = ["id": messageID, "threadId": "thread-" + messageID, "labelIds": ["INBOX"]]
        if let html { message["payload"] = ["mimeType": "text/html", "body": ["data": Data(html.utf8).base64EncodedString()]] }
        let body: [String: Any] = url.path.contains("/threads/") ? ["id": id, "messages": [message]] : message
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
private struct TaskGrants: GoogleGrantStorage {
    func all() -> [GoogleAccountStore.Grant] {
        ["one@example.test", "two@example.test"].map { .init(email: $0, refreshToken: "fixture", scopes: ["https://www.googleapis.com/auth/gmail.modify"], grantedAt: Date(), isPrimary: $0.hasPrefix("one")) }
    }
    func save(_ grant: GoogleAccountStore.Grant) -> Bool { true }
    func remove(_ email: String) {}
    func removeAll() {}
}
@MainActor
private struct TaskTokens: GoogleTokenProvider {
    func token(for email: String?, requiredScopes: [String]) async -> Result<GoogleCredential.Token, GoogleCredential.Failure> {
        .success(.init(accessToken: email ?? "one@example.test", email: email ?? "one@example.test", scopes: requiredScopes))
    }
}
