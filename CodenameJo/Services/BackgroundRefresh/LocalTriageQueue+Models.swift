import Foundation

extension LocalTriageQueue {
    /// What the queue is walking. `important` is the past week of the inbox in our importance order.
    /// Must match the `scope` enum in `LiveToolSchemas.triageNext` and `QUEUE_SCOPES` in `auth:lib/queue-scopes.ts`.
    enum Scope: String, Codable, Sendable {
        case unread
        case all
        case important

        /// What this scope walks, for the log.
        var query: String {
            switch self {
            case .all: "in:inbox"
            case .important: "in:inbox newer_than:7d -from:me"
            case .unread: "in:inbox is:unread"
            }
        }

        /// Whether the unread cache holds this scope's mail. `all` cannot, since the cache holds unread
        /// mail only; `important`'s week is listed and reconciled in full by `BackgroundMailRefresh`.
        var cacheCanAnswer: Bool { self == .unread || self == .important }

        /// Whether a page from the cache is the important scope's week rather than the unread pile.
        var importantOnly: Bool { self == .important }

        /// The pile, named the way it is said out loud. Only read when the user did not
        /// choose it in the call — see `scopeUnsaid`.
        var spokenPile: String {
            switch self {
            case .all: "your whole inbox, read mail included"
            case .important: "your most important mail from this week"
            case .unread: "your unread mail"
            }
        }

        /// Every stage, in order. `all` is last because only its end leaves nothing in the inbox unseen.
        static let scopeChain: [Scope] = [.important, .unread, .all]

        /// Where a walk starts for an account that has chosen no pile: our own ranking of the past
        /// week, so what the user meets first is what matters most.
        static let automaticStart: Scope = .important

        /// The stages still to walk from a chosen starting point, including it: a saved pick is
        /// where the walk starts, not where it stops.
        var restOfWalk: [Scope] {
            guard let at = Self.scopeChain.firstIndex(of: self) else { return [self] }
            return Array(Self.scopeChain[at...])
        }
    }

    /// One queued message. Carries no unsubscribe headers; `unsubscribe_sender` reads the message itself.
    struct Item: Codable, Sendable, Equatable {
        let account: String
        var id: String
        var threadId: String
        var from: String
        var subject: String
        var date: String
        var snippet: String
        /// Who it went to, so a sent message can be introduced without a read. Optional so older
        /// snapshots decode.
        var recipient: String? = nil
        /// Gmail's received time in milliseconds. A paging cursor, never put in a payload, because
        /// numbers in a payload get read aloud.
        var internalDate: Int64
        /// What the user did with it, once they have. Set by the tool that did it.
        var acted: String?
        /// Whether its unread flag is gone in Gmail. Separate from `acted` because a skip marks read
        /// and is not an action.
        var markedRead = false
        /// Set once when the queue moves forward from this message. Optional so snapshots
        /// written by older builds decode without a migration.
        var coachingCounted: Bool? = nil
        var unresolvedContinuation: Bool? = nil
        var displayGroupID: String? = nil
        var threadReadVerified: Bool? = nil
        var threadMessageCount: Int? = nil
        var summaryMessages: [Message]? = nil
        var exchangeContext: [Message]? = nil
        var messages: [Message]? = nil
        /// An unsent draft is sitting on this conversation, so the step can say so before
        /// asking the user what to do with it.
        var hasDraft: Bool? = nil
        /// Why this one is in front of them; top band only. The band itself orders and is never spoken.
        var importanceWhy: String? = nil
        /// Which band it was walked from. Never in a payload; it only tells the walk where
        /// the important mail ends.
        var importanceBand: String? = nil
        var topicId: String? = nil
        var topicParts: [Item]? = nil

        var threadIDs: Set<String> { Set(conversation.map { $0.threadId ?? threadId }.filter { !$0.isEmpty }) }
        var isTopicGroup: Bool { (topicParts?.count ?? 0) > 1 }
        func thread(for messageID: String) -> String {
            conversation.first { $0.id == messageID }?.threadId ?? threadId
        }
        var unwrappedTopics: [Item] {
            guard let topicParts else { return [self] }
            return topicParts.compactMap { part in
                part.keeping(conversation.filter { part.holds($0.id) })
            }
        }

        /// One message inside a queued conversation.
        struct Message: Codable, Sendable, Equatable {
            let id: String
            let from: String
            let subject: String
            let date: String
            let snippet: String
            let internalDate: Int64
            /// Who this member went to. See `Item.recipient`.
            var recipient: String? = nil
            /// New to the user. `false` for a read message carried only as context.
            var unread: Bool = true
            var queueWeight: Int? = nil
            var exchangeID: String? = nil
            var ancestryCached: Bool? = nil
            var rfcMessageID: String? = nil
            var inReplyTo: String? = nil
            var references: String? = nil
            var threadId: String? = nil
            var topicId: String? = nil
        }

        /// The conversation's messages, with the pre-grouping shape folded in, so nothing
        /// has to branch on whether `messages` is present.
        var conversation: [Message] {
            if let messages, !messages.isEmpty { return messages }
            return [
                Message(
                    id: id, from: from, subject: subject, date: date,
                    snippet: snippet, internalDate: internalDate, recipient: recipient,
                    unread: true, threadId: threadId, topicId: topicId)
            ]
        }

