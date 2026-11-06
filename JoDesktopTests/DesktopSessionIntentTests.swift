import XCTest
@testable import CodenameJo

final class DesktopSessionIntentTests: XCTestCase {
    func testStartSessionBuildsAnAutomaticFeedWithoutAnOffer() throws {
        let setup = setup(for: .feed)
        XCTAssertEqual(setup.openingMode, .emailQueue)
        XCTAssertTrue(setup.sequentialFeed)
        XCTAssertTrue(setup.slackFeedStage)
        XCTAssertTrue(setup.calendarFeedDue)
        XCTAssertEqual(SessionOpening.accepted(requested: DesktopSessionIntent.feed.opening,
                                              echoed: setup.openingMode), .emailQueue)
        let facts = LivePrompt.Facts(setup.prompt)
        XCTAssertTrue(facts.sequentialOpening)
        XCTAssertFalse(facts.feedOffer)
        let instructions = try LivePrompt.brainInstructions(facts, timeZone: "UTC")
        XCTAssertTrue(instructions.contains("# Fresh-call sequential email feed"))
        XCTAssertFalse(instructions.contains("# Fresh-call feed offer"))
        XCTAssertFalse(instructions.contains("Want me to go through your inbox?"))
    }

    func testQuickActionListensWithoutAFeedButKeepsActionToolsAvailable() throws {
        let setup = setup(for: .quickAction)
        XCTAssertEqual(setup.openingMode, .none)
        XCTAssertFalse(setup.sequentialFeed)
        XCTAssertFalse(setup.slackFeedStage)
        XCTAssertFalse(setup.calendarFeedDue)
        XCTAssertFalse(setup.feedBriefing)
        let instructions = try LivePrompt.brainInstructions(LivePrompt.Facts(setup.prompt), timeZone: "UTC")
        XCTAssertFalse(instructions.contains("# Fresh-call sequential email feed"))
        XCTAssertFalse(instructions.contains("# Fresh-call feed offer"))
        let tools = Set(setup.tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(tools.contains("dispatch"))
        XCTAssertTrue(tools.contains("create_draft"))
        XCTAssertTrue(tools.contains("triage_next"))
    }

    func testReconnectingKeepsTheChosenOpeningUntilItHasBeenHeard() {
        XCTAssertEqual(SessionOpening.afterReconnect(requested: DesktopSessionIntent.feed.opening,
                                                    wasAudible: false), .emailQueue)
        XCTAssertEqual(SessionOpening.afterReconnect(requested: DesktopSessionIntent.feed.opening,
                                                    wasAudible: true), .none)
        XCTAssertEqual(SessionOpening.afterReconnect(requested: DesktopSessionIntent.quickAction.opening,
                                                    wasAudible: false), .none)
    }

    private func setup(for intent: DesktopSessionIntent) -> LiveSessionSetup.Result {
        var request = LiveSessionSetup.Request()
        request.opening = intent.opening
        request.sequentialFeed = true
        request.calendarFeedDue = true
        request.feedItems = true
        request.dispatch = true
        var state = LiveSessionSetup.State()
        state.inboxes = ["jo-qa@example.com"]
        state.calendars = state.inboxes
        state.slackWorkspaces = ["QA"]
        return LiveSessionSetup.resolve(request, state, catalog: .bundled)
    }
}
