import Foundation
import FactoryKit
import UIKit

/// The job body every background wake runs: fetch mail with the phone's own token and write it
/// into the phone's own database. The watermark moves with the messages, so a killed pass just repeats.
enum BackgroundMailRefresh {
    /// What the caller should tell iOS. Maps onto `UIBackgroundFetchResult`.
    enum Result {
        case newData
        case noData
        case failed
    }

/// The fetch window: a week of inbox, read or unread, since ranking covers the past week.
/// `in:inbox` keeps never-read archived mail out. Nothing evicts by age.
    static let seedQuery = "in:inbox newer_than:7d"

    /// What onboarding seeds instead: a day, so the gets don't compete with the onboarding queue for Gmail's rate limit.
    static let onboardingSeedQuery = "in:inbox newer_than:1d"

    /// The most messages one pass fetches out of the week listing, newest first.
    static let weekFetchLimit = 200

    /// Sent mail from the same week, ids and threads only, so the important scope knows a thread was answered.
    static let sentQuery = "in:sent newer_than:7d"

    /// The most sent messages one pass fetches for that.
    static let sentFetchLimit = 50

    /// The listing that keeps the store honest, unscoped by time: cached mail outlives the window,
    /// so this is how an old message read elsewhere loses `UNREAD`. Ids only, 5 quota units per hundred.
    static let allUnreadQuery = "in:inbox is:unread"

    /// The most messages one pass will fetch. The listing is never capped, so the true unread count
    /// is always known. A silent push gets ~30 s before iOS reclaims the process; other triggers fetch everything.
    static func fetchLimit(for trigger: BackgroundRefreshLog.Trigger) -> Int {
        switch trigger {
        case .silentPush: 400
        case .launch, .manual, .signIn, .toolWrite, .staleRead: .max
        }
    }

    /// The most older unread a single pass will backfill, on top of the window. Capped because
    /// unbounded batches hit Gmail's 250 units/sec ceiling; a deeper mailbox catches up over passes.
    static let backfillLimit = 200

    /// Ids per `messages.list` page. Gmail's own maximum.
    static let listPageSize = 100

    /// Messages per `/batch/gmail/v1` request. Unbatched backfill rate-limits.
    static let batchSize = 50

    /// The shortest gap between two foreground passes, so app-switching doesn't cost a Gmail round trip.
    static let launchThrottle: TimeInterval = 2 * 60

    /// The shortest gap between two push-triggered passes. A push is a hint, and a burst collapses into one pass
    /// to protect battery.
    static let pushThrottle: TimeInterval = 10 * 60

    private static let staleKey = "mailboxMayBeStale"

    /// Whether something has changed the mailbox since the last completed pass. In `UserDefaults`
    /// so it survives a force-quit between the write and the next launch.
    static var mailboxMayBeStale: Bool {
        UserDefaults.standard.bool(forKey: staleKey)
    }

    /// Record that the mailbox may have moved under the cache. Called for every completed tool call:
    /// a missed write costs a wrong count said aloud, an extra one costs a single listing.
    static func noteMailboxMayBeStale() {
        UserDefaults.standard.set(true, forKey: staleKey)
    }

    /// Cleared only by a pass that actually reconciled, never at the start of one.
    private static func clearMailboxStale() {
        UserDefaults.standard.set(false, forKey: staleKey)
    }

