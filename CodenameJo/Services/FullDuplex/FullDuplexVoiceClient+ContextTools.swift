import FactoryKit
import Foundation

extension FullDuplexVoiceClient {
    /// Answer `local_search_context` from GRDB, without leaving the phone.
    ///
    /// The whole reason this tool exists: a hit costs an FTS5 query and a data-channel
    /// hop, where every other lookup on this path costs OpenAI's ~700 ms round trip to
    /// our MCP server *before* the work starts. Whether that difference is audible is
    /// the thing to measure, and `DialTiming`-style logging here is what will answer it.
    ///
    /// **`query` is the only argument read, and a missing one is not an error.** The
    /// model occasionally calls a tool with `{}` while it works out what it wanted; an
    /// empty query returns the miss sentence, which reads as "nothing stored" and costs
    /// one turn, rather than as a broken tool.
    /// `search_context` — the local read.
    ///
    /// The whole reason the store exists on the phone: a hit costs an FTS5 query and a
    /// data-channel hop, where the same tool on our MCP server cost OpenAI's ~700 ms round
    /// trip *before* the work started. Measured at 11 ms on device.
    ///
    /// **A missing `query` is not an error.** The model occasionally calls a tool with `{}`
    /// while it works out what it wanted; an empty query returns the miss sentence, which
    /// costs one turn, rather than reading as a broken tool.
    func answerContextSearch(callId: String, argumentsJSON: String) {
        let toolArguments = ToolArguments(argumentsJSON)
        let query = toolArguments.string("query") ?? ""
        // **Absent means "as before", not `call`.** The two halves defaulted differently
        // before this argument existed — the cache to this call, the turns to everything —
        // and a broker too old to declare `scope` has to keep getting exactly that, or
        // shipping the app first would quietly take cross-call recall away. An unrecognised
        // value is `call`: a typo must not widen a search. See `RecallScope.parse`.
        let scope = RecallScope.parse(toolArguments.string("scope"))
        RealtimeLog.log("localContext: search \"\(query)\" (\(scope?.rawValue ?? "unscoped")) — answering on device")
        FullDuplexTrace.note("!! search_context \"\(query)\" [\(scope?.rawValue ?? "unscoped")]")
        let conversation = conversationId()
        // Whose turns to search. Read here rather than in the store because the store is not
        // `@MainActor` and `BackendService` is — and it is a filter rather than a purge for
        // the reason `TurnStore.Turn.userId` gives.
        let owner = contextOwner
        // The dial this search belongs to, for the reason `answerRecentSearch` captures one:
        // `isActive` is true again on a re-dial, so an answer that resolves after a hang-up
        // would post into a conversation it was never about. See `dialGeneration`.
        let dial = dialGeneration
        // **Outside the `Task`, and that is the whole point.** This class is `@MainActor`, so
        // the closure below cannot start until the main thread is free — and a voice turn is
        // exactly when it is not. Started inside, the clock skipped that wait and every local
        // tool under-reported by however long it queued.
        let started = Date()
        localContextTasks[callId] = Task { [weak self, localContext] in
            // **Two memories, searched together — the broker did this and it matters.**
            // The store holds what was *fetched*; the turns hold what was *said*. A
            // resumed conversation often has only the second, which is exactly the case a
            // cache-only search answers "nothing stored" to. `searchConversationTurns` ran
            // in parallel with the cache server-side; here both are local, so the pair
            // costs what the slower one costs and the slower one is single-digit ms.
            // **The two halves widen differently, and that asymmetry is deliberate.** A
            // wider scope reaches earlier *turns* freely — what was said stays true — but
            // reaches earlier cache rows only where the model deliberately saved one. See
            // `LocalContextStore.search` for the session that proved why: an unscoped search
            // answered "what's in my inbox" with two earlier calls' unread lists, and a day
            // scope narrows that window without closing it.
            let result = await localContext.search(
                query, conversationId: conversation, userId: owner, scope: scope ?? .call)
            // **A bare time is a request for that call, not a search.** The day list below
            // hands the model `12:40`; quoting it back reads that whole call, oldest turn
            // first. Same move as the cache half's `m_N` fetch, one level up.
            let store = TurnStore(database: localContext.dbPool)
            let asked = TurnStore.callHandle(in: query)
            let oneCall = asked == nil
                ? nil
                : await store.turns(ofCallStartingAt: asked!, userId: owner)
            // **"No handle in the query" and "that handle resolved to nothing" are different
            // answers.** Both used to fall through to an ordinary search, whose recency
            // top-up then returned the previous or current call — presented as the transcript
            // that was asked for. That hands back the wrong conversation precisely when the
            // handle was ambiguous, undoing the check that refused to guess.
            let handleMissed = asked != nil && oneCall == nil
            // **An `m_N` query is an exact cache fetch and nothing else.** It has no
            // transcript to match, so the turns half fell through to its recency fill and
            // told the model to answer from the previous call's turns — unrelated
            // conversation content stapled to the one lookup that asked for a specific row.
            let exactKey = query.trimmingCharacters(in: .whitespacesAndNewlines)
                .range(of: "^m_[0-9]+$", options: .regularExpression) != nil
            let turns: TurnStore.Hits
            if handleMissed || exactKey {
                turns = TurnStore.Hits(matched: [], recent: [], recentIsPreviousCall: false)
            } else if let oneCall {
                turns = TurnStore.Hits(matched: oneCall.turns, recent: [],
                                       recentIsPreviousCall: false)
            } else {
                turns = await Self.matchingTurns(
                    query, in: localContext, userId: owner,
                    conversationId: conversation, scope: scope)
            }
            guard !Task.isCancelled, let self, self.isActive else { return }
            let ms = Date().timeIntervalSince(started) * 1000
            self.localContextTasks[callId] = nil
            // **Nothing found means nothing on screen.** The step is not drawn, not
            // narrated, and not part of the turn the user watches — they never learn a
            // search happened, because from their side nothing did. The model still gets the
            // sentence telling it to go and fetch, which is the only party that needs to
            // know. Turns count towards "found": a widened search that recalled what was
            // said earlier has used the memory even when the cache half was empty, and
            // hiding that step made the one scope worth watching the one that showed
            // nothing.
            //
            // Decided *after* the query rather than before it, and that is what makes this
            // free: the query is ~1 ms against an indexed empty table, so there is no
            // running state worth showing and nothing to undo once it comes back empty.
            // Announcing "searching your memory" and then admitting there was no memory is
            // two frames of a step that should never have appeared.
            self.finishContextTool(
                callId: callId, tool: "search_context",
                output: Self.searchOutput(
                    handleMissed: handleMissed, handle: asked, call: oneCall,
                    result: result, query: query, conversation: conversation,
                    turns: turns, scope: scope),
                ms: ms,
                // `local_empty` distinguishes an unfilled store from a search that fell
                // through to recency — the same distinction `matched` exists to draw.
                // `local_turns` is the third case the scopes made reachable: no cached
                // lookup, but something the user said.
                outcome: result.rows.isEmpty
                    ? (turns.isEmpty ? "local_empty" : "local_turns")
                    : "local_\(result.matched.rawValue)",
                query: query,
                // The scope rides in the detail because it is the one thing a device log
                // cannot otherwise recover: a widened search that found nothing and a narrow
                // search that was never widened read identically without it.
                detail: "\(result.rows.count) row(s) by \(result.matched.rawValue), "
                    + "\(turns.matched.count) matched + \(turns.recent.count) recent "
                    + "turn(s), scope \(scope?.rawValue ?? "unscoped")",
                visible: !(result.rows.isEmpty && turns.isEmpty),
                dial: dial)
        }
    }

