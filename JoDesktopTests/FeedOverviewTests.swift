import XCTest
@testable import CodenameJo

@MainActor
final class FeedOverviewTests: XCTestCase {
    func testOverviewOwnsFocusAndSidebarWithoutGrantingEmailActions() throws {
        let overview = try XCTUnwrap(FeedOverview(payload: ["id": "opening", "entries": [
            ["identity": "Priya", "subject": "Contract", "why": "Needs a signature"],
            ["identity": "Dana", "subject": "Review"],
            ["identity": "Dana", "subject": "Another review"]]]))
        let mail = LocalTriageQueue.Item(account: "work@example.test", id: "first", threadId: "thread",
            from: "Priya", subject: "Contract", date: "", snippet: "", internalDate: 0)
        let client = FullDuplexVoiceClient(localTriage: LocalTriageQueue(mailAccounts: { [] }))
        client.sequentialFeed = true
        let model = DesktopWorkspaceModel()
        model.inSession = true
        model.conversationID = UUID()
        client.onFeedFocus = { model.focus = $0 }
        client.applyStep(overview.step, progress: nil, standing: nil, served: [], dial: client.dialGeneration)
        model.applySessionFeed(.init(mail: .init(items: [mail], currentID: nil, account: mail.account,
            scope: "important", status: .ready, revision: 1, overview: overview)))

        XCTAssertEqual(model.displayedFocus, .overview(overview))
        XCTAssertFalse(model.selectionIsTransitioning)
        XCTAssertNil(model.presentedSelection)
        XCTAssertNil(model.feedActionContext)
        XCTAssertEqual(model.feedRows.count, 2)
        XCTAssertTrue(model.isCurrentRow(model.feedRows[0]))
        XCTAssertFalse(model.isCurrentRow(model.feedRows[1]))
        model.filter = "Email"
        XCTAssertEqual(model.filteredQueue.count, 2, "The current overview stays visible when filtering email")
        XCTAssertTrue(overview.speech.contains("Dana, Review; Dana, Another review"))

        let email = FeedFocus.Email(sender: mail.from, subject: mail.subject, snippet: "", account: mail.account,
            position: 1, total: 1, messageId: mail.id)
        model.focus = .email(email)
        XCTAssertEqual(model.displayedFocus, .overview(overview), "Hold the overview until email one is committed")
        model.applySessionFeed(.init(mail: .init(items: [mail], currentID: mail.id, account: mail.account,
            scope: "important", status: .ready, revision: 2)))
        XCTAssertEqual(model.displayedFocus, .email(email))
        XCTAssertEqual(model.feedRows.count, 1)
        XCTAssertNotNil(model.feedActionContext)
    }

    func testInvalidOverviewDoesNotReplaceCurrentFocusAndResetClearsIt() throws {
        let overview = try XCTUnwrap(FeedOverview(payload: ["id": "one", "entries": [
            ["identity": "Priya", "subject": "Contract"]]]))
        XCTAssertEqual(overview.title, "One thing that matters")
        XCTAssertTrue(overview.speech.hasPrefix("One thing matters"))
        var tracker = FeedFocusTracker()
        tracker.applyTriage(output: overview.step)
        tracker.applyTriage(output: #"{"overview":{"id":"bad","entries":[]}}"#)
        XCTAssertEqual(tracker.focus, .overview(overview))
        XCTAssertNil(tracker.reset())
        XCTAssertNil(FeedOverview(payload: ["entries": []]))
    }
}
