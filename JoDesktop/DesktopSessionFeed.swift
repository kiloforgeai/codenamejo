#if targetEnvironment(macCatalyst)
import Foundation

struct DesktopFeedRow: Identifiable, Equatable, Sendable {
    let id: String
    let source: String
    let title: String
    let detail: String
    let reason: String?
    var selection: MailSelection? = nil
    var section: FeedSection? = nil
    var symbol: String { source == "Slack" ? "number" : source == "Calendar" ? "calendar" : "envelope" }

    static func email(account: String, messageID: String, subject: String, sender: String,
                      reason: String? = nil, section: FeedSection? = nil) -> Self {
        .init(id: "mail:\(account):\(messageID)", source: "Email",
              title: subject.isEmpty ? "No subject" : subject, detail: sender, reason: reason,
              selection: .init(account: account, messageID: messageID), section: section)
    }

    static func slack(_ item: SlackQueueSnapshot.Item) -> Self {
        .init(id: "slack:\(item.teamId):\(item.channelId)", source: "Slack",
              title: item.label, detail: item.teamName, reason: item.why.isEmpty ? nil : item.why)
    }

    static func calendar(_ event: CalendarStore.Event) -> Self {
        .init(id: "calendar:\(event.account):\(event.calendarId):\(event.id)", source: "Calendar",
              title: event.summary ?? "Untitled event", detail: event.startRaw ?? "Today", reason: nil,
              section: .init(kind: .calendar))
    }
}

struct DesktopFeedSection: Identifiable, Equatable, Sendable {
    let section: FeedSection
    var rows: [DesktopFeedRow]
    var id: String { section.id }
}

struct DesktopSessionFeed: Equatable, Sendable {
    var rows: [DesktopFeedRow] = []
    var current: MailSelection?
    var status: LocalTriageQueue.DesktopStatus = .idle
    var scope = ""
    var revision = 0
}

extension DesktopSessionFeed {
    init(mail: LocalTriageQueue.DesktopSnapshot, slack: [SlackQueueSnapshot.Item] = []) {
        rows = mail.sections?.flatMap(\.rows) ?? (mail.items.map {
            .email(account: $0.account, messageID: $0.id, subject: $0.subject,
                   sender: $0.from, reason: $0.importanceWhy)
        } + slack.map(DesktopFeedRow.slack))
        current = mail.currentID.flatMap { id in mail.account.map { .init(account: $0, messageID: id) } }
        status = mail.status
        scope = mail.scope
        revision = mail.revision
    }
}
#endif