    /// `save_context` — the local write, for what no tool result produced.
    ///
    /// Reads through our own tools cache themselves off `response.output_item.done`, so
    /// this is the rarer path, and the store refuses a save that duplicates one of those
    /// automatic rows. That refusal is ported deliberately: told plainly not to save after
    /// a mail read, the model did it anyway on the very next call, which is why the guard
    /// has to be a refusal rather than a sentence in a description.
    func answerContextSave(callId: String, argumentsJSON: String) {
        let toolArguments = ToolArguments(argumentsJSON)
        let request = toolArguments.string("request") ?? ""
        let result = toolArguments.string("result") ?? ""
        let summary = toolArguments.string("summary") ?? ""
        let kind = toolArguments.string("kind") ?? "note"
        RealtimeLog.log("localContext: save \"\(request)\" — writing on device")
        FullDuplexTrace.note("!! save_context \"\(request)\"")
        // Outside the `Task` — see `answerContextSearch`. `@MainActor` queueing is not free.
        let started = Date()
        let conversation = conversationId()
        let owner = contextOwner
        let dial = dialGeneration
        localContextTasks[callId] = Task { [weak self, localContext] in
            let output = await localContext.save(
                request: request, result: result, summary: summary, kind: kind,
                conversationId: conversation,
                userId: owner)
            guard !Task.isCancelled, let self, self.isActive else { return }
            self.localContextTasks[callId] = nil
            self.finishContextTool(
                callId: callId, tool: "save_context", output: output,
                ms: Date().timeIntervalSince(started) * 1000,
                outcome: output.hasPrefix("Cached") ? "local_saved" : "local_refused",
                query: request, detail: output, dial: dial)
        }
    }

