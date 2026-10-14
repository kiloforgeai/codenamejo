import Foundation

/// The in-app-only representation of the Feed stage Jo is speaking about. It contains no
/// actions and is never sent to the broker or Live Activity.
enum FeedFocus: Hashable, Sendable {
    case email(Email)
    case emailStatus(EmailStatus)
    case slack(Slack)
    case slackStatus(SlackStatus)
    case tip(Tip)
    /// Onboarding's draft of what Jo learned about the user; Jo speaks only some of it.
    case about([String])
    case calendar(CalendarState)
    case complete(Summary)

    struct Email: Hashable, Sendable {
        let sender: String
        let subject: String
        let snippet: String
        let account: String
        var position: Int
        var total: Int?

        var pageTotal: Int? {
            guard let total, total > 0 else { return nil }
            let pageEnd = ((max(position, 1) - 1) / LocalTriageQueue.pageSize + 1)
                * LocalTriageQueue.pageSize
            return min(pageEnd, max(total, position))
        }

        /// Gmail's receipt time, when the queue item carried one.
        var received: Date? = nil
        /// This message's place among queued messages from the same thread, when more than one.
        var threadIndex: Int? = nil
        var threadCount: Int? = nil
        var threadKind: String? = nil
        var threadMessageCount: Int? = nil
    }

    enum EmailStatus: Hashable, Sendable {
        case complete
        case empty
        case unavailable
    }

    /// The Slack conversation the device-walked Slack queue is on.
    struct Slack: Hashable, Sendable {
        struct Message: Hashable, Sendable {
            let from: String
            let text: String
        }

        let name: String
        let workspace: String
        /// The queue spans more than one workspace, so the name alone is ambiguous.
        let showsWorkspace: Bool
        let unread: Int
        /// The unread count is a floor.
        let more: Bool
        /// The latest few, oldest first.
        let messages: [Message]
        let position: Int
        let total: Int?
    }

    enum SlackStatus: Hashable, Sendable {
        case complete
        case stopped
    }

    struct Tip: Hashable, Sendable {
        let capability: String?
        let copy: String

        static let genericCopy = "A quick tip from Jo is ready."
    }

    enum CalendarState: Hashable, Sendable {
        case loading
        case agenda(events: [CalendarEvent], partial: Bool)
        case empty(partial: Bool)
        case unavailable
    }

    struct CalendarEvent: Hashable, Sendable {
        let id: String
        let account: String
        let title: String
        let location: String?
        let start: Date?
        let end: Date?
        let allDay: Bool
    }

    struct Summary: Hashable, Sendable {
        enum EmailResult: Hashable, Sendable {
            case notRun
            case reviewing
            case complete
            case empty
            case unavailable
        }

        enum CalendarResult: Hashable, Sendable {
            case notRun
            case pending
            case agenda(count: Int, partial: Bool)
            case empty(partial: Bool)
            case unavailable
        }

        enum SlackResult: Hashable, Sendable {
            case notRun
            case reviewing
            case complete
        }

        var email: EmailResult = .notRun
        var slack: SlackResult = .notRun
        var tipShown = false
        var calendar: CalendarResult = .notRun
    }

    var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }

    /// A stage with nothing left to show: the email pass finished, a tip or calendar answer landed,
    /// or the summary is up.
    var isSettled: Bool {
        switch self {
        case .email, .slack, .about, .calendar(.loading): return false
        case .emailStatus, .slackStatus, .tip, .calendar, .complete: return true
        }
    }
}

/// A deterministic reducer from queue/calendar data to presentation, independent of the
/// transcript so lagging narration can't make the card stale or advance it early.
struct FeedFocusTracker: Sendable {
    private(set) var focus: FeedFocus?
    private(set) var summary = FeedFocus.Summary()
    private var terminalResponsePending = false
    /// Only a queue's first step lists its workspaces.
    private var slackWorkspaceCount = 0

    var hasCalendarResult: Bool {
        switch focus {
        case .calendar(.agenda), .calendar(.empty), .calendar(.unavailable): return true
        default: return false
        }
    }

