import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import CodenameJo

@MainActor
final class DesktopKeyboardTests: XCTestCase {
    func testEditorsAndEmbeddedBrowserNeverAuthorizeFeedShortcuts() {
        XCTAssertTrue(DesktopKeyboardFocus.blocksFeedAction(UITextField()))
        let editor = UITextView()
        XCTAssertTrue(DesktopKeyboardFocus.blocksFeedAction(editor))
        editor.isEditable = false
        XCTAssertFalse(DesktopKeyboardFocus.blocksFeedAction(editor), "The read-only email remains a keyboard work surface")
        let browser = WKWebView()
        let webContent = UIView()
        browser.addSubview(webContent)
        XCTAssertTrue(DesktopKeyboardFocus.blocksFeedAction(webContent))
        XCTAssertTrue(DesktopKeyboardFocus.blocksFeedAction(browser))
        XCTAssertFalse(DesktopKeyboardFocus.blocksFeedAction(UIButton()))
        XCTAssertFalse(DesktopKeyboardFocus.allowsFeedAction(in: nil))
        let hidden = UIWindow()
        hidden.isHidden = true
        XCTAssertFalse(DesktopKeyboardFocus.allowsFeedAction(in: hidden))
    }

    func testDialogAndPendingActionGatesFollowCapturedSource() throws {
        let model = DesktopWorkspaceModel()
        XCTAssertEqual(model.feedActionDisabledReason, "Select an email in the feed first.")
        model.profileID = "fixture"
        model.conversationID = UUID()
        model.inSession = true
        let source = MailSelection(account: "owner@example.test", messageID: "A")
        model.focus = .email(.init(sender: "Sender", subject: "Subject", snippet: "",
            account: source.account, position: 1, messageId: source.messageID))
        model.applySessionFeed(.init(rows: [.email(account: source.account, messageID: source.messageID,
            subject: "Subject", sender: "Sender")], current: source, status: .ready, scope: "fixture", revision: 1))
        XCTAssertNil(model.feedActionDisabledReason)
        model.pendingFeedActions.insert(source)
        XCTAssertEqual(model.feedActionDisabledReason, "An action is running for this email. Follow its result in Activity.")
        model.pendingFeedActions = [.init(account: source.account, messageID: "B")]
        XCTAssertNil(model.feedActionDisabledReason, "An unrelated background action does not capture the selected source")
        model.showingFeedback = true
        XCTAssertEqual(model.feedActionDisabledReason, "Close the dialog to use feed actions.")
        model.showingFeedback = false
        model.showingSettings = true
        XCTAssertEqual(model.feedActionDisabledReason, "Close the dialog to use feed actions.")
        model.showingSettings = false
        model.showingActionMenu = true
        XCTAssertEqual(model.feedActionDisabledReason, "Close the dialog to use feed actions.")
        model.showingActionMenu = false
        model.showingShortcutReference = true
        XCTAssertEqual(model.feedActionDisabledReason, "Close the dialog to use feed actions.")
    }

    func testShortcutAndClickUseTheSameHandlerContract() {
        let handler = Handler()
        let selection = MailSelection(account: "owner@example.test", messageID: "A")
        let state = RenderedFeedState(profileID: "fixture", conversationID: UUID(), focus: selection, queueCurrent: selection)
        let context = FeedActionContext(state)!
        handler.performFeedShortcut(.archive, context: context)
        handler.performFeedAction(.next, context: context)
        XCTAssertEqual(handler.calls.map(\.0), [.archive, .next])
        XCTAssertTrue(handler.calls.allSatisfy { $0.1 == context })
    }

    private final class Handler: DesktopWorkspaceHandler {
        var calls: [(LiveFastAction, FeedActionContext)] = []
        func performFeedAction(_ action: LiveFastAction, context: FeedActionContext) { calls.append((action, context)) }
        func toggleSession() {}
        func quickAction() {}
        func toggleMute() {}
        func stopSpeaking() {}
        func exportDiagnostics() {}
        func exportHistory() {}
        func showFeedback() {}
        func saveFeedback() {}
        func rendered(_ state: RenderedFeedState) {}
        func selectReturnedResult(_ id: UUID) {}
        func selectFeedItem(_ row: DesktopFeedRow) {}
        func submitTask(_ text: String, commandID: String?, context: FeedActionContext) {}
        func retryEmailReader() {}
        func refreshFeed() {}
    }
}
