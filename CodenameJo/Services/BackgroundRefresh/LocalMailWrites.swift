import Foundation
import FactoryKit

/// `archive_message`, `trash_message`, `mark_spam`, `label_message` and `count_messages`, run on the phone's own
/// Google grant. Receipts, refusals and failure sentences are load-bearing: the queue handlers and
/// `ArchiveReceiptPolicy` read them.
enum LocalMailWrites {
    static let names: Set<String> = ["archive_message", "trash_message", "mark_spam", "label_message", "count_messages"]

    typealias Refusal = GmailReadTools.Refusal
    private typealias Manage = GmailManageTools

    static let noMessageId = "No message id — search first, then act on a result."

    /// - Parameter defer: the caller advances on the receipt, so the Gmail call may land after it.
    static func run(name: String, argumentsJSON: String, defer deferred: Bool,
                    conversationId: String? = nil) async -> FullDuplexBroker.ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let started = Date()
        do {
            let result = name == "count_messages"
                ? try await count(args)
                : try await write(name, args, deferred: deferred, conversationId: conversationId)
            RealtimeLog.log("localMailWrites: \(name) \(result.ok == false ? "failed" : "ok") in "
                + "\(Int(Date().timeIntervalSince(started) * 1000))ms — \(result.text.prefix(80))")
            return result
        } catch let refusal as Refusal {
            RealtimeLog.log("localMailWrites: \(name) refused — \(refusal.text.prefix(120))")
            return .init(text: refusal.text, ok: false)
        } catch {
            RealtimeLog.log("localMailWrites: \(name) failed — \(error)")
            return .init(text: "The \(name) call failed: \(Manage.detail(error))", ok: false)
        }
    }

    // MARK: - count_messages

    /// The inbox label's own counter for the queue's two queries, a counted listing for any other.
    private static func count(_ args: [String: Any]) async throws -> FullDuplexBroker.ToolResult {
        let accounts = try GmailReadTools.targets(args)
        let query = GmailReadTools.string(args, "query") ?? ""
        let counted = await withTaskGroup(of: (Int, [String: Any]).self) { group in
            for (index, account) in accounts.enumerated() {
                group.addTask {
                    do {
                        let token = try await GmailReadTools.token(account)
                        let (count, atLeast) = try await (labelCounter(for: query) ?? { try await Manage.countUpTo($0, query: query, cap: 500) })(token)
                        return (index, ["account": account, "result": ["count": count, "atLeast": atLeast]])
                    } catch {
                        return (index, ["account": account, "error": Manage.detail(error)])
                    }
                }
            }
            var out: [(Int, [String: Any])] = []
            for await entry in group { out.append(entry) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return .init(text: GmailReadTools.json(counted), ok: nil)
    }

    /// Exact set equality on the terms, so a nearly-matching query never reads a counter.
    static func labelCounter(for query: String) -> (@Sendable (String) async throws -> (Int, Bool))? {
        let terms = Set(query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        if terms == ["in:inbox", "is:unread"] { return { (try await GmailAPI.inboxUnreadCount(token: $0), false) } }
        if terms == ["in:inbox"] { return { (try await GmailAPI.inboxTotalCount(token: $0), false) } }
        return nil
    }

    // MARK: - The four writes

    private static func write(_ name: String, _ given: [String: Any], deferred: Bool,
                              conversationId: String?) async throws -> FullDuplexBroker.ToolResult {
        var (args, accounts) = try await Manage.bind(name: name, given)
        if name == "label_message" { return try await label(args, accounts, deferred: deferred, conversationId: conversationId) }
        guard let messageId = GmailReadTools.string(args, "message_id") else { throw Refusal(text: noMessageId) }
        // A message lives in one mailbox, so which one to archive in is not a question to ask.
        if name == "archive_message", accounts.count > 1, let owner = await owner(of: messageId, among: accounts) {
            accounts = [owner]
            args["account"] = owner
        }
        let account = try Manage.single(accounts)
        if deferred {
            let pending = try await enqueue(name, account: account, messageId: messageId, conversationId: conversationId)
            return .init(text: queuedText[name] ?? "", ok: true, pendingArchive: pending)
        }

        let token = try await GmailReadTools.token(account)
        let effects = Manage.Effects()
        let run = { (id: String) async throws in
            switch name {
            case "archive_message":
                try await Manage.modifyThreadWide(token, account: account, id: id, add: [], remove: ["INBOX", "UNREAD"], effects)
            default:
                _ = try await Manage.modify(token, account: account, id: id,
                    add: [name == "mark_spam" ? "SPAM" : "TRASH"], remove: ["INBOX", "UNREAD"], effects)
            }
        }
        do {
            try await retryingDeadId(name, token: token, args: args, messageId: messageId, run)
        } catch {
            let threadStep = name == "archive_message" && !effects.list.isEmpty
            // A throttled archive outside a call is still owed, so it gets a retry row.
            if name == "archive_message", case GmailAPI.Failure.throttled = error,
               let pending = try? await enqueue(name, account: account, messageId: messageId,
                    threadId: effects.list.first?.threadId, conversationId: conversationId,
                    delay: PendingMailWritePolicy.delay(attempt: 1)) {
                return .init(text: "Archiving. The archive is queued for background retry. Say exactly \"Archiving\" "
                    + "and continue; do not wait or claim it has finished.", ok: true, pendingArchive: pending)
            }
            return .init(text: failure(error, account: account, operation: name, threadStep: threadStep), ok: false,
                         effects: effects.list.isEmpty ? nil : effects.list)
        }
        return .init(text: receipt(name, account: account), ok: true, effects: effects.list)
    }

    private static let queuedText = [
        "archive_message": "Archived. The archive is queued durably; keep pending status internal and continue with "
            + "the next item without waiting.",
        "mark_spam": "The spam action is queued durably. Keep retry status internal and do not speak a spam receipt. "
            + "Follow the supplied queue state; do not advance it yourself.",
        "trash_message": "The move to Trash is queued durably. Follow the supplied queue state and do not advance again.",
    ]

    private static func receipt(_ name: String, account: String) -> String {
        switch name {
        case "archive_message": "Archived in \(account)."
        case "mark_spam": "Marked as spam in \(account)."
        default: "Deleted in \(account)."
        }
    }

    private static func enqueue(_ name: String, account: String, messageId: String, threadId: String? = nil,
                                conversationId: String?, delay: TimeInterval = 0) async throws -> PendingArchive {
        let userId = await MainActor.run { Container.shared.backend().userId ?? "" }
        let queue = Container.shared.pendingMailWrites()
        let pending = try await queue.enqueue(userId: userId, operation: name, account: account, messageId: messageId,
                                              threadId: threadId, conversationId: conversationId, delay: delay)
        queue.drainSoon(userId: userId)
        return pending
    }

    /// The first mailbox, in profile order, that holds the message. Nil when none answers.
    private static func owner(of messageId: String, among accounts: [String]) async -> String? {
        let found = await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, account) in accounts.enumerated() {
                group.addTask {
                    guard let token = try? await GmailReadTools.token(account) else { return (index, false) }
                    await GmailQuota.shared.spend(GmailQuota.Cost.get)
                    let held = (try? await GmailAPI.call("GET", path: "messages/\(messageId)",
                        query: ["format": "minimal", "fields": "id"], token: token)) != nil
                    return (index, held)
                }
            }
            var held: [Int] = []
            for await (index, ok) in group where ok { held.append(index) }
            return held.min()
        }
        return found.map { accounts[$0] }
    }

    /// A 404 retried once against the model's `search`, and logged when it lands.
    private static func retryingDeadId(_ name: String, token: String, args: [String: Any], messageId: String,
                                       _ run: (String) async throws -> Void) async throws {
        do {
            try await run(messageId)
        } catch GmailAPI.Failure.http(404) {
            guard let found = await Manage.findAgain(token, args: args, deadId: messageId) else {
                throw GmailAPI.Failure.http(404)
            }
            do {
                try await run(found)
            } catch {
                throw GmailAPI.Failure.http(404)
            }
            RealtimeLog.log("localMailWrites: \(name) recovered — \(messageId) was dead, acted on \(found) instead")
        }
    }

    // MARK: - label_message

    private static func label(_ args: [String: Any], _ accounts: [String], deferred: Bool,
                              conversationId: String?) async throws -> FullDuplexBroker.ToolResult {
        guard let label = GmailReadTools.string(args, "label") else {
            throw Refusal(text: "No label given — ask the user what to call it.")
        }
        if let reserved = Manage.systemLabelRefusal(label) { throw Refusal(text: reserved) }
        guard let messageId = GmailReadTools.string(args, "message_id") else { throw Refusal(text: noMessageId) }
        let account = try Manage.single(accounts)
        let token = try await GmailReadTools.token(account)
        let alsoArchive = strictJSONBool(args["also_archive"]) == true
        let byRule = !alsoArchive && StandingRule.archiveAfterLabel.isOn

        let labels = try await Manage.labels(token)
        let existing = labels.first { $0.name.lowercased() == label.lowercased() }
        if existing == nil, let refusal = similarRefusal(label, labels: labels, createNew: strictJSONBool(args["create_new"]) == true) {
            throw Refusal(text: refusal)
        }
        let name = existing?.name ?? label
        let receipt = alsoArchive || byRule
            ? "Labelled \"\(name)\" and archived in \(account)."
            : "Labelled \"\(name)\" in \(account)."

        let apply = { (effects: Manage.Effects) async throws in
            let labelId: String
            if let existing { labelId = existing.id } else { labelId = try await Manage.resolveLabel(token, label) }
            try await retryingDeadId("label_message", token: token, args: args, messageId: messageId) { id in
                let confirmed = try await Manage.modify(token, account: account, id: id, add: [labelId],
                    remove: (alsoArchive ? ["INBOX"] : []) + ["UNREAD"], effects)
                // A rule that cannot file is not a label that failed: the message stays in the inbox and comes round again.
                guard byRule, !confirmed.threadId.isEmpty else { return }
                do {
                    try await Manage.modifyThread(token, account: account, threadId: confirmed.threadId,
                                                  add: [], remove: ["INBOX", "UNREAD"], effects)
                } catch {
                    RealtimeLog.log("localMailWrites: archive after label failed — \(Manage.detail(error))")
                }
            }
        }

        guard deferred else {
            let effects = Manage.Effects()
            do {
                try await apply(effects)
            } catch {
                return .init(text: failure(error, account: account, operation: "label_message"), ok: false,
                             effects: effects.list.isEmpty ? nil : effects.list)
            }
            return .init(text: receipt, ok: true, effects: effects.list)
        }
        let accepted = Date()
        Task.detached {
            let effects = Manage.Effects()
            do {
                try await apply(effects)
                RealtimeLog.log("localMailWrites: deferred label landed \(Int(Date().timeIntervalSince(accepted) * 1000))ms after accept")
                let store = await MainActor.run { Container.shared.mailStore() }
                _ = await Container.shared.localTriage().applyConfirmedEffects(effects.list, store: store)
            } catch {
                Container.shared.localWriteNotices().push(failure(error, account: account, operation: "label_message"),
                                                          conversation: conversationId)
            }
        }
        return .init(text: receipt, ok: true, deferred: true)
    }

    /// No exact match: the user's own labels that look like it are offered back, unless a new one was asked for.
    static func similarRefusal(_ label: String, labels: [GmailManageTools.Label], createNew: Bool) -> String? {
        let normalize = { (value: String) in String(value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)) }
        let wanted = normalize(label)
        guard !wanted.isEmpty, !createNew else { return nil }
        let similar = labels.filter { $0.user && (normalize($0.name).contains(wanted) || wanted.contains(normalize($0.name))) }
        guard !similar.isEmpty else { return nil }
        let names = similar.map { "\"\($0.name)\"" }.joined(separator: ", ")
        return "No label exactly named \"\(label)\". Existing labels: \(names). Ask which one they mean before labelling."
    }

    // MARK: - Failure sentences

    /// What is still true when the write did not land.
    static func unchanged(_ operation: String) -> String {
        switch operation {
        case "trash_message": "the message is not in Trash"
        case "label_message": "the label was not applied"
        default: "the message is still in the inbox"
        }
    }

    /// A thread-level throttle on an archive says the thread was not fully archived.
    static func failure(_ error: Error, account: String, operation: String, threadStep: Bool = false) -> String {
        if operation == "archive_message", threadStep, case GmailAPI.Failure.throttled = error {
            return "\(GmailManageTools.throttled) The thread was not fully archived."
        }
        return GmailManageTools.unchangedRefusal(error, account: account, unchanged: unchanged(operation)).text
    }
}
