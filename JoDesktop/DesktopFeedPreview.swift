#if targetEnvironment(macCatalyst)
import Combine
import Foundation
import FactoryKit

@MainActor
class DesktopFeedPreview: ObservableObject {
    struct Context: Equatable, Sendable {
        let userID: String
        let profileID: String
        let emails: [String]
        let slackTeams: [String]
        var sections: [FeedSection]? = nil
        var forceRefresh = false
    }

    struct Part: Sendable {
        var rows: [DesktopFeedRow] = []
        var count: Int? = 0
        var incomplete = false
        static var unavailable: Part { Part(count: nil, incomplete: true) }
    }

    struct Snapshot: Sendable {
        var mail: Part
        var slack: Part
        var calendar: Part = .init()
        var sections: [FeedSection]? = nil
        var rows: [DesktopFeedRow] {
            let all = mail.rows + slack.rows + calendar.rows
            guard let sections else { return all }
            return sections.filter(\.enabled).flatMap { section in all.filter { $0.section?.id == section.id } }
        }
        var incomplete: Bool { mail.incomplete || slack.incomplete || calendar.incomplete }

        func countLabel(filter: String) -> String {
            let parts = filter == "Email" ? [mail] : filter == "Slack" ? [slack] : filter == "Calendar" ? [calendar] : [mail, slack, calendar]
            let known = parts.compactMap(\.count)
            let count = known.reduce(0, +)
            guard !known.isEmpty, count > 0 || parts.allSatisfy({ $0.count != nil && !$0.incomplete }) else { return "—" }
            return count == 0 ? "0" : "≈\(count)"
        }

        func retainingUnavailable(from previous: Snapshot?) -> Snapshot {
            var next = self
            if mail.count == nil, var saved = previous?.mail { saved.incomplete = true; next.mail = saved }
            if slack.count == nil, var saved = previous?.slack { saved.incomplete = true; next.slack = saved }
            if calendar.count == nil, var saved = previous?.calendar { saved.incomplete = true; next.calendar = saved }
            return next
        }
    }

    @Published var snapshot: Snapshot?
    @Published var refreshing = false
    private var context: Context?
    private var lastAttempt: Date?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let load: @Sendable (Context) async -> Snapshot
    static let refreshInterval: TimeInterval = 120

    init(load: @escaping @Sendable (Context) async -> Snapshot = { await DesktopFeedPreviewLoader.load($0) }) {
        self.load = load
    }

    func update(context: Context?, inSession: Bool, now: Date = Date(), force: Bool = false) {
        if self.context != context {
            pause()
            self.context = context
            snapshot = nil
        }
        guard let context else { return }
        guard !inSession else { pause(); return }
        guard task == nil, force || (lastAttempt.map({ now.timeIntervalSince($0) >= Self.refreshInterval }) ?? true) else { return }
        lastAttempt = now
        refreshing = true
        let request = UUID()
        generation = request
        task = Task { [weak self, load] in
            var requestContext = context
            requestContext.forceRefresh = force
            let result = await load(requestContext)
            guard let self, !Task.isCancelled, self.generation == request, self.context == context else { return }
            self.snapshot = result.retainingUnavailable(from: self.snapshot)
            self.refreshing = false
            self.task = nil
        }
    }

    func pause() {
        generation = UUID()
        task?.cancel()
        task = nil
        lastAttempt = nil
        if refreshing { refreshing = false }
    }

    deinit { task?.cancel() }

    func remove(_ selection: MailSelection) {
        guard var value = snapshot else { return }
        let count = value.mail.rows.count
        value.mail.rows.removeAll { $0.selection == selection }
        if value.mail.rows.count < count, let total = value.mail.count { value.mail.count = max(0, total - 1) }
        snapshot = value
    }
}

enum DesktopFeedPreviewLoader {
    static func load(_ context: DesktopFeedPreview.Context) async -> DesktopFeedPreview.Snapshot {
        async let mail = mail(context)
        async let slack = slack(context)
        async let calendar = calendar(context)
        return await .init(mail: mail, slack: slack, calendar: calendar, sections: context.sections)
    }

