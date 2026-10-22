import XCTest

@testable import CodenameJo

/// The plan is chosen at mint and the phone walks it. These cover what that walk must never
/// do: repeat a lesson, or offer a rule the user has already switched on.
final class CoachingRotationTests: XCTestCase {

    private func lessons(_ capabilities: String...) -> [FullDuplexBroker.CoachingLesson] {
        capabilities.map { FullDuplexBroker.CoachingLesson(capability: $0, copy: "copy for \($0)") }
    }

    private let none: (String) -> Bool = { _ in false }

    func testTheCursorWalksForwardAndNeverWrapsToTheStart() {
        let plan = lessons("archive_after_reply", "dispatch", "feed_items")
        XCTAssertEqual(LocalTriageQueue.nextCoachingIndex(in: plan, from: 0, adopted: none), 0)
        XCTAssertEqual(LocalTriageQueue.nextCoachingIndex(in: plan, from: 1, adopted: none), 1)
        XCTAssertEqual(LocalTriageQueue.nextCoachingIndex(in: plan, from: 2, adopted: none), 2)
        // A spent plan is silent. Wrapping here is what served one tip repeatedly in a call.
        XCTAssertNil(LocalTriageQueue.nextCoachingIndex(in: plan, from: 3, adopted: none))
    }

    func testARuleSwitchedOnDuringTheCallIsSkipped() {
        let plan = lessons("archive_after_reply", "archive_after_forward", "dispatch")
        let adopted: (String) -> Bool = { $0 == "archive_after_reply" }
        XCTAssertEqual(LocalTriageQueue.nextCoachingIndex(in: plan, from: 0, adopted: adopted), 1)
    }

    func testAPlanOfOnlyAdoptedRulesOffersNothing() {
        let plan = lessons("archive_after_reply", "archive_after_label")
        XCTAssertNil(LocalTriageQueue.nextCoachingIndex(in: plan, from: 0, adopted: { _ in true }))
    }

    func testAdoptionIsReadFromTheStandingRuleTheCapabilityNames() {
        // The plan's capability strings are the rule ids, which is what lets the default
        // predicate answer from the switch the user just flipped.
        XCTAssertEqual(StandingRule.archiveAfterReply.rawValue, "archive_after_reply")
        XCTAssertEqual(StandingRule.archiveAfterForward.rawValue, "archive_after_forward")
        XCTAssertEqual(StandingRule.archiveAfterLabel.rawValue, "archive_after_label")
    }

    // MARK: - The phone's own rotation

