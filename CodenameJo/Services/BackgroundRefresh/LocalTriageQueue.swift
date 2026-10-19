import Foundation
import CryptoKit
import FactoryKit

/// Model-facing queue payloads never expose mailbox counts unless the user asks for one.
enum EmailQueueSpeechContract {
    private static let hiddenCountKeys: Set<String> = ["left", "leftAtLeast", "unreadLeft"]

    static func sanitize(_ payload: [String: Any]) -> [String: Any] {
        payload.reduce(into: [:]) { clean, entry in
            guard !hiddenCountKeys.contains(entry.key) else { return }
            clean[entry.key] = sanitizeValue(entry.value)
        }
    }

    private static func sanitizeValue(_ value: Any) -> Any {
        if let object = value as? [String: Any] { return sanitize(object) }
        if let array = value as? [Any] { return array.map(sanitizeValue) }
        return value
    }
}

/// The email triage queue (`triage_next`) for one connected account, walked and acted on on this phone.
/// Pages come from `MailStore` when the cache covers the scope, otherwise from Gmail with the phone's grant.
actor LocalTriageQueue {
    private var preparationChanged: (@Sendable () async -> Void)?

    private let mailAccounts: @Sendable () async -> [String]
    private let unreadOpeningLoader: @Sendable (String) async -> [MailStore.Ingest]?
    private var enrichmentTasks: [String: Task<Void, Never>] = [:]
    private var enrichmentRequestedAgain: Set<String> = []
    private var topicRefreshPending = false
    private var includeUnreadArrivalsPending = false
    private var preparingDailySnapshot = false
    private var presentedTopicKeys: Set<String> = []

    init(liveFeatures: Bool = false, mailAccounts: @escaping @Sendable () async -> [String] = {
        // Only the active profile's inboxes. Snapshots are account-keyed, so each profile
        // resumes its own cursor.
        return ProfileRuntime.allowedMailAccounts(GoogleAccountStore.mailAccounts())
    }, unreadOpeningLoader: @escaping @Sendable (String) async -> [MailStore.Ingest]? = { account in
        guard case .success(let token) = await GoogleCredential.token(for: account) else { return nil }
        do {
            let refs = try await GmailAPI.recentMessageIds(
                token: token.accessToken, query: Scope.unread.query, limit: LocalTriageQueue.pageSize)
            let details = await GmailAPI.metadata(token: token.accessToken, ids: refs.map(\.id))
            guard details.count == refs.count else { return nil }
            return details.map { MailStore.Ingest(detail: $0, account: account) }
        } catch {
            RealtimeLog.log("localTriage: unread opening refresh failed for \(account) — \(error)")
            return nil
        }
    }) {
        self.mailAccounts = mailAccounts
        self.unreadOpeningLoader = unreadOpeningLoader
        self.liveFeatures = liveFeatures
    }

    /// Only a presented queue item grants automatic account selection.
    private var profileHandoff = FeedProfileHandoff()
    private var feedProfileId: String?

    func configureProfileHandoff(current: WorkspaceProfile?, profiles: [WorkspaceProfile],
                                 enabled: Bool, newCall: Bool = false) {
        if newCall { profileHandoff = FeedProfileHandoff() }
        let profileChanged = feedProfileId != current?.id
        feedProfileId = current?.id
        profileHandoff.configure(current: current, profiles: profiles, enabled: enabled)
        if !newCall { feedEligible = sequentialFeed }
        if dynamicSlackFeed && (newCall || profileChanged) {
            slackFeedPrefetch?.cancel()
            slackFeedPrefetched = nil
            importantSlackServed = false
            let scope = ProfileRuntime.snapshot
            slackFeedPrefetch = Task {
                let loaded = await SlackQueueRefresh.forFeed(scope: scope)
                if !Task.isCancelled { self.slackFeedPrefetched = (scope?.profileId, loaded) }
                return loaded
            }
        }
    }

    func updateProfileCatalog(current: WorkspaceProfile?, profiles: [WorkspaceProfile], enabled: Bool) {
        profileHandoff.configure(current: current, profiles: profiles, enabled: enabled)
    }

    private var mailboxUpdateInFlight = false

    private func synchronizedStep(
        _ input: Input, store: MailStore, startsNewSession: Bool = false, dealtWith: Bool = true
    ) async -> (output: String, served: Served) {
        guard !mailboxUpdateInFlight else {
            return (Self.json(["note": "The inbox switch is still being confirmed. Retry this step."]), .ask)
        }
        if topicRefreshPending { await refreshTopicMembership(store: store) }
        mailboxUpdateInFlight = true
        defer {
            mailboxUpdateInFlight = false
            if topicRefreshPending { Task { await self.refreshTopicMembership(store: store) } }
        }
        return await stepWithoutWaitingForPreparation(
            input, store: store,
            startsNewSession: startsNewSession, dealtWith: dealtWith)
    }

    /// How an item is presented, per voice model. Live reads the message because it invents senders
    /// and subjects from the step alone; Realtime is accurate from the snippet.
    private static let liveBodySummary =
        "Automatically include what its body is about and what the sender wants, in your own "
            + "words. Delegate retrieval of the current message body unless it is already "
            + "supplied. Never volunteer when it was sent; give the sent date only if they ask, "
            + "and then use the message's own date, never one from the body. If unavailable, say "
            + "so. Summarize only this selected chain and its latest reply; retrieve needed "
            + "members without mixing other chains. Do not advance for retrieval. "
    private static let realtimeBodySummary =
        "Say what it is about from item.subject, item.snippet and the supplied conversation "
            + "context. Presenting an item costs no tool call: never read the message, search "
            + "context for its body, or announce a lookup. Never volunteer when it was sent; "
            + "give the sent date only if they ask, and then use item.date. Summarize only this "
            + "selected chain and its latest reply from the context supplied, never mixing other "
            + "chains. Only an explicit request for what it says or for more detail calls the "
            + "full-message read tool, and only then may the summary be extended. "

    var currentMailbox: String? {
        guard running, position >= 1, position <= items.count else { return nil }
        return items[position - 1].account
    }

    private var activeAccount: String?
    private var completedAccounts: Set<String> = []
    private var offeredAccount: String?

    /// The connected mailboxes as read when this walk began. Every step asked the Keychain again;
    /// `end` drops the cache, and a connect or disconnect ends the queue.
    private var walkAccounts: [String]?

    private func queueAccounts() async -> [String] {
        let connected: [String]
        if running, let walkAccounts {
            connected = walkAccounts
        } else {
            connected = await mailAccounts()
            if running { walkAccounts = connected }
        }
        guard !connected.isEmpty else { return [] }
        if let activeAccount,
           let match = connected.first(where: {
               $0.caseInsensitiveCompare(activeAccount) == .orderedSame
           }) {
            self.activeAccount = match
            return [match]
        }
        activeAccount = connected[0]
        return [connected[0]]
    }

    /// How many messages a page holds. A latency choice: the runway a background top-up has to
    /// hide the next fetch behind.
    static let pageSize = 12
    static let coachingEvery = 12

    nonisolated static func calendarReadTool(localCalendar: Bool) -> String {
        localCalendar ? "search_calendar" : "list_calendar_events"
    }

    /// Tools whose receipt is the whole turn: the model says nothing before calling them and leads
    /// with the receipt, so nothing composes in front of it. Canonicalised the way `markActed` stores it.
    private static let receiptAfterActing: Set<String> = [
        "send_email", "forward_email", "create_draft", "unsubscribe_sender",
    ]

    /// How close to the end of the buffer a top-up starts.
    static let topUpAt = 5


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

        /// Whether reaching the end of this queue means the inbox is actually clear. Only `unread`:
        /// `all` and `important` leave mail behind.
        var meansInboxZero: Bool { self == .unread }

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
        let position: Int
        let queued: Int
        let remaining: Int
        let done: Bool
        // Visual progress counts queue stops; message counts still drive traversal and actions.
        var displayPosition: Int? = nil
        var displayQueued: Int? = nil
        var displayRemaining: Int? = nil
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
        var onboardingMailMode: String? = nil
        /// The user answered no to the offer the previous step made. Undeclared in the schema
        /// and asked for by the step's own note, like `onboarding_mail_mode`.
        var offerDeclined = false
        /// A dispatch handoff's advance. It must hand over an email: the job's answer rides the step
        /// after it, and a tip here would strand the answer inside the lesson.
        var defersCoaching = false
    }

    // MARK: - State

    private var items: [Item] = []
    private var grouping = false
    private var topicGrouping = false
    /// The mode this walk captured, not the current setting.
    var groupsThreads: Bool { grouping }
    var coachingHandled: Int { handledForCoaching }
    /// True when the queue is a handful handed in by `adopt` rather than a mailbox walk, so the
    /// closing sentences do not claim the whole inbox is done.
    private var adopted = false
    /// 1-based. Zero means no queue is running.
    private var position = 0
    /// Items handled before a restored compact tail. Keeps spoken progress on the original
    /// queue ordinal while the in-memory array contains only unresolved work.
    private var ordinalOffset = 0
    /// Epoch **seconds**, the bound for the next page. Nil means there has been no page yet.
    private var before: Int64?
    private var more = false
    /// How much mail matches the query, off Gmail's own label counter.
    private var total = 0
    /// The mailbox's unread count as the walk started, for the Live Activity's fraction. A snapshot
    /// because archiving decrements the live count, which would shrink the denominator under the walk.
    private var mailboxUnreadAtStart = 0
    private var scope: Scope = .unread
    /// Which importance band is being walked; nil when the walk is not banded. A band only orders
    /// mail and is not a scope, so a band boundary never gets a scope's close sentences.
    private var band: String?
    /// The score half of a band walk's cursor — see `MailStore.unreadPage(beforeScore:)`.
    /// Reset with `before` at every band crossing, because each band pages from its top.
    private var beforeScore: Int?
    private var beforeID: String?
    /// True when this queue's scope came off the saved default rather than out of the
    /// user's mouth, so the opening step names the pile once. Cleared as it is used.
    private var scopeUnsaid = false
    /// Set when an important walk is built, so its first step says the top few as a list.
    /// Cleared as it is used.
    private var rankedPending = false
    /// An automatic important-week opening checks the week's bands once before its first message.
    private var nothingImportantCheck = false
    /// The opening said there is nothing important and asked about cleanup; a plain next serves item 1.
    private var nothingImportantStanding = false
    private var running = false
    /// Stage crossings replace `items`. Retain completed stages so voice navigation can cross
    /// those otherwise destructive boundaries.
    private struct NavigationStage {
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
    private var earlierStages: [NavigationStage] = []
    private var laterStages: [NavigationStage] = []
    private var navigationExcludedIDs: Set<String> = []
    /// Dispatched jobs that have come back, oldest first. One is served per step and the
    /// cursor does not move for it — see `hold` and `step`.
    private var outcomes: [Outcome] = []
    /// Results stay with the mailbox whose cursor produced them while another inbox is active.
    private var pausedOutcomes: [String: [Outcome]] = [:]
    /// The researched email presented over the live queue cursor. Acting on it must finish the
    /// suspended step the held answer consumed, not count as an unrelated write behind the cursor.
    private struct ActionOutcome {
        let about: Outcome.About
        let messageId: String
        let threadId: String
        /// Whether the intercepted step may finish the cursor message. False for an answer-shaped
        /// dispatch, which must not mark an email read just because the user asked about it.
        let dealtWith: Bool
    }
    private var actionOutcome: ActionOutcome?

    struct ActionOutcomeResolution: Sendable, Equatable {
        let cursorId: String
        let dealtWith: Bool
    }
    /// Jobs whose answer has reached a payload, waiting to be reported to the caller so the
    /// row can be marked delivered. Read once and cleared — see `takeServedOutcomes`.
    private var served: [UUID] = []
    /// The fetch in flight, so a second caller waits for it rather than skipping it; skipping lets a
    /// fast "next" find nothing fetched and report the queue finished.
    private var refillTask: Task<Bool, Never>?
    /// Ids the user has finished with (acted on or skipped), against when. Survives rebuilds and calls
    /// so finished mail is not offered again; pruned by `dealtWithMaxAge` and `dealtWithCap`.
    private var dealtAt: [String: Double] = [:]
    private var ledgerUserID: String?
    private var ledgerSaveTask: Task<Void, Never>?
    /// Gmail ids finished during this logical walk. Unlike `dealtAt`, this is not a seven-day
    /// history: read mail from an earlier walk still belongs in a later `all` queue.
    private var gmailWalkDealtWith: Set<String> = []
    private var summarizedReadThreads: Set<String> = []
    /// Cached IDs covered by Dispatch during this queue, including later cached pages.
    private var dispatchSweepIDs: Set<String> = []
    /// Which walk the state belongs to, bumped by everything that replaces or clears a queue, so a
    /// page in flight cannot append into or stall a newer queue.
    private var generation = 0
    /// Saved buffer and its cursor offsets; unchanged tails need only a cursor write.
    private var savedBuffer: (key: String, items: [Item], trimmedItems: Int, trimmedOrdinals: Int,
                              itemCount: Int, ordinalOffset: Int)?
    private var reconciliationLifetime = 0
    private var queueBuildsInFlight = 0
    private var confirmedEffectsRevision = 0
    /// Mailbox owning the checkpoint. Set from the cache state even for an empty queue.
    private var snapshotAccount: String?
    private var restoredServedForLastStep: Served?
    /// A restore is a presentation, not an advance. The opening's first no-argument call
    /// must return the unresolved current message before any cursor mutation occurs.
    private var restoredNeedsCurrent = false
    /// Unique forward departures across pages and section boundaries.
    private var handledForCoaching = 0 { didSet { saveCoachingCadence() } }
    /// Last twelve-message checkpoint attached to a model-visible result.
    private var lastCoachingCheckpoint = 0 { didSet { saveCoachingCadence() } }
    /// The day the two counters above belong to, so they roll over with it.
    private var coachingDay = ""
    private var coachingCadenceKey = ""
    /// Launch-time preparation in flight, so a voice turn waits for it instead of starting a second build.
    /// The preparation body calls `stepWithoutWaitingForPreparation` so it never waits on itself.
    private var preparationTask: Task<Void, Never>?
    private var onboardingFlow: EmailOnboardingFlow?
    private var onboardingMailModePending = false
    private var onboardingMailModeResumeAdvance = false
    private var onboardingMailModeReceipt: OnboardingMailModeReceipt?
    private var onboardingPreferenceSaved: (@Sendable (OnboardingMailPreference) async -> Void)?
    private var onboardingModeSaver: (@Sendable (String) async throws -> OnboardingMailModeReceipt)?
    private var onboardingItems: [String: EmailOnboardingItem] = [:]
    private var onboardingPreparation: Task<EmailOnboardingSelection, Never>?
    private var onboardingPrepared = false
    private var onboardingCompletionPresented = false {
        didSet { if onboardingCompletionPresented { OnboardingResume.finish() } }
    }
    /// A resumed run skips the steps an earlier call already walked.
    private var onboardingResumeStep = 0
    private var onboardingFailures: [String] = []
    private var onboardingExcludedThreads: Set<String> = []
    /// Eligibility, not copy: a lesson's words stay off the checkpoint until the user accepts. An empty
    /// plan suppresses tips while still consuming checkpoints; nil suppresses the tip entirely.
    private var coachingPlan: FullDuplexBroker.CoachingPlan?
    private var coachingPlanPosition = 0
    private var localCoachingDelivery = false
    /// A fresh onboarding always teaches the Feed first, even when this account's durable
    /// coaching rotation has already seen that lesson on another install.
    private var forceOnboardingFeedLesson = false
    /// Accepted per-session mode. `feedEligible` is then narrowed to an automatic walk;
    /// a named scope, explicit stop or failed load never reaches the fallback.
    private var sequentialFeed = false
    private var feedEligible = false
    private var feedEmitted = false
    private var pageFeedPresented = false
    private var feedCoachingOrdinal = 0
    private var calendarFeedDue = false
    /// The calendar stage's rest-of-today, started at session setup so the stage never waits on it.
    private var calendarAgendaPrefetch: Task<CalendarSearch.Result?, Never>?
    /// The events the last inlined calendar stage carried, for the Feed card.
    private(set) var inlinedCalendarEvents: [CalendarStore.Event] = []
    /// The Feed reaches Slack for the active profile; the sweep starts with the call.
    private var dynamicSlackFeed = false
    private var slackFeedPrefetch: Task<SlackQueueCache.Loaded?, Never>?
    /// The prefetch's answer once it has landed. Read by the important-Slack stage, which
    /// runs mid-walk and must never wait on the network to serve the next email.
    private var slackFeedPrefetched: (profileId: String?, loaded: SlackQueueCache.Loaded?)?
    private var importantSlackStage = false
    /// Offered at most once per profile per call.
    private var importantSlackServed = false
    private var declinedCleanups: Set<String> = []
    /// Sender-and-category cleanups already put to the user in this call. The offer is put
    /// once whether or not the no ever reaches us.
    private var offeredCleanups: Set<String> = []
    /// The cleanup offer the last step put to the user.
    private var standingOffer: String?

    private typealias SnapshotPayload = TriageQueueSnapshotStore.Payload

    /// How long a prefetched page stays usable.
    static let prefetchFreshness: TimeInterval = 300

    private typealias InboxAhead = TriageQueueBuilder.InboxAhead
    private var inboxAheadTask: Task<Void, Never>?
    private var inboxAhead: InboxAhead?
    /// The other mailboxes of this profile being prepared on scratch queues — see `prefetchOtherMailboxes`.
    private var mailboxAheadTask: Task<Void, Never>?
    /// Lowercased mailboxes prepared ahead in this conversation; once per call is enough.
    private var mailboxesPreparedAhead: Set<String> = []
    /// Every other mailbox is prepared (or there is none), so a step need not look again this call.
    private var mailboxAheadSettled = false
    /// Off on a scratch queue, which prepares one mailbox and must not prepare the others in turn.
    private var prefetchesOtherMailboxes = true
    /// Thread context carried by today's row, keyed by `threadKey`, so a page rebuilt from the cache
    /// reuses it instead of asking Gmail for each thread again — see `enrichThreadContext`.
    private var restoredThreadContexts: [String: Item] = [:]
    /// The pages the crossing build may still read; nil once one missed, so the row says live.
    private var inboxAheadPages: [Int64?: LivePageResult]?

    /// How long a step waits for an uncached cleanup lookup before presenting without it.
    static let cleanupWait: Duration = .milliseconds(400)
    /// A page that should have arrived and did not, so the buffer ran out with mail behind it.
    /// Closing there would tell the user they had been through mail they are in the middle of.
    private var stalled = false

    /// Gmail scopes covered by an automatic daily walk. Explicitly scoped queues leave it empty.
    private var scopePlan: [Scope] = []

    /// The Gmail scope just finished when the current step starts the next planned scope.
    private var crossedFromScope: Scope?

    /// What follows the Gmail scope in hand, or nil when this queue is explicitly bounded.
    private func nextScopeInPlan() -> Scope? {
        guard let at = scopePlan.firstIndex(of: scope),
              scopePlan.indices.contains(at + 1)
        else { return nil }
        return scopePlan[at + 1]
    }

    private func navigationStage(position savedPosition: Int? = nil) -> NavigationStage {
        NavigationStage(
            items: items, grouping: grouping, topicGrouping: topicGrouping, adopted: adopted,
            position: savedPosition ?? position, ordinalOffset: ordinalOffset,
            before: before, more: more, total: total,
            mailboxUnreadAtStart: mailboxUnreadAtStart, scope: scope,
            scopeUnsaid: scopeUnsaid, scopePlan: scopePlan, stalled: stalled)
    }

    private func navigableStage(_ stage: NavigationStage) -> NavigationStage? {
        let retained = stage.items.compactMap {
            navigableItem($0, scope: stage.scope, grouping: stage.grouping)
        }
        guard !retained.isEmpty else { return nil }
        let retainedThroughPosition = stage.items.prefix(stage.position)
            .compactMap { navigableItem($0, scope: stage.scope, grouping: stage.grouping) }
            .count
        let originalCount = stage.items.reduce(0) {
            $0 + Self.messageCount($1, scope: stage.scope, grouping: stage.grouping)
        }
        let retainedCount = retained.reduce(0) {
            $0 + Self.messageCount($1, scope: stage.scope, grouping: stage.grouping)
        }
        return NavigationStage(
            items: retained, grouping: stage.grouping, topicGrouping: stage.topicGrouping, adopted: stage.adopted,
            position: min(retained.count, max(1, retainedThroughPosition)),
            ordinalOffset: stage.ordinalOffset, before: stage.before,
            more: stage.more,
            total: max(0, stage.total - originalCount + retainedCount),
            mailboxUnreadAtStart: stage.mailboxUnreadAtStart, scope: stage.scope,
            scopeUnsaid: stage.scopeUnsaid, scopePlan: stage.scopePlan, stalled: stage.stalled)
    }

    private func navigableItem(_ item: Item, scope: Scope, grouping: Bool) -> Item? {
        guard let retained = item.keeping(item.conversation.filter({ member in
            !navigationExcludedIDs.contains(
                Self.messageKey(account: item.account, id: member.id))
                && !pendingArchives.contains {
                    $0.matches(account: item.account, ids: [member.id], threadId: member.threadId ?? item.threadId)
                }
        })) else { return nil }
        return Self.messageCount(retained, scope: scope, grouping: grouping) > 0
            ? retained : nil
    }

    private func restoreNavigationStage(_ stage: NavigationStage) {
        savedBuffer = nil
        items = stage.items
        grouping = stage.grouping
        topicGrouping = stage.topicGrouping
        adopted = stage.adopted
        position = stage.position
        ordinalOffset = stage.ordinalOffset
        before = stage.before
        more = stage.more
        total = stage.total
        mailboxUnreadAtStart = stage.mailboxUnreadAtStart
        scope = stage.scope
        scopeUnsaid = stage.scopeUnsaid
        scopePlan = stage.scopePlan
        stalled = stage.stalled
        crossedFromScope = nil
        running = true
        actionOutcome = nil
    }

    private func retainStageBeforeCrossing() {
        guard !items.isEmpty else { return }
        earlierStages.append(navigationStage(position: min(items.count, max(1, position - 1))))
        laterStages = []
    }

    private func cancelStageWork() {
        generation &+= 1
        refillTask?.cancel()
        refillTask = nil
    }

    private func clearStageNavigation() {
        earlierStages = []
        laterStages = []
        navigationExcludedIDs = []
    }

    /// Remember mail removed by a successful action with no structured Gmail effect. Saved stages are
    /// snapshots, so pruning only `items` would let it return when navigation crosses a stage.
    private func excludeFromNavigation(
        senders rawSenders: [String] = [], ids rawIds: Set<String> = [],
        threadId: String? = nil, account: String? = nil
    ) {
        let senders = rawSenders.map { TriageDispatchReconciler.addressIn($0) }.filter { !$0.isEmpty }
        guard !senders.isEmpty || !rawIds.isEmpty || threadId != nil else { return }
        let stages = earlierStages + laterStages
        let historical = stages.flatMap(\.items).filter { item in
            guard let account else { return true }
            return item.account.caseInsensitiveCompare(account) == .orderedSame
        }.flatMap { item in
            item.conversation.compactMap { member -> String? in
                let matches = rawIds.contains(member.id)
                    || (threadId != nil && item.threadId == threadId)
                    || (!senders.isEmpty && TriageDispatchReconciler.sentBy(member.from, senders))
                return matches ? Self.messageKey(account: item.account, id: member.id) : nil
            }
        }
        navigationExcludedIDs.formUnion(historical)
    }

    @discardableResult
    private func updateNavigationExclusions(
        for effect: GmailWriteEffect, ids: Set<String>
    ) -> (laterHeld: Set<String>, requeued: [Item]) {
        let earlierHeld = Self.navigationIDs(in: earlierStages, for: effect, ids: ids)
        let laterHeld = Self.navigationIDs(in: laterStages, for: effect, ids: ids)
        let affected = ids.union(earlierHeld).union(laterHeld)
        let keys = Set(affected.map { Self.messageKey(account: effect.account, id: $0) })
        var requeued: [Item] = []
        if effect.added.contains("INBOX") {
            navigationExcludedIDs.subtract(keys)
            // Requeued mail from behind the cursor belongs in the active continuation, not
            // both there and in its historical stage. Mail still ahead stays in that stage.
            requeued = Self.takeNavigationItems(
                &earlierStages, ids: earlierHeld, account: effect.account)
            Self.restoreNavigationItems(&laterStages, ids: laterHeld, account: effect.account)
        } else if effect.removesFromInbox { navigationExcludedIDs.formUnion(keys) }
        Self.applyNavigationEffect(&earlierStages, effect: effect, ids: affected)
        Self.applyNavigationEffect(&laterStages, effect: effect, ids: affected)
        return (laterHeld, requeued)
    }

    private static func navigationIDs(
        in stages: [NavigationStage], for effect: GmailWriteEffect, ids: Set<String>
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

    private static func restoreNavigationItems(
        _ stages: inout [NavigationStage], ids: Set<String>, account: String
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

    private static func takeNavigationItems(
        _ stages: inout [NavigationStage], ids: Set<String>, account: String
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

    private static func applyNavigationEffect(
        _ stages: inout [NavigationStage], effect: GmailWriteEffect, ids: Set<String>
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

    private var pendingArchives: [PendingArchive] = []
    private var archiveStatusLoaded = false
    private var liveFeatures = false

    /// The tip cadence belongs to the account, not a mailbox, so profile switches, scope changes and
    /// stops do not reset it; only the day does.
    private func loadCoachingCadence() async {
        let userId = await MainActor.run { Container.shared.backend().userId ?? "" }
        coachingCadenceKey = "dailyEmailQueueCoachingCadence.\(userId)"
        let saved = UserDefaults.standard.dictionary(forKey: coachingCadenceKey) ?? [:]
        coachingDay = Self.localDay()
        let sameDay = saved["day"] as? String == coachingDay
        handledForCoaching = sameDay ? max(0, saved["handled"] as? Int ?? 0) : 0
        lastCoachingCheckpoint = sameDay ? max(0, saved["checkpoint"] as? Int ?? 0) : 0
    }

    private func saveCoachingCadence() {
        guard !coachingCadenceKey.isEmpty else { return }
        UserDefaults.standard.set(
            ["day": coachingDay, "handled": handledForCoaching,
             "checkpoint": lastCoachingCheckpoint],
            forKey: coachingCadenceKey)
    }

    /// Hand the queue what a call needs. Called once, at connect.
    func configure(
        liveFeatures: Bool = false,
        coachingPlan: FullDuplexBroker.CoachingPlan?,
        localCoachingDelivery: Bool = false,
        forceOnboardingFeedLesson: Bool,
        sequentialFeed: Bool,
        calendarFeedDue: Bool,
        dynamicSlackFeed: Bool = false,
        importantSlackStage: Bool = false,
        localCalendar: Bool,
        onboardingFlow: EmailOnboardingFlow? = nil,
        onboardingLoader: (@Sendable () async -> EmailOnboardingSelection)? = nil,
        onboardingModeSaver: (@Sendable (String) async throws -> OnboardingMailModeReceipt)? = nil,
        onboardingPreferenceSaved: (@Sendable (OnboardingMailPreference) async -> Void)? = nil,
        preparationChanged: (@Sendable () async -> Void)? = nil
    ) async {
        // App-open preparation owns the actor until its checkpoint is durable, so session setup waits
        // for the one already-running preparation task before installing its configuration.
        if let preparationTask { await preparationTask.value }
        self.liveFeatures = liveFeatures
        self.preparationChanged = preparationChanged
        reconciliationLifetime &+= 1
        archiveStatusLoaded = false
        // Rewound only for a new plan: re-preparing mid-call must not replay lessons given.
        if self.coachingPlan != coachingPlan { coachingPlanPosition = 0 }
        await loadCoachingCadence()
        self.coachingPlan = coachingPlan
        self.localCoachingDelivery = localCoachingDelivery
        self.forceOnboardingFeedLesson = forceOnboardingFeedLesson
        self.sequentialFeed = sequentialFeed
        feedEligible = sequentialFeed
        feedEmitted = false
        pageFeedPresented = false
        self.calendarFeedDue = calendarFeedDue
        calendarAgendaPrefetch?.cancel()
        calendarAgendaPrefetch = calendarFeedDue && sequentialFeed
            ? Task {
                let granted = GoogleAccountStore.all()
                    .filter { GoogleCredential.calendarScopes.allSatisfy($0.scopes.contains) }
                    .map(\.email)
                return await CalendarSearch.feedAgenda(
                    accounts: ProfileRuntime.allowedMailAccounts(granted),
                    store: CalendarStore(database: Container.shared.localContext().dbPool))
            }
            : nil
        inlinedCalendarEvents = []
        self.dynamicSlackFeed = dynamicSlackFeed
        self.importantSlackStage = importantSlackStage
        RealtimeLog.log("localTriage: important Slack stage \(importantSlackStage ? "on" : "off")")
        importantSlackServed = false
        slackFeedPrefetch?.cancel()
        slackFeedPrefetch = nil
        slackFeedPrefetched = nil
        // Seeded once per dial, pruned on the way in — see `dealtAt`. Cheap: a bounded JSON read.
        await loadDealtWith()
        // Repair the local inbox before opening a saved queue. The write itself stays
        // deferred; a completed receipt is verified against Gmail so undo/new replies win.
        let writes = Container.shared.pendingMailWrites()
        let userId = await MainActor.run { Container.shared.backend().userId ?? "" }
        writes.drainSoon(userId: userId)
        if liveFeatures {
            await reconcileArchives(await writes.status(userId: userId), store: Container.shared.mailStore())
        } else {
            pendingArchives = await writes.pending(userId: userId)
        }
        if let onboardingFlow, [1, 2].contains(onboardingFlow.version) {
            if self.onboardingFlow?.runId != onboardingFlow.runId {
                await end()
                self.onboardingFlow = onboardingFlow
                self.onboardingMailModePending = onboardingFlow.mailModeChoice?.status == "pending"
                self.onboardingModeSaver = onboardingModeSaver
                onboardingResumeStep = onboardingFlow.resume == true ? OnboardingResume.step : 0
                for seeded in onboardingFlow.seededItems
                where (seeded.kind(in: onboardingFlow.config) != "welcome" || onboardingFlow.mailPreference == nil)
                    && seeded.onboardingStep >= onboardingResumeStep {
                    items.append(seeded.queueItem)
                    onboardingItems[seeded.id] = seeded
                }
                scope = .all
                onboardingPreparation = Task {
                    if let onboardingLoader { return await onboardingLoader() }
                    let store = await Container.shared.mailStore()
                    async let about = EmailOnboardingContract.aboutItem(flow: onboardingFlow, store: store)
                    let mail = await LocalOnboardingMail.prepare(flow: onboardingFlow, store: store)
                    guard let about = await about else { return mail }
                    return .init(items: mail.items + [about], failures: mail.failures)
                }
            }
            self.onboardingModeSaver = onboardingModeSaver
            self.onboardingPreferenceSaved = onboardingPreferenceSaved
            if let preference = onboardingFlow.mailPreference {
                self.onboardingFlow?.mailPreference = preference
                self.onboardingFlow?.mailModeChoice = onboardingFlow.mailModeChoice
                if running, position >= 1, position <= items.count, onboardingOnWelcome {
                    onboardingMailModePending = false
                    onboardingMailModeResumeAdvance = true
                }
            }
            feedEligible = false
        }
    }

    /// Prepare the automatic daily queue after the launch mail refresh, through `step`, without publishing
    /// a tool event. The next call consumes the row through `restoreIfAvailable`.
    func prepareDailySnapshot(
        store: MailStore, liveFeatures: Bool = false
    ) async {
        guard AgentLedEmailSettings.isEnabled else { return }
        let callActive = await MainActor.run { Container.shared.realtimeService().isConversing }
        guard !callActive else {
            RealtimeLog.log("localTriage: launch preparation skipped — call active")
            return
        }
        if let preparationTask {
            await preparationTask.value
            return
        }
        // A call already owns this actor. Its ordinary checkpoints are fresher and more meaningful
        // than anything an app lifecycle callback could prepare beside it.
        guard !running, !mailboxUpdateInFlight else {
            RealtimeLog.log("localTriage: launch preparation skipped — queue running or opening")
            return
        }

        self.liveFeatures = liveFeatures
        archiveStatusLoaded = false
        pendingArchives = []
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performDailySnapshotPreparation(store: store)
        }
        preparationTask = task
        await task.value
        preparationTask = nil
    }

    private func performDailySnapshotPreparation(store: MailStore) async {
        preparingDailySnapshot = true
        defer { preparingDailySnapshot = false }
        let started = Date()
        coachingPlan = nil
        coachingPlanPosition = 0
        localCoachingDelivery = false
        forceOnboardingFeedLesson = false
        sequentialFeed = false
        feedEligible = false
        feedEmitted = false
        pageFeedPresented = false
        calendarFeedDue = false
        calendarAgendaPrefetch?.cancel()
        calendarAgendaPrefetch = nil
        inlinedCalendarEvents = []
        dynamicSlackFeed = false
        importantSlackStage = false
        slackFeedPrefetch?.cancel()
        slackFeedPrefetch = nil
        slackFeedPrefetched = nil
        await loadDealtWith()

        // Every mailbox the profile may walk, not only the first: a switch mid-call restores the
        // other mailbox's row from disc instead of building it in front of the user.
        let mailboxes = await mailAccounts()
        var prepared = 0
        for (index, mailbox) in mailboxes.enumerated() {
            if index > 0 {
                // A call that began while the first mailbox was being prepared owns the actor
                // from here; its own checkpoints are fresher than anything prepared beside it.
                let callActive = await MainActor.run { Container.shared.realtimeService().isConversing }
                guard !callActive else {
                    RealtimeLog.log("localTriage: daily preparation stopped before \(mailbox) — call active")
                    break
                }
                await end(preservingMailboxState: true)
            }
            let result = await prepareSnapshot(for: mailbox, store: store)
            prepared += 1
            RealtimeLog.log(
                "localTriage: daily snapshot prepared \(result.served.rawValue) for \(mailbox)"
                    + String(format: " in %.0f ms", result.ms))
        }
        // After the last row has landed, so every mailbox's opening candidates come off its own snapshot.
        if prepared > 0 { await warmOpeningSummary(store: store, restart: true) }
        let ms = Date().timeIntervalSince(started) * 1_000
        RealtimeLog.log(
            "localTriage: daily snapshot prepared \(prepared) of \(mailboxes.count) mailbox(es)"
                + String(format: " in %.0f ms", ms))
        // The durable row is the product of this work. The in-memory cursor still belongs to a
        // conversation, and leaving it running would make the first call advance past item one.
        await end()
    }

    /// Build or refresh today's row for one mailbox through `step`, and warm the cleanup decisions
    /// for its first few items. Leaves the queue running on that mailbox; the caller ends it.
    private func prepareSnapshot(for mailbox: String, store: MailStore) async -> (served: Served, ms: Double) {
        let started = Date()
        activeAccount = mailbox
        snapshotAccount = mailbox
        let result = await stepWithoutWaitingForPreparation(
            Input(), store: store, startsNewSession: true)
        if running, !items.isEmpty {
            let warmEnd = min(items.count, position + 7)
            let inputs = items[(position - 1)..<warmEnd].map { Self.cleanupInput($0) }
            let userId = await MainActor.run { Container.shared.backend().userId ?? "" }
            await Container.shared.emailCleanup().prefetch(
                inputs, userId: userId, store: store)
            RealtimeLog.log("emailCleanup: warming \(inputs.count) prepared queue item(s) for \(mailbox)")
        }
        return (result.served, Date().timeIntervalSince(started) * 1_000)
    }

    /// Prepare the other mailboxes of this profile on a scratch queue, so a switch mid-call restores
    /// a row written minutes ago. Modelled on `prefetchInboxStage`: one mailbox at a time, so the
    /// Gmail quota is shared with the walk in front of the user rather than contended for.
    private func prefetchOtherMailboxes(store: MailStore) {
        guard prefetchesOtherMailboxes, !mailboxAheadSettled, running, position >= 1, onboardingFlow == nil,
              !preparingDailySnapshot, mailboxAheadTask == nil else { return }
        let current = (activeAccount ?? snapshotAccount ?? items.first?.account)?.lowercased()
        let lifetime = reconciliationLifetime
        mailboxAheadTask = Task { [weak self] in
            await self?.prepareOtherMailboxes(current: current, lifetime: lifetime, store: store)
        }
    }

    private func prepareOtherMailboxes(current: String?, lifetime: Int, store: MailStore) async {
        defer { mailboxAheadTask = nil }
        let others = await mailAccounts().filter {
            $0.lowercased() != current && !mailboxesPreparedAhead.contains($0.lowercased())
        }
        guard !others.isEmpty else {
            mailboxAheadSettled = true
            return
        }
        for mailbox in others {
            guard !Task.isCancelled, reconciliationLifetime == lifetime else { return }
            let started = Date()
            let scratch = LocalTriageQueue(
                liveFeatures: liveFeatures, mailAccounts: { [mailbox] },
                unreadOpeningLoader: unreadOpeningLoader)
            let served = await scratch.prepareMailboxAhead(store: store)
            // A profile switch or disconnect ends this queue and drops the prefetch with it; a row
            // written for a mailbox that is no longer ours is harmless, but nothing is warmed for it.
            guard !Task.isCancelled, reconciliationLifetime == lifetime,
                  await mailAccounts().contains(where: { $0.lowercased() == mailbox.lowercased() })
            else { return }
            mailboxesPreparedAhead.insert(mailbox.lowercased())
            RealtimeLog.log(
                "mailboxAhead: prepared \(mailbox) \(served?.rawValue ?? "nothing") in "
                    + String(format: "%.0f", Date().timeIntervalSince(started) * 1000) + "ms")
        }
        // The first three summaries of each prepared mailbox, off their fresh rows.
        await warmOpeningSummary(store: store, restart: true)
    }

    /// Today's row for this queue's one mailbox, built on a scratch instance while another queue
    /// walks in front of the user. No call-active guard: the call is the reason this runs.
    func prepareMailboxAhead(store: MailStore) async -> Served? {
        guard !running, preparationTask == nil else { return nil }
        prefetchesOtherMailboxes = false
        preparingDailySnapshot = true
        defer { preparingDailySnapshot = false }
        await loadDealtWith()
        guard let mailbox = await mailAccounts().first else { return nil }
        let result = await prepareSnapshot(for: mailbox, store: store)
        await end()
        return result.served
    }

    /// Tests await the prefetch they started; nothing in production ever waits on it.
    func awaitMailboxAhead() async {
        await mailboxAheadTask?.value
    }

    private func warmOpeningSummary(store: MailStore, restart: Bool = false) async {
        guard liveFeatures, onboardingFlow == nil else { return }
        let profiles = await MainActor.run { Container.shared.workspaceProfiles() }
        await profiles.prepareProfileOpenings(store: store, restart: restart)
    }

    // Messages, not items: a conversation dealt with is worth however much mail it held,
    // which is what keeps every spoken number in the unit the mailbox uses.
    private func count(_ item: Item) -> Int {
        Self.messageCount(item, scope: scope, grouping: grouping)
    }

    static func messageCount(_ item: Item, scope: Scope, grouping: Bool) -> Int {
        scope == .all || !grouping || item.unresolvedContinuation == true
            ? item.conversation.count : item.conversation.reduce(0) { $0 + ($1.queueWeight ?? ($1.unread ? 1 : 0)) }
    }

    func unreadRemovalIDs(id: String, verb: String, account: String) -> [String] {
        Self.unreadRemovalIDs(id: id, verb: verb, account: account,
            presented: items)
    }

    static func unreadRemovalIDs(id: String, verb: String, account: String, presented: [Item]) -> [String] {
        guard verb == "archive_message",
              let item = presented.first(where: {
                  $0.holds(id) && $0.account.lowercased() == account.lowercased()
              }) else { return [id] }
        let thread = item.thread(for: id)
        guard !thread.isEmpty else { return [id] }
        return Array(Set(presented.filter {
            $0.account.lowercased() == account.lowercased()
        }.flatMap { entry in entry.conversation.filter { ($0.threadId ?? entry.threadId) == thread }.map(\.id) })).sorted()
    }

    private var messageOrdinal: Int {
        guard position > 0 else { return ordinalOffset }
        return ordinalOffset + items.prefix(position - 1).reduce(0) { $0 + count($1) }
            + (position <= items.count ? 1 : 0)
    }

    private var acted: Int {
        items.filter { $0.acted != nil }.reduce(0) { $0 + count($1) }
    }
    private var cleared: Int {
        items.filter { $0.acted != nil || $0.markedRead }.reduce(0) { $0 + count($1) }
    }

    /// Where the queue is, or nil when none is running. Read by the chip.
    var progress: Progress? {
        guard running else { return nil }
        return Progress(
            account: activeAccount ?? snapshotAccount ?? items.first?.account,
            position: messageOrdinal,
            queued: items.reduce(0) { $0 + count($1) },
            remaining: items.dropFirst(max(0, position - 1)).reduce(0) { $0 + count($1) },
            done: position > items.count && !more,
            displayPosition: topicGrouping && scope == .unread ? position : nil,
            displayQueued: topicGrouping && scope == .unread ? items.count : nil,
            displayRemaining: topicGrouping && scope == .unread
                ? items.dropFirst(max(0, position - 1)).count : nil
        )
    }

    /// Mailbox an accountless local read should use, matching triage_next's active-or-primary
    /// selection without moving the cursor.
    func selectedMailbox() async -> String? {
        await queueAccounts().first
    }

    /// Validate a model-provided mailbox before any local cache row is read, and return the
    /// connected account's canonical casing for exact SQLite comparisons.
    func connectedMailbox(named requested: String) async -> String? {
        let wanted = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        return await mailAccounts().first {
            $0.caseInsensitiveCompare(wanted) == .orderedSame
        }
    }

    // MARK: - The tool

    /// One `triage_next` call. Never throws and always returns a string: a call without a
    /// `function_call_output` is a turn that stops in silence.
    /// - Parameter dealtWith: whether the message being stepped off is finished with. `false` (an
    ///   answer-shaped dispatch) moves the cursor without marking it read or logging it in `DealtWithLog`.
    func step(
        _ input: Input, store: MailStore, dealtWith finishesCurrent: Bool = true
    ) async -> (output: String, served: Served) {
        if let preparationTask { await preparationTask.value }
        return await synchronizedStep(input, store: store, dealtWith: finishesCurrent)
    }

    /// The automatic opening is a new walk for the user even when it consumes the unresolved
    /// tail of today's durable snapshot. Keep the cached work, but number that tail from one.
    func openingStep(store: MailStore) async -> (output: String, served: Served) {
        if let preparationTask { await preparationTask.value }
        return await synchronizedStep(Input(), store: store, startsNewSession: true)
    }

    private func stepWithoutWaitingForPreparation(
        _ input: Input, store: MailStore,
        startsNewSession: Bool = false, dealtWith finishesCurrent: Bool = true
    ) async -> (output: String, served: Served) {
        if onboardingFlow != nil {
            return await onboardingStep(input, store: store, dealtWith: finishesCurrent,
                opening: startsNewSession)
        }
        if input.onboardingMailMode != nil {
            return (Self.json(["note": "The onboarding preference is not active. No setting or queue position changed."]), .ask)
        }
        if input.offerDeclined { noteOfferDeclined() }
        // The yes to the cleanup offer serves the first message rather than stepping past it.
        if nothingImportantStanding {
            nothingImportantStanding = false
            if running, input.direction == nil, !input.restart, !input.stop, input.scope == nil,
               input.account == nil, input.rawScope == nil {
                return (await current(store: store), .hit)
            }
        }
        restoredServedForLastStep = nil
        if let requested = input.account?.trimmingCharacters(in: .whitespaces), !requested.isEmpty {
            let connected = await mailAccounts()
            guard let selected = connected.first(where: {
                $0.caseInsensitiveCompare(requested) == .orderedSame
            }) else {
                return (Self.json([
                    "note": "There is no connected mailbox called \(requested). Ask which "
                        + "connected inbox they meant; do not switch or move the current queue.",
                ]), .ask)
            }
            if activeAccount?.caseInsensitiveCompare(selected) != .orderedSame {
                let previous = activeAccount ?? snapshotAccount ?? items.first?.account
                let wasRunning = running
                // Phase timings like `profileSwitch`, so the switch's cost can be read off the log.
                mailboxSwitch = (Date(), selected)
                if wasRunning { await checkpoint(store: store) }
                markMailboxSwitch("checkpoint")
                // An unrelated answer belongs to no mailbox, so it follows the user across.
                let unrelated = outcomes.filter(\.independent)
                if wasRunning, let previous {
                    pausedOutcomes[previous.lowercased()] = outcomes.filter { !$0.independent }
                }
                await end(preservingMailboxState: true)
                markMailboxSwitch("end")
                activeAccount = selected
                snapshotAccount = selected
                outcomes = unrelated + (pausedOutcomes.removeValue(forKey: selected.lowercased()) ?? [])
                completedAccounts.remove(selected.lowercased())
                offeredAccount = nil
                RealtimeLog.log("localTriage: switched \(previous ?? "primary") → \(selected)")
            } else if running, input.direction == nil, !input.restart, !input.stop,
                      input.scope == nil, input.rawScope == nil {
                // Selecting the mailbox already on screen is idempotent: an account-only call means
                // "use this inbox" and must not skip the message the user is looking at.
                return (await current(store: store), .hit)
            }
        }
        if let offeredAccount, input.account == nil, !input.stop {
            return (Self.json([
                "account": activeAccount ?? snapshotAccount ?? "mailbox",
                "note": "That mailbox is finished and no new queue has been selected. Ask "
                    + "again whether they want to switch to \(offeredAccount). If they agree, "
                    + "call triage_next with that exact account; if they decline, use stop true.",
            ]), .hit)
        }
        // Stop pauses the durable walk for this conversation. Save before the in-memory stop
        // tears its presentation state down; a fresh call restores this exact message.
        if input.stop { await checkpoint(store: store) }
        if input.restart {
            reconciliationLifetime &+= 1
            await discardToday(store: store)
        }
        if !running, !input.restart, !input.stop {
            let restored = await restoreIfAvailable(
                for: input, store: store, startsNewSession: startsNewSession)
            markMailboxSwitch(restored ? "restored from disc" : "no row to restore")
        }
        let performed = await performStep(input, store: store, dealtWith: finishesCurrent)
        let result = (
            output: performed.output,
            served: restoredServedForLastStep ?? performed.served)
        markMailboxSwitch("first card \(result.served.rawValue)"
            + (currentMailbox.map { " for \($0)" } ?? ""))
        mailboxSwitch = nil
        if !input.stop { await checkpoint(store: store) }
        // Behind the card, never in front of it: the other mailboxes' rows for a later switch.
        prefetchOtherMailboxes(store: store)
        return result
    }

    /// The mailbox switch in progress, for its phase log. Cleared once the first card is served.
    private var mailboxSwitch: (started: Date, to: String)?

    private func markMailboxSwitch(_ phase: String) {
        guard let mailboxSwitch else { return }
        RealtimeLog.log("mailboxSwitch: \(phase) +\(Int(Date().timeIntervalSince(mailboxSwitch.started) * 1000))ms"
            + " → \(mailboxSwitch.to)")
    }

    private func prepareOnboardingTail() async {
        guard !onboardingPrepared, let task = onboardingPreparation else { return }
        let runId = onboardingFlow?.runId
        let selection = await task.value
        guard onboardingFlow?.runId == runId, runId != nil else { return }
        onboardingPrepared = true
        onboardingFailures = selection.failures
        for item in selection.items where onboardingItems[item.id] == nil && item.onboardingStep >= onboardingResumeStep {
            if item.kind(in: onboardingFlow?.config) == "welcome", onboardingFlow?.mailPreference != nil { continue }
            onboardingItems[item.id] = item
            items.append(item.queueItem)
        }
        // v2 mail lands after the seeded steps; put everything not yet walked in config order.
        if onboardingFlow?.config != nil, position < items.count {
            let start = max(position, 0)
            let order = { (item: Item) in self.onboardingItems[item.id]?.onboardingStep ?? .max }
            let tail = items[start...].enumerated().sorted {
                (order($0.element), $0.offset) < (order($1.element), $1.offset)
            }.map(\.element)
            items.replaceSubrange(start..., with: tail)
        }
        total = items.count
    }

    private var onboardingOnWelcome: Bool {
        guard position >= 1, position <= items.count, let stage = onboardingItems[items[position - 1].id] else { return false }
        return stage.kind(in: onboardingFlow?.config) == "welcome"
    }

    /// v2 numbers the walk; v1 keeps its fixed 5.
    private var onboardingFinishStage: [String: Any] {
        let finish = onboardingFlow?.config?.finish
        return ["step": onboardingFlow?.config == nil ? 5 : items.count + 1, "kind": "finish",
                "note": EmailOnboardingContract.finishInstruction(
                    tip: finish?.tip ?? EmailOnboardingContract.tip,
                    question: finish?.question ?? EmailOnboardingContract.question)]
    }

    private func onboardingCurrent() -> String {
        let item = items[position - 1]
        guard let stage = onboardingItems[item.id] else {
            return Self.json(["note": "This onboarding item is unavailable. Call triage_next."])
        }
        let config = onboardingFlow?.config
        if let runId = onboardingFlow?.runId { OnboardingResume.reached(step: stage.onboardingStep, runId: runId) }
        // Last, it asks the finish question itself, so the next advance leaves onboarding.
        let aboutQuestion = stage.about != nil && position == items.count
            ? config?.finish?.question ?? EmailOnboardingContract.question : nil
        if aboutQuestion != nil { onboardingCompletionPresented = true }
        let note = onboardingMailModePending
            ? config?.mailModeQuestion.map(EmailOnboardingContract.mailModeInstruction(question:)) ?? EmailOnboardingContract.mailModeNote
            : stage.about.map { EmailOnboardingContract.aboutInstruction($0, question: aboutQuestion) } ?? stage.note(config: config)
        // `kind` is what the phone reads to answer a stage itself; see `tryOnboardingAnswer`.
        let kind = onboardingMailModePending ? "mail_mode" : stage.kind(in: config)
        var payload: [String: Any] = ["done": false, "position": position,
            "onboarding": ["step": config == nil ? stage.onboardingStep : position, "kind": kind, "note": note], "note": note]
        // The two handoff lines are the speaker's to recite, as the about step's script already
        // is. Left inside the note, the welcome line came out as an ordinary email summary ending
        // on "What would you like to do with it?", and the question after the draft depended on
        // the model finding it under "say nothing else".
        if onboardingMailModePending {
            payload["script"] = config?.mailModeQuestion ?? EmailOnboardingContract.mailModeQuestion
        } else if stage.kind(in: config) == "welcome" {
            payload["script"] = config?.step(stage.onboardingStep)?.line ?? EmailOnboardingContract.welcomeLine
        }
        // A beat has a placeholder item so the cursor can stand on it; it is never shown as mail.
        if let about = stage.about {
            payload["about"] = ["items": about.items]
            if let aboutQuestion, !onboardingMailModePending {
                payload["script"] = EmailOnboardingContract.aboutScript(about, question: aboutQuestion)
            }
        } else if stage.kind(in: config) != "beat" {
            payload["item"] = ["account": item.account, "id": item.id, "threadId": item.threadId,
                "from": item.from, "subject": item.subject, "date": item.date,
                "snippet": MailHeadersOnly.snippet(item.snippet)]
        }
        if let cleanup = stage.cleanup,
           let data = try? JSONEncoder().encode(cleanup),
           let object = try? JSONSerialization.jsonObject(with: data) {
            payload["cleanup"] = object
        }
        if !onboardingFailures.isEmpty {
            payload["heardSince"] = onboardingFailures.joined(separator: " ")
            onboardingFailures = []
        }
        return Self.json(payload)
    }

    private func onboardingStep(
        _ input: Input, store: MailStore, dealtWith: Bool, opening: Bool
    ) async -> (output: String, served: Served) {
        if input.stop {
            await end()
            return (Self.json(["stopped": true, "note": "Onboarding has stopped."]), .hit)
        }
        if let mode = input.onboardingMailMode {
            guard ["drafts", "send", "skip"].contains(mode) else {
                return (Self.json(["onboarding": ["step": 1], "note": "Choose send or drafts explicitly; yes/no is ambiguous. Nothing was saved."]), .ask)
            }
            let alreadyAdvanced = onboardingMailModeReceipt != nil && !onboardingMailModeResumeAdvance
            guard onboardingMailModePending || alreadyAdvanced || onboardingMailModeResumeAdvance,
                  let flow = onboardingFlow else {
                return (Self.json(["onboarding": ["step": 1], "note": "The preference question is not pending. Nothing was saved or advanced."]), .ask)
            }
            let runId = flow.runId
            let preferenceSaved = onboardingPreferenceSaved
            do {
                let receipt: OnboardingMailModeReceipt
                if let onboardingModeSaver { receipt = try await onboardingModeSaver(mode) }
                else { receipt = try EmailOnboardingContract.saveMailMode(flow: flow, mode: mode) }
                guard receipt.mailPreference.account == flow.mailModeChoice?.account else { throw URLError(.cannotParseResponse) }
                // Saving belongs to the signed-in owner even if this call has ended.
                await preferenceSaved?(receipt.mailPreference)
                guard onboardingFlow?.runId == runId else { return (Self.json(["stopped": true]), .hit) }
                onboardingMailModeReceipt = receipt
                onboardingMailModePending = false
                onboardingMailModeResumeAdvance = false
                if alreadyAdvanced {
                    return (mailModeOutput(receipt, output: onboardingCompletionPresented
                        ? Self.json(["onboarding": onboardingFinishStage]) : onboardingCurrent()), .hit)
                }
                await prepareOnboardingTail()
                guard onboardingFlow?.runId == runId else { return (Self.json(["stopped": true]), .hit) }
                onboardingMailModeResumeAdvance = false
                let next = await advance(Input(), store: store, dealtWith: dealtWith)
                return (mailModeOutput(receipt, output: next.0), next.1)
            } catch {
                guard onboardingFlow?.runId == runId else { return (Self.json(["stopped": true]), .hit) }
                RealtimeLog.log("onboarding: preference save failed — \(error)")
                return (Self.json(["onboarding": ["step": 1], "note": "I couldn’t confirm the preference was saved. Please try that choice again. " + EmailOnboardingContract.mailModeNote]), .ask)
            }
        }
        if onboardingMailModeResumeAdvance {
            let runId = onboardingFlow?.runId
            await prepareOnboardingTail()
            guard onboardingFlow?.runId == runId, runId != nil else { return (Self.json(["stopped": true]), .hit) }
            onboardingMailModeResumeAdvance = false
            if running, onboardingOnWelcome {
                return await advance(Input(), store: store, dealtWith: dealtWith)
            }
        }
        if onboardingCompletionPresented {
            let seen = items
            await end()
            onboardingExcludedThreads = Set(seen.map { "\($0.account):\($0.threadId)" })
            for item in seen { noteDealtWith(item) }
            return await performStep(Input(), store: store)
        }
        if !running {
            if items.isEmpty || onboardingMailComesFirst { await prepareOnboardingTail() }
            guard onboardingFlow != nil else { return (Self.json(["stopped": true]), .hit) }
            running = true
            position = 1
            total = items.count
            if items.isEmpty { return (await close(), .hit) }
            return (onboardingCurrent(), .hit)
        }
        if opening || input.direction == "back" { return (onboardingCurrent(), .hit) }
        if onboardingMailModePending { return (onboardingCurrent(), .hit) }
        if let flow = onboardingFlow, flow.mailModeChoice != nil, flow.mailPreference == nil,
           onboardingMailModeReceipt == nil, onboardingOnWelcome {
            onboardingMailModePending = true
            OnboardingResume.asked(runId: flow.runId)
            return (onboardingCurrent(), .hit)
        }
        await prepareOnboardingTail()
        guard onboardingFlow != nil else { return (Self.json(["stopped": true]), .hit) }
        return await advance(input, store: store, dealtWith: dealtWith)
    }

    /// A v2 config can open on mail; the first turn then waits for it rather than skipping it.
    private var onboardingMailComesFirst: Bool {
        guard let steps = onboardingFlow?.config?.steps else { return false }
        let firstMail = steps.firstIndex { ["important", "cleanup"].contains($0.kind) }.map { $0 + 1 } ?? .max
        let firstSeeded = items.first.flatMap { onboardingItems[$0.id]?.onboardingStep } ?? .max
        return firstMail < firstSeeded
    }

    private func mailModeOutput(_ receipt: OnboardingMailModeReceipt, output: String) -> String {
        guard var payload = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let data = try? JSONEncoder().encode(receipt.mailPreference),
              let preference = try? JSONSerialization.jsonObject(with: data) else { return output }
        // No spoken receipt: Live's own acknowledgement of their answer already says it.
        payload["mailPreference"] = preference
        return Self.json(payload)
    }

    private func performStep(
        _ input: Input, store: MailStore, dealtWith finishesCurrent: Bool = true
    ) async -> (output: String, served: Served) {
        if input.stop { return (stop(), .hit) }
        // Only an unscoped automatic walk earns the terminal feed. A scope supplied by the
        // model is the user's bounded request, including when it replaces an automatic walk.
        if input.scope != nil { feedEligible = false }
        else if !running { feedEligible = sequentialFeed && (!feedEmitted || profileHandoff.canCompleteCurrent) }
        // A scope we could not read is not a scope nobody sent, so answer it before anything else
        // reads `input.scope`.
        if input.scope == nil, let raw = input.rawScope?.trimmingCharacters(in: .whitespaces),
           !raw.isEmpty {
            RealtimeLog.log("localTriage: unknown scope \"\(raw)\" — asking again")
            // `.ask` — it re-asks and serves no mail, exactly like the question branch below.
            return (Self.json([
                "note": "\"\(raw)\" is not a scope this queue takes. The scopes are "
                    + "\"unread\", \"important\" and \"all\". "
                    + "Call triage_next again with one of those, and if you are not sure which "
                    + "they meant, ask them rather than guessing. Do not tell them anything "
                    + "went wrong.",
            ]), .ask)
        }

        // Rescoping rebuilds: the watermark arithmetic is over one result set, so a queue cannot be
        // half one scope and half another.
        let rescoped = running && input.scope != nil && input.scope != scope
        if rescoped { reconciliationLifetime &+= 1 }
        let starting = !running || input.restart || rescoped


        if starting {
            clearStageNavigation()
            gmailWalkDealtWith = []
            summarizedReadThreads = []
            dispatchSweepIDs = []
            // No scope means "start the daily queue". Fresh calls are agent-led, so the
            // absence of a scope can never bounce back as a question the user must answer.
            guard let asked = input.scope else {
                // A saved pile picks where the walk starts, not where it stops — see
                // `Scope.restOfWalk`. Absent, it starts at the head of the same chain.
                let saved = TriageScope.preferred.flatMap { Scope(rawValue: $0.rawValue) }
                let first = saved ?? Scope.automaticStart
                let walking = first.restOfWalk
                RealtimeLog.log(
                    "localTriage: no scope sent — \(saved == nil ? "default" : "saved default") "
                        + "walk \(walking.map(\.rawValue).joined(separator: " → "))")
                scopeUnsaid = true
                return await build(scope: first, store: store, walking: walking)
            }
            return await build(scope: asked, store: store)
        }

        return await advance(input, store: store, dealtWith: finishesCurrent)
    }

    // MARK: - Daily persistence

    private func restoreIfAvailable(
        for input: Input, store: MailStore, startsNewSession: Bool
    ) async -> Bool {
        queueBuildsInFlight += 1
        defer { queueBuildsInFlight -= 1 }
        guard let database = store.database else { return false }
        let currentAccounts = Set(await mailAccounts().map { $0.lowercased() })
        guard !currentAccounts.isEmpty else { return false }
        // The current account set is the authority: an activeAccount a profile switch removed must
        // not steer the restore.
        var selectedAccount = activeAccount.flatMap { currentAccounts.contains($0.lowercased()) ? $0 : nil }
            ?? input.account
        if selectedAccount == nil { selectedAccount = (await queueAccounts()).first }
        let day = Self.localDay()
        guard case let (account, saved)? = await TriageQueueSnapshotStore.resumable(
            in: database, userId: store.userId, day: day, account: selectedAccount,
            input: input, currentAccounts: currentAccounts) else { return false }
        guard await snapshotStillResumes(saved, account: account, selectedAccount: selectedAccount,
                                         input: input, store: store, startsNewSession: startsNewSession)
        else { return false }
        // Kept whether or not the cursor is resumed below: the thread context the row carries is
        // today's, and a rebuilt page would otherwise ask Gmail for every thread again.
        restoredThreadContexts = TriageMailSource.threadContextIndex(saved.items)

        grouping = saved.grouping ?? false
        topicGrouping = saved.topicGrouping ?? false
        presentedTopicKeys = saved.presentedTopicKeys.map(Set.init)
            ?? Self.messageKeys(Array(saved.items.prefix(saved.position)))
        scope = saved.scope
        // Nil on a checkpoint written before importance ordering, which restores as the unbanded walk
        // it was.
        band = saved.band
        beforeScore = saved.beforeScore
        beforeID = saved.beforeID

        let currentIndex = min(max(0, saved.position - 1), max(0, saved.items.count - 1))
        let savedCurrent = saved.items.indices.contains(currentIndex)
            ? saved.items[currentIndex] : nil
        restoreWalkLedgers(from: saved)
        let suppressed = gmailWalkDealtWith.union(dispatchSweepIDs)
        let remainingSaved = saved.items.enumerated().compactMap { index, item -> Item? in
            // A failed/cancelled pending write is still unresolved, even behind the cursor.
            // Successful archives are excluded by the reconciled inbox labels below.
            let wasPending = liveFeatures && (saved.pendingArchives ?? []).contains {
                $0.matches(account: item.account, ids: item.ids, threadId: item.threadId)
            }
            guard index >= currentIndex || wasPending, item.acted == nil, !item.markedRead,
                  !item.ids.allSatisfy({ suppressed.contains(Self.messageKey(account: item.account, id: $0)) })
            else { return nil }
            return Self.gmailEligible([item], dealtWithThisWalk: suppressed).first
        }
        let (heldRows, eligibleSaved) = await eligibleSavedTail(remainingSaved, scope: saved.scope, store: store)

        var head = await restoredHead(for: saved, account: account, store: store)
        let known = Self.messageKeys(saved.items).union(saved.trimmedKeys ?? []).union(suppressed)
        let fresh = Self.gmailEligible(head.fresh, dealtWithThisWalk: known)
        let refreshed = Self.excludingSummarizedReadThreads(
            await Self.refreshFacts(eligibleSaved, store: store), keys: summarizedReadThreads)
        let restored = remainingSaved.flatMap { savedItem in
            grouped(refreshed.filter {
                $0.account.lowercased() == savedItem.account.lowercased() && savedItem.holds($0.id)
            })
        }
        let currentAccount = savedCurrent?.account
        let survivingCurrent = restored.first { candidate in
            guard let savedCurrent else { return false }
            return candidate.account.lowercased() == savedCurrent.account.lowercased()
                && !Set(candidate.ids).isDisjoint(with: savedCurrent.ids)
        }
        var merged = Self.restoringPage(
            grouped(Self.excludingSummarizedReadThreads(
                await Self.refreshFacts(fresh, store: store, refreshUnread: saved.scope != .all),
                keys: summarizedReadThreads)), to: restored,
            currentID: survivingCurrent?.id, currentAccount: currentAccount, grouping: grouping)
        if band != nil {
            merged = Self.orderByImportance(merged, rows: head.importanceRows + heldRows,
                currentID: survivingCurrent?.id, currentAccount: currentAccount)
        }
        if liveFeatures && startsNewSession {
            // Re-ranking the cache must not turn resume into a mailbox-wide Gmail scan.
            let candidates = band == nil ? merged : Array(merged.prefix(Self.pageSize))
            let archived = await archivedCachedItemKeys(in: candidates, store: store)
            restoredServedForLastStep = .live
            merged = merged.compactMap { item in item.keeping(item.conversation.filter {
                !archived.contains(Self.messageKey(account: item.account, id: $0.id))
            }) }
        }
        guard !merged.isEmpty else { return false }

        if band != nil {
            (merged, head.before) = resumeBandCursor(merged, importanceRows: head.importanceRows)
            head.more = true
        }

        if topicGrouping, saved.scope == .unread {
            let frozen = (merged.lastIndex {
                !Self.messageKeys([$0]).isDisjoint(with: presentedTopicKeys)
            }.map { $0 + 1 } ?? 0)
            let tail = await expandedTopicPage(Array(merged.dropFirst(frozen)).flatMap(\.unwrappedTopics),
                                               store: store, excluding: Self.messageKeys(merged))
            merged = Array(merged.prefix(frozen)) + grouped(tail)
        }
        savedBuffer = nil
        items = merged
        position = 1
        scope = saved.scope
        let resumedOffset = max(0, saved.ordinalOffset ?? 0)
            + saved.items.prefix(currentIndex).reduce(0) { $0 + count($1) }
        ordinalOffset = startsNewSession ? 0 : resumedOffset
        before = head.before
        more = head.more
        // Keep completed positions in the denominator, add genuinely new mail, and subtract saved tail
        // entries that are no longer eligible.
        let savedTailCount = saved.items.dropFirst(currentIndex).reduce(0) { $0 + count($1) }
        let removedFromSavedTail = max(0, savedTailCount - eligibleSaved.reduce(0) { $0 + count($1) })
        let mergedCount = merged.reduce(0) { $0 + count($1) }
        total = startsNewSession
            ? mergedCount
            : max(
                ordinalOffset + mergedCount,
                saved.total + fresh.reduce(0) { $0 + count($1) } - removedFromSavedTail)
        mailboxUnreadAtStart = saved.mailboxUnreadAtStart
        scope = saved.scope
        scopeUnsaid = saved.scopeUnsaid
        scopePlan = saved.scopePlan ?? []
        crossedFromScope = nil
        adopted = saved.adopted
        // A call opening on a prepared important walk that has not moved yet still says its list.
        rankedPending = saved.scope == .important && currentIndex == 0
        nothingImportantCheck = currentIndex == 0 && saved.scope == .important
        nothingImportantStanding = false
        running = true
        activeAccount = account
        snapshotAccount = account
        stalled = head.stalled
        generation &+= 1
        restoredNeedsCurrent = true
        RealtimeLog.log("localTriage: restored \(scope.rawValue) for \(day) at "
            + "\(messageOrdinal) with \(fresh.count) new message(s) after current")
        return true
    }

    /// Whether a saved walk should still be resumed, rather than rebuilt from the mailbox as it is now.
    private func snapshotStillResumes(
        _ saved: SnapshotPayload, account: String, selectedAccount: String?, input: Input,
        store: MailStore, startsNewSession: Bool
    ) async -> Bool {
        // An unbanded snapshot is discarded once this mailbox has bands, so the walk opens in band
        // order; the rebuilt snapshot carries a band, so this fires at most once per mailbox.
        if saved.band == nil, saved.scope == .important, !saved.completed {
            RealtimeLog.log("localTriage: discarding an important snapshot from before the week scope")
            return false
        }
        if saved.band == nil, saved.scope.cacheCanAnswer, !saved.completed, saved.topicGrouping != true,
           let account = selectedAccount, await store.hasBands(account: account) {
            RealtimeLog.log("localTriage: discarding an unbanded snapshot "
                + "(position \(saved.position)) so the walk opens in band order")
            return false
        }

        // Every call opens on the week ranked by importance, whatever the day's walk reached, so
        // mail that arrived since the last call is weighed against the rest and the list is said.
        if startsNewSession, input.scope == nil, input.rawScope == nil,
           !saved.completed, saved.scopePlan?.first == .important,
           await importantHasMailLeft(account: account, store: store) {
            RealtimeLog.log("localTriage: discarding the \(saved.scope.rawValue) snapshot — a new call opens on the week")
            return false
        }

        // An automatic unread-first opening must not inherit yesterday's empty-unread verdict.
        if input.scope == nil, saved.scope == .all,
           TriageScope.preferred == nil || TriageScope.preferred == .unread {
            let unread = await reconcileUnreadOpening(account: account, store: store)
            guard unread == false else {
                RealtimeLog.log("localTriage: leaving all-mail fallback — unread is present or unverified")
                return false
            }
        }
        return true
    }

    /// What this walk has already dealt with, carried over from the saved one.
    private func restoreWalkLedgers(from saved: SnapshotPayload) {
        gmailWalkDealtWith = Self.restoredHandledKeys(
            saved.gmailWalkDealtWith ?? [], items: saved.items, accounts: saved.accounts ?? [])
        dispatchSweepIDs = liveFeatures ? Set(saved.dispatchSweepIDs ?? []) : []
        if liveFeatures && !archiveStatusLoaded {
            for job in saved.pendingArchives ?? [] where !pendingArchives.contains(where: { $0.id == job.id }) {
                pendingArchives.append(job)
            }
        }
        summarizedReadThreads = Set(saved.summarizedReadThreads ?? [])
    }

    /// The saved tail, refreshed from the cache and kept only where it still belongs to the scope.
    private func eligibleSavedTail(
        _ remainingSaved: [Item], scope savedScope: Scope, store: MailStore
    ) async -> (heldRows: [MailStore.Message], eligible: [Item]) {
        let heldRows = await store.messages(ids: remainingSaved.flatMap(\.ids))
        let heldIDs = Set(heldRows.map(\.id))
        let eligibleIDs: Set<String>?
        if savedScope == .important {
            eligibleIDs = await store.importantIds(among: Array(heldIDs))
        } else if savedScope == .unread {
            eligibleIDs = await store.unreadInboxIds(among: Array(heldIDs))
        } else if savedScope == .all {
            eligibleIDs = await store.inboxIds(among: Array(heldIDs))
        } else {
            eligibleIDs = heldIDs
        }
        let requeuedInbox = await store.inboxIds(among: remainingSaved.filter {
            $0.unresolvedContinuation == true
        }.flatMap(\.ids))
        let eligibleSaved = Self.refreshedSavedItems(
            remainingSaved, rows: heldRows, eligibleIDs: eligibleIDs,
            requeuedInboxIDs: requeuedInbox)
        return (heldRows, eligibleSaved)
    }

    /// The mail at the head of the mailbox now, read the way the saved walk reads it.
    private struct RestoredHead {
        var fresh: [Item] = []
        var importanceRows: [MailStore.Message] = []
        var before: Int64?
        var more: Bool
        var stalled = false
    }

    private func restoredHead(
        for saved: SnapshotPayload, account: String, store: MailStore
    ) async -> RestoredHead {
        var head = RestoredHead(before: saved.before, more: saved.more)
        if saved.scope == .unread || saved.scope == .important {
            if band != nil {
                activeAccount = account
                band = MailImportance.walkOrder.first
                beforeScore = nil
                beforeID = nil
                head.before = nil
                repeat {
                    let page = await pageRun(before: head.before, store: store,
                        held: Self.messageKeys(head.fresh))
                    head.fresh.append(contentsOf: page.items)
                    head.before = page.before
                    head.more = page.more
                    head.stalled = page.stalled
                } while head.fresh.reduce(0, { $0 + count($1) }) < Self.pageSize
                    && head.more && !head.stalled
                head.importanceRows = await store.messages(ids: head.fresh.flatMap(\.ids))
            } else {
                head.fresh = await store.unreadPage(
                    before: nil, limit: Self.pageSize, importantOnly: saved.scope == .important,
                    account: account).map(TriageMailSource.item(from:))
            }
            restoredServedForLastStep = .hit
        } else if saved.scope == .all {
            // Full inbox is intentionally a cache miss. Refresh it live and merge its new
            // head rather than claiming the saved snapshot was preloaded.
            scope = .all
            let page = await fetchPage(before: nil, store: store)
            head.fresh = page.items
            head.before = page.before
            head.more = page.more
            head.stalled = page.stalled
            restoredServedForLastStep = page.live ? .live : .hit
        }
        return head
    }

    /// Keep one page of the ranked merge and move the band cursor to just after it. Returns the kept
    /// items and the `before` to resume from.
    private func resumeBandCursor(
        _ merged: [Item], importanceRows: [MailStore.Message]
    ) -> ([Item], Int64?) {
        var messages = 0
        let merged = merged.filter { item in
            let keep = messages < Self.pageSize || item.unresolvedContinuation == true
            if keep { messages += count(item) }
            return keep
        }
        // Resume after the retained fresh prefix; a held current item may rank elsewhere.
        let retained = Self.messageKeys(merged)
        let ranked = Self.orderByImportance(importanceRows.map(TriageMailSource.item(from:)),
            rows: importanceRows, currentID: nil, currentAccount: nil)
        let last = ranked.prefix { retained.contains(Self.messageKey(account: $0.account, id: $0.id)) }.last
        let cursor = importanceRows.first { $0.id == last?.id && $0.account == last?.account }
        band = cursor?.importanceBand ?? (cursor == nil ? MailImportance.walkOrder.first : "normal")
        beforeScore = cursor.map { $0.importanceScore ?? 0 }
        beforeID = cursor?.id
        return (merged, cursor?.internalDate)
    }

    private static func logPruned(_ items: [Item], reason: String) {
        for item in items {
            RealtimeLog.log("localTriage: pruned thread=\(item.threadId) message=\(item.id)"
                + " reason=\(reason)")
        }
    }

    private func importantHasMailLeft(account: String, store: MailStore) async -> Bool {
        let week = await store.unreadPage(before: nil, limit: 100, importantOnly: true, account: account)
        let handled = Set(dealtAt.keys).union(dispatchSweepIDs)
        return week.contains { !handled.contains(Self.messageKey(account: $0.account, id: $0.id)) }
    }

    /// Check the saved opening on every dial/profile re-entry, regardless of which worker
    /// changed Gmail. A previous call's missed completion must not revive cached inbox rows.
    func archivedCachedItemKeys(
        in candidates: [Item], store: MailStore,
        archivedThreads: @Sendable (String, [String]) async -> Set<String> = { account, ids in
            guard case .success(let token) = await GoogleCredential.token(for: account) else { return [] }
            return await GmailAPI.archivedThreadIDs(token: token.accessToken, ids: ids)
        }
    ) async -> Set<String> {
        let lifetime = reconciliationLifetime
        let revision = confirmedEffectsRevision
        var excluded = Set<String>()
        for (account, items) in Dictionary(grouping: candidates, by: { $0.account.lowercased() }) {
            let threads = Set(items.flatMap(\.threadIDs))
            let archived = await archivedThreads(account, Array(threads)).intersection(threads)
            guard lifetime == reconciliationLifetime, revision == confirmedEffectsRevision else { return [] }
            for thread in archived {
                let effect = GmailWriteEffect(account: account, scope: "thread", threadId: thread,
                    messageIds: [], messageIdsComplete: false, operation: "modify", removeLabelIds: ["INBOX"])
                let ids = await store.confirmedEffectIDs(effect)
                guard lifetime == reconciliationLifetime, revision == confirmedEffectsRevision else { return [] }
                await store.applyConfirmedEffect(effect, ids: ids)
                note(ids.map { Self.messageKey(account: account, id: $0) })
            }
            excluded.formUnion(items.flatMap { item in item.conversation.filter {
                archived.contains($0.threadId ?? item.threadId)
            }.map { Self.messageKey(account: account, id: $0.id) } })
        }
        Self.logPruned(candidates.filter { excluded.contains(Self.messageKey(account: $0.account, id: $0.id)) }, reason: "thread_not_in_inbox")
        return excluded
    }

    /// Save the cursor, rewriting the buffer only when its remaining items change.
    func checkpoint(store: MailStore) async {
        if !liveFeatures && !pendingArchives.isEmpty {
            await discardToday(store: store)
            return
        }
        guard onboardingFlow == nil else { return }
        guard let database = store.database else { return }
        let connectedAccounts = await queueAccounts()
        if snapshotAccount == nil {
            let cachedAccount = await store.inboxUnread()?.accounts.first
            snapshotAccount = items.first?.account ?? cachedAccount
        }
        guard let account = snapshotAccount else { return }
        let day = Self.localDay()
        let key = TriageQueueSnapshotStore.key(account: account, day: day, scope: scope, split: "")
        let tail = items.dropFirst(max(0, position - 1))
        var buffer: SnapshotPayload?
        var trimmed = (items: savedBuffer?.trimmedItems ?? 0, ordinals: savedBuffer?.trimmedOrdinals ?? 0)
        let bufferHolds = savedBuffer.map { saved in
            saved.key == key && saved.itemCount == items.count && saved.ordinalOffset == ordinalOffset
                && saved.items.count >= tail.count && saved.items.suffix(tail.count).elementsEqual(tail)
        } ?? false
        if !bufferHolds {
            // Items behind the cursor leave the row, except a pending write still unresolved there;
            // their keys stay so a restore does not take that mail for new.
            var kept: [Item] = []
            var droppedKeys: [String] = []
            trimmed = (0, 0)
            for (index, item) in items.enumerated() {
                let pendingWrite = liveFeatures && pendingArchives.contains {
                    $0.matches(account: item.account, ids: item.ids, threadId: item.threadId)
                }
                if index >= position - 1 || pendingWrite {
                    kept.append(item)
                } else {
                    trimmed.items += 1
                    trimmed.ordinals += count(item)
                    droppedKeys.append(contentsOf: Self.messageKeys([item]).sorted())
                }
            }
            let itemAccounts = Set(items.map { $0.account.lowercased() })
            let coveredAccounts = itemAccounts.isEmpty
                ? connectedAccounts.map { $0.lowercased() }.sorted()
                : itemAccounts.sorted()
            buffer = SnapshotPayload(
                items: kept,
                grouping: grouping,
                accounts: coveredAccounts.isEmpty ? [account.lowercased()] : coveredAccounts,
                position: max(0, position - trimmed.items),
                ordinalOffset: max(0, ordinalOffset) + trimmed.ordinals,
                before: before,
                more: more,
                total: total,
                mailboxUnreadAtStart: mailboxUnreadAtStart,
                scope: scope,
                scopeUnsaid: scopeUnsaid,
                scopePlan: scopePlan,
                adopted: adopted,
                completed: !running && (items.isEmpty || position > items.count) && !more,
                gmailWalkDealtWith: gmailWalkDealtWith.sorted(),
                summarizedReadThreads: summarizedReadThreads.sorted(),
                pendingArchives: liveFeatures ? pendingArchives : nil,
                dispatchSweepIDs: liveFeatures ? dispatchSweepIDs.sorted() : nil,
                band: band,
                beforeScore: beforeScore,
                beforeID: beforeID, topicGrouping: topicGrouping,
                presentedTopicKeys: presentedTopicKeys.sorted(),
                trimmedItems: trimmed.items, trimmedOrdinals: trimmed.ordinals, trimmedKeys: droppedKeys)
        }
        let cursor = TriageQueueSnapshotStore.Cursor(
            position: max(0, position),
            ordinalOffset: max(0, ordinalOffset),
            before: before,
            more: more,
            total: total,
            completed: !running && (items.isEmpty || position > items.count) && !more,
            scopeUnsaid: scopeUnsaid,
            gmailWalkDealtWith: gmailWalkDealtWith.sorted(),
            summarizedReadThreads: summarizedReadThreads.sorted(),
            pendingArchives: liveFeatures ? pendingArchives : nil,
            dispatchSweepIDs: liveFeatures ? dispatchSweepIDs.sorted() : nil,
            band: band,
            beforeScore: beforeScore,
            beforeID: beforeID,
            presentedTopicKeys: presentedTopicKeys.sorted())
        let written = await TriageQueueSnapshotStore.save(
            cursor: cursor, buffer: buffer, account: account, day: day, scope: scope,
            store: store, database: database)
        if let buffer, written {
            savedBuffer = (key, buffer.items, trimmed.items, trimmed.ordinals,
                           buffer.items.count + trimmed.items, cursor.ordinalOffset)
        } else if !written {
            savedBuffer = nil
        }
    }

    private func discardToday(store: MailStore) async {
        guard let database = store.database else { return }
        let accounts = await queueAccounts()
        await TriageQueueSnapshotStore.discard(day: Self.localDay(), accounts: accounts,
                                               store: store, database: database)
        ordinalOffset = 0
        snapshotAccount = nil
        savedBuffer = nil
    }

    /// End the in-memory conversation view only after its durable cursor has landed. This is
    /// the call-ending path; unlike an explicit queue stop, the next fresh call should resume.
    func pauseForConversationEnd(store: MailStore) async {
        // A fresh dial also calls this to retire the previous conversation's queue. Launch preparation
        // is not a running conversation; checkpointing its cleared state would mark the prepared row completed.
        if let preparationTask { await preparationTask.value }
        guard running else {
            RealtimeLog.log("localTriage: no live conversation queue to pause — prepared snapshot kept")
            return
        }
        await checkpoint(store: store)
        await end()
    }

    // MARK: - Building

    private func build(
        scope asked: Scope,
        store: MailStore,
        walking: [Scope] = [],
        crossedFromScope: Scope? = nil
    ) async -> (String, Served) {
        queueBuildsInFlight += 1
        defer { queueBuildsInFlight -= 1 }
        let ahead = await takeInboxAhead(crossing: asked == .all && crossedFromScope != nil)
        scope = asked
        rankedPending = asked == .important && crossedFromScope == nil
        nothingImportantCheck = rankedPending
        nothingImportantStanding = false
        presentedTopicKeys = []
        topicGrouping = asked == .unread
        if crossedFromScope == nil { grouping = ThreadQueue.isOn }
        actionOutcome = nil
        items = []
        // A real walk of the mailbox, so the scope sentences apply again.
        adopted = false
        position = 0
        ordinalOffset = 0
        before = nil
        band = nil
        beforeScore = nil
        beforeID = nil
        scopePlan = walking
        self.crossedFromScope = crossedFromScope
        stalled = false
        more = false
        running = true
        // A page already in flight belongs to the queue this one replaces — see `generation`.
        generation &+= 1

        // Counted before the page is fetched, and only for scopes that need it: `important` cannot
        // settle its first page without a mailbox count (see `cacheHoldsItAll`).
        let counted: (total: Int?, live: Bool)
        if let ahead {
            counted = (ahead.total, false)
            inboxAheadPages = ahead.pages
        } else {
            counted = await count(store: store)
        }
        let unreadState = await store.inboxUnread()
        let connectedAccounts = Set(
            await queueAccounts().map { $0.lowercased() })
        // Banded only when the mailbox has been scored and the cache can answer the scope; otherwise it
        // walks by date. `important` is always banded, with unscored mail in the middle band.
        if scope.cacheCanAnswer, let account = activeAccount,
           scope == .important ? true : await store.hasBands(account: account) {
            band = MailImportance.walkOrder.first
        }
        let cachedUnreadCoversEveryAccount = unreadState.map {
            Set($0.accounts.map { $0.lowercased() }) == connectedAccounts
        } ?? false
        mailboxUnreadAtStart = asked == .unread
            ? counted.total ?? 0
            : cachedUnreadCoversEveryAccount ? unreadState?.count ?? 0 : 0
        snapshotAccount = activeAccount ?? items.first?.account ?? unreadState?.accounts.first
        var page = await pageRun(before: nil, store: store, held: [], knownTotal: counted.total)
        items = page.items
        // The opening list needs its top few in hand, and a banded page stops at the end of a
        // band — one high message would otherwise be a list of one.
        while rankedPending, items.count < Self.rankedMax, page.more, !page.stalled {
            page = await pageRun(before: page.before, store: store, held: Self.messageKeys(items))
            items += page.items
        }
        before = page.before
        more = page.more
        stalled = page.stalled
        total = max(counted.total ?? 0, items.reduce(0) { $0 + count($1) })
        let fromAhead = inboxAheadPages != nil
        inboxAheadPages = nil
        // Either leg can reach Gmail, and both are awaited in front of the user — a build
        // that counted live and paged from cache still cost them the round trip.
        let served: Served = fromAhead ? .prefetched : (counted.live || page.live) ? .live : .hit

        if items.isEmpty, let pending = Self.gmailEmptyDisposition(
            hasMore: more, stalled: stalled
        ) {
            return (gmailPending(pending), served)
        }

        guard !items.isEmpty else {
            running = false
            if let next = nextScopeInPlan() {
                RealtimeLog.log(
                    "localTriage: \(asked.rawValue) is empty — skipping to \(next.rawValue)")
                return await build(
                    scope: next,
                    store: store,
                    walking: scopePlan,
                    crossedFromScope: crossedFromScope)
            }
            let empty = TriageQueueBuilder.emptyNote(asked: asked, crossedFrom: crossedFromScope)
            // Nothing to open with, so the pile is never named — cleared here or it would
            // be announced at the top of whatever queue is built next.
            scopeUnsaid = false
            RealtimeLog.log("localTriage: built an empty queue (\(asked.rawValue))")
            let payload: [String: Any] = [
                "started": true,
                "total": total,
                "queued": 0,
                "empty": true,
                "note": empty,
            ]
            return (await mailboxHandoffOrFeed(payload, trigger: "empty opening"), served)
        }

        position = 1
        RealtimeLog.log(
            "localTriage: built \(items.count) of \(total) (\(asked.rawValue))"
                + (more ? ", more from \(before ?? 0)" : ", all of it"))
        return (await current(store: store), served)
    }

    /// `TriageQueueBuilder.count` over this walk's mailbox.
    private func count(store: MailStore, scope asked: Scope? = nil) async -> (total: Int?, live: Bool) {
        let scope = asked ?? self.scope
        return await TriageQueueBuilder.count(scope: scope, accounts: await queueAccounts(), store: store)
    }


    // MARK: - Prefetch

    /// Fetch the `all` stage behind unread's last few messages, only once `more` is false so it never
    /// shares the wire with a top-up. The unread re-check at the crossing stays live to catch new mail.
    private func prefetchInboxStage(store: MailStore) {
        guard scope == .unread, !more, nextScopeInPlan() == .all,
              items.count - position < Self.topUpAt, inboxAheadTask == nil, inboxAhead == nil
        else { return }
        let gen = generation
        RealtimeLog.log("localTriage: prefetching all behind unread")
        inboxAheadTask = Task { [weak self] in await self?.fetchInboxAhead(generation: gen, store: store) }
    }

    private func fetchInboxAhead(generation gen: Int, store: MailStore) async {
        let started = Date()
        let accounts = await queueAccounts()
        let counted = await count(store: store, scope: .all)
        // Everything unread still holds will be dealt with by the crossing, so a page of only
        // that is a page `pageRun` would skip — keep going, as it would.
        let walked = Self.messageKeys(items).union(gmailWalkDealtWith)
            .union(dispatchSweepIDs).union(navigationExcludedIDs)
        let pages = await TriageQueueBuilder.inboxAheadPages(walked: walked, budget: Self.gmailPageBudget) { before in
            await self.livePage(before: before, store: store, scope: .all)
        }
        guard gen == generation, scope == .unread else { return }
        inboxAhead = InboxAhead(total: counted.total, accounts: accounts, pages: pages, at: Date())
        inboxAheadTask = nil
        RealtimeLog.log(
            "localTriage: prefetched \(pages.count) page(s) of all in "
                + String(format: "%.0f", Date().timeIntervalSince(started) * 1000) + "ms")
        // The first message of the next stage, so its summary and cleanup are ready at the crossing.
        let userId = await MainActor.run { Container.shared.backend().userId ?? "" }
        await Container.shared.emailCleanup().prefetch(
            inboxAheadFirst(2).map { Self.cleanupInput($0) }, userId: userId, store: store)
        await preparationChanged?()
    }

    /// The prefetched stage's first messages that the crossing would actually serve.
    private func inboxAheadFirst(_ n: Int) -> [Item] {
        guard case .success(let live, _, _)? = inboxAhead?.pages[nil] else { return [] }
        let walked = Self.messageKeys(items).union(gmailWalkDealtWith)
            .union(dispatchSweepIDs).union(navigationExcludedIDs)
        return Array(grouped(Self.gmailEligible(live, dealtWithThisWalk: walked)).prefix(n))
    }

    /// Hand the crossing whatever `prefetchInboxStage` got, waiting for it if still in flight.
    /// Any other build drops it: it was fetched for this walk's crossing and no other.
    private func takeInboxAhead(crossing: Bool) async -> InboxAhead? {
        if crossing, let task = inboxAheadTask { await task.value }
        defer { inboxAhead = nil; inboxAheadTask = nil }
        guard crossing, let ahead = inboxAhead,
              Date().timeIntervalSince(ahead.at) < Self.prefetchFreshness,
              await queueAccounts() == ahead.accounts
        else { return nil }
        return ahead
    }

    /// Retire the walk's handles; in-flight reads may still update the account-scoped cache.
    private func releasePrefetch() {
        inboxAhead = nil
        inboxAheadTask = nil
    }

    // MARK: - Advancing

    private func advance(
        // Not named `dealtWith` internally: on this actor that is the seven-day ledger.
        _ input: Input, store: MailStore, dealtWith finishesCurrent: Bool = true
    ) async -> (String, Served) {
        if restoredNeedsCurrent, input.direction == nil {
            restoredNeedsCurrent = false
            return (await current(store: store), .hit)
        }
        restoredNeedsCurrent = false
        let goingBack = input.direction == "back"

        if goingBack, position <= 1, crossToEarlierStage() {
            return (await current(store: store), .hit)
        }
        // A second queue command means the user carried on without acting on the circled-back email.
        // Retire the marker; another held outcome below replaces it with its own referent.
        if !goingBack, actionOutcome != nil {
            actionOutcome = nil
            RealtimeLog.log("localTriage: outcome presentation skipped — resuming cursor")
        }

        // An answer about the message they were standing on is served on that message, before the
        // advance: no coaching count, read mark or cursor move. Only the head, so FIFO holds; not on "back".
        if !goingBack, let waiting = outcomes.first, waiting.presents {
            _ = takeOneOutcome()
            let mail = items.first { $0.id == waiting.about?.id }
            if let about = waiting.about {
                actionOutcome = ActionOutcome(
                    about: about,
                    messageId: about.id, threadId: about.threadId,
                    dealtWith: finishesCurrent)
            }
            RealtimeLog.log(
                "localTriage: outcome presented on its own message, cursor held at \(position)"
                    + " — \(outcomes.count) still waiting")
            return (Self.json(Self.presentedFields(waiting, item: mail)), .hit)
        }

        if finishesCurrent, !goingBack, position >= 1, position <= items.count,
           items[position - 1].displayGroupID == "read-thread" {
            let leaving = items[position - 1]
            summarizedReadThreads.insert(Self.threadKey(account: leaving.account, threadId: leaving.threadId))
            let tail = Self.excludingSummarizedReadThreads(Array(items.dropFirst(position)), keys: summarizedReadThreads)
            let removed = items.dropFirst(position).reduce(0) { $0 + count($1) } - tail.reduce(0) { $0 + count($1) }
            items = Array(items.prefix(position)) + tail
            total = max(0, total - removed)
        }

        if !goingBack, position >= 1, position <= items.count,
           items[position - 1].coachingCounted != true {
            items[position - 1].coachingCounted = true
            // The mail, not the item, so the long-inbox pause arrives on time.
            handledForCoaching += count(items[position - 1])
        }

        // A skip is a decision: the message being left is marked read (detached), or the unread query
        // brings it back tomorrow. Going back marks nothing.
        if finishesCurrent, !goingBack, position >= 1, position <= items.count,
           !items[position - 1].markedRead {
            let leaving = items[position - 1]
            items[position - 1].markedRead = true
            // The conversation, not one message of it: a skip is a decision about the whole stop.
            noteDealtWith(leaving)
            if !leaving.id.hasPrefix(EmailOnboardingContract.beatPrefix) {
                Task.detached(priority: .utility) { [leaving] in
                    await TriageMailSource.markRead(leaving, store: store)
                }
            }
        }

        // A coaching checkpoint is its own turn between messages: no cursor move, so the next
        // `triage_next` serves the item. Deferred on a dispatch handoff, not consumed.
        if !goingBack, onboardingFlow == nil, !input.defersCoaching,
           let interstitial = await checkpointBetweenMessages(store: store) {
            return (interstitial, .hit)
        }

        position = goingBack ? max(1, position - 1) : position + 1

        if !goingBack, position > items.count, crossToLaterStage() {
            return (await current(store: store), .hit)
        }

        // Past the buffer with mail still behind it: fetch now, in the foreground, or a spent buffer reads
        // as a clear inbox. The only place a plain "next" can cost a round trip.
        var served: Served = .hit
        if position > items.count, more {
            if await refill(store: store) { served = .live }
        }

        // Out of buffer with a page owed is not the end of the queue. Reachable only when the fetch
        // above failed, so `stalled` means the last attempt errored and `more` means a page is owed.
        if position > items.count,
           let pending = Self.gmailEmptyDisposition(hasMore: more, stalled: stalled) {
            return (gmailPending(pending), served)
        }

        if position > items.count, more || stalled {
            position = max(1, items.count)
            // `served`, not `.hit`: the foreground refill above was tried and paid for.
            return (Self.json([
                "position": position,
                "note": "The next page of their mail could not be loaded, and they are NOT "
                    + "finished with it. Say so and offer to try again — do NOT say they are "
                    + "done, and do NOT say it is clear.",
            ]), served)
        }

        if position > items.count, scope == .unread, liveFeatures {
            switch await collectUnreadArrivalsBeforeLeaving(store: store) {
            case true?: return (await current(store: store), .live)
            case nil: return (gmailPending(.retryUnavailable), .live)
            case false?: break
            }
        }

        if position > items.count {
            // A stage of the default walk ending is not the walk ending: build the next one and
            // hand back its first message, rather than closing and waiting to be asked for it.
            if let next = nextScopeInPlan() {
                retainStageBeforeCrossing()
                return await build(
                    scope: next,
                    store: store,
                    walking: scopePlan,
                    crossedFromScope: scope)
            }
            return (await close(), served)
        }

        // Behind the answer the user is about to hear, so deliberately not `.live`: they waited for none of it.
        if more, items.count - position < Self.topUpAt, refillTask == nil {
            Task { [weak self] in _ = await self?.refill(store: store) }
        }
        prefetchInboxStage(store: store)

        // A landed job's answer rides this step rather than replacing it, which would consume the
        // continuation the cursor advances in. Excluded on "back".
        return (await current(includeOutcome: !goingBack, store: store), served)
    }

    /// Steps back into the nearest earlier stage that can still be walked. Returns whether it did.
    private func crossToEarlierStage() -> Bool {
        var excluded: [NavigationStage] = []
        while let candidate = earlierStages.popLast() {
            guard let previous = navigableStage(candidate) else {
                excluded.append(candidate)
                continue
            }
            laterStages.append(navigationStage())
            laterStages.append(contentsOf: excluded)
            cancelStageWork()
            restoreNavigationStage(previous)
            RealtimeLog.log("localTriage: back across stage boundary to \(scope.rawValue)")
            return true
        }
        earlierStages.append(contentsOf: excluded.reversed())
        return false
    }

    /// Steps forward into the nearest later stage that can still be walked. Returns whether it did.
    private func crossToLaterStage() -> Bool {
        var excluded: [NavigationStage] = []
        while let candidate = laterStages.popLast() {
            guard let next = navigableStage(candidate) else {
                excluded.append(candidate)
                continue
            }
            earlierStages.append(navigationStage(position: max(1, min(position, items.count))))
            earlierStages.append(contentsOf: excluded)
            cancelStageWork()
            restoreNavigationStage(next)
            RealtimeLog.log("localTriage: forward across stage boundary to \(scope.rawValue)")
            return true
        }
        laterStages.append(contentsOf: excluded.reversed())
        return false
    }

    /// A page, important-Slack or coaching checkpoint due between this message and the next, or nil.
    private func checkpointBetweenMessages(store: MailStore) async -> String? {
        if sequentialFeed, mailRemainsAfterCurrent(),
           let page = await takeSequentialPageCheckpoint() {
            RealtimeLog.log("localTriage: page checkpoint after "
                + "\(messageOrdinal) — cursor held; calendar="
                + "\(page["calendarDue"] as? Bool == true)")
            return Self.json(page)
        }
        if sequentialFeed, mailRemainsAfterCurrent(),
           let slack = await takeImportantSlackStage(store: store) {
            RealtimeLog.log("localTriage: important Slack after \(messageOrdinal) — cursor held")
            return Self.json(slack)
        }
        if !sequentialFeed, let coaching = await takeCoachingCheckpoint() {
            RealtimeLog.log("localTriage: coaching checkpoint after "
                + "\(messageOrdinal) — cursor held")
            return Self.json([
                "done": false,
                "interstitial": "coaching",
                "position": messageOrdinal,
                "coaching": coaching,
            ])
        }
        return nil
    }

    /// Fetch the next page and append it. Returns whether the page cost a round trip. Serialised
    /// rather than skipped: a second caller waits for the page already in flight.
    @discardableResult
    private func refill(store: MailStore) async -> Bool {
        // A caller that waits on an in-flight page reports what that page cost, not `false`.
        if let inFlight = refillTask { return await inFlight.value }
        guard more else { return false }
        let task = Task { [weak self] in await self?.fetchNextPage(store: store) ?? false }
        refillTask = task
        let live = await task.value
        refillTask = nil
        return live
    }

    private func appendPage(_ page: [Item]) {
        let frozen = topicGrouping ? max(position, (items.lastIndex {
            !Self.messageKeys([$0]).isDisjoint(with: presentedTopicKeys)
        }.map { $0 + 1 } ?? 0)) : position
        items = Self.appendingPage(page, to: items, position: frozen, grouping: grouping)
        if topicGrouping, scope == .unread {
            items = Array(items.prefix(frozen)) + Self.groupByTopic(Array(items.dropFirst(frozen)))
        }
    }

    static func messageKey(account: String, id: String) -> String {
        "message:\(account.lowercased())|\(id)"
    }

    static func messageKeys(_ items: [Item]) -> Set<String> {
        Set(items.flatMap { item in item.ids.map { messageKey(account: item.account, id: $0) } })
    }

    /// Returns whether the page was fetched over the network.
    private func fetchNextPage(store: MailStore) async -> Bool {
        // Which walk this page belongs to, read before the first await: a rescope inside the
        // fetch must not append into the new buffer.
        let gen = generation

        let held = Self.messageKeys(items)
        let page = await pageRun(before: before, store: store, held: held)
        guard gen == generation else { return false }
        appendPage(page.items)
        before = page.before ?? before
        more = page.more
        stalled = page.stalled
        total = max(total, items.reduce(0) { $0 + count($1) })
        if page.items.isEmpty, !more {
            RealtimeLog.log("localTriage: nothing new at \(before ?? 0) — closing the walk")
        } else {
            RealtimeLog.log("localTriage: +\(page.items.count) (buffer \(items.count))")
        }
        await preparationChanged?()
        return page.live
    }

    /// How many Gmail pages to pull through looking for mail the user has not dealt with.
    /// Cached pages are a disc read, so this is generous.
    static let gmailPageBudget = 8

    private func gmailPending(_ disposition: GmailEmptyDisposition) -> String {
        position = items.count
        switch disposition {
        case .continuePaging:
            return Self.json([
                "done": false,
                "loading": true,
                "note": "More matching mail exists beyond this scan checkpoint. Call "
                    + "triage_next again immediately without speaking or asking the user. "
                    + "Do NOT say the queue is done, clear or empty.",
            ])
        case .retryUnavailable:
            return Self.json([
                "done": false,
                "loading": false,
                "note": "Gmail could not be read far enough to determine whether this queue "
                    + "is finished. Say that mail could not be loaded and offer to try again. "
                    + "Do NOT say the queue or inbox is done, clear or empty.",
            ])
        }
    }

    /// Gmail pages until something not dealt with in this walk turns up, the mailbox runs out, or the
    /// budget does. Each automatic stage contains the one before, so early pages can be all finished mail.
    /// - Parameter held: ids already in the buffer. Nothing new on a page ends the walk: the watermark
    ///   is a second, not a unique key, so paging again would loop.
    private func pageRun(
        before start: Int64?, store: MailStore, held: Set<String>, knownTotal: Int? = nil
    ) async -> (items: [Item], before: Int64?, more: Bool, live: Bool, stalled: Bool) {
        var items: [Item] = []
        var before = start
        var live = false
        var seen = held
        var known = knownTotal
        for _ in 0..<Self.gmailPageBudget {
            let previousBefore = before
            let previousBand = band, previousScore = beforeScore, previousID = beforeID
            let page = await fetchPage(before: before, store: store, knownTotal: known)
            known = nil
            live = live || page.live
            before = page.before ?? before
            let fresh = page.items.compactMap { item in
                item.keeping(item.conversation.filter { seen.insert(Self.messageKey(account: item.account, id: $0.id)).inserted })
            }
            // `important` walks read mail, so a skip's read mark cannot retire it; the ledger must.
            let finished = scope == .important ? gmailWalkDealtWith.union(dealtAt.keys) : gmailWalkDealtWith
            let eligible = Self.excludingSummarizedReadThreads(Self.gmailEligible(
                fresh,
                dealtWithThisWalk: finished.union(dispatchSweepIDs)
                    .union(navigationExcludedIDs)), keys: summarizedReadThreads)
            let dealt = fresh.count - eligible.count
            if dealt > 0 {
                RealtimeLog.log(
                    "localTriage: \(dealt) of \(fresh.count) dealt with in this walk "
                        + "(\(scope.rawValue))")
            }
            items.append(contentsOf: eligible)
            if page.stalled { return (items, before, true, live, true) }
            if fresh.isEmpty, page.more, before == previousBefore,
               band == previousBand, beforeScore == previousScore, beforeID == previousID {
                return (items, before, true, live, true)
            }
            if !items.isEmpty || !page.more {
                return (items, before, page.more, live, false)
            }
        }
        return (items, before, true, live, true)
    }

    // MARK: - Closing

    private func close() async -> String {
        if onboardingFlow != nil {
            onboardingCompletionPresented = true
            running = false
            let stage = onboardingFinishStage
            return Self.json(["done": true, "heardSince": onboardingFailures.joined(separator: " "),
                "onboarding": stage, "note": stage["note"] ?? EmailOnboardingContract.finish])
        }
        let queued = items.reduce(0) { $0 + count($1) }
        let dealt = acted
        let walked = scope.rawValue
        reconciliationLifetime &+= 1
        running = false
        clearStageNavigation()
        generation &+= 1
        RealtimeLog.log("localTriage: done — \(dealt) acted, \(queued - dealt) passed (\(walked))")
        // All but always empty: `step` serves a waiting outcome before the advance that could
        // reach this. What is left is one landing while a refill was in flight.
        var payload: [String: Any] = Self.farewell(takeOutcomes())
        payload.merge([
            "done": true,
            "queued": queued,
            "acted": dealt,
            "passed": queued - dealt,
            // The claim again, because this is a different turn: a bare `done: true` at the end of
            // an email queue gets answered with "that's your inbox clear".
            "note": Self.closeClaim(scope: scope, adopted: adopted),
        ]) { a, _ in a }
        return await mailboxHandoffOrFeed(payload, trigger: "queue exhaustion")
    }

    /// Held answers that ran out of steps, for a close or a stop to carry. Empty in, empty out, so
    /// both callers merge it unconditionally.
    private static func farewell(_ outcomes: [Outcome]) -> [String: Any] {
        guard !outcomes.isEmpty else { return [:] }
        // Per entry, because a closing set can mix a sweep and a summary on the same last message.
        let answers = outcomes.filter { $0.shape == .answer }
        let items: [[String: Any]] = outcomes.map { o in
            var item: [String: Any] = ["task": o.task, "outcome": o.text]
            if o.ok == false { item["unresolved"] = true }
            if o.shape == .answer { item["wantsTheAnswer"] = true }
            if o.independent { item["unrelatedToMail"] = true }
            return item
        }

        // Built by statement rather than as one expression: the `?:` chain was too slow for the
        // Swift type-checker.
        var note = outcomes.count == 1 ? "A job" : "\(outcomes.count) jobs"
        note += " you handed off came back while they were going through their mail, and the "
        note += "queue ended before there was a step to say it in. After the sentence above, "
        note += "reconnect each result to its original request. For an item marked "
        note += "`wantsTheAnswer`, say \"By the way, the background research you asked me "
        note += "to do on [who it is about, by name] came back\"; for other work, "
        note += "say \"By the way, the work you asked me to do on "
        note += "[who it is about, by name] is finished\". Replace the bracketed words; never read them "
        note += "aloud. For an item marked `unrelatedToMail`, instead say \"By the way,\", name what "
        note += "they asked about and give the answer. "
        // Name each job from its own outcome, not its task: the task names a document, and by now the
        // mail is gone, so the outcome is the only thing carrying a name.
        note += "**Each name comes from that item's own outcome, or from the sender of the "
        note += "email it was about — not from its task**, which describes documents and "
        note += "roles rather than naming anyone. Use the task's wording only when neither "
        note += "gives you a name, and never a role when a name is there. "
        note += "Then say how it went — every address it wrote to and whatever it "
        note += "moved — and stop there. "
        if outcomes.count > 1 {
            note += "Several, so lead with one sentence saying how many and what they touched, "
            note += "and let them ask: do NOT recite them one by one. "
        }
        // The one place the "do NOT recite" rule bends: a single answer-shaped entry is read out;
        // several fall back to "let them ask".
        if answers.count == 1 {
            note += "**One of them is marked `wantsTheAnswer`** — that one was asked to find "
            note += "something out, so give its answer rather than saying it finished, however "
            note += "many sentences that takes. \"That summary is done\" is not an answer. "
            note += "The rest, if any, stay a clause each."
        } else if answers.count > 1 {
            note += "**\(answers.count) of them are marked `wantsTheAnswer`** — each was asked "
            note += "to find something out, so a status is not enough for any of them. Give "
            note += "the first one's answer properly, say the others came back too and name "
            note += "what each was about, and let them ask for those."
        }

        return ["dispatchOutcomes": items, "dispatchOutcomesNote": note]
    }

    /// What may be said when the walk lands on its last message; `closeClaim` belongs to the turn after.
    private static func lastNote(scope: Scope, adopted: Bool = false) -> String {
        let forbidden: String
        let close: String
        if adopted {
            forbidden = "they are through the messages they asked for"
            close = "\"Archived — that was the last one you asked for.\" Their inbox is NOT "
                + "clear, empty, at zero or gone through — never say any of that, and do not "
                + "state a mailbox count."
        } else {
            switch scope {
            case .all:
                forbidden = "they have been through their whole inbox"
                close = "\"Archived — that was the last one, and that's your whole inbox "
                    + "walked.\" Even then, do NOT say their inbox is clear, empty or at zero: "
                    + "every message they did not act on is still sitting in it."
            case .important:
                forbidden = "their important mail is done"
                close = "\"Archived — that was the last one, and that's your important mail "
                    + "done.\" Even then, do NOT say their inbox is clear or at zero: this "
                    + "queue only ever looked at what mattered from their past week, and the "
                    + "rest of their inbox is exactly where it was."
            case .unread:
                forbidden = "their inbox is clear"
                close = "\"Archived — that was the last one, and that's your inbox clear.\""
            }
        }
        return "This is the LAST message in the queue, and IT IS NOT DEALT WITH YET — so the "
            + "queue is NOT finished and you must not tell them it is. Do NOT say they are "
            + "done, do NOT say \(forbidden), and do NOT sum the queue up: they are standing "
            + "on a message that is still sitting in their inbox. Nothing else about THIS turn "
            + "changes — handle this message exactly as you would any other step. What changes "
            + "is the turn AFTER. There is no next message behind this one, so never say "
            + "\"Next is …\" about it: it leaves them waiting for mail that does not exist. "
            + "And WHEN THEY TELL YOU TO ARCHIVE, LABEL OR SPAM IT, THAT turn is the receipt "
            + "and the close together, with the call inside it: \(close) Only say that if the "
            + "write actually went and actually finished the message — a refusal, or a thread "
            + "with members left behind, is not a close. None of that is a reason to call "
            + "triage_next on THIS turn; `note` already says when the queue moves."
    }

    /// What may honestly be said about the mailbox at the end of this walk. Only `unread` may claim
    /// the inbox is clear; every other scope leaves mail behind.
    private static func closeClaim(scope: Scope, adopted: Bool = false) -> String {
        // An adopted queue is the handful they named, so the only claim worth stating is the one that
        // would be false.
        if adopted {
            return "This queue was only the messages they asked for, and it is finished. "
                + "Their inbox is NOT clear, empty, at zero or gone through — never say any "
                + "of that, and do not state a mailbox count."
        }
        guard !scope.meansInboxZero else {
            return "That is their inbox clear — here it is true. Say it in one sentence."
        }
        let unit: String
        switch scope {
        case .all: unit = "their whole inbox"
        case .important: unit = "their important mail"
        case .unread: unit = "their unread"
        }
        return "They have been through \(unit). Say that in one sentence and NOTHING more — do "
            + "NOT say their inbox is clear, empty or at zero, and do not imply they are "
            + "finished with their mail. Everything outside \(unit) is exactly where it was."
    }

    private func stop() -> String {
        let hasMailboxSession = offeredAccount != nil || !pausedOutcomes.isEmpty
        guard running || hasMailboxSession else {
            return Self.json([
                "stopped": true,
                "note": "No queue was running. Do not say you have stopped one.",
            ])
        }
        let left = max(0, total - cleared)
        savedBuffer = nil
        running = false
        actionOutcome = nil
        items = []
        position = 0
        ordinalOffset = 0
        before = nil
        scopePlan = []
        crossedFromScope = nil
        clearStageNavigation()
        stalled = false
        more = false
        gmailWalkDealtWith = []
        summarizedReadThreads = []
        dispatchSweepIDs = []
        reconciliationLifetime &+= 1
        // `dealtAt` deliberately survives a stop: they still dealt with that mail, and "carry on
        // later" must not start by reading it back to them.
        generation &+= 1
        // The walk is over, so pages fetched ahead of it are waste held open. Dropped here as
        // well as in `end()`: a `stop` leaves the call running.
        releasePrefetch()
        RealtimeLog.log("localTriage: stopped with \(left) left")
        let closing = "The queue is closed. Say that you stopped and stop — do not state a "
            + "mailbox count or offer the next message."
        var payload: [String: Any] = [
            "stopped": true,
            "note": closing,
        ]
        // Nothing served these and nothing is going to: the walk they were waiting on is over.
        for waiting in pausedOutcomes.values { outcomes.append(contentsOf: waiting) }
        pausedOutcomes = [:]
        offeredAccount = nil
        completedAccounts = []
        payload.merge(Self.farewell(takeOutcomes())) { a, _ in a }
        return Self.json(payload)
    }

    /// Take the queue away without a tool call. For a call ending, or a new conversation.
    func onboardingDispatchAdvances(task: String, expects: Outcome.Shape) -> Bool {
        guard onboardingFlow != nil else { return true }
        guard running, position >= 1, position <= items.count, expects != .answer else { return false }
        let item = items[position - 1]
        return task == onboardingItems[item.id]?.cleanup?.dispatch.task
            || task.contains(item.id) || task.contains(item.threadId)
    }

    func cancelOnboarding(runId: String) async {
        guard onboardingFlow?.runId == runId else { return }
        await end()
    }

    func end(preservingMailboxState: Bool = false) async {
        onboardingPreparation?.cancel()
        onboardingPreparation = nil
        onboardingFlow = nil
        onboardingMailModePending = false
        onboardingMailModeResumeAdvance = false
        onboardingMailModeReceipt = nil
        onboardingModeSaver = nil
        onboardingPreferenceSaved = nil
        onboardingItems = [:]
        onboardingPrepared = false
        onboardingCompletionPresented = false
        onboardingResumeStep = 0
        onboardingFailures = []
        onboardingExcludedThreads = []
        reconciliationLifetime &+= 1
        running = false
        // Dropped rather than delivered: there is nobody to say them to. The job row stays undelivered,
        // so the next dial's opening digest carries them.
        outcomes = []
        actionOutcome = nil
        items = []
        position = 0
        ordinalOffset = 0
        restoredNeedsCurrent = false
        before = nil
        scopePlan = []
        crossedFromScope = nil
        clearStageNavigation()
        stalled = false
        more = false
        total = 0
        mailboxUnreadAtStart = 0
        gmailWalkDealtWith = []
        summarizedReadThreads = []
        dispatchSweepIDs = []
        declinedCleanups = []
        offeredCleanups = []
        standingOffer = nil
        // `dealtAt` survives the call for the same reason it survives a stop.
        generation &+= 1
        // A new conversation must not inherit a page.
        releasePrefetch()
        restoredThreadContexts = [:]
        offeredAccount = nil
        walkAccounts = nil
        savedBuffer = nil
        if !preservingMailboxState {
            pausedOutcomes = [:]
            completedAccounts = []
            // The prefetch was for this profile's other mailboxes; a profile switch or disconnect
            // changes which those are.
            mailboxAheadTask?.cancel()
            mailboxAheadTask = nil
            mailboxesPreparedAhead = []
            mailboxAheadSettled = false
            // A profile switch or disconnect changes which inboxes this queue may walk, so the
            // selection must not outlive it.
            activeAccount = nil
            snapshotAccount = nil
        }
    }

    /// Mark the message the user is standing on as dealt with, so `left` and the close
    /// count it. Called when a write lands on the current message.
    func markActed(id: String, as verb: String, account: String? = nil, wholeGroup: Bool? = nil) {
        let matches = items.indices.filter {
            items[$0].holds(id) && (account == nil || items[$0].account.lowercased() == account?.lowercased())
        }
        guard Set(matches.map { items[$0].account.lowercased() }).count == 1,
              let index = matches.first else { return }
        if items[index].isTopicGroup {
            let original = items[index]
            let selectedThread = original.thread(for: id)
            let threadAction = verb == "archive_message"
            let selected = original.conversation.filter { threadAction ? ($0.threadId ?? original.threadId) == selectedThread : $0.id == id }
            if let affected = original.keeping(selected) {
                items[index] = affected
                if var remainder = original.keeping(original.conversation.filter { !Set(selected.map(\.id)).contains($0.id) }) {
                    remainder.unresolvedContinuation = true
                    items.insert(remainder, at: max(index + 1, position))
                }
            }
        }
        if wholeGroup == nil, verb == "archive_message" {
            let item = items[index]
            excludeFromNavigation(ids: Set(item.ids),
                threadId: item.threadId.isEmpty ? nil : item.threadId, account: item.account)
            finishThread(at: index, as: verb)
            return
        }
        guard items[index].acted == nil else { return }
        let finishesGroup = wholeGroup ?? ["archive_message", "send_email", "create_draft"].contains(verb)
        if ["archive_message", "trash_message", "mark_spam"].contains(verb) {
            let removed: Set<String> = finishesGroup ? Set(items[index].ids) : [id]
            excludeFromNavigation(ids: removed, account: items[index].account)
        }
        if !finishesGroup, items[index].conversation.count > 1 {
            let original = items[index]
            guard let selected = original.keeping(original.conversation.filter { $0.id == id }) else { return }
            items[index] = selected
            if var remainder = original.keeping(original.conversation.filter { $0.id != id }) {
                remainder.acted = nil
                remainder.markedRead = false
                remainder.unresolvedContinuation = true
                forgetDealtWith(remainder)
                items.insert(remainder, at: max(index + 1, position))
            }
        }
        items[index].acted = verb
        items[index].markedRead = true
        noteDealtWith(items[index])
    }

    private func noteOfferDeclined() {
        defer { standingOffer = nil }
        guard let key = standingOffer else {
            RealtimeLog.log("localTriage: decline arrived with no offer outstanding")
            return
        }
        declinedCleanups.insert(key)
        RealtimeLog.log("localTriage: declined cleanup — \(key) is not offered again")
    }

    /// One sender and one Gmail category, which is what a cleanup offer is about.
    private static func cleanupKey(account: String, from: String, category: String) -> String {
        "\(account.lowercased())|\(EmailCleanupPolicy.sender(from) ?? from.lowercased())|\(category)"
    }

    static func topicSelectionID(_ item: Item) -> String {
        let identity = [item.account.lowercased(), item.topicId ?? ""] + item.ids.sorted()
        let digest = SHA256.hash(data: Data(identity.joined(separator: "|").utf8))
        return "topic:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    func topicArchiveTargets(selection: String, account: String?) -> [Item]? {
        guard selection.hasPrefix("topic:") else { return nil }
        guard running, actionOutcome == nil, items.indices.contains(position - 1) else { return [] }
        let item = items[position - 1]
        guard item.isTopicGroup, Self.topicSelectionID(item) == selection,
              account?.lowercased() == item.account.lowercased() else { return [] }
        return item.unwrappedTopics
    }

    func requiresTopicReplySelection(_ arguments: String) -> Bool {
        guard running, items.indices.contains(position - 1), items[position - 1].isTopicGroup,
              let json = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]
        else { return false }
        let item = items[position - 1]
        guard let thread = json["thread_id"] as? String,
              item.threadIDs.contains(thread) || thread.hasPrefix("topic:") else { return false }
        return json["reply_message_id"] == nil
    }

    /// Retain accepted work in the snapshot; only unresolved members are offered again.
    func finishTopicArchive(selection: String, accepted: Set<String>, pending: [PendingArchive],
                            effects: [GmailWriteEffect], store: MailStore) async -> Bool {
        guard running, items.indices.contains(position - 1),
              Self.topicSelectionID(items[position - 1]) == selection else { return false }
        let original = items[position - 1]
        let index = position - 1
        let gen = generation
        for receipt in pending { _ = acceptPendingArchive(receipt, splitTopic: false) }
        for effect in effects {
            let ids = await store.confirmedEffectIDs(effect)
            await store.applyConfirmedEffect(effect, ids: ids)
            guard gen == generation else { return false }
            _ = updateNavigationExclusions(for: effect, ids: ids)
            if effect.removesFromInbox { note(ids.map { Self.messageKey(account: effect.account, id: $0) }) }
        }
        guard gen == generation, items.indices.contains(index),
              Self.topicSelectionID(items[index]) == selection,
              var resolved = original.keeping(original.conversation.filter { accepted.contains($0.id) })
        else { await checkpoint(store: store); return false }
        if pending.isEmpty {
            resolved.acted = "archive_message"
            resolved.markedRead = true
            noteDealtWith(resolved)
        }
        items[index] = resolved
        if var remainder = original.keeping(original.conversation.filter { !accepted.contains($0.id) }) {
            remainder.unresolvedContinuation = true
            items.insert(remainder, at: index + 1)
        }
        await checkpoint(store: store)
        return true
    }

    /// Pending work advances the conversation without changing cached Gmail labels or
    /// recording the message in the permanent dealt-with ledger.
    func acceptPendingArchive(_ pending: PendingArchive, splitTopic: Bool = true) -> String? {
        pendingArchives.removeAll { $0.id == pending.id }
        let matched = items.first { pending.matches(account: $0.account, ids: $0.ids, threadId: $0.threadId) }
        pendingArchives.append(PendingArchive(id: pending.id, account: pending.account,
            messageId: pending.messageId, threadId: pending.isMessageScoped ? nil : pending.threadId ?? matched?.thread(for: pending.messageId),
            operation: pending.operation))
        guard running, items.indices.contains(position - 1) else { return nil }
        let item = items[position - 1]
        let selected = item.conversation.filter {
            pending.matches(account: item.account, ids: [$0.id], threadId: $0.threadId ?? item.threadId)
        }
        guard !selected.isEmpty else { return nil }
        if splitTopic, (item.isTopicGroup || pending.isMessageScoped), selected.count < item.ids.count,
           let resolved = item.keeping(selected),
           var remainder = item.keeping(item.conversation.filter { member in !selected.contains { $0.id == member.id } }) {
            remainder.unresolvedContinuation = true
            items[position - 1] = resolved
            items.insert(remainder, at: position)
            return resolved.id
        }
        return item.id
    }

    /// A queued write that will never land: its message belongs in the queue again.
    func dropPendingArchive(id: String) {
        pendingArchives.removeAll { $0.id == id }
    }

    /// Deferred archives return no immediate Gmail effects. Reconcile their receipts on
    /// redial, before consulting the cached inbox, including receipts from an older build.
    func reconcileArchives(
        _ status: ArchiveRetryStatus, store: MailStore,
        archivedThreads: @Sendable (String, [String]) async -> Set<String> = { account, ids in
            guard case .success(let token) = await GoogleCredential.token(for: account) else { return [] }
            return await GmailAPI.archivedThreadIDs(token: token.accessToken, ids: ids)
        },
        spamMessages: @Sendable (String, [String]) async -> Set<String> = { account, ids in
            guard case .success(let token) = await GoogleCredential.token(for: account) else { return [] }
            return await GmailAPI.removedMessageIDs(token: token.accessToken, ids: ids, label: "SPAM")
        },
        trashedMessages: @Sendable (String, [String]) async -> Set<String> = { account, ids in
            guard case .success(let token) = await GoogleCredential.token(for: account) else { return [] }
            return await GmailAPI.removedMessageIDs(token: token.accessToken, ids: ids, label: "TRASH")
        }
    ) async {
        let lifetime = reconciliationLifetime
        let revision = confirmedEffectsRevision
        let accounts = Set(await mailAccounts().map { $0.lowercased() })
        let effects = await TriageDispatchReconciler.archiveReceiptEffects(
            status, accounts: accounts, store: store, archivedThreads: archivedThreads,
            spamMessages: spamMessages, trashedMessages: trashedMessages)
        guard lifetime == reconciliationLifetime, revision == confirmedEffectsRevision else { return }
        pendingArchives = status.pending.filter { accounts.contains($0.account.lowercased()) }
        archiveStatusLoaded = true
        // No checkpoint while disconnected: it would overwrite the saved cursor with an
        // empty queue. Provider reads above prove only inbox membership, not read status.
        if running {
            _ = await applyConfirmedEffects(effects, store: store, expectedEffectsRevision: revision)
        } else {
            for effect in effects {
                let ids = await store.confirmedEffectIDs(effect)
                guard lifetime == reconciliationLifetime, revision == confirmedEffectsRevision else { return }
                await store.applyConfirmedEffect(effect, ids: ids)
                note(ids.map { Self.messageKey(account: effect.account, id: $0) })
            }
        }
        RealtimeLog.log("localTriage: archive receipts reconciled threads=\(effects.count) pending=\(pendingArchives.count)")
    }

    func applyConfirmedEffects(_ effects: [GmailWriteEffect], store: MailStore, expectedGeneration: Int? = nil, expectedEffectsRevision: Int? = nil) async -> String? {
        if expectedEffectsRevision == nil { confirmedEffectsRevision &+= 1 }
        var finished: String?
        for effect in effects {
            guard (expectedGeneration == nil || expectedGeneration == generation),
                  (expectedEffectsRevision == nil || expectedEffectsRevision == confirmedEffectsRevision) else {
                return expectedGeneration == generation ? finished : nil
            }
            if effect.added.contains("INBOX") {
                pendingArchives.removeAll { $0.matches(account: effect.account,
                    ids: effect.messageIds, threadId: effect.threadId) }
            }
            var ids = await store.confirmedEffectIDs(effect)
            guard (expectedGeneration == nil || expectedGeneration == generation),
                  (expectedEffectsRevision == nil || expectedEffectsRevision == confirmedEffectsRevision) else {
                return expectedGeneration == generation ? finished : nil
            }
            if !effect.messageIdsComplete, effect.scope == "thread", let thread = effect.threadId {
                ids.formUnion(items.filter { $0.account.lowercased() == effect.account.lowercased()
                    }.flatMap { item in item.conversation.filter { ($0.threadId ?? item.threadId) == thread }.map(\.id) })
            }
            let navigation = updateNavigationExclusions(for: effect, ids: ids)
            await store.applyConfirmedEffect(effect, ids: ids)
            guard (expectedGeneration == nil || expectedGeneration == generation),
                  (expectedEffectsRevision == nil || expectedEffectsRevision == confirmedEffectsRevision) else {
                return expectedGeneration == generation ? finished : nil
            }
            let matches: (Item) -> Bool = { $0.account.lowercased() == effect.account.lowercased()
                && !Set($0.ids).isDisjoint(with: ids) }
            if effect.added.contains("INBOX") {
                let activeIDs = Set(items.filter {
                    $0.account.caseInsensitiveCompare(effect.account) == .orderedSame
                }.flatMap(\.ids))
                var restoredItems = navigation.requeued.compactMap { item in
                    item.keeping(item.conversation.filter { !activeIDs.contains($0.id) })
                }
                total += restoredItems.reduce(0) { $0 + count($1) }
                for index in items.indices.reversed() where matches(items[index]) {
                    let original = items[index]
                    guard original.acted != nil || index < position - 1,
                          var restored = original.keeping(original.conversation.filter { ids.contains($0.id) }) else { continue }
                    restored.acted = nil
                    restored.markedRead = false
                    restored.unresolvedContinuation = true
                    if index == position - 1 { finished = nil }
                    if let remainder = original.keeping(original.conversation.filter { !ids.contains($0.id) }) {
                        items[index] = remainder
                        restoredItems.append(restored)
                    } else if index == position - 1 {
                        items[index] = restored
                    } else {
                        items.remove(at: index)
                        if index < position - 1 { position -= 1 }
                        restoredItems.append(restored)
                    }
                }
                let held = Set(items.filter { $0.account.lowercased() == effect.account.lowercased() }.flatMap(\.ids))
                    .union(restoredItems.flatMap(\.ids)).union(navigation.laterHeld)
                let missing = await store.messages(ids: Array(ids.subtracting(held)), account: effect.account)
                let recovered = await Self.refreshFacts(missing.map(TriageMailSource.item(from:)), store: store)
                for var item in grouped(recovered) {
                    item.unresolvedContinuation = true
                    item.coachingCounted = true
                    total += count(item)
                    restoredItems.append(item)
                }
                items.insert(contentsOf: restoredItems, at: min(max(position, 0), items.count))
                for id in ids {
                    let key = Self.messageKey(account: effect.account, id: id)
                    dealtAt.removeValue(forKey: key)
                    gmailWalkDealtWith.remove(key)
                    dispatchSweepIDs.remove(key)
                }
                if let thread = effect.threadId {
                    summarizedReadThreads.remove(Self.threadKey(account: effect.account, threadId: thread))
                }
                persistDealtWith()
            }
            for index in items.indices where matches(items[index]) {
                items[index].messages = items[index].conversation.map { member in
                    var member = member
                    if ids.contains(member.id) {
                        member.queueWeight = member.queueWeight ?? (member.unread ? 1 : 0)
                        if effect.removed.contains("UNREAD") { member.unread = false }
                        if effect.added.contains("UNREAD") { member.unread = true }
                    }
                    return member
                }
            }
            guard effect.removesFromInbox else { continue }
            let currentIndex = position - 1
            let touchesCurrent = running && items.indices.contains(currentIndex) && matches(items[currentIndex])
            let verb = effect.isDeletion || effect.added.contains("TRASH") ? "trash_message"
                : effect.added.contains("SPAM") ? "mark_spam" : "archive_message"
            let currentThread = touchesCurrent ? items[currentIndex].threadId : nil
            var absorbed: [Item.Message] = []
            for index in items.indices.reversed() where matches(items[index]) {
                let original = items[index]
                let removed = original.conversation.filter { ids.contains($0.id) }
                guard let affected = original.keeping(removed) else { continue }
                noteDealtWith(affected)
                if touchesCurrent, original.threadId == currentThread, original.coachingCounted != true {
                    handledForCoaching += count(affected)
                }
                if index > currentIndex {
                    if touchesCurrent, original.threadId == currentThread { absorbed.append(contentsOf: removed) }
                    else { total = max(0, total - count(affected)) }
                    if let remaining = original.keeping(original.conversation.filter { !ids.contains($0.id) }) {
                        items[index] = remaining
                    } else { items.remove(at: index) }
                } else if index == currentIndex && touchesCurrent {
                    var completed = affected
                    completed.messages = (removed + absorbed).sorted { $0.internalDate < $1.internalDate }
                    if let normalized = completed.keeping(completed.conversation) { completed = normalized }
                    completed.acted = verb
                    completed.markedRead = true
                    completed.coachingCounted = true
                    items[index] = completed
                    if var remaining = original.keeping(original.conversation.filter { !ids.contains($0.id) }) {
                        remaining.acted = nil
                        remaining.markedRead = false
                        remaining.unresolvedContinuation = true
                        forgetDealtWith(remaining)
                        items.insert(remaining, at: index + 1)
                    }
                    finished = completed.id
                } else if ids.isSuperset(of: original.ids) {
                    items[index].acted = verb
                }
            }
        }
        await checkpoint(store: store)
        return finished
    }

    private func finishThread(at selectedIndex: Int, as verb: String) {
        let selected = items[selectedIndex]
        let matches = items.indices.filter {
            items[$0].account.lowercased() == selected.account.lowercased()
                && (selected.threadId.isEmpty ? $0 == selectedIndex : items[$0].threadId == selected.threadId)
        }
        for index in matches where items[index].coachingCounted != true {
            handledForCoaching += count(items[index])
            items[index].coachingCounted = true
        }
        let anchor = matches.contains(position - 1) ? position - 1 : selectedIndex
        let ahead = matches.filter { $0 >= position && $0 != anchor }
        var seen = Set<String>()
        let members = (items[anchor].conversation + ahead.flatMap { items[$0].conversation })
            .filter { seen.insert($0.id).inserted }
        if let merged = items[anchor].keeping(members) { items[anchor] = merged }
        for index in matches where !ahead.contains(index) {
            items[index].acted = verb
            items[index].markedRead = true
            noteDealtWith(items[index])
        }
        for index in ahead.reversed() { items.remove(at: index) }
    }

    /// Finish the message at the live cursor when a successful tool has no mail identifier.
    func markCurrentActed(as verb: String) -> String? {
        guard running, position >= 1, position <= items.count else { return nil }
        let id = items[position - 1].id
        markActed(id: id, as: verb, account: items[position - 1].account)
        return id
    }

    /// Badge a message in the buffer behind the cursor, and nothing else: an answer-shaped handoff
    /// hands it back later, and the badge catches up then.
    /// - Returns: whether it badged something, so the caller can tell this from a write that
    ///   matched nothing at all.
    func badgeBehindCursor(id: String, as verb: String, account: String? = nil, store: MailStore? = nil) async -> Bool {
        guard running, position >= 1 else { return false }
        guard let index = items.prefix(position - 1).firstIndex(where: {
            $0.holds(id) && (account == nil || $0.account.lowercased() == account?.lowercased())
        }) else { return false }
        if verb == "archive_message" {
            finishThread(at: index, as: verb)
            return true
        }
        guard items[index].acted == nil else { return false }
        let original = items[index]
        let wholeGroup = ["archive_message", "send_email", "create_draft"].contains(verb)
        if !wholeGroup, original.conversation.count > 1 {
            guard let selected = original.keeping(original.conversation.filter { $0.id == id }) else { return false }
            items[index] = selected
            if var remainder = original.keeping(original.conversation.filter { $0.id != id }) {
                remainder.acted = nil
                remainder.markedRead = false
                remainder.unresolvedContinuation = true
                forgetDealtWith(remainder)
                items.insert(remainder, at: position)
            }
        }
        items[index].acted = verb
        if let store { await checkpoint(store: store) }
        RealtimeLog.log(
            "localTriage: \(verb) landed behind the cursor — badged \(id), held at \(position)")
        return true
    }

    /// Finish the circled-back email and return the live cursor id whose suspended advance is now owed;
    /// nil for an ordinary off-cursor write. The cursor id is the callers' compare-and-step token.
    func resolveActionOutcome(
        id: String?, threadId: String?, allowUnscoped: Bool = false, as verb: String
    ) -> ActionOutcomeResolution? {
        guard running, let presented = actionOutcome else { return nil }
        let matches = if let id {
            id == presented.messageId
        } else if let threadId {
            threadId == presented.threadId
        } else {
            allowUnscoped
        }
        guard matches, let cursor = currentId else { return nil }

        actionOutcome = nil
        if let index = items.firstIndex(where: { $0.id == presented.messageId }),
           items[index].acted == nil {
            items[index].acted = verb
        }
        RealtimeLog.log(
            "localTriage: outcome presentation resolved by \(verb)"
                + (id == nil && threadId == nil ? " from the user's referent" : "")
                + " — resuming \(cursor)")
        return ActionOutcomeResolution(
            cursorId: cursor, dealtWith: presented.dealtWith)
    }

    /// Everything archived, labelled or walked past recently. Gmail walks use `gmailWalkDealtWith`
    /// so a later all-inbox review still includes read mail.
    var dealtWith: Set<String> { Set(dealtAt.keys) }

    /// Record a message as finished with, and persist it. Detached: the user is waiting on the
    /// next message, not on a 30 kB write, and a lost write costs one repeated message.
    private func noteDealtWith(_ item: Item) {
        note(item.ids.map { Self.messageKey(account: item.account, id: $0) })
    }

    static func threadKey(account: String, threadId: String) -> String {
        threadId.isEmpty ? "" : "thread:\(account.lowercased())|\(threadId)"
    }

    private func loadDealtWith() async {
        await ledgerSaveTask?.value
        let userID = await MainActor.run { Container.shared.backend().userId }
        if ledgerUserID != userID {
            gmailWalkDealtWith = []
            dispatchSweepIDs = []
            pendingArchives = []
        }
        ledgerUserID = userID
        dealtAt = userID.map { DealtWithLog.load(userID: $0) } ?? [:]
    }

    private func note(_ keys: [String]) {
        let now = Date().timeIntervalSince1970
        for key in keys where !key.isEmpty {
            dealtAt[key] = now
            gmailWalkDealtWith.insert(key)
        }
        persistDealtWith()
    }

    private func forgetDealtWith(_ item: Item) {
        for id in item.ids {
            let key = Self.messageKey(account: item.account, id: id)
            dealtAt.removeValue(forKey: key)
            gmailWalkDealtWith.remove(key)
        }
        persistDealtWith()
    }

    private func persistDealtWith() {
        let snapshot = dealtAt
        guard let userID = ledgerUserID else { return }
        let previous = ledgerSaveTask
        ledgerSaveTask = Task.detached(priority: .utility) {
            await previous?.value
            DealtWithLog.save(snapshot, userID: userID)
        }
    }

    /// Hold a finished job's answer for the next step to hand over. `false` when no queue is running,
    /// and the caller delivers it itself.
    func hold(_ outcome: Outcome) -> Bool {
        // Failures wait too, riding as `unresolved`; the caller's watchdog still speaks one if the walk
        // stops moving.
        if let account = outcome.about?.account.lowercased(),
           let active = (activeAccount ?? snapshotAccount ?? items.first?.account)?.lowercased(),
           account != active {
            guard pausedOutcomes[account] != nil else { return false }
            pausedOutcomes[account, default: []].append(outcome)
            RealtimeLog.log(
                "localTriage: holding \(pausedOutcomes[account]?.count ?? 0) outcome(s) for \(account)")
            return true
        }
        guard running, position >= 1, position <= items.count else { return false }
        // Onboarding stages speak a fixed script, which would drop an unrelated answer.
        if outcome.independent, onboardingFlow != nil { return false }
        outcomes.append(outcome)
        RealtimeLog.log("localTriage: holding \(outcomes.count) outcome(s) at \(position)")
        return true
    }

    /// Give a held answer back because nothing served it in time. `nil` means a step got there first,
    /// and the caller drops its copy.
    func release(jobId: UUID) -> Outcome? {
        if let index = outcomes.firstIndex(where: { $0.jobId == jobId }) {
            return outcomes.remove(at: index)
        }
        for account in Array(pausedOutcomes.keys) {
            guard let index = pausedOutcomes[account]?.firstIndex(where: { $0.jobId == jobId })
            else { continue }
            return pausedOutcomes[account]?.remove(at: index)
        }
        return nil
    }

    /// Every held answer, for a stop or a close: the walk is ending and there is no step left
    /// to serve them one at a time.
    private func takeOutcomes() -> [Outcome] {
        defer {
            served.append(contentsOf: outcomes.map(\.jobId))
            outcomes = []
        }
        return outcomes
    }

    /// The oldest waiting answer, marked served on the way out. One per step: two answers in
    /// one turn is the recital the start-of-call digest already forbids.
    private func takeOneOutcome() -> Outcome? {
        guard !outcomes.isEmpty else { return nil }
        let landed = outcomes.removeFirst()
        served.append(landed.jobId)
        return landed
    }

    /// Jobs whose answer has just reached a payload, read straight after `step` so the caller can mark
    /// the row delivered and the next dial does not repeat it.
    func takeServedOutcomes() -> [UUID] {
        defer { served = [] }
        return served
    }

    /// The id of the message the user is standing on, or nil when no queue is running.
    var currentId: String? {
        guard running, position >= 1, position <= items.count else { return nil }
        return items[position - 1].id
    }

    func actionAccount(messageId: String?, threadId: String?, account: String?, store: MailStore? = nil) async -> String? {
        let matches = items.filter { item in
            (account == nil || item.account.lowercased() == account?.lowercased())
                && (messageId.map { item.holds($0) } ?? threadId.map { item.threadId == $0 } ?? false)
        }
        let accounts = Set(matches.map { $0.account.lowercased() })
        if accounts.isEmpty, account == nil, let messageId, let store {
            return await store.cachedMailbox(messageId: messageId)
        }
        return accounts.count == 1 ? accounts.first : nil
    }

    func standingOnAction(messageId: String, verb: String, account: String) -> Bool {
        if standingOn(messageId: messageId, account: account) { return true }
        guard verb == "archive_message",
              let target = items.first(where: {
                  $0.holds(messageId) && $0.account.lowercased() == account.lowercased()
              }), !target.threadId.isEmpty else { return false }
        return standingOn(threadId: target.threadId, account: account)
    }

    func standingOn(messageId: String, account: String? = nil) -> Bool {
        guard running, position >= 1, position <= items.count else { return false }
        return items[position - 1].holds(messageId)
            && (account == nil || items[position - 1].account.lowercased() == account?.lowercased())
    }

    /// Speculative reads only: never restore, advance, mark read, or publish mailbox authority.
    static func openingPreparationCandidates(
        account: String, store: MailStore, grouping: Bool, preferred: Scope = .unread
    ) async -> [LiveEmailPresentation.Key] {
        var savedKeys: [LiveEmailPresentation.Key] = []
        if let database = store.database {
            do {
                if let saved = try await TriageQueueSnapshotStore.savedToday(
                    account: account, userId: store.userId, database: database)
                    .first(where: { !$0.completed && $0.items.allSatisfy { $0.account.caseInsensitiveCompare(account) == .orderedSame } }) {
                    // The item the switch or opening serves first, and the two behind it — its own
                    // snapshot's order, not the cache's guess at it.
                    savedKeys = saved.items.dropFirst(max(0, saved.position - 1)).prefix(3)
                        .compactMap(LiveEmailPresentation.Key.item)
                    RealtimeLog.log("openingSummary: \(savedKeys.count) candidate(s) from today's row for \(account)")
                }
            } catch { RealtimeLog.log("openingSummary: snapshot lookup failed — \(error)") }
        }
        let banded = await store.hasBands(account: account)
        let rows = preferred.cacheCanAnswer ? await store.unreadPage(
            before: nil, limit: pageSize, importantOnly: preferred == .important,
            account: account, importanceOrder: banded || preferred == .important) : []
        let fresh = groupByConversation(rows.map { TriageMailSource.item(from: $0) }, grouping: grouping, preserveOrder: true)
            .prefix(3).compactMap(LiveEmailPresentation.Key.item)
        var seen: Set<LiveEmailPresentation.Key.Identity> = []
        var result: [LiveEmailPresentation.Key] = []
        for key in savedKeys + fresh where seen.insert(key.identity).inserted {
            guard let inbox = await store.inboxIds(among: key.selectedIDs, account: account),
                  Set(key.selectedIDs).isSubset(of: inbox) else { continue }
            result.append(key)
        }
        return result
    }

    /// Private read-ahead candidates; requesting them never moves or presents the queue. Three deep
    /// because a summary takes ~2.2 s (p90 3.2 s) and two was outrun by quick skips.
    static let preparationReadAhead = 3

    func emailPreparationCandidates() -> [LiveEmailPresentation.Key] {
        guard running, onboardingFlow == nil, position >= 1, position <= items.count else { return [] }
        let next = Array(items.dropFirst(position).prefix(Self.preparationReadAhead))
        return (next + inboxAheadFirst(Self.preparationReadAhead - next.count))
            .compactMap(LiveEmailPresentation.Key.item)
    }

    var standingOnJSON: String? {
        guard running, position >= 1, position <= items.count else { return nil }
        let item = items[position - 1]
        var dict: [String: Any] = [
            "account": item.account, "id": item.id, "threadId": item.threadId,
            "from": item.from, "subject": item.subject,
        ]
        if item.conversation.count > 1 {
            dict["messages"] = item.conversation.map {
                ["id": $0.id, "from": $0.from, "subject": $0.subject]
            }
            dict["selectionNote"] = "The outer id is display metadata. Resolve the task's target "
                + "from the member messages; no individual message has been selected by this handoff."
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The message the user is standing on as an outcome referent, for in-process use; `standingOnJSON`
    /// is its twin that is relayed verbatim and must stay opaque text.
    var standingOnAbout: Outcome.About? {
        guard running, position >= 1, position <= items.count else { return nil }
        let item = items[position - 1]
        return Outcome.About(
            account: item.account, id: item.id, threadId: item.threadId,
            from: item.from, subject: item.subject)
    }

    /// A follow-up on a returned answer belongs to its displayed email, not the suspended cursor.
    var dispatchAnswerAbout: Outcome.About? {
        actionOutcome?.about ?? standingOnAbout
    }

    /// Is the message the user is standing on part of this thread? A reply and a draft carry only
    /// `thread_id`, so this is the only way to match one.
    func standingOn(threadId: String, account: String? = nil) -> Bool {
        guard running, position >= 1, position <= items.count else { return false }
        return items[position - 1].threadId == threadId
            && (account == nil || items[position - 1].account.lowercased() == account?.lowercased())
    }

    static func resolvedReplyThreadId(_ identifier: String, in items: [Item], account: String? = nil) -> String {
        let matches = items.filter {
            $0.holds(identifier) && (account == nil || $0.account.lowercased() == account?.lowercased())
        }
        guard Set(matches.map { $0.account.lowercased() }).count == 1 else { return identifier }
        return matches.first?.thread(for: identifier) ?? identifier
    }

    func completionMessageID(named: String?, thread: String?, verb: String, account: String?) -> String? {
        if let named { return named }
        guard ["send_email", "create_draft"].contains(verb) else { return nil }
        return Self.selectedReplyMessageID(thread, account: account, in: items)
    }

    func selectedReplyMessageID(_ identifier: String?, account: String?) -> String? {
        Self.selectedReplyMessageID(identifier, account: account, in: items)
    }

    static func selectedReplyMessageID(_ identifier: String?, account: String?, in items: [Item]) -> String? {
        guard let identifier else { return nil }
        if items.contains(where: {
            $0.threadId == identifier && (account == nil || $0.account.lowercased() == account?.lowercased())
        }) { return nil }
        let matches = items.filter {
            $0.holds(identifier) && (account == nil || $0.account.lowercased() == account?.lowercased())
        }
        return Set(matches.map { $0.account.lowercased() }).count == 1 ? identifier : nil
    }

    func draftRelayArguments(_ arguments: String) -> String {
        Self.draftRelayArguments(arguments, in: items)
    }

    /// The Nate reply, steered onto his thread as a draft; nil for any other write. Aimed at Nate
    /// it is steered for as long as onboarding runs, so a saved send preference never sends it;
    /// unaddressed, only while the welcome stage is up and its question has not been put. See
    /// `EmailOnboardingContract.welcomeReplyArguments`.
    func onboardingWelcomeReply(_ arguments: String) -> String? {
        guard let welcome = onboardingFlow?.welcome else { return nil }
        return EmailOnboardingContract.welcomeReplyArguments(
            arguments, welcome: welcome, onWelcomeStage: onboardingOnWelcome && !onboardingMailModePending)
    }

    static func draftRelayArguments(_ arguments: String, in items: [Item]) -> String {
        guard let data = arguments.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identifier = json["thread_id"] as? String else { return arguments }
        let mailbox = (json["account"] as? String)?.lowercased()
        let scoped = items.flatMap(\.unwrappedTopics).filter { mailbox == nil || $0.account.lowercased() == mailbox }
        let selected = json["reply_message_id"] as? String
        let threadMatches = scoped.filter { $0.threadId == identifier }
        let matches = threadMatches.isEmpty ? scoped.filter { $0.holds(identifier) } : threadMatches
        guard Set(matches.map { $0.account.lowercased() }).count == 1,
              let match = matches.first else { return arguments }
        if json["account"] == nil { json["account"] = match.account }
        // A real thread ID may also identify its first message; only explicit selection disambiguates it.
        if threadMatches.isEmpty, !match.threadId.isEmpty {
            json["thread_id"] = match.threadId
            if selected == nil { json["reply_message_id"] = identifier }
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: json),
              let result = String(data: encoded, encoding: .utf8) else { return arguments }
        return result
    }

    /// The `From` header of a buffered message, or nil if it is not in the buffer. Turns a bare message
    /// id into a sender term for `pruneAhead` without a Gmail lookup.
    func from(ofId id: String, account: String? = nil) -> String? {
        Self.sender(ofId: id, account: account, in: items)
    }

    static func sender(ofId id: String, account: String?, in items: [Item]) -> String? {
        let matches = items.filter {
            $0.holds(id) && (account == nil || $0.account.lowercased() == account?.lowercased())
        }
        guard Set(matches.map { $0.account.lowercased() }).count == 1 else { return nil }
        return matches.first?.conversation.first(where: { $0.id == id })?.from
    }

    /// Removes queue items strictly after the cursor from these senders or with these exact ids, and
    /// lowers `total`. The cursor and everything before it are untouched, so a sweep can never act backward.
    @discardableResult
    func pruneAhead(
        senders rawSenders: [String], ids rawIds: [String] = [], account: String? = nil
    ) -> Int {
        let senders = rawSenders.map { TriageDispatchReconciler.addressIn($0) }.filter { !$0.isEmpty }
        let ids = Set(rawIds)
        guard !senders.isEmpty || !ids.isEmpty, position <= items.count else { return 0 }
        excludeFromNavigation(senders: senders, ids: ids, account: account)

        let held = Array(items.prefix(position))
        var kept: [Item] = []
        var removed = 0
        var removedCount = 0
        for item in items.suffix(from: min(position, items.count)) {
            let inAccount = account == nil || item.account.lowercased() == account?.lowercased()
            guard inAccount else { kept.append(item); continue }
            let remaining = item.conversation.filter {
                !ids.contains($0.id) && !TriageDispatchReconciler.sentBy($0.from, senders)
            }
            guard remaining.count != item.conversation.count else { kept.append(item); continue }
            let retained = item.keeping(remaining).flatMap { count($0) > 0 ? $0 : nil }
            removed += item.conversation.count - remaining.count
            if item.acted == nil && !item.markedRead {
                removedCount += count(item) - (retained.map { count($0) } ?? 0)
            }
            if let retained { kept.append(retained) }
        }
        guard removed > 0 else { return 0 }
        items = held + kept
        total = max(0, total - removedCount)
        return removed
    }

    /// Whether the user wrote this message: a spoken name alone can't tell their mail from a participant's.
    static func fromMe(_ from: String, accounts: [String]) -> Bool {
        TriageDispatchReconciler.sentBy(from, accounts.map(TriageDispatchReconciler.addressIn))
    }

    func validatedDispatchCleanup(_ scope: DispatchCleanupScope, account: String?) -> String? {
        guard let account else { return nil }
        return Self.validatedCleanupQuery(scope, account: account, items: items)
    }

    func dispatchReconciliation(account: String?) -> DispatchReconciliation? {
        guard !adopted, running, items.indices.contains(position - 1) else { return nil }
        let current = items[position - 1]
        let mailbox = account ?? current.account
        return DispatchReconciliation(lifetime: reconciliationLifetime, account: mailbox,
            sourceThread: liveFeatures && mailbox.caseInsensitiveCompare(current.account) == .orderedSame ? current.threadId : nil)
    }

    /// Recheck the live tail after a worker finishes; failed reads never prove removal.
    func reconcileDispatch(
        _ context: DispatchReconciliation, store: MailStore,
        archivedThreads: @Sendable (String, [String]) async -> Set<String> = { account, ids in
            switch await GoogleCredential.token(for: account) {
            case .success(let token):
                return await GmailAPI.archivedThreadIDs(token: token.accessToken, ids: ids)
            case .failure(let why):
                RealtimeLog.log("localTriage: dispatch inbox verification unavailable for \(account): \(why)")
                return []
            }
        }
    ) async -> String? {
        var completion: String?
        func currentCompletion() -> String? {
            guard let completion, currentId == completion, items.indices.contains(position - 1),
                  items[position - 1].acted != nil else { return nil }
            return completion
        }
        while !Task.isCancelled {
            guard reconciliationLifetime == context.lifetime else { return nil }
            if queueBuildsInFlight > 0 {
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return nil }
                continue
            }
            guard running, !adopted else { return nil }
            let queueGeneration = generation
            let revision = confirmedEffectsRevision
            let candidates = items.dropFirst(max(0, position - 1)).filter {
                $0.account.caseInsensitiveCompare(context.account) == .orderedSame && $0.acted == nil
            }
            // A handoff already removed matching mail from the live tail. Those cached
            // messages still need confirmation, or they reappear on a later day's walk.
            let prefix = Self.messageKey(account: context.account, id: "")
            let sweptIDs = dispatchSweepIDs.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            let sweptRows = await store.messages(ids: sweptIDs, account: context.account)
            let threads = Array(Set((candidates.map(\.threadId) + sweptRows.map(\.threadId)
                + [context.sourceThread].compactMap { $0 }).filter { !$0.isEmpty }))
            guard !threads.isEmpty else { return currentCompletion() }
            let archived = await archivedThreads(context.account, threads)
            guard reconciliationLifetime == context.lifetime, !Task.isCancelled else { return nil }
            guard queueBuildsInFlight == 0, generation == queueGeneration,
                  confirmedEffectsRevision == revision else { continue }
            let effects = archived.intersection(threads).map {
                GmailWriteEffect(account: context.account, scope: "thread", threadId: $0,
                    messageIds: [], messageIdsComplete: false, operation: "modify", removeLabelIds: ["INBOX"])
            }
            guard !effects.isEmpty else { return currentCompletion() }
            let finished = await applyConfirmedEffects(effects, store: store, expectedGeneration: queueGeneration,
                expectedEffectsRevision: revision)
            guard reconciliationLifetime == context.lifetime else { return nil }
            if queueBuildsInFlight > 0 { completion = nil; continue }
            guard running else { return nil }
            if generation != queueGeneration { completion = nil; continue }
            completion = finished ?? completion
            guard confirmedEffectsRevision == revision else { continue }
            RealtimeLog.log("localTriage: dispatch reconciled archivedThreads=\(effects.count)")
            return currentCompletion()
        }
        return nil
    }

    /// Split the current display group before any cleanup badge, read mark or advance.
    @discardableResult
    func pruneIfDispatchSweepsSender(task originalTask: String, store: MailStore, account: String? = nil,
                                    cleanupScope: DispatchCleanupScope? = nil) async -> Bool {
        guard running, position >= 1, position <= items.count else { return false }
        let task: String
        if liveFeatures, let cleanupScope {
            guard Self.sweepsTheSender(originalTask), let account,
                  Self.validatedCleanupQuery(cleanupScope, account: account, items: items) != nil else {
                RealtimeLog.log("localTriage: rejected unpinned dispatch cleanup scope")
                return false
            }
            task = "Archive all " + cleanupScope.query
        } else {
            task = originalTask
        }
        guard Self.sweepsTheSender(task) else {
            let current = items[position - 1]
            // One message, not one sender: several of one person's replies cannot say which is meant,
            // so an unresolved target advances unbadged.
            return current.conversation.count == 1
                && (account == nil || current.account.lowercased() == account?.lowercased())
        }
        let index = position - 1
        let current = items[index]
        let gen = generation
        guard account == nil || current.account.lowercased() == account?.lowercased(),
              let cleanup = Self.dispatchSweepScope(task: task, item: current) else { return false }
        let said = task.lowercased()
        let cleanupInput = Self.cleanupInput(current)
        let generated = liveFeatures ? EmailCleanupPolicy.generatedCleanupCategory(task: task, item: cleanupInput) : nil
        let simpleQuery = said.range(of: #"(?:^|\s)-\S|\bor\b|[{}()]"#, options: .regularExpression) == nil &&
              said.range(of: #"\b(?!(?:from|category|in):)[a-z_]+:"#, options: .regularExpression) == nil &&
              said.range(of: #"\bin:(?!inbox\b)"#, options: .regularExpression) == nil &&
              (!said.contains("category:") || cleanup.category != nil)
        guard generated != nil || simpleQuery else { return false }
        let cached = await store.inboxMessageIDs(
            account: current.account, sender: cleanup.sender, category: cleanup.category)
        var enrichedIDs: [String] = []
        if generated != nil {
            let userId = await MainActor.run { Container.shared.backend().userId ?? "" }
            if let decision = await Container.shared.emailCleanup().decision(
                for: cleanupInput, userId: userId, store: store, within: .zero),
               decision.category == generated {
                enrichedIDs = decision.matchingMessageIDs
            }
        }
        guard cleanup.category == nil || cached != nil || !enrichedIDs.isEmpty else { return false }
        let cachedIDs = Self.dispatchPrunePlan(category: cleanup.category,
            cachedIDs: cached, enrichedIDs: enrichedIDs).ids
        guard generation == gen, position - 1 == index,
              items.indices.contains(index), items[index].ids == current.ids else { return false }
        let selected = current.conversation.filter {
            cleanup.category == nil ? TriageDispatchReconciler.sentBy($0.from, [cleanup.sender]) : cachedIDs.contains($0.id)
        }
        if liveFeatures {
            dispatchSweepIDs.formUnion(cachedIDs.map { Self.messageKey(account: current.account, id: $0) })
            navigationExcludedIDs.formUnion(cachedIDs.map {
                Self.messageKey(account: current.account, id: $0)
            })
        }
        // An off-cursor cleanup prunes matching mail ahead without finishing the current item.
        guard let selectedItem = current.keeping(selected) else {
            guard liveFeatures || cleanup.category == nil else { return false }
            let gone = cleanup.category == nil
                ? pruneAhead(senders: [cleanup.sender], account: current.account)
                : pruneAhead(senders: [], ids: Array(cachedIDs), account: current.account)
            RealtimeLog.log("localTriage: dispatch cleanup off-cursor sender pruned=\(gone)")
            await checkpoint(store: store)
            return false
        }
        let selectedIDs = Set(selected.map(\.id))
        items[index] = selectedItem
        if let remainder = current.keeping(current.conversation.filter { !selectedIDs.contains($0.id) }) {
            items.insert(remainder, at: index + 1)
        }
        let gone = cleanup.category == nil
            ? pruneAhead(senders: [cleanup.sender], account: current.account)
            : pruneAhead(senders: [], ids: Array(cachedIDs), account: current.account)
        RealtimeLog.log("localTriage: dispatch cleanup selected=\(selected.count) pruned=\(gone)")
        await checkpoint(store: store)
        return true
    }

    /// What the Live Activity's triage card draws, or nil when no queue is running. The denominator is
    /// the frozen `mailboxUnreadAtStart` (`.all` uses its own count); `max` stops "3 of 2".
    var standing: (position: Int, total: Int)? {
        guard running, position >= 1, position <= items.count else { return nil }
        if topicGrouping && scope == .unread {
            return (position: position, total: items.count)
        }
        let walked = messageOrdinal
        let walkTotal = max(total, ordinalOffset + items.reduce(0) { $0 + count($1) })
        let counted = (scope != .all && mailboxUnreadAtStart > 0)
            ? mailboxUnreadAtStart
            : walkTotal
        return (position: walked, total: max(counted, walked))
    }

    // MARK: - The payload

    /// A landed job's answer, merged onto the step it rides: before the next message and after any
    /// email-action receipt, all from one result.
    private static func outcomeFields(_ outcome: Outcome) -> [String: Any] {
        [
            "dispatchOutcome": [
                "task": outcome.task,
                "outcome": outcome.text,
            ].merging(outcome.ok == false ? ["unresolved": true] : [:]) { a, _ in a },
            "dispatchOutcomeNote": outcome.independent ? independentNote
                : (outcome.shape == .receipt ? receiptNote : answerNote) + outcomeNaming,
        ]
    }

    private static let independentNote = "Something the user asked earlier, unrelated to their "
        + "email, has been answered. Use this order: FIRST, if this turn just acted on an email, "
        + "acknowledge that action in a clause; SECOND, say \"By the way,\" name what they asked "
        + "about in a few words, and give them the answer, as briefly as it allows; THIRD, read the "
        + "message below out as normal, ending on what they want to do with it. If no email action "
        + "happened this turn, begin at SECOND. Keep all of it in this one turn. The answer is not "
        + "about the message below: \"the email\" and \"this one\" still mean the message. "

    /// The note for a job that was asked to get work done.
    private static let receiptNote = "Work they handed off earlier has come back. Use this "
        + "order: FIRST, if this turn just acted on an email, acknowledge that action "
        + "(\"That email was archived\", or the matching receipt); SECOND, use the task "
        + "below to say \"By the way, the work you asked me to do on "
        + "[who it is about, by name] is finished\" — replacing the bracketed words, never reading them "
        + "aloud — and say how it went in one clause — **name who or what it was "
        + "about**, the count it moved, every address it wrote *to*, whatever it came "
        + "back asking; THIRD, read the message below out as normal. If no email "
        + "action happened this turn, begin at SECOND. Keep all of it in this one "
        + "turn. Do "
        + "NOT drop the message to make room; and once you have said it, \"the "
        + "email\" and \"this one\" mean the message, never the job. "

    /// The note for a job that owes the user substance rather than a receipt. It names "that summary is
    /// done" because reporting completion and dropping the answer is what models do; length is `current()`'s.
    private static let answerNote = "A job they handed off earlier has come back, and it was "
        + "asked to **find something out** — so the answer below is the substance of this "
        + "turn, not a status to report. Use this order: FIRST, if this turn just acted on an "
        + "email, acknowledge that action in a clause (\"That email was archived\"); SECOND, "
        + "say \"By the way, the background research you asked me to "
        + "do on [who it is about, by name] came back\" — replacing the bracketed "
        + "words, never reading them aloud — and then **give them the answer — "
        + "everything they asked for, however many sentences that takes**; THIRD, read the "
        + "message below out as normal, ending on what they want to do with it. If no email "
        + "action happened this turn, begin at SECOND. Keep all of it in this one turn. "
        + "**\"That summary is done\" is not an answer.** They asked what something says, who "
        + "someone is, or what was decided — that is read out, never reported, and if you "
        + "find yourself saying the job finished you have dropped the thing they were waiting "
        + "for. Do NOT drop the message below to make room; and once you have given the "
        + "answer, \"the email\" and \"this one\" mean the message, never the job. "

    /// An answer served on the message it was about, as a step of its own. Not `current()`: no
    /// `position`, `note`, `last` or scope line, since the cursor has not moved.
    /// - Parameter item: this queue's own copy, when the message is still in the buffer (only items
    ///   ahead of the cursor are pruned). It carries the date, snippet and `acted` badge; the referent does not.
    private static func presentedFields(
        _ outcome: Outcome, item: Item?
    ) -> [String: Any] {
        let about = outcome.about
        var mail: [String: Any] = [
            "account": item?.account ?? about?.account ?? "",
            "id": item?.id ?? about?.id ?? "",
            "threadId": item?.threadId ?? about?.threadId ?? "",
            // Raw, exactly as `current()` emits it, so a message sounds the same whichever step serves it.
            "from": item?.from ?? about?.from ?? "",
            "subject": item?.subject ?? about?.subject ?? "",
        ]
        if let item {
            mail["date"] = item.date
            mail["snippet"] = MailHeadersOnly.snippet(item.snippet)
        }
        // Normally absent: an answer-shaped handoff does not badge the message it was about.
        if let acted = item?.acted { mail["alreadyDone"] = acted }
        var payload: [String: Any] = [
            "presentedForOutcome": true,
            "item": mail,
            "dispatchOutcomeNote": presentNote + outcomeNaming,
        ]
        var job: [String: Any] = ["task": outcome.task, "outcome": outcome.text]
        if outcome.ok == false { job["unresolved"] = true }
        payload["dispatchOutcome"] = job
        return payload
    }

    /// The returned answer owns this turn; the next user response releases the suspended queue.
    private static let presentNote = "A job they handed off earlier has come back. The message below is the email that job was about. "
        + "For this turn only, present this answer as its own feed item. Say \"By the way, the background research you asked me to do on [who it is about, by name] came back\" "
        + "— replacing the bracketed words, never reading them aloud — and give them everything they asked for, however many sentences that takes. "
        + "\"That summary is done\" is not an answer. End \"Circling back to that email from [sender].\" Do not ask its question again; it was already asked and stays open. "
        + "Use the sender below. Never say \"It's the email from …\"; do not re-read its body, announce another email, or repeat the preceding action receipt. "
        + "Wait for the user. Do not call triage_next again in this turn. That applies to this turn only; do not repeat the answer on later turns. "
        + "From here on \"the email\", \"this one\" and \"that message\" mean the message below. Pass message_id explicitly when you act on it, because the cursor is elsewhere. "
        + "Their place in the queue is untouched — nothing was skipped to make room for this, and the next triage_next carries on from where they were. "

    /// Naming the job, shared by both shapes. Keyed on where a name can be found (the outcome, then
    /// `item.from`, then the task), because a task describes a document and renders as a role.
    private static let outcomeNaming =
        "**Never say \"dispatch job\", \"that job\", \"the job is done\", or \"the "
        + "output of the background research\".** Name the original "
        + "request in plain language. For research, call it \"the background research you "
        + "asked me to do on [who it is about, by name]\"; for an action, call it \"the work you asked me "
        + "to do on [who it is about, by name]\". Replace the bracketed words; never read them aloud. Never "
        + "say \"that sender\" either. If all the task gives you is an address, say the "
        + "name it stands for — billing@mail.northwind-books.com is \"Northwind Books\". "
        + "**That subject is a name.** It is the person, company or thing the answer is "
        + "actually about, and you take it from the answer below, or from the sender of "
        + "the email the job was about — in that order. **The task is the last place to "
        + "look, not the first.** It was spoken over the message, so it says \"this one\" "
        + "and \"these\"; and it describes documents and roles rather than naming anyone, "
        + "so a task about an application paraphrases to \"that candidate\" — which names "
        + "nobody. Fall back to the task's own wording only when neither the answer nor "
        + "the sender gives you a name. **Never a role or a category when a name is "
        + "there**: \"that candidate\", \"the applicant\", \"the company\", \"that "
        + "sender\" all name nobody."

    /// Attach the deterministic post-mail stages exactly once to an automatic walk. Empty coaching
    /// yields calendar directly; nil keeps the hosted eligibility gate for a failed or older plan mint.
    func terminalFeed(
        _ base: [String: Any], trigger: String
    ) async -> String {
        guard feedEligible else { return Self.json(base) }
        let profileComplete = profileHandoff.canCompleteCurrent
        guard !feedEmitted || profileComplete else { return Self.json(base) }
        guard !pageFeedPresented || profileComplete else { return Self.json(base) }
        let scope = ProfileRuntime.snapshot
        var slackLoaded: SlackQueueCache.Loaded?
        if dynamicSlackFeed {
            slackLoaded = await slackFeedPrefetch?.value
            let stale = slackLoaded.map {
                Date().timeIntervalSince($0.generatedAt) >= SlackQueueRefresh.backgroundFreshness
            } ?? true
            if stale { slackLoaded = await SlackQueueRefresh.forFeed(scope: scope) }
            guard ProfileRuntime.snapshot?.profileId == scope?.profileId else { return Self.json(base) }
        }
        let stagesPresented = feedEmitted || pageFeedPresented
        let nextProfile = profileHandoff.takeNext()
        feedEmitted = true
        var payload = base
        payload["interstitial"] = "feed"
        payload["calendarDue"] = calendarFeedDue && !stagesPresented
        let slackTeams = slackLoaded?.teams ?? []
        let slackCount = await Container.shared.localSlack().unwalkedCount(slackLoaded?.queue)
        let slackDue = dynamicSlackFeed && slackCount > 0
            && CalendarFeedCadence.isDue(owners: SlackFeedCadence.owners(teams: slackTeams))
        if slackDue {
            payload["slackDue"] = true
            payload["slackTeams"] = slackTeams
        }
        if let nextProfile {
            payload["currentProfile"] = profileHandoff.currentName
            payload["nextProfile"] = nextProfile.name
        }
        payload["feedNote"] = "This is the terminal automatic feed. "
            + "When coaching is present, ask its exact yes/no invitation and wait. Fetch "
            + "a lesson only after yes, then follow its exact terminal question and the "
            + "tool required by the answer. After its terminal answer or a decline, "
            + "continue the remaining stages. "
            + "Then, only when calendarDue is true, say exactly \"That's all in "
            + "the emails, let's go through your calendar now.\" When calendarEvents is present it is the rest of today, already "
            + "looked up: summarize it chronologically right after that line, in the same response, "
            + "and call no time or calendar tool. Otherwise start current_time and the "
            + "calendar lookup in that same response, before results arrive. Do not offer a "
            + "demo. A calendar failure is unavailable, never an empty day. "
            + (slackDue
                // On Live the phone opens the Slack stage itself once this turn settles.
                ? liveFeatures
                    ? Self.liveSlackSentence
                    : "Then, after the calendar stage (or the tip, when no calendar is due), go "
                        + "straight on to Slack without asking: say \"Now, your Slack.\" and call "
                        + "slack_triage_next in that same response, then walk it to its close. "
                : "")
            + "Preserve the terminal completion instructions. " + FeedProfileHandoff.completionInstructions
        if !stagesPresented, let coaching = await takeFeedCoaching(page: false) { payload["coaching"] = coaching }
        // Behind a tip the stage is a later turn, so it keeps its own lookup.
        if payload["calendarDue"] as? Bool == true, payload["coaching"] == nil,
           let agenda = await inlineCalendarAgenda() {
            payload["calendarEvents"] = agenda
        }
        // With no tip or calendar in between, Slack's first conversation rides in this same step,
        // so the mail close and the first Slack conversation are one turn.
        if slackDue, payload["coaching"] == nil, payload["calendarDue"] as? Bool != true {
            let first = await Container.shared.localSlack().step(direction: nil, restart: false, stop: false)
            if !first.closed,
               let step = try? JSONSerialization.jsonObject(with: Data(first.text.utf8)) as? [String: Any] {
                payload["slackStep"] = step
                let inline = "The Slack stage has already started and slackStep is its first "
                    + "conversation: after the mail result in one clause, say \"Now, your Slack.\" and "
                    + "present slackStep in a sentence or two, ending on whether to reply, react, or "
                    + "mark it as read. Do not call slack_triage_next for it. "
                let note = payload["feedNote"] as? String ?? ""
                payload["feedNote"] = note.contains(Self.liveSlackSentence)
                    ? note.replacingOccurrences(of: Self.liveSlackSentence, with: inline)
                    : inline + note
            }
        }
        RealtimeLog.log(
            "localTriage: feed selected after \(trigger); calendar=\(calendarFeedDue) slack=\(slackDue)"
                + (payload["slackStep"] == nil ? "" : " (first Slack step inline)"))
        return Self.json(payload)
    }

    private static let liveSlackSentence = "Then the application moves straight on to Slack by itself: do not call "
        + "slack_triage_next for it and ask nothing about Slack. "

    /// Important Slack between the important mail and the rest, once per profile per call, with the
    /// cursor held on the email being left. Nil until the prefetch lands, or when nothing is high.
    private func takeImportantSlackStage(store: MailStore) async -> [String: Any]? {
        guard importantSlackStage, dynamicSlackFeed, feedEligible, !importantSlackServed,
              !(await nextIsImportantMail(store: store)) else { return nil }
        guard let prefetched = slackFeedPrefetched,
              ProfileRuntime.snapshot?.profileId == prefetched.profileId else {
            RealtimeLog.log("localTriage: important Slack due, Slack prefetch not landed — retry next step")
            return nil
        }
        importantSlackServed = true
        let queue = prefetched.loaded?.queue
        let important = queue?.items.filter { $0.band == "high" } ?? []
        guard let queue, !important.isEmpty else {
            RealtimeLog.log("localTriage: important Slack skipped — 0 of \(queue?.items.count ?? 0) high")
            return nil
        }
        var slice = queue
        slice.items = important
        let first = await Container.shared.localSlack().startImportant(slice)
        guard !first.closed,
              let step = try? JSONSerialization.jsonObject(with: Data(first.text.utf8)) as? [String: Any]
        else { return nil }
        return [
            "done": false,
            "interstitial": "slack",
            "position": messageOrdinal,
            "slackStep": step,
            "note": "Before the rest of the email, the Slack that is waiting on them. Say "
                + "\"Before the rest of your email, your Slack.\" and present slackStep in a sentence "
                + "or two, ending on whether to reply, react, or mark it as read. Do not call "
                + "slack_triage_next for it. Walk slack_triage_next from their answer; when a Slack "
                + "result says the queue is closed, call triage_next in that same response and "
                + "present the next email. The queue is still open; no next email has been supplied.",
        ]
    }

    /// The prefetch's answer, installed directly. Tests only — the call path sets it from
    /// `configureProfileHandoff`.
    func installSlackPrefetch(_ loaded: SlackQueueCache.Loaded?, profileId: String?) {
        slackFeedPrefetched = (profileId, loaded)
    }

    /// Whether the email after the current one is still top-band. Unbanded walks answer no.
    private func nextIsImportantMail(store: MailStore) async -> Bool {
        if position < items.count { return items[position].importanceBand == "high" }
        guard band == "high" else { return false }
        let peek = await store.unreadPage(
            before: before, limit: 1, importantOnly: scope.importantOnly,
            account: activeAccount, band: "high", beforeScore: beforeScore, beforeID: beforeID)
        return !peek.isEmpty
    }

    /// Finish the active mailbox before the broader Feed. With more connected mailboxes, the
    /// next turn is an explicit handoff question; Feed remains terminal only after all of them.
    private func mailboxHandoffOrFeed(
        _ base: [String: Any], trigger: String
    ) async -> String {
        let connected = await mailAccounts()
        guard connected.count > 1,
              let current = activeAccount ?? snapshotAccount ?? items.first?.account
        else { return await terminalFeed(base, trigger: trigger) }
        completedAccounts.insert(current.lowercased())
        guard let next = connected.first(where: {
            !completedAccounts.contains($0.lowercased())
        }) else { return await terminalFeed(base, trigger: trigger) }
        offeredAccount = next
        var payload = base
        payload["account"] = current
        let prior = (payload["note"] as? String).map { $0 + " " } ?? ""
        payload["note"] = prior
            + "Say they are done with the selected queue in \(current). Then ask exactly "
            + "\"Would you like to switch to \(next)?\" If they immediately agree, call "
            + "triage_next once with account \"\(next)\" and present its message. If they "
            + "decline, call triage_next with stop true. Do not call either until they answer, "
            + "and do not treat a later ambiguous yes as approval."
        RealtimeLog.log("localTriage: \(current) complete — offering \(next)")
        return Self.json(payload)
    }

    /// The next lesson not already adopted, or `nil` once the plan is spent. The plan froze
    /// at session setup, so a rule switched on since is skipped rather than offered again.
    static func nextCoachingIndex(
        in lessons: [FullDuplexBroker.CoachingLesson],
        from position: Int,
        adopted: (String) -> Bool = { StandingRule(rawValue: $0)?.isOn == true }
    ) -> Int? {
        var index = max(position, 0)
        while index < lessons.count {
            if !adopted(lessons[index].capability) { return index }
            index += 1
        }
        return nil
    }

    private func nextCoachingLesson(
        from plan: FullDuplexBroker.CoachingPlan
    ) -> FullDuplexBroker.CoachingLesson? {
        guard let index = Self.nextCoachingIndex(in: plan.lessons, from: coachingPlanPosition)
        else {
            coachingPlanPosition = plan.lessons.count
            return nil
        }
        coachingPlanPosition = index + 1
        return plan.lessons[index]
    }

    private func localCoachingInvitation(
        plan: FullDuplexBroker.CoachingPlan, checkpoint: Int, id: String,
        preferred: String? = nil
    ) -> [String: Any]? {
        let onboarding = preferred == plan.onboardingFeed?.capability ? plan.onboardingFeed : nil
        guard let lesson = onboarding ?? plan.lessons.first(where: { $0.capability == preferred })
            ?? nextCoachingLesson(from: plan) else { return nil }
        guard let speech = lesson.speech, let answer = lesson.answerInstruction else { return nil }
        RealtimeLog.log("coaching: selected locally \(lesson.capability); playback not yet confirmed")
        return [
            "checkpoint": checkpoint, "id": id, "interactive": true,
            "delivery": "local_playback",
            "lesson": ["capability": lesson.capability, "copy": lesson.copy,
                       "speech": speech, "answerInstruction": answer],
            "note": "Ask exactly `\(SpokenPhrases.coachingInvitation)` and wait. "
                + "Only after yes, speak lesson.speech exactly, without any tool call or loading "
                + "announcement. Follow answerInstruction for the terminal question. An interrupted "
                + "lesson remains available here; resume it only when asked. A no, new request, or "
                + "keep going cancels the pending tip. Resume emails with triage_next, without a "
                + "calendar interlude. Never interpret keep going as consent to a rule action. "
                + "If this is the terminal Feed, do not invent emails; respect a request to skip "
                + "calendar and follow feedNote for the profile offer or wrap-up instead.",
        ]
    }

    private func takeFeedCoaching(page: Bool) async -> [String: Any]? {
        let account = snapshotAccount ?? items.first?.account ?? "mailbox"
        // The ordinal keeps each offer's receipt distinct; the stage stays last.
        feedCoachingOrdinal += 1
        let id = [account.lowercased(), Self.localDay(), String(feedCoachingOrdinal),
                  page ? "page" : "feed"].joined(separator: "|")
        let plan = coachingPlan
        let preferred = forceOnboardingFeedLesson ? plan?.onboardingFeed?.capability : nil
        forceOnboardingFeedLesson = false
        guard localCoachingDelivery, let plan, !plan.lessons.isEmpty || preferred != nil else {
            RealtimeLog.log("localTriage: feed tip suppressed by empty plan")
            return nil
        }
        RealtimeLog.log("localTriage: feed tip invitation selected")
        return localCoachingInvitation(plan: plan, checkpoint: 1, id: id, preferred: preferred)
    }

    private func mailRemainsAfterCurrent() -> Bool {
        position < items.count || more || nextScopeInPlan() != nil
    }

    func beginPageFeed() -> Bool {
        let first = !pageFeedPresented && !feedEmitted
        pageFeedPresented = true
        return first
    }

    /// Consume a nonterminal twelve-email page only when the automatic walk has mail behind it.
    private func takeSequentialPageCheckpoint() async -> [String: Any]? {
        // Owed from the twelfth handled message onwards, not only on the exact multiple, so a declined
        // or deferred checkpoint stays owed until something serves it.
        guard handledForCoaching > 0 else { return nil }
        let checkpoint = handledForCoaching / Self.coachingEvery
        guard checkpoint > lastCoachingCheckpoint else { return nil }
        // Never in the same turn as a draft's or a send's receipt: the model speaks the receipt and drops
        // the checkpoint's script. Read off `acted`, so losing the race to `markActed` only serves it as before.
        if position >= 1, position <= items.count,
           let acted = items[position - 1].acted,
           Self.receiptAfterActing.contains(acted) {
            RealtimeLog.log("localTriage: page checkpoint \(checkpoint) deferred — the turn "
                + "owes a \(acted) receipt")
            return nil
        }
        lastCoachingCheckpoint = checkpoint
        let firstPage = beginPageFeed()
        let calendarDue = firstPage && calendarFeedDue && !localCoachingDelivery
        var payload: [String: Any] = [
            "done": false,
            "interstitial": "page",
            "position": messageOrdinal,
            "checkpoint": checkpoint,
            "calendarDue": calendarDue,
            "note": (firstPage
                ? "This is the first long-inbox pause in this fresh session. "
                    + "When coaching is present, ask its exact yes/no invitation and wait. "
                    + "After yes, follow coaching.note and the lesson’s exact terminal "
                    + "question and the tool required by the answer. After its terminal "
                    + "answer or a decline, continue. "
                    + (calendarDue
                        ? "Then say exactly \"Let's pause the emails and go through your "
                            + "calendar now.\" When calendarEvents is present it is the rest "
                            + "of today, already looked up: summarize it right after that line "
                            + "and call no time or calendar tool. Otherwise start current_time "
                            + "and the calendar lookup in that same response before results "
                            + "arrive. Cover the rest of "
                            + "today chronologically; a failed lookup is unavailable, never "
                            + "an empty day. "
                        : "Today's calendar feed is not due, so do not read the calendar. ")
                : "This session already used its tip/calendar interlude, so do not repeat "
                    + "either. ")
                + "Then call triage_next once and present the next message automatically. "
                + "The queue is still open; no next message has been supplied.",
        ]
        if firstPage, let coaching = await takeFeedCoaching(page: true) {
            payload["coaching"] = coaching
        }
        if calendarDue, payload["coaching"] == nil, let agenda = await inlineCalendarAgenda() {
            payload["calendarEvents"] = agenda
        }
        // An empty checkpoint has no work to present; advance within the same action.
        guard calendarDue || payload["coaching"] != nil else { return nil }
        return payload
    }

    /// The prefetched agenda as the stage's `calendarEvents`, or nil when it could not be
    /// read — the stage then runs the model's own lookup.
    private func inlineCalendarAgenda() async -> String? {
        guard let agenda = await calendarAgendaPrefetch?.value else { return nil }
        let remaining = CalendarSearch.remaining(agenda)
        inlinedCalendarEvents = remaining.events
        return CalendarSearch.formatted(remaining, query: "")
    }

    static func nextCoachingCheckpoint(handled: Int, last: Int) -> Int? {
        handled / coachingEvery > last ? last + 1 : nil
    }

    /// Consume one deterministic lesson slot after each complete batch of twelve messages.
    private func takeCoachingCheckpoint() async -> [String: Any]? {
        guard let checkpoint = Self.nextCoachingCheckpoint(
            handled: handledForCoaching, last: lastCoachingCheckpoint) else { return nil }
        lastCoachingCheckpoint = checkpoint
        let account = snapshotAccount ?? items.first?.account ?? "mailbox"
        let id = [
            account.lowercased(), Self.localDay(), scope.rawValue, "", String(checkpoint),
        ].joined(separator: "|")
        guard localCoachingDelivery, let plan = coachingPlan, !plan.lessons.isEmpty else {
            RealtimeLog.log("localTriage: coaching checkpoint \(checkpoint) suppressed")
            return nil
        }
        RealtimeLog.log("localTriage: coaching invitation at checkpoint \(checkpoint)")
        return localCoachingInvitation(plan: plan, checkpoint: checkpoint, id: id)
    }

    /// The step the model reads.
    /// - Parameter riding: a job's answer to say before the message, when one has come back.
    private func threadStanding() -> [String: Any]? {
        if items.indices.contains(position - 1), items[position - 1].isTopicGroup {
            return Self.threadStanding(items[position - 1], scope: scope)
        }
        let item = items[position - 1]
        if grouping, !item.threadId.isEmpty {
            let sameThread = items.indices.filter {
                items[$0].account.lowercased() == item.account.lowercased() && items[$0].threadId == item.threadId
            }
            var knownMessages = Set<String>()
            for index in sameThread {
                let member = items[index]
                knownMessages.formUnion(member.ids)
                if let summary = member.summaryMessages {
                    knownMessages.formUnion(summary.map(\.id))
                }
                if let context = member.exchangeContext {
                    knownMessages.formUnion(context.map(\.id))
                }
            }
            let messageCount = max(item.threadMessageCount ?? 0, knownMessages.count)
            guard messageCount > 1 else { return Self.threadStanding(item, scope: scope) }
            let index = (sameThread.firstIndex(of: position - 1) ?? 0) + 1
            let continues = position > 1 && sameThread.contains(position - 2)
            let summary = item.displayGroupID == "read-thread"
            var result = Self.threadStanding(item, scope: scope) ?? [:]
            result["threadId"] = item.threadId
            result["messageCount"] = messageCount
            result["exchangeId"] = item.displayGroupID
            result["index"] = index
            result["queued"] = sameThread.count
            result["continues"] = continues
            result["kind"] = summary ? "threadSummary" : "exchange"
            result["note"] = "Identify this as part of the email thread \"\(item.subject)\". "
                + (continues ? "The preceding queue item was another exchange on this same thread. " : "")
                + (summary ? "Give one summary of the whole thread and its latest reply; use get_thread if the selected snippets lack context. Do not walk its old messages one at a time. "
                           : "This queue item is one distinct exchange, from \(Self.spokenList(Self.spokenSenders(item.conversation))). ")
                + "Next moves to the next queue item, never through the old messages summarized here. "
                + (result["note"] as? String ?? "")
            return result
        }
        guard !item.threadId.isEmpty else { return Self.threadStanding(item, scope: scope) }
        let sameThread = items.indices.filter {
            items[$0].account.lowercased() == item.account.lowercased() && items[$0].threadId == item.threadId
        }
        guard sameThread.count > 1 else { return Self.threadStanding(item, scope: scope) }
        let index = (sameThread.firstIndex(of: position - 1) ?? 0) + 1
        let continues = position > 1 && sameThread.contains(position - 2)
        var note = continues
            ? "Still the same conversation as the message before it — number \(index) of \(sameThread.count). "
                + "Carry it on as another reply on that thread rather than introducing unrelated mail."
            : "This is message \(index) of \(sameThread.count) from the same conversation in the queue. "
                + "Say it is part of that thread as you read this message; the others have separate queue turns."
        if let draftNote = Self.threadStanding(item, scope: scope)?["note"] as? String {
            note += " " + draftNote
        }
        return ["queued": sameThread.count, "index": index, "continues": continues, "note": note]
    }

    static func threadStanding(_ item: Item, scope: Scope) -> [String: Any]? {
        if item.isTopicGroup {
            return ["queued": item.ids.count, "note": "These emails from the same sender concern one specific matter across separate Gmail threads. Give ONE concise summary of the latest state and outstanding requests, using all selected messages and their conversation context. Open with who and what; do not enumerate repetitive updates. End with item.suggestedQuestion when supplied: ONE checked calendar slot for the whole cluster. Otherwise ask what to do with it; never invent a proactive suggestion. Later updates supersede earlier requests. Do not suggest separate actions for each email or use only the representative. Next leaves the entire group. For archive it, call archive_message with message_id set to item.archiveGroupId and the account; this archives all presented threads; an explicitly selected email targets only its thread. Replies and other writes require a specific member; ask which one if ambiguous. Never use the representative as an implicit reply target."]
        }
        let messages = item.conversation
        let hasDraft = item.hasDraft ?? false
        let pending = item.unresolvedContinuation == true
        // A single selected message inside a longer Gmail thread still owes a summary of the
        // conversation and its latest reply, so it needs a note.
        let inLongerThread = (item.threadMessageCount ?? 1) > messages.count
        guard messages.count > 1 || hasDraft || pending || inLongerThread else { return nil }
        let unread = messages.filter(\.unread)
        let read = messages.count - unread.count
        let senders = Self.spokenSenders(unread)
        let draft = hasDraft
            ? " They already have an unsent draft on this conversation — say so before "
                + "asking what to do with it."
            : ""
        guard messages.count > 1 else {
            let continuation = pending
                ? (unread.isEmpty
                    ? "This message was already read but requeued for a decision. Do not present it as new mail."
                    : "This message was requeued for a decision.")
                : ""
            let conversation = inLongerThread
                ? "**Open with the mail, never with the fact that it is a conversation.** Say who "
                    + "it is from and what it is about or wants first, in one or two sentences, "
                    + "summarising the earlier messages and this latest reply together from the "
                    + "thread context in this result. Only after that may you note it is part of "
                    + "a conversation, and only if it helps. Never open with 'this is a thread', "
                    + "never say how many messages it holds, and never name the thread instead of "
                    + "summarising it. Read the thread only if that context is missing. "
                : ""
            return ["queued": 1, "unread": unread.count, "senders": Self.spokenSenders(messages),
                    "note": (conversation + continuation + draft).trimmingCharacters(in: .whitespaces)]
        }
        if unread.isEmpty {
            return [
                "queued": messages.count, "unread": 0,
                "senders": Self.spokenSenders(messages),
                "note": "One conversation with \(messages.count) messages they have already read. "
                    + "Summarise the selected messages once: what the conversation is about "
                    + "and what the most recent message asks for. Do not present read messages as new."
                    + draft,
            ]
        }
        return [
            "queued": messages.count,
            "unread": unread.count,
            "senders": senders,
            "note": "One conversation with \(unread.count) new "
                + "\(unread.count == 1 ? "message" : "messages"), from \(Self.spokenList(senders))"
                + (read > 0
                    ? ", plus \(read) \(read == 1 ? "message" : "messages") they have already read"
                        + (scope == .all ? ", included in this inbox review" : ", carried only as context")
                    : "")
                + ". **Open with the mail, never with the fact that it is a conversation.** Say "
                + "who it is from and what it is about or wants first. Summarise it ONCE: what "
                + "it is about, what each new message says in a "
                + "clause, and what the most recent one asks for. Do not read them out one at "
                + "a time and do not repeat the subject for each. Never open with 'this is a "
                + "thread' or lead with how many messages it holds. Never present a message "
                + "marked read as new."
                + (scope == .all ? " Summarise the selected read messages too." : " Read messages are context only.")
                + draft,
        ]
    }

    private static func spokenSenders(_ messages: [Item.Message]) -> [String] {
        var seen = Set<String>()
        return messages.map { spokenSender($0.from) }.filter { seen.insert($0.lowercased()).inserted }
    }

    /// "Marcus, Vivek and Jonathan" — a list as it is said rather than as it is punctuated.
    private static func spokenList(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        if names.count == 2 { return "\(names[0]) and \(names[1])" }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    /// Who a message is from, as a name to say.
    static func spokenSender(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "<") else { return trimmed }
        let name = trimmed[trimmed.startIndex..<open]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        return name.isEmpty ? trimmed : speakableName(name)
    }

    private static let nameSuffixes: Set<String> = ["inc", "llc", "ltd", "co", "corp", "jr", "sr", "ii", "iii",
        "iv", "phd", "md", "esq", "gmbh", "plc", "llp", "lp", "pc", "ag", "sa"]

    /// A directory-style "Last, First" display name as it is said: "First Last".
    static func speakableName(_ display: String) -> String {
        let parts = display.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return display }
        let last = parts[0].split(whereSeparator: \.isWhitespace).map(String.init)
        let first = parts[1].split(whereSeparator: \.isWhitespace).map(String.init)
        let isName = { (word: String) in
            word.first?.isLetter == true && word.allSatisfy { $0.isLetter || "'.-".contains($0) }
                && !nameSuffixes.contains(word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        }
        guard last.count <= 2, first.count <= 2, (last + first).allSatisfy(isName) else { return display }
        return (first + last).joined(separator: " ")
    }

    /// The most messages the opening list of an important walk names.
    static let rankedMax = 5
    static let nothingImportantScript =
        "There's nothing important in your inbox right now. Want to do some cleanup?"

    /// The chain's latest member, whose author `spokenIdentity` names.
    static func latestAuthor(_ item: Item) -> (from: String, recipient: String?) {
        let contextual = item.displayGroupID == "read-thread"
            ? item.summaryMessages ?? [] : item.exchangeContext ?? []
        let latest = (item.conversation + contextual)
            .max(by: { $0.internalDate < $1.internalDate })
        return (latest?.from ?? item.from, latest?.recipient ?? item.recipient)
    }

    static func spokenIdentity(_ item: Item, owned: [String] = []) -> String {
        /// A name to say, or the bare address when the header carries no display name —
        /// a placeholder there erases the only identity such a message has.
        func speakable(_ raw: String, fallback: String) -> String {
            let name = spokenSender(raw)
            guard name.contains("@") else { return name }
            return MailAddress.list(raw).first?.email ?? fallback
        }
        let (from, recipient) = Self.latestAuthor(item)
        if Self.fromMe(from, accounts: [item.account] + owned),
           let recipient, !recipient.isEmpty {
            let parsed = MailAddress.list(recipient)
            let named = parsed.map(\.name).filter { !$0.isEmpty && !$0.contains("@") }
            let names: String
            if parsed.count > 1, named.isEmpty {
                names = "the recipients"
            } else if named.count < parsed.count, !named.isEmpty {
                names = Self.spokenList(named + ["other recipients"])
            } else {
                names = named.isEmpty
                    ? speakable(recipient, fallback: "the recipient") : Self.spokenList(named)
            }
            return "Your message to \(names)"
        }
        return speakable(from, fallback: "the sender")
    }

    static func presentationMatches(_ captured: Item, current: Item) -> Bool {
        captured.account.lowercased() == current.account.lowercased()
            && captured.threadId == current.threadId && captured.ids == current.ids
            && captured.acted == current.acted && captured.markedRead == current.markedRead
            && captured.displayGroupID == current.displayGroupID
    }

    private func current(includeOutcome: Bool = false, store: MailStore) async -> String {
        if onboardingFlow != nil {
            let output = onboardingCurrent()
            guard includeOutcome, let outcome = takeOneOutcome(),
                  let data = output.data(using: .utf8),
                  var payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return output }
            payload.merge(Self.outcomeFields(outcome)) { a, _ in a }
            return Self.json(payload)
        }
        splitPendingArchiveMembers()
        if let instead = await stepPastPendingArchives(store: store) { return instead }
        if let interstitial = await nothingImportantInterstitial(store: store) { return interstitial }
        var item = items[position - 1]
        if topicGrouping, !preparingDailySnapshot { presentedTopicKeys.formUnion(Self.messageKeys([item])) }
        if onboardingExcludedThreads.contains("\(item.account):\(item.threadId)") {
            return await advance(Input(), store: store, dealtWith: false).0
        }
        let at = position
        let gen = generation
        let enricher = Container.shared.emailCleanup()
        let input = Self.cleanupInput(item)
        let userId = await MainActor.run { Container.shared.backend().userId ?? "" }
        let stale = Self.json(["stale": true, "note": "The queue changed while preparing this item. "
            + "Do not present it or act on it. Follow the user's most recent request."])
        guard gen == generation, at == position, running, items.indices.contains(at - 1),
              Self.presentationMatches(item, current: items[at - 1]) else { return stale }
        let warmEnd = min(items.count, position + 7)
        await enricher.prefetch(
            items[(position - 1)..<warmEnd].map { Self.cleanupInput($0) },
            userId: userId,
            store: store)
        // The card must not wait on a Gmail round trip. An uncached lookup gets this long,
        // then the item presents without cleanup and the worker finishes for the next step.
        let decision = await enricher.decision(
            for: input, userId: userId, store: store, within: Self.cleanupWait)
        // Every connected mailbox: mail the user sent from one arrives in another unlabelled.
        let owned = [item.account] + (await mailAccounts())
        if let drafts = await store.draftThreadIDs(account: item.account, among: item.threadIDs) {
            item.hasDraft = !drafts.isDisjoint(with: item.threadIDs)
        }
        guard gen == generation, at == position, running, items.indices.contains(at - 1),
              Self.presentationMatches(item, current: items[at - 1]) else { return stale }
        items[position - 1].hasDraft = item.hasDraft
        let riding = includeOutcome ? takeOneOutcome() : nil
        let itemPayload = Self.itemPayload(item, owned: owned, decision: decision)

        // Whatever this step ships is what a later `offer_declined` answers, so a step that
        // offers nothing leaves nothing standing for a stray decline to land on.
        standingOffer = nil
        // A sender and category the user has already turned down is not offered again, so
        // walking the next message from them is a summary rather than the same question.
        let cleanupKey = decision.map {
            Self.cleanupKey(account: item.account, from: item.from, category: $0.category.rawValue)
        }
        let cleanup = decision.flatMap { decision -> [String: Any]? in
            guard Self.cleanupCoversConversation(item, decision: decision),
                  let cleanupKey, !declinedCleanups.contains(cleanupKey),
                  !offeredCleanups.contains(cleanupKey) else { return nil }
            return EmailCleanupPolicy.cleanupPayload(item: input, decision: decision)
        }
        var payload: [String: Any] = [
            "done": false,
            "account": item.account,
            "position": messageOrdinal,
            "item": itemPayload,
        ]
        if let cleanup {
            payload["cleanup"] = cleanup
            if let cleanupKey {
                standingOffer = cleanupKey
                offeredCleanups.insert(cleanupKey)
                RealtimeLog.log("localTriage: offered cleanup \(cleanupKey)")
            }
        }
        if let thread = threadStanding() { payload["thread"] = thread }

        // The user did not pick this pile in the call, so name the automatic start once.
        if position == 1, scopeUnsaid {
            scopeUnsaid = false
            payload["scopeIsForSaying"] = "The user did not choose this pile out loud; it is "
                + "the automatic daily start. Address them directly as you/your and name it "
                + "in the opening clause as \(scope.spokenPile). Never say they/their."
        }

        if let ranked = takeRankedList(owned: owned) { payload.merge(ranked) { $1 } }

        // No `next` lookahead: nothing moves this cursor but `triage_next`, so the model would announce
        // the next message and then read it again. `nextScopeInPlan` matters: `last` closes the walk.
        if position >= items.count, !more, nextScopeInPlan() == nil {
            // A field, because the absence of `next` cannot mean "last": on the last message a model
            // following the "Next is …" template reads the placeholder aloud.
            payload["last"] = true
            // And the words: the close belongs to the turn after, so this says what not to say yet.
            payload["lastIsForSaying"] = Self.lastNote(scope: scope, adopted: adopted)
        }

        // The crossing goes in front of everything else because it takes back a close the model has
        // been told to say. Consumed once; every later step of this stage is ordinary.
        var note = ""
        if let finished = crossedFromScope {
            crossedFromScope = nil
            note += "They have finished \(TriageQueueBuilder.stageLabel(finished)) and "
            note += "\(TriageQueueBuilder.stageLabel(scope)) starts here — this is NOT the end of the mail "
            note += "walk. Say what you just did, that \(TriageQueueBuilder.stageLabel(finished)) is done, "
            note += "then move straight into this message, all in ONE turn. Do NOT say their "
            note += "inbox is clear and do NOT ask whether they want another queue. "
        }
        if let decision, cleanup != nil {
            note += Self.cleanupOfferNote(decision)
        } else {
            note += Self.summaryNote(liveFeatures: liveFeatures)
        }
        note += Self.archiveRuleNote
        payload["note"] = note

        // Last, so the answer is the freshest instruction in the payload; it is said before the message.
        if let riding { payload.merge(Self.outcomeFields(riding)) { a, _ in a } }

        return Self.json(payload)
    }

    /// A stop with some members waiting on an archive presents the rest on their own, right after it.
    private func splitPendingArchiveMembers() {
        if items.indices.contains(position - 1) {
            let selected = items[position - 1]
            let pendingMembers = selected.conversation.filter { member in
                pendingArchives.contains { $0.matches(account: selected.account, ids: [member.id],
                    threadId: member.threadId ?? selected.threadId) }
            }
            if !pendingMembers.isEmpty, pendingMembers.count < selected.ids.count,
               let pending = selected.keeping(pendingMembers),
               var remaining = selected.keeping(selected.conversation.filter { member in
                   !pendingMembers.contains { $0.id == member.id }
               }) {
                remaining.unresolvedContinuation = true
                items[position - 1] = pending
                items.insert(remaining, at: position)
            }
        }
    }

    /// Moves the cursor past stops whose archive is pending. Nil when it lands on one to present;
    /// otherwise what this step says instead, from the next stage, the close or a load failure.
    private func stepPastPendingArchives(store: MailStore) async -> String? {
        // A pending archive is omitted from presentation, never marked read as a skip.
        while items.indices.contains(position - 1), items[position - 1].conversation.allSatisfy({ member in
            pendingArchives.contains { $0.matches(account: items[position - 1].account, ids: [member.id],
                threadId: member.threadId ?? items[position - 1].threadId) }
        }) {
            position += 1
            if position > items.count, more { _ = await refill(store: store) }
        }
        if !items.indices.contains(position - 1), !more, !stalled, scope == .unread, liveFeatures {
            switch await collectUnreadArrivalsBeforeLeaving(store: store) {
            case true?: return await current(store: store)
            case nil: return gmailPending(.retryUnavailable)
            case false?: break
            }
        }
        guard items.indices.contains(position - 1) else {
            if more || stalled {
                return Self.json(["note": "The next page could not be loaded. Pending archives continue in the background; do not say the inbox is clear."])
            }
            if let next = nextScopeInPlan() {
                retainStageBeforeCrossing()
                return await build(scope: next, store: store, walking: scopePlan, crossedFromScope: scope).0
            }
            return await close()
        }
        return nil
    }

    /// The first step of an important walk with nothing important in it offers a cleanup instead.
    private func nothingImportantInterstitial(store: MailStore) async -> String? {
        if position == 1, nothingImportantCheck, !adopted {
            nothingImportantCheck = false
            if await store.weekHasNothingImportant(accounts: await queueAccounts()) {
                rankedPending = false
                scopeUnsaid = false
                nothingImportantStanding = true
                RealtimeLog.log("localTriage: nothing important this week — offering cleanup")
                return Self.json(["done": false, "interstitial": "nothingImportant", "position": 0,
                    "script": Self.nothingImportantScript,
                    "note": "Nothing this week is important. Say exactly the script and wait. On yes, "
                        + "call triage_next and present as usual. On no, do not call triage_next; "
                        + "follow what they ask next."])
            }
        }
        return nil
    }

    /// The `item` a step hands the model: the message, its conversation, and its topic members.
    private static func itemPayload(
        _ item: Item, owned: [String], decision: EmailCleanupDecision?
    ) -> [String: Any] {
        var itemPayload: [String: Any] = [
            "account": item.account,
            "id": item.id,
            "threadId": item.threadId,
            "from": item.from,
            "subject": item.subject,
            "date": item.date,
            "snippet": MailHeadersOnly.snippet(item.snippet),
            "fromMe": Self.fromMe(item.from, accounts: owned),
        ]
        // The step names who a sent message went to, so it never has to read one to say it.
        if let recipient = item.recipient, !recipient.isEmpty { itemPayload["to"] = recipient }
        itemPayload["exchangeId"] = item.displayGroupID
        for (key, context) in [("summaryMessages", item.summaryMessages), ("exchangeContext", item.exchangeContext)] {
            if let context, let data = try? JSONEncoder().encode(context),
               let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                itemPayload[key] = zip(entries, context).map { entry, message in
                    entry.merging(["fromMe": Self.fromMe(message.from, accounts: owned)]) { $1 }
                }
            }
        }
        if let acted = item.acted { itemPayload["alreadyDone"] = acted }
        let conversation = item.conversation
        if conversation.count > 1 {
            itemPayload["messages"] = conversation.map { message in
                var payload: [String: Any] = [
                    "id": message.id,
                    "threadId": message.threadId ?? item.threadId,
                    "from": Self.spokenSender(message.from),
                    "subject": message.subject,
                    "date": message.date,
                    "snippet": MailHeadersOnly.snippet(message.snippet),
                    "unread": message.unread,
                    "fromMe": Self.fromMe(message.from, accounts: owned),
                ]
                if let recipient = message.recipient, !recipient.isEmpty {
                    payload["to"] = recipient
                }
                return payload
            }
        }
        if item.isTopicGroup {
            itemPayload["groupKind"] = "topic"
            itemPayload["archiveGroupId"] = Self.topicSelectionID(item)
            itemPayload["conversations"] = item.unwrappedTopics.map { part -> [String: Any] in
                let context = part.summaryMessages ?? part.exchangeContext ?? []
                return ["threadId": part.threadId, "exchangeId": part.displayGroupID ?? "",
                    "messages": (part.conversation + context).map { member -> [String: Any] in
                        ["id": member.id, "threadId": member.threadId ?? part.threadId,
                         "from": Self.spokenSender(member.from), "subject": member.subject,
                         "snippet": MailHeadersOnly.snippet(member.snippet), "unread": member.unread,
                         "fromMe": Self.fromMe(member.from, accounts: owned)]
                    }]
            }
        }
        if item.hasDraft == true { itemPayload["hasDraft"] = true }
        // Why this one is in front of them, only ever on the top band. A reason the model can say in
        // passing, rather than a band label it would announce.
        if let why = item.importanceWhy, !why.isEmpty { itemPayload["why"] = why }
        if let decision {
            itemPayload["senderInboxCount"] = decision.senderInboxCount
        }
        // Unconditional: a cleanup offer changes what to say about the item, not who it is from.
        itemPayload["identity"] = Self.spokenIdentity(item, owned: owned)
        return itemPayload
    }

    /// "What's most important?" is answered with a short list, then the first of it. The list is
    /// the head of `items`, so the walk serves the rest in the order it was said. Said once.
    private func takeRankedList(owned: [String]) -> [String: Any]? {
        guard position == 1, rankedPending, scope == .important, !adopted else { return nil }
        rankedPending = false
        // Bulk never makes the list; it walks last, so cutting it off keeps the list the head of the walk.
        let head = items.prefix(Self.rankedMax).prefix { $0.importanceBand != "low" }
        guard !head.isEmpty else { return nil }
        var ranked: [String: Any] = [:]
        ranked["ranked"] = head.map { item -> [String: Any] in
            let identity = Self.spokenIdentity(item, owned: owned)
            var entry: [String: Any] = ["identity": identity, "subject": item.subject]
            if let why = item.importanceWhy, !why.isEmpty { entry["why"] = why }
            // Groups a sender's entries in the spoken list; none for mail you sent.
            let author = Self.latestAuthor(item).from
            if !Self.fromMe(author, accounts: [item.account] + owned),
               let address = MailAddress.list(author).first?.email, !address.isEmpty {
                entry["sender"] = address.lowercased() + "|" + identity
            }
            return entry
        }
        ranked["rankedIsForSaying"] = "They asked what matters most. Before this "
            + "message, say how many are in `ranked` and one short clause each, in "
            + "that order — e.g. \"Three things need you: …\" — using `why` where "
            + "there is one and the gist of `subject` where not. No addresses, dates or "
            + "subject lines read out as labels. Then present the first one as usual, "
            + "in the same turn. Never repeat the list on later steps."
        return ranked
    }

    /// How to put a Gmail-category cleanup offer for this item, in place of the ordinary summary.
    private static func cleanupOfferNote(_ decision: EmailCleanupDecision) -> String {
        var note = ""
        note += "This cleanup comes from Gmail's own \(decision.category.rawValue) category, "
        note += "not a local model, and it does not change queue order. Do not give the "
        note += "ordinary summary or generic action question. "
        if decision.action == .unsubscribe {
            note += "Say this shape, substituting the sender display name and exact count: "
            note += "\"You have "
            note += decision.atLeast ? "at least [count]" : "[count]"
            note += " promotional emails from [sender] in your inbox. I can unsubscribe you "
            note += "from this sender and archive those messages. Should I go ahead and "
            note += "do that? \(EmailCleanupPolicy.alternativeOfferSentence)\" "
        } else if decision.category == .promotions {
            note += "The available cleanup action is archive. Do not mention unsubscribe "
            note += "availability, route safety, or verification. Say this shape: \"You have "
            note += decision.atLeast ? "at least [count]" : "[count]"
            note += " promotional emails from [sender] in your inbox. I can archive this "
            note += "batch. Shall I do that? \(EmailCleanupPolicy.alternativeOfferSentence)\" "
        } else {
            note += "Say this shape: \"This looks like a purchase or receipt. You have "
            note += decision.atLeast ? "at least [count]" : "[count]"
            note += " purchase emails from [sender] in your inbox. I can archive this batch. "
            note += "Shall I do that? \(EmailCleanupPolicy.alternativeOfferSentence)\" "
        }
        note += "Use cleanup.senderInboxCount for [count]. For [sender], use "
        note += "cleanup.senderDisplayName exactly. The first sender reference must be that "
        note += "actual name and must never be 'this sender'; only the later reference may "
        note += "say 'this sender'. Offer that one proactive recommendation, mention the "
        note += "alternative from the sentence above, and wait. Do not list every action. "
        note += (decision.action == .unsubscribe
            ? "Neither action has run. " : "Nothing has run. ")
        note += "Only an explicit yes to this immediately preceding "
        note += "offer for this item and account authorizes cleanup. On approval call dispatch "
        note += "exactly once with cleanup.dispatch.task, cleanup.dispatch.account, "
        note += "cleanup.dispatch.expects and cleanup.dispatch.facts. Never call "
        note += "unsubscribe_sender or modify_matching inline, and do not wait for the "
        note += "background result; follow dispatch's queue advance. A topic change, "
        note += "interruption, bare acknowledgement, silence or ambiguous answer does not "
        note += "authorize cleanup. If they ask who the sender is, how many there are, or "
        note += "what the offer means, answer from this item and cleanup, repeat the same "
        note += "cleanup question, and wait; do not call triage_next. That repeated offer is "
        note += "the new immediate approval context. A no or skip calls triage_next "
        note += "without a write. On an answered no — not a skip, a topic change or an "
        note += "interruption — set offer_declined true on that triage_next, so this "
        note += "sender is not offered the same cleanup again in this call. "
        note += EmailCleanupPolicy.alternativeActionGuidance
        return note
    }

    /// How to summarize an ordinary item and what to ask after it.
    private static func summaryNote(liveFeatures: Bool) -> String {
        var note = ""
        note += "Give the normal one- or two-sentence summary. Open it with item.identity "
        note += "exactly, carry straight on into what the message says, and never speak the "
        note += "subject line as a label or a heading. "
        if !MailHeadersOnly.withholdsBodies {
            note += liveFeatures ? Self.liveBodySummary : Self.realtimeBodySummary
        } else {
            note += "Use item.snippet and supplied conversation context for what it says. "
        }
        note += "Introduce every item that way, including after an archive "
        note += "or a next. When the message is one the user sent, name who it went to "
        note += "from the item's 'to' field — 'your reply to Dana Whitfield', never just 'a reply "
        note += "you wrote' — using the display name in that field and never its address. "
        note += "For a thread summary, name the correspondent and who wrote the latest reply, "
        note += "and never borrow another member's recipients. fromMe true marks a message the user wrote: "
        note += "call it yours ('your invite', 'you proposed') and never say its sender's name. Credit what "
        note += "it says — an invitation, a proposed time or place — to the user, never to a participant its "
        note += "subject names. Credit every other message to its own sender, and quoted "
        note += "text in a snippet to whoever its attribution line names, never to the quoting sender. When the user asks to reply, say "
        note += "the recipient address the reply tool resolved, every recipient for reply-all. "
        note += "Never recite field labels such as From, Subject or Snippet, "
        note += "never spell the sender's address, and never invent the body. "
        if MailHeadersOnly.withholdsBodies {
            note += "No body is available; never fetch or infer one. "
        } else {
            note += "Only an explicit word-for-word read request gets the original wording. "
        }
        note += "End with item.suggestedQuestion VERBATIM in this same response when supplied. "
        note += "Exception: after switching items or accounts, a bare yes before this item has been presented "
        note += "answers the previous item's question, however short it was, and is not permission to present this one. "
        note += "It needs clarification: Did you mean the previous offer, or something for this email? "
        note += "Stop any summary underway; ask only that question, without acting. "
        note += "This overrides automatic presentation and the generic question below. "
        note += "It is already prepared speech: say the summary AND the whole suggested question, "
        note += "then stop. A summary alone is incomplete, even for what is this email. Ask it once per item: "
        note += "answers to follow-ups about this item end without re-asking it, and the offer stays open. No lookup "
        note += "or delegation is needed to speak these supplied fields. Otherwise ask "
        note += "'What would you like to do with it?' and nothing else. Without item.suggestedQuestion, never offer an action "
        note += "of your own (no 'want me to draft/find/accept…'). Do not invent other proactive suggestions. "
        note += "Wait for the answer. When they "
        note += "have said what to do — "
        note += "archive, label, reply, or nothing — do it and call triage_next again in "
        note += "the SAME turn to move on. Never ask whether they want to carry on."
        // Without this, an acknowledgement can make the model repeat the current message.
        note += " Once you have summarized this message, do not summarize it again — if they "
        note += "answer with nothing that decides anything (\"okay\", \"sure\", \"got it\"), "
        note += "call triage_next only if the preceding question was the generic action question "
        note += "or 'How do you want to deal with it?'. "
        note += "An explicit yes or sure to a concrete suggested action accepts that offer for "
        note += "this item and account; do not skip it. Delegate it with the suggestion text; the backend picks the tools "
        note += "and checks the calendar itself. Finding a time is synchronous, never a dispatch: keep this email selected, "
        note += "wait for the free time, ask whether it works, and do not call triage_next first. "
        note += "An open question such as 'How do you want to respond?' is not an offer: a bare yes, okay or sure "
        note += "gives no direction, so ask what they want to say and do not advance. "
        note += "No declines the suggestion without advancing; ask what they want instead. Then wait. Next "
        note += "or skip advances without accepting it. Silence or noise accepts nothing."
        return note
    }

    /// Every step carries this: noise never archives, and an explicit archive needs no confirmation.
    private static let archiveRuleNote = " Archive is NEVER the default queue action. A cough, throat-clear, breath, "
        + "background noise, silence, unintelligible audio or a laugh does not authorize "
        + "archive_message or a cleanup dispatch. If the user asks to archive, archive the "
        + "email immediately without asking for confirmation, then continue the queue. "
        + "Next or skip means triage_next without archiving. A request to read or explain "
        + "the email means answer that request, not archive or advance. An acknowledgement "
        + "such as 'that was me, got it' is not an archive instruction. Only the explicit "
        + "approval of this item's immediately preceding cleanup offer authorizes its "
        + "proposed cleanup; never infer approval from noise or an earlier email's instruction."

    static func cleanupCoversConversation(_ item: Item, decision: EmailCleanupDecision) -> Bool {
        guard item.acted == nil, let sender = EmailCleanupPolicy.sender(item.from) else { return false }
        let matching = Set(decision.matchingMessageIDs)
        return item.conversation.allSatisfy {
            matching.contains($0.id) && EmailCleanupPolicy.sender($0.from) == sender
        }
    }

    private static func cleanupInput(_ item: Item) -> EmailCleanupInput {
        EmailCleanupInput(
            account: item.account,
            id: item.id,
            from: item.from)
    }

    private static func json(_ payload: [String: Any]) -> String {
        let sanitized = EmailQueueSpeechContract.sanitize(payload)
        guard let data = try? JSONSerialization.data(withJSONObject: sanitized),
              let text = String(data: data, encoding: .utf8)
        else { return "{\"note\":\"The queue could not be read. Say so and stop.\"}" }
        return text
    }

    // MARK: - Where the mail comes from

    /// The band this walk crosses into when the one in hand runs out, or nil at the end of the last one.
    private func nextBand() -> String? {
        guard let band, let at = MailImportance.walkOrder.firstIndex(of: band),
              at + 1 < MailImportance.walkOrder.count else { return nil }
        return MailImportance.walkOrder[at + 1]
    }

    private func cachedTotal(store: MailStore) async -> Int? {
        guard scope == .unread else { return nil }
        let accounts = Set(await queueAccounts().map { $0.lowercased() })
        guard !accounts.isEmpty, let cached = await store.inboxUnread(), cached.count >= 0,
              Set(cached.accounts.map { $0.lowercased() }) == accounts
        else { return nil }
        return cached.count
    }

    /// One page: the cache if it covers it, Gmail from the phone if it does not.
    /// - Parameter knownTotal: the scope's mailbox count, when the caller has it. Only the first page
    ///   can use it, and only a count of the mailbox will do; see `cacheHoldsItAll`.
    private func fetchPage(
        before: Int64?, store: MailStore, knownTotal: Int? = nil
    ) async -> (items: [Item], before: Int64?, more: Bool, live: Bool, stalled: Bool) {
        var page: [Item] = []

        // The cache cannot answer `all` (it holds unread mail only), so that scope is always live.
        // `important` is the week the cache holds in full, so it is served from disc like `unread`.
        if scope.cacheCanAnswer {
            // A banded walk is a walk of the cache and never falls through to Gmail: bands exist only on
            // cached rows, and the reconcile mirrors the whole unread inbox, so running out is running out.
            if band != nil {
                // Exact milliseconds and a strict comparison, not the Gmail path's rounded seconds: against
                // SQLite, rounding makes a one-message band page to itself and the cursor never moves.
                var cached = await store.unreadPage(
                    before: before,
                    limit: Self.pageSize,
                    importantOnly: scope.importantOnly,
                    account: activeAccount,
                    band: band,
                    beforeScore: beforeScore, beforeID: beforeID)
                // An exhausted band hands over to the next one with a fresh watermark; the caller never
                // learns a crossing happened.
                while cached.isEmpty, let next = nextBand() {
                    band = next
                    beforeScore = nil
                    beforeID = nil
                    cached = await store.unreadPage(
                        before: nil,
                        limit: Self.pageSize,
                        importantOnly: scope.importantOnly,
                        account: activeAccount,
                        band: next)
                }
                // The cursor is the last row in sort order, not the oldest by date — with a
                // score-ordered page those are different rows.
                beforeScore = cached.last.map { $0.importanceScore ?? 0 }
                beforeID = cached.last?.id
                page = cached.map(TriageMailSource.item(from:))
                // The cursor is the last row in sort order, returned as the walk's `before`.
                let cursor = cached.last.map { $0.internalDate ?? 0 }
                // A short page means this band is done, whatever is in it. The count is the row count the
                // LIMIT applied to, not the grouped item count: a folded page is not a short one.
                let more = cached.count >= Self.pageSize || nextBand() != nil
                let enriched = await TriageMailSource.enrichThreadContext(
                    await Self.refreshFacts(await expandedTopicPage(page, store: store), store: store), store: store, grouping: grouping,
                    known: knownThreadContexts())
                return (grouped(enriched), cursor, more, false, false)
            }
            let cached = await store.unreadPage(
                before: before.map { $0 * 1000 },
                limit: Self.pageSize,
                importantOnly: scope.importantOnly,
                account: activeAccount)
            page = cached.map(TriageMailSource.item(from:))
        }

        // A short page is not a missing page: the question is whether the cache is short of the
        // mailbox. Only the first page can be settled against a mailbox count (`knownTotal` or `inboxUnread`).
        var cacheHoldsItAll = false
        // `??` takes an autoclosure, which cannot be `async`, so the fallback is an explicit branch.
        var settleAgainst = knownTotal
        if settleAgainst == nil, before == nil {
            settleAgainst = await cachedTotal(store: store)
        }
        if before == nil, let known = settleAgainst, known >= 0, page.count >= known,
           known > 0 || scope != .unread {
            cacheHoldsItAll = true
            RealtimeLog.log(
                "localTriage: cache holds all \(known) \(scope.rawValue) — no Gmail fetch")
        }

        let needsAncestry = grouping && page.contains { item in
            item.conversation.contains { $0.ancestryCached != true }
        }
        if needsAncestry || (page.count < Self.pageSize && !cacheHoldsItAll) {
            // Keep no grant, a confirmed empty result and a failed read distinct: only the
            // confirmed empty result is evidence that the mailbox ran out here.
            switch await livePage(before: before, store: store) {
            case .success(let live, let hasMore, let complete):
                page = await Self.mergingLivePage(live, with: page, store: store)
                return (grouped(await expandedTopicPage(page, store: store)), TriageMailSource.watermark(page), complete ? hasMore : true, true, !complete)
            case .unavailable:
                return (grouped(await Self.refreshFacts(page, store: store)), TriageMailSource.watermark(page), true, false, true)
            case .failure:
                return (grouped(await Self.refreshFacts(page, store: store)), TriageMailSource.watermark(page), true, true, true)
            }
        }

        // The cache answered without Gmail. `hasMore` is false only when the count says the cache holds
        // all of it; a short page with no count means unknown, which must mean "keep going".
        let enriched = await TriageMailSource.enrichThreadContext(await Self.refreshFacts(await expandedTopicPage(page, store: store), store: store), store: store, grouping: grouping,
            known: knownThreadContexts())
        return (grouped(enriched), TriageMailSource.watermark(page), !cacheHoldsItAll, false, false)
    }

    /// What `enrichThreadContext` may reuse: the buffer in hand over today's row, since a page already
    /// walked is the newer of the two.
    private func knownThreadContexts() -> [String: Item] {
        restoredThreadContexts.merging(TriageMailSource.threadContextIndex(items)) { _, held in held }
    }

    private typealias LivePageResult = TriageMailSource.LivePageResult

    /// A live page from `TriageMailSource`, unless the crossing build already holds this `all` page.
    private func livePage(
        before: Int64?, store: MailStore, scope asked: Scope? = nil
    ) async -> LivePageResult {
        let scope = asked ?? self.scope
        if asked == nil, scope == .all, inboxAheadPages != nil {
            if let prefetched = inboxAheadPages?.removeValue(forKey: before) { return prefetched }
            inboxAheadPages = nil
        }
        return await TriageMailSource.livePage(
            before: before, scope: scope, accounts: await queueAccounts(), grouping: grouping, store: store,
            unreadOpeningLoader: unreadOpeningLoader,
            cached: { account in self.scheduleEnrichment(account: account, store: store) })
    }

    /// Take an explicit set of messages as the queue, what `search_recent` just read out. `more` is
    /// false, so the walk ends where the list does.
    func adopt(_ messages: [MailStore.Message], account requestedAccount: String? = nil,
               store: MailStore) async {
        // Never over a live walk: a second `search_recent` mid-queue would reset `position`.
        guard !running else {
            RealtimeLog.log("localTriage: adopt skipped — a queue is already running")
            return
        }
        let selectedAccount = requestedAccount ?? messages.first?.account
        guard let selectedAccount else { return }
        let selected = messages.filter {
            $0.account.caseInsensitiveCompare(selectedAccount) == .orderedSame
        }
        guard !selected.isEmpty else {
            RealtimeLog.log("localTriage: adopt skipped — no rows for \(selectedAccount)")
            return
        }
        clearStageNavigation()
        activeAccount = selected.first?.account ?? selectedAccount
        snapshotAccount = activeAccount
        scope = .all
        grouping = ThreadQueue.isOn
        topicGrouping = false
        actionOutcome = nil
        scopePlan = []
        crossedFromScope = nil
        // Grouped like a built page, so an adopted queue is the same unit as any other.
        items = grouped(await TriageMailSource.enrichThreadContext(
            await Self.refreshFacts(selected.map(TriageMailSource.item(from:)), store: store),
            store: store, grouping: grouping))
        adopted = true
        // 1, not 0: `search_recent` already read these out, so the user is standing on the first.
        // At 0 the next `triage_next` would reread it and `currentId` would be nil.
        position = items.isEmpty ? 0 : 1
        ordinalOffset = 0
        before = nil
        more = false
        stalled = false
        running = !items.isEmpty
        reconciliationLifetime &+= 1
        generation &+= 1
        total = items.reduce(0) { $0 + count($1) }
        mailboxUnreadAtStart = await store.syncState(account: activeAccount ?? selectedAccount)?.inboxUnread ?? 0
        RealtimeLog.log(
            "localTriage: adopted \(items.count) from search_recent for "
                + "\(activeAccount ?? selectedAccount)")
    }

    private func grouped(_ items: [Item]) -> [Item] {
        Self.groupForPresentation(items, grouping: grouping,
                                  topicGrouping: topicGrouping && scope == .unread, preserveOrder: band != nil)
    }

    /// A complete cached page is not evidence that no new unread mail arrived during this walk.
    private func collectUnreadArrivalsBeforeLeaving(store: MailStore) async -> Bool? {
        let gen = generation
        let accounts = await queueAccounts()
        guard !accounts.isEmpty else { return nil }
        var incoming: [Item] = []
        var fullPage = false
        for account in accounts {
            guard let batch = await unreadOpeningLoader(account) else { return nil }
            guard gen == generation, scope == .unread else { return nil }
            await store.cache(batch)
            if !batch.isEmpty { scheduleEnrichment(account: account, store: store) }
            incoming += batch.map(Self.liveItem(from:))
            fullPage = fullPage || batch.count >= Self.pageSize
        }
        let held = Self.messageKeys(items).union(gmailWalkDealtWith)
            .union(dispatchSweepIDs).union(navigationExcludedIDs)
        let eligible = Self.gmailEligible(incoming, dealtWithThisWalk: held).filter { item in
            !pendingArchives.contains { $0.matches(account: item.account, ids: item.ids, threadId: item.threadId) }
        }
        let expanded = await expandedTopicPage(eligible, store: store)
        guard gen == generation, scope == .unread else { return nil }
        let fresh = grouped(expanded)
        guard !fresh.isEmpty else { return fullPage ? nil : false }
        items += fresh
        total = max(total, items.reduce(0) { $0 + count($1) })
        if fullPage {
            band = nil
            beforeScore = nil
            beforeID = nil
            before = TriageMailSource.watermark(incoming)
            more = true
        }
        RealtimeLog.log("localTriage: kept \(fresh.count) newly discovered stops in unread before all-mail")
        return true
    }

    private func reconcileUnreadOpening(account: String, store: MailStore) async -> Bool? {
        if !(await store.unreadPage(before: nil, limit: 1, account: account)).isEmpty { return true }
        guard let batch = await unreadOpeningLoader(account) else { return nil }
        await store.cache(batch)
        if !batch.isEmpty { scheduleEnrichment(account: account, store: store) }
        return !batch.isEmpty
    }

    private func scheduleEnrichment(account: String, store: MailStore) {
        guard enrichmentTasks[account] == nil else {
            enrichmentRequestedAgain.insert(account)
            return
        }
        let lifetime = reconciliationLifetime
        enrichmentTasks[account] = Task { [weak self] in
            await Container.shared.mailImportance().score(account: account, store: store)
            guard let self else { return }
            await self.enrichmentFinished(account: account, store: store, lifetime: lifetime)
        }
    }

    private func enrichmentFinished(account: String, store: MailStore, lifetime: Int) async {
        enrichmentTasks[account] = nil
        let requestedAgain = enrichmentRequestedAgain.remove(account) != nil
        guard lifetime == reconciliationLifetime else { return }
        await refreshTopicMembership(store: store, includeArrivals: true)
        if requestedAgain { scheduleEnrichment(account: account, store: store) }
    }

    /// Classification changes unseen stops only; current and previously spoken selections stay frozen.
    func refreshTopicMembership(store: MailStore, includeArrivals: Bool = false) async {
        includeUnreadArrivalsPending = includeUnreadArrivalsPending || includeArrivals
        topicRefreshPending = true
        guard !mailboxUpdateInFlight, queueBuildsInFlight == 0 else { return }
        topicRefreshPending = false
        guard running, topicGrouping, scope == .unread else { return }
        let gen = generation
        let original = items
        let cursor = position
        let frozen = max(min(position, items.count), (items.lastIndex {
            !Self.messageKeys([$0]).isDisjoint(with: presentedTopicKeys)
        }.map { $0 + 1 } ?? 0))
        var tail = Array(items.dropFirst(frozen)).flatMap(\.unwrappedTopics)
        let includedArrivals = includeUnreadArrivalsPending
        if includedArrivals {
            includeUnreadArrivalsPending = false
            let arrivals = await store.unreadPage(before: nil, limit: Self.pageSize,
                account: activeAccount ?? snapshotAccount, importanceOrder: true)
            let held = Self.messageKeys(items).union(gmailWalkDealtWith)
                .union(dispatchSweepIDs).union(navigationExcludedIDs)
            let candidates = arrivals.filter { row in
                !held.contains(Self.messageKey(account: row.account, id: row.id))
                    && !pendingArchives.contains { $0.matches(account: row.account, ids: [row.id], threadId: row.threadId) }
            }.map(TriageMailSource.item(from:))
            tail += candidates
        }
        guard !tail.isEmpty else { return }
        let refreshed = await expandedTopicPage(tail, store: store)
        guard gen == generation, cursor == position, items == original,
              !mailboxUpdateInFlight, queueBuildsInFlight == 0 else {
            topicRefreshPending = true
            includeUnreadArrivalsPending = includeUnreadArrivalsPending || includedArrivals
            return
        }
        items = Array(items.prefix(frozen)) + grouped(refreshed)
        total = max(total, items.reduce(0) { $0 + count($1) })
        guard items != original else { return }
        RealtimeLog.log("localTriage: topic enrichment regrouped unseen stops \(original.count) → \(items.count)")
        await checkpoint(store: store)
        await preparationChanged?()
    }

    private func expandedTopicPage(
        _ page: [Item], store: MailStore, excluding: Set<String> = []
    ) async -> [Item] {
        guard topicGrouping, scope == .unread else { return page }
        let selectedKeys = Self.messageKeys(page)
        let rows = await store.messages(ids: page.flatMap(\.ids)).filter {
            selectedKeys.contains(Self.messageKey(account: $0.account, id: $0.id))
        }
        let siblings = await store.topicSiblings(of: rows)
        let held = Self.messageKeys(items).union(Self.messageKeys(page)).union(gmailWalkDealtWith)
            .union(dispatchSweepIDs).union(navigationExcludedIDs).union(excluding)
        let candidates = siblings.filter { row in
            !held.contains(Self.messageKey(account: row.account, id: row.id))
                && !pendingArchives.contains { $0.matches(account: row.account, ids: [row.id], threadId: row.threadId) }
        }
        let byID = Dictionary(rows.map { (Self.messageKey(account: $0.account, id: $0.id), $0) }, uniquingKeysWith: { first, _ in first })
        let annotated = page.map { original in
            var item = original
            if let row = byID[Self.messageKey(account: item.account, id: item.id)], row.topicVersion == 1 {
                item.topicId = row.topicId
            }
            item.messages = item.conversation.map { original in
                var member = original
                member.threadId = member.threadId ?? item.threadId
                if let row = byID[Self.messageKey(account: item.account, id: member.id)], row.topicVersion == 1 {
                    member.topicId = row.topicId
                }
                return member
            }
            return item
        }
        let combined = annotated + candidates.map(TriageMailSource.item(from:))
        return Self.orderByImportance(combined, rows: rows + siblings, currentID: nil, currentAccount: nil)
    }

}

/// Where `LocalTriageQueue.dealtAt` lives between calls.
enum DealtWithLog {
    /// Short enough that mail the user wants to see again is never permanently hidden.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    static let cap = 1000

    private struct Record: Codable {
        let user_id: String
        let entries: [String: Double]
    }

    static func url(userID: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let key = Data(userID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return base.appendingPathComponent("LocalTriage", isDirectory: true)
            .appendingPathComponent("dealt-with-\(key).json")
    }

    static func load(userID: String, now: Date = Date()) -> [String: Double] {
        let path = url(userID: userID)
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        do {
            let raw = try JSONDecoder().decode(Record.self, from: Data(contentsOf: path))
            guard raw.user_id == userID else { return [:] }
            return prune(raw.entries, now: now)
        } catch {
            RealtimeLog.log("localTriage: could not load dealt-with ledger — \(error)")
            return [:]
        }
    }

    static func save(_ entries: [String: Double], userID: String, now: Date = Date()) {
        let path = url(userID: userID)
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Record(user_id: userID, entries: prune(entries, now: now)))
            try data.write(to: path, options: .atomic)
        } catch {
            RealtimeLog.log("localTriage: could not save dealt-with ledger — \(error)")
        }
    }

    /// Hand one owner's ledger to another — the identity migration, when the owner id changes.
    static func move(from old: String, to new: String) {
        let path = url(userID: old)
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        save(load(userID: old).merging(load(userID: new)) { max($0, $1) }, userID: new)
        do { try FileManager.default.removeItem(at: path) }
        catch { RealtimeLog.log("localTriage: could not remove the old dealt-with ledger — \(error)") }
    }

    /// Drop what has aged out, then keep the newest `cap`. Both bounds: a quiet week prunes nothing,
    /// and a heavy day outruns the cap.
    static func prune(_ entries: [String: Double], now: Date = Date()) -> [String: Double] {
        let cutoff = now.timeIntervalSince1970 - maxAge
        let fresh = entries.filter { $0.value >= cutoff }
        guard fresh.count > cap else { return fresh }
        let newest = fresh.sorted { $0.value > $1.value }.prefix(cap)
        return Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }
}
