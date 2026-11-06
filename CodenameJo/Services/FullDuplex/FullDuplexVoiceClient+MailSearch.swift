import FactoryKit
import Foundation

extension FullDuplexVoiceClient {
    // MARK: - Mail search

    /// `search_recent`, answered on this phone out of its own mail cache.
    ///
    /// **The first mail tool the device answers, and it takes nothing away.** The broker
    /// still serves `gmail_search_messages` for the whole mailbox across every connected
    /// account; this is the fast, offline-capable half over the last day the phone already
    /// has cached, read or unread (`MailSearch`).
    func answerRecentSearch(callId: String, argumentsJSON: String) {
        let toolArguments = ToolArguments(argumentsJSON)
        let query = toolArguments.string("query") ?? ""
        // Listing mode — "read me the last three". Answered off the newest cached rows rather
        // than by searching for a word, which is what the query above does.
        let count = toolArguments.integer("count")
        // "my last three *unread*" — the same listing with the UNREAD label required.
        let unreadOnly = toolArguments.bool("unread") ?? false
        let requestedAccount = toolArguments.string("account")
        FullDuplexTrace.note("!! search_recent \"\(query)\""
            + (count.map { " count=\($0)" } ?? "") + (unreadOnly ? " unread" : "")
            + (requestedAccount.map { " account=\($0)" } ?? ""))

        // Outside the `Task` — see `answerContextSearch`. `@MainActor` queueing is not free.
        let started = Date()
        // Captured before the `await`s below, so a search that outlives its call is told
        // apart from one that belongs here. See `dialGeneration`.
        let dial = dialGeneration
        Task { [weak self, localContext, localTriage] in
            let store = Container.shared.mailStore()
            // Archiving happens in Gmail, not in this cache, so an archived message stays the
            // newest row here — without this the same three come back.
            let account: String?
            if let queueAccount = await localTriage.currentMailbox {
                account = queueAccount
            } else if let requestedAccount {
                guard let connected = await localTriage.connectedMailbox(named: requestedAccount) else {
                    guard let self, self.isActive else { return }
                    self.finishContextTool(
                        callId: callId,
                        tool: "search_recent",
                        output: "No connected mailbox matches \"\(requestedAccount)\". Ask which "
                            + "connected inbox they meant and do not claim that no mail exists.",
                        ms: Date().timeIntervalSince(started) * 1000,
                        outcome: "refused",
                        query: requestedAccount,
                        detail: "unknown mailbox",
                        subsystem: "searchRecent",
                        dial: dial)
                    return
                }
                account = connected
            } else {
                // No queue and no named account is the common case outside the feed, not a
                // fault: the same active-or-primary mailbox `triage_next` would open.
                account = await localTriage.selectedMailbox()
            }
            let dealt = count == nil ? [] : await localTriage.dealtWith
            let result = await MailSearch.run(
                query: query, count: count, unreadOnly: unreadOnly,
                account: account, excluding: dealt, store: store)
            // The three it just read out become the queue, so "archive that one" advances to
            // the next through the same walker every other queue uses.
            if count != nil, !result.messages.isEmpty {
                await localTriage.adopt(result.messages, account: account, store: store)
            }
            guard let self, self.isActive else { return }
            let cached = await store.count()

            // Through `finishContextTool`, which draws the step and logs the timing.
            self.finishContextTool(
                callId: callId,
                tool: "search_recent",
                output: MailSearch.formatted(
                    result, query: query, count: count, unreadOnly: unreadOnly),
                ms: Date().timeIntervalSince(started) * 1000,
                // Which half answered, in the vocabulary the other local tools use — the
                // dashboard's OUTCOME column is where "the cache served this" and "Gmail
                // had to be asked" stop being indistinguishable.
                outcome: result.servedLive ? "local_miss_live" : "local_hit",
                // Listing and searching read the same store but answer different asks, so the
                // dashboard's ARGUMENT column has to tell them apart.
                query: count.map { "last \($0)" } ?? (query.isEmpty ? "(list)" : query),
                detail: "\(result.messages.count) of \(cached) cached",
                subsystem: "searchRecent",
                dial: dial
            )
        }
    }

    /// `search_drafts`, answered on this phone out of its own drafts cache.
    ///
    /// **The second mail tool the device answers, and the reason it exists is speed and
    /// account correctness rather than capability.** Finding a draft used to mean the model
    /// reasoning live about which connected mailbox to search and fanning a query out to it
    /// — every draft is now synced onto the device by `BackgroundMailRefresh`, tagged with
    /// its account, so this answers instantly and names the account in the result instead of
    /// guessing at it.
    /// - Parameter account: an optional argument the model can pass when the user names a
    ///   mailbox ("my personal account"). Left to whatever `GoogleCredential.token(for:)`
    ///   already does with an unrecognised or absent value — the primary mailbox — rather
    ///   than inventing a second resolution rule here.
    func answerDraftSearch(callId: String, argumentsJSON: String) {
        let toolArguments = ToolArguments(argumentsJSON)
        let query = toolArguments.string("query") ?? ""
        let account = toolArguments.string("account")
        FullDuplexTrace.note("!! search_drafts \"\(query)\"" + (account.map { " (\($0))" } ?? ""))

        // Outside the `Task` — see `answerContextSearch`. `@MainActor` queueing is not free.
        let started = Date()
        Task { [weak self, localContext] in
            // The queue item owns the account while a feed is running. Outside one, nil is
            // the answer `DraftSearch` already has: every mailbox, each line naming its own.
            let queueAccount = await Container.shared.localTriage().currentMailbox
            let account = queueAccount ?? account
            let store = Container.shared.mailStore()
            let result = await DraftSearch.run(query: query, account: account, store: store)
            guard let self, self.isActive else { return }
            let cached = await store.draftCount(account: account)

            // Through `finishContextTool`, for the reason `answerRecentSearch` gives.
            self.finishContextTool(
                callId: callId,
                tool: "search_drafts",
                output: DraftSearch.formatted(result, query: query, requestedAccount: account),
                ms: Date().timeIntervalSince(started) * 1000,
                outcome: result.servedLive ? "local_miss_live" : "local_hit",
                query: query.isEmpty ? "(list)" : query,
                detail: "\(result.drafts.count) of \(cached) cached",
                subsystem: "searchDrafts"
            )
        }
    }
}