    @discardableResult
    mutating func reset() -> FeedFocus? {
        focus = nil
        summary = FeedFocus.Summary()
        slackWorkspaceCount = 0
        terminalResponsePending = false
        return focus
    }

    mutating func refreshEmailProgress(_ progress: LocalTriageQueue.Progress) -> FeedFocus? {
        guard case .email(var email) = focus,
              email.account.caseInsensitiveCompare(progress.account ?? "") == .orderedSame else { return focus }
        email.position = progress.displayPosition ?? progress.position
        email.total = progress.displayQueued ?? progress.queued
        focus = .email(email)
        return focus
    }

    /// Applies a device-owned `triage_next` result. Outcome-only results are excluded by
    /// the caller so an archive or draft receipt cannot replace the message being acted on.
    @discardableResult
    mutating func applyTriage(
        output: String,
        queuePosition: Int? = nil,
        queueTotal: Int? = nil,
        displayPosition: Int? = nil,
        displayTotal: Int? = nil
    ) -> FeedFocus? {
        guard let object = Self.object(from: output) else {
            return focus
        }

        if Self.bool(object["stopped"]) == true {
            focus = nil
            terminalResponsePending = false
            return focus
        }
        if let items = (object["about"] as? [String: Any])?["items"] as? [String], !items.isEmpty {
            focus = .about(items)
            return focus
        }
        if let item = object["item"] as? [String: Any] {
            let position = displayPosition ?? Self.int(object["position"]) ?? queuePosition ?? 1
            let email = FeedFocus.Email(
                sender: Self.string(item["from"], fallback: "Unknown sender"),
                subject: Self.string(item["subject"], fallback: "No subject"),
                snippet: Self.string(item["snippet"], fallback: ""),
                account: Self.string(item["account"], fallback: ""),
                position: position,
                total: displayTotal ?? queueTotal,
                received: Self.date(item["date"]),
                threadIndex: (object["thread"] as? [String: Any]).flatMap { Self.int($0["index"]) },
                threadCount: (object["thread"] as? [String: Any]).flatMap { Self.int($0["queued"]) },
                threadKind: (object["thread"] as? [String: Any])?["kind"] as? String,
                threadMessageCount: (object["thread"] as? [String: Any]).flatMap { Self.int($0["messageCount"]) }
            )
            summary.email = .reviewing
            terminalResponsePending = false
            focus = .email(email)
            return focus
        }

        let interstitial = object["interstitial"] as? String
        // Important Slack between the important mail and the rest: its first conversation.
        if interstitial == "slack", let slackStep = object["slackStep"] as? [String: Any] {
            applySlack(step: slackStep)
            return focus
        }
        guard interstitial == "feed" || interstitial == "page" else {
            // A stop, failed preparation, or ordinary non-Feed completion has no stage
            // that is safe to keep showing.
            if Self.bool(object["done"]) == true {
                focus = nil
                terminalResponsePending = false
            }
            return focus
        }

        terminalResponsePending = interstitial == "feed"
        let priorFocus = focus
        let queued = Self.int(object["queued"]) ?? queueTotal
        let emailStatus: FeedFocus.EmailStatus
        if queued == 0 || Self.bool(object["empty"]) == true {
            emailStatus = .empty
            if interstitial == "feed" { summary.email = .empty }
        } else {
            emailStatus = .complete
            if interstitial == "feed" { summary.email = .complete }
        }

        if Self.bool(object["calendarDue"]) == true,
           summary.calendar == .notRun {
            summary.calendar = .pending
        }

        if let coaching = object["coaching"] as? [String: Any] {
            let lesson = coaching["lesson"] as? [String: Any]
            if let lesson {
                focus = .tip(FeedFocus.Tip(
                    capability: lesson["capability"] as? String,
                    copy: Self.string(
                        lesson["copy"], fallback: FeedFocus.Tip.genericCopy)
                ))
                summary.tipShown = true
            } else {
                focus = interstitial == "page" ? priorFocus : .emailStatus(emailStatus)
            }
        } else {
            focus = interstitial == "page" ? priorFocus : .emailStatus(emailStatus)
        }
        if let slackStep = object["slackStep"] as? [String: Any] {
            applySlack(step: slackStep)
        }
        return focus
    }

