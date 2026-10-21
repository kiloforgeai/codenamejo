import XCTest
@testable import CodenameJo

/// A returning call asks before the feed starts; the first call after onboarding still walks
/// the queue unasked, and the opt-out keeps its listening-first dial.
final class FeedOfferOpeningTests: XCTestCase {
    func testAReturningCallOffersTheFeedAndOnboardingStillStartsIt() {
        XCTAssertEqual(SessionOpening.freshConversation(onboardingPending: false, agentLedEmailEnabled: true), .feedOffer)
        XCTAssertEqual(SessionOpening.freshConversation(onboardingPending: true, agentLedEmailEnabled: true), .emailQueue)
        XCTAssertEqual(SessionOpening.freshConversation(onboardingPending: false, agentLedEmailEnabled: false), .none)
        XCTAssertEqual(SessionOpening.freshConversation(onboardingPending: true, agentLedEmailEnabled: false), .onboarding)
    }

    func testTheOfferIsFailClosedOnTheSessionSetupsEcho() {
        XCTAssertEqual(SessionOpening.accepted(requested: .feedOffer, echoed: .feedOffer), .feedOffer)
        XCTAssertEqual(SessionOpening.accepted(requested: .feedOffer, echoed: nil), .none)
        XCTAssertEqual(SessionOpening.accepted(requested: .feedOffer, echoed: .emailQueue), .none)
        XCTAssertEqual(SessionOpening.accepted(requested: .emailQueue, echoed: .feedOffer), .none)
        XCTAssertEqual(SessionOpening.accepted(requested: .feedOffer, echoed: nil, resumingOnboarding: true), .none)
        XCTAssertEqual(SessionOpening.accepted(requested: .feedOffer, echoed: SessionOpening.none, resumingOnboarding: true), .none)
        XCTAssertEqual(SessionOpening.accepted(requested: .none, echoed: .emailQueue, resumingOnboarding: true), .none)
        XCTAssertTrue(SessionOpening.feedOffer.leadsWithFeed)
        XCTAssertTrue(SessionOpening.emailQueue.leadsWithFeed)
        XCTAssertFalse(SessionOpening.none.leadsWithFeed)
        XCTAssertFalse(SessionOpening.onboarding.leadsWithFeed)
    }

    func testTheSessionSetupEchoesTheOfferWithTheWholeFeedBehindIt() throws {
        let catalog = LiveSessionSetup.Catalog.bundled
        var request = LiveSessionSetup.Request()
        request.opening = .feedOffer
        request.sequentialFeed = true
        request.calendarFeedDue = true
        request.feedItems = true
        var state = LiveSessionSetup.State()
        state.inboxes = ["nate@example.com"]
        state.calendars = ["nate@example.com"]

        let setup = LiveSessionSetup.resolve(request, state, catalog: catalog)
        XCTAssertEqual(setup.openingMode, .feedOffer)
        XCTAssertTrue(setup.sequentialFeed)
        XCTAssertTrue(setup.interactiveCoaching)
        XCTAssertTrue(setup.calendarFeedDue)
        XCTAssertTrue(setup.feedBriefing)
        XCTAssertEqual(setup.prompt["feedOffer"] as? Bool, true)
        XCTAssertEqual(setup.prompt["sequentialOpening"] as? Bool, false)

        let facts = LivePrompt.Facts(setup.prompt)
        XCTAssertTrue(facts.feedOffer)
        XCTAssertFalse(facts.sequentialOpening)
        let brain = try LivePrompt.brainInstructions(facts, timeZone: "UTC")
        XCTAssertTrue(brain.contains("# Fresh-call feed offer"))
        XCTAssertFalse(brain.contains("# Fresh-call sequential email feed"))

        request.onboardingRun = (resume: true, opening: "")
        let resumedSetup = LiveSessionSetup.resolve(request, state, catalog: catalog)
        XCTAssertEqual(resumedSetup.openingMode, .emailQueue)
        XCTAssertEqual(SessionOpening.accepted(
            requested: request.opening, echoed: resumedSetup.openingMode, resumingOnboarding: true), .emailQueue)
    }

    func testTheAutomaticOpeningKeepsItsOwnPrompt() throws {
        let catalog = LiveSessionSetup.Catalog.bundled
        var request = LiveSessionSetup.Request()
        request.opening = .emailQueue
        request.sequentialFeed = true
        var state = LiveSessionSetup.State()
        state.inboxes = ["nate@example.com"]

        let setup = LiveSessionSetup.resolve(request, state, catalog: catalog)
        XCTAssertEqual(setup.openingMode, .emailQueue)
        XCTAssertNil(setup.prompt["feedOffer"])
        XCTAssertEqual(setup.prompt["sequentialOpening"] as? Bool, true)
        let brain = try LivePrompt.brainInstructions(LivePrompt.Facts(setup.prompt), timeZone: "UTC")
        XCTAssertTrue(brain.contains("# Fresh-call sequential email feed"))
        XCTAssertFalse(brain.contains("# Fresh-call feed offer"))
    }

    func testAnOfferWithNoInboxFallsBackToListeningFirst() throws {
        let catalog = LiveSessionSetup.Catalog.bundled
        var request = LiveSessionSetup.Request()
        request.opening = .feedOffer
        request.sequentialFeed = true
        let setup = LiveSessionSetup.resolve(request, LiveSessionSetup.State(), catalog: catalog)
        XCTAssertEqual(setup.openingMode, SessionOpening.none)
        XCTAssertFalse(setup.sequentialFeed)
        XCTAssertNil(setup.prompt["feedOffer"])
    }

    @MainActor
    func testTheOfferLineKeepsTheGreetingShapeWithAndWithoutAName() {
        XCTAssertEqual(FullDuplexVoiceClient.feedOfferLine(address: ""),
                       "Hi, welcome back. Want me to go through your inbox?")
        XCTAssertEqual(FullDuplexVoiceClient.feedOfferLine(address: " Raghav"),
                       "Hi Raghav, welcome back. Want me to go through your inbox?")
        let plain = FullDuplexVoiceClient.feedOfferInstructions(address: " Raghav")
        XCTAssertTrue(plain.contains("Begin exactly with \"Hi Raghav, welcome back. Want me to go through your inbox?\""))
        XCTAssertTrue(plain.contains("Call no tool"))
        let briefed = FullDuplexVoiceClient.briefedFeedOfferInstructions(address: "", answers: ["Rain by noon."])
        XCTAssertTrue(briefed.contains("Begin exactly with \"Hi, welcome back.\""))
        XCTAssertTrue(briefed.contains("Rain by noon."))
        XCTAssertTrue(briefed.contains("Then ask exactly \"Want me to go through your inbox?\""))
    }
}
