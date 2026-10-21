import XCTest
import FactoryKit
@testable import CodenameJo

final class FeedProfileHandoffTests: XCTestCase {
    private let personal = WorkspaceProfile(id: "p", name: "Personal", isDefault: true, createdAt: "")
    private let work = WorkspaceProfile(id: "w", name: "Work", isDefault: false, createdAt: "")
    private let other = WorkspaceProfile(id: "o", name: "Other", isDefault: false, createdAt: "")

    func testWalkOffersEachUnvisitedProfileWithoutLooping() {
        var handoff = FeedProfileHandoff()
        let all = [personal, work, other]
        handoff.configure(current: personal, profiles: all, enabled: true)
        XCTAssertEqual(handoff.takeNext(), work)
        handoff.configure(current: work, profiles: all, enabled: true)
        XCTAssertEqual(handoff.takeNext(), other)
        handoff.configure(current: other, profiles: all, enabled: true)
        XCTAssertTrue(handoff.canCompleteCurrent)
        XCTAssertNil(handoff.takeNext())
        XCTAssertFalse(handoff.canCompleteCurrent)
    }

    func testRestartOrDeclineDoesNotRepeatAnOffer() {
        var handoff = FeedProfileHandoff()
        handoff.configure(current: personal, profiles: [personal, work], enabled: true)
        XCTAssertEqual(handoff.takeNext(), work)
        XCTAssertNil(handoff.takeNext())
        handoff.configure(current: personal, profiles: [personal, work], enabled: true)
        XCTAssertNil(handoff.takeNext())
    }

    func testDisabledSwitchingSingleProfileAndMissingSelectionOfferNothing() {
        var handoff = FeedProfileHandoff()
        handoff.configure(current: personal, profiles: [personal, work], enabled: false)
        XCTAssertNil(handoff.takeNext())
        handoff.configure(current: personal, profiles: [personal], enabled: true)
        XCTAssertNil(handoff.takeNext())
        handoff.configure(current: nil, profiles: [personal, work], enabled: true)
        XCTAssertNil(handoff.takeNext())
    }

    func testManualSwitchSkipsProfilesAlreadyVisited() {
        var handoff = FeedProfileHandoff()
        let all = [personal, work, other]
        handoff.configure(current: work, profiles: all, enabled: true)
        handoff.configure(current: personal, profiles: all, enabled: true)
        XCTAssertEqual(handoff.takeNext(), other)
    }

    func testNewCallStartsFreshAndUsesUpdatedCatalog() {
        var handoff = FeedProfileHandoff()
        handoff.configure(current: personal, profiles: [personal, work], enabled: true)
        XCTAssertEqual(handoff.takeNext(), work)
        handoff = FeedProfileHandoff()
        handoff.configure(current: personal, profiles: [personal, other], enabled: true)
        XCTAssertEqual(handoff.takeNext(), other)
    }

    func testRenamingVisitedProfileDoesNotOfferItAgain() {
        var handoff = FeedProfileHandoff()
        handoff.configure(current: work, profiles: [personal, work], enabled: true)
        let renamed = WorkspaceProfile(id: work.id, name: "Renamed", isDefault: false, createdAt: "")
        handoff.configure(current: personal, profiles: [personal, renamed, other], enabled: true)
        XCTAssertEqual(handoff.takeNext(), other)
    }
    func testProfileCompletionPreservesCallStageConsumptionAndFinalWrapUp() async throws {
        let queue = LocalTriageQueue(mailAccounts: { [] })
        await queue.configure(coachingPlan: .init(lessons: []),
            forceOnboardingFeedLesson: false, sequentialFeed: true,
            calendarFeedDue: true, localCalendar: false)
        let all = [personal, work, other]
        await queue.configureProfileHandoff(current: personal, profiles: all, enabled: true, newCall: true)
        let first = await queue.terminalFeed(["done": true], trigger: "test")
        let firstPayload = try payload(first)
        XCTAssertEqual(firstPayload["nextProfile"] as? String, "Work")
        XCTAssertEqual(firstPayload["calendarDue"] as? Bool, true)
        await queue.end()
        await queue.configureProfileHandoff(current: work, profiles: all, enabled: true)
        _ = await queue.openingStep(store: MailStore(database: nil, userId: "test-user"))
        let repeatsStages = await queue.beginPageFeed()
        XCTAssertFalse(repeatsStages, "A page in Work must not repeat Personal's terminal stages")
        let second = await queue.terminalFeed(["done": true], trigger: "test")
        let secondPayload = try payload(second)
        XCTAssertEqual(secondPayload["nextProfile"] as? String, "Other")
        XCTAssertEqual(secondPayload["calendarDue"] as? Bool, false)
        XCTAssertNil(secondPayload["coaching"])
        await queue.configureProfileHandoff(current: other, profiles: all, enabled: true)
        let last = await queue.terminalFeed(["done": true], trigger: "test")
        let lastPayload = try payload(last)
        XCTAssertEqual(lastPayload["interstitial"] as? String, "feed")
        XCTAssertNil(lastPayload["nextProfile"])
        XCTAssertEqual(lastPayload["calendarDue"] as? Bool, false)
        await queue.configureProfileHandoff(current: personal, profiles: all, enabled: true)
        let repeated = await queue.terminalFeed(["done": true], trigger: "test")
        XCTAssertNil(try payload(repeated)["interstitial"])
        await queue.end()
    }

