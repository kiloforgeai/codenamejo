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