    private static func mail(_ context: DesktopFeedPreview.Context) async -> DesktopFeedPreview.Part {
        var result = DesktopFeedPreview.Part()
        var answered = 0
        let sections = context.sections ?? FeedSection.resolved(nil, accounts: context.emails)
        let accounts = context.emails.filter { account in sections.contains { $0.isMail && $0.enabled && $0.account?.lowercased() == account.lowercased() } }
        let store = await MainActor.run { Container.shared.mailStore() }
        for account in accounts {
            guard !Task.isCancelled else { return .unavailable }
            guard case .success(let token) = await GoogleCredential.token(for: account) else {
                result.incomplete = true
                continue
            }
            do {
                let count = try await GmailAPI.inboxTotalCount(token: token.accessToken)
                answered += 1
                let enabledKinds = Set(sections.filter { $0.enabled && $0.account?.lowercased() == account.lowercased() }.map(\.kind))
                let priorRows = result.rows.count
                if enabledKinds.count == 2 { result.count = (result.count ?? 0) + count }
                let limit = 24
                guard count > 0, limit > 0, !Task.isCancelled else { continue }
                let refs = try await GmailAPI.recentMessageIds(token: token.accessToken, query: "in:inbox", limit: limit)
                guard !Task.isCancelled else { return .unavailable }
                let details = await GmailAPI.metadata(token: token.accessToken, ids: refs.map(\.id))
                if details.count != refs.count { result.incomplete = true }
                let byID = Dictionary(details.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                guard let importantIDs = await store.importantFeedIDs(among: refs.map(\.id), account: account) else {
                    result.incomplete = true
                    continue
                }
                if enabledKinds.contains(.important) {
                    let important = await store.unreadPage(before: nil, limit: 24, importantOnly: true, account: account, band: "high")
                    result.rows += important.map {
                        .email(account: account, messageID: $0.id, subject: $0.subject ?? "", sender: $0.sender ?? account,
                               section: context.sections == nil ? nil : .init(kind: .important, account: account))
                    }
                }
                let held = Set(result.rows.map(\.id))
                result.rows += refs.compactMap { ref in
                    guard !held.contains("mail:\(account):\(ref.id)") else { return nil }
                    guard let detail = byID[ref.id] else { return nil }
                    let kind: FeedSection.Kind = importantIDs.contains(ref.id) ? .important : .remaining
                    let section = FeedSection(kind: kind, account: account)
                    guard sections.contains(where: { $0.id == section.id && $0.enabled }) else { return nil }
                    return .email(account: account, messageID: ref.id, subject: detail.header("Subject") ?? "",
                                  sender: detail.header("From") ?? account, section: context.sections == nil ? nil : section)
                }
                if enabledKinds.count < 2 { result.count = (result.count ?? 0) + result.rows.count - priorRows }
            } catch {
                result.incomplete = true
                RealtimeLog.log("desktop feed: inbox preview failed — \(error.localizedDescription)")
            }
        }
        if !accounts.isEmpty && answered == 0 { result.count = nil }
        return result
    }

    private static func slack(_ context: DesktopFeedPreview.Context) async -> DesktopFeedPreview.Part {
        guard context.sections?.contains(where: { $0.kind == .slack && $0.enabled }) != false,
              !context.slackTeams.isEmpty else { return .init() }
        let workspaces = SlackWorkspace.served(profileId: context.profileID).filter { context.slackTeams.contains($0.teamId) }
        guard !workspaces.isEmpty, !Task.isCancelled else { return .unavailable }
        // A read-only sweep; no model ranking, live cursor, or mark-read calls.
        let queue = await SlackSweep.buildQueue(workspaces, model: nil)
        let report = queue.report
        let partial = !(report.workspacesUnavailable ?? []).isEmpty || report.unchecked > 0
            || report.unreachable > 0 || report.readStateUnknown > 0 || report.dmsUnavailable == true
            || workspaces.count != context.slackTeams.count
        return .init(rows: queue.items.map {
            var row = DesktopFeedRow.slack($0)
            if context.sections != nil { row.section = .init(kind: .slack) }
            return row
        },
                     count: queue.workspaces.isEmpty ? nil : queue.total, incomplete: partial)
    }
    private static func calendar(_ context: DesktopFeedPreview.Context) async -> DesktopFeedPreview.Part {
        guard context.sections?.contains(where: { $0.kind == .calendar && $0.enabled }) == true else { return .init() }
        let granted = GoogleAccountStore.all().filter { GoogleCredential.calendarScopes.allSatisfy($0.scopes.contains) }.map(\.email)
        let accounts = context.emails.filter { email in granted.contains { $0.caseInsensitiveCompare(email) == .orderedSame } }
        guard !accounts.isEmpty else { return .init() }
        guard let result = await CalendarSearch.feedAgenda(accounts: accounts,
            store: CalendarStore(database: Container.shared.localContext().dbPool), forceRefresh: context.forceRefresh), result.successful else { return .unavailable }
        return .init(rows: result.events.map(DesktopFeedRow.calendar), count: result.events.count)
    }
}

#endif