    func testCatalogUpdateUsesRenamedDestinationWithoutResettingCompletion() async throws {
        let queue = LocalTriageQueue(mailAccounts: { [] })
        await queue.configure(coachingPlan: .init(lessons: []),
            forceOnboardingFeedLesson: false, sequentialFeed: true,
            calendarFeedDue: false, localCalendar: false)
        await queue.configureProfileHandoff(current: personal, profiles: [personal, work], enabled: true, newCall: true)
        let renamed = WorkspaceProfile(id: work.id, name: "Business", isDefault: false, createdAt: "")
        await queue.updateProfileCatalog(current: personal, profiles: [personal, renamed], enabled: true)
        let result = await queue.terminalFeed(["done": true], trigger: "test")
        XCTAssertEqual(try payload(result)["nextProfile"] as? String, "Business")
        await queue.updateProfileCatalog(current: personal, profiles: [personal, renamed, other], enabled: true)
        let repeated = await queue.terminalFeed(["done": true], trigger: "test")
        XCTAssertNil(try payload(repeated)["nextProfile"])
        await queue.end()
    }

    func testPageBeforeTerminalDoesNotRepeatCalendarAtProfileHandoff() async throws {
        let queue = LocalTriageQueue(mailAccounts: { [] })
        await queue.configure(coachingPlan: .init(lessons: []),
            forceOnboardingFeedLesson: false, sequentialFeed: true,
            calendarFeedDue: true, localCalendar: false)
        await queue.configureProfileHandoff(current: personal, profiles: [personal, work], enabled: true, newCall: true)
        let firstPage = await queue.beginPageFeed()
        XCTAssertTrue(firstPage)
        let secondPage = await queue.beginPageFeed()
        XCTAssertFalse(secondPage)
        let terminal = await queue.terminalFeed(["done": true], trigger: "test")
        XCTAssertEqual(try payload(terminal)["nextProfile"] as? String, "Work")
        XCTAssertEqual(try payload(terminal)["calendarDue"] as? Bool, false)
        XCTAssertNil(try payload(terminal)["coaching"])
        await queue.end()
    }

    func testTerminalTipCarriesPreparedCalendarForItsContinuation() async throws {
        let queue = LocalTriageQueue(mailAccounts: { [] })
        await queue.configure(coachingPlan: .init(lessons: [.init(capability: "voice_only",
            copy: "Hands free", speech: "Quick tip: hands free. Was that helpful?",
            answerInstruction: "Feedback only.")]), localCoachingDelivery: true,
            forceOnboardingFeedLesson: false, sequentialFeed: true,
            calendarFeedDue: true, localCalendar: false)
        await queue.installCalendarPrefetch(.init(events: [], attendees: [], covered: true,
            servedLive: false, successful: true, ms: 0))
        let result = try payload(await queue.terminalFeed(["done": true], trigger: "test"))
        XCTAssertNotNil(result["coaching"])
        XCTAssertEqual(result["calendarDue"] as? Bool, true)
        XCTAssertNotNil(result["calendarAfterCoaching"] as? String)
        XCTAssertNil(result["calendarEvents"], "Do not present calendar before the tip is answered")
        await queue.end()
    }

    func testLongCallKeepsPreparedSlackThroughCalendarInsteadOfRescanning() async throws {
        let queue = LocalTriageQueue(mailAccounts: { [] })
        await queue.configure(coachingPlan: .init(lessons: []),
            forceOnboardingFeedLesson: false, sequentialFeed: true,
            calendarFeedDue: true, dynamicSlackFeed: true, localCalendar: false)
        let team = UUID().uuidString
        let prepared = SlackQueueSnapshot(workspaces: ["Prepared workspace"], total: 1,
            items: [.init(teamId: team, teamName: "Prepared workspace", channelId: "C-prepared",
                withUserId: nil, label: "Prepared channel", kind: "channel", unread: 1, more: false,
                messages: [], why: "")],
            report: .init(workspacesUnavailable: nil, unchecked: 0, unreachable: 0,
                          readStateUnknown: 0, dmsUnavailable: nil, markUnavailable: nil))
        await queue.installSlackPrefetch(.init(generatedAt: Date().addingTimeInterval(-3600),
            teams: [team], queue: prepared), profileId: ProfileRuntime.snapshot?.profileId)
        await Container.shared.localSlack().beginCall()
        let result = try payload(await queue.terminalFeed(["done": true], trigger: "test"))
        XCTAssertEqual(result["slackDue"] as? Bool, true)
        XCTAssertNil(result["slackStep"], "Calendar is still ahead of Slack")
        let slack = await Container.shared.localSlack().step(direction: nil, restart: false, stop: false)
        XCTAssertEqual((try payload(slack.text)["item"] as? [String: Any])?["channel_id"] as? String,
                       "C-prepared")
        await Container.shared.localSlack().end()
        await queue.end()
    }

    private func payload(_ output: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

}
