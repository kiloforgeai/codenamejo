import Foundation

/// Where the triage queue's mail comes from: cached rows and live Gmail pages, turned into queue
/// items and grouped the way the queue presents them. Stateless; the walk's cursor stays on
/// `LocalTriageQueue`.
enum TriageMailSource {
    typealias Item = LocalTriageQueue.Item
    typealias Scope = LocalTriageQueue.Scope

    static func cacheThreadReadState(
        _ thread: GmailAPI.ThreadMetadata, expectedID: String, account: String, store: MailStore
    ) async -> Bool {
        guard thread.id == expectedID else { return false }
        let members = thread.messages ?? []
        let inbox = members.filter { ($0.labelIds ?? []).contains("INBOX") }
        await store.cache(inbox.map { MailStore.Ingest(detail: $0, account: account) })
        return !members.isEmpty && members.allSatisfy { !($0.labelIds ?? []).contains("UNREAD") }
    }

    static func liveItem(from ingest: MailStore.Ingest) -> Item {
        var item = Self.item(from: ingest.message)
        item.messages = item.conversation.map { member in
            var member = member
            member.unread = ingest.labels.contains("UNREAD")
            return member
        }
        return item
    }

    static func mergingLivePage(_ live: [Item], with cached: [Item], store: MailStore) async -> [Item] {
        let live = await refreshFacts(live, store: store, refreshUnread: false)
        let cached = await refreshFacts(cached, store: store)
        var seen = Set<String>()
        let combined = (live + cached).filter { seen.insert(LocalTriageQueue.messageKey(account: $0.account, id: $0.id)).inserted }
        return Array(combined.sorted { $0.internalDate > $1.internalDate }.prefix(LocalTriageQueue.pageSize))
    }

    enum LivePageResult {
        case unavailable
        case success([Item], hasMore: Bool, complete: Bool)
        case failure
    }

    /// Ask Gmail, from the phone, and keep what comes back. A missing grant, an empty page and a failed
    /// request stay distinct, so neither of the latter two can be reported as an empty inbox.
    /// - Parameter cached: told each account whose page was just written to the cache.
    static func livePage(
        before: Int64?, scope: Scope, accounts: [String], grouping: Bool, store: MailStore,
        unreadOpeningLoader: @Sendable (String) async -> [MailStore.Ingest]?,
        cached: (String) async -> Void
    ) async -> LivePageResult {
        guard !accounts.isEmpty else {
            RealtimeLog.log("localTriage: no Google grant on this device")
            return .unavailable
        }
        let query = before.map { "\(scope.query) before:\($0)" } ?? scope.query
        var all: [Item] = []
        var anyAnswered = false
        var complete = true
        var hasMore = false

        // Query accounts sequentially to respect Gmail's per-user quota.
        for account in accounts {
            if scope == .unread, before == nil {
                guard let batch = await unreadOpeningLoader(account) else {
                    complete = false
                    continue
                }
                anyAnswered = true
                hasMore = hasMore || batch.count >= LocalTriageQueue.pageSize
                await store.cache(batch)
                if !batch.isEmpty { await cached(account) }
                let enriched = await Self.enrichThreadContext(
                    batch.map(Self.liveItem(from:)), store: store, grouping: grouping)
                all.append(contentsOf: enriched)
                RealtimeLog.log("localTriage: refreshed unread opening — \(batch.count) messages for \(account)")
                continue
            }
            guard case .success(let token) = await GoogleCredential.token(for: account) else {
                complete = false
                RealtimeLog.log("localTriage: no usable grant for \(account)")
                continue
            }
            do {
                let refs = try await GmailAPI.recentMessageIds(
                    token: token.accessToken, query: query, limit: LocalTriageQueue.pageSize)
                anyAnswered = true
                if refs.count >= LocalTriageQueue.pageSize { hasMore = true }
                let details = await GmailAPI.metadata(
                    token: token.accessToken, ids: refs.map(\.id))
                if details.count != refs.count { complete = false }
                let batch = details.map {
                    MailStore.Ingest(detail: $0, account: token.email ?? account)
                }
                await store.cache(batch)
                if !batch.isEmpty { await cached(account) }
                var liveItems = batch.map(Self.liveItem(from:))
                liveItems = await Self.enrichThreadContext(liveItems, store: store, grouping: grouping)
                all.append(contentsOf: liveItems)
                RealtimeLog.log(
                    "localTriage: Gmail answered \(batch.count) for \(account) \"\(query)\"")
            } catch {
                complete = false
                RealtimeLog.log("localTriage: Gmail unreachable for \(account) — \(error)")
            }
        }

        guard anyAnswered else { return .failure }
        all.sort { $0.internalDate > $1.internalDate }
        if all.count > LocalTriageQueue.pageSize { hasMore = true }
        return .success(
            Array(all.prefix(LocalTriageQueue.pageSize)),
            hasMore: hasMore,
            complete: complete)
    }

