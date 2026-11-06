import FactoryKit
import XCTest
@testable import CodenameJo

@MainActor
final class RenderedSelectionRegressionTests: XCTestCase {
    private var service: RealtimeService!
    override func setUp() async throws {
        try await super.setUp()
        Container.shared.manager.push()
        ProfileRuntime.install(.init(profileId: "work", isDefault: false, emails: ["work@example.test"]))
        service = RealtimeService()
        let service = service!
        Container.shared.realtimeService.register { service }
        service.isConversing = true
    }
    override func tearDown() async throws {
        service.isConversing = false
        Scope.singleton.reset()
        Container.shared.manager.pop()
        ProfileRuntime.install(nil)
        try await super.tearDown()
    }
    private func step(_ id: String) -> String {
        GmailReadTools.json(["done": false, "item": ["account": "work@example.test", "id": id,
            "threadId": "thread-\(id)", "from": "Same sender", "subject": "Same subject"]])
    }

    func testSingleSelectedEmailInLongThreadRemainsActionableWithoutUnboundedPreparation() throws {
        let members = (0..<27).map { ["id": "context-\($0)", "threadId": "thread-A"] }
        let step = GmailReadTools.json(["done": false, "item": ["id": "A", "account": "work@example.test",
            "threadId": "thread-A", "exchangeContext": members, "summaryMessages": members]])
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        XCTAssertEqual(key.messageId, "A")
        XCTAssertEqual(key.selectedIDs, ["A"])
        XCTAssertEqual(key.messageIDs.count, 28)
        XCTAssertTrue(LiveEmailPreparationCache.candidates(current: step, readAhead: [key]).isEmpty)
        let selection = MailSelection(account: "work@example.test", messageID: "A")
        let client = FullDuplexVoiceClient()
        client.standingStep = step
        service.renderedWorkspace = .init(profileID: "work", conversationID: nil, focus: selection, queueCurrent: selection)
        XCTAssertNil(client.renderedSelectionRefusal())
        service.renderedWorkspace?.queueCurrent = .init(account: "work@example.test", messageID: "B")
        XCTAssertNotNil(client.renderedSelectionRefusal(), "Long threads must still reject a genuinely changed selection")
        XCTAssertTrue(LiveFastAction.allowsFollowup(name: "gmail_get_message",
            arguments: #"{"message_id":"A","account":"work@example.test"}"#, step: step))
    }

    func testDelayedAndOutOfOrderSnapshotsHoldTheVisibleCardWithoutAuthorizingActions() {
        let model = DesktopWorkspaceModel()
        model.profileID = "work"; model.conversationID = UUID(); model.inSession = true
        func focus(_ id: String) -> FeedFocus {
            .email(.init(sender: "Same sender", subject: "Same subject", snippet: "",
                account: "work@example.test", position: 1, messageId: id))
        }
        func feed(_ id: String?, _ revision: Int) -> DesktopSessionFeed {
            .init(rows: [.email(account: "work@example.test", messageID: "B", subject: "Same subject", sender: "Same sender")],
                current: id.map { .init(account: "work@example.test", messageID: $0) }, status: .ready, scope: "work", revision: revision)
        }
        model.focus = focus("A"); model.applySessionFeed(feed("A", 1))
        XCTAssertNotNil(model.feedActionContext)
        model.focus = focus("B")
        XCTAssertEqual(model.displayedFocus, focus("A"))
        XCTAssertTrue(model.selectionIsTransitioning)
        XCTAssertNil(model.feedActionContext, "Even a retained card matching the old queue cannot authorize a write")
        XCTAssertEqual(model.renderedState.rawFocus?.messageID, "B")
        XCTAssertEqual(model.renderedState.focus?.messageID, "A")
        XCTAssertEqual(model.renderedState.displayBranch, "held")
        model.applySessionFeed(feed("B", 3))
        XCTAssertEqual(model.displayedFocus, focus("B"))
        XCTAssertNotNil(model.feedActionContext)
        model.applySessionFeed(feed("A", 2))
        XCTAssertEqual(model.sessionFeed.current?.messageID, "B", "A delayed snapshot must not roll the visible queue backward")
        var oldScope = feed("A", 1); oldScope.scope = "old-inbox"
        model.applySessionFeed(oldScope)
        XCTAssertEqual(model.sessionFeed.scope, "work")
        model.focus = nil; model.applySessionFeed(feed(nil, 4))
        XCTAssertEqual(model.displayedFocus, focus("B"))
        XCTAssertNil(model.feedActionContext)
        let trace = VoiceDiagnostics().begin(engine: "test")
        let fields = VoiceDiagnostics.safeFields(model.renderedState.diagnosticFields(session: trace, revision: 8))
        XCTAssertEqual(fields["selection_state"], "transitioning", "Nil raw and queue identities must not hide the held card")
        XCTAssertEqual(fields["raw_focus_state"], "none")
        XCTAssertEqual(fields["display_branch"], "held")
        XCTAssertNotNil(fields["target_hash"])
        model.profileID = "another"
        XCTAssertNil(model.displayedFocus)
        XCTAssertNil(model.feedActionContext)
    }

    func testCalendarAndCompletionCanReplaceAnEmailWithoutWaitingForMailQueueToMove() {
        let model = DesktopWorkspaceModel()
        model.inSession = true
        model.focus = .calendar(.loading)
        model.sessionFeed = .init(current: .init(account: "work@example.test", messageID: "held"), status: .ready)
        XCTAssertEqual(model.displayedFocus, .calendar(.loading))
        XCTAssertFalse(model.selectionIsTransitioning)
        XCTAssertNil(model.feedActionContext)
        model.focus = .complete(.init())
        XCTAssertEqual(model.displayedFocus, .complete(.init()))
    }
    func testReturnedResultNeverBorrowsTheHeldCursorsDisplayedOrdinal() {
        var email = FeedFocus.Email(sender: "Same sender", subject: "Same subject", snippet: "",
            account: "work@example.test", position: 7, total: 40, messageId: "R", isBackgroundResult: true)
        XCTAssertNil(email.displayedPosition)
        XCTAssertNil(email.displayedTotal)
        email.isBackgroundResult = false
        XCTAssertEqual(email.displayedPosition, 7)
        XCTAssertEqual(email.displayedTotal, 40)
    }

    func testTransitionTraceDoesNotClaimAnOrdinalThatTheWindowHides() {
        let model = DesktopWorkspaceModel()
        model.focus = .email(.init(sender: "Sender", subject: "Subject", snippet: "",
            account: "work@example.test", position: 7, total: 40, messageId: "D"))
        XCTAssertTrue(model.selectionIsTransitioning)
        XCTAssertNil(model.presentedSelection, "The row cannot be CURRENT before the matching card is rendered")
        XCTAssertNil(model.renderedState.focus)
        XCTAssertNil(model.renderedState.position)
        XCTAssertNil(model.renderedState.total)
    }
    func testNoSelectionAndMissingRenderNeverAuthorizeCurrentEmailActions() {
        let client = FullDuplexVoiceClient()
        service.renderedWorkspace = .init(profileID: "work", conversationID: nil, focus: nil, queueCurrent: nil)
        XCTAssertNotNil(client.renderedSelectionRefusal(), "Two missing identities do not establish a target")
        client.standingStep = step("C")
        service.renderedWorkspace = nil
        XCTAssertNotNil(client.renderedSelectionRefusal())
    }
    func testRenderedCardQueueAndRequestMustAgreeAcrossTransitionsAndProfiles() {
        let client = FullDuplexVoiceClient()
        let c = MailSelection(account: "work@example.test", messageID: "C")
        let d = MailSelection(account: "work@example.test", messageID: "D")
        client.standingStep = step("D")
        service.renderedWorkspace = .init(profileID: "work", conversationID: nil, focus: c, queueCurrent: d)
        XCTAssertNotNil(client.renderedSelectionRefusal())
        service.renderedWorkspace?.focus = d
        XCTAssertNil(client.renderedSelectionRefusal())
        client.liveQueueActionAnchor = .init(step: step("C"), profileId: "work", revision: 1)
        XCTAssertNotNil(client.renderedSelectionRefusal(), "A background/previous request cannot inherit D")
        client.liveQueueActionAnchor = .init(step: step("D"), profileId: "other-profile", revision: 2)
        XCTAssertNotNil(client.renderedSelectionRefusal())
        client.liveQueueActionAnchor = nil
        service.renderedWorkspace?.conversationID = UUID()
        XCTAssertNotNil(client.renderedSelectionRefusal(), "A previous window/session cannot authorize the new call")
    }
}
