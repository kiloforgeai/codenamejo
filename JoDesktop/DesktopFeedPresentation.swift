#if targetEnvironment(macCatalyst)
import Foundation

struct DesktopFeedPresentation {
    let rawFocus: FeedFocus?
    let displayedFocus: FeedFocus?
    let isTransitioning: Bool

    init(focus: FeedFocus?, committedFocus: FeedFocus?, feed: DesktopSessionFeed,
         inSession: Bool, intent: DesktopSessionIntent, holdingStartup: Bool = false) {
        rawFocus = focus
        if holdingStartup {
            isTransitioning = true
        } else if case .email = focus {
            let selection = Self.selection(for: focus)
            isTransitioning = selection == nil || selection != feed.current
        } else if focus == nil, inSession, intent == .feed {
            isTransitioning = feed.current != nil || (!feed.rows.isEmpty && feed.status != .complete)
        } else {
            isTransitioning = false
        }
        displayedFocus = isTransitioning ? committedFocus : focus
    }

    var rawSelection: MailSelection? { Self.selection(for: rawFocus) }
    var displayedSelection: MailSelection? { Self.selection(for: displayedFocus) }
    var presentedSelection: MailSelection? { isTransitioning ? nil : rawSelection }

    var currentEmail: FeedFocus.Email? {
        guard !isTransitioning, case .email(let email) = rawFocus else { return nil }
        return email
    }

    var displayBranch: String {
        if isTransitioning { return displayedSelection == nil ? "waiting" : "held" }
        return displayedSelection == nil ? "none" : "current"
    }

    func isCurrentRow(_ row: DesktopFeedRow) -> Bool {
        if case .overview(let overview) = displayedFocus { return row.id == "overview:\(overview.id)" }
        return presentedSelection.map { row.selection == $0 } ?? false
    }

    static func selection(for focus: FeedFocus?) -> MailSelection? {
        guard case .email(let email) = focus, let id = email.messageId else { return nil }
        return .init(account: email.account, messageID: id)
    }
}
#endif