    /// The bound for the next page, in epoch seconds. One second past the oldest message, because
    /// `before:` is strictly older; the duplicate boundary message is deduped on the way in.
    static func watermark(_ page: [Item]) -> Int64? {
        guard let oldest = page.map(\.internalDate).min() else { return nil }
        return oldest / 1000 + 1
    }

    static func refreshFacts(_ items: [Item], store: MailStore, refreshUnread: Bool = true) async -> [Item] {
        let unread = if refreshUnread { await store.unreadState(among: items.flatMap(\.ids)) } else { nil as Set<String>? }
        var draftsByAccount: [String: Set<String>] = [:]
        for (account, members) in Dictionary(grouping: items, by: \.account) {
            draftsByAccount[account] = await store.draftThreadIDs(account: account, among: Set(members.flatMap(\.threadIDs)))
        }
        return items.map { item in
            var updated = item
            updated.messages = item.conversation.map { message in
                var updated = message
                if let unread { updated.unread = unread.contains(message.id) }
                return updated
            }
            if let draftThreads = draftsByAccount[item.account] {
                updated.hasDraft = !draftThreads.isDisjoint(with: item.threadIDs)
            }
            return updated
        }
    }

    static func item(from message: MailStore.Message) -> Item {
        let date = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: Double(message.internalDate ?? 0) / 1000))
        return Item(
            account: message.account,
            id: message.id,
            threadId: message.threadId,
            from: message.sender ?? "unknown sender",
            subject: message.subject ?? "(no subject)",
            date: date,
            snippet: message.snippet ?? "",
            recipient: message.recipient,
            internalDate: message.internalDate ?? 0,
            // A one-message conversation until `groupByConversation` folds its siblings in.
            messages: [
                Item.Message(
                    id: message.id,
                    from: message.sender ?? "unknown sender",
                    subject: message.subject ?? "(no subject)",
                    date: date,
                    snippet: message.snippet ?? "",
                    internalDate: message.internalDate ?? 0,
                    recipient: message.recipient,
                    unread: true,
                    exchangeID: exchangeID(messageID: message.id, rfcID: message.rfcMessageID,
                                           inReplyTo: message.inReplyTo, references: message.referenceHeaders),
                    ancestryCached: message.ancestryCached, rfcMessageID: message.rfcMessageID,
                    inReplyTo: message.inReplyTo, references: message.referenceHeaders,
                    threadId: message.threadId, topicId: message.topicVersion == 1 ? message.topicId : nil)
            ],
            importanceWhy: message.importanceWhy,
            importanceBand: message.importanceBand,
            topicId: message.topicVersion == 1 ? message.topicId : nil
        )
    }

    static func groupForPresentation(
        _ items: [Item], grouping: Bool, topicGrouping: Bool, preserveOrder: Bool = false
    ) -> [Item] {
        let threads = groupByConversation(items, grouping: grouping, preserveOrder: preserveOrder)
        return topicGrouping ? groupByTopic(threads) : threads
    }

    static func groupByTopic(_ source: [Item]) -> [Item] {
        var result: [Item] = []
        for item in source {
            guard let topic = item.topicId, !topic.isEmpty,
                  let sender = EmailCleanupPolicy.sender(item.from), !sender.isEmpty,
                  item.acted == nil, item.unresolvedContinuation != true,
                  !item.threadIDs.isEmpty else { result.append(item); continue }
            let match = result.firstIndex {
                $0.topicId == topic && $0.account.lowercased() == item.account.lowercased()
                    && EmailCleanupPolicy.sender($0.from) == sender && $0.acted == nil
                    && $0.unresolvedContinuation != true && $0.threadIDs.isDisjoint(with: item.threadIDs)
                    && ($0.coachingCounted == true) == (item.coachingCounted == true)
            }
            guard let match else { result.append(item); continue }
            let previous = result[match]
            var combined = previous
            combined.topicParts = previous.unwrappedTopics + item.unwrappedTopics
            combined.messages = (previous.conversation.map { member in
                var member = member; member.threadId = member.threadId ?? previous.threadId; return member
            } + item.conversation.map { member in
                var member = member; member.threadId = member.threadId ?? item.threadId; return member
            }).sorted { $0.internalDate < $1.internalDate }
            combined.displayGroupID = "topic:" + topic
            combined.summaryMessages = nil
            combined.exchangeContext = nil
            combined.hasDraft = previous.hasDraft == true || item.hasDraft == true
            result[match] = combined.keeping(combined.conversation) ?? combined
        }
        return result
    }

    static func excludingSummarizedReadThreads(_ items: [Item], keys: Set<String>) -> [Item] {
        items.compactMap { item in
            guard item.displayGroupID == "read-thread", item.threadReadVerified == true,
                  keys.contains(LocalTriageQueue.threadKey(account: item.account, threadId: item.threadId)),
                  item.unresolvedContinuation != true else { return item }
            guard var remaining = item.keeping(item.conversation.filter(\.unread)) else { return nil }
            if remaining.displayGroupID == "read-thread" { remaining.displayGroupID = nil }
            return remaining
        }
    }

    static func ancestryTokens(_ value: String?) -> [String]? {
        guard let value else { return [] }
        guard let regex = try? NSRegularExpression(pattern: #"<([^<>\s]+@[^<>\s]+)>"#) else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        guard regex.stringByReplacingMatches(in: value, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let text = value as NSString
        return regex.matches(in: value, range: range).map { text.substring(with: $0.range(at: 1)) }
    }

    static func ancestryChain(rfcID: String?, inReplyTo: String?, references: String?) -> [String]? {
        guard let own = ancestryTokens(rfcID), let parents = ancestryTokens(inReplyTo),
              let ancestors = ancestryTokens(references), own.count == 1, parents.count <= 1,
              Set(ancestors).count == ancestors.count, !ancestors.contains(own[0]),
              parents.isEmpty || ancestors.last == parents.first else { return nil }
        return ancestors + own
    }

    static func exchangeID(
        messageID: String, rfcID: String?, inReplyTo: String?, references: String?, context: [Item.Message] = []
    ) -> String {
        let fallback = "message:" + messageID
        guard let chain = ancestryChain(rfcID: rfcID, inReplyTo: inReplyTo, references: references) else { return fallback }
        if chain.count == 1 {
            let replies = context.filter {
                guard let reply = ancestryChain(rfcID: $0.rfcMessageID, inReplyTo: $0.inReplyTo, references: $0.references)
                else { return false }
                return reply.count > 1 && reply.first == chain.first
            }
            let branches = Set(replies.map {
                exchangeID(messageID: $0.id, rfcID: $0.rfcMessageID,
                           inReplyTo: $0.inReplyTo, references: $0.references, context: context)
            })
            // A root belongs to its sole proven reply chain; multiple branches remain separate.
            guard branches.count == 1, let branch = branches.first, branch.hasPrefix("branch:") else { return fallback }
            return branch
        }
        for index in chain.indices {
            let known = context.filter { ancestryTokens($0.rfcMessageID)?.first == chain[index] }
            guard known.count <= 1, known.allSatisfy({
                ancestryChain(rfcID: $0.rfcMessageID, inReplyTo: $0.inReplyTo, references: $0.references) == Array(chain.prefix(index + 1))
            }) else { return fallback }
        }
        return "branch:\(chain[0].utf8.count):\(chain[0])\(chain[1])"
    }

    /// Items whose thread context is already known, by `threadKey`: the buffer being walked plus
    /// whatever today's row carried. Topic groups contribute their parts.
    static func threadContextIndex(_ items: [Item]) -> [String: Item] {
        var index: [String: Item] = [:]
        for item in items.flatMap(\.unwrappedTopics) where item.exchangeContext != nil {
            let key = LocalTriageQueue.threadKey(account: item.account, threadId: item.threadId)
            guard !key.isEmpty else { continue }
            // The fuller context wins when the same thread was held twice.
            if let held = index[key], (held.exchangeContext?.count ?? 0) >= (item.exchangeContext?.count ?? 0) { continue }
            index[key] = item
        }
        return index
    }

    /// `item` with `source`'s thread context, when that context still describes the thread: every
    /// member of `item` must be in it, so a thread with a new message is fetched again. The read
    /// verdict holds only while nothing in the item is unread.
    static func reusingThreadContext(_ item: Item, from source: Item) -> Item? {
        guard item.exchangeContext == nil, !item.isTopicGroup,
              item.account.lowercased() == source.account.lowercased(), item.threadId == source.threadId,
              let context = source.exchangeContext, !context.isEmpty else { return nil }
        let known = Dictionary(context.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard item.conversation.allSatisfy({ known[$0.id] != nil }) else { return nil }
        var item = item
        let verified = source.threadReadVerified == true && !item.conversation.contains(where: \.unread)
        item.threadReadVerified = verified
        item.threadMessageCount = source.threadMessageCount ?? Set(context.map(\.id)).count
        item.messages = item.conversation.map { selected in
            var selected = selected
            guard let fetched = known[selected.id] else { return selected }
            selected.rfcMessageID = fetched.rfcMessageID
            selected.inReplyTo = fetched.inReplyTo
            selected.references = fetched.references
            selected.ancestryCached = fetched.ancestryCached
            selected.exchangeID = fetched.exchangeID
            return selected
        }
        item.exchangeContext = context
        item.summaryMessages = verified ? context : nil
        return item
    }

    /// - Parameter known: thread context already in hand (`threadContextIndex`), reused for an item
    ///   whose thread it still describes, so only threads the walk has never seen reach Gmail.
    static func enrichThreadContext(
        _ items: [Item], store: MailStore, grouping: Bool, known: [String: Item] = [:]
    ) async -> [Item] {
        guard grouping else { return items }
        var result = items
        if !known.isEmpty {
            var reused = 0
            for index in result.indices where result[index].exchangeContext == nil {
                guard let source = known[LocalTriageQueue.threadKey(account: result[index].account, threadId: result[index].threadId)],
                      let item = reusingThreadContext(result[index], from: source) else { continue }
                result[index] = item
                reused += 1
            }
            if reused > 0 { RealtimeLog.log("localTriage: thread context reused for \(reused) item(s) — no Gmail fetch") }
        }
        for account in Set(result.filter { $0.exchangeContext == nil }.map(\.account)) {
            guard case .success(let token) = await GoogleCredential.token(for: account) else {
                RealtimeLog.log("localTriage: thread context unavailable for \(account)")
                continue
            }
            let threads = Set(result.filter { $0.account == account && $0.exchangeContext == nil }.map(\.threadId))
            RealtimeLog.log("localTriage: thread context fetching \(threads.filter { !$0.isEmpty }.count) thread(s) for \(account)")
            let contexts = await threadContexts(ids: Array(threads.filter { !$0.isEmpty })) { threadID in
                do {
                    let thread = try await GmailAPI.threadMetadata(token: token.accessToken, id: threadID)
                    let verified = await cacheThreadReadState(thread, expectedID: threadID, account: account, store: store)
                    return (thread, verified)
                } catch {
                    RealtimeLog.log("localTriage: thread context failed — \(error)")
                    return nil
                }
            }
            for index in result.indices where result[index].account == account {
                if let (thread, verified) = contexts[result[index].threadId] {
                    result[index] = withThreadContext(result[index], thread: thread, verified: verified)
                }
            }
        }
        return result
    }

    static func threadContexts<Value: Sendable>(
        ids: [String], limit: Int = 4,
        fetch: @escaping @Sendable (String) async -> Value?
    ) async -> [String: Value] {
        await withTaskGroup(of: (String, Value?).self) { group in
            var pending = Array(Set(ids)).makeIterator()
            func enqueue(_ id: String) {
                group.addTask { (id, await fetch(id)) }
            }
            for _ in 0..<max(1, limit) {
                if let id = pending.next() { enqueue(id) }
            }
            var results: [String: Value] = [:]
            for await (id, value) in group {
                results[id] = value
                if !Task.isCancelled, let next = pending.next() { enqueue(next) }
            }
            return results
        }
    }

    static func withThreadContext(_ item: Item, thread: GmailAPI.ThreadMetadata, verified: Bool) -> Item {
        guard thread.id == item.threadId else { return item }
        var item = item
        let raw = (thread.messages ?? []).flatMap {
            liveItem(from: MailStore.Ingest(detail: $0, account: item.account)).conversation
        }.sorted { $0.internalDate < $1.internalDate }
        func annotated(_ message: Item.Message) -> Item.Message {
            var message = message
            message.exchangeID = exchangeID(messageID: message.id, rfcID: message.rfcMessageID,
                inReplyTo: message.inReplyTo, references: message.references, context: raw)
            return message
        }
        item.threadReadVerified = verified
        item.threadMessageCount = Set(raw.map(\.id)).count
        item.messages = item.conversation.map { selected in
            var selected = selected
            let matches = raw.filter { $0.id == selected.id && $0.threadId == item.threadId }
            if matches.count == 1, let fetched = matches.first {
                selected.rfcMessageID = fetched.rfcMessageID
                selected.inReplyTo = fetched.inReplyTo
                selected.references = fetched.references
                selected.ancestryCached = fetched.ancestryCached
            }
            return annotated(selected)
        }
        item.exchangeContext = raw.map(annotated)
        item.summaryMessages = verified ? raw.map(annotated) : nil
        return item
    }

    static func groupByConversation(_ items: [Item], grouping: Bool = ThreadQueue.isOn, preserveOrder: Bool = false) -> [Item] {
        let singles = items.flatMap(\.unwrappedTopics).flatMap { item in
            item.conversation.compactMap { item.keeping([$0], preservingSummary: true) }
        }
        guard grouping else { return singles }
        let threadsWithUnread = Set(singles.filter { $0.unreadCount > 0 || $0.threadReadVerified != true }.map {
            LocalTriageQueue.threadKey(account: $0.account, threadId: $0.threadId.isEmpty ? $0.id : $0.threadId)
        })
        var order: [String] = []
        var groups: [String: Item] = [:]
        for var item in singles {
            let thread = LocalTriageQueue.threadKey(account: item.account, threadId: item.threadId.isEmpty ? item.id : item.threadId)
            let member = item.conversation[0]
            let context = item.exchangeContext ?? singles.filter {
                $0.account.lowercased() == item.account.lowercased() && $0.threadId == item.threadId
            }.flatMap(\.conversation)
            let branch = member.rfcMessageID == nil ? member.exchangeID ?? "message:" + item.id
                : exchangeID(messageID: member.id, rfcID: member.rfcMessageID,
                             inReplyTo: member.inReplyTo, references: member.references, context: context)
            let exchange = item.displayGroupID ?? (threadsWithUnread.contains(thread) ? branch : "read-thread")
            item.displayGroupID = exchange
            if exchange != "read-thread", let context = item.exchangeContext {
                // Unread chain members another stop selects still inform this summary.
                item.exchangeContext = context.filter { $0.exchangeID == exchange }
            }
            // Mailbox, thread and reply ancestry, never the sender: a reply from anyone stays inside the
            // chain it answers.
            let key = "\(thread.utf8.count):\(thread)\(exchange)"
            guard let existing = groups[key] else {
                order.append(key)
                groups[key] = item
                continue
            }
            let members = Dictionary((existing.conversation + item.conversation).map { ($0.id, $0) },
                                     uniquingKeysWith: { _, newest in newest }).values
            var merged = existing.keeping(Array(members))!
            merged.hasDraft = existing.hasDraft == true || item.hasDraft == true
            groups[key] = merged
        }
        let result = order.compactMap { groups[$0] }
        return preserveOrder ? result : result.sorted { $0.internalDate > $1.internalDate }
    }

    /// Clear the unread flag, in Gmail and here; the next page comes from the same store. The local
    /// clear and retry intent share a transaction, so `flushMarkReadOutbox` retries a failed live call.
    static func markRead(_ item: Item, store: MailStore) async {
        for id in item.conversation.filter(\.unread).map(\.id) {
            await store.clearUnreadDurably(id: id, account: item.account)
        }
        // The item's own mailbox: the primary account's token on another mailbox's message gets a 404.
        guard case .success(let token) = await GoogleCredential.token(for: item.account)
        else { return }
        for id in item.conversation.filter(\.unread).map(\.id) {
            do {
                try await GmailAPI.markRead(token: token.accessToken, id: id)
                await store.removeMarkReadOutbox(id)
            } catch {
                // Left in the outbox rather than dropped — see `flushMarkReadOutbox`.
                RealtimeLog.log("localTriage: could not mark \(id) read — \(error), queued for retry")
            }
        }
    }
}

/// The queue's original entry points, kept so existing callers read unchanged.
extension LocalTriageQueue {
    static func cacheThreadReadState(
        _ thread: GmailAPI.ThreadMetadata, expectedID: String, account: String, store: MailStore
    ) async -> Bool {
        await TriageMailSource.cacheThreadReadState(thread, expectedID: expectedID, account: account, store: store)
    }

    static func liveItem(from ingest: MailStore.Ingest) -> Item {
        TriageMailSource.liveItem(from: ingest)
    }

    static func mergingLivePage(_ live: [Item], with cached: [Item], store: MailStore) async -> [Item] {
        await TriageMailSource.mergingLivePage(live, with: cached, store: store)
    }

    static func refreshFacts(_ items: [Item], store: MailStore, refreshUnread: Bool = true) async -> [Item] {
        await TriageMailSource.refreshFacts(items, store: store, refreshUnread: refreshUnread)
    }

    static func groupForPresentation(
        _ items: [Item], grouping: Bool, topicGrouping: Bool, preserveOrder: Bool = false
    ) -> [Item] {
        TriageMailSource.groupForPresentation(
            items, grouping: grouping, topicGrouping: topicGrouping, preserveOrder: preserveOrder)
    }

    static func groupByTopic(_ source: [Item]) -> [Item] {
        TriageMailSource.groupByTopic(source)
    }

    static func excludingSummarizedReadThreads(_ items: [Item], keys: Set<String>) -> [Item] {
        TriageMailSource.excludingSummarizedReadThreads(items, keys: keys)
    }

    static func exchangeID(
        messageID: String, rfcID: String?, inReplyTo: String?, references: String?, context: [Item.Message] = []
    ) -> String {
        TriageMailSource.exchangeID(
            messageID: messageID, rfcID: rfcID, inReplyTo: inReplyTo, references: references, context: context)
    }

    static func threadContexts<Value: Sendable>(
        ids: [String], limit: Int = 4,
        fetch: @escaping @Sendable (String) async -> Value?
    ) async -> [String: Value] {
        await TriageMailSource.threadContexts(ids: ids, limit: limit, fetch: fetch)
    }

    static func withThreadContext(_ item: Item, thread: GmailAPI.ThreadMetadata, verified: Bool) -> Item {
        TriageMailSource.withThreadContext(item, thread: thread, verified: verified)
    }

    static func threadContextIndex(_ items: [Item]) -> [String: Item] {
        TriageMailSource.threadContextIndex(items)
    }

    static func reusingThreadContext(_ item: Item, from source: Item) -> Item? {
        TriageMailSource.reusingThreadContext(item, from: source)
    }

    static func groupByConversation(_ items: [Item], grouping: Bool = ThreadQueue.isOn, preserveOrder: Bool = false) -> [Item] {
        TriageMailSource.groupByConversation(items, grouping: grouping, preserveOrder: preserveOrder)
    }
}