    private func scratchDefaults() -> UserDefaults {
        let name = "CoachingRotationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private let catalog = ["feed", "dispatch", "feed_items", "multi_account_routing"]
        .map { CoachingRotation.Lesson(capability: $0, copy: "copy for \($0)") }

    func testTheBundledCatalogOpensOnTheFeedLesson() {
        XCTAssertEqual(CoachingRotation.catalog.first?.capability, "feed")
        XCTAssertNil(CoachingRotation.catalog.first { $0.capability == "session_recap" })
    }

    func testAPlanCarriesOnlyUnheardAvailableLessonsInCatalogOrder() {
        let defaults = scratchDefaults()
        CoachingRotation.recordOffer("dispatch", defaults: defaults)
        let plan = CoachingRotation.plan(.init(hasFeedItems: false), catalog: catalog, defaults: defaults)
        XCTAssertEqual(plan.lessons.map(\.capability), ["feed", "feed_items"],
                       "offered, unavailable and adopted lessons stay out")
        XCTAssertEqual(CoachingRotation.plan(.init(multipleInboxes: true, hasFeedItems: true),
                                             catalog: catalog, defaults: defaults).lessons.map(\.capability),
                       ["feed", "multi_account_routing"])
    }

    func testDisablingTipsRemovesBothRegularAndOnboardingLessonsWithoutDismissingThem() {
        let defaults = scratchDefaults()
        CoachingRotation.recordOffer("dispatch", defaults: defaults)
        defaults.set(false, forKey: JoTips.storageKey)
        let disabled = CoachingRotation.plan(.init(), catalog: catalog, defaults: defaults)
        XCTAssertTrue(disabled.lessons.isEmpty)
        XCTAssertNil(disabled.onboardingFeed)
        defaults.set(true, forKey: JoTips.storageKey)
        let enabled = CoachingRotation.plan(.init(), catalog: catalog, defaults: defaults)
        XCTAssertEqual(enabled.lessons.map(\.capability), ["feed", "feed_items"])
        XCTAssertEqual(enabled.onboardingFeed?.capability, "feed")
    }

    func testDisabledPlanCompletesFeedWithoutOfferingATip() async throws {
        let defaults = scratchDefaults()
        for enabled in [false, true] {
            defaults.set(enabled, forKey: JoTips.storageKey)
            let queue = LocalTriageQueue(mailAccounts: { [] })
            await queue.configure(coachingPlan: CoachingRotation.plan(.init(), catalog: catalog, defaults: defaults),
                localCoachingDelivery: true, forceOnboardingFeedLesson: true,
                sequentialFeed: true, calendarFeedDue: false, localCalendar: false)
            let output = await queue.terminalFeed(["done": true], trigger: "test")
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            XCTAssertEqual(payload["done"] as? Bool, true)
            XCTAssertEqual(payload["coaching"] != nil, enabled)
            XCTAssertNotNil(payload["feedNote"], "Closing the feed must still have its normal instructions")
            await queue.end()
        }
    }

    func testOnboardingKeepsTheFeedLessonUntilItIsDismissed() {
        let defaults = scratchDefaults()
        CoachingRotation.recordOffer("feed", defaults: defaults)
        XCTAssertEqual(CoachingRotation.plan(.init(), catalog: catalog, defaults: defaults).onboardingFeed?.capability, "feed")
        _ = CoachingRotation.run(argumentsJSON: #"{"action":"dismiss","capability":"feed","answer":"no","user_words":"stop"}"#,
                                 defaults: defaults)
        XCTAssertNil(CoachingRotation.plan(.init(), catalog: catalog, defaults: defaults).onboardingFeed)
    }

    func testARuleLessonEndsOnAnOfferAndNamesTheToolForYes() {
        let lesson = CoachingRotation.lesson(.init(capability: "archive_after_reply", copy: "Copy."))
        XCTAssertEqual(lesson.speech, "Quick tip: Copy. It is switched off at the moment. Want me to turn that on?")
        XCTAssertTrue(lesson.answerInstruction?.contains(#"call set_rule with rule "archive_after_reply" and enabled true"#) == true)
        let explanation = CoachingRotation.lesson(.init(capability: "dispatch", copy: "Copy."))
        XCTAssertEqual(explanation.speech, "Quick tip: Copy. Was that helpful?")
        XCTAssertTrue(explanation.answerInstruction?.contains("Yes or no is feedback only") == true)
    }

    func testFeedbackNeedsTheUsersWordsAndNeverDismisses() {
        let defaults = scratchDefaults()
        XCTAssertTrue(CoachingRotation.run(argumentsJSON: #"{"action":"feedback","capability":"dispatch"}"#, defaults: defaults).failed)
        XCTAssertTrue(CoachingRotation.run(argumentsJSON: #"{"action":"offer","capability":"dispatch"}"#, defaults: defaults).failed)
        let recorded = CoachingRotation.run(
            argumentsJSON: #"{"action":"feedback","capability":"dispatch","answer":"yes","user_words":"nice"}"#, defaults: defaults)
        XCTAssertFalse(recorded.failed)
        XCTAssertTrue(recorded.output.hasPrefix("Tip feedback recorded."))
        XCTAssertNil(defaults.stringArray(forKey: CoachingRotation.dismissedKey))
    }

    func testDismissalResumesThePendingFeed() {
        let defaults = scratchDefaults()
        let result = CoachingRotation.run(argumentsJSON: #"{"action":"dismiss","capability":"dispatch"}"#, defaults: defaults)
        XCTAssertFalse(result.failed)
        XCTAssertTrue(result.output.contains("receipt is never the end of the turn"))
        XCTAssertEqual(defaults.stringArray(forKey: CoachingRotation.dismissedKey), ["dispatch"])
        XCTAssertTrue(CoachingRotation.run(argumentsJSON: #"{"action":"dismiss","capability":"no_such_tip"}"#,
                                           defaults: defaults).failed)
    }

    func testAQueueStepNamesTheLessonItOffered() {
        let step = #"{"coaching":{"id":"a|b|1","delivery":"local_playback","lesson":{"capability":"dispatch"}}}"#
        XCTAssertEqual(CoachingRotation.offer(inQueueOutput: step)?.capability, "dispatch")
        XCTAssertEqual(CoachingRotation.offer(inQueueOutput: step)?.id, "a|b|1")
        XCTAssertNil(CoachingRotation.offer(inQueueOutput: #"{"coaching":{"id":"x","interactive":true}}"#))
    }
}
