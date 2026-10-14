import Foundation

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
    private var input: [[String: Any]] = []
    private var task: Task<Void, Never>?
    private var delegation: String?
    private var liveDelegation: String?
    private var generation = UUID()
    private var pendingCalls = Set<String>()
    private var results = Set<String>()
    private var completedTurns = Set<Int>()
    private var currentTurn = 0
    private var latestUser = ""
    private var latestAssistant = ""
    private var turnHistoryIndex: Int?
    private var state = ""
    private var turnState = ""
    private var scope: String?
    private var presentationOnly = false
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
    private var functionItems: [String: [String: Any]] = [:]
    private var pendingQuestion = ""
    private var queuedDelegation: (id: String, live: Bool, turn: Int)?

    init(request: @escaping Request, deliver: @escaping ([String: Any]) -> Void,
         speak: @escaping (String, String?) -> Void, failed: @escaping (String) -> Void) {
        self.request = request
        self.deliver = deliver
        self.speak = speak
        self.failed = failed
    }

    var busy: Bool { task != nil || !pendingCalls.isEmpty }

    func updateState(_ text: String, scope: String?) {
        if self.scope != scope {
            scopeChanged = self.scope != nil
            self.scope = scope
            scopeRevision += 1
            actionRecords.removeAll()
            functionItems.removeAll()
            pendingCalls.removeAll()
            input.removeAll()
            latestAssistant = ""
            latestUser = ""
            pendingQuestion = ""
            questionState = ""
            requestState = ""
            queuedDelegation = nil
            pendingPresentation = nil
            presentationOnly = false
            history.removeAll()
            context.removeAll()
            state = ""
            turnState = ""
            turnHistoryIndex = nil
        }
        state = LiveCompactContext.text(text)
    }

    func user(_ text: String, turn: Int) {
        scopeChanged = false
        transcriptRevision += 1
        settledTurn = nil
        if turn != currentTurn {
            if !latestAssistant.isEmpty {
                history.append(["type": "message", "role": "assistant", "content": latestAssistant])
            }
            latestAssistant = ""
            currentTurn = turn
            turnState = state
            history.append(["type": "message", "role": "user", "content": text])
            while history.count > 24 { history.removeFirst() }
            turnHistoryIndex = history.count - 1
        } else if let index = turnHistoryIndex, history.indices.contains(index) {
            history[index]["content"] = text
        }
        latestUser = text
        // The response handler rejects proposals for an older turn before emitting any tools.
    }

    func assistant(_ delta: String) {
        latestAssistant += delta
        if latestAssistant.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") {
            pendingQuestion = latestAssistant
            questionState = state
        }
    }

    func observe(_ text: String) {
        let compact = LiveCompactContext.text(text)
        guard context.last != compact else { return }
        context.append(compact)
        // Current selection and the latest question are retained separately from these presentation hints.
        while context.count > 6 { context.removeFirst() }
    }

    func item(_ item: [String: Any]) {
        var item = item
        if let text = item["content"] as? String { item["content"] = LiveCompactContext.text(text) }
        if let output = item["output"] as? String { item["output"] = LiveCompactContext.text(output) }
        if item["type"] as? String == "function_call_output", let id = item["call_id"] as? String {
            guard pendingCalls.contains(id), results.insert(id).inserted else { return }
            pendingCalls.remove(id)
        }
        if item["type"] as? String == "function_call_output", let id = item["call_id"] as? String,
           let call = functionItems[id] {
            actionRecords.append(["call": call, "result": item["output"] ?? "No result"])
            functionItems.removeValue(forKey: id)
            while actionRecords.count > 12 { actionRecords.removeFirst() }
        }
        if item["type"] as? String == "message", ["system", "developer"].contains(item["role"] as? String ?? ""),
           let text = item["content"] as? String {
            observe(text)
        } else { input.append(item) }
    }

    func begin(_ id: String, live: Bool, turn: Int) {
        guard !completedTurns.contains(turn), queuedDelegation?.id != id, delegation != id else { return }
        queuedDelegation = (id, live, turn)
    }

    func settle(turn: Int) {
        settledTurn = turn
        startSettledDelegation()
    }

    private func startSettledDelegation() {
        guard let turn = settledTurn, turn == currentTurn, !latestUser.isEmpty else { return }
        guard let queued = queuedDelegation, (queued.turn == turn || queued.turn == 0), !busy else { return }
        guard !completedTurns.contains(turn) else { queuedDelegation = nil; return }
        queuedDelegation = nil
        delegation = queued.id
        liveDelegation = queued.live ? queued.id : nil
        steps = 0
        presentationOnly = false
        requestTurn = turn
        requestState = turnState
        input.append(["type": "message", "role": "user", "content": latestUser])
        run()
    }

    func continueResponse(delegation id: String?) {
        guard !busy else { return }
        if delegation == nil {
            delegation = id ?? "application-" + UUID().uuidString
            requestTurn = currentTurn
            requestState = turnState
            steps = 0
        }
        run()
    }

    func recordFastResult(_ output: String, turn: Int) {
        completedTurns.insert(turn)
        observe("Application already handled user turn \(turn). Verified result: " + output)
        // In-flight proposals are suppressed when they return, preserving response bookkeeping.
        if queuedDelegation?.turn == turn { queuedDelegation = nil }
    }

    func presentResult(_ output: String, delegation: String, turn: Int) {
        pendingPresentation = (delegation, turn, LiveCompactContext.text(output))
        startPresentationIfReady()
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
        run()
    }

    private func run() {
        guard task == nil, pendingCalls.isEmpty, let delegation else { return }
        if scopeChanged {
            let responseID = "jo-" + UUID().uuidString
            deliver(["type": "response.event", "delegation_id": delegation,
                     "event": ["type": "response.created", "response": ["id": responseID]]])
            self.delegation = nil
            liveDelegation = nil
            finish(responseID: responseID, delegation: delegation, response: [:])
            return
        }
        steps += 1
        guard steps <= 12 else { fail("This task reached its step limit. No further actions were attempted."); return }
        let requestGeneration = generation
        let requestTurn = self.requestTurn
        let requestRevision = transcriptRevision
        let requestScope = scopeRevision
        let requestPresentation = presentationOnly
        let responseID = "jo-" + UUID().uuidString
        var mandatory = ["requestSelection": requestState == state ? "Same as currentSelection" : requestState, "currentSelection": state,
                         "latestAssistant": latestAssistant, "pendingQuestion": pendingQuestion, "questionSelection": questionState == state ? "Same as currentSelection" : questionState,
                         "recordedActions": Array(actionRecords.suffix(12)), "applicationUpdates": context] as [String: Any]
        var optionalUpdates = context
        while !optionalUpdates.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: mandatory), data.count > 64_000 {
            optionalUpdates.removeFirst()
            mandatory["applicationUpdates"] = optionalUpdates
        }
        guard let stateData = try? JSONSerialization.data(withJSONObject: mandatory, options: [.sortedKeys]),
              stateData.count <= 96_000 else { fail("The current task context is too large to process safely."); return }
        let prior = history.enumerated().filter { $0.offset != turnHistoryIndex }.map(\.element)
        let body: [String: Any] = ["requestId": UUID().uuidString,
            "context": String(decoding: stateData, as: UTF8.self), "history": Array(prior.suffix(12)), "input": input,
            "presentationOnly": presentationOnly]
        deliver(["type": "response.event", "delegation_id": delegation,
                 "event": ["type": "response.created", "response": ["id": responseID]]])
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await request(body)
                guard !Task.isCancelled, generation == requestGeneration else { return }
                task = nil
                guard let output = response["output"] as? [[String: Any]] else {
                    throw NSError(domain: "LiveClientBrain", code: 1)
                }
                let functions = output.filter { $0["type"] as? String == "function_call" }
                if requestTurn != currentTurn || requestRevision != transcriptRevision
                    || requestScope != scopeRevision || (!requestPresentation && completedTurns.contains(requestTurn)) {
                    let retry = requestTurn == currentTurn && requestScope == scopeRevision
                        && !completedTurns.contains(requestTurn)
                    if retry { queuedDelegation = (delegation, liveDelegation != nil, currentTurn) }
                    // Preserve already returned tool outcomes when applying a same-turn correction.
                    if !retry { input.removeAll() }
                    self.delegation = nil
                    liveDelegation = nil
                    finish(responseID: responseID, delegation: delegation, response: [:])
                    startPresentationIfReady()
                    startSettledDelegation()
                    return
                }
                input += output
                pendingCalls.formUnion(functions.compactMap { $0["call_id"] as? String })
                for function in functions {
                    if let id = function["call_id"] as? String { functionItems[id] = function }
                }
                for item in output {
                    deliver(["type": "response.event", "delegation_id": delegation,
                             "event": ["type": "response.output_item.done", "response_id": responseID, "item": item]])
                }
                if functions.isEmpty {
                    let text = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                        .compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !text.isEmpty { speak(text, liveDelegation) }
                    completedTurns.insert(requestTurn)
                    input.removeAll()
                    self.delegation = nil
                    liveDelegation = nil
                }
                finish(responseID: responseID, delegation: delegation, response: response)
                if functions.isEmpty {
                    presentationOnly = false
                    startPresentationIfReady()
                    startSettledDelegation()
                }
            } catch {
                guard !Task.isCancelled, generation == requestGeneration else { return }
                task = nil
                input.removeAll()
                self.delegation = nil
                liveDelegation = nil
                if !requestPresentation && completedTurns.contains(requestTurn) {
                    finish(responseID: responseID, delegation: delegation, response: [:])
                    startPresentationIfReady()
                    startSettledDelegation()
                    return
                }
                deliver(["type": "response.event", "delegation_id": delegation,
                         "event": ["type": "response.failed", "response": ["id": responseID, "status": "failed", "client_task": true]]])
                let detail = (error as? LiveBrainRequestError)?.diagnostic ?? "transport_or_response_failure"
                RealtimeLog.log("liveBrain: request failed \(detail)")
                fail("That task could not complete. The call is still connected; existing actions have not been repeated.")
            }
        }
    }

    private func finish(responseID: String, delegation: String, response: [String: Any]) {
        deliver(["type": "response.event", "delegation_id": delegation,
                 "event": ["type": "response.completed", "response": ["id": responseID,
                    "output": response["output"] ?? [], "usage": response["usage"] ?? [:]]]])
    }

    private func fail(_ message: String) {
        input.removeAll()
        delegation = nil
        liveDelegation = nil
        pendingPresentation = nil
        presentationOnly = false
        completedTurns.insert(currentTurn)
        failed(message)
    }

    private func cancelRequest() {
        generation = UUID()
        task?.cancel()
        task = nil
    }

    func close() { cancelRequest(); queuedDelegation = nil }
}
