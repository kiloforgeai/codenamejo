import CryptoKit
import FactoryKit
import Foundation

/// A dispatched job, run on the phone: a `/v1/responses` loop on the user's key over the phone's own tools.
/// It lives exactly as long as the task awaiting it. A live call's task outlives hang-up under
/// `HangUpRunway`, and the row it writes is what the next call reports.
enum DispatchWorker {
    struct Job {
        var id: UUID
        var task: String
        var account: String? = nil
        var facts: [String] = []
        var standingOnJSON: String? = nil
        var authoredAt: Date? = nil
        var authoredTimeZone: TimeZone? = nil
        var expects: LocalTriageQueue.Outcome.Shape? = nil
        var scope: DispatchScope? = nil
        /// A saved command's stored steps, forced one per round; nil for a free-text job.
        var commandSteps: [CommandAction]? = nil
        var profileId: String? = ProfileRuntime.snapshot?.profileId
        /// Advanced once per round, out of `maxRounds`, for `HangUpRunway`'s system card.
        var progress: Progress? = nil
    }

    static let maxRounds = 16
    /// Rounds stop starting here, leaving room for the terminal write.
    static let budget: TimeInterval = 270
    /// The message that ends every failure the live assistant relays.
    private static let relay = " Tell the user plainly; do not invent a result."

    private struct Performed { let tool: String; let summary: String; let failed: Bool }
    private struct Forced { let stored: String; let actual: String; let detail: String; let web: Bool }

    // MARK: - Running

    @MainActor
    static func run(_ job: Job) async -> FullDuplexBroker.DispatchOutcome {
        let store = Container.shared.dispatchJobs()
        store.begin(id: job.id, task: job.task, profileId: job.profileId)
        let started = Date()
        var performed: [Performed] = []
        do {
            let text = try await loop(job, started: started) { ref in
                // A refusal the job corrected and retried is not a failed write.
                if !ref.failed { performed.removeAll { $0.failed && $0.tool == ref.tool } }
                performed.append(ref)
            }
            return finish(job, text: text, performed: performed, store: store, started: started)
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            let wrote = performed.contains { !$0.failed }
            let reason = cancelled ? "That job was stopped before it could finish" : "That job failed before it could finish"
            let row = wrote ? "\(reason), part-way. Before it stopped: \(describe(performed))"
                : (error as? LiveOpenAI.MissingKey)?.errorDescription ?? "\(reason), and nothing was changed."
            RealtimeLog.log("dispatch: \(job.id) \(cancelled ? "cancelled" : "failed") after "
                + "\(Int(Date().timeIntervalSince(started) * 1000))ms — \(error.localizedDescription)")
            // An unreachable OpenAI or a missing key, with nothing done, leaves no row: a note retries later.
            let unreached = !cancelled && !wrote && (error is URLError || error is LiveOpenAI.MissingKey)
            if unreached { store.discard(job.id) } else { store.finish(job.id, state: "failed", result: row) }
            return FullDuplexBroker.DispatchOutcome(text: row + relay, ok: false, recorded: !unreached)
        }
    }

    @MainActor
    private static func finish(_ job: Job, text raw: String, performed: [Performed],
                               store: DispatchJobStore, started: Date) -> FullDuplexBroker.DispatchOutcome {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if job.expects == .receipt {
            var result = actionResult(text, writeFailed: performed.contains(where: \.failed))
            if !result.ok, !performed.isEmpty {
                result.text += " Action record: " + performed.map { $0.failed ? "\($0.summary) failed" : $0.summary }
                    .joined(separator: "; ") + "."
            }
            store.finish(job.id, state: result.ok ? "done" : "failed", result: result.text, reportBack: !result.ok)
            RealtimeLog.log("dispatch: \(job.id) \(result.ok ? "done silently" : "failed") in \(ms)ms")
            return FullDuplexBroker.DispatchOutcome(text: result.text, ok: result.ok, reportBack: !result.ok)
        }
        RealtimeLog.log("dispatch: \(job.id) answered in \(ms)ms — \(text.count) chars")
        if !text.isEmpty {
            store.finish(job.id, state: "done", result: text)
            return FullDuplexBroker.DispatchOutcome(text: text, ok: nil)
        }
        if !performed.isEmpty {
            let done = "That job ran out of steps before it could say how it went, but it did this much — "
                + describe(performed)
            store.finish(job.id, state: "done", result: done)
            return FullDuplexBroker.DispatchOutcome(text: done, ok: nil)
        }
        let empty = "That job stopped before it had anything to report, and nothing was changed."
        store.finish(job.id, state: "failed", result: empty)
        return FullDuplexBroker.DispatchOutcome(text: empty + relay, ok: false)
    }

