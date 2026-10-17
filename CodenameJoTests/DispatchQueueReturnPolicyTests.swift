import XCTest
import GRDB
@testable import CodenameJo

@MainActor
final class DispatchQueueReturnPolicyTests: XCTestCase {
    func testTerminalFeedClearsTheStandingEmail() {
        XCTAssertEqual(LocalQueueStandingUpdate.forInterstitial("feed"), .clear)
    }

    func testTemporaryQueueInterstitialsPreserveTheStandingEmail() {
        XCTAssertEqual(LocalQueueStandingUpdate.forInterstitial("page"), .preserve)
        XCTAssertEqual(LocalQueueStandingUpdate.forInterstitial("coaching"), .preserve)
    }

    func testOrdinaryStepPublishesItsMessageEvenWhenAnOutcomeRidesIt() {
        XCTAssertEqual(LocalQueueStandingUpdate.forInterstitial(nil), .publish)
    }

    func testQueueOriginReportCannotExpireUnspoken() {
        XCTAssertFalse(DispatchReportDelivery.nextQuietBeat.mayExpireUnspoken)
        XCTAssertTrue(DispatchReportDelivery.standard.mayExpireUnspoken)
    }

    // MARK: - An answer is served on the message it was about

    func testReturnedAnswerHasACompleteDedicatedSpeakerBrief() throws {
        let substance = String(repeating: "The research found a useful fact. ", count: 40)
        let data = try JSONSerialization.data(withJSONObject: [
            "presentedForOutcome": true,
            "item": ["id": "original", "from": "Research Sender"],
            "dispatchOutcome": ["task": "Research the company", "outcome": substance],
        ])
        let step = String(decoding: data, as: UTF8.self)
        let presentation = try XCTUnwrap(DispatchAnswerPresentation(step: step))
        XCTAssertTrue(presentation.speakerBrief.contains(substance), "Do not truncate the answer to an email script's budget")
        XCTAssertTrue(presentation.speakerBrief.contains("Circling back"))
        XCTAssertTrue(presentation.speakerBrief.contains("Wait for the user"))
        XCTAssertTrue(presentation.speakerBrief.contains("Research Sender"))
        let inline = FullDuplexVoiceClient.renderLocalDispatchAdvance(stepOutput: step, done: false)
        XCTAssertTrue(inline.contains("returned answer's own feed item"))
        XCTAssertFalse(inline.contains("queue has ALREADY moved"))
        XCTAssertFalse(inline.contains("Say the job is going"))
        XCTAssertTrue(inline.contains("After their reply"))
    }

