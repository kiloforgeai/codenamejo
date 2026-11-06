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
        XCTAssertEqual(LiveEmailPreparationCache.candidates(current: step, readAhead: [key]).map(\.messageIDs), [["A"]])
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

    func testReceiptDraftAndHandledMetadataDoNotEraseTheCurrentSelection() throws {
        let selected = MailSelection(account: "work@example.test", messageID: "A")
        let client = FullDuplexVoiceClient()
        service.renderedWorkspace = .init(profileID: "work", conversationID: nil, focus: selected, queueCurrent: selected)
        for metadata: [String: Any] in [
            ["dispatchOutcome": ["status": "completed", "summary": "Reply sent"]],
            ["presentedForOutcome": true],
            ["hasDraft": true], ["alreadyDone": "sent"]
        ] {
            var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(step("A").utf8)) as? [String: Any])
            if metadata["hasDraft"] != nil || metadata["alreadyDone"] != nil {
                var item = try XCTUnwrap(payload["item"] as? [String: Any])
                item.merge(metadata, uniquingKeysWith: { _, value in value }); payload["item"] = item
            } else { payload.merge(metadata, uniquingKeysWith: { _, value in value }) }
            let output = GmailReadTools.json(payload)
            client.standingStep = output
            XCTAssertNil(LiveEmailPresentation.Key.step(output), "Summary eligibility must stay bounded")
            let key = try XCTUnwrap(LiveEmailPresentation.Key.selection(output))
            XCTAssertEqual(key.selectedIDs, ["A"])
            XCTAssertNil(client.renderedSelectionRefusal(), "A follow-up archive/next can target the unchanged rendered email")
            XCTAssertTrue(LiveFastAction.Anchor(key: key, profileId: "work", revision: 2)
                .matches(step: step("A"), profileId: "work", revision: 2))
            XCTAssertTrue(LiveFastAction.allowsFollowup(name: "gmail_get_message",
                arguments: #"{"message_id":"A","account":"work@example.test"}"#, step: output))
            service.renderedWorkspace?.queueCurrent = .init(account: "work@example.test", messageID: "B")
            XCTAssertNotNil(client.renderedSelectionRefusal(), "Receipt metadata cannot bypass the queue guard")
            service.renderedWorkspace?.queueCurrent = selected
        }
    }

    func testFailedBackgroundReceiptKeepsForegroundIdentityAndRejectsOldAnchors() throws {
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(step("F").utf8)) as? [String: Any])
        payload["dispatchOutcome"] = ["status": "failed", "sourceMessageID": "D"]
        let output = GmailReadTools.json(payload)
        let client = FullDuplexVoiceClient()
        client.standingStep = output
        let foreground = MailSelection(account: "work@example.test", messageID: "F")
        service.renderedWorkspace = .init(profileID: "work", conversationID: nil, focus: foreground, queueCurrent: foreground)
        XCTAssertEqual(LiveEmailPresentation.Key.selection(output)?.messageId, "F")
        XCTAssertNil(client.renderedSelectionRefusal())
        client.liveQueueActionAnchor = .init(step: step("D"), profileId: "work", revision: 1)
        XCTAssertNotNil(client.renderedSelectionRefusal(), "The background receipt must not reauthorize D")
        client.liveQueueActionAnchor = .init(step: output, profileId: "other", revision: 2)
        XCTAssertNotNil(client.renderedSelectionRefusal())
    }

    func testReceiptWithoutAnEmailIdentityNeverAuthorizesAnAction() {
        for output in [#"{"done":false,"dispatchOutcome":{"status":"completed"}}"#,
                       #"{"done":false,"item":{"account":"","id":"A","threadId":"t"}}"#,
                       #"{"done":true,"item":{"account":"work@example.test","id":"A","threadId":"t"}}"#] {
            XCTAssertNil(LiveEmailPresentation.Key.selection(output))
        }
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

    func testPreviewSurvivesStartupUntilFocusAndQueueCommitTogether() {
        let model = DesktopWorkspaceModel()
        model.profileID = "work"
        let row = DesktopFeedRow.email(account: "work@example.test", messageID: "A", subject: "Subject", sender: "Sender")
        model.feedPreview = .init(mail: .init(rows: [row], count: 40), slack: .init())
        model.previewSelection = row
        let visible = model.displayedFocus
        model.conversationID = UUID()
        model.inSession = true
        XCTAssertEqual(model.feedRows, [row])
        XCTAssertEqual(model.currentFeedRowID, row.id, "Keep the reader and scroll identity through handoff")
        XCTAssertEqual(model.displayedFocus, visible)
        XCTAssertTrue(model.isStartingFeed)
        XCTAssertNil(model.feedActionContext)
        model.applySessionFeed(.init(status: .loading, revision: 1))
        model.focus = row.previewFocus
        XCTAssertEqual(model.feedRows, [row])
        XCTAssertNil(model.feedActionContext)
        let fields = VoiceDiagnostics.safeFields(model.renderedState.diagnosticFields(session: VoiceDiagnostics().begin(engine: "test"), revision: 1))
        XCTAssertEqual(fields["sidebar_source"], "held_preview")
        XCTAssertEqual(fields["session_phase"], "starting")
        XCTAssertEqual(fields["visible_count"], "1")
        model.applySessionFeed(.init(rows: [row], current: row.selection, status: .ready, revision: 2))
        XCTAssertFalse(model.isStartingFeed)
        XCTAssertEqual(model.currentFeedRowID, row.id)
        XCTAssertNotNil(model.feedActionContext)
        model.conversationID = UUID()
        XCTAssertTrue(model.isStartingFeed, "Same-profile restart keeps the last coherent surface")
        XCTAssertEqual(model.feedRows, [row])
        XCTAssertNil(model.feedActionContext)
        model.profileID = "other"
        XCTAssertNil(model.displayedFocus)
        XCTAssertTrue(model.feedRows.isEmpty)
        XCTAssertNil(model.feedPreview)
    }

    func testColdStartupAndUnavailableFeedDoNotLookCompleteOrRetainOtherSessions() {
        let model = DesktopWorkspaceModel()
        model.conversationID = UUID(); model.inSession = true
        XCTAssertTrue(model.selectionIsTransitioning)
        XCTAssertFalse(model.feedComplete)
        XCTAssertEqual(model.feedCountLabel, "—", "Cold startup has no confirmed zero count")
        XCTAssertNil(model.feedActionContext)
        model.applySessionFeed(.init(status: .unavailable, revision: 1))
        XCTAssertFalse(model.isStartingFeed)
        XCTAssertFalse(model.feedComplete)
        model.inSession = false; model.conversationID = nil
        XCTAssertFalse(model.isStartingFeed)
        model.sessionIntent = .quickAction
        model.conversationID = UUID(); model.inSession = true
        XCTAssertFalse(model.isStartingFeed)
    }

    func testSessionEndRestartAndTransientRefreshNeverReplaceVisibleRowsWithEmpty() {
        let model = DesktopWorkspaceModel()
        model.profileID = "work"
        let row = DesktopFeedRow.email(account: "work@example.test", messageID: "A", subject: "Subject", sender: "Sender")
        model.feedPreview = .visible([row]); model.previewSelection = row
        model.conversationID = UUID(); model.inSession = true
        model.focus = row.previewFocus
        model.applySessionFeed(.init(rows: [row], current: row.selection, status: .ready, revision: 1))
        let visible = model.displayedFocus
        for status: LocalTriageQueue.DesktopStatus in [.loading, .unavailable, .idle] {
            model.applySessionFeed(.init(status: status, revision: model.sessionFeed.revision + 1))
            XCTAssertEqual(model.feedRows, [row])
            XCTAssertEqual(model.displayedFocus, visible)
            XCTAssertNil(model.feedActionContext)
        }
        model.applySessionFeed(.init(rows: [row], current: row.selection, status: .ready, revision: 9))
        model.conversationID = nil; model.inSession = false; model.focus = nil
        XCTAssertEqual(model.feedRows, [row])
        XCTAssertEqual(model.displayedFocus, visible)
        XCTAssertEqual(model.currentFeedRowID, row.id)
        model.conversationID = UUID(); model.inSession = true
        model.applySessionFeed(.init(status: .unavailable, revision: 1))
        XCTAssertEqual(model.feedRows, [row])
        XCTAssertEqual(model.displayedFocus, visible)
        XCTAssertNil(model.feedActionContext)
        model.focus = row.previewFocus
        model.applySessionFeed(.init(rows: [row], current: row.selection, status: .ready, revision: 2))
        XCTAssertNotNil(model.feedActionContext)
        model.focus = .complete(.init())
        model.applySessionFeed(.init(status: .complete, revision: 3))
        XCTAssertTrue(model.feedRows.isEmpty, "Confirmed completion can clear the list")
    }

    func testOwnerHydrationAndMembershipRemovalPreserveOnlyAuthorizedContent() {
        let model = DesktopWorkspaceModel()
        let context = DesktopFeedPreview.Context(userID: "owner", profileID: "work", emails: ["work@example.test"], slackTeams: [])
        model.reconcileScope(owner: "owner", profile: "work", context: context)
        let row = DesktopFeedRow.email(account: "work@example.test", messageID: "A", subject: "Subject", sender: "Sender")
        model.feedPreview = .visible([row]); model.previewSelection = row
        model.reconcileScope(owner: "owner", profile: nil, context: nil)
        XCTAssertEqual(model.feedRows, [row])
        XCTAssertEqual(model.displayedFocus, row.previewFocus)
        XCTAssertNil(model.feedActionContext)
        XCTAssertEqual(model.profileID, "work")
        model.reconcileScope(owner: "owner", profile: "work", context: context)
        XCTAssertNotNil(model.feedActionContext)
        model.reconcileScope(owner: "owner", profile: "work", context: .init(userID: "owner", profileID: "work", emails: [], slackTeams: []))
        XCTAssertTrue(model.feedRows.isEmpty)
        XCTAssertNil(model.displayedFocus)
        model.feedPreview = .visible([row]); model.previewSelection = row
        model.reconcileScope(owner: "another", profile: nil, context: nil)
        XCTAssertTrue(model.feedRows.isEmpty)
        XCTAssertNil(model.displayedFocus)
        XCTAssertNil(model.profileID)
        model.reconcileScope(owner: nil, profile: nil, context: nil)
        XCTAssertFalse(model.scopeHydrating)
    }

    func testEndingDuringSelectionTransitionNeverAttachesTheOldReaderToANewRow() {
        let model = DesktopWorkspaceModel()
        let rows = ["A", "B"].map { DesktopFeedRow.email(account: "work@example.test", messageID: $0, subject: $0, sender: "Sender") }
        model.conversationID = UUID(); model.inSession = true
        model.focus = rows[0].previewFocus
        model.applySessionFeed(.init(rows: rows, current: rows[0].selection, status: .ready, revision: 1))
        model.applySessionFeed(.init(rows: rows, current: rows[1].selection, status: .ready, revision: 2))
        XCTAssertTrue(model.selectionIsTransitioning)
        model.conversationID = nil; model.inSession = false; model.focus = nil
        XCTAssertEqual(model.previewSelection?.selection, rows[0].selection)
        XCTAssertEqual(model.feedActionContext?.selection, rows[0].selection)
        XCTAssertEqual(model.currentFeedRowID, rows[0].id)
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