    /// Applies a device-owned Slack queue step: `slack_triage_next`, or a finisher's receipt
    /// with the next step appended. Output without a step leaves the card where it is.
    @discardableResult
    mutating func applySlack(output: String) -> FeedFocus? {
        var candidates = [output]
        if let start = output.range(of: "\n{", options: .backwards) {
            candidates.append(String(output[output.index(after: start.lowerBound)...]))
        }
        guard let step = candidates.lazy.compactMap({ Self.object(from: $0) }).first else { return focus }
        applySlack(step: step)
        return focus
    }

    private mutating func applySlack(step: [String: Any]) {
        if Self.bool(step["stopped"]) == true {
            if summary.slack == .reviewing { summary.slack = .complete }
            focus = .slackStatus(.stopped)
            return
        }
        if let workspaces = step["workspaces"] as? [Any] { slackWorkspaceCount = workspaces.count }
        guard let item = step["item"] as? [String: Any] else {
            if Self.bool(step["done"]) == true {
                summary.slack = .complete
                focus = .slackStatus(.complete)
            }
            return
        }
        let messages = (item["messages"] as? [[String: Any]] ?? []).prefix(3).compactMap {
            message -> FeedFocus.Slack.Message? in
            let text = Self.string(message["text"], fallback: "")
            guard !text.isEmpty else { return nil }
            return FeedFocus.Slack.Message(from: Self.string(message["from"], fallback: "Someone"), text: text)
        }
        summary.slack = .reviewing
        focus = .slack(FeedFocus.Slack(
            name: Self.string(item["name"], fallback: "Slack"),
            workspace: Self.string(item["workspace"], fallback: ""),
            showsWorkspace: slackWorkspaceCount > 1,
            unread: Self.int(item["unread"]) ?? 0,
            more: Self.bool(item["more"]) ?? false,
            messages: messages.reversed(),
            position: Self.int(step["position"]) ?? 1,
            total: Self.int(step["queued"])
        ))
    }

    @discardableResult
    mutating func calendarLoading() -> FeedFocus? {
        switch focus {
        case .calendar(.agenda), .calendar(.empty), .calendar(.unavailable):
            return focus
        default:
            break
        }
        summary.calendar = .pending
        focus = .calendar(.loading)
        return focus
    }

    @discardableResult
    mutating func calendarResult(
        events: [FeedFocus.CalendarEvent],
        successful: Bool,
        partial: Bool = false,
        merging: Bool = false
    ) -> FeedFocus? {
        let existingEvents: [FeedFocus.CalendarEvent]
        let alreadySucceeded: Bool
        let alreadyPartial: Bool
        if merging {
            switch focus {
            case .calendar(.agenda(let events, let partial)):
                existingEvents = events
                alreadySucceeded = true
                alreadyPartial = partial
            case .calendar(.empty(let partial)):
                existingEvents = []
                alreadySucceeded = true
                alreadyPartial = partial
            case .calendar(.unavailable):
                existingEvents = []
                alreadySucceeded = false
                alreadyPartial = true
            default:
                existingEvents = []
                alreadySucceeded = false
                alreadyPartial = false
            }
        } else {
            existingEvents = []
            alreadySucceeded = false
            alreadyPartial = false
        }

        guard successful else {
            if alreadySucceeded {
                let isPartial = true
                if existingEvents.isEmpty {
                    summary.calendar = .empty(partial: isPartial)
                    focus = .calendar(.empty(partial: isPartial))
                } else {
                    summary.calendar = .agenda(count: existingEvents.count, partial: isPartial)
                    focus = .calendar(.agenda(events: existingEvents, partial: isPartial))
                }
                return focus
            }
            summary.calendar = .unavailable
            focus = .calendar(.unavailable)
            return focus
        }
        let ordered = Self.ordered(existingEvents + events)
        let isPartial = partial || alreadyPartial
        if ordered.isEmpty {
            summary.calendar = .empty(partial: isPartial)
            focus = .calendar(.empty(partial: isPartial))
        } else {
            summary.calendar = .agenda(count: ordered.count, partial: isPartial)
            focus = .calendar(.agenda(events: ordered, partial: isPartial))
        }
        return focus
    }