    /// `forget_context` — the local delete, and still the only way a row leaves the store.
    func answerContextForget(callId: String, argumentsJSON: String) {
        let key = Self.stringArgument("key", in: argumentsJSON) ?? ""
        RealtimeLog.log("localContext: forget \(key) — deleting on device")
        FullDuplexTrace.note("!! forget_context \(key)")
        // Outside the `Task` — see `answerContextSearch`. `@MainActor` queueing is not free.
        let started = Date()
        let conversation = conversationId()
        let dial = dialGeneration
        localContextTasks[callId] = Task { [weak self, localContext] in
            let output = await localContext.forget(key: key, conversationId: conversation)
            guard !Task.isCancelled, let self, self.isActive else { return }
            self.localContextTasks[callId] = nil
            self.finishContextTool(
                callId: callId, tool: "forget_context", output: output,
                ms: Date().timeIntervalSince(started) * 1000,
                outcome: output.hasPrefix("Forgot") ? "local_forgot" : "local_missing",
                query: key, detail: output, dial: dial)
        }
    }

    /// Turns of this user's conversations that match the query — the device's
    /// `searchConversationTurns`.
    ///
    /// **Out of GRDB, not out of `CommandStore.commands`.** It used to filter that
    /// in-memory array, which had three problems the scopes made unaffordable: the array is
    /// populated by a network fetch, so it is empty on a cold launch where the main screen
    /// has not refreshed; the match was substring-per-term with no ranking, so the newest
    /// weak hit beat the best one; and there was no way to bound a day. `TurnStore` mirrors
    /// every stored turn into the same SQLite file the cache rows live in, so this is now an
    /// FTS5 query on the same pool — and the comment that stood here already named the move:
    /// *"if it ever needs ranking, the turns belong in GRDB beside the context rows."*
    ///
    /// **Widened without restriction, unlike the cache half.** A lookup goes stale; a thing
    /// somebody said does not stop having been said.
    private static func matchingTurns(
        _ query: String,
        in localContext: LocalContextStore,
        userId: String,
        conversationId: String?,
        scope: RecallScope?
    ) async -> TurnStore.Hits {
        await TurnStore(database: localContext.dbPool)
            .search(query, userId: userId, conversationId: conversationId, scope: scope)
    }

