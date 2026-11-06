import Foundation
import FactoryKit

/// Owns the active Responses exchange; completed tool chains never accumulate in the next request.
@MainActor
final class LiveClientBrain {
    typealias Request = ([String: Any]) async throws -> [String: Any]
    let request: Request
    let deliver: ([String: Any]) -> Void
    let speak: (String, String?) -> Void
    let failed: (String) -> Void
    private var history: [[String: Any]] = []
    private var context: [String] = []
    var now: () -> Date = Date.init
    var timeZone: () -> TimeZone = { .current }
    private var requestDate: Date?
    private var requestZone: TimeZone?
    private var calendar = LiveCalendarConversation()
    private var replyComposition: LiveReplyComposition?
    private var replyRecoveryTurns = Set<Int>()
    var automaticNarration = true
    var onReplyComposition: (([String: String]) -> Void)?
    var calendarWindow: CalendarRequestWindow? { calendar.window }
    var needsExactCalendarSpeech: Bool { calendar.checkingAvailability(for: latestUser) }
    var onCalendarIntent: (([String: String]) -> Void)?
    private var requestSourceState: String { calendar.sourceState(fallback: state) }

    /// Only calls already accepted by this brain can keep the original scheduling source.
    func calendarSource(for call: LiveSessionAdapter.Call) -> String? {
        guard functionItems[call.id] != nil else { return nil }
        return calendar.source(for: call)
    }

    func replySource(for callID: String) -> String? {
        guard functionItems[callID] != nil, replyComposition?.writeCall == callID else { return nil }
        return replyComposition?.selection
    }

    private func recoverReplyPreflight() {
        guard let composition = replyComposition, let call = composition.writeCall,
              let job = Container.shared.dispatchJobs().preflightReply(call, source: composition.source) else { return }
        replyComposition?.recover(job)
        recordReplyComposition("reply_preflight_recovery")
    }

    private func persistCalendarIntent() {
        guard let intent = calendar.intent else { return }
        let store = Container.shared.dispatchJobs(), owner = Container.shared.backend().userId, profile = ProfileRuntime.snapshot?.profileId
        Task { _ = await store.saveCalendarIntent(intent, ownerID: owner, profileID: profile) }
    }
    private var completedJobs: [(id: UUID, result: String)] = []
    private var jobRevision = 0
    private var input: [[String: Any]] = []
    private var task: Task<Void, Never>?
    private var activeRequest: (requestID: String, responseID: String, delegation: String)?
    private var requestWatchdog: Task<Void, Never>?
    var requestBound: TimeInterval = 10
    var onRequestTransition: ((String, String, String, Int) -> Void)?
    var onAttemptOutcome: ((Int, [String: String]) -> Void)?
    var encodeContext: ([String: Any]) throws -> Data = { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
    var contextByteLimit = 96_000
    var stepLimit = 12
    private var attempt: (id: String, turn: Int)?
    private var attemptFields: [String: String] = [:]
    var onPresentationInvalidated: ((String, String?) -> Void)?
    private var rejectingAssistantPresentation = false
    private var correctedEmptySelection = false
    private var delegation: String?
    private var liveDelegation: String?
    private var generation = UUID()
    private var closed = false
    private var pendingCalls = Set<String>()
    private var unclaimedCalls = Set<String>()
    private var results = Set<String>()
    private var completedTurns = Set<Int>()
    private var currentTurn = 0
    private var latestUser = ""
    private var userInputFinalized = true
    private var latestAssistant = ""
    private var turnHistoryIndex: Int?
    private var state = ""
    private var turnState = ""
    private var scope: String?
    private var presentationOnly = false
    var present: ((String) -> Void)?
    private var pendingPresentation: (id: String, turn: Int, result: String)?
    private var steps = 0
    private var requestTurn = 0
    private var transcriptRevision = 0
    private var scopeRevision = 0
    private var settledTurn: Int?
    private var requestState = ""
    private var scopeChanged = false
    private var questionState = ""
    private var actionRecords: [[String: Any]] = []
    private var retainedResults: [(id: String, text: String)] = []
    private var functionOrigins: [String: (turn: Int, selection: String)] = [:]
    private var functionItems: [String: [String: Any]] = [:]
    private var pendingQuestion = ""
    private struct Lookup {
        let request: String
        let selection: String
        var queries: [String] = []
        var corrections: [Int: String] = [:]
        var searchCoverage: [String: Any]?
        var fallbackArguments: [String: Any]?
        var candidateKeys = Set<String>()
        var inspectedKeys = Set<String>()
        var context: [String: Any] {
            var value: [String: Any] = ["request": request, "heldSelection": selection, "queries": queries,
             "corrections": corrections.keys.sorted().compactMap { corrections[$0] },
             "rule": "Corrections here constrain this lookup, not the unrelated held email. Keep the goal while treating approximate topic words, file types and remembered mailboxes as clues. After an empty restrictive query, search the sender alone within the requested accounts, then inspect plausible candidates and their actual attachment metadata before ruling them out. Use company/context clues if needed. Never describe one empty query as no message anywhere. Partial errors and pagination leave coverage incomplete. Never relax a bulk-action query or an explicit exact constraint. Search results do not change the held feed selection."]
            value["lastSearch"] = searchCoverage
            return value
        }
    }
    private var lookup: Lookup?
    private var priorReplyDestination: DispatchJob.MailOrigin?
    private var investigating = false
    private var sourceInquiry: SelectedEmailInquiry?
    private var sourceQuestion = false
    private var releasedDecisionSources = Set<MailSelection>()
    var holdsFeedDecision: Bool {
        if replyComposition?.holdsDecision == true { return true }
        if calendar.holdsFeedDecision { return true }
        if investigating { return true }
        guard let key = LiveEmailPresentation.Key.selection(state) else { return false }
        let selection = MailSelection(account: key.account, messageID: key.messageId)
        guard !releasedDecisionSources.contains(selection) else { return false }
        return Container.shared.dispatchJobs().decisionDependencies.contains {
            $0.sourceSelection == selection && $0.context?.decisionReleased != true
        }
    }
    var needsSelectedSource: Bool { sourceQuestion && sourceInquiry != nil }
    private var queuedDelegation: (id: String, live: Bool, turn: Int)?
    /// The tool whose own result survives the scope change it causes: that result is the new
    /// scope's feed, and the switch would otherwise end in silence after "Switching to X."
    static let scopeSwitchTool = "switch_profile"
    private var scopeSwitchCalls = Set<String>()
    /// Calls accepted by the adapter use its execution watchdog, including time spent queued.
    /// This bound covers calls that never reached the adapter.
    var toolCallBound: TimeInterval = LiveSessionAdapter.toolCallBound + 5
    private var callWatchdog: Task<Void, Never>?

    init(request: @escaping Request, deliver: @escaping ([String: Any]) -> Void,
         speak: @escaping (String, String?) -> Void, failed: @escaping (String) -> Void) {
        self.request = request
        self.deliver = deliver
        self.speak = speak
        self.failed = failed
    }

    var busy: Bool { task != nil || !pendingCalls.isEmpty }

    func requestWasSent(_ id: String) {
        guard activeRequest?.requestID == id else { return }
        attemptFields["request_sent"] = "true"
    }

    func updateState(_ text: String, scope: String?) {
        let previousSelection = LiveSelectionGrounding.selection(state)
        if self.scope != scope {
            // A pending switch call caused this change: its result still belongs to this
            // delegation, so the response is not cut short. Any other pending result is stale.
            let switching = pendingCalls.filter { functionItems[$0]?["name"] as? String == Self.scopeSwitchTool }
            scopeChanged = self.scope != nil && switching.isEmpty
            scopeSwitchCalls = switching
            self.scope = scope
            scopeRevision += 1
            actionRecords.removeAll()
            retainedResults.removeAll()
            completedJobs.removeAll()
            jobRevision += 1
            functionItems.removeAll()
            functionOrigins.removeAll()
            pendingCalls.removeAll()
            unclaimedCalls.removeAll()
            callWatchdog?.cancel()
            callWatchdog = nil
            input.removeAll()
            latestAssistant = ""
            latestUser = ""
            pendingQuestion = ""
            questionState = ""
            requestState = ""
            finishQueuedAttempt(reason: "scope_changed")
            queuedDelegation = nil
            pendingPresentation = nil
            presentationOnly = false
            history.removeAll()
            context.removeAll()
            lookup = nil
            priorReplyDestination = nil
            calendar.scopeChanged()
            replyComposition = nil
            replyRecoveryTurns.removeAll()
            investigating = false
            releasedDecisionSources.removeAll()
            sourceInquiry = nil
            sourceQuestion = false
            state = ""
            turnState = ""
            turnHistoryIndex = nil
        }
        state = LiveCompactContext.bounded(text, bytes: 24_000)
        if let object = try? JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any],
           object["done"] as? Bool == false, let item = object["item"] as? [String: Any] {
            let origin = DispatchJob.MailOrigin.from(item)
            priorReplyDestination = origin?.threadID.isEmpty == false ? origin : nil
        }
        let selected = LiveSelectionGrounding.selection(state)
        if selected != previousSelection {
            if !calendar.focused { sourceInquiry = nil }
            lookup = nil
            investigating = false
            calendar.selectionChanged()
            invalidatePresentation(reason: "selection_changed")
            rejectingAssistantPresentation = false
            if selected.identity != nil { correctedEmptySelection = false }
        }
    }

