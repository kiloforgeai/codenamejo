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
    var previewFocus: FeedFocus? = nil
    var context: String? = nil
    var selectionStep: String? {
        guard let context else { return nil }
        if source == "Overview" { return context }
        guard let value = try? JSONSerialization.jsonObject(with: Data(context.utf8)) else { return nil }
        return LocalTriageQueue.json(["done": false, "desktopSelection": source, "selection": value,
            "note": "This is the selected feed item. No email is selected. The next triage_next resumes the held feed."])
    }
    var symbol: String { source == "Overview" ? "list.number" : source == "Slack" ? "number" : source == "Calendar" ? "calendar" : "envelope" }

    static func overview(_ overview: FeedOverview) -> Self {
        .init(id: "overview:\(overview.id)", source: "Overview", title: overview.title,
              detail: "Your priorities at a glance", reason: nil, previewFocus: .overview(overview), context: overview.step)
    }

    static func email(account: String, messageID: String, subject: String, sender: String,
                      reason: String? = nil, section: FeedSection? = nil) -> Self {
        .init(id: "mail:\(account):\(messageID)", source: "Email",
              title: subject.isEmpty ? "No subject" : subject, detail: sender, reason: reason,
              selection: .init(account: account, messageID: messageID), section: section,
              previewFocus: .email(.init(sender: sender, subject: subject, snippet: "", account: account,
                position: 1, total: nil, messageId: messageID, isFeedSelection: true)))
    }

    static func slack(_ item: SlackQueueSnapshot.Item) -> Self {
        .init(id: "slack:\(item.teamId):\(item.channelId)", source: "Slack",
              title: item.label, detail: item.teamName, reason: item.why.isEmpty ? nil : item.why,
              previewFocus: .slack(.init(name: item.label, workspace: item.teamName, showsWorkspace: true,
                unread: item.unread, more: item.more, messages: item.messages.map { .init(from: $0.from, text: $0.text) },
                position: 1, total: nil)),
              context: LocalSlackQueue.json(["workspace": item.teamName, "team_id": item.teamId,
                "channel_id": item.channelId, "name": item.label,
                "messages": item.messages.map { ["from": $0.from, "text": $0.text, "ts": $0.ts] }]))
    }

    static func calendar(_ event: CalendarStore.Event) -> Self {
        .init(id: "calendar:\(event.account):\(event.calendarId):\(event.id)", source: "Calendar",
              title: event.summary ?? "Untitled event", detail: event.startRaw ?? "Today", reason: nil,
              section: .init(kind: .calendar), previewFocus: .calendar(.agenda(events: [.init(id: event.id,
                account: event.account, title: event.summary ?? "Untitled event", location: event.location,
                start: event.startEpochMs.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                end: event.endEpochMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }, allDay: event.isAllDay)], partial: false)),
              context: LocalTriageQueue.json(["account": event.account, "calendar_id": event.calendarId,
                "event_id": event.id, "title": event.summary ?? "Untitled event",
                "start": event.startRaw ?? "", "end": event.endRaw ?? "", "location": event.location ?? ""]))
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
    var selectedRow: DesktopFeedRow?
}

extension DesktopSessionFeed {
    init(mail: LocalTriageQueue.DesktopSnapshot, slack: [SlackQueueSnapshot.Item] = []) {
        rows = mail.sections?.flatMap(\.rows) ?? (mail.items.map {
            .email(account: $0.account, messageID: $0.id, subject: $0.subject,
                   sender: $0.from, reason: $0.importanceWhy)
        } + slack.map(DesktopFeedRow.slack))
        if let overview = mail.overview { rows.insert(.overview(overview), at: 0) }
        current = mail.currentID.flatMap { id in mail.account.map { .init(account: $0, messageID: id) } }
        status = mail.status
        scope = mail.scope
        revision = mail.revision
        selectedRow = mail.selectedRow
        if let selectedRow { rows = [selectedRow] + rows.filter { $0.id != selectedRow.id } }
    }
}
#endif