    /// One pass at a time. The throttle can't do this: it compares against the last
    /// *finished* pass, so two started together both pass it.
    private actor Gate {
        static let shared = Gate()
        private var running = false
        private var idleWaiters: [CheckedContinuation<Void, Never>] = []

        func enter() -> Bool {
            if running { return false }
            running = true
            return true
        }

        func leave() {
            running = false
            let waiters = idleWaiters
            idleWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        /// A sign-out purge waits here so an in-flight refresh can't repopulate the departed mailbox.
        func waitUntilIdle() async {
            guard running else { return }
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    /// The cache teardown boundary used by `BackendService.signOut()`.
    static func waitUntilIdle() async {
        await Gate.shared.waitUntilIdle()
    }

    @discardableResult
    static func run(trigger: BackgroundRefreshLog.Trigger, refreshForCall: Bool = false) async -> Result {
        let started = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

        // Signed out means no mail. The Google grant survives a delete-and-reinstall in the keychain.
        if trigger == .launch || trigger == .silentPush {
            let signedIn = await MainActor.run { Container.shared.backend().isSignedIn }
            guard signedIn else {
                BackgroundRefreshLog.skipped(trigger, .signedOut)
                return .noData
            }
        }

        let backend = await MainActor.run { Container.shared.backend() }
        guard let progressOwner = await backend.userId, !progressOwner.isEmpty else {
            RealtimeLog.log("mail: refresh skipped — cache owner unavailable")
            return .failed
        }
        // Queued archives, spam and trash land before the pass reads the inbox they change.
        await Container.shared.pendingMailWrites().drain(userId: progressOwner)
        // `manual` has no floor: it is the diagnostic. `signIn` has none: it must beat the no-grant
        // `launch` failure seconds earlier, and the throttle ignores outcome.
        let floor: TimeInterval? = switch trigger {
        case .silentPush: pushThrottle
        // A known-stale cache outranks the launch throttle.
        case .launch: mailboxMayBeStale ? nil : launchThrottle
        case .manual, .signIn, .toolWrite, .staleRead: nil
        }
        if !refreshForCall, let floor, let last = BackgroundRefreshLog.entries.first,
           Date().timeIntervalSince(last.at) < floor {
            let ago = Int(Date().timeIntervalSince(last.at))
            BackgroundRefreshLog.skipped(trigger, .throttled(secondsAgo: ago))
            // A recent push may have refreshed the cache without preparing the queue, so prepare it from local rows.
            if trigger == .launch {
                await prepareDailyQueue(store: Container.shared.mailStore())
            }
            return .noData
        }

        guard await Gate.shared.enter() else {
            BackgroundRefreshLog.skipped(trigger, .alreadyRunning)
            return .noData
        }
        defer { Task { await Gate.shared.leave() } }

        RealtimeLog.log("mail: \(trigger.rawValue) pass starting")

        // Every mailbox the phone holds a grant for, not just the primary.
        let mailboxes = GoogleAccountStore.emails()
        guard !mailboxes.isEmpty else {
            BackgroundRefreshLog.record(
                trigger, .credentialFailed(GoogleCredential.Failure.noStoredGrant.logLabel),
                ms: elapsed())
            return .noData
        }

        let store = await Container.shared.mailStore()

        // Sequential: Gmail's quota is per user, and one mailbox's failure must not cancel another's writes.
        var cachedTotal = 0
        var anyReconciled = false
        var lastFailure: GoogleCredential.Failure?
        var fetchError: Error?

        for account in mailboxes {
            let token: GoogleCredential.Token
            switch await GoogleCredential.token(for: account) {
            case .success(let value):
                token = value
            case .failure(let failure):
                // One mailbox's dead grant does not end the pass.
                RealtimeLog.log("mail: \(account) skipped — \(failure.logLabel)")
                lastFailure = failure
                continue
            }
            do {
                let resolved = try await resolveAccount(token: token)
                // Retry mark-reads Gmail never confirmed; this pass already wakes often enough.
                await flushMarkReadOutbox(token: token.accessToken, account: resolved, store: store)
                cachedTotal += try await reconcile(
                    token: token.accessToken, account: resolved,
                    store: store, trigger: trigger, elapsed: elapsed
                )
                anyReconciled = true
                // Best-effort: a drafts failure must not fail the mail sync. Skipped during onboarding,
                // where the per-draft gets would compete with the onboarding queue for Gmail's rate limit.
                if !OnboardingState.isComplete || OnboardingResume.runId != nil {
                    RealtimeLog.log("mail: \(resolved) draft sync skipped — onboarding")
                } else {
                    do {
                        let cachedDrafts = try await reconcileDrafts(
                            token: token.accessToken, account: resolved, store: store)
                        RealtimeLog.log("mail: \(resolved) → \(cachedDrafts) draft(s) cached")
                    } catch {
                        RealtimeLog.log("mail: \(resolved) draft sync failed — \(label(for: error))")
                    }
                }
            } catch is CancellationError {
                // Stop the whole pass: the budget that ran out belongs to every mailbox.
                recordExpiry(trigger: trigger, startedAt: started)
                return .noData
            } catch {
                RealtimeLog.log("mail: \(account) failed — \(label(for: error))")
                fetchError = error
            }
        }

        // Prepare the first daily queue step before any contact work, which isn't on the path to Jo's first message.
        let appIsActive = await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        if anyReconciled, trigger != .silentPush || appIsActive {
            await prepareDailyQueue(store: store)
        }

        // `ContactScan`'s Gmail walk is unwired; the directory is built from cached mail and calendar.
        // _ = await ContactScan.run(
        //     token: token, account: account, store: Container.shared.contactStore(),
        //     deadline: deadline, force: trigger == .manual
        // )

        // Only when nothing failed: a partial pass hasn't proved the cache clean.
        if anyReconciled, fetchError == nil, lastFailure == nil { clearMailboxStale() }

        if !anyReconciled {
            if let fetchError {
                BackgroundRefreshLog.record(
                    trigger, .fetchFailed(label(for: fetchError)), ms: elapsed())
                return .failed
            }
            let failure = lastFailure ?? .noStoredGrant
            BackgroundRefreshLog.record(
                trigger, .credentialFailed(failure.logLabel), ms: elapsed())
            return failure.isWorthRetrying ? .failed : .noData
        }

        // One mailbox reconciling lands here.
        BackgroundRefreshLog.record(
            trigger,
            cachedTotal == 0 ? .upToDate : .synced(cached: cachedTotal, seeded: false),
            ms: elapsed())
        return cachedTotal == 0 ? .noData : .newData
    }

    // MARK: - The pass

    /// Turn a current mail cache into the durable first daily queue step. Separate from reconciliation
    /// because a throttled launch still needs it.
    private static func prepareDailyQueue(store: MailStore) async {
        await Container.shared.workspaceProfiles().prepareProfileOpenings(store: store)
        guard AgentLedEmailSettings.isEnabled else { return }
        // Importance scoring runs here, before the snapshot, on mail already on disc. No Gmail request.
        for account in ProfileRuntime.allowedMailAccounts(GoogleAccountStore.mailAccounts()) {
            await Container.shared.mailImportance().score(account: account, store: store)
        }
        await Container.shared.localTriage().refreshTopicMembership(store: store, includeArrivals: true)
        await Container.shared.localTriage().prepareDailySnapshot(store: store, liveFeatures: true)
    }

    /// Retry every mark-read Gmail never confirmed for one mailbox.
    /// Retry every mark-read Gmail never confirmed for one mailbox. Never throws; rows left behind
    /// are retried next pass, with no attempt cap.
    private static func flushMarkReadOutbox(token: String, account: String, store: MailStore) async {
        let pending = await store.pendingMarkReads(account: account)
        guard !pending.isEmpty else { return }
        var cleared = 0
        for row in pending {
            do {
                try await GmailAPI.markRead(token: token, id: row.messageId)
                await store.removeMarkReadOutbox(row.messageId)
                cleared += 1
            } catch {
                RealtimeLog.log("mail: outbox retry failed for \(row.messageId) — \(error)")
            }
        }
        RealtimeLog.log("mail: outbox cleared \(cleared) of \(pending.count) for \(account)")
    }

    /// Make the cache hold every unread message in the mailbox, and nothing stale.
    /// Make the cache hold every unread message in the mailbox, and nothing stale. A full reconcile,
    /// not a delta: `history.list` never revisits mail older than the first fill. Message ids are stable.
    /// - Returns: how many messages it cached for this mailbox.
    private static func reconcile(
        token: String,
        account: String,
        store: MailStore,
        trigger: BackgroundRefreshLog.Trigger,
        elapsed: () -> Int
    ) async throws -> Int {
        // Taken before the listing, so mail arriving mid-pass is newer than the watermark.
        let watermark = try await GmailAPI.profile(token: token).historyId

        // Two listings: the window says what to fetch; the unscoped unread listing says what is still unread at all.
        let onboarding = !OnboardingState.isComplete
        var windowRefs: [GmailAPI.MessageRef] = []
        var pageToken: String?
        repeat {
            let page = try await GmailAPI.messagePage(
                token: token, query: onboarding ? onboardingSeedQuery : seedQuery,
                limit: listPageSize, pageToken: pageToken
            )
            try Task.checkCancellation()
            windowRefs.append(contentsOf: page.messages ?? [])
            pageToken = page.nextPageToken
        } while pageToken != nil
        let windowIds = windowRefs.map(\.id)

        // Kept in listing order (newest first) because this is also the backfill queue.
        var allUnreadOrdered: [String] = []
        pageToken = nil
        repeat {
            let page = try await GmailAPI.messagePage(
                token: token, query: allUnreadQuery, limit: listPageSize, pageToken: pageToken
            )
            try Task.checkCancellation()
            allUnreadOrdered.append(contentsOf: (page.messages ?? []).map(\.id))
            pageToken = page.nextPageToken
        } while pageToken != nil
        let allUnreadIds = Set(allUnreadOrdered)

        // Recent first, then backfill. Checked against both listings, or cached read mail would refetch every pass.
        let known = await store.existingIds(among: Array(Set(allUnreadOrdered + windowIds)))
        let inWindow = Set(windowIds)
        let recentMissing = windowIds.filter { !known.contains($0) }
        let olderMissing = allUnreadOrdered.filter {
            !known.contains($0) && !inWindow.contains($0)
        }
        // The true shortfall, before either cap, so a capped pass reports what it left.
        let uncached = recentMissing.count + olderMissing.count
        let allMissing = Array(recentMissing.prefix(weekFetchLimit))
            + Array(olderMissing.prefix(backfillLimit))
        let missing = Array(allMissing.prefix(fetchLimit(for: trigger)))
        // Exact, because the unread listing is complete: anything held unread that Gmail didn't list was read or archived.
        let staleUnread = await store.unreadIdsNotIn(allUnreadIds, account: account)
        // Read mail archived in Gmail, within the week window less an hour so a boundary row doesn't flap.
        let archived = onboarding ? [] : await store.inboxIdsNotIn(
            Set(windowIds), account: account,
            since: MailStore.importantSince(now: Date().addingTimeInterval(-60 * 60)))

        // The `INBOX` label's `messagesUnread`: exact where a listing caps out. -1 when Gmail refused, distinct from 0.
        let totalUnread = (try? await GmailAPI.inboxUnreadCount(token: token)) ?? -1
        // The sentinel never reaches the store. Nil makes `apply` keep the last good count.
        let storedUnread = totalUnread >= 0 ? totalUnread : nil

        RealtimeLog.log(
            "mail: \(totalUnread) unread in inbox · \(allUnreadIds.count) listed · "
            + "last \(onboarding ? "24h" : "7d"): \(windowIds.count) · not cached: \(uncached) · "
            + "fetching \(missing.count) (\(recentMissing.count) recent, "
            + "\(missing.count - recentMissing.count) backfill)"
            + (uncached > missing.count
               ? " · \(uncached - missing.count) deferred to the next pass" : "")
            + " · \(staleUnread.count) since read · \(archived.count) since archived")

        // Fetched in batches; one-at-a-time rate-limits.
        var cached = 0
        for chunk in stride(from: 0, to: missing.count, by: batchSize) {
            let slice = Array(missing[chunk..<min(chunk + batchSize, missing.count)])
            var details = await GmailAPI.metadataBatch(token: token, ids: slice)
            try Task.checkCancellation()

            // `/batch/gmail/v1` came back 30–50% short on a real mailbox, so whatever it drops is fetched singly.
            let returned = Set(details.map(\.id))
            let dropped = slice.filter { !returned.contains($0) }
            if !dropped.isEmpty {
                RealtimeLog.log(
                    "mail: batch returned \(details.count) of \(slice.count) — "
                    + "fetching \(dropped.count) singly")
                details += await GmailAPI.metadata(token: token, ids: dropped)
                try Task.checkCancellation()
            }
            let batch = details.map { MailStore.Ingest(detail: $0, account: account) }
            // Written per batch so a pass killed partway keeps what it already fetched.
            await store.apply(
                batch, account: account, historyId: watermark, inboxUnread: storedUnread)
            cached += batch.count
        }

        if !staleUnread.isEmpty {
            await store.clearUnread(staleUnread)
        }
        if !archived.isEmpty {
            await store.clearInbox(archived)
        }
        if !onboarding, trigger != .silentPush {
            await cacheAnsweringSent(
                token: token, account: account, store: store,
                inboxThreads: Set(windowRefs.map(\.threadId)))
        }
        // Written even when nothing was fetched, so the count stays current on a quiet mailbox.
        if missing.isEmpty, let storedUnread {
            await store.apply([], account: account, historyId: watermark, inboxUnread: storedUnread)
        }

        // `run` owns the stale flag and the log row for the whole pass.
        RealtimeLog.log("mail: \(account) → \(cached) cached, \(staleUnread.count) since read")
        return cached
    }

    /// Cache the user's sent mail in threads the week's inbox holds, so the important scope can skip
    /// answered messages. Best-effort: a failure leaves a thread looking unanswered, never loses mail.
    private static func cacheAnsweringSent(
        token: String, account: String, store: MailStore, inboxThreads: Set<String>
    ) async {
        guard !inboxThreads.isEmpty else { return }
        var refs: [GmailAPI.MessageRef] = []
        var pageToken: String?
        do {
            repeat {
                let page = try await GmailAPI.messagePage(
                    token: token, query: sentQuery, limit: listPageSize, pageToken: pageToken)
                refs.append(contentsOf: page.messages ?? [])
                pageToken = page.nextPageToken
            } while pageToken != nil
        } catch {
            RealtimeLog.log("mail: sent listing failed — \(label(for: error))")
            return
        }
        let answering = refs.filter { inboxThreads.contains($0.threadId) }.map(\.id)
        let known = await store.existingIds(among: answering)
        let missing = Array(answering.filter { !known.contains($0) }.prefix(sentFetchLimit))
        guard !missing.isEmpty else { return }
        var details = await GmailAPI.metadataBatch(token: token, ids: missing)
        let returned = Set(details.map(\.id))
        details += await GmailAPI.metadata(token: token, ids: missing.filter { !returned.contains($0) })
        await store.cache(details.map { MailStore.Ingest(detail: $0, account: account) })
        RealtimeLog.log("mail: \(details.count) sent repl(ies) cached for the important scope")
    }

    static func allDraftReferences(
        fetchPage: (String?) async throws -> GmailAPI.DraftList
    ) async throws -> [GmailAPI.DraftRef] {
        var refs: [GmailAPI.DraftRef] = []
        var pageToken: String?
        var seenIDs = Set<String>()
        var seenTokens = Set<String>()
        repeat {
            let page = try await fetchPage(pageToken)
            try Task.checkCancellation()
            refs.append(contentsOf: (page.drafts ?? []).filter { seenIDs.insert($0.id).inserted })
            pageToken = page.nextPageToken
            if let pageToken, !seenTokens.insert(pageToken).inserted {
                throw NSError(domain: "GmailDraftSync", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Gmail draft pagination repeated a page token."])
            }
        } while pageToken != nil
        return refs
    }

    /// Make the drafts cache match the mailbox, wholesale.
    /// Make the drafts cache match the mailbox, wholesale. There is no `drafts.history`, and drafts are few.
    /// - Returns: how many drafts it cached for this mailbox.
    private static func reconcileDrafts(
        token: String, account: String, store: MailStore
    ) async throws -> Int {
        let refs = try await allDraftReferences { pageToken in
            try await GmailAPI.draftPage(token: token, limit: listPageSize, pageToken: pageToken)
        }
        // `drafts.get` has no cheaper change signal, so already-cached drafts aren't refetched.
        let known = await store.draftsById(account: account)
        let missing = refs.filter { known[$0.id] == nil }

        var details: [GmailAPI.DraftDetail] = []
        for start in stride(from: 0, to: missing.count, by: batchSize) {
            let batch = missing[start..<min(start + batchSize, missing.count)]
            let fetched = try await withThrowingTaskGroup(of: GmailAPI.DraftDetail.self) { group in
                for ref in batch {
                    group.addTask { try await GmailAPI.draftDetail(token: token, id: ref.id) }
                }
                var result: [GmailAPI.DraftDetail] = []
                for try await detail in group {
                    guard detail.message != nil else {
                        throw NSError(domain: "GmailDraftSync", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "Gmail returned a draft without its message."])
                    }
                    result.append(detail)
                }
                return result
            }
            details.append(contentsOf: fetched)
        }
        try Task.checkCancellation()

        let fetched = details.compactMap { detail -> MailStore.Draft? in
            guard let message = detail.message else { return nil }
            return MailStore.Draft(
                id: detail.id,
                messageId: message.id,
                threadId: message.threadId,
                account: account,
                recipient: message.header("To"),
                subject: message.header("Subject"),
                snippet: message.snippet,
                internalDate: message.internalDate.flatMap(Int64.init),
                cachedAt: Date()
            )
        }
        // Reused rows keep their original `cachedAt`.
        let keptIds = Set(refs.map(\.id)).subtracting(missing.map(\.id))
        let kept = keptIds.compactMap { known[$0] }
        let all = fetched + kept

        await store.applyDrafts(all, account: account)
        return all.count
    }

    /// When the correspondent walk must stop, or nil to skip it on this trigger.
    /// When the correspondent walk must stop, or nil to skip it on this trigger. Nil on a silent push:
    /// `AppDelegate` gives it ~25 s, which belongs to the unread cache.
    private static func contactsDeadline(
        trigger: BackgroundRefreshLog.Trigger, startedAt: Date
    ) -> Date? {
        switch trigger {
        case .silentPush: nil
        // Not on sign-in: the walk owned Gmail's per-second quota and 429'd onboarding.
        case .signIn: nil
        // Generous: nobody is waiting, and this is someone watching Settings.
        case .manual: startedAt.addingTimeInterval(90)
        // Bounded: a foreground pass competes with a dial the user may be about to start.
        case .launch: startedAt.addingTimeInterval(20)
        // Mid-call: never spend a live call's Gmail quota on the directory.
        case .toolWrite, .staleRead: nil
        }
    }

    // MARK: - Helpers

    /// Which mailbox this is.
    /// Which mailbox this is. `users.getProfile` covers a restored grant with an empty cached profile;
    /// the account column keys sync state, so a guess would make a phantom mailbox.
    private static func resolveAccount(token: GoogleCredential.Token) async throws -> String {
        if let email = token.email, !email.isEmpty { return email }
        let profile = try await GmailAPI.profile(token: token.accessToken)
        guard let address = profile.emailAddress, !address.isEmpty else {
            throw GmailAPI.Failure.decoding("profile carried no address")
        }
        return address
    }

    /// Short, stable, and free of anything from a mailbox.
    private static func label(for error: Error) -> String {
        switch error {
        case GmailAPI.Failure.unauthorized: return "unauthorized"
        case GmailAPI.Failure.historyExpired: return "history_expired"
        case GmailAPI.Failure.http(let code): return "http_\(code)"
        case GmailAPI.Failure.transport(let detail): return "transport(\(detail))"
        // Keeps the detail: `GmailAPI` names the path and quotes the body's first bytes.
        case GmailAPI.Failure.decoding(let detail): return "decoding \(detail)"
        default: return "unknown"
        }
    }

    /// Record a pass that was cancelled before it finished.
    /// Record a pass that was cancelled before it finished. Synchronous and minimal so an
    /// expiration handler, which has moments rather than seconds, could call it too.
    static func recordExpiry(trigger: BackgroundRefreshLog.Trigger, startedAt: Date) {
        BackgroundRefreshLog.record(
            trigger, .expired, ms: Int(Date().timeIntervalSince(startedAt) * 1000)
        )
    }
}