    func user(_ text: String, turn: Int, finalized: Bool = true) {
        userInputFinalized = finalized
        if finalized {
            recoverReplyPreflight()
            if let replyComposition, let call = replyComposition.writeCall,
               LiveReplyComposition.requestsReply(text),
               Container.shared.dispatchJobs().resolvedMailCall(call, source: replyComposition.source) {
                self.replyComposition = nil
            }
            if LiveReplyComposition.cancels(text) { replyComposition = nil }
            else if replyComposition?.active == true {
                replyComposition?.user(text, turn: turn, selection: state)
            } else if LiveReplyComposition.requestsReply(text), let source = DispatchJob.MailOrigin.captured(in: state) {
                if replyComposition?.turn == turn { replyComposition?.user(text, turn: turn, selection: state) }
                else { replyComposition = .init(source: source, selection: state, request: text, turn: turn) }
            }
            recordReplyComposition("reply_input")
        }
        calendar.user(text, selection: state, proposal: latestAssistant, newTurn: turn != currentTurn,
                      jobs: Container.shared.dispatchJobs(), finalized: finalized)
        var intentFields = calendar.intentDiagnostics
        intentFields["transition"] = "calendar_intent_input"
        intentFields["input_finalized"] = String(finalized)
        intentFields["reason"] = CalendarConversationIntent.emailOnly(text) ? "email_composition_only" :
            CalendarConversationIntent.accepts(text) ? (finalized ? "explicit_reply_and_invitation" : "provisional_request") : "no_combined_request"
        onCalendarIntent?(intentFields)
        if finalized { persistCalendarIntent() }
        sourceQuestion = calendar.focused || SelectedEmailInquiry.requiresSource(text)
        if replyComposition?.active == true, replyComposition?.targetConfirmed == true,
           LiveReplyComposition.confirmsTarget(text) || LiveReplyComposition.requestsReply(text) { sourceQuestion = false }
        if sourceQuestion {
            sourceInquiry = SelectedEmailInquiry(state: requestSourceState, previous: sourceInquiry,
                headersOnly: MailHeadersOnly.withholdsBodies || ProfileRuntime.snapshot?.mailHeadersOnly == true)
        }
        if LiveFastAction.parse(text) != nil || Self.requestsDecision(text) || DispatchScope.explicitlyContinuesFeed(text) {
            investigating = false
            if let key = LiveEmailPresentation.Key.selection(state) {
                let selection = MailSelection(account: key.account, messageID: key.messageId)
                releasedDecisionSources.insert(selection)
                let owner = Container.shared.backend().userId, profile = ProfileRuntime.snapshot?.profileId
                let jobs = Container.shared.dispatchJobs()
                Task {
                    guard owner == Container.shared.backend().userId, profile == ProfileRuntime.snapshot?.profileId else { return }
                    await jobs.releaseDecisionHold(selection)
                }
            }
        } else if LiveSelectionGrounding.selection(state).identity != nil,
                  LiveRequestRecovery.isQuestion(text) || LiveRequestRecovery.isFeedback(text)
                    || DispatchScope.refersToSelectedEmail(text) || DispatchScope.pausesDecision(text) {
            investigating = true
            pendingQuestion = ""
            questionState = ""
        }
        if LiveFastAction.parse(text) != nil || ["stop searching", "cancel the search", "cancel search", "stop looking"]
            .contains(FullDuplexVoiceClient.normalize(text)) { lookup = nil }
        if turn != currentTurn {
            requestDate = now()
            requestZone = timeZone()
        }
        calendar.resolveWindow(for: text, newTurn: turn != currentTurn,
                               reference: requestDate ?? now(), zone: requestZone ?? timeZone())
        if LiveRequestRecovery.isFeedback(text) {
            invalidatePresentation(reason: "feedback")
        }
        scopeChanged = false
        transcriptRevision += 1
        settledTurn = nil
        if turn != currentTurn {
            if !latestAssistant.isEmpty {
                history.append(["type": "message", "role": "assistant", "content": latestAssistant])
            }
            latestAssistant = ""
            rejectingAssistantPresentation = false
            currentTurn = turn
            turnState = requestSourceState
            history.append(["type": "message", "role": "user", "content": text])
            while history.count > 24 { history.removeFirst() }
            turnHistoryIndex = history.count - 1
        } else if let index = turnHistoryIndex, history.indices.contains(index) {
            history[index]["content"] = text
        }
        latestUser = text
        if task != nil, requestTurn != turn { supersedeRequest() }
    }

    func finalizeUser(turn: Int) {
        guard turn == currentTurn, !latestUser.isEmpty, !userInputFinalized else { return }
        user(latestUser, turn: turn, finalized: true)
    }

