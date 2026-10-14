import Foundation
import FactoryKit

/// The Slack queue walked on the phone: `slack_triage_next` and its five finishers.
/// One instance, so there is one cursor.
actor LocalSlackQueue {
    static let finishingTools: Set<String> = [
        "slack_send_message", "slack_add_reaction", "slack_schedule_message",
        "slack_mark_read", "slack_mark_unread",
    ]
    /// The reads declared beside them; they never move the cursor.
    static let readTools = SlackTools.readNames
    static let marksRead: Set<String> = ["slack_send_message", "slack_add_reaction", "slack_schedule_message"]
    static let actedAs: [String: String] = [
        "slack_send_message": "replied", "slack_add_reaction": "reacted",
        "slack_schedule_message": "scheduled a reply", "slack_mark_read": "marked read",
        "slack_mark_unread": "left unread",
    ]
    /// A snapshot older than this is rebuilt before the first step is served.
    static let servingFreshness: TimeInterval = 10 * 60
    /// A queue call this soon after an inline advance is an echo.
    static let inlineEchoWindow: TimeInterval = 3

    struct Answer: Sendable {
        let text: String
        /// The queue closed with this answer — finished, stopped, or empty.
        let closed: Bool
    }

    private var queue: SlackQueueSnapshot?
    private var position = 0
    private var advancedInlineAt: Date?
    private var notices: [String] = []
    /// Running the important-Slack stage mid mail walk: its close hands back to the email.
    private var importantStage = false
    /// Conversations the important stage already walked this call, per profile, so the
    /// Feed's Slack stage holds only the rest.
    private var walked: [String: Set<String>] = [:]

    var isRunning: Bool { queue != nil }

    func end() {
        queue = nil
        position = 0
        advancedInlineAt = nil
        notices = []
        importantStage = false
    }

    /// A new call: nothing has been walked yet.
    func beginCall() {
        end()
        walked = [:]
    }

    /// Install the important slice and return its first step, the way `terminalFeed` opens the
    /// Slack stage inline. Its conversations are left out of this call's later Slack stage.
    func startImportant(_ snapshot: SlackQueueSnapshot) -> Answer {
        start(snapshot)
        importantStage = true
        walked[SlackQueueRefresh.profileKey(), default: []]
            .formUnion(snapshot.items.map(Self.walkKey))
        var payload = stepObject()
        payload["started"] = true
        payload["total"] = snapshot.total
        payload["workspaces"] = snapshot.workspaces
        payload["report"] = Self.reportObject(snapshot.report)
        return Answer(text: Self.json(payload), closed: false)
    }

    /// How many conversations in `snapshot` the important stage has not already walked.
    func unwalkedCount(_ snapshot: SlackQueueSnapshot?) -> Int {
        guard let snapshot else { return 0 }
        return unwalked(snapshot).items.count
    }

    private func unwalked(_ snapshot: SlackQueueSnapshot) -> SlackQueueSnapshot {
        guard let done = walked[SlackQueueRefresh.profileKey()], !done.isEmpty else { return snapshot }
        var rest = snapshot
        rest.items.removeAll { done.contains(Self.walkKey($0)) }
        return rest
    }

    private static func walkKey(_ item: SlackQueueSnapshot.Item) -> String {
        "\(item.teamId):\(item.channelId)"
    }

    /// Appended to every close of the important stage: the mail walk resumes, not the Feed.
    static let backToEmailNote = " This was the Slack waiting on them before the rest of the "
        + "email: call triage_next in this same response and present the next email. Do not ask "
        + "the Feed's wrap-up question."

    /// Install a queue at its first conversation. The step path's own start, and the tests'.
    func start(_ snapshot: SlackQueueSnapshot) {
        queue = snapshot
        position = 1
        advancedInlineAt = nil
        notices = []
    }

    // MARK: - slack_triage_next

    func step(direction: String?, restart: Bool, stop: Bool, now: Date = Date()) async -> Answer {
        if stop {
            guard let queue else { return Answer(text: Self.renderStop(remaining: nil), closed: true) }
            let remaining = queue.items.count - (position - 1)
            RealtimeLog.log("slackQueue: stopped at \(position) of \(queue.items.count)")
            let resume = importantStage ? Self.backToEmailNote : ""
            end()
            return Answer(text: Self.renderStop(remaining: max(0, remaining)) + resume, closed: true)
        }

        let starting = restart || queue == nil
        if starting {
            guard let loaded = await load(forceRefresh: restart) else {
                end()
                return Answer(
                    text: "No Slack workspace is connected and working in this profile. Say so plainly in one "
                        + "sentence and, if they want Slack, that it is connected in Settings; do not guess what is waiting there.",
                    closed: true)
            }
            start(loaded)
            if loaded.items.isEmpty {
                end()
                return Answer(text: Self.json([
                    "started": true, "total": 0, "queued": 0, "empty": true,
                    "workspaces": loaded.workspaces, "report": Self.reportObject(loaded.report),
                    "note": Self.emptyNote,
                ]), closed: true)
            }
        } else if let movedAt = advancedInlineAt {
            advancedInlineAt = nil
            let gap = now.timeIntervalSince(movedAt)
            if direction != "back", gap >= 0, gap < Self.inlineEchoWindow {
                RealtimeLog.log("slackQueue: slack_triage_next \(Int(gap * 1000))ms after an inline advance — suppressed")
                return Answer(text: renderEcho(), closed: false)
            }
            moveCursor(direction)
        } else {
            moveCursor(direction)
        }

        guard let queue else { return Answer(text: Self.renderStop(remaining: nil), closed: true) }
        var payload = stepObject()
        if !notices.isEmpty {
            payload["heardSince"] = notices.joined(separator: " ")
            notices = []
        }
        if payload["done"] as? Bool == true {
            payload["note"] = Self.closeNote(payload) + (importantStage ? Self.backToEmailNote : "")
            end()
            return Answer(text: Self.json(payload), closed: true)
        }
        if starting {
            payload["started"] = true
            payload["total"] = queue.total
            payload["workspaces"] = queue.workspaces
            payload["report"] = Self.reportObject(queue.report)
        }
        return Answer(text: Self.json(payload), closed: false)
    }

    /// The conversation the cursor is on, as a step payload, without moving it.
    func currentStep() -> String { Self.json(stepObject()) }

    // MARK: - Finishers

    /// Where a reply or reaction on the current conversation should also clear its badge.
    func markTarget(input: [String: Any]) -> SlackTools.MarkTarget? {
        guard let item = current, isCurrent(input: input, resolvedChannel: nil),
              let ts = item.messages.first?.ts else { return nil }
        return SlackTools.MarkTarget(teamId: item.teamId, channelId: item.channelId, ts: ts)
    }

    /// Advance past the current conversation after a write on it. Nil when nothing moved: the
    /// write failed, or it was about another conversation.
    func finish(
        tool: String, input: [String: Any], written: Bool, channel: String?, markedRead: Bool?,
        now: Date = Date()
    ) -> Answer? {
        guard Self.finishingTools.contains(tool), written, var item = current,
              isCurrent(input: input, resolvedChannel: channel) else { return nil }
        item.acted = Self.actedAs[tool] ?? tool
        if let markedRead {
            item.markedRead = markedRead
        }
        if Self.marksRead.contains(tool), markedRead == false {
            notices.append("\(item.label) could not be marked read in Slack, so it is still "
                + "showing unread — say so in a clause.")
        }
        queue?.items[position - 1] = item
        let from = position
        moveCursor("forward")
        advancedInlineAt = now

        let step = stepObject()
        let said = notices
        notices = []
        let done = step["done"] as? Bool == true
        RealtimeLog.log("slackQueue: \(from) → \(done ? "closed" : "\(position)") inline after \(tool)")
        let text = Self.renderInlineAdvance(step, notices: said)
            + (done && importantStage ? Self.backToEmailNote : "")
        if done { end() }
        return Answer(text: text, closed: done)
    }

    // MARK: - Feed

    // MARK: - Internals

    private var current: SlackQueueSnapshot.Item? {
        guard let queue, position >= 1, position <= queue.items.count else { return nil }
        return queue.items[position - 1]
    }

    private func moveCursor(_ direction: String?) {
        position = direction == "back" ? max(1, position - 1) : position + 1
    }

    private func isCurrent(input: [String: Any], resolvedChannel: String?) -> Bool {
        guard let item = current else { return false }
        let given = (input["channel_id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let resolved = resolvedChannel?.trimmingCharacters(in: .whitespaces) ?? ""
        return (!given.isEmpty && (given == item.channelId || given == item.withUserId))
            || (!resolved.isEmpty && resolved == item.channelId)
    }

    private func load(forceRefresh: Bool) async -> SlackQueueSnapshot? {
        if !forceRefresh, let stored = await SlackQueueRefresh.cached(),
           Date().timeIntervalSince(stored.generatedAt) < Self.servingFreshness, let queue = stored.queue {
            return unwalked(queue)
        }
        guard let fresh = await SlackQueueRefresh.fetch(trigger: forceRefresh ? "restart" : "stale") else {
            return nil
        }
        return fresh.queue.map(unwalked) ?? .empty
    }

    /// The step payload at the cursor.
    private func stepObject() -> [String: Any] {
        guard let queue else { return [:] }
        let queued = queue.items.count
        guard let item = current else {
            let acted = queue.items.filter { $0.acted != nil }.count
            let markedRead = queue.items.filter { $0.markedRead == true }.count
            return ["done": true, "queued": queued, "acted": acted, "passed": queued - acted,
                    "markedRead": markedRead, "stillUnread": queued - markedRead]
        }
        var object: [String: Any] = [
            "workspace": item.teamName, "channel_id": item.channelId, "name": item.label,
            "kind": item.kind, "unread": item.unread, "more": item.more, "why": item.why,
            "messages": item.messages.map { message -> [String: Any] in
                var m: [String: Any] = ["from": message.from, "ts": message.ts, "text": message.text]
                if let fromId = message.fromId { m["fromId"] = fromId }
                if let threadTs = message.threadTs { m["threadTs"] = threadTs }
                if let replies = message.replies { m["replies"] = replies }
                return m
            },
        ]
        if let withUserId = item.withUserId { object["with_user_id"] = withUserId }
        if let acted = item.acted { object["alreadyDone"] = acted }
        return ["done": false, "position": position, "queued": queued,
                "remaining": queued - (position - 1), "item": object]
    }

    private func renderEcho() -> String {
        var step = stepObject()
        guard step["done"] as? Bool != true else { return Self.json(step) }
        step["repeat"] = true
        step["note"] = "This is the conversation you were just handed with the action — the cursor has "
            + "not moved. If you have already said what's in it, say nothing more and wait for "
            + "the user. If they have just asked for the next one, call slack_triage_next once "
            + "more and it will move."
        return Self.json(step)
    }

    // MARK: - The notes

    static let emptyNote = "Nothing came back unread. Say Slack is quiet in one sentence — and if anything in "
        + "`report` is non-zero, say that part honestly rather than folding it into the total: "
        + "conversations you could not check are not conversations you know are clear."

    static func stillUnreadNote(markedRead: Int, stillUnread: Int) -> String {
        if markedRead == 0 {
            return "Say plainly that they are all still showing as unread in Slack — going through "
                + "them here does not mark anything read."
        }
        if stillUnread == 0 {
            return "Every one of them is marked read in Slack now, so say that — their badges are "
                + "actually clear. Do not add a caveat about anything still being unread."
        }
        return "Say both numbers: \(markedRead) marked read in Slack, \(stillUnread) still showing "
            + "as unread. Do not round that up into one reassuring clause — the ones they passed "
            + "over are exactly where they were."
    }

    static func closeNote(_ step: [String: Any]) -> String {
        "The queue is finished. Tell them you are through them and what you did, in one "
            + "sentence. Don't list the conversations again. "
            + stillUnreadNote(markedRead: step["markedRead"] as? Int ?? 0,
                              stillUnread: step["stillUnread"] as? Int ?? 0)
            + " If they ask about Slack again, start a new queue — this one is closed."
    }

    static func renderInlineAdvance(_ step: [String: Any], notices: [String]) -> String {
        let said = notices.isEmpty ? "" : " " + notices.joined(separator: " ")
        let queued = step["queued"] as? Int ?? 0
        if step["done"] as? Bool == true {
            return "\n\nQueue: that was the last of \(queued). The queue is closed — do NOT call "
                + "slack_triage_next. Tell them you are through them and what you did, in one "
                + "sentence, and don't list the conversations again. "
                + stillUnreadNote(markedRead: step["markedRead"] as? Int ?? 0,
                                  stillUnread: step["stillUnread"] as? Int ?? 0)
                + " If they ask about Slack again, start a new queue.\(said)\n" + json(step)
        }
        let position = step["position"] as? Int ?? 0
        let remaining = step["remaining"] as? Int ?? 0
        return "\n\nQueue: that was \(position - 1) of \(queued), \(remaining) left. "
            + "The next conversation is below — say what's new in it now, in this same turn, in a "
            + "sentence or two, and end on the question. Do NOT call slack_triage_next in this "
            + "turn: this result is its answer, and calling it now walks them past a conversation "
            + "they never heard. That applies to this turn only — from the user's next reply the "
            + "queue is ordinary again, so anything carrying no decision about this conversation "
            + "means call slack_triage_next, and do not read this conversation out a second time "
            + "while you wait to be asked.\(said)\n" + json(step)
    }

    static func renderStop(remaining: Int?) -> String {
        guard let remaining else {
            return json([
                "stopped": false,
                "note": "There was no Slack queue running, so nothing was stopped. Answer whatever they "
                    + "actually asked and say nothing about a queue — telling them you have stopped "
                    + "something that was not running reads as a mistake.",
            ])
        }
        return json([
            "stopped": true, "remaining": remaining,
            "note": "The queue is closed and the row is gone. Say you have stopped and that \(remaining) "
                + "conversations are still unread, in ONE sentence, then drop it. Do NOT argue, do "
                + "NOT ask if they are sure, do NOT try to land one more, and do NOT offer to carry "
                + "on. Nothing will bring this queue back on its own now — if they ask about Slack "
                + "later, call slack_triage_next again and it starts a fresh one.",
        ])
    }

    private static func reportObject(_ report: SlackQueueSnapshot.Report) -> [String: Any] {
        var object: [String: Any] = [
            "unchecked": report.unchecked, "unreachable": report.unreachable,
            "readStateUnknown": report.readStateUnknown,
        ]
        if let unavailable = report.workspacesUnavailable, !unavailable.isEmpty {
            object["workspacesUnavailable"] = unavailable
        }
        if report.dmsUnavailable == true { object["dmsUnavailable"] = true }
        if report.markUnavailable == true { object["markUnavailable"] = true }
        return object
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
