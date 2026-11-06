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

    func testQuietSuccessHasNoReturnedItemOrSpeechAndPersistsPreference() async throws {
        let tasks = ApplicationTasks(request: { _ in self.answer("Done") })
        let job = try tasks.job(request: "Research A", commandID: nil, origin: origin("A"), profile: nil, preference: .quiet)
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
        let job = try tasks.job(request: "Find a time", commandID: nil, origin: origin("A"), profile: nil, preference: .quiet)
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
