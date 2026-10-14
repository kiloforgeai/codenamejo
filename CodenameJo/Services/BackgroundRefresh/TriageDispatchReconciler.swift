import Foundation

/// How a dispatched cleanup is matched against the queue and reconciled once it lands: what a task's
/// wording sweeps, which messages a sweep covers, and which Gmail effects a receipt proves.
/// Stateless; `LocalTriageQueue` applies the result to the walk.
enum TriageDispatchReconciler {
    typealias Item = LocalTriageQueue.Item

    /// Is this message from one of these senders? An exact address match, or a host/subdomain match
    /// against a bare domain.
    static func sentBy(_ from: String, _ senders: [String]) -> Bool {
        let address = addressIn(from)
        guard let at = address.firstIndex(of: "@") else { return false }
        let host = String(address[address.index(after: at)...])
        return senders.contains { sender in
            sender.contains("@") ? address == sender : host == sender || host.hasSuffix(".\(sender)")
        }
    }

    /// The address out of `Name <addr>` (or the string itself when already bare), lowercased.
    static func addressIn(_ raw: String) -> String {
        let stripped: String
        if let range = raw.range(of: #"<([^>]+)>"#, options: .regularExpression) {
            stripped = String(raw[range].dropFirst().dropLast())
        } else {
            stripped = raw
        }
        return stripped.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Does this dispatched task's own wording clear a whole sender out of the inbox?
    static func sweepsTheSender(_ task: String) -> Bool {
        let said = task.lowercased()
        let unsubscribeLeavesExisting = said.range(
            of: #"\bclear_existing\s+false\b"#, options: .regularExpression
        ) != nil
        if said.range(of: #"\bunsubscrib\w*\b"#, options: .regularExpression) != nil,
           !unsubscribeLeavesExisting { return true }
        guard said.range(
            of: #"\b(all|every|everything|each|the rest|the lot)\b"#, options: .regularExpression
        ) != nil else { return false }
        if said.range(of: #"\b(archiv\w*|clear\w*|tidy|junk)\b"#, options: .regularExpression) != nil {
            return true
        }
        return said.range(of: #"\b(as|to) spam\b"#, options: .regularExpression) != nil
    }

    struct DispatchSweepScope: Equatable, Sendable {
        let sender: String
        let category: GmailMailCategory?
    }

    struct DispatchPrunePlan: Equatable, Sendable {
        let ids: Set<String>
        let usesSenderFallback: Bool
    }

    struct DispatchCleanupScope: Decodable, Sendable {
        let messageId: String
        let query: String
        enum CodingKeys: String, CodingKey { case messageId = "message_id", query }
    }

    /// Queue removal follows explicit tool arguments, not punctuation in a worker's prose.
    /// Require a known source message, the selected mailbox and a simple positive scope.
    static func validatedCleanupQuery(_ scope: DispatchCleanupScope, account: String, items: [Item]) -> String? {
        let terms = scope.query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard (2...3).contains(terms.count), Set(terms).count == terms.count,
              terms.filter({ $0 == "in:inbox" }).count == 1,
              let from = terms.first(where: { $0.hasPrefix("from:") }),
              terms.filter({ $0.hasPrefix("from:") }).count == 1,
              from.range(of: #"^from:[a-z0-9._%+-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil,
              terms.allSatisfy({ $0 == "in:inbox" || $0 == from || ["category:promotions", "category:purchases"].contains($0) }),
              let source = items.first(where: { $0.account.lowercased() == account.lowercased() && $0.holds(scope.messageId) }),
              let sender = source.conversation.first(where: { $0.id == scope.messageId })?.from,
              addressIn(sender) == String(from.dropFirst(5)) else { return nil }
        return terms.joined(separator: " ")
    }

    static func dispatchPrunePlan(
        category: GmailMailCategory?, cachedIDs: [String]?, enrichedIDs: [String]
    ) -> DispatchPrunePlan {
        let ids = Set(cachedIDs ?? []).union(enrichedIDs)
        return DispatchPrunePlan(
            ids: ids,
            usesSenderFallback: category == nil && ids.isEmpty)
    }

    /// Prefer the generated category query; generic sender cleanups use the sending host.
    static func dispatchSweepScope(task: String, currentFrom: String) -> DispatchSweepScope? {
        guard sweepsTheSender(task) else { return nil }
        let said = task.lowercased()
        let explicitSender = said.range(
            of: #"\bfrom:(?:[a-z0-9._%+-]+@)?[a-z0-9-]+(?:\.[a-z0-9-]+)+"#,
            options: .regularExpression
        ).map { String(said[$0].dropFirst("from:".count)) }
        let category: GmailMailCategory? = {
            guard let range = said.range(
                of: #"\bcategory:(promotions|purchases|reservations|updates|social|forums)\b"#,
                options: .regularExpression)
            else { return nil }
            return GmailMailCategory(rawValue: String(said[range].dropFirst("category:".count)))
        }()
        if let explicitSender {
            return DispatchSweepScope(sender: explicitSender, category: category)
        }

        let address = addressIn(currentFrom)
        guard let at = address.firstIndex(of: "@") else { return nil }
        let host = String(address[address.index(after: at)...])
        return host.isEmpty ? nil : DispatchSweepScope(sender: host, category: nil)
    }

    static func dispatchSweepScope(task: String, item: Item) -> DispatchSweepScope? {
        let said = task.lowercased()
        if said.contains("from:") { return dispatchSweepScope(task: task, currentFrom: "") }
        let namesOnly = said.replacingOccurrences(of: #"\S*@\S*"#, with: " ", options: .regularExpression)
        let senders = Set(item.conversation.map(\.from))
        let named = senders.filter { sender in
            let name = LocalTriageQueue.spokenSender(sender).lowercased()
            let address = addressIn(sender)
            let addressPattern = "(?<![a-z0-9.!#$%&'*+/=?^_`{|}~@-])"
                + NSRegularExpression.escapedPattern(for: address) + "(?![a-z0-9.@-])"
            let namePattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b"
            return (!address.isEmpty && said.range(of: addressPattern, options: .regularExpression) != nil)
                || (!name.isEmpty && namesOnly.range(of: namePattern, options: .regularExpression) != nil)
                || name.split(separator: " ").contains { part in
                    part.count > 2 && namesOnly.range(of: "\\b" + NSRegularExpression.escapedPattern(for: String(part)) + "\\b",
                                               options: .regularExpression) != nil
                }
        }
        if named.count == 1, let sender = named.first, sweepsTheSender(task) {
            return DispatchSweepScope(sender: addressIn(sender), category: nil)
        }
        guard Set(senders.map { addressIn($0) }).count == 1 else { return nil }
        return dispatchSweepScope(task: task, currentFrom: item.from)
    }

    struct DispatchReconciliation: Sendable {
        let lifetime: Int
        let account: String
        var sourceThread: String? = nil
    }

    /// The Gmail effects that succeeded archive, spam and trash receipts prove, read per account from
    /// Gmail and the cache. A thread counts as archived only if the cache still holds it in the inbox.
    static func archiveReceiptEffects(
        _ status: ArchiveRetryStatus, accounts: Set<String>, store: MailStore,
        archivedThreads: @Sendable (String, [String]) async -> Set<String>,
        spamMessages: @Sendable (String, [String]) async -> Set<String>,
        trashedMessages: @Sendable (String, [String]) async -> Set<String>
    ) async -> [GmailWriteEffect] {
        var effects: [GmailWriteEffect] = []
        for account in accounts {
            let jobs = (status.succeeded ?? []).filter { $0.account.lowercased() == account }
            let spamIDs = jobs.filter(\.isSpam).map(\.messageId)
            if !spamIDs.isEmpty {
                let confirmed = await spamMessages(account, spamIDs)
                effects += confirmed.map {
                    GmailWriteEffect(account: account, scope: "message", threadId: nil,
                        messageIds: [$0], messageIdsComplete: true, operation: "modify",
                        addLabelIds: ["SPAM"], removeLabelIds: ["INBOX"])
                }
            }
            let trashIDs = jobs.filter(\.isTrash).map(\.messageId)
            if !trashIDs.isEmpty {
                let confirmed = await trashedMessages(account, trashIDs)
                effects += confirmed.map {
                    GmailWriteEffect(account: account, scope: "message", threadId: nil,
                        messageIds: [$0], messageIdsComplete: true, operation: "modify",
                        addLabelIds: ["TRASH"], removeLabelIds: ["INBOX"])
                }
            }
            var candidates = Set<String>()
            for job in jobs where !job.isMessageScoped {
                // Old workers did not persist the resolved thread ID; cached metadata can
                // supply it, but never assume a message ID is a thread ID.
                let rows = await store.messages(ids: [job.messageId], account: account)
                guard let thread = job.threadId ?? rows.first?.threadId, !thread.isEmpty else { continue }
                let effect = GmailWriteEffect(account: account, scope: "thread", threadId: thread,
                    messageIds: [job.messageId], messageIdsComplete: false, operation: "modify")
                let ids = await store.confirmedEffectIDs(effect)
                if let inbox = await store.inboxIds(among: Array(ids), account: account), !inbox.isEmpty {
                    candidates.insert(thread)
                }
            }
            if candidates.isEmpty { continue }
            let archived = await archivedThreads(account, Array(candidates))
            effects += archived.intersection(candidates).map {
                GmailWriteEffect(account: account, scope: "thread", threadId: $0,
                    messageIds: [], messageIdsComplete: false, operation: "modify", removeLabelIds: ["INBOX"])
            }
        }
        return effects
    }
}

/// The queue's original entry points, kept so existing callers read unchanged.
extension LocalTriageQueue {
    typealias DispatchSweepScope = TriageDispatchReconciler.DispatchSweepScope
    typealias DispatchPrunePlan = TriageDispatchReconciler.DispatchPrunePlan
    typealias DispatchCleanupScope = TriageDispatchReconciler.DispatchCleanupScope
    typealias DispatchReconciliation = TriageDispatchReconciler.DispatchReconciliation

    static func sweepsTheSender(_ task: String) -> Bool {
        TriageDispatchReconciler.sweepsTheSender(task)
    }

    static func validatedCleanupQuery(_ scope: DispatchCleanupScope, account: String, items: [Item]) -> String? {
        TriageDispatchReconciler.validatedCleanupQuery(scope, account: account, items: items)
    }

    static func dispatchPrunePlan(
        category: GmailMailCategory?, cachedIDs: [String]?, enrichedIDs: [String]
    ) -> DispatchPrunePlan {
        TriageDispatchReconciler.dispatchPrunePlan(category: category, cachedIDs: cachedIDs, enrichedIDs: enrichedIDs)
    }

    static func dispatchSweepScope(task: String, currentFrom: String) -> DispatchSweepScope? {
        TriageDispatchReconciler.dispatchSweepScope(task: task, currentFrom: currentFrom)
    }

    static func dispatchSweepScope(task: String, item: Item) -> DispatchSweepScope? {
        TriageDispatchReconciler.dispatchSweepScope(task: task, item: item)
    }
}