    /// The turns half of a search result, appended to the cache half.
    ///
    /// Separated by a heading rather than merged into one list, because the model has to
    /// know which is which: a cached lookup is data that was *read*, and a turn is
    /// something that was *said* — and answering "you told me X" from a mail row, or
    /// quoting a subject line as though the user had said it, are different mistakes.
    ///
    /// **Grouped by call and stamped with a clock time**, which is what the scopes are for:
    /// "in this conversation or an earlier one" is not something the model can repeat back
    /// to somebody, where "your 09:41 call" is.
    private static func turnsSection(
        _ hits: TurnStore.Hits,
        conversationId: String?,
        scope: RecallScope?
    ) -> String {
        guard !hits.isEmpty else { return "" }
        let conversation = conversationId ?? ""
        func lines(_ group: [TurnStore.Turn]) -> String {
            group.map { turn in
                let asked = turn.commandText.replacingOccurrences(of: "\n", with: " ")
                let said = turn.responseText
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(LocalContextStore.headLength)
                let here = turn.conversationId == conversation
                    ? ""
                    : " (an earlier call)"
                return "• \(turn.clock)\(here) — they asked: \(asked)\n  you said: \(said)"
            }
            .joined(separator: "\n")
        }
        let when = scope == .today ? "earlier today" : "earlier"
        // `recentIsPreviousCall` was set by the store and read by nobody, so a fill that came
        // from one identifiable call was described as loose recency — the model could not say
        // *which* conversation it was recounting, which is the whole point of the fill.
        let fill = hits.recentIsPreviousCall
            ? "Your previous call, the one before this one"
            : "The most recent " + when
        var out = ""
        if !hits.matched.isEmpty {
            out += "\n\nSaid \(when), matching what they asked:\n" + lines(hits.matched)
        }
        // **Worded as an offer, never as the answer.** These matched nothing — they are the
        // most recent turns in range, and the model has to know that or it reports the newest
        // thing as though it were what was asked for. Which is also why they are useful: "what
        // did we discuss" has nothing to match on, and the last few turns *are* the answer to
        // it.
        if !hits.recent.isEmpty {
            out += "\n\n\(fill) — this is what they mean when they ask what "
                + "was discussed, so answer from it directly. Never tell them it only "
                + "matched by recency, or that these are the ones you happen to have:\n"
                + lines(hits.recent)
        }
        return out
    }