    /// Parses the broker fallback result when the device calendar search could not answer. A row
    /// with events is a success; an error-only row keeps empty distinct from unavailable.
    @discardableResult
    mutating func calendarMCPResult(_ output: String) -> FeedFocus? {
        guard let result = Self.calendarMCPData(from: output) else {
            return calendarResult(events: [], successful: false)
        }
        return calendarResult(
            events: result.events,
            successful: result.successfulAccounts > 0,
            partial: result.failedAccounts > 0 && result.successfulAccounts > 0
        )
    }

    @discardableResult
    mutating func finishTerminalResponse() -> FeedFocus? {
        guard terminalResponsePending else { return focus }
        terminalResponsePending = false
        if summary.email == .reviewing { summary.email = .complete }
        focus = .complete(summary)
        return focus
    }

    /// The user spoke after a stage settled, so they have moved on; the card goes with them.
    @discardableResult
    mutating func dismissSettled() -> FeedFocus? {
        guard focus?.isSettled == true else { return focus }
        focus = nil
        terminalResponsePending = false
        return focus
    }

    static func event(_ event: CalendarStore.Event) -> FeedFocus.CalendarEvent {
        FeedFocus.CalendarEvent(
            id: event.id,
            account: event.account,
            title: event.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "Untitled event",
            location: Self.optionalString(event.location),
            start: event.startEpochMs.map { Date(timeIntervalSince1970: Double($0) / 1_000) },
            end: event.endEpochMs.map { Date(timeIntervalSince1970: Double($0) / 1_000) },
            allDay: event.isAllDay
        )
    }

    // MARK: - Parsing

    private static func object(from output: String) -> [String: Any]? {
        guard let data = output.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func calendarMCPData(
        from output: String
    ) -> (events: [FeedFocus.CalendarEvent], successfulAccounts: Int, failedAccounts: Int)? {
        guard let data = output.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return nil }

        var events: [FeedFocus.CalendarEvent] = []
        var successfulAccounts = 0
        var failedAccounts = 0
        for row in rows {
            if let error = row["error"], !(error is NSNull) {
                failedAccounts += 1
                continue
            }
            guard let rawEvents = row["events"] as? [[String: Any]] else {
                failedAccounts += 1
                continue
            }
            successfulAccounts += 1
            let account = string(row["account"], fallback: "")
            for raw in rawEvents {
                let startRaw = raw["start"] as? String
                let endRaw = raw["end"] as? String
                let title = string(raw["summary"], fallback: "Untitled event")
                let id = string(
                    raw["id"], fallback: "\(account)|\(title)|\(startRaw ?? "unknown")")
                let allDay = bool(raw["allDay"]) == true
                    || (startRaw?.count == 10 && startRaw?.contains("T") == false)
                events.append(FeedFocus.CalendarEvent(
                    id: id,
                    account: string(raw["account"], fallback: account),
                    title: title,
                    location: optionalString(raw["location"] as? String),
                    start: date(from: startRaw),
                    end: date(from: endRaw),
                    allDay: allDay
                ))
            }
        }
        return (ordered(events), successfulAccounts, failedAccounts)
    }

    private static func ordered(
        _ events: [FeedFocus.CalendarEvent]
    ) -> [FeedFocus.CalendarEvent] {
        var seen = Set<String>()
        return events
            .sorted {
                switch ($0.start, $1.start) {
                case let (left?, right?): return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return $0.title < $1.title
                }
            }
            .filter { seen.insert("\($0.account)|\($0.id)").inserted }
    }

    private static func date(from raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        guard raw.count == 10 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }

    private static func string(_ value: Any?, fallback: String) -> String {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return fallback }
        return value
    }

    private static func optionalString(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
