import Foundation

enum TriageNavigation {
    typealias Item = LocalTriageQueue.Item
    typealias Scope = LocalTriageQueue.Scope
    /// Stage crossings replace `items`. Retain completed stages so voice navigation can cross
    /// those otherwise destructive boundaries.
    struct Stage: Codable, Sendable {
        var items: [Item]
        let grouping: Bool
        let topicGrouping: Bool
        let adopted: Bool
        let position: Int
        let ordinalOffset: Int
        let before: Int64?
        let more: Bool
        let total: Int
        let mailboxUnreadAtStart: Int
        let scope: Scope
        let scopeUnsaid: Bool
        let scopePlan: [Scope]
        let stalled: Bool
    }

    static func navigationIDs(
        in stages: [Stage], for effect: GmailWriteEffect, ids: Set<String>
    ) -> Set<String> {
        var held = Set<String>()
        for stage in stages {
            for item in stage.items
            where item.account.caseInsensitiveCompare(effect.account) == .orderedSame {
                if effect.scope == "thread", !effect.messageIdsComplete,
                   let thread = effect.threadId {
                    held.formUnion(item.conversation.filter { ($0.threadId ?? item.threadId) == thread }.map(\.id))
                } else {
                    held.formUnion(item.ids.filter { ids.contains($0) })
                }
            }
        }
        return held
    }

    static func restoreNavigationItems(
        _ stages: inout [Stage], ids: Set<String>, account: String
    ) {
        guard !ids.isEmpty else { return }
        for stageIndex in stages.indices {
            for itemIndex in stages[stageIndex].items.indices where
                stages[stageIndex].items[itemIndex].account.caseInsensitiveCompare(account) == .orderedSame
                    && !Set(stages[stageIndex].items[itemIndex].ids).isDisjoint(with: ids) {
                stages[stageIndex].items[itemIndex].acted = nil
                stages[stageIndex].items[itemIndex].markedRead = false
                stages[stageIndex].items[itemIndex].unresolvedContinuation = true
            }
        }
    }

    static func takeNavigationItems(
        _ stages: inout [Stage], ids: Set<String>, account: String
    ) -> [Item] {
        guard !ids.isEmpty else { return [] }
        var taken: [Item] = []
        var seen = Set<String>()
        for stageIndex in stages.indices {
            stages[stageIndex].items = stages[stageIndex].items.compactMap { item in
                guard item.account.caseInsensitiveCompare(account) == .orderedSame else {
                    return item
                }
                if var restored = item.keeping(item.conversation.filter {
                    ids.contains($0.id) && seen.insert($0.id).inserted
                }) {
                    restored.acted = nil
                    restored.markedRead = false
                    restored.unresolvedContinuation = true
                    restored.coachingCounted = true
                    taken.append(restored)
                }
                return item.keeping(item.conversation.filter { !ids.contains($0.id) })
            }
        }
        return taken
    }

    static func applyNavigationEffect(
        _ stages: inout [Stage], effect: GmailWriteEffect, ids: Set<String>
    ) {
        for stageIndex in stages.indices {
            for itemIndex in stages[stageIndex].items.indices
            where stages[stageIndex].items[itemIndex].account
                .caseInsensitiveCompare(effect.account) == .orderedSame {
                stages[stageIndex].items[itemIndex].messages =
                    stages[stageIndex].items[itemIndex].conversation.map { member in
                        var member = member
                        if ids.contains(member.id) {
                            member.queueWeight = member.queueWeight ?? (member.unread ? 1 : 0)
                            if effect.removed.contains("UNREAD") { member.unread = false }
                            if effect.added.contains("UNREAD") { member.unread = true }
                        }
                        return member
                    }
            }
        }
    }

}
