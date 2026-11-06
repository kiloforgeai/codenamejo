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

        func sharesOwner(with other: Context?) -> Bool {
            other?.userID == userID && other?.profileID == profileID
        }

        func allows(_ row: DesktopFeedRow) -> Bool {
            if let section = row.section, let sections,
               !sections.contains(where: { $0.id == section.id && $0.enabled }) { return false }
            if let selection = row.selection {
                return emails.contains { $0.caseInsensitiveCompare(selection.account) == .orderedSame }
            }
            if row.source == "Overview" { return true }
            guard let data = row.context?.data(using: .utf8),
                  let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            if row.source == "Slack", let team = fields["team_id"] as? String { return slackTeams.contains(team) }
            if row.source == "Calendar", let account = fields["account"] as? String {
                return emails.contains { $0.caseInsensitiveCompare(account) == .orderedSame }
            }
            return false
        }
    }

    struct Part: Sendable {
        var rows: [DesktopFeedRow] = []
        var count: Int? = 0
        var incomplete = false
        var unavailableAccounts: Set<String>? = nil
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
            func retain(_ part: Part, _ saved: Part?) -> Part {
                guard part.incomplete || part.count == nil, let saved else { return part }
                var result = part
                let fresh = Set(part.rows.map(\.id))
                result.rows += saved.rows.filter { row in
                    guard !fresh.contains(row.id) else { return false }
                    guard let accounts = part.unavailableAccounts else { return true }
                    return row.selection.map { accounts.contains($0.account.lowercased()) } ?? false
                }
                result.count = max(part.count ?? 0, saved.count ?? result.rows.count)
                result.incomplete = true
                return result
            }
            next.mail = retain(mail, previous?.mail)
            next.slack = retain(slack, previous?.slack)
            next.calendar = retain(calendar, previous?.calendar)
            return next
        }

        func restricted(to context: Context) -> Snapshot {
            func restrict(_ part: Part) -> Part {
                let rows = part.rows.filter(context.allows)
                return .init(rows: rows, count: rows.count == part.rows.count ? part.count : rows.count,
                             incomplete: part.incomplete)
            }
            return .init(mail: restrict(mail), slack: restrict(slack), calendar: restrict(calendar), sections: context.sections)
        }

        static func visible(_ rows: [DesktopFeedRow]) -> Snapshot {
            func part(_ source: String) -> Part {
                let rows = rows.filter { $0.source == source }
                return .init(rows: rows, count: rows.count)
            }
            return .init(mail: part("Email"), slack: part("Slack"), calendar: part("Calendar"))
        }
    }

    @Published var snapshot: Snapshot?
    @Published var refreshing = false
    private var context: Context?
    private var lastAttempt: Date?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var removedDuringRefresh = Set<MailSelection>()
    private var trace: VoiceDiagnostics.Session?
    private let load: @Sendable (Context) async -> Snapshot
    static let refreshInterval: TimeInterval = 120

    init(load: @escaping @Sendable (Context) async -> Snapshot = { await DesktopFeedPreviewLoader.load($0) }) {
        self.load = load
    }

    func update(context: Context?, inSession: Bool, now: Date = Date(), force: Bool = false,
                hydratingOwner: String? = nil, hydratingProfile: String? = nil) {
        if context == nil, let hydratingOwner, self.context?.userID == hydratingOwner,
           hydratingProfile == nil || self.context?.profileID == hydratingProfile {
            pause()
            return
        }
        if self.context != context {
            let retain = context?.sharesOwner(with: self.context) == true
            pause()
            if !retain {
                record("clear", ["reason": context == nil ? "signed_out" : "owner_or_profile_changed"])
                trace = context.map { Container.shared.voiceDiagnostics().begin(engine: "desktop_feed", userID: $0.userID) }
            }
            self.context = context
            snapshot = retain ? context.flatMap { snapshot?.restricted(to: $0) } : nil
        }
        guard let context else { return }
        guard !inSession else { pause(); return }
        guard task == nil, force || (lastAttempt.map({ now.timeIntervalSince($0) >= Self.refreshInterval }) ?? true) else { return }
        lastAttempt = now
        refreshing = true
        let request = UUID()
        generation = request
        removedDuringRefresh = []
        record("started", ["request_id": request.uuidString, "reason": force ? "manual" : "periodic_or_open"])
        task = Task { [weak self, load] in
            var requestContext = context
            requestContext.forceRefresh = force
            let result = await load(requestContext)
            guard let self else { return }
            guard !Task.isCancelled, self.generation == request, self.context == context else {
                self.record("discarded", ["request_id": request.uuidString, "reason": "superseded"])
                return
            }
            var next = result.retainingUnavailable(from: self.snapshot)
            let removed = next.mail.rows.filter { row in row.selection.map { self.removedDuringRefresh.contains($0) } ?? false }.count
            next.mail.rows.removeAll { row in row.selection.map { self.removedDuringRefresh.contains($0) } ?? false }
            if let count = next.mail.count { next.mail.count = max(next.mail.rows.count, count - removed) }
            self.recordChange(from: self.snapshot?.rows ?? [], to: next.rows, request: request)
            self.snapshot = next
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

    func seed(_ value: Snapshot, context: Context) {
        guard context.sharesOwner(with: self.context) else { return }
        pause()
        snapshot = value.restricted(to: context)
        record("retained", ["reason": "session_ended"])
    }

    func record(_ phase: String, _ fields: [String: String] = [:]) {
        var fields = fields
        fields["phase"] = phase
        fields["sidebar_source"] = "preview"
        trace?.record(.feedRefresh, fields)
    }

    func recordSession(_ phase: String, feed: DesktopSessionFeed) {
        guard let trace else { return }
        trace.record(.feedRefresh, ["phase": phase, "sidebar_source": "session",
            "queue_revision": String(feed.revision), "visible_count": String(feed.rows.count),
            "queue_order": feed.rows.map { trace.target($0.id) }.joined(separator: ","),
            "target_hash": feed.current.map { trace.target($0.canonical) } ?? "none"])
    }

    private func recordChange(from old: [DesktopFeedRow], to new: [DesktopFeedRow], request: UUID) {
        guard let trace else { return }
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let next = Set(new.map(\.id))
        record("applied", ["request_id": request.uuidString, "visible_count": String(new.count),
            "queue_order": new.map { trace.target($0.id) }.joined(separator: ","),
            "inserted_count": String(new.filter { previous[$0.id] == nil }.count),
            "updated_count": String(new.filter { previous[$0.id] != nil && previous[$0.id] != $0 }.count),
            "removed_count": String(old.filter { !next.contains($0.id) }.count)])
    }

    func remove(_ selection: MailSelection) {
        if task != nil { removedDuringRefresh.insert(selection) }
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
        result.unavailableAccounts = []
        var answered = 0
        let sections = context.sections ?? FeedSection.resolved(nil, accounts: context.emails)
        let accounts = context.emails.filter { account in sections.contains { $0.isMail && $0.enabled && $0.account?.lowercased() == account.lowercased() } }
        let store = await MainActor.run { Container.shared.mailStore() }
        for account in accounts {
            guard !Task.isCancelled else { return .unavailable }
            guard case .success(let token) = await GoogleCredential.token(for: account) else {
                result.incomplete = true
                result.unavailableAccounts?.insert(account.lowercased())
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
                if details.count != refs.count {
                    result.incomplete = true
                    result.unavailableAccounts?.insert(account.lowercased())
                }
                let byID = Dictionary(details.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                guard let importantIDs = await store.importantFeedIDs(among: refs.map(\.id), account: account) else {
                    result.incomplete = true
                    result.unavailableAccounts?.insert(account.lowercased())
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
                result.unavailableAccounts?.insert(account.lowercased())
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