    /// `list_calls` — today's calls, by name rather than as a side effect of searching.
    ///
    /// **A tool because the count rode on the search result and that was not enough.** The
    /// day list was appended to every `search_context` answer, which works only if the model
    /// decides to search — and asked "how many calls have I had today" it answered from
    /// nothing without calling anything, because a count does not look like a search. A named
    /// tool is what a counting question can hit directly.
    ///
    /// Today only, like everything else here.
    func answerListCalls(callId: String) {
        RealtimeLog.log("localContext: list_calls — answering on device")
        FullDuplexTrace.note("!! list_calls")
        let owner = contextOwner
        let dial = dialGeneration
        let started = Date()
        localContextTasks[callId] = Task { [weak self, localContext] in
            let day = await TurnStore(database: localContext.dbPool).daySummary(userId: owner)
            guard !Task.isCancelled, let self, self.isActive else { return }
            let ms = Date().timeIntervalSince(started) * 1000
            self.localContextTasks[callId] = nil
            let output = Self.daySection(day, currentConversation: self.conversationId() ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.finishContextTool(
                callId: callId, tool: "list_calls",
                output: output.isEmpty
                    ? "No calls recorded today before this one."
                    : output,
                ms: ms,
                outcome: day == nil ? "local_empty" : "local_calls",
                query: "",
                detail: "\(day?.calls.count ?? 0) call(s)",
                dial: dial)
        }
    }

    /// The whole `search_context` answer, assembled in one place.
    ///
    /// Broken out because the expression that built it inline had four optional parts and
    /// stopped compiling in reasonable time — and because the order matters: a handle that
    /// resolved to nothing has to say so *before* anything else, or the model reads whatever
    /// follows as the call it asked for.
    private static func searchOutput(
        handleMissed: Bool,
        handle: String?,
        call: (call: TurnStore.Call, turns: [TurnStore.Turn], truncated: Bool)?,
        result: LocalContextStore.Result,
        query: String,
        conversation: String?,
        turns: TurnStore.Hits,
        scope: RecallScope?
    ) -> String {
        if handleMissed {
            return "No call today started at \(handle ?? "that time"). Either it was not "
                + "today, or two calls started in that minute — call list_calls and use the "
                + "exact start time it prints."
        }
        let header: String = callHeader(call)
        let cache: String = LocalContextStore.formatted(
            result, query: query, conversationId: conversation, hasTurns: !turns.isEmpty)
        let said: String = turnsSection(turns, conversationId: conversation, scope: scope)
        return (header + cache + said).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Which conversation is being read back — its time and what it opened with.
    ///
    /// **Prepended whenever a whole call is fetched by its handle.** Twelve calls in a day
    /// means the turns alone do not say which one they came from, and the user asking to hear
    /// one back needs to be told when it was.
    private static func callHeader(_ fetched: (call: TurnStore.Call, turns: [TurnStore.Turn],
                                              truncated: Bool)?) -> String {
        guard let fetched else { return "" }
        let call = fetched.call
        let topic: String = call.opening.isEmpty
            ? ""
            : ", titled \"" + String(call.opening.prefix(90)) + "\""
        let span: String = call.length.map { ", " + $0 } ?? ""
        let cut: String = fetched.truncated
            ? " These are its first \(fetched.turns.count) of \(call.turns) exchanges, not "
                + "all of it — say so if they ask about the end of it."
            : ""
        return "Your call at " + call.label() + span + topic
            + ". Say when it was when you describe it." + cut + "\n"
    }

    /// The day's calls, with what each one was about.
    ///
    /// **Only `list_calls` renders this.** It used to be appended to every `search_context`
    /// answer, which handed a *call*-scoped lookup every earlier call's opening line — the
    /// boundary the scoped queries above take care to keep, broken by the footer under them.
    /// A count question reaches `list_calls` by name, so the footer bought nothing.
    ///
    /// **One tool call answers "what were they all about", and that is the point.** Handed a
    /// bare list of twelve start times, the model asked what each was about by firing twelve
    /// `search_context` calls — one per handle, in parallel, for a question the list itself
    /// could answer. Each row now carries the ask that opened that call, so the topic of
    /// every conversation today arrives in a single result.
    ///
    /// Ordered oldest first, the way the day happened. Today only.
    private static func daySection(
        _ day: (calls: [TurnStore.Call], turns: Int)?,
        currentConversation: String
    ) -> String {
        guard let day, !day.calls.isEmpty else { return "" }
        // **The live call is counted separately, because it may not be in the table yet.**
        // A turn only becomes a row once it has completed and been stored, so `list_calls`
        // on the first exchange of a call sees only the earlier ones — and the header used to
        // say "including this call", making one earlier call read as a total of one.
        let live: Bool = day.calls.contains { $0.id == currentConversation }
        let total: Int = day.calls.count + (live ? 0 : 1)
        let calls: String = "\(total) call\(total == 1 ? "" : "s")"
        let turns: String = "\(day.turns) exchange\(day.turns == 1 ? "" : "s")"
        let rows: [String] = day.calls.map { call -> String in
            let topic: String = call.opening.isEmpty
                ? "(no title)"
                : "\"" + String(call.opening.prefix(90)) + "\""
            let span: String = call.length.map { " · " + $0 } ?? ""
            return "• " + call.label() + span + " · " + topic
        }
        let list: String = rows.joined(separator: "\n")
        // **The numbers, and an order not to qualify them.** Told these were "the recorded
        // count", the model answered "it's not a full call log, but the recorded count is
        // three" — hedging about its own bookkeeping, which is not what was asked.
        let header: String = "\n\nToday, this call included: " + calls + ", " + turns
            + " stored so far"
            + (live ? "" : " (this call has no completed exchanges yet, so it is counted but "
                + "not listed)") + ".\n"
        let rule: String = "\nEach row is the time it started, how long it ran, and what it "
            + "was about, and the whole day is here. A row with no length is a call whose "
            + "duration the exchanges cannot tell you — do not invent one. **Speak the three most recent unless "
            + "they ask for more** — a dozen read aloud is unlistenable — then say how many "
            + "there are in total and stop. When they do ask for more, or for all of them, "
            + "give every remaining row rather than another three. Say the count and the rows "
            + "plainly, "
            + "no caveat and no explanation of where they came from. **It already tells you "
            + "what each call was about, so never search per call to find out.** Search for "
            + "one only when they ask for more detail about that one, with its start time as "
            + "the query."
        return header + list + rule
    }
}