        func keeping(_ members: [Message], preservingSummary: Bool = false) -> Item? {
            guard let newest = members.max(by: { $0.internalDate < $1.internalDate }) else { return nil }
            var result = self
            result.messages = members.sorted { $0.internalDate < $1.internalDate }
            result.threadId = newest.threadId ?? threadId
            result.topicId = newest.topicId ?? topicId
            if let parts = topicParts {
                result.topicParts = parts.compactMap { part in part.keeping(members.filter { part.holds($0.id) }) }
                if result.topicParts?.count == 1, let part = result.topicParts?.first {
                    result.topicParts = nil
                    result.displayGroupID = part.displayGroupID
                    result.exchangeContext = part.exchangeContext
                    result.summaryMessages = part.summaryMessages
                }
            }
            result.id = newest.id
            result.from = newest.from
            result.subject = newest.subject
            result.date = newest.date
            result.snippet = newest.snippet
            result.internalDate = newest.internalDate
            if !preservingSummary, displayGroupID == "read-thread", !Set(ids).isSubset(of: Set(members.map(\.id))) {
                result.displayGroupID = nil
                result.threadReadVerified = false
                result.summaryMessages = nil
            }
            return result
        }

        /// Every Gmail id this item stands for.
        var ids: [String] { conversation.map(\.id) }

        /// Does this item hold that message?
        func holds(_ candidate: String) -> Bool {
            !candidate.isEmpty && (id == candidate || messages?.contains { $0.id == candidate } == true)
        }

        var unreadCount: Int {
            guard let messages, !messages.isEmpty else { return 1 }
            return messages.filter(\.unread).count
        }
    }

    /// A dispatched job's answer, waiting for a step to be spoken in.
    struct Outcome: Sendable {
        let jobId: UUID
        let task: String
        let text: String
        /// `false` when the job is known not to have finished. `nil` means the prose in `text`
        /// is the whole account of how it went — never that it worked.
        let ok: Bool?
        /// Whether the user is owed the substance of `text` or just the fact of it, as the model said
        /// at handoff (`dispatch`'s `expects`). `nil` reads as `.answer`; see `shape`.
        let expects: Shape?
        /// The message this job was handed over about, so an answer can be served on it. Built from
        /// this queue's own item, never by parsing `standingOnJSON`.
        let about: About?
        /// An answer to a request unrelated to the mail; it rides a step but is never about it.
        var independent = false
        var taskRevision: Int? = nil
        var taskState: String? = nil

        /// The fields that name a message and let a write land on it. Not the `Item` itself: `snippet`
        /// is content and `internalDate` is a cursor, and neither belongs in a referent.
        struct About: Sendable {
            let account: String
            let id: String
            let threadId: String
            /// The sender, in whatever form `Item.from` holds it — this side does not split
            /// the address off, and `presentedFields` says why.
            let from: String
            let subject: String
        }

        /// Whether a handed-off job owes the user an answer or a receipt.
        enum Shape: String, Codable, Sendable {
            case answer
            case receipt
        }

        /// Which note this outcome gets. `nil` means `.answer`: an over-full receipt costs a sentence,
        /// but a compressed answer is lost silently.
        var shape: Shape { expects == .receipt ? .receipt : .answer }

        /// Whether this answer is served on the message it was about rather than riding the next one:
        /// it needs an answer shape and a referent.
        var presents: Bool { shape == .answer && !(about?.id.isEmpty ?? true) }
    }

    /// What a step actually cost, for the tool event's OUTCOME column: did this leave the phone?
    /// The shape of the answer goes in `detail`.
    enum Served: String, Sendable {
        /// Answered off memory or the cache. Nothing over the network.
        case hit = "local_hit"
        /// A network call was awaited in the foreground, so the user waited through it.
        case live = "local_miss_live"
        /// Returned the scope question. Nothing was built and no mail was served, so this
        /// cannot be a `hit`: it would read as a message the user never heard.
        case ask = "local_ask"
        /// A stage built off pages fetched ahead of it, so the network call already happened. Its own
        /// case so the row shows whether the prefetch earns its call.
        case prefetched = "local_prefetch"
    }

    /// Where the queue is, for the chip.
    struct Progress: Sendable, Equatable {
        let account: String?
        // Both values include pruned positions in this pass; remaining counts only buffered mail.
        let position: Int
        let queued: Int
        let remaining: Int
        let done: Bool
        // Visual progress counts queue stops; message counts still drive traversal and actions.
        var displayPosition: Int? = nil
        var displayQueued: Int? = nil
        var displayRemaining: Int? = nil
        var messageId: String? = nil
        var threadId: String? = nil
    }

    /// What the model asked for.
    struct Input: Sendable {
        var direction: String?
        var restart = false
        var stop = false
        var scope: Scope?
        /// Exact connected mailbox to activate. Omitting it continues the current mailbox.
        var account: String? = nil
        /// The `scope` string as it arrived, when this build does not know it. Kept apart from an absent
        /// scope (`nil` means nobody has been asked yet) so `step` can tell the user what happened.
        var rawScope: String?
        /// The user answered no to the offer the previous step made. Undeclared in the schema
        /// and asked for by the step's own note.
        var offerDeclined = false
        /// A dispatch handoff's advance. It must hand over an email: the job's answer rides the step
        /// after it, and a tip here would strand the answer inside the lesson.
        var defersCoaching = false
    }
}