    func testOrdinaryEmailAndActionReceiptDoNotUseAnswerPresentation() {
        XCTAssertNil(DispatchAnswerPresentation(step: #"{"done":false,"item":{"id":"next"}}"#))
        XCTAssertNil(DispatchAnswerPresentation(step: #"{"dispatchOutcome":{"outcome":"Archived."},"item":{"id":"next"}}"#))
        XCTAssertNil(DispatchAnswerPresentation(step: #"{"presentedForOutcome":true,"item":{},"dispatchOutcome":{}}"#))
    }

    func testReportWaitsForForegroundTool() {
        var inFlight = false
        XCTAssertFalse(FullDuplexVoiceClient.reserveDispatchReportTurn(
            responseInFlight: &inFlight, userSpeaking: false, assistantAudible: false,
            foregroundToolPending: true))
        XCTAssertFalse(inFlight)
        XCTAssertTrue(FullDuplexVoiceClient.reserveDispatchReportTurn(
            responseInFlight: &inFlight, userSpeaking: false, assistantAudible: false,
            foregroundToolPending: false))
    }

    /// Requested speech is silent for a few seconds before Live plays it; a report there talks over it.
    func testReportWaitsForRequestedSpeechThatIsNotYetAudible() {
        var inFlight = false
        XCTAssertFalse(FullDuplexVoiceClient.reserveDispatchReportTurn(
            responseInFlight: &inFlight, userSpeaking: false, assistantAudible: false,
            foregroundToolPending: false, speechRequested: true))
        XCTAssertFalse(inFlight)
    }

    func testIndependentAnswerRidesTheNextEmailWithoutPresentingOne() async throws {
        let (store, directory) = try makeStore()
        defer {
            try? store.database?.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let queue = LocalTriageQueue()
        await queue.adopt([message("first"), message("second"), message("third")], store: store)
        _ = await queue.step(.init(direction: "next"), store: store, dealtWith: false)
        var answer = LocalTriageQueue.Outcome(
            jobId: UUID(), task: "Is there a Giants game today?",
            text: "No, the Giants don't play today.", ok: nil, expects: .answer, about: nil)
        answer.independent = true
        let held = await queue.hold(answer)
        XCTAssertTrue(held)

        let next = await queue.step(.init(direction: "next"), store: store)
        XCTAssertNil(DispatchAnswerPresentation(step: next.output))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(next.output.utf8)) as? [String: Any])
        XCTAssertEqual((payload["item"] as? [String: Any])?["id"] as? String, "third")
        let note = try XCTUnwrap(payload["dispatchOutcomeNote"] as? String)
        XCTAssertTrue(note.contains("unrelated to their email"))
        XCTAssertFalse(note.contains("background research you asked me to do on"))
        let delivered = await queue.takeServedOutcomes()
        XCTAssertEqual(delivered, [answer.jobId])
    }

    func testStoppedQueueNamesAnUnrelatedAnswerAsUnrelated() async throws {
        let (store, directory) = try makeStore()
        defer {
            try? store.database?.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let queue = LocalTriageQueue()
        await queue.adopt([message("first"), message("second")], store: store)
        var answer = LocalTriageQueue.Outcome(
            jobId: UUID(), task: "Weather in San Francisco?",
            text: "69 and cloudy.", ok: nil, expects: .answer, about: nil)
        answer.independent = true
        let held = await queue.hold(answer)
        XCTAssertTrue(held)
        let stopped = await queue.step(.init(stop: true), store: store)
        XCTAssertTrue(stopped.output.contains("unrelatedToMail"))
        XCTAssertTrue(stopped.output.contains("69 and cloudy."))
    }

    /// A result spoken into the silence after "what's the feedback?" loses the capture.
    func testReportWaitsWhileTheUserOwesAnAnswer() {
        var inFlight = false
        XCTAssertFalse(FullDuplexVoiceClient.reserveDispatchReportTurn(
            responseInFlight: &inFlight, userSpeaking: false, assistantAudible: false,
            foregroundToolPending: false, answerPending: true))
        XCTAssertFalse(inFlight)
        XCTAssertTrue(LiveSessionAdapter.endsOnQuestion("Yes, what's the feedback?"))
        XCTAssertFalse(LiveSessionAdapter.endsOnQuestion("Hmm, you'd like a brief confirmation."))
    }

    func testAnswerHoldIsBoundedSoTheResultIsStillSpoken() {
        let now = ContinuousClock.now
        func holds(owed: Bool = true, answering: Bool, asked: Duration, held: Duration?) -> Bool {
            FullDuplexVoiceClient.holdsReportForAnswer(
                answerOwed: owed, userAnswering: answering, askedAt: now - asked,
                heldSince: held.map { now - $0 }, now: now)
        }
        XCTAssertFalse(holds(owed: false, answering: false, asked: .zero, held: nil))
        XCTAssertTrue(holds(answering: false, asked: .seconds(2), held: nil))
        // Nobody started answering: the user may simply be waiting for the result.
        XCTAssertFalse(holds(answering: false, asked: FullDuplexVoiceClient.silentAnswerLimit, held: .seconds(2)))
        // A capture under way keeps holding, but not past the overall limit.
        XCTAssertTrue(holds(answering: true, asked: .seconds(60), held: .seconds(60)))
        XCTAssertFalse(holds(answering: true, asked: .seconds(5), held: FullDuplexVoiceClient.answerHoldLimit))
        XCTAssertTrue(FullDuplexVoiceClient.unansweredQuestionNote.contains("ask that same question again and wait"))
    }

    func testRapidReportArrivalsReserveOnlyOneResponseUntilItFinishes() {
        var inFlight = false
        XCTAssertTrue(FullDuplexVoiceClient.reserveDispatchReportTurn(
            responseInFlight: &inFlight, userSpeaking: false, assistantAudible: false,
            foregroundToolPending: false))
        XCTAssertFalse(FullDuplexVoiceClient.reserveDispatchReportTurn(
            responseInFlight: &inFlight, userSpeaking: false, assistantAudible: false,
            foregroundToolPending: false))
        inFlight = false // response.done or response.cancelled
        XCTAssertTrue(FullDuplexVoiceClient.reserveDispatchReportTurn(
            responseInFlight: &inFlight, userSpeaking: false, assistantAudible: false,
            foregroundToolPending: false))
    }

    /// #989: a failure spoken at the first quiet beat landed on top of Jo's next question.
    func testFailedActionRidesTheNextStepWithoutReplacingOrAdvancingCurrentEmail() async throws {
        let (store, directory) = try makeStore()
        defer {
            try? store.database?.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let queue = LocalTriageQueue()
        await queue.adopt([message("original"), message("current"), message("next")], store: store)
        _ = await queue.step(.init(direction: "next"), store: store, dealtWith: false)
        let failed = LocalTriageQueue.Outcome(
            jobId: UUID(), task: "Forward the original to Josh and Huckleberry Finn",
            text: "No matching address for Huckleberry Finn. Nothing was sent or drafted.",
            ok: false, expects: .receipt, about: referent(id: "original"))

        let held = await queue.hold(failed)
        XCTAssertTrue(held, "A failure waits for the next step like any other outcome")
        let current = await queue.currentId
        XCTAssertEqual(current, "current")

        let step = await queue.step(.init(direction: "next"), store: store, dealtWith: false)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(step.output.utf8)) as? [String: Any])
        let rider = try XCTUnwrap(payload["dispatchOutcome"] as? [String: Any])
        XCTAssertEqual(rider["unresolved"] as? Bool, true)
        XCTAssertEqual((payload["item"] as? [String: Any])?["id"] as? String, "next")
        let released = await queue.release(jobId: failed.jobId)
        XCTAssertNil(released, "A served failure must not be spoken again by the watchdog")
    }

    func testFailedDispatchContextKeepsOriginalTargetAndClarificationAfterQueueContext() {
        let report = FullDuplexVoiceClient.renderFailedDispatchReport(
            task: "Forward original-id in original@example.com to Josh and Huckleberry Finn; draft only",
            result: "Josh is josh@example.com. Huckleberry Finn has no matching address.",
            standingStep: "current-id in current@example.com. Ask what to do with this email.")
        XCTAssertTrue(report.contains("original-id in original@example.com"))
        XCTAssertTrue(report.contains("draft only"))
        XCTAssertTrue(report.contains("josh@example.com"))
        let current = report.range(of: "current-id")!
        let clarification = report.range(of: "ask one concrete clarification question and WAIT")!
        XCTAssertLessThan(current.lowerBound, clarification.lowerBound)
        XCTAssertTrue(report.contains("Do not advance the queue while clarifying"))
        XCTAssertTrue(report.contains("permission, network, or service failure"))
        XCTAssertFalse(report.contains("is finished"))
    }

    func testAnUncrossedFailureReportIsUnchanged() {
        let plain = FullDuplexVoiceClient.renderFailedDispatchReport(
            task: "task", result: "result", standingStep: "standing")
        let explicitlyUncrossed = FullDuplexVoiceClient.renderFailedDispatchReport(
            task: "task", result: "result", standingStep: "standing", crossedFrom: nil, into: "Work")
        XCTAssertEqual(plain, explicitlyUncrossed)
        XCTAssertTrue(plain.contains("finish only the unresolved action with live tools"))
    }

    func testACrossedFailureNamesTheOriginAndRefusesToFinishItHere() {
        let report = FullDuplexVoiceClient.renderFailedDispatchReport(
            task: "Read original-id in original@example.com in full",
            result: "The message could not be fetched.",
            standingStep: "current-id in current@example.com. Ask what to do with this email.",
            crossedFrom: "Personal", into: "Work")
        XCTAssertTrue(report.contains("Personal"))
        XCTAssertTrue(report.contains("Work"))
        // A retry here would run against the profile the call has moved to.
        XCTAssertFalse(report.contains("finish only the unresolved action with live tools"))
        XCTAssertFalse(report.contains("ask one concrete clarification question and WAIT"))
        XCTAssertTrue(report.contains("switching back to Personal"))
        let queueContext = report.range(of: "current-id")!
        XCTAssertTrue(report.contains("the Personal profile"))
        let crossing = report.range(of: "This job was started in the Personal profile")!
        XCTAssertLessThan(queueContext.lowerBound, crossing.lowerBound)
    }

    func testACrossedAnswerNamesOnlyItsOriginAndAddsNoSecondQuestion() {
        let note = FullDuplexVoiceClient.renderCrossProfileDispatchNote(from: "Work")
        XCTAssertTrue(note.contains("from the Work profile"))
        XCTAssertTrue(note.contains("\"from your Work profile\""))
        XCTAssertTrue(note.contains("is a name"))
        // The note goes last, so it has to carry the delivery requirement itself:
        // attributing an answer instead of giving it is the failure it can cause.
        XCTAssertTrue(note.contains("Give them the answer itself, in this turn, in full."))
        XCTAssertTrue(note.contains("none of it replaces saying it"))
        // The queue's own question is the turn's only one: a finished answer has
        // nothing to go back for, and the destination is where they just put themselves.
        XCTAssertTrue(note.contains("do not offer to switch back"))
        XCTAssertTrue(note.contains("do not ask a second question"))
        XCTAssertTrue(note.contains("do not tell them where they are"))
        XCTAssertFalse(note.contains("moved past"))
    }

    func testAProfileIsOnlyCrossedWhenTheCallHasMovedOn() {
        let personal = WorkspaceProfile(id: "personal", name: "Personal", isDefault: true, createdAt: "")
        XCTAssertNil(FullDuplexVoiceClient.crossedProfile(origin: personal, current: "personal"))
        XCTAssertNil(FullDuplexVoiceClient.crossedProfile(origin: nil, current: "work"))
        XCTAssertNil(FullDuplexVoiceClient.crossedProfile(origin: personal, current: nil))
        XCTAssertEqual(FullDuplexVoiceClient.crossedProfile(origin: personal, current: "work"), "Personal")
    }

    /// The pair `presents` tests for, and the two that must fail it.
    ///
    /// A receipt really was dealt with by the handoff — that is what the advance has meant
    /// since 2026-08-13 — and an answer with no referent is a lookup with no mail behind it,
    /// which has nothing to present. The broker's `outcomePresents` is the same test.
    func testOnlyAnAnswerWithAReferentIsServedOnItsOwnMessage() {
        XCTAssertTrue(outcome(.answer, about: referent()).presents)
        XCTAssertFalse(outcome(.answer, about: nil).presents)
        XCTAssertFalse(outcome(.receipt, about: referent()).presents)
    }

    /// **`nil` still reads as an answer, and an empty id still does not present.** The first
    /// is the 2026-09-01 asymmetry — a compressed answer is lost silently, so absent means
    /// say too much. The second is this change's own edge: a referent that failed to build
    /// must fall back to the rider rather than present a message with no id, which is a step
    /// the model cannot act on.
    func testAbsentShapeIsAnAnswerAndAnEmptyReferentDoesNotPresent() {
        XCTAssertEqual(outcome(nil, about: referent()).shape, .answer)
        XCTAssertTrue(outcome(nil, about: referent()).presents)
        XCTAssertFalse(outcome(.answer, about: referent(id: "")).presents)
    }

    /// A presentation carries no `interstitial`, so it publishes the card like an ordinary
    /// step — which is the point. The email being talked about is the one that should be on
    /// screen, and drawing the cursor's message while the answer was about another was the
    /// visible half of the 2026-09-02 report.
    func testAPresentedAnswerPublishesItsOwnMessageToTheCard() {
        XCTAssertEqual(LocalQueueStandingUpdate.forInterstitial(nil), .publish)
    }

    /// Reproduces the phone run from 2026-09-07: an answer for message one arrives while an
    /// action on message two is trying to advance. The answer takes the turn; acting on its
    /// older email must then release the suspended advance and land on message three.
    func testActionOnPresentedOutcomeResumesTheHeldQueueAdvance() async throws {
        let (store, directory) = try makeStore()
        defer {
            try? store.database?.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let queue = LocalTriageQueue()
        await queue.adopt([
            message("rejuvenation", thread: "rejuvenation-thread"),
            message("pottery"),
            message("roku"),
        ], store: store)

        // The research handoff moved on without dealing with Rejuvenation.
        _ = await queue.step(.init(direction: "next"), store: store, dealtWith: false)
        let afterResearch = await queue.currentId
        XCTAssertEqual(afterResearch, "pottery")
        let held = await queue.hold(outcome(
            .answer, about: referent(id: "rejuvenation", thread: "rejuvenation-thread")))
        XCTAssertTrue(held)

        // Pottery's action earned an advance, but the landed research answer takes that turn.
        await queue.markActed(id: "pottery", as: "dispatched")
        let presented = await queue.step(.init(direction: "next"), store: store)
        XCTAssertTrue(presented.output.contains("\"presentedForOutcome\":true"))
        let presentation = try XCTUnwrap(DispatchAnswerPresentation(step: presented.output))
        XCTAssertEqual(presentation.item["id"] as? String, "rejuvenation")
        XCTAssertFalse(presentation.speakerBrief.contains("roku"))
        let followup = await queue.dispatchAnswerAbout
        XCTAssertEqual(followup?.id, "rejuvenation", "A follow-up must not capture Pottery's suspended cursor")
        let afterPresentation = await queue.currentId
        XCTAssertEqual(afterPresentation, "pottery")

        // A draft names only the thread. Resolving it returns the live cursor to advance.
        let resolution = await queue.resolveActionOutcome(
            id: nil, threadId: "rejuvenation-thread", as: "create_draft")
        XCTAssertEqual(resolution?.cursorId, "pottery")
        XCTAssertEqual(resolution?.dealtWith, true)
        let resumed = await queue.step(
            .init(), store: store, dealtWith: resolution?.dealtWith ?? true)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(resumed.output.utf8)) as? [String: Any])
        XCTAssertEqual((payload["item"] as? [String: Any])?["id"] as? String, "roku")
        let afterResume = await queue.currentId
        XCTAssertEqual(afterResume, "roku")
        let afterResumeTarget = await queue.dispatchAnswerAbout
        XCTAssertEqual(afterResumeTarget?.id, "roku")
        let consumed = await queue.takeServedOutcomes()
        XCTAssertEqual(consumed.count, 1, "The return is consumed once, including after resuming")
    }

    func testNextAfterReturnedAnswerResumesWithoutReplayingIt() async throws {
        let (store, directory) = try makeStore()
        defer {
            try? store.database?.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let queue = LocalTriageQueue()
        await queue.adopt([message("original"), message("current"), message("next")], store: store)
        _ = await queue.step(.init(direction: "next"), store: store, dealtWith: false)
        let held = await queue.hold(outcome(.answer, about: referent(id: "original")))
        XCTAssertTrue(held)
        let returned = await queue.step(.init(direction: "next"), store: store)
        XCTAssertNotNil(DispatchAnswerPresentation(step: returned.output))
        let whilePresented = await queue.currentId
        XCTAssertEqual(whilePresented, "current")
        let resumed = await queue.step(.init(direction: "next"), store: store)
        XCTAssertNil(DispatchAnswerPresentation(step: resumed.output))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(resumed.output.utf8)) as? [String: Any])
        XCTAssertEqual((payload["item"] as? [String: Any])?["id"] as? String, "next")
        XCTAssertNil(payload["dispatchOutcome"])
        let delivered = await queue.takeServedOutcomes()
        XCTAssertEqual(delivered.count, 1)
    }

    /// The suspended step remembers whether it came from an answer-shaped dispatch. Resuming
    /// that path must not convert "research this" into a read/dealt decision on the cursor.
    func testPresentedOutcomeResumePreservesAnswerDispatchDisposition() async throws {
        let (store, directory) = try makeStore()
        defer {
            try? store.database?.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let queue = LocalTriageQueue()
        await queue.adopt([
            message("first", thread: "first-thread"),
            message("second"),
            message("third"),
        ], store: store)
        _ = await queue.step(.init(direction: "next"), store: store, dealtWith: false)
        _ = await queue.hold(outcome(
            .answer, about: referent(id: "first", thread: "first-thread")))

        _ = await queue.step(.init(direction: "next"), store: store, dealtWith: false)
        let resolution = await queue.resolveActionOutcome(
            id: "first", threadId: nil, as: "archive_message")
        XCTAssertEqual(resolution?.dealtWith, false)
        _ = await queue.step(
            .init(), store: store, dealtWith: resolution?.dealtWith ?? true)
        let dealtWith = await queue.dealtWith
        XCTAssertFalse(dealtWith.contains("second"))
    }

    func testStandaloneDraftCanResolvePresentedOutcomeFromExplicitReferent() async throws {
        let (store, directory) = try makeStore()
        defer {
            try? store.database?.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let queue = LocalTriageQueue()
        await queue.adopt([
            message("researched", thread: "researched-thread"),
            message("cursor"),
            message("next"),
        ], store: store)
        _ = await queue.step(.init(direction: "next"), store: store, dealtWith: false)
        _ = await queue.hold(outcome(
            .answer, about: referent(id: "researched", thread: "researched-thread")))
        await queue.markActed(id: "cursor", as: "archived")
        _ = await queue.step(.init(direction: "next"), store: store)

        let unresolved = await queue.resolveActionOutcome(
            id: nil, threadId: nil, as: "create_draft")
        XCTAssertNil(unresolved, "A nameless unrelated draft must not move the queue")
        let resolved = await queue.resolveActionOutcome(
            id: nil, threadId: nil, allowUnscoped: true, as: "create_draft")
        XCTAssertEqual(resolved?.cursorId, "cursor")
    }

    func testOnlyReferentialDraftLanguageCanUsePresentedOutcomeFallback() {
        XCTAssertTrue(FullDuplexVoiceClient.refersToPresentedOutcome(
            "Create a draft to my work email to check out this survey company."))
        XCTAssertTrue(FullDuplexVoiceClient.refersToPresentedOutcome(
            "Forward it to my mom."))
        XCTAssertFalse(FullDuplexVoiceClient.refersToPresentedOutcome(
            "Draft Alex an email about lunch tomorrow."))
        XCTAssertFalse(FullDuplexVoiceClient.refersToPresentedOutcome(
            "Draft Alex about lunch; it's alex@example.com."))
    }

    private func referent(
        id: String = "msg-3", thread: String = "thr-3"
    ) -> LocalTriageQueue.Outcome.About {
        LocalTriageQueue.Outcome.About(
            account: "me@example.com", id: id, threadId: thread,
            from: "Dana Okafor <dana@northwind.example>", subject: "Northwind contract")
    }

    private func outcome(
        _ expects: LocalTriageQueue.Outcome.Shape?,
        about: LocalTriageQueue.Outcome.About?
    ) -> LocalTriageQueue.Outcome {
        LocalTriageQueue.Outcome(
            jobId: UUID(), task: "Read the resume attached and say who this is",
            text: "Six years in finance, an MBA, asking for a call next week.",
            ok: nil, expects: expects, about: about)
    }

    private func message(_ id: String, thread: String? = nil) -> MailStore.Message {
        MailStore.Message(
            user_id: "test-user", id: id, account: "me@example.com", threadId: thread ?? "\(id)-thread",
            sender: "Sender", recipient: nil, subject: id, snippet: "",
            internalDate: 1, cachedAt: Date(timeIntervalSince1970: 1))
    }

    private func makeStore() throws -> (MailStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try DatabasePool(path: directory.appendingPathComponent("test.sqlite").path)
        try database.write { db in
            try MailStore.createUserScopedSchema(db)
            try DailyEmailQueueSnapshotRecord.createSchema(db)
            try DailyEmailQueueSnapshotRecord.addOwner(db)
        }
        return (MailStore(database: database, userId: "test-user"), directory)
    }
}
