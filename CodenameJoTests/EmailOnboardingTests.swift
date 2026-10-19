import Foundation
import XCTest
@testable import CodenameJo

private extension OnboardingMailPreference {
    /// The preference a queue result carries, if any.
    static func decode(from output: String) -> Self? {
        struct Result: Decodable { let mailPreference: OnboardingMailPreference? }
        return try? JSONDecoder().decode(Result.self, from: Data(output.utf8)).mailPreference
    }
}

final class EmailOnboardingTests: XCTestCase {
    func testMailPreferenceReceiptAndReconnectDecode() throws {
        let receipt = #"{"mailPreference":{"account":"first@example.test","draftsOnly":false},"onboarding":{"step":2}}"#
        let choice = try XCTUnwrap(OnboardingMailPreference.decode(from: receipt))
        XCTAssertEqual(choice.account, "first@example.test")
        XCTAssertEqual(choice.draftsOnly, false)
        let skip = try XCTUnwrap(OnboardingMailPreference.decode(from:
            #"{"mailPreference":{"account":"first@example.test"}}"#))
        XCTAssertNil(skip.draftsOnly)
        XCTAssertNil(OnboardingMailPreference.decode(from: "The preference could not be saved"))
        XCTAssertNil(OnboardingMailPreference.decode(from: #"{"onboarding":{"step":1}}"#))
        let flow = try JSONDecoder().decode(EmailOnboardingFlow.self, from: Data(
            #"{"version":1,"runId":"run","welcome":null,"mailPreference":{"account":"first@example.test","draftsOnly":true}}"#.utf8))
        XCTAssertEqual(flow.mailPreference?.draftsOnly, true)
        let old = try JSONDecoder().decode(EmailOnboardingFlow.self, from: Data(
            #"{"version":1,"runId":"run","welcome":null}"#.utf8))
        XCTAssertNil(old.mailPreference)
    }

    private func item(_ step: Int) -> EmailOnboardingItem {
        .init(account: "owner@example.test", id: "message-\(step)", threadId: "thread-\(step)",
              from: "Sender", subject: "Subject", date: "2026-09-07", snippet: "A message",
              internalDate: 1, onboardingStep: step, cleanup: nil)
    }

    private func configured(_ steps: [Int]) async -> LocalTriageQueue {
        let queue = LocalTriageQueue()
        let all = steps.map(item)
        let flow = EmailOnboardingFlow(version: 1, runId: UUID().uuidString,
                                      welcome: all.first { $0.onboardingStep == 1 })
        await queue.configure(coachingPlan: nil,
            forceOnboardingFeedLesson: false,
            sequentialFeed: false, calendarFeedDue: false, localCalendar: false,
            onboardingFlow: flow, onboardingLoader: { .init(items: all, failures: []) })
        return queue
    }

    private func stage(_ output: String) throws -> Int? {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        return (object["onboarding"] as? [String: Any])?["step"] as? Int
    }

    func testFiveStepsAndReconnectDoNotSkipOrRestart() async throws {
        let queue = await configured([1,2,3,4])
        let store = MailStore(database: nil, userId: "test-user")
        let first = await queue.openingStep(store: store)
        XCTAssertEqual(try stage(first.output), 1)
        let reconnect = await queue.openingStep(store: store)
        XCTAssertEqual(try stage(reconnect.output), 1)
        for expected in [2,3,4,5] {
            let next = await queue.step(.init(), store: store, dealtWith: false)
            XCTAssertEqual(try stage(next.output), expected)
            if expected == 5 {
                XCTAssertTrue(next.output.contains(EmailOnboardingContract.question))
                XCTAssertFalse(next.output.contains("calendarDue"))
                XCTAssertFalse(next.output.contains("interstitial"))
            }
        }
        await queue.end()
    }

    func testHangUpResumesAtTheUnfinishedStepUntilTheFinish() async throws {
        OnboardingResume.finish()
        defer { OnboardingResume.finish() }
        let all = [1,2,3,4].map(item)
        var flow = EmailOnboardingFlow(version: 1, runId: UUID().uuidString, welcome: all[0])
        let store = MailStore(database: nil, userId: "test-user")
        let dial = { (flow: EmailOnboardingFlow) async -> LocalTriageQueue in
            let queue = LocalTriageQueue()
            await queue.configure(coachingPlan: nil,
                forceOnboardingFeedLesson: false,
                sequentialFeed: false, calendarFeedDue: false, localCalendar: false,
                onboardingFlow: flow, onboardingLoader: { .init(items: all, failures: []) })
            return queue
        }
        OnboardingResume.begin(flow)
        let first = await dial(flow)
        _ = await first.openingStep(store: store)
        _ = await first.step(.init(), store: store, dealtWith: false)
        await first.end()
        XCTAssertEqual(OnboardingResume.runId, flow.runId)
        XCTAssertEqual(OnboardingResume.step, 2)

        flow.resume = true
        let second = await dial(flow)
        let resumed = await second.openingStep(store: store)
        XCTAssertEqual(try stage(resumed.output), 2)
        for expected in [3,4,5] {
            let next = await second.step(.init(), store: store, dealtWith: false)
            XCTAssertEqual(try stage(next.output), expected)
        }
        XCTAssertNil(OnboardingResume.runId)
        await second.end()
    }

    func testHangUpAfterTheNateDraftResumesOnTheMailModeQuestion() async throws {
        OnboardingResume.finish()
        defer { OnboardingResume.finish() }
        let all = [1,2,3,4].map(item)
        let flow = EmailOnboardingFlow(version: 1, runId: UUID().uuidString, welcome: all[0],
            mailModeChoice: .init(account: "owner@example.test", status: "welcome", mode: nil))
        let store = MailStore(database: nil, userId: "test-user")
        let dial = { (flow: EmailOnboardingFlow) async -> LocalTriageQueue in
            let queue = LocalTriageQueue()
            await queue.configure(coachingPlan: nil,
                forceOnboardingFeedLesson: false,
                sequentialFeed: false, calendarFeedDue: false, localCalendar: false,
                onboardingFlow: flow, onboardingLoader: { .init(items: all, failures: []) })
            return queue
        }
        OnboardingResume.begin(flow)
        let first = await dial(flow)
        let welcome = await first.openingStep(store: store)
        XCTAssertTrue(welcome.output.contains("to this exact thread"))
        // The draft landed on Nate's thread, so the question is on the floor when the call drops.
        let asked = await first.step(.init(), store: store, dealtWith: true)
        XCTAssertTrue(asked.output.contains("Going forward"))
        await first.end()
        XCTAssertEqual(OnboardingResume.flow?.mailModeChoice?.status, "pending")

        let resumed = try XCTUnwrap(LocalOnboardingRun.resumed())
        XCTAssertEqual(resumed.resume, true)
        let second = await dial(resumed)
        let opening = await second.openingStep(store: store)
        XCTAssertTrue(opening.output.contains("Going forward"), "the question again, not a second Nate draft")
        XCTAssertFalse(opening.output.contains("to this exact thread"))
        var choice = LocalTriageQueue.Input()
        choice.onboardingMailMode = "drafts"
        let saved = await second.step(choice, store: store, dealtWith: false)
        XCTAssertEqual(try stage(saved.output), 2)
        XCTAssertEqual(OnboardingResume.flow?.mailModeChoice?.status, "saved")
        await second.end()
    }

    private func script(_ output: String) throws -> String? {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        return object["script"] as? String
    }

    func testTheWelcomeAndMailModeStagesCarryTheirOwnLines() async throws {
        let config = try XCTUnwrap(LocalOnboardingRun.config())
        let flow = EmailOnboardingFlow(version: 2, runId: UUID().uuidString, welcome: item(1),
            mailModeChoice: .init(account: "owner@example.test", status: "welcome", mode: nil), config: config)
        let queue = LocalTriageQueue()
        await queue.configure(coachingPlan: nil,
            forceOnboardingFeedLesson: false, sequentialFeed: false, calendarFeedDue: false,
            localCalendar: false, onboardingFlow: flow, onboardingLoader: { .init(items: [], failures: []) })
        let store = MailStore(database: nil, userId: "test-user")
        let welcome = await queue.openingStep(store: store)
        XCTAssertEqual(try script(welcome.output), config.steps[0].line)
        XCTAssertTrue(welcome.output.contains("to this exact thread"), "the note still drives the draft")
        let question = await queue.step(.init(), store: store, dealtWith: true)
        XCTAssertEqual(try script(question.output),
                       [config.steps[0].receipt, config.mailModeQuestion].compactMap { $0 }.joined(separator: " "))
        XCTAssertEqual(config.steps[0].receipt, "Your reply is saved as a draft.")
        XCTAssertEqual(try stage(question.output), 1, "the question shares the welcome stage")
        await queue.end()
    }

    private func kind(_ output: String) throws -> String? {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        return (object["onboarding"] as? [String: Any])?["kind"] as? String
    }

    func testStagesNameTheirKindForThePhone() async throws {
        let config = try XCTUnwrap(LocalOnboardingRun.config())
        let flow = EmailOnboardingFlow(version: 2, runId: UUID().uuidString, welcome: item(1),
            mailModeChoice: .init(account: "owner@example.test", status: "welcome", mode: nil), config: config)
        let queue = LocalTriageQueue()
        await queue.configure(coachingPlan: nil,
            forceOnboardingFeedLesson: false, sequentialFeed: false, calendarFeedDue: false,
            localCalendar: false, onboardingFlow: flow, onboardingLoader: { .init(items: [], failures: []) })
        let store = MailStore(database: nil, userId: "test-user")
        let welcome = await queue.openingStep(store: store)
        XCTAssertEqual(try kind(welcome.output), "welcome")
        let question = await queue.step(.init(), store: store, dealtWith: true)
        XCTAssertEqual(try kind(question.output), "mail_mode")
        var choice = LocalTriageQueue.Input()
        choice.onboardingMailMode = "drafts"
        let finish = await queue.step(choice, store: store, dealtWith: false)
        XCTAssertEqual(try kind(finish.output), "finish")
        await queue.end()
    }

    func testTheMailModeAnswerIsReadOnThePhone() {
        XCTAssertEqual(EmailOnboardingContract.mailModeAnswer("You can send my emails."), "send")
        XCTAssertEqual(EmailOnboardingContract.mailModeAnswer("Keep them in drafts please"), "drafts")
        XCTAssertEqual(EmailOnboardingContract.mailModeAnswer("Just draft them."), "drafts")
        XCTAssertEqual(EmailOnboardingContract.mailModeAnswer("skip"), "skip")
        XCTAssertNil(EmailOnboardingContract.mailModeAnswer("Yes"), "a bare yes is the brain's to clarify")
        XCTAssertNil(EmailOnboardingContract.mailModeAnswer("Don't send them, keep drafts"), "both named")
        XCTAssertNil(EmailOnboardingContract.mailModeAnswer("No, not send"), "negated")
        XCTAssertNil(EmailOnboardingContract.mailModeAnswer("I'd rather you send them"), "hedged")
        XCTAssertNil(EmailOnboardingContract.mailModeAnswer("What does drafts mean?"))
    }

    func testTheComposedReplyIsKeptOnlyWhenItAnswersNate() throws {
        XCTAssertEqual(EmailOnboardingContract.parseReply(#"{"answers":true,"reply":" Hey Nate, it went really well. "}"#),
                       "Hey Nate, it went really well.")
        XCTAssertNil(EmailOnboardingContract.parseReply(#"{"answers":false,"reply":""}"#))
        XCTAssertNil(EmailOnboardingContract.parseReply(#"{"answers":false,"reply":"Hey Nate, skip this"}"#))
        XCTAssertNil(EmailOnboardingContract.parseReply(#"{"answers":true,"reply":"   "}"#))
        XCTAssertNil(EmailOnboardingContract.parseReply("not json"))
        let prompt = try EmailOnboardingContract.replyPrompt(question: "How did your onboarding go?")
        XCTAssertTrue(prompt.contains("\"How did your onboarding go?\""))
        XCTAssertTrue(prompt.contains("Return JSON"))
    }

    func testTheNateReplyIsSteeredOntoHisThreadAsADraft() throws {
        let welcome = EmailOnboardingItem(account: "owner@example.test", id: "welcome-id", threadId: "welcome-thread",
            from: "Nate from Codename Jo <nate@kiloforge.com>", subject: "don't type your reply", date: "2026-10-19",
            snippet: "How did your onboarding go?", internalDate: 1, onboardingStep: 1, cleanup: nil)
        func steered(_ arguments: String, onStage: Bool = true) throws -> [String: Any]? {
            try EmailOnboardingContract.welcomeReplyArguments(arguments, welcome: welcome, onWelcomeStage: onStage)
                .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        }
        // Unaddressed while the stage is up: this is the reply.
        let bare = try XCTUnwrap(steered(#"{"body":"Loved it.","user_request":"I loved it"}"#))
        XCTAssertEqual(bare["thread_id"] as? String, "welcome-thread")
        XCTAssertEqual(bare["account"] as? String, "owner@example.test")
        XCTAssertEqual(bare["body"] as? String, "Loved it.")
        // Addressed to Nate as new mail: onto the thread, without the address or subject.
        let addressed = try XCTUnwrap(steered(
            #"{"to":"Nate <nate@kiloforge.com>","subject":"Re: hi","body":"x","user_request":"x"}"#))
        XCTAssertEqual(addressed["thread_id"] as? String, "welcome-thread")
        XCTAssertNil(addressed["to"])
        XCTAssertNil(addressed["subject"])
        // The message id passed as the thread, with a selected message that is not on it.
        let byId = try XCTUnwrap(steered(
            #"{"thread_id":"welcome-id","reply_message_id":"elsewhere","body":"x","user_request":"x"}"#))
        XCTAssertEqual(byId["thread_id"] as? String, "welcome-thread")
        XCTAssertNil(byId["reply_message_id"])
        let selected = try XCTUnwrap(steered(
            #"{"thread_id":"welcome-thread","reply_message_id":"welcome-id","body":"x","user_request":"x"}"#))
        XCTAssertEqual(selected["reply_message_id"] as? String, "welcome-id")
        // A side request to someone else is left alone, as is an unaddressed write once the stage has moved on.
        XCTAssertNil(try steered(#"{"to":"josh@kiloforge.com","body":"x","user_request":"x"}"#))
        XCTAssertNil(try steered(#"{"to":"Josh","body":"x","user_request":"x"}"#))
        XCTAssertNil(try steered(#"{"to":"Nate","body":"x","user_request":"x"}"#),
                     "a name is not an address: the route refuses it and asks for the thread, as for anyone")
        XCTAssertNil(try steered(#"{"thread_id":"another-thread","body":"x","user_request":"x"}"#))
        XCTAssertNil(try steered(#"{"body":"x","user_request":"x"}"#, onStage: false))
        // Aimed at Nate after the stage has moved on, it is still a draft: that reply is never sent.
        XCTAssertNotNil(try steered(#"{"thread_id":"welcome-thread","body":"x","user_request":"x"}"#, onStage: false))
    }

    func testTheQueueSteersTheNateReplyOnlyWhileTheWelcomeStageIsUp() async throws {
        let all = [1,2,3,4].map(item)
        let flow = EmailOnboardingFlow(version: 1, runId: UUID().uuidString, welcome: all[0],
            mailModeChoice: .init(account: "owner@example.test", status: "welcome", mode: nil))
        let queue = LocalTriageQueue()
        await queue.configure(coachingPlan: nil,
            forceOnboardingFeedLesson: false,
            sequentialFeed: false, calendarFeedDue: false, localCalendar: false,
            onboardingFlow: flow, onboardingLoader: { .init(items: all, failures: []) })
        let store = MailStore(database: nil, userId: "test-user")
        _ = await queue.openingStep(store: store)
        let bare = #"{"body":"Loved it.","user_request":"I loved it"}"#
        let onStage = await queue.onboardingWelcomeReply(bare)
        XCTAssertTrue(onStage?.contains("thread-1") == true)
        _ = await queue.step(.init(), store: store, dealtWith: true)
        let afterQuestion = await queue.onboardingWelcomeReply(bare)
        XCTAssertNil(afterQuestion, "the question is up; an unaddressed write is not Nate's")
        let aimedAtNate = await queue.onboardingWelcomeReply(#"{"thread_id":"thread-1","body":"x","user_request":"x"}"#)
        XCTAssertNotNil(aimedAtNate)
        await queue.end()
    }

    func testMissingMailSkipsStraightToTip() async throws {
        let queue = await configured([])
        let first = await queue.openingStep(store: MailStore(database: nil, userId: "test-user"))
        XCTAssertEqual(try stage(first.output), 5)
        await queue.end()
    }

    func testMissingNateAndSecondImportantPreserveOrder() async throws {
        let queue = await configured([2,4])
        let store = MailStore(database: nil, userId: "test-user")
        let first = await queue.openingStep(store: store)
        let second = await queue.step(.init(), store: store, dealtWith: false)
        let last = await queue.step(.init(), store: store, dealtWith: false)
        XCTAssertEqual(try stage(first.output), 2)
        XCTAssertEqual(try stage(second.output), 4)
        XCTAssertEqual(try stage(last.output), 5)
        await queue.end()
    }

    func testCancelAndRepeatStartFresh() async throws {
        let queue = await configured([1,2,3,4])
        let store = MailStore(database: nil, userId: "test-user")
        _ = await queue.openingStep(store: store)
        _ = await queue.step(.init(), store: store, dealtWith: false)
        await queue.end()
        let flow = EmailOnboardingFlow(version: 1, runId: "new", welcome: item(1))
        await queue.configure(coachingPlan: nil,
            forceOnboardingFeedLesson: false,
            sequentialFeed: false, calendarFeedDue: false, localCalendar: false,
            onboardingFlow: flow, onboardingLoader: { .init(items: [], failures: []) })
        let first = await queue.openingStep(store: store)
        XCTAssertEqual(try stage(first.output), 1)
        await queue.end()
    }
    private actor PreferenceServer {
        var attempts = 0
        var failNext = true
        var draftsOnly = false
        func save(_ mode: String) throws -> OnboardingMailModeReceipt {
            attempts += 1
            if failNext { failNext = false; throw URLError(.timedOut) }
            return .init(note: "Got it, saved. You can change this anytime in Settings.",
                         mailPreference: .init(account: "owner@example.test", draftsOnly: mode == "skip" ? nil : draftsOnly))
        }
        func editInSettings() { draftsOnly = true }
    }

    func testLocalPreferenceHoldsOnFailureAndAdvancesOnceAfterReceipt() async throws {
        let queue = LocalTriageQueue()
        let server = PreferenceServer()
        let all = [1,2,3,4].map(item)
        let flow = EmailOnboardingFlow(version: 1, runId: "local-choice", welcome: all[0],
            mailModeChoice: .init(account: "owner@example.test", status: "welcome", mode: nil))
        await queue.configure(coachingPlan: nil,
            forceOnboardingFeedLesson: false,
            sequentialFeed: false, calendarFeedDue: false, localCalendar: false,
            onboardingFlow: flow, onboardingLoader: { .init(items: all, failures: []) },
            onboardingModeSaver: { try await server.save($0) })
        let store = MailStore(database: nil, userId: "test-user")
        let first = await queue.openingStep(store: store)
        XCTAssertEqual(try stage(first.output), 1)
        var choice = LocalTriageQueue.Input()
        choice.onboardingMailMode = "send"
        let premature = await queue.step(choice, store: store, dealtWith: false)
        XCTAssertNil(OnboardingMailPreference.decode(from: premature.output))
        let pending = await queue.step(.init(), store: store, dealtWith: false)
        XCTAssertTrue(pending.output.contains("Going forward"))
        let held = await queue.step(.init(), store: store, dealtWith: false)
        XCTAssertEqual(try stage(held.output), 1)
        choice.onboardingMailMode = "yes"
        _ = await queue.step(choice, store: store, dealtWith: false)
        let attemptsBefore = await server.attempts
        XCTAssertEqual(attemptsBefore, 0)
        choice.onboardingMailMode = "send"
        let failed = await queue.step(choice, store: store, dealtWith: false)
        XCTAssertTrue(failed.output.contains("couldn’t confirm"))
        XCTAssertNil(OnboardingMailPreference.decode(from: failed.output))
        let resumed = await queue.openingStep(store: store)
        XCTAssertTrue(resumed.output.contains("Going forward"))
        let saved = await queue.step(choice, store: store, dealtWith: false)
        XCTAssertEqual(try stage(saved.output), 2)
        XCTAssertEqual(OnboardingMailPreference.decode(from: saved.output)?.draftsOnly, false)
        XCTAssertFalse(saved.output.contains("Settings"), "Live already acknowledged the answer")
        await server.editInSettings()
        let duplicate = await queue.step(choice, store: store, dealtWith: false)
        XCTAssertEqual(try stage(duplicate.output), 2)
        XCTAssertEqual(OnboardingMailPreference.decode(from: duplicate.output)?.draftsOnly, true)
        let next = await queue.step(.init(), store: store, dealtWith: false)
        XCTAssertEqual(try stage(next.output), 3)
        await queue.end()
    }

    func testSavedPreferenceDescriptorDoesNotReplayNateOnFreshQueue() async throws {
        let queue = LocalTriageQueue()
        let all = [1,2,3,4].map(item)
        let flow = EmailOnboardingFlow(version: 1, runId: "saved-choice", welcome: all[0],
            mailPreference: .init(account: "owner@example.test", draftsOnly: false),
            mailModeChoice: .init(account: "owner@example.test", status: "saved", mode: "send"))
        await queue.configure(coachingPlan: nil,
            forceOnboardingFeedLesson: false,
            sequentialFeed: false, calendarFeedDue: false, localCalendar: false,
            onboardingFlow: flow, onboardingLoader: { .init(items: all, failures: []) })
        let result = await queue.openingStep(store: MailStore(database: nil, userId: "test-user"))
        XCTAssertEqual(try stage(result.output), 2)
        XCTAssertFalse(result.output.contains("Going forward"))
        await queue.end()
    }

    private actor TailGate {
        var release: CheckedContinuation<Void, Never>?
        var entered: CheckedContinuation<Void, Never>?
        var didEnter = false
        func wait() async {
            await withCheckedContinuation { continuation in
                release = continuation
                didEnter = true
                entered?.resume()
                entered = nil
            }
        }
        func waitForEntry() async {
            if didEnter { return }
            await withCheckedContinuation { entered = $0 }
        }
        func open() { release?.resume(); release = nil }
    }

    func testSavedReconnectDuringProfileSynchronizationAdvancesOnlyOnce() async throws {
        let queue = LocalTriageQueue()
        let gate = TailGate()
        let all = [1,2,3,4].map(item)
        let flow = EmailOnboardingFlow(version: 1, runId: "race", welcome: all[0],
            mailModeChoice: .init(account: "owner@example.test", status: "welcome", mode: nil))
        let receipt = OnboardingMailModeReceipt(note: "Saved. Change it in Settings.",
            mailPreference: .init(account: "owner@example.test", draftsOnly: false))
        await queue.configure(coachingPlan: nil,
            forceOnboardingFeedLesson: false,
            sequentialFeed: false, calendarFeedDue: false, localCalendar: false,
            onboardingFlow: flow, onboardingLoader: { .init(items: all, failures: []) },
            onboardingModeSaver: { _ in receipt }, onboardingPreferenceSaved: { _ in await gate.wait() })
        let store = MailStore(database: nil, userId: "test-user")
        _ = await queue.openingStep(store: store)
        _ = await queue.step(.init(), store: store, dealtWith: false)
        let saving = Task { await queue.step(.init(onboardingMailMode: "send"), store: store, dealtWith: false) }
        await gate.waitForEntry()
        let savedFlow = EmailOnboardingFlow(version: 1, runId: "race", welcome: all[0],
            mailPreference: receipt.mailPreference,
            mailModeChoice: .init(account: "owner@example.test", status: "saved", mode: "send"))
        await queue.configure(coachingPlan: nil,
            forceOnboardingFeedLesson: false,
            sequentialFeed: false, calendarFeedDue: false, localCalendar: false,
            onboardingFlow: savedFlow, onboardingModeSaver: { _ in receipt })
        let busyOpening = await queue.openingStep(store: store)
        XCTAssertTrue(busyOpening.output.contains("still being confirmed"))
        await gate.open()
        let saved = await saving.value
        XCTAssertEqual(try stage(saved.output), 2)
        let opening = await queue.openingStep(store: store)
        XCTAssertEqual(try stage(opening.output), 2)
        await queue.end()
    }

    private actor ReceiptSink {
        var values: [OnboardingMailPreference] = []
        func receive(_ preference: OnboardingMailPreference) { values.append(preference) }
    }

    func testEndingCallDuringSaveStillReconcilesPreferenceWithoutAdvancing() async throws {
        let queue = LocalTriageQueue()
        let gate = TailGate()
        let sink = ReceiptSink()
        let welcome = item(1)
        let flow = EmailOnboardingFlow(version: 1, runId: "ended-save", welcome: welcome,
            mailModeChoice: .init(account: "owner@example.test", status: "welcome", mode: nil))
        await queue.configure(coachingPlan: nil,
            forceOnboardingFeedLesson: false,
            sequentialFeed: false, calendarFeedDue: false, localCalendar: false,
            onboardingFlow: flow, onboardingLoader: { .init(items: [], failures: []) },
            onboardingModeSaver: { _ in
                await gate.wait()
                return .init(note: "Saved", mailPreference: .init(account: "owner@example.test", draftsOnly: false))
            }, onboardingPreferenceSaved: { await sink.receive($0) })
        let store = MailStore(database: nil, userId: "test-user")
        _ = await queue.openingStep(store: store)
        _ = await queue.step(.init(), store: store, dealtWith: false)
        let saving = Task { await queue.step(.init(onboardingMailMode: "send"), store: store, dealtWith: false) }
        await gate.waitForEntry()
        await queue.cancelOnboarding(runId: flow.runId)
        await gate.open()
        let result = await saving.value
        let receipts = await sink.values
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.draftsOnly, false)
        XCTAssertTrue(result.output.contains("stopped"))
        let progress = await queue.progress
        XCTAssertNil(progress)
    }

    func testTransientQueueRepliesKeepOnboardingIdentity() {
        XCTAssertFalse(EmailOnboardingContract.exitsOnboarding(#"{"note":"The inbox switch is still being confirmed. Retry this step."}"#))
        XCTAssertFalse(EmailOnboardingContract.exitsOnboarding(#"{"error":"unavailable"}"#))
        XCTAssertFalse(EmailOnboardingContract.exitsOnboarding(#"{"done":true,"onboarding":{"step":5}}"#))
        XCTAssertTrue(EmailOnboardingContract.exitsOnboarding(#"{"stopped":true}"#))
        XCTAssertTrue(EmailOnboardingContract.exitsOnboarding(#"{"done":true}"#))
        XCTAssertTrue(EmailOnboardingContract.exitsOnboarding(#"{"done":false,"item":{"id":"ordinary-mail"}}"#))
    }

    @MainActor func testV2FlowDecodesUnknownKinds() throws {
        let flow = try JSONDecoder().decode(EmailOnboardingFlow.self, from: Data(#"""
            {"version":2,"runId":"run","welcome":null,"config":{"opening":"Hi! Jo here.","steps":[
              {"id":"future","kind":"survey","whatever":1},
              {"id":"finish","kind":"finish","tip":"Tip.","question":"Keep going?"}]}}
            """#.utf8))
        XCTAssertEqual(flow.config?.steps.map(\.kind), ["survey", "finish"])
        XCTAssertTrue(flow.seededItems.isEmpty)
        XCTAssertEqual(FullDuplexVoiceClient.onboardingOpeningLine(address: " Sam", configured: "Hi! Jo here."), "Hi Sam! Jo here.")
        XCTAssertEqual(FullDuplexVoiceClient.onboardingOpeningLine(address: ""),
                       FullDuplexVoiceClient.onboardingOpeningLine(address: "", configured: nil))
    }

    func testV2WalksConfiguredOrderWithBeatAndEditedCopy() async throws {
        let config = try JSONDecoder().decode(EmailOnboardingConfig.self, from: Data(#"""
            {"opening":"Hi! Jo.","steps":[
              {"id":"hello","kind":"beat","say":"Two minutes, then you are done."},
              {"id":"welcome","kind":"welcome","line":"Nate wrote. Say word of mouth."},
              {"id":"important","kind":"important","query":"is:important","count":1,"note":"One line."},
              {"id":"finish","kind":"finish","tip":"That is the Feed.","question":"Keep going?"}]}
            """#.utf8))
        let welcome = item(2)
        var important = item(3)
        important = .init(account: important.account, id: "important", threadId: "important", from: "Sender",
                          subject: "Subject", date: "2026-09-07", snippet: "A message", internalDate: 1,
                          onboardingStep: 3, cleanup: nil)
        let flow = EmailOnboardingFlow(version: 2, runId: UUID().uuidString, welcome: welcome, config: config)
        let queue = LocalTriageQueue()
        await queue.configure(coachingPlan: nil,
            forceOnboardingFeedLesson: false, sequentialFeed: false, calendarFeedDue: false,
            localCalendar: false, onboardingFlow: flow,
            onboardingLoader: { [important] in .init(items: [important], failures: []) })
        let store = MailStore(database: nil, userId: "test-user")
        let opening = await queue.openingStep(store: store)
        let beat = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(opening.output.utf8)) as? [String: Any])
        XCTAssertNil(beat["item"], "a beat is never shown as mail")
        XCTAssertTrue((beat["note"] as? String)?.contains("Two minutes, then you are done.") == true)
        let founder = await queue.step(.init(), store: store, dealtWith: false)
        XCTAssertTrue(founder.output.contains("Nate wrote. Say word of mouth."))
        XCTAssertTrue(founder.output.contains("to this exact thread"))
        let mail = await queue.step(.init(), store: store, dealtWith: false)
        XCTAssertTrue(mail.output.contains("One line. Use the existing mail tools"))
        let finish = await queue.step(.init(), store: store, dealtWith: false)
        XCTAssertEqual(try stage(finish.output), 4)
        XCTAssertTrue(finish.output.contains("That is the Feed."))
        await queue.end()
    }

    private func aboutQueue(draft: Bool) async throws -> LocalTriageQueue {
        let config = try JSONDecoder().decode(EmailOnboardingConfig.self, from: Data(#"""
            {"opening":"Hi! Jo.","steps":[
              {"id":"welcome","kind":"welcome","line":"Nate wrote."},
              {"id":"about","kind":"about"},
              {"id":"finish","kind":"finish","tip":"That is the Feed.","question":"Keep going?"}]}
            """#.utf8))
        let flow = EmailOnboardingFlow(version: 2, runId: UUID().uuidString, welcome: item(1), config: config)
        let about = EmailOnboardingItem.about(id: "about", step: 2, account: "owner@example.test",
            about: .init(items: ["Plays chess on Chess.com", "Plays golf", "Shops at West Elm"],
                         spoken: ["Plays chess", "Plays golf", "Shops at West Elm"],
                         help: ["West Elm writes a lot; say 'Unsubscribe me from this sender' when one comes up."]))
        let queue = LocalTriageQueue()
        await queue.configure(coachingPlan: nil,
            forceOnboardingFeedLesson: false, sequentialFeed: false, calendarFeedDue: false,
            localCalendar: false, onboardingFlow: flow,
            onboardingLoader: { [about] in .init(items: draft ? [about] : [], failures: []) })
        return queue
    }

    func testAboutStepSaysWhatItCanDoAndAsksTheFinishQuestion() async throws {
        let queue = try await aboutQueue(draft: true)
        let store = MailStore(database: nil, userId: "test-user")
        _ = await queue.openingStep(store: store)
        let about = await queue.step(.init(), store: store, dealtWith: false)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(about.output.utf8)) as? [String: Any])
        XCTAssertNil(payload["item"], "the about step is never shown as mail")
        XCTAssertEqual((payload["about"] as? [String: Any])?["items"] as? [String],
                       ["Plays chess on Chess.com", "Plays golf", "Shops at West Elm"])
        XCTAssertTrue(about.output.contains("Plays chess; Plays golf; Shops at West Elm"))
        XCTAssertFalse(about.output.contains("saved"), "nothing about the user is kept, so nothing is offered for approval")
        XCTAssertEqual(try stage(about.output), 2)
        let script = try XCTUnwrap(payload["script"] as? String, "Live speaks it without a backend turn")
        XCTAssertTrue(script.contains("Unsubscribe me from this sender"))
        XCTAssertTrue(script.hasSuffix("Keep going?"))

        let next = await queue.step(.init(), store: store, dealtWith: false)
        XCTAssertFalse(next.output.contains("That is the Feed."), "the finish step is not spoken a second time")
        await queue.end()
    }

    func testMissingAboutDraftGoesStraightToFinish() async throws {
        let queue = try await aboutQueue(draft: false)
        let store = MailStore(database: nil, userId: "test-user")
        _ = await queue.openingStep(store: store)
        let finish = await queue.step(.init(), store: store, dealtWith: false)
        XCTAssertTrue(finish.output.contains("That is the Feed."))
        await queue.end()
    }

    func testTheBundledStepsAreTheShippedOnes() throws {
        let config = try XCTUnwrap(LocalOnboardingRun.config())
        XCTAssertEqual(config.steps.map(\.kind), ["welcome", "mail_mode", "about", "finish"])
        XCTAssertNotNil(config.mailModeQuestion)
    }

    func testASavedMailModeRidesTheRunSoAResumeSkipsTheQuestion() throws {
        OnboardingResume.finish()
        defer { OnboardingResume.finish() }
        let flow = EmailOnboardingFlow(version: 2, runId: "saved-locally", welcome: item(1),
            mailModeChoice: .init(account: "owner@example.test", status: "welcome", mode: nil))
        OnboardingResume.begin(flow)
        let receipt = try EmailOnboardingContract.saveMailMode(flow: flow, mode: "drafts")
        XCTAssertEqual(receipt.mailPreference.draftsOnly, true)
        XCTAssertTrue(receipt.note.contains("Drafts"))
        let resumed = try XCTUnwrap(LocalOnboardingRun.resumed())
        XCTAssertEqual(resumed.resume, true)
        XCTAssertEqual(resumed.mailModeChoice?.status, "saved")
        XCTAssertEqual(resumed.mailPreference?.draftsOnly, true)
        XCTAssertNil(try EmailOnboardingContract.saveMailMode(flow: flow, mode: "skip").mailPreference.draftsOnly)
        XCTAssertThrowsError(try EmailOnboardingContract.saveMailMode(flow: flow, mode: "yes"))
    }

    func testAnAboutDraftKeepsOnlyBoundedLinesAndKnownCapabilities() throws {
        let about = try XCTUnwrap(EmailOnboardingContract.parseAbout(#"""
            {"items":["You receive GitHub mail", "", "Chess.com appears"],"spoken":["GitHub mail"],
             "help":[{"tip":"unsubscribe","senders":["GitHub"],"line":"Say unsubscribe."},
                     {"tip":"invented","line":"No."},
                     {"tip":"unsubscribe","line":"Twice."},
                     {"tip":"dispatch","line":"Send me off."}]}
            """#))
        XCTAssertEqual(about.items, ["You receive GitHub mail", "Chess.com appears"])
        XCTAssertEqual(about.help, ["Say unsubscribe.", "Send me off."])
        XCTAssertNil(EmailOnboardingContract.parseAbout(#"{"items":[],"spoken":["x"]}"#))
        XCTAssertNil(EmailOnboardingContract.parseAbout("not json"))
    }

    func testTheWelcomeEmailThreadsOntoThePriorCopyAndAsksItsQuestion() throws {
        let copy = WelcomeEmail.Copy(founder: "founder@example.test", fromName: "Founder from Jo",
            subject: "a subject", question: "How did it go?", body: ["One question: {{question}}"])
        let raw = WelcomeEmail.raw(copy, to: "owner@example.test", date: Date(timeIntervalSince1970: 0),
                                   messageId: "<new@example.test>", replyTo: "<old@example.test>")
        let padded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - raw.count % 4) % 4)
        let text = try XCTUnwrap(Data(base64Encoded: padded).map { String(decoding: $0, as: UTF8.self) })
        XCTAssertTrue(text.contains("From: Founder from Jo <founder@example.test>\r\n"))
        XCTAssertTrue(text.contains("In-Reply-To: <old@example.test>"))
        XCTAssertTrue(text.contains("Date: Thu, 01 Jan 1970 00:00:00 GMT"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\nOne question: how did it go?"))
    }
}
