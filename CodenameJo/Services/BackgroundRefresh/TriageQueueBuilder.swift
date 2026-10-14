import Foundation

/// How the triage queue is built: counting a scope, ranking and appending pages, deciding what an
/// empty page means, and prefetching the next stage. Stateless; `LocalTriageQueue.build` applies
/// the result to the walk.
enum TriageQueueBuilder {
    typealias Item = LocalTriageQueue.Item
    typealias Scope = LocalTriageQueue.Scope

    /// The `all` stage's count and first Gmail pages, fetched while unread's tail is walked. Keyed by
    /// the `before:` each page was asked with; `pageRun` re-filters them against the walk.
    struct InboxAhead {
        let total: Int?
        let accounts: [String]
        let pages: [Int64?: TriageMailSource.LivePageResult]
        let at: Date
    }

    static func orderByImportance(
        _ items: [Item], rows: [MailStore.Message], currentID: String?, currentAccount: String?
    ) -> [Item] {
        let ranked = rows.sorted { lhs, rhs in
            let left = MailImportance.walkOrder.firstIndex(of: lhs.importanceBand ?? "normal") ?? 1
            let right = MailImportance.walkOrder.firstIndex(of: rhs.importanceBand ?? "normal") ?? 1
            if left != right { return left < right }
            if lhs.importanceScore != rhs.importanceScore {
                return (lhs.importanceScore ?? 0) > (rhs.importanceScore ?? 0)
            }
            if lhs.internalDate != rhs.internalDate { return (lhs.internalDate ?? 0) > (rhs.internalDate ?? 0) }
            return lhs.id > rhs.id
        }
        let ranks = Dictionary(ranked.enumerated().map {
            (LocalTriageQueue.messageKey(account: $0.element.account, id: $0.element.id), $0.offset)
        }, uniquingKeysWith: min)
        // Rank whole conversations by their strongest member; never split a reply chain.
        func rank(_ item: Item) -> Int {
            item.ids.compactMap { ranks[LocalTriageQueue.messageKey(account: item.account, id: $0)] }.min() ?? Int.max
        }
        return items.enumerated().sorted { lhs, rhs in
            let leftCurrent = lhs.element.id == currentID && lhs.element.account == currentAccount
            let rightCurrent = rhs.element.id == currentID && rhs.element.account == currentAccount
            if leftCurrent != rightCurrent { return leftCurrent }
            let left = rank(lhs.element), right = rank(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// A stage, named the way it is announced at a crossing into it. `all` is "the rest of their
    /// inbox", since it is only ever crossed into after the unread half.
    static func stageLabel(_ scope: Scope) -> String {
        switch scope {
        case .important: "their most important mail from this week"
        case .unread: "the rest of their unread mail"
        case .all: "the rest of their inbox, read mail included"
        }
    }

    static func appendingPage(
        _ page: [Item], to buffer: [Item], position: Int = 0, grouping: Bool = ThreadQueue.isOn
    ) -> [Item] {
        var items = buffer.map { item in
            let normalized = TriageMailSource.groupByConversation([item], grouping: grouping)
            return normalized.count == 1 ? normalized[0] : item
        }
        var seen = LocalTriageQueue.messageKeys(buffer)
        for incoming in TriageMailSource.groupByConversation(page, grouping: grouping) {
            guard let fresh = incoming.keeping(incoming.conversation.filter {
                seen.insert(LocalTriageQueue.messageKey(account: incoming.account, id: $0.id)).inserted
            }) else { continue }
            if grouping, let index = items.indices.first(where: {
                $0 >= position && items[$0].account.lowercased() == fresh.account.lowercased()
                    && !fresh.threadId.isEmpty && items[$0].threadId == fresh.threadId
                    && items[$0].displayGroupID == fresh.displayGroupID
                    && (items[$0].coachingCounted == true) == (fresh.coachingCounted == true)
                    && (items[$0].unresolvedContinuation == true) == (fresh.unresolvedContinuation == true)
            }) {
                if let merged = TriageMailSource.groupByConversation([items[index], fresh], grouping: true).first {
                    items[index] = merged
                }
            } else {
                items.append(contentsOf: TriageMailSource.groupByConversation([fresh], grouping: grouping))
            }
        }
        return items
    }

    enum GmailEmptyDisposition: Equatable {
        case continuePaging
        case retryUnavailable
    }

    /// An empty buffer is terminal only when Gmail has authoritatively run out of matches.
    static func gmailEmptyDisposition(
        hasMore: Bool, stalled: Bool
    ) -> GmailEmptyDisposition? {
        if stalled { return .retryUnavailable }
        return hasMore ? .continuePaging : nil
    }

    static func gmailEligible(
        _ items: [Item], dealtWithThisWalk: Set<String>
    ) -> [Item] {
        items.compactMap { item in
            item.keeping(item.conversation.filter {
                !dealtWithThisWalk.contains(LocalTriageQueue.messageKey(account: item.account, id: $0.id))
            })
        }
    }

    /// How much mail matches the query, off Gmail's own label counter rather than by listing. The
    /// cache's row count is the wrong number: it holds a day, the mailbox holds far more.
    static func count(
        scope: Scope, accounts: [String], store: MailStore
    ) async -> (total: Int?, live: Bool) {
        // The account rides with the count from `inboxUnread()`, so a number is never spoken about the
        // wrong mailbox. The pages come from the same store, so count and contents agree.
        if scope == .unread,
           let cached = await store.inboxUnread(), cached.count >= 0,
           Set(cached.accounts.map { $0.lowercased() }) == Set(accounts.map { $0.lowercased() }) {
            return (cached.count, false)
        }
        guard !accounts.isEmpty else { return (nil, false) }
        // The week is on disc, so its count is too — see `MailStore.importantCount`.
        if scope == .important {
            return (await store.importantCount(accounts: accounts), false)
        }

        var total = 0
        var answered = 0
        var failed = 0
        for account in accounts {
            guard case .success(let token) = await GoogleCredential.token(for: account) else {
                failed += 1
                continue
            }

            do {
                if scope == .all {
                    total += try await GmailAPI.inboxTotalCount(token: token.accessToken)
                } else {
                    total += try await GmailAPI.inboxUnreadCount(token: token.accessToken)
                }
                answered += 1
            } catch {
                failed += 1
                RealtimeLog.log("localTriage: count failed for \(account) — \(error)")
            }
        }
        if failed > 0 {
            RealtimeLog.log(
                "localTriage: count covered \(answered) of \(accounts.count) mailbox(es)")
            // A partial sum is not a mailbox total. Keep the successfully fetched page, but
            // withhold the number rather than presenting one account's count as all accounts.
            return (nil, true)
        }
        return (answered > 0 ? total : nil, true)
    }

    /// What to say when a build finds nothing. Three scopes, three different true sentences:
    /// "nothing unread" over an important-only walk would claim more than the queue looked at.
    static func emptyNote(asked: Scope, crossedFrom crossedFromScope: Scope?) -> String {
        if let finished = crossedFromScope {
            // The stage that ran out decides what may be claimed. Only an empty `all` is an empty
            // inbox; every earlier stage leaves the rest of it, and the walk carries on into it.
            return "They have finished \(stageLabel(finished)), and "
                + (asked == .all
                    ? "there is nothing left in their inbox at all — not unread, nothing. "
                        + "Say that in one sentence: that is their inbox genuinely clear."
                    : "\(stageLabel(asked)) had nothing in it. Say what they finished "
                        + "and that there was nothing after it, in one sentence — do NOT "
                        + "say their inbox is clear, empty or at zero.")
                + " Do not ask them to start another queue."
        } else {
            switch asked {
            case .all:
                return "Their inbox is completely empty — not just read, empty. "
                    + "Say so in one sentence."
            case .important:
                return "Nothing from their past week needs them. Say THAT in one "
                    + "sentence — not that their inbox is empty or clear, which it probably "
                    + "is not. If they want the rest of their unread, that is a fresh queue "
                    + "and they will ask for it."
            case .unread:
                return "Their inbox has nothing unread in it. Say so in one sentence."
            }
        }
    }

    /// The `all` stage's first Gmail pages for `prefetchInboxStage`, keyed by the `before:` each
    /// was asked with. Stops at the first incomplete answer, or once a page holds mail not yet walked.
    static func inboxAheadPages(
        walked: Set<String>, budget: Int,
        livePage: (Int64?) async -> TriageMailSource.LivePageResult
    ) async -> [Int64?: TriageMailSource.LivePageResult] {
        var pages: [Int64?: TriageMailSource.LivePageResult] = [:]
        var before: Int64?
        for _ in 0..<budget {
            // Only complete answers are kept; anything else is left for the crossing to ask live.
            let page = await livePage(before)
            guard case .success(let live, let hasMore, true) = page else { break }
            pages[before] = page
            guard hasMore, Self.gmailEligible(live, dealtWithThisWalk: walked).isEmpty,
                  let next = TriageMailSource.watermark(live), next != before
            else { break }
            before = next
        }
        return pages
    }
}

/// The queue's original entry points, kept so existing callers read unchanged.
extension LocalTriageQueue {
    typealias GmailEmptyDisposition = TriageQueueBuilder.GmailEmptyDisposition

    static func orderByImportance(
        _ items: [Item], rows: [MailStore.Message], currentID: String?, currentAccount: String?
    ) -> [Item] {
        TriageQueueBuilder.orderByImportance(items, rows: rows, currentID: currentID, currentAccount: currentAccount)
    }

    static func appendingPage(
        _ page: [Item], to buffer: [Item], position: Int = 0, grouping: Bool = ThreadQueue.isOn
    ) -> [Item] {
        TriageQueueBuilder.appendingPage(page, to: buffer, position: position, grouping: grouping)
    }

    static func gmailEmptyDisposition(hasMore: Bool, stalled: Bool) -> GmailEmptyDisposition? {
        TriageQueueBuilder.gmailEmptyDisposition(hasMore: hasMore, stalled: stalled)
    }

    static func gmailEligible(_ items: [Item], dealtWithThisWalk: Set<String>) -> [Item] {
        TriageQueueBuilder.gmailEligible(items, dealtWithThisWalk: dealtWithThisWalk)
    }
}