    func assistant(_ delta: String) {
        guard !rejectingAssistantPresentation else { return }
        latestAssistant += delta
        if LiveSelectionGrounding.unsupportedIntroduction(latestAssistant, state: state) {
            rejectingAssistantPresentation = true
            invalidatePresentation(reason: "unsupported_spoken_introduction")
            return
        }
        if latestAssistant.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") {
            replyComposition?.question(latestAssistant)
            guard !holdsFeedDecision || Self.withoutDispositionQuestion(latestAssistant) == latestAssistant else { return }
            pendingQuestion = latestAssistant
            questionState = LiveCompactContext.selectionReference(state)
        }
    }

    private func recordReplyComposition(_ transition: String) {
        guard let replyComposition else { return }
        onReplyComposition?(["transition": transition, "composition_id": replyComposition.id.uuidString,
            "composition_revision": String(replyComposition.revision), "target_confirmed": String(replyComposition.targetConfirmed),
            "reason": replyComposition.writeCall == nil ? "preserved_request" : "write_already_attempted"])
    }

    private func invalidatePresentation(reason: String) {
        latestAssistant = ""
        pendingQuestion = ""
        questionState = ""
        let priorUserIndex = turnHistoryIndex
        if let priorUserIndex {
            turnHistoryIndex = history.prefix(priorUserIndex).filter { $0["role"] as? String != "assistant" }.count
        }
        history.removeAll { $0["role"] as? String == "assistant" }
        if LiveSelectionGrounding.selection(state).isEmpty {
            context.removeAll()
            observe("No current email is selected. Earlier spoken descriptions and questions are not mailbox evidence. Never resume them. Continue only from an application-selected item.")
        }
        onPresentationInvalidated?(reason, LiveSelectionGrounding.selection(state).identity)
    }

    private func groundedReply(_ text: String) -> String {
        let text = holdsFeedDecision ? Self.withoutDispositionQuestion(text) : text
        if let coverage = lookup?.searchCoverage, Self.negativeSearchClaim(text) {
            if coverage["complete"] as? Bool == false {
                return "The search was incomplete, so I can't rule out a match in the remaining mail."
            }
            if coverage["hits"] as? Int == 0 {
                return "Those searches didn't return a matching email. That doesn't establish that it is absent; another sender name or company clue would help."
            }
            if let lookup, !lookup.candidateKeys.subtracting(lookup.inspectedKeys).isEmpty {
                return "I found possible matches, but haven't inspected all of them yet, so I can't rule out the document."
            }
        }
        guard LiveSelectionGrounding.unsupportedIntroduction(text, state: state) else {
            return text.isEmpty ? "I'm keeping this email selected." : text
        }
        invalidatePresentation(reason: "unsupported_model_introduction")
        defer { correctedEmptySelection = true }
        return correctedEmptySelection ? LiveSelectionGrounding.noSelection : LiveSelectionGrounding.correction
    }

    private static func requestsDecision(_ text: String) -> Bool {
        text.range(of: #"\b(?:what should (?:i|we) do|help (?:me|us) (?:decide|respond)|what do you (?:recommend|suggest) (?:i|we) do|what are my options|should (?:i|we) (?:reply|archive|delete))\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func withoutDispositionQuestion(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?:^|(?<=[.!?])\s+)(?:what (?:would|do) you (?:like|want) (?:me )?to do\b|(?:would|do) you (?:like|want)(?: me)? to (?:reply|respond|archive|delete|move on|continue|draft)\b|(?:should|shall) (?:i|we) (?:reply|respond|archive|delete|move on|continue|draft)\b)[^?\n]{0,180}\?\s*$"#,
            with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func correctEmailInterpretation() {
        transcriptRevision += 1
        turnState = state
        context.removeAll()
        invalidatePresentation(reason: "factual_correction")
    }

    func correctLookup(_ text: String) -> Bool {
        guard lookup != nil, LiveEmailPreparationCache.isFactualCorrection(text) || LiveRequestRecovery.isCorrection(text),
              text.range(of: #"\b(?:this|current|selected|visible) (?:email|message)|\bon (?:the )?screen\b"#,
                  options: [.regularExpression, .caseInsensitive]) == nil else { return false }
        lookup?.corrections[currentTurn] = LiveCompactContext.bounded(text, bytes: 2_000)
        if let oldest = lookup?.corrections.keys.sorted().first, (lookup?.corrections.count ?? 0) > 8 {
            lookup?.corrections.removeValue(forKey: oldest)
        }
        transcriptRevision += 1
        pendingQuestion = ""
        questionState = ""
        return true
    }

    private func recordLookup(_ call: [String: Any]) {
        guard call["name"] as? String == GmailReadTools.search,
              let raw = call["arguments"] as? String, let query = ToolArguments(raw).string("query"), !query.isEmpty else { return }
        if lookup == nil {
            lookup = Lookup(request: LiveCompactContext.bounded(latestUser, bytes: 2_000),
                selection: LiveCompactContext.selectionReference(state))
        }
        investigating = true
        pendingQuestion = ""
        questionState = ""
        let queries = (lookup?.queries ?? []) + [LiveCompactContext.bounded(query, bytes: 1_000)]
        lookup?.queries = Array(queries.suffix(8))
        lookup?.fallbackArguments = nil
    }

    nonisolated static func negativeSearchClaim(_ text: String) -> Bool {
        text.replacingOccurrences(of: "’", with: "'").range(of: #"\b(?:could(?:n't| not) find|can(?:'t|not) find|did(?:n't| not) find|no (?:such )?(?:emails?|messages?|documents?|decks?|matches?)|does(?:n't| not) exist|nothing (?:from|anywhere|in))\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    nonisolated static func relaxedSenderQuery(_ query: String, request: String) -> String? {
        guard request.range(of: #"\b(?:find|look for|search for|locate)\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
              request.range(of: #"\b(?:only|exact|exactly|must|archive|delete|trash|label|unsubscribe|forward|send)\b"#,
                  options: [.regularExpression, .caseInsensitive]) == nil,
              !request.contains("\""), !query.contains("{"), !query.contains("}"),
              query.range(of: #"\bOR\b|(?:^|\s)-"#, options: .regularExpression) == nil,
              let regex = try? NSRegularExpression(pattern: #"(?:^|\s)(from:(?:\([^)]{1,200}\)|"[^"]{1,200}"|[^\s]+))"#, options: .caseInsensitive) else { return nil }
        let matches = regex.matches(in: query, range: NSRange(query.startIndex..., in: query))
        guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: query) else { return nil }
        let sender = String(query[range])
        return sender.caseInsensitiveCompare(query.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame ? nil : sender
    }

    private func recordSearchCoverage(_ call: [String: Any], output: String) {
        if call["name"] as? String == GmailReadTools.getMessage,
           let rows = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]] {
            for row in rows {
                if let account = row["account"] as? String, let message = row["result"] as? [String: Any],
                   let id = message["id"] as? String, message["body"] as? String != nil {
                    lookup?.inspectedKeys.insert(account.lowercased() + ":" + id)
                }
            }
        }
        guard call["name"] as? String == GmailReadTools.search, var lookup,
              let raw = call["arguments"] as? String,
              let args = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let query = args["query"] as? String else { return }
        guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let accounts = object["accounts"] as? [[String: Any]], !accounts.isEmpty else {
            lookup.searchCoverage = ["complete": false, "query": query]
            self.lookup = lookup
            return
        }
        let hits = accounts.reduce(0) { $0 + (($1["result"] as? [[String: Any]])?.count ?? 0) }
        let failed = accounts.filter { $0["error"] != nil || $0["result"] as? [[String: Any]] == nil }.count
        let complete = failed == 0 && object["more"] as? Bool == false
        for group in accounts {
            for hit in group["result"] as? [[String: Any]] ?? [] {
                if let account = hit["account"] as? String, let id = hit["id"] as? String {
                    lookup.candidateKeys.insert(account.lowercased() + ":" + id)
                }
            }
        }
        lookup.searchCoverage = ["query": query, "hits": hits, "complete": complete, "failedAccounts": failed,
                                 "accounts": accounts.compactMap { $0["account"] as? String }]
        if hits == 0, complete, lookup.queries.count <= 3,
           let sender = Self.relaxedSenderQuery(query, request: lookup.request + " " + lookup.corrections.keys.sorted().compactMap { lookup.corrections[$0] }.joined(separator: " ")),
           !lookup.queries.contains(where: { $0.caseInsensitiveCompare(sender) == .orderedSame }) {
            var fallback = args
            fallback["query"] = sender
            fallback.removeValue(forKey: "before")
            fallback["max_results"] = 10
            lookup.fallbackArguments = fallback
        }
        self.lookup = lookup
    }

    func jobCompleted(id: UUID, result: String) {
        let compact = LiveCompactContext.text(result, includeEmailContent: false)
        let result = String(decoding: compact.utf8.prefix(2048), as: UTF8.self)
            + (compact.utf8.count > 2048 ? " [Result shortened; consult the returned result before describing details.]" : "")
        guard !completedJobs.contains(where: { $0.id == id && $0.result == result }) else { return }
        completedJobs.removeAll { $0.id == id }
        completedJobs.append((id, result))
        if completedJobs.count > 12 { completedJobs.removeFirst() }
        jobRevision += 1
    }

    func observe(_ text: String) {
        let compact = LiveCompactContext.text(text, includeEmailContent: false)
        guard context.last != compact else { return }
        context.append(compact)
        // Current selection and the latest question are retained separately from these presentation hints.
        while context.count > 6 { context.removeFirst() }
    }

    func item(_ item: [String: Any]) {
        guard !closed else { return }
        var item = item
        if let id = item["call_id"] as? String, let output = item["output"] as? String,
           pendingCalls.contains(id), sourceInquiry?.accept(callID: id, output: output) == true {
            item["output"] = sourceInquiry?.failure ?? "Complete source retained in selectedEmailEvidence for this selection."
        }
        if item["type"] as? String == "function_call_output", let output = item["output"] as? String,
           let id = item["call_id"] as? String, pendingCalls.contains(id) || scopeSwitchCalls.contains(id) {
            if let call = functionItems[id] { recordSearchCoverage(call, output: output) }
            if functionItems[id]?["name"] as? String == CalendarTools.list {
                calendar.recordRead(id: id, arguments: functionItems[id]?["arguments"] as? String, output: output,
                                    accounts: CalendarTools.accounts(), now: now(), zone: timeZone())
                if calendar.focused { persistCalendarIntent() }
            }
            attemptFields["tool_result_bytes"] = String(max(Int(attemptFields["tool_result_bytes"] ?? "0") ?? 0, output.utf8.count))
        }
        if let text = item["content"] as? String { item["content"] = LiveCompactContext.text(text) }
        if let output = item["output"] as? String, let id = item["call_id"] as? String,
           pendingCalls.contains(id) || scopeSwitchCalls.contains(id), !results.contains(id) {
            if functionItems[id]?["name"] as? String != "read_tool_result",
               LiveOpenAI.bytes(output) > 24_000 {
                retainedResults.removeAll { $0.id == id }
                retainedResults.append((id, output))
                while retainedResults.count > 12 || retainedResults.reduce(0, { $0 + $1.text.utf8.count }) > 8_000_000 {
                    retainedResults.removeFirst()
                }
                item["output"] = resultPage(id: id, offset: 0)
            } else { item["output"] = LiveCompactContext.text(output) }
        }
        if item["type"] as? String == "function_call_output", let id = item["call_id"] as? String {
            if scopeSwitchCalls.remove(id) != nil {
                guard results.insert(id).inserted else { return }
                // Its function_call item left with the old scope's input, so the result rides
                // as a message the next step can still present.
                let output = item["output"] as? String ?? "No result"
                actionRecords.append(["call": ["type": "function_call", "name": Self.scopeSwitchTool, "call_id": id],
                                      "result": LiveCompactContext.text(output, includeEmailContent: false)])
                input.append(["type": "message", "role": "user", "content":
                    "The \(Self.scopeSwitchTool) call completed; this is its result. Present it as the switch's own outcome and continue from it:\n" + output])
                return
            }
            guard pendingCalls.contains(id), results.insert(id).inserted else { return }
            pendingCalls.remove(id)
            acceptToolCall(id)
        }
        if item["type"] as? String == "function_call_output", let id = item["call_id"] as? String,
           let call = functionItems[id] {
            if LiveSelectionGrounding.selection(state).isEmpty,
               let name = call["name"] as? String,
               ["search_context", "gmail_search_messages", "search_messages"].contains(name),
               LiveSelectionGrounding.emptySearch(item["output"] as? String ?? "") {
                invalidatePresentation(reason: "negative_verification")
            }
            var record = Self.actionRecord(call: call, output: item["output"] as? String ?? "No result")
            if let origin = functionOrigins.removeValue(forKey: id) {
                record["origin_turn"] = origin.turn
                record["origin_selection"] = LiveCompactContext.selectionReference(origin.selection)
            }
            actionRecords.append(record)
            if calendar.intent != nil {
                calendar.reconcile(jobs: Container.shared.dispatchJobs())
                persistCalendarIntent()
            }
            recoverReplyPreflight()
            functionItems.removeValue(forKey: id)
            while actionRecords.count > 12 { actionRecords.removeFirst() }
        }
        if item["type"] as? String == "message", ["system", "developer"].contains(item["role"] as? String ?? ""),
           let text = item["content"] as? String {
            observe(text)
        } else { input.append(item) }
    }

    /// Keep command definitions in the active exchange, not a second copy in every later turn.
    private static func actionRecord(call: [String: Any], output: String) -> [String: Any] {
        var call = call
        var result = LiveCompactContext.bounded(output, bytes: 2_000, includeEmailContent: false)
        if call["name"] as? String == "commands",
           let raw = call["arguments"] as? String,
           let arguments = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] {
            let action = arguments["action"] as? String ?? "run"
            if action == "save" {
                let identity = arguments.filter { ["action", "keyword"].contains($0.key) }
                if let data = try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]) {
                    call["arguments"] = String(decoding: data, as: UTF8.self)
                }
            } else if action == "run" || action == "list" {
                result = "Command lookup returned; this was not execution of its steps. "
                    + "Individual action records report what ran. Fetch the command again for a new run."
            }
        }
        if let arguments = call["arguments"] as? String {
            call["arguments"] = LiveCompactContext.bounded(arguments, bytes: 2_000, includeEmailContent: false)
        }
        return ["call": call, "result": result]
    }

    private func resultPage(id: String, offset: Int) -> String {
        guard let source = retainedResults.first(where: { $0.id == id })?.text else {
            return "Retained result is unavailable. Retrieve the source with a read-only tool if needed; never repeat a write to recover its receipt."
        }
        let bytes = Array(source.utf8)
        guard offset >= 0, offset <= bytes.count,
              offset == bytes.count || bytes[offset] & 0xC0 != 0x80 else {
            return "Invalid result offset. Start at 0 or use the previous next_offset."
        }
        let remaining = String(decoding: bytes.dropFirst(offset), as: UTF8.self)
        var chunk = FeedEmailContent.prefix(remaining, bytes: 12_000)
        while LiveOpenAI.bytes(chunk) > 16_000 { chunk = FeedEmailContent.prefix(chunk, bytes: chunk.utf8.count / 2) }
        let next = offset + chunk.utf8.count
        let value: [String: Any] = ["source_call_id": id, "total_bytes": bytes.count, "offset": offset,
            "next_offset": next, "complete": next == bytes.count, "text": chunk,
            "contentAccess": "This is a page of an already returned tool result, not a retrieval failure. Use read_tool_result with source_call_id and next_offset for more. Do not repeat the original action. Do not claim a full read from a partial page."]
        do { return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
        catch { return "The saved result could not be encoded for presentation. The original operation has not been repeated." }
    }

    func begin(_ id: String, live: Bool, turn: Int) {
        guard !closed else { return }
        guard !completedTurns.contains(turn), queuedDelegation?.id != id, delegation != id else { return }
        finishQueuedAttempt(reason: "superseded")
        queuedDelegation = (id, live, turn)
    }

    private func finishQueuedAttempt(reason: String) {
        guard let queued = queuedDelegation else { return }
        onAttemptOutcome?(queued.turn, ["delegation_id": queued.id, "request_sent": "false", "stage": "queued",
            "reason": reason, "outcome": "stopped", "recovery": "none", "byte_limit": String(contextByteLimit)])
    }

    func settle(turn: Int) {
        settledTurn = turn
        startSettledDelegation()
    }

    private func startSettledDelegation() {
        guard let turn = settledTurn, turn == currentTurn, !latestUser.isEmpty else { return }
        guard !LiveRequestRecovery.isBackchannel(latestUser), !LiveRequestRecovery.incompleteAction(latestUser) else {
            finishQueuedAttempt(reason: "non_request"); queuedDelegation = nil; return
        }
        guard let queued = queuedDelegation, (queued.turn == turn || queued.turn == 0), !busy else { return }
        guard !completedTurns.contains(turn) else { queuedDelegation = nil; return }
        queuedDelegation = nil
        delegation = queued.id
        liveDelegation = queued.live ? queued.id : nil
        steps = 0
        presentationOnly = false
        requestTurn = turn
        requestState = turnState
        startAttempt()
        input.append(["type": "message", "role": "user", "content": latestUser])
        run()
    }

    func continueResponse(delegation id: String?) {
        guard !closed else { return }
        guard !busy else { return }
        if delegation != nil, requestTurn != currentTurn {
            endAttempt(reason: "superseded", stage: "continuation", recovery: "new_turn")
            input.removeAll()
            delegation = nil
            liveDelegation = nil
            presentationOnly = false
            startPresentationIfReady()
            startSettledDelegation()
            return
        }
        if delegation == nil {
            delegation = id ?? "application-" + UUID().uuidString
            requestTurn = currentTurn
            requestState = turnState
            steps = 0
            startAttempt()
        }
        run()
    }

    func recordFastResult(_ output: String, turn: Int) {
        completedTurns.insert(turn)
        observe("Application already handled user turn \(turn). Verified result: " + output)
        if queuedDelegation?.turn == turn { finishQueuedAttempt(reason: "locally_resolved"); queuedDelegation = nil }
        if task != nil, requestTurn == turn, !presentationOnly { supersedeRequest() }
    }

    func presentResult(_ output: String, delegation: String, turn: Int) {
        pendingPresentation = (delegation, turn, LiveCompactContext.text(output))
        startPresentationIfReady()
    }

    func cancelPresentation(delegations: Set<String>) {
        if let pending = pendingPresentation, delegations.contains(pending.id) { pendingPresentation = nil }
        guard let delegation, delegations.contains(delegation) else { return }
        endAttempt(reason: "cancelled", stage: "result_presentation", recovery: "retain_completed_action")
        cancelRequest()
        pendingCalls.removeAll()
        unclaimedCalls.removeAll()
        functionItems.removeAll()
        functionOrigins.removeAll()
        input.removeAll()
        self.delegation = nil
        liveDelegation = nil
        presentationOnly = false
    }

    private func startPresentationIfReady() {
        guard !busy, let pending = pendingPresentation else { return }
        pendingPresentation = nil
        guard pending.turn == currentTurn else { return }
        input = [["type": "message", "role": "user", "content":
            "Present this verified application result and its current queue item. The action already ran. "
            + "Only retrieve email content needed for the presentation; never write or advance again.\n" + pending.result]]
        delegation = pending.id
        liveDelegation = nil
        presentationOnly = true
        requestTurn = pending.turn
        requestState = state
        steps = 0
        startAttempt()
        run()
    }

    private func startAttempt() {
        endAttempt(reason: "superseded", stage: "handoff", recovery: "new_attempt")
        attempt = (delegation ?? "application-" + UUID().uuidString, requestTurn)
        attemptFields = ["request_sent": "false", "byte_limit": String(contextByteLimit), "tool_result_bytes": "0"]
    }

    private func endAttempt(reason: String, stage: String, recovery: String) {
        guard let attempt else { return }
        self.attempt = nil
        var fields = attemptFields
        fields["delegation_id"] = attempt.id
        fields["reason"] = reason
        fields["stage"] = stage
        fields["recovery"] = recovery
        fields["outcome"] = reason == "completed" ? "completed" : "stopped"
        onAttemptOutcome?(attempt.turn, fields)
    }

    private func run() {
        guard !closed, task == nil, pendingCalls.isEmpty, let delegation else { return }
        if scopeChanged {
            endAttempt(reason: "scope_changed", stage: "continuation", recovery: "select_current_profile")
            let responseID = "jo-" + UUID().uuidString
            deliver(["type": "response.event", "delegation_id": delegation,
                     "event": ["type": "response.created", "response": ["id": responseID]]])
            self.delegation = nil
            liveDelegation = nil
            finish(responseID: responseID, delegation: delegation, response: [:])
            return
        }
        steps += 1
        guard steps <= stepLimit else { fail("This task reached its step limit. No further actions were attempted.", reason: "step_limit", stage: "continuation"); return }
        let requestGeneration = generation
        let requestTurn = self.requestTurn
        let requestRevision = transcriptRevision
        let requestScope = scopeRevision
        let requestPresentation = presentationOnly
        let requestJobs = jobRevision
        let sourceState = requestSourceState
        let requestSelection = LiveSelectionGrounding.selection(sourceState)
        let responseID = "jo-" + UUID().uuidString
        let readingSource = sourceQuestion && !requestPresentation
        let comparingSources = readingSource && SelectedEmailInquiry.requestsComparison(latestUser)
        if readingSource, MailBodyCache.withheld {
            sourceInquiry?.failure = "I only have header access for this email, so I can't verify what its body says."
        }
        if readingSource, LiveSelectionGrounding.selection(requestState) != requestSelection {
            fail("The selected email changed while I was checking it. Ask about the email now in focus.", reason: "source_selection_changed", stage: "pre_request")
            return
        }
        if readingSource, let failure = sourceInquiry?.failure {
            fail(failure, reason: "selected_source_unavailable", stage: "pre_request")
            return
        }
        let sourceCall = readingSource ? sourceInquiry?.nextCall() : nil
        var mandatory = ["current_turn": currentTurn, "selectionStatus": LiveSelectionGrounding.selection(state).isEmpty ? "none" : "application_state",
                         "selectionRule": "Only currentSelection establishes the current email. Speech, prior questions, history and background findings cannot create one. Select a returned result explicitly before acting on it.",
                         "requestSelection": requestState == state ? "Same as currentSelection" : LiveCompactContext.selectionReference(requestState), "currentSelection": state,
                         "latestAssistant": LiveCompactContext.bounded(latestAssistant, bytes: 2_000), "pendingQuestion": LiveCompactContext.bounded(pendingQuestion, bytes: 2_000), "questionSelection": questionState == state ? "Same as currentSelection" : questionState,
                         "recordedActions": Array(actionRecords.suffix(12)), "completedJobs": completedJobs.map {
                             ["job_id": $0.id.uuidString, "state": "finished", "result": $0.result]
                         }, "applicationUpdates": context] as [String: Any]
        mandatory["selectedTask"] = Container.shared.applicationTasks().selectedContext
        if !automaticNarration {
            mandatory["narrationMode"] = "At computer: answer only the user's current request. Keep successful spoken-action confirmations brief. Do not introduce or summarize the next email, recap the feed, or ask for its disposition. Explicit read-aloud and factual questions still receive full answers. Background reporting rules are unchanged."
        }
        mandatory.merge(calendar.context(selection: state, user: latestUser, now: now())) { _, new in new }
        attemptFields.merge(calendar.intentDiagnostics) { _, new in new }
        mandatory["emailDependencies"] = Container.shared.dispatchJobs().decisionDependencies.prefix(4).map { job in
            ["job_id": job.id.uuidString, "request": job.task, "state": job.state,
             "account": job.origin?.account ?? "", "message_id": job.origin?.messageID ?? "",
             "result": LiveCompactContext.bounded(job.result ?? "No confirmed result yet.", bytes: 4_000),
             "rule": "A source-related dependency, not approval for a later write. For an explicit follow-up such as add that email there, pass source_task_id to dispatch to retain this original email and verified destination even if selection changed. If the reference is ambiguous, ask which task. Do not substitute the new selected email or invent a destination."]
        }
        mandatory["activeLookup"] = lookup?.context
        if replyComposition?.active == true { mandatory["pendingReply"] = replyComposition?.context }
        if readingSource, sourceInquiry?.complete == true {
            mandatory["selectedEmailEvidence"] = sourceInquiry?.context
            if calendar.focused, var evidence = sourceInquiry?.context {
                evidence["rule"] = "Original email evidence for the accepted calendar request. Prefer the latest rescheduling proposal over cancelled dates in subject/quoted history. " + SelectedEmailInquiry.attributionRule
                mandatory["selectedEmailEvidence"] = evidence
            }
            mandatory["currentSelection"] = LiveCompactContext.selectionReference(sourceState)
            if let source = try? JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any],
               let item = source["item"] as? [String: Any], let correction = item["userCorrection"] {
                mandatory["selectedEmailUserCorrection"] = correction
                mandatory["interpretationRule"] = source["interpretationRule"]
            }
            // Earlier summaries, task results and the model's own claims are not evidence for
            // this source. Keep them out of an ordinary recap, rather than merely warning it.
            if !comparingSources && !calendar.focused {
                for key in ["latestAssistant", "pendingQuestion", "questionSelection", "recordedActions", "completedJobs",
                            "applicationUpdates", "selectedTask", "emailDependencies", "activeLookup"] {
                    mandatory.removeValue(forKey: key)
                }
                mandatory["pendingQuestion"] = ""
            }
            mandatory["recapAttribution"] = comparingSources
                ? "This is an explicit comparison. selectedEmailEvidence belongs only to the current account/message IDs. Earlier history is an unverified reference, not source evidence: retrieve each other email before comparing, label every claim with its source, and do not merge their authors or proposals."
                : "This answer describes only selectedEmailEvidence. Do not use prior dialogue or another email as evidence. " + SelectedEmailInquiry.attributionRule
            attemptFields["reason"] = comparingSources ? "selected_source_comparison" : "selected_source_recap"
            onRequestTransition?(comparingSources ? "selected_source_comparison" : "selected_source_recap", "source-evidence", delegation, requestTurn)
        }
        if let destination = priorReplyDestination, !readingSource {
            mandatory["priorReplyDestination"] = ["account": destination.account, "thread_id": destination.threadID,
                "reply_message_id": destination.messageID, "from": destination.sender, "subject": destination.subject,
                "rule": "This is the last unambiguous email discussed in this profile, retained when the feed stops. It is a historical reply destination, not the current feed selection and not permission to act. Resolve explicit references such as the email we were discussing or the one back in the feed from these exact IDs. Search results and source attachments do not replace this destination. A reply uses its thread/account/message; derive recipients from that thread rather than asking which same-name contact. Never substitute a forward or new message. Honor an explicit different destination; ask once if the user's reference is still ambiguous. General this/next/archive instructions use currentSelection only."]
        }
        if holdsFeedDecision {
            mandatory["feedDecision"] = "Held while the user gathers information. Answer only the current question or lookup. Do not repeat the email introduction or ask what to do with it. A pause, okay, correction or arriving result does not request another disposition question. Ask only a concrete clarification required for this request; wait for an explicit action, continuation or request for decision help."
        }
        mandatory["clock"] = LiveSessionAdapter.clockLine(now: now(), zone: timeZone())
        mandatory["requestClock"] = LiveSessionAdapter.clockLine(now: requestDate ?? now(), zone: requestZone ?? timeZone())
        mandatory.merge(calendar.windowContext(now: now())) { _, new in new }
        attemptFields.merge(calendar.windowDiagnostics) { _, new in new }
        var optionalUpdates = context
        while !optionalUpdates.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: mandatory), data.count > 64_000 {
            optionalUpdates.removeFirst()
            mandatory["applicationUpdates"] = optionalUpdates
        }
        if LiveOpenAI.bytes(mandatory) > 80_000 {
            mandatory["currentSelection"] = LiveCompactContext.bounded(state, bytes: 12_000)
            mandatory["completedJobs"] = completedJobs.suffix(4).map {
                ["job_id": $0.id.uuidString, "state": "finished", "result": LiveCompactContext.bounded($0.result, bytes: 800)]
            }
            mandatory["recordedActions"] = actionRecords.suffix(12).map { record in
                var record = record
                for key in ["result", "origin_selection"] {
                    if let text = record[key] as? String { record[key] = LiveCompactContext.bounded(text, bytes: 1_000, includeEmailContent: false) }
                }
                return record
            }
        }
        for (key, value) in mandatory { attemptFields[key + "_bytes"] = String(LiveOpenAI.bytes(value)) }
        let stateData: Data
        do { stateData = try encodeContext(mandatory) }
        catch {
            fail("Jo couldn't prepare this answer. Your selected email and previous actions are unchanged.", reason: "context_encoding_failed", stage: "pre_request")
            return
        }
        attemptFields["total_bytes"] = String(stateData.count)
        guard stateData.count <= contextByteLimit else {
            let sizes = mandatory.keys.sorted().map { "\($0)=\(LiveOpenAI.bytes(mandatory[$0]!))" }.joined(separator: " ")
            RealtimeLog.log("liveBrain: context limit exceeded bytes by field: " + sizes)
            context.removeAll()
            latestAssistant = ""
            pendingQuestion = ""
            questionState = ""
            fail("Jo couldn't fit this task's context into an answer. Your mailbox isn't full. The selected email and previous actions are unchanged; select a single message or skip this item.", reason: "context_limit", stage: "pre_request"); return
        }
        let prior = readingSource && !comparingSources && !calendar.focused ? [] : history.enumerated().filter { $0.offset != turnHistoryIndex }.map(\.element)
        let requestID = UUID().uuidString
        let body: [String: Any] = ["requestId": requestID, "delegationId": delegation, "turnIndex": currentTurn, "turnID": String(currentTurn),
            "context": String(decoding: stateData, as: UTF8.self), "history": Array(prior.suffix(12)), "input": input,
            "presentationOnly": presentationOnly]
        deliver(["type": "response.event", "delegation_id": delegation,
                 "event": ["type": "response.created", "response": ["id": responseID]]])
        activeRequest = (requestID, responseID, delegation)
        attemptFields["request_id"] = requestID
        let bound = requestBound
        requestWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(bound))
            guard let self, !Task.isCancelled, generation == requestGeneration else { return }
            expireRequest()
        }
        task = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                var response: [String: Any]
                if let sourceCall { response = ["output": [sourceCall]] }
                else { response = try await request(body) }
                guard !Task.isCancelled, generation == requestGeneration else { return }
                task = nil
                requestWatchdog?.cancel()
                requestWatchdog = nil
                activeRequest = nil
                guard var output = response["output"] as? [[String: Any]] else {
                    throw NSError(domain: "LiveClientBrain", code: 1)
                }
                var functions = output.filter { $0["type"] as? String == "function_call" }
                let staleSource = readingSource && (requestSelection != LiveSelectionGrounding.selection(requestSourceState) || MailBodyCache.withheld)
                if requestTurn != currentTurn || requestRevision != transcriptRevision || staleSource
                    || requestScope != scopeRevision || (!requestPresentation && completedTurns.contains(requestTurn)) {
                    let retry = requestTurn == currentTurn && requestScope == scopeRevision && !staleSource
                        && !completedTurns.contains(requestTurn)
                    endAttempt(reason: "superseded", stage: "provider_response", recovery: retry ? "revised_transcript" : "new_turn")
                    if retry {
                        onRequestTransition?("request_transcript_revised", requestID, delegation, requestTurn)
                        queuedDelegation = (delegation, liveDelegation != nil, currentTurn)
                    }
                    // Preserve already returned tool outcomes when applying a same-turn correction.
                    if !retry { input.removeAll() }
                    self.delegation = nil
                    liveDelegation = nil
                    finish(responseID: responseID, delegation: delegation, response: [:])
                    startPresentationIfReady()
                    startSettledDelegation()
                    return
                }
                // A late acknowledgment must use job results that landed during its request.
                if functions.isEmpty, requestJobs != jobRevision {
                    finish(responseID: responseID, delegation: delegation, response: [:])
                    run()
                    return
                }
                let repeatedSearch = functions.count == 1 && functions[0]["name"] as? String == GmailReadTools.search
                    && (functions[0]["arguments"] as? String).flatMap { ToolArguments($0).string("query") } == lookup?.queries.last
                if (functions.isEmpty || repeatedSearch), let fallback = lookup?.fallbackArguments, !requestPresentation {
                    output = [["type": "function_call", "call_id": "search-recovery-" + UUID().uuidString,
                               "name": GmailReadTools.search, "arguments": GmailReadTools.json(fallback)]]
                    functions = output
                }
                output = output.map { calendar.prepare($0, user: latestUser) }
                functions = output.filter { $0["type"] as? String == "function_call" }
                input += output
                let calls = Set(functions.compactMap { $0["call_id"] as? String })
                pendingCalls.formUnion(calls)
                for function in functions {
                    recordLookup(function)
                    if let id = function["call_id"] as? String {
                        functionItems[id] = function
                        functionOrigins[id] = (requestTurn, LiveCompactContext.text(requestState, includeEmailContent: false))
                    }
                }
                if !calls.isEmpty { armCallWatchdog(for: calls) }
                var localResultCalls = false
                for originalItem in output {
                    var item = originalItem
                    if let name = item["name"] as? String, ["send_email", "reply_email", "create_draft"].contains(ToolNarration.canonical(name)),
                       let id = item["call_id"] as? String, let composition = replyComposition,
                       composition.writeCall == nil, composition.recoveryJobID == nil, !LiveReplyComposition.sameSource(DispatchJob.MailOrigin.captured(in: state), composition.source),
                       let key = LiveEmailPresentation.Key.selection(composition.selection) {
                        let args = (item["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                        let source = LocalCompose.ReplySource(selection: key, ownerID: Container.shared.backend().userId,
                            profileID: ProfileRuntime.snapshot?.profileId, isCurrent: { false }, isOriginalRequestSource: true)
                        let reason = "NOT SENT — the feed moved away from the original reply. The complete body is retained in Activity. Use Work on this email there, then retry. Nothing was sent or saved to Gmail."
                        _ = await LocalCompose.retainReply(name, args: args, reason: reason, source: source,
                            conversationId: nil, callID: id)
                        guard requestScope == scopeRevision, requestTurn == currentTurn else { return }
                        replyComposition?.writeCall = id
                        self.item(["type": "function_call_output", "call_id": id, "output": reason])
                        localResultCalls = true
                        continue
                    }
                    if let name = item["name"] as? String, let id = item["call_id"] as? String,
                       let refusal = replyComposition?.refusal(name: name, arguments: item["arguments"] as? String ?? "{}", selection: state) {
                        recordReplyComposition("reply_write_refused")
                        self.item(["type": "function_call_output", "call_id": id, "output": refusal])
                        localResultCalls = true
                        continue
                    }
                    if let name = item["name"] as? String, ["send_email", "reply_email", "create_draft"].contains(ToolNarration.canonical(name)),
                       let body = replyComposition?.recoveredBody, replyComposition?.targetConfirmed == true,
                       LiveReplyComposition.requestsRetry(latestUser), let raw = item["arguments"] as? String,
                       var args = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
                        args["body"] = body
                        item["arguments"] = GmailReadTools.json(args)
                    }
                    if item["type"] as? String == "message", needsExactCalendarSpeech,
                       CalendarAvailabilityEvidence.claimsAvailability(GmailReadTools.json(item)) { continue }
                    if item["name"] as? String == CalendarAvailabilityEvidence.toolName, let id = item["call_id"] as? String {
                        let check = calendar.checkSlot(arguments: item["arguments"] as? String ?? "{}", now: now())
                        if calendar.focused { persistCalendarIntent() }
                        attemptFields["calendar_receipt_id"] = check.receiptID
                        attemptFields["calendar_slot_status"] = check.status
                        self.item(["type": "function_call_output", "call_id": id, "output": check.output])
                        localResultCalls = true; continue
                    }
                    if let name = item["name"] as? String, let id = item["call_id"] as? String,
                       let refusal = calendar.refusal(name: name, arguments: item["arguments"] as? String,
                                                      now: now(), jobs: Container.shared.dispatchJobs()) {
                        if refusal.outsideRange { onRequestTransition?("calendar_range_refused", requestID, delegation, requestTurn) }
                        self.item(["type": "function_call_output", "call_id": id, "output": refusal.message])
                        localResultCalls = true
                        continue
                    }
                    if item["name"] as? String == "read_tool_result", let id = item["call_id"] as? String {
                        let args = (item["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                        self.item(["type": "function_call_output", "call_id": id,
                                   "output": resultPage(id: args?["source_call_id"] as? String ?? "", offset: args?["offset"] as? Int ?? 0)])
                        localResultCalls = true
                        continue
                    }
                    if let name = item["name"] as? String, let id = item["call_id"] as? String,
                       let raw = item["arguments"] as? String,
                       let intent = calendar.preparingWrite(name: name, id: id, arguments: raw) {
                        guard await Container.shared.dispatchJobs().saveCalendarIntent(intent,
                            ownerID: Container.shared.backend().userId, profileID: ProfileRuntime.snapshot?.profileId),
                            requestScope == scopeRevision, requestTurn == currentTurn else {
                            self.item(["type": "function_call_output", "call_id": id, "output": "Not executed: the scheduling workflow could not be saved or its request changed."])
                            localResultCalls = true; continue
                        }
                        calendar.acceptPreparedWrite(intent)
                    }
                    if let name = item["name"] as? String, ["send_email", "reply_email", "create_draft"].contains(name),
                       let id = item["call_id"] as? String {
                        replyComposition?.writeCall = id
                        recordReplyComposition("reply_write_accepted")
                    }
                    deliver(["type": "response.event", "delegation_id": delegation,
                             "event": ["type": "response.output_item.done", "response_id": responseID, "item": item]])
                }
                if functions.isEmpty {
                    var text = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                        .compactMap { $0["text"] as? String }.joined(separator: "\n")
                    let presentation = calendar.presentation(text, user: latestUser, now: now())
                    attemptFields.merge(presentation.diagnostics) { _, new in new }
                    if let failure = presentation.failure {
                        finish(responseID: responseID, delegation: delegation, response: [:])
                        fail(failure.message, reason: failure.reason, stage: "presentation")
                        return
                    }
                    text = presentation.text
                    if replyComposition?.active == true, replyComposition?.targetConfirmed == true,
                       replyComposition?.writeCall == nil, Self.withoutDispositionQuestion(text) != text {
                        finish(responseID: responseID, delegation: delegation, response: [:])
                        if replyRecoveryTurns.insert(requestTurn).inserted {
                            observe("The destination clarification is resolved. Continue pendingReply's original dictated request now using its preserved details and existing send/draft policy. Do not summarize the email or ask for disposition again.")
                            run()
                        } else {
                            fail("Your reply text is preserved, but I couldn't continue it after the clarification. No message was sent.",
                                 reason: "reply_not_completed", stage: "clarification")
                        }
                        return
                    }
                    replyComposition?.question(text)
                    recordReplyComposition("reply_response")
                    if presentation.replaced {
                        response["output"] = [["type": "message", "content": [["type": "output_text", "text": text]]]]
                    }
                    // An earlier receipt is history, not proof that this turn's command ran.
                    let hasCurrentAction = actionRecords.contains { record in
                        guard record["origin_turn"] as? Int == requestTurn,
                              let call = record["call"] as? [String: Any], let name = call["name"] as? String else { return false }
                        return LiveWriteTarget.mailWrites.contains(ToolNarration.canonical(name)) || ["dispatch", "dispatch_command"].contains(name)
                    }
                    if !requestPresentation, LiveFastAction.parse(latestUser) == .archive,
                       !hasCurrentAction, !Self.isActionClarification(text) {
                        onRequestTransition?("request_no_action", requestID, delegation, requestTurn)
                        finish(responseID: responseID, delegation: delegation, response: [:])
                        fail("I haven't executed this new archive request. Please try again.", reason: "no_action", stage: "presentation")
                        return
                    }
                    if requestPresentation, let present {
                        present(LiveSessionAdapter.hasSubstantiveSpeech(text) ? groundedReply(text)
                            : "The action returned, but I couldn't explain the next item. Check Live Activity for its result. You can continue with the feed buttons.")
                    } else if !text.isEmpty { speak(groundedReply(text), liveDelegation) }
                    endAttempt(reason: "completed", stage: "presentation_queued", recovery: "none")
                    completedTurns.insert(requestTurn)
                    input.removeAll()
                    self.delegation = nil
                    liveDelegation = nil
                }
                finish(responseID: responseID, delegation: delegation, response: response)
                if localResultCalls, pendingCalls.isEmpty { run() }
                if functions.isEmpty {
                    presentationOnly = false
                    startPresentationIfReady()
                    startSettledDelegation()
                }
            } catch {
                guard !Task.isCancelled, generation == requestGeneration else { return }
                task = nil
                requestWatchdog?.cancel()
                requestWatchdog = nil
                activeRequest = nil
                input.removeAll()
                if !requestPresentation && completedTurns.contains(requestTurn) {
                    endAttempt(reason: "locally_resolved", stage: "provider_response", recovery: "application_result")
                    self.delegation = nil
                    liveDelegation = nil
                    finish(responseID: responseID, delegation: delegation, response: [:])
                    startPresentationIfReady()
                    startSettledDelegation()
                    return
                }
                deliver(["type": "response.event", "delegation_id": delegation,
                         "event": ["type": "response.failed", "response": ["id": responseID, "status": "failed", "client_task": true]]])
                let sent = attemptFields["request_sent"] == "true"
                onRequestTransition?(sent ? "request_provider_failed" : "request_preparation_failed", requestID, delegation, requestTurn)
                let detail = (error as? LiveBrainRequestError)?.diagnostic ?? "transport_or_response_failure"
                RealtimeLog.log("liveBrain: request failed \(detail)")
                attemptFields.merge(VoiceDiagnostics.failure(error)) { _, new in new }
                if let error = error as? LiveBrainRequestError { attemptFields["http_status"] = String(error.status) }
                fail("That task could not complete. The call is still connected; existing actions have not been repeated.", reason: sent ? "provider_failure" : "request_preparation_failed", stage: sent ? "provider_request" : "pre_request")
            }
        }
    }

    private static func isActionClarification(_ text: String) -> Bool {
        let question = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return question.hasSuffix("?") && ["which email", "which message", "do you mean", "did you mean"]
            .contains(where: question.hasPrefix)
    }

    private func supersedeRequest() {
        guard let active = activeRequest else { return }
        endAttempt(reason: "superseded", stage: "provider_request", recovery: "new_turn")
        onRequestTransition?("request_superseded", active.requestID, active.delegation, requestTurn)
        cancelRequest()
        input.removeAll()
        delegation = nil
        liveDelegation = nil
        presentationOnly = false
        RealtimeLog.log("liveBrain: superseded request for turn \(requestTurn)")
        finish(responseID: active.responseID, delegation: active.delegation, response: [:])
    }

    private func expireRequest() {
        guard let active = activeRequest else { return }
        onRequestTransition?("request_timed_out", active.requestID, active.delegation, requestTurn)
        cancelRequest()
        RealtimeLog.log("liveBrain: request exceeded \(Int(requestBound))s; releasing turn \(requestTurn)")
        deliver(["type": "response.event", "delegation_id": active.delegation,
                 "event": ["type": "response.failed", "response": ["id": active.responseID,
                    "status": "failed", "client_task": true]]])
        fail("I couldn't finish that answer in time. You can ask again; I haven't repeated any email actions.", reason: "timeout", stage: "provider_request")
    }

    private func finish(responseID: String, delegation: String, response: [String: Any]) {
        deliver(["type": "response.event", "delegation_id": delegation,
                 "event": ["type": "response.completed", "response": ["id": responseID,
                    "output": response["output"] ?? [], "usage": response["usage"] ?? [:]]]])
    }

    private func fail(_ message: String, reason: String, stage: String) {
        endAttempt(reason: reason, stage: stage, recovery: "retain_selection_and_receipts")
        let live = liveDelegation
        input.removeAll()
        delegation = nil
        liveDelegation = nil
        pendingPresentation = nil
        presentationOnly = false
        // The request's own turn is over, not whichever turn the user has since started:
        // completing `currentTurn` here discarded a delegation queued for the newer turn.
        completedTurns.insert(requestTurn)
        speak(message, live)
        failed(message)
        // A turn that began while the failed request ran is still owed its delegation.
        startPresentationIfReady()
        startSettledDelegation()
    }

    func acceptToolCall(_ id: String) {
        unclaimedCalls.remove(id)
        if unclaimedCalls.isEmpty { callWatchdog?.cancel(); callWatchdog = nil }
    }

    /// Release calls the adapter never answered, then let the response go on without them.
    private func armCallWatchdog(for calls: Set<String>) {
        callWatchdog?.cancel()
        unclaimedCalls = calls
        let bound = toolCallBound
        callWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(bound))
            guard let self, !Task.isCancelled else { return }
            releaseUnansweredCalls(calls)
        }
    }

    private func releaseUnansweredCalls(_ calls: Set<String>) {
        let stuck = calls.intersection(unclaimedCalls).intersection(pendingCalls)
        guard !stuck.isEmpty else { return }
        RealtimeLog.log("liveBrain: \(stuck.count) tool call(s) unanswered after \(Int(toolCallBound))s; releasing")
        for id in stuck.sorted() {
            item(["type": "function_call_output", "call_id": id, "output": LiveSessionAdapter.toolCallUnfinished])
        }
        if delegation != nil { run() }
    }

    private func cancelRequest() {
        generation = UUID()
        task?.cancel()
        task = nil
        activeRequest = nil
        requestWatchdog?.cancel()
        requestWatchdog = nil
        callWatchdog?.cancel()
        callWatchdog = nil
    }

    func close() {
        closed = true
        lookup = nil
        priorReplyDestination = nil
        investigating = false
        endAttempt(reason: "cancelled", stage: "session_close", recovery: "none")
        finishQueuedAttempt(reason: "cancelled")
        cancelRequest(); queuedDelegation = nil
    }
}