    /// The writes a job made, for when it produced no prose of its own.
    private static func describe(_ refs: [Performed]) -> String {
        let done = refs.filter { !$0.failed }.map(\.summary)
        let failed = refs.filter(\.failed).map(\.summary)
        return [done.isEmpty ? "" : done.joined(separator: "; ") + ".",
                failed.isEmpty ? "" : "These did not go through: " + failed.joined(separator: "; ") + "."]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A receipt job's structured report; anything unparseable must surface as unfinished.
    static func actionResult(_ raw: String, writeFailed: Bool) -> (text: String, ok: Bool) {
        if let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let completed = json["completed"] as? Bool,
           let report = (json["report"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !report.isEmpty {
            return (report, completed && !writeFailed)
        }
        return ("That job did not confirm that all the requested work finished. Its outcome needs checking.", false)
    }

    // MARK: - The loop

    @MainActor
    private static func loop(_ job: Job, started: Date, performed: (Performed) -> Void) async throws -> String {
        let mail = GoogleAccountStore.mailAccounts()
        let calendar = CalendarTools.accounts()
        let target = job.scope == .independent ? nil : target(standingOnJSON: job.standingOnJSON, facts: job.facts)
        let receipt = job.expects == .receipt
        // The job's own profile, not the active one: a note can run after the user switched.
        let connectors = ConnectorRegistry.statuses(profileId: job.profileId)
        let relay = FullDuplexBroker.workerTools(mail: ProfileRuntime.allowedMailAccounts(mail), calendar: calendar,
                                                 connectors: connectors)
        let relayNames = Set(relay.compactMap { $0["name"] as? String })
        let tools = tools(mail: mail, calendar: calendar, relay: relay)
        let instructions = try instructions(receipt: receipt, mail: !mail.isEmpty, calendar: !calendar.isEmpty,
                                            connectors: connectors)
        var input: [[String: Any]] = [
            ["role": "user", "content": job.task],
            ["role": "developer", "content": try context(job, target: target, mail: mail, calendar: calendar)],
        ]
        let names = Set(tools.compactMap { $0["name"] as? String })
        let cursor = target.flatMap { about -> GmailManageTools.Cursor? in
            guard let data = try? JSONSerialization.data(withJSONObject: ["done": false, "item": about]) else { return nil }
            return GmailManageTools.cursor(step: String(decoding: data, as: UTF8.self))
        }

        // A saved command's steps, each pinned to the worker's own name for its tool. A step the
        // worker has no tool for stops the job and says which, rather than substituting another.
        var forced: [Forced] = []
        var finalInstruction = "Give the concise final report for the completed command."
        if let steps = job.commandSteps {
            let summaries = steps.indices.filter { ["summarize", "summarise"].contains(steps[$0].tool.lowercased()) }
            if summaries.count > 1 || (summaries.count == 1 && summaries[0] != steps.count - 1) {
                return "The saved command has a Final answer step that is not its single last step."
            }
            if let last = summaries.first, !steps[last].detail.isEmpty { finalInstruction = steps[last].detail }
            for (index, step) in steps.enumerated() where !summaries.contains(index) {
                let stored = step.tool.trimmingCharacters(in: .whitespaces)
                if stored == WebSearchTool.name {
                    forced.append(Forced(stored: stored, actual: stored, detail: step.detail, web: true)); continue
                }
                let bare = stored.hasPrefix("gmail_") ? String(stored.dropFirst(6)) : stored
                guard let actual = [stored, bare, "gmail_" + bare].first(where: names.contains) else {
                    return "Saved command step \(index + 1) needs \(stored), which is not available to a background job."
                }
                forced.append(Forced(stored: stored, actual: actual, detail: step.detail, web: false))
            }
            if forced.count >= maxRounds {
                return "The saved command has \(forced.count) tool steps, and a dispatched job can run at most "
                    + "\(maxRounds - 1) before its report. Shorten the command."
            }
        }
        var next = 0
        let cacheKey = SHA256.hash(data: Data((instructions + names.sorted().joined()).utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()

        for round in 0..<maxRounds {
            guard Date().timeIntervalSince(started) < budget else {
                RealtimeLog.log("dispatch: \(job.id) stopped at the deadline, \(round) round(s) in")
                return ""
            }
            try Task.checkCancellation()
            job.progress?.completedUnitCount = Int64(round)
            let step = job.commandSteps == nil ? nil : forced.indices.contains(next) ? forced[next] : nil
            let finalCommandRound = job.commandSteps != nil && step == nil
            var choice: Any?
            if let step {
                input.append(["role": "user", "content": "Execute saved command step \(next + 1) now. You must call "
                    + "\(step.stored) exactly once. " + (step.detail.isEmpty
                        ? "Resolve its arguments from the task and prior step results."
                        : "Use this stored instruction to form its arguments: \(step.detail)")])
                choice = step.web ? ["type": "allowed_tools", "mode": "required", "tools": [["type": "web_search"]]]
                    : ["type": "function", "name": step.actual]
            } else if finalCommandRound {
                input.append(["role": "user", "content": "Every required saved-command tool step has completed. "
                    + "Do not call another tool. Return the final answer now. \(finalInstruction)"])
                choice = "none"
            }
            var text: [String: Any] = ["verbosity": "medium"]
            if receipt {
                text["format"] = ["type": "json_schema", "name": "dispatch_result", "strict": true, "schema": [
                    "type": "object", "additionalProperties": false, "required": ["completed", "report"],
                    "properties": ["completed": ["type": "boolean"], "report": ["type": "string"]],
                ] as [String: Any]]
            }
            var body: [String: Any] = [
                "model": LivePrompt.brainModel, "instructions": instructions, "input": input, "tools": tools,
                "reasoning": ["effort": "low"], "text": text, "service_tier": "priority", "store": false,
                "include": ["reasoning.encrypted_content"], "prompt_cache_key": cacheKey,
            ]
            if let choice { body["tool_choice"] = choice }
            let output = try await respond(body, deadline: started.addingTimeInterval(budget))
            input += output
            let calls = output.filter { $0["type"] as? String == "function_call" }
            if let step, step.web {
                let searches = output.filter { $0["type"] as? String == "web_search_call" }
                guard searches.count == 1, searches[0]["status"] as? String == "completed" else {
                    return "Saved command step \(next + 1) could not complete web search."
                }
                next += 1
                continue
            }
            if let step, calls.count != 1 || calls[0]["name"] as? String != step.actual {
                return "Saved command step \(next + 1) did not call \(step.stored) exactly once."
            }
            guard !calls.isEmpty else {
                return output.filter { $0["type"] as? String == "message" }
                    .flatMap { $0["content"] as? [[String: Any]] ?? [] }
                    .compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }
                    .joined()
            }
            for call in calls {
                try Task.checkCancellation()
                let name = call["name"] as? String ?? ""
                let callId = call["call_id"] as? String ?? ""
                let raw = call["arguments"] as? String ?? "{}"
                let result: (output: String, failed: Bool, write: Bool)
                if var args = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] {
                    // The account the live call pinned, unless the model named one or is replying on a thread.
                    // A connector tool takes none: GitHub's `account` is a login, and the rest have no such field.
                    if let account = job.account, !account.isEmpty, args["account"] == nil, args["thread_id"] == nil,
                       takesMailAccount(name) {
                        args["account"] = account
                    }
                    let json = String(decoding: (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8), as: UTF8.self)
                    result = await execute(name, json, relayNames: relayNames, cursor: cursor, standingOn: target,
                                           profileId: job.profileId)
                } else {
                    result = ("Could not read those arguments as JSON. Call the tool again.", true, false)
                }
                if result.write {
                    let line = result.output.split(separator: "\n").first.map(String.init) ?? name
                    performed(Performed(tool: name, summary: String(line.prefix(200)), failed: result.failed))
                }
                RealtimeLog.log("dispatch: \(job.id) tool \(name)\(result.failed ? " failed" : "")")
                input.append(["type": "function_call_output", "call_id": callId, "output": result.output])
            }
            if step != nil { next += 1 }
        }
        RealtimeLog.log("dispatch: \(job.id) hit the \(maxRounds)-round tool cap")
        return ""
    }

    /// One round, retried twice on a transient failure while the deadline allows.
    private static func respond(_ body: [String: Any], deadline: Date) async throws -> [[String: Any]] {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let result = try await LiveOpenAI.responses(body, timeout: 120)
                guard let output = result["output"] as? [[String: Any]] else {
                    throw LiveBrainRequestError(status: 502, serverCode: "dispatch_request_failed")
                }
                return output
            } catch let error as LiveBrainRequestError where error.status == 429 || error.status >= 500 || error.status < 0 {
                guard attempt < 3, Date() < deadline else { throw error }
            } catch let error as URLError where error.code != .cancelled {
                guard attempt < 3, Date() < deadline else { throw error }
            }
            try await Task.sleep(for: .seconds(attempt))
        }
    }

    // MARK: - Tools

    /// The phone's mail and calendar tools, the relay's writes and connectors, link reading and hosted web search.
    static func tools(mail: [String], calendar: [String], relay: [[String: Any]],
                      text: LivePrompt.Text = .bundled) -> [[String: Any]] {
        let invite = (try? text("dispatch/invite-note")) ?? ""
        let calendarTools = CalendarTools.definitions(accounts: calendar).map { tool -> [String: Any] in
            guard tool["name"] as? String == CalendarTools.create else { return tool }
            var tool = tool
            tool["description"] = (tool["description"] as? String ?? "") + invite
            return tool
        }
        return GmailReadTools.definitions(accounts: mail,
                bodies: !MailHeadersOnly.withholdsBodies && ProfileRuntime.snapshot?.mailHeadersOnly != true)
            + GmailManageTools.definitions(accounts: mail, filterAccounts: mail.filter {
                GoogleAccountStore.grant(for: $0)?.scopes.contains(GmailManageTools.filterScope) == true })
            + calendarTools
            + relay
            + (MailHeadersOnly.withholdsBodies ? [] : EmailLinkTool.definitions(accounts: mail))
            + [["type": "web_search", "search_context_size": "medium"]]
    }

    private static let readOnlyRelays: Set<String> = ["find_person", "count_messages"]
    private static let readOnlyManage: Set<String> = [GmailManageTools.listLabels, GmailManageTools.listFilters]

    /// Whether a tool's `account` is a mail or calendar account, the one a live call pins on a job.
    /// A connector tool takes none: GitHub's `account` is a login, and the rest have no such field.
    static func takesMailAccount(_ name: String) -> Bool { !ConnectorRegistry.owns(name) }

    static func execute(_ name: String, _ arguments: String, relayNames: Set<String>,
                                cursor: GmailManageTools.Cursor?, standingOn: [String: Any]?, profileId: String?)
        async -> (output: String, failed: Bool, write: Bool) {
        // A connector's tool, on the job profile's own grant.
        if let connector = ConnectorRegistry.owner(of: name), relayNames.contains(name) {
            let result = await connector.run(name, argumentsJSON: arguments, profileId: profileId)
            return (result.text, result.ok == false, connector.writes(name))
        }
        if GmailReadTools.names.contains(name) {
            let result = await GmailReadTools.run(name: name, argumentsJSON: arguments)
            return (result.output, result.failed, false)
        }
        if GmailManageTools.names.contains(name) {
            let resolved = GmailManageTools.resolvedArguments(name: name, argumentsJSON: arguments, cursor: cursor)
            let result = await GmailManageTools.run(name: name, argumentsJSON: resolved)
            return (result.output, result.failed, !readOnlyManage.contains(name))
        }
        if CalendarTools.names.contains(name) {
            let result = await CalendarTools.run(name: name, argumentsJSON: arguments)
            return (result.output, result.failed, name != CalendarTools.list)
        }
        if name == EmailLinkTool.name {
            return (await EmailLinkTool.run(argumentsJSON: arguments, standingOn: standingOn), false, false)
        }
        // Answered from this phone's correspondent directory, as a call's `find_person` is.
        if name == "find_person", relayNames.contains(name) {
            let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
            let spoken = (args["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = await FullDuplexVoiceClient.resolvePerson(spoken, store: Container.shared.contactStore())
            return (answer.output, false, false)
        }
        // Drafts and sends run on this phone (`LocalCompose`); `runTool` routes them there.
        if relayNames.contains(name) {
            let result = await FullDuplexBroker.runTool(name: name, argumentsJSON: arguments)
            return (result.text, result.ok == false, !readOnlyRelays.contains(name))
        }
        return ("There is no tool called \(name). Use only the tools you were given.", true, false)
    }

    // MARK: - Prompt

    /// The stable half: policy, cached across jobs. Per-job state goes in `context`, after the task.
    static func instructions(receipt: Bool, mail: Bool, calendar: Bool, connectors: [String: ConnectorStatus] = [:],
                             text: LivePrompt.Text = .bundled) throws -> String {
        var facts = LivePrompt.Facts()
        facts.skills = (mail ? ["email"] : []) + (calendar ? ["calendar"] : [])
            + ConnectorRegistry.all.compactMap { connectors[$0.id]?.isConnected == true ? $0.skill : nil }
        var out = try LivePrompt.baseInstructions(facts, text: text)
        // Before the worker section, so its reading of every "ask the user" above covers this note too.
        let customMCP = connectors[CustomMCPConnector.id]?.working ?? []
        if !customMCP.isEmpty {
            out += "\n\n" + (try text("notes/custom-mcp", ["servers": customMCP.joined(separator: ", ")]))
        }
        out += "\n\n" + (try text("dispatch/worker"))
        if receipt { out += "\n\n" + (try text("dispatch/action-result")) }
        return out
    }

    static func context(_ job: Job, target: [String: Any]?, mail: [String], calendar: [String],
                        now: Date = Date(), text: LivePrompt.Text = .bundled) throws -> String {
        let zone = TimeZone.current
        var parts = [try text("dispatch/clock", ["now": spoken(now, in: zone), "zone": zone.identifier,
                                                  "unix": String(Int(now.timeIntervalSince1970))])]
        if let authored = job.authoredAt, now.timeIntervalSince(authored) >= 5 * 60 {
            let minutes = max(0, Int((now.timeIntervalSince(authored) / 60).rounded()))
            func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
            let ago = minutes < 60 ? unit(minutes, "minute")
                : minutes < 1440 ? unit(minutes / 60, "hour") + " and " + unit(minutes % 60, "minute")
                : unit(minutes / 1440, "day")
            parts.append(try text("dispatch/authored", ["spoken": spoken(authored, in: job.authoredTimeZone ?? zone),
                                                        "ago": ago]))
        }
        var calendarFacts = LivePrompt.Facts()
        calendarFacts.calendarAccounts = calendar
        if let note = try LivePrompt.calendarNote(calendarFacts, timeZone: zone.identifier, now: now, text: text) {
            parts.append(note)
        }
        if !mail.isEmpty {
            let lines = mail.count == 1 ? "- their own email address: \(mail[0])"
                : "- their own email addresses, primary first: " + mail.joined(separator: ", ")
            parts.append(try text("dispatch/self", ["lines": lines]))
        }
        if !job.facts.isEmpty {
            parts.append(try text("dispatch/known-facts", ["facts": job.facts.map { "- " + $0 }.joined(separator: "\n")]))
        }
        if let target { parts.append(try standingOn(target, text: text)) }
        return parts.joined(separator: "\n\n")
    }

    private static func spoken(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_CA")
        formatter.timeZone = zone
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func standingOn(_ about: [String: Any], text: LivePrompt.Text) throws -> String {
        func field(_ key: String) -> String { about[key] as? String ?? "" }
        if let members = about["messages"] as? [[String: Any]], !members.isEmpty {
            let lines = members.compactMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
                .map { String(decoding: $0, as: UTF8.self) }
            return try text("dispatch/standing-on-group", ["account": field("account"), "threadId": field("threadId"),
                                                           "members": lines.joined(separator: "\n")])
        }
        let fields = [("from", "from"), ("subject", "subject"), ("message_id", "id"), ("thread_id", "threadId"),
                      ("account", "account")]
            .compactMap { label, key in field(key).isEmpty ? nil : "- \(label): \(field(key))" }
        return try text("dispatch/standing-on", ["fields": fields.joined(separator: "\n")])
    }

    /// The message a job was handed over about. A malformed group never degrades into one representative.
    static func target(standingOnJSON: String?, facts: [String]) -> [String: Any]? {
        var raw = standingOnJSON
        let marker = "Current queue context, not a resolved action target."
        if let fact = facts.first(where: { $0.hasPrefix(marker) }) {
            guard let brace = fact.firstIndex(of: "{") else { return nil }
            raw = String(fact[brace...])
        }
        guard let raw, let o = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { return nil }
        func field(_ key: String) -> String { (o[key] as? String)?.trimmingCharacters(in: .whitespaces) ?? "" }
        var members: [[String: Any]] = []
        if let list = o["messages"] as? [Any] {
            for value in list {
                guard let m = value as? [String: Any],
                      let id = (m["id"] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty,
                      let from = (m["from"] as? String)?.trimmingCharacters(in: .whitespaces), !from.isEmpty
                else { return nil }
                members.append(["id": id, "from": from, "subject": m["subject"] as? String ?? ""])
            }
            if members.isEmpty { return nil }
        }
        let group = members.count > 1
        let from = group ? "" : members.first?["from"] as? String ?? field("from")
        guard !from.isEmpty || group else { return nil }
        var out: [String: Any] = ["account": field("account"), "threadId": field("threadId"),
            "id": group ? "" : members.first?["id"] as? String ?? field("id"), "from": from,
            "subject": members.count == 1 ? members[0]["subject"] as? String ?? "" : field("subject")]
        if group { out["messages"] = members }
        return out
    }
}
