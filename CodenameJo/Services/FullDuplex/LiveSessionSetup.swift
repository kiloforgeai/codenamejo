import Foundation

/// The Live session's function tools, prompt facts and capability answers, decided on the phone
/// from local state. The schemas are `LiveToolSchemas`, and `tools` is what a call to each runs.
enum LiveSessionSetup {
    static let onboardingOpening = "Hi! I'm Jo. I check your emails and help you get through them by doing things, not just talking about them."
    static let fastActionNames: Set<String> = ["archive_message", "mark_spam", "trash_message", "triage_next"]

    /// What this dial asks for.
    struct Request {
        var opening: SessionOpening = .none
        var onboardingRun: (mailMode: Bool, resume: Bool, opening: String)?
        var dispatch = false
        var shortcutText = false
        var shortcutRead = false
        var coachingLessons = 0
        /// The mailboxes the phone's mail cache covers.
        var cachedMailboxes: [String] = []
        /// Asked only for an email opening.
        var sequentialFeed = false
        var calendarFeedDue = false
        var feedItems = false
    }

    /// What this phone knows about the user, in place of the server's account rows.
    struct State {
        /// Reachable mailboxes and calendars of the active profile.
        var inboxes: [String] = []
        var calendars: [String] = []
        var needsReauth: [String] = []
        var unreachable: [String] = []
        var draftsOnly: (String) -> Bool = { _ in true }
        var triageScope: String?
        var notionNeedsReauth: [String] = []
        /// GitHub logins whose token GitHub still honours, and the ones it has refused.
        var githubAccounts: [String] = []
        var githubNeedsReauth: [String] = []
        /// A working Granola grant in the active profile, and the accounts whose refresh was refused.
        var granola = false
        var granolaNeedsReauth: [String] = []
        /// The active profile's Slack workspaces whose grant works, and those needing reconnecting.
        var slackWorkspaces: [String] = []
        var slackNeedsReauth: [String] = []
        /// A Notion grant of the active profile still works, so dispatch jobs get Notion's tools.
        var notion = false
        /// Google profile names, best first: the first inbox's, then the signed-in account's.
        var ownerNames: [String?] = []
        /// The profile's own MCP servers: their tools as function definitions, the names of the
        /// ones serving this call, and the ones whose credential was refused.
        var customMCPTools: [[String: Any]] = []
        var customMCPServers: [String] = []
        var customMCPNeedsReauth: [String] = []
    }

    struct Result {
        var tools: [[String: Any]]
        var fastActions: [String]
        /// The facts `LivePrompt.Facts` reads.
        var prompt: [String: Any]
        var openingMode: SessionOpening
        var sequentialFeed: Bool
        var interactiveCoaching: Bool
        var localCoachingDelivery: Bool
        var calendarFeedDue: Bool
        var feedBriefing: Bool
        /// Whether `search_recent` and `search_drafts` were declared.
        var localMail: Bool
        /// The first name the opening greets the user by; nil keeps the nameless copy.
        var greetingName: String? = nil
        /// The Slack queue is walked on this phone, and the Feed reaches it.
        var localSlackTriage = false
        var slackFeedStage = false
        var importantSlackStage = false
    }

    /// The mailboxes and calendars a schema names as connected.
    struct Accounts {
        var inboxes: [String] = []
        var calendars: [String] = []
        /// The mailboxes the phone's mail cache covers, which `search_recent` reads.
        var unread: [String] = []
    }

    /// Every schema `tools` declares, by name, and the second wording two of them have, by `name.variant`.
    struct Catalog {
        let tools: [String: (Accounts) -> [String: Any]]

        static let bundled: Catalog = {
            var schemas: [String: (Accounts) -> [String: Any]] = [
                "triage_next.onboarding_mail_mode": { _ in LiveToolSchemas.triageNextOnboardingMailMode },
                "find_person.worker": LiveToolSchemas.findPersonWorker,
            ]
            for (name, tool) in LiveSessionSetup.tools where tool.schema(Accounts()) != nil {
                schemas[name] = { tool.schema($0) ?? [:] }
            }
            return Catalog(tools: schemas)
        }()

        /// One tool for these accounts, with `note` appended to its description.
        func tool(_ key: String, _ accounts: Accounts = Accounts(), note: String = "") -> [String: Any] {
            guard var tool = tools[key]?(accounts) else { return [:] }
            if !note.isEmpty { tool["description"] = (tool["description"] as? String ?? "") + note }
            return tool
        }
    }

    /// Every Live tool by name: its schema and what a call to it runs. `runFunctionTool` looks a call
    /// up here and relays a name with no entry to `FullDuplexBroker.runTool`. The phone's Gmail and
    /// Calendar tools (`GmailReadTools`, `GmailManageTools`, `CalendarTools`) are routed before it.
    static let tools: [String: any LiveTool] = {
        let s = LiveToolSchemas.self
        let phone: [any LiveTool] = [
            PhoneTool(s.listProfiles) { $0.answerProfiles(callId: $1.id, name: $1.name, argumentsJSON: $1.arguments) },
            PhoneTool(s.switchProfile) { $0.answerProfiles(callId: $1.id, name: $1.name, argumentsJSON: $1.arguments) },
            PhoneTool(s.createProfile) { $0.runProfileManagement(callId: $1.id, name: $1.name, argumentsJSON: $1.arguments) },
            PhoneTool(s.renameProfile) { $0.runProfileManagement(callId: $1.id, name: $1.name, argumentsJSON: $1.arguments) },
            // **Neither handoff may reach `runFunctionToolBlocking`, and that is load-bearing.** Its
            // `functionCallTask?.cancel()` would kill an in-flight relay — destroying the report of an
            // irreversible write that `interrupt()` goes out of its way to preserve, and leaving the
            // model to say nothing about mail that already went.
            PhoneTool(s.dispatch) {
                $0.startDispatch(callId: $1.id, argumentsJSON: $1.arguments, requestedBackground: $1.requestedBackground)
            },
            PhoneTool(s.dispatchCommand) {
                $0.startDispatch(callId: $1.id, argumentsJSON: $1.arguments, requestedBackground: $1.requestedBackground)
            },
            // The user's own commands, kept off that cancel for the same reason: a save is a write
            // that happens whether or not the user barged in.
            PhoneTool(s.commands) { $0.answerCommands(callId: $1.id, argumentsJSON: $1.arguments) },
            PhoneTool(s.summarize) { $0.answerSummarise(callId: $1.id, argumentsJSON: $1.arguments) },
            // The three context tools, each answered on this phone out of SQLite. One handler each
            // rather than a shared router: they read differently and they write differently.
            PhoneTool(s.searchContext) { $0.answerContextSearch(callId: $1.id, argumentsJSON: $1.arguments) },
            PhoneTool(s.saveContext) { $0.answerContextSave(callId: $1.id, argumentsJSON: $1.arguments) },
            PhoneTool(s.forgetContext) { $0.answerContextForget(callId: $1.id, argumentsJSON: $1.arguments) },
            PhoneTool(s.listCalls) { client, call in client.answerListCalls(callId: call.id) },
            // The last day of this phone's mail, read or unread, searched here. **Additional to
            // `gmail_search_messages` (`GmailReadTools`), not a replacement**, which searches the
            // whole mailbox where this reads the phone's cache. Distinctly named for the reason
            // `local_search_context` recorded: offered two tools that do the same thing, the model
            // picks whichever name the prompt uses.
            PhoneTool("search_recent", s.searchRecent) { $0.answerRecentSearch(callId: $1.id, argumentsJSON: $1.arguments) },
            // Renamed from `search_unread` (2026-08-24) and still answered under the old name.
            // Nothing declares it, so no call for it can arrive and it can be dropped.
            PhoneTool("search_unread", nil) { $0.answerRecentSearch(callId: $1.id, argumentsJSON: $1.arguments) },
            // The drafts this phone already holds, additional to the whole-mailbox search the same way.
            PhoneTool("search_drafts", s.searchDrafts) { $0.answerDraftSearch(callId: $1.id, argumentsJSON: $1.arguments) },
            // No `gmail_find_person` is declared beside this — same as `triage_next`. Two resolvers
            // over one mailbox would disagree, and the model would pick by name.
            PhoneTool(s.findPerson) { $0.answerFindPerson(callId: $1.id, argumentsJSON: $1.arguments) },
            // The email queue, walked here. **The same name the old server's tool had**, and no
            // `gmail_triage_next` beside it: two queues would mean two cursors, and mail walked past twice.
            PhoneTool(s.triageNext) { $0.answerTriageNext(callId: $1.id, argumentsJSON: $1.arguments) },
            // Always a client function, so the phone can refuse an unsolicited count before it runs.
            PhoneTool("count_messages", s.countMessages) {
                $0.answerGuardedQueueCount(callId: $1.id, argumentsJSON: $1.arguments)
            },
            // Drafts and sends run on this phone (`LocalCompose`), so the receipt can carry the
            // queue's next message.
            PhoneTool("create_draft", s.createDraft) { $0.answerLocalMailWrite(callId: $1.id, argumentsJSON: $1.arguments) },
            PhoneTool("send_email", s.sendEmail) {
                $0.answerLocalMailWrite(callId: $1.id, argumentsJSON: $1.arguments, tool: $1.name)
            },
            PhoneTool("forward_email", s.forwardEmail) {
                $0.answerLocalMailWrite(callId: $1.id, argumentsJSON: $1.arguments, tool: $1.name)
            },
            PhoneTool("label_message", s.labelMessage) {
                $0.answerLocalQueueRemoval(callId: $1.id, argumentsJSON: $1.arguments,
                    tool: $1.name, successOutput: "", deed: "labelling that message",
                    say: "Say which label it was filed under", pastTense: "labelled", subsystem: "localLabel")
            },
            PhoneTool("mark_spam", s.markSpam) {
                $0.answerLocalQueueRemoval(callId: $1.id, argumentsJSON: $1.arguments,
                    tool: "mark_spam", successOutput: "Marked as spam.", deed: "marking that message as spam",
                    say: "Omit the spam receipt",
                    pastTense: "marked as spam", subsystem: "localSpam")
            },
            PhoneTool("archive_message", s.archiveMessage) { $0.answerLocalArchive(callId: $1.id, argumentsJSON: $1.arguments) },
            PhoneTool("trash_message", s.trashMessage) {
                $0.answerGuardedLocalTrash(callId: $1.id, argumentsJSON: $1.arguments)
            },
            PhoneTool(LocalCalendarWrites.respond, s.respondToCalendarEvent) {
                $0.answerLocalCalendarWrite(callId: $1.id, name: $1.name, argumentsJSON: $1.arguments)
            },
            PhoneTool(LocalCalendarWrites.cancel, s.cancelCalendarEvent) {
                $0.answerLocalCalendarWrite(callId: $1.id, name: $1.name, argumentsJSON: $1.arguments)
            },
            // The clock. The aurex server stopped offering `current_time` on 2026-08-20: answering it
            // there meant asking Google Calendar for the user's timezone, 248 ms at p50, where this is
            // a struct read.
            PhoneTool(s.currentTime) { client, call in client.answerCurrentTime(callId: call.id) },
            PhoneTool(s.webSearch) { $0.answerWebSearch(callId: $1.id, argumentsJSON: $1.arguments) },
            PhoneTool(s.setRule) { client, call in
                client.answerSettingsTool(callId: call.id, tool: call.name) {
                    (StandingRuleTool.run(argumentsJSON: call.arguments), false)
                }
            },
            PhoneTool(s.feedItems) { client, call in
                client.answerSettingsTool(callId: call.id, tool: call.name) { (FeedItems.run(argumentsJSON: call.arguments), false) }
            },
            PhoneTool(s.coachCapability) { client, call in
                client.answerSettingsTool(callId: call.id, tool: call.name) { CoachingRotation.run(argumentsJSON: call.arguments) }
            },
            PhoneTool(s.sendText) { $0.answerSendText(callId: $1.id, argumentsJSON: $1.arguments) },
            PhoneTool(s.readTexts) { $0.answerReadTexts(callId: $1.id, argumentsJSON: $1.arguments) },
            PhoneTool(s.findContact) { $0.answerFindContact(callId: $1.id, argumentsJSON: $1.arguments) },
            // Hanging up, kept off that cancel too: the farewell this arms is the last thing the user
            // hears, and a cancel between the tool result and the goodbye would end the call in silence.
            PhoneTool(s.endSession) { $0.answerEndSession(callId: $1.id, argumentsJSON: $1.arguments) },
            PhoneTool(s.stopListening) { client, call in client.answerStopListening(callId: call.id) },
        ]
        // The Slack queue and its tools, run here on the user's own Slack token while it is up.
        let slack: [any LiveTool] = LiveToolSchemas.slack.map {
            PhoneTool($0) { client, call in
                guard client.slackOnDevice else { return client.runUnregisteredTool(call) }
                if call.name == SlackTools.queueName {
                    client.answerSlackTriageNext(callId: call.id, argumentsJSON: call.arguments)
                } else if LocalSlackQueue.finishingTools.contains(call.name) {
                    client.answerLocalSlackWrite(callId: call.id, name: call.name, argumentsJSON: call.arguments)
                } else if LocalSlackQueue.readTools.contains(call.name) {
                    client.answerLocalSlackRead(callId: call.id, name: call.name, argumentsJSON: call.arguments)
                } else {
                    client.runUnregisteredTool(call)
                }
            }
        }
        let connectors: [any LiveTool] = (LiveToolSchemas.github + LiveToolSchemas.granola + LiveToolSchemas.notion)
            .map { ConnectorTool($0) }
        return Dictionary(uniqueKeysWithValues: (phone + slack + connectors).map { ($0.name, $0) })
    }()

    private static let queueNote = " The result may carry the already-advanced queue. Follow it and do not call triage_next afterwards."
    /// Notion's tools are the second agent's alone, so every Notion ask is a dispatch.
    static let notionDispatchNote = " Notion is the exception: only the second agent has it, so anything in their Notion — "
        + "finding or reading a page or database, filing a note, marking something done — goes here, even a single lookup."

    static func resolve(_ request: Request, _ state: State, catalog: Catalog) -> Result {
        let inboxes = state.inboxes, calendars = state.calendars
        let fiveStep = request.onboardingRun != nil
        let onboardingMailMode = request.onboardingRun?.mailMode == true
        let unreadAccounts = request.cachedMailboxes.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let cacheServesMailbox = mailboxSetsMatch(inboxes, unreadAccounts)
        let opening: SessionOpening = fiveStep ? .emailQueue
            : request.opening.leadsWithFeed && !inboxes.isEmpty ? request.opening
            : request.opening == .onboarding ? .onboarding : .none
        let sequentialFeed = request.sequentialFeed && opening.leadsWithFeed
        let interactiveCoaching = opening.leadsWithFeed
        let localCoachingDelivery = interactiveCoaching
        let calendarFeedDue = sequentialFeed && request.calendarFeedDue && !calendars.isEmpty

        let accounts = Accounts(inboxes: inboxes, calendars: calendars, unread: unreadAccounts)
        var tools: [[String: Any]] = []
        func add(_ key: String, note: String = "") { tools.append(catalog.tool(key, accounts, note: note)) }
        if request.dispatch { add("dispatch", note: state.notion ? notionDispatchNote : "") }
        if cacheServesMailbox {
            add("search_recent")
            add("search_drafts")
        }
        if !calendars.isEmpty {
            add("respond_to_calendar_event")
            add("cancel_calendar_event")
        }
        add("find_person")
        if !inboxes.isEmpty {
            add("create_draft")
            add("send_email", note: queueNote)
            add("forward_email", note: queueNote)
            add("count_messages")
            add("archive_message", note: " In this device-owned queue, call without speaking first. The result "
                + "confirms the archive and carries the already-advanced queue. Follow it and do not call triage_next afterwards.")
            add("label_message", note: queueNote)
            add("mark_spam", note: " In this device-owned queue, call without speaking first. "
                + "Target only a specifically selected message; ask which member if a grouped item is ambiguous. "
                + "A successful result accepts the action and may carry the already-advanced queue. "
                + "Present it without a spam receipt and do not call triage_next afterwards.")
            add("trash_message", note: " In this device-owned queue, deletion is authorized against the user's "
                + "latest completed words before the write runs. Never use this as a fallback for archive_message or ambiguous audio.")
        }
        add(onboardingMailMode ? "triage_next.onboarding_mail_mode" : "triage_next")
        add("current_time")
        // Dispatch owns web research in a permission-first coaching session.
        if !(interactiveCoaching && request.dispatch) { add("web_search") }
        add("set_rule")
        add("feed_items")
        if localCoachingDelivery { add("coach_capability") }
        for name in ["list_profiles", "switch_profile", "create_profile", "rename_profile",
                     "search_context", "list_calls", "save_context", "forget_context", "end_session", "stop_listening"] {
            add(name)
        }
        if request.shortcutText { add("send_text") }
        if request.shortcutRead { add("read_texts") }
        add("find_contact")
        if state.granola { GranolaTools.names.forEach { add($0) } }
        let slack = !state.slackWorkspaces.isEmpty
        if slack { SlackTools.catalogOrder.forEach { add($0) } }
        tools += GitHubTools.definitions(logins: state.githubAccounts, catalog: catalog)
        tools += state.customMCPTools

        var prompt: [String: Any] = [
            "skills": (inboxes.isEmpty ? [] : ["email"]) + (calendars.isEmpty ? [] : ["calendar"])
                + (slack ? ["slack"] : []) + (state.granola ? ["granola"] : [])
                + (state.githubAccounts.isEmpty ? [] : ["github"]),
            "memory": true, "profiles": true, "profileManagement": true,
            "calendarAccounts": calendars, "localClock": true,
            "sequentialOpening": !fiveStep && opening == .emailQueue && sequentialFeed,
            "localCoachingDelivery": localCoachingDelivery, "localTriage": true,
            "noDeviceMail": !cacheServesMailbox, "calendar": !calendars.isEmpty,
            "dispatch": request.dispatch, "emailLinkDispatch": true, "endSession": true,
            "onboardingMailMode": onboardingMailMode, "mailModeSwitching": true,
            "drafting": inboxes.filter(state.draftsOnly), "sending": inboxes.filter { !state.draftsOnly($0) },
            "googleNeedsReauth": state.needsReauth, "googleUnreachable": state.unreachable,
            "notionNeedsReauth": state.notionNeedsReauth,
            "githubNeedsReauth": state.githubNeedsReauth,
        ]
        if let run = request.onboardingRun {
            let configured = String(run.opening.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
            prompt["fiveStepOnboarding"] = ["resume": run.resume, "opening": run.resume
                ? EmailOnboardingContract.resumeLine : configured.isEmpty ? onboardingOpening : configured]
        }
        if !state.granolaNeedsReauth.isEmpty { prompt["granolaNeedsReauth"] = state.granolaNeedsReauth }
        if !state.customMCPServers.isEmpty { prompt["customMCP"] = state.customMCPServers }
        if !state.customMCPNeedsReauth.isEmpty { prompt["customMCPNeedsReauth"] = state.customMCPNeedsReauth }
        if slack {
            prompt["localSlackTriage"] = true
            prompt["slackFeedStage"] = sequentialFeed
            prompt["importantSlackStage"] = sequentialFeed
        }
        if !state.slackNeedsReauth.isEmpty { prompt["slackNeedsReauth"] = state.slackNeedsReauth }
        if opening == .feedOffer, sequentialFeed { prompt["feedOffer"] = true }
        if interactiveCoaching { prompt["coaching"] = request.coachingLessons > 0 ? "lessons" : "none" }
        if let scope = state.triageScope, TriageScope(rawValue: scope) != nil { prompt["triageScope"] = scope }

        var result = Result(
            tools: tools,
            fastActions: tools.compactMap { $0["name"] as? String }.filter(fastActionNames.contains),
            prompt: prompt, openingMode: opening, sequentialFeed: sequentialFeed,
            interactiveCoaching: interactiveCoaching, localCoachingDelivery: localCoachingDelivery,
            calendarFeedDue: calendarFeedDue,
            feedBriefing: request.feedItems && opening.leadsWithFeed && !fiveStep,
            localMail: cacheServesMailbox,
            greetingName: greetingFirstName(state.ownerNames))
        result.localSlackTriage = slack
        result.slackFeedStage = slack && sequentialFeed
        result.importantSlackStage = slack && sequentialFeed
        return result
    }

    /// The user's saved commands on a finished tool list: `commands` and `summarize` always,
    /// `dispatch_command` when dispatch is on and there is a command to dispatch. Apart from
    /// `resolve` so its server parity holds; called once every other tool is on the list, because
    /// a step may name any allowed tool this session has. `keywords` include switched-off ones —
    /// the list is frozen at dial and `commands` can switch one on mid-call; the phone refuses a
    /// switched-off one when it runs.
    static func addingCommands(to tools: [[String: Any]], keywords: [String], dispatch: Bool,
                               catalog: Catalog) -> [[String: Any]] {
        let names = tools.compactMap { $0["name"] as? String }
        var commands = catalog.tool("commands")
        if var parameters = commands["parameters"] as? [String: Any],
           var properties = parameters["properties"] as? [String: Any],
           var actions = properties["actions"] as? [String: Any],
           var items = actions["items"] as? [String: Any],
           var stepProperties = items["properties"] as? [String: Any],
           var tool = stepProperties["tool"] as? [String: Any] {
            tool["enum"] = CustomCommandRules.allowedNames(in: names)
            stepProperties["tool"] = tool; items["properties"] = stepProperties; actions["items"] = items
            properties["actions"] = actions; parameters["properties"] = properties; commands["parameters"] = parameters
        }
        var out = tools + [commands, catalog.tool("summarize")]
        guard dispatch, !keywords.isEmpty, names.contains("dispatch") else { return out }
        var dispatchCommand = catalog.tool("dispatch_command")
        if var parameters = dispatchCommand["parameters"] as? [String: Any],
           var properties = parameters["properties"] as? [String: Any],
           var command = properties["command"] as? [String: Any] {
            command["enum"] = keywords
            properties["command"] = command; parameters["properties"] = properties
            dispatchCommand["parameters"] = parameters
        }
        if let index = out.firstIndex(where: { $0["name"] as? String == "dispatch" }) {
            out[index]["description"] = (out[index]["description"] as? String ?? "") + dispatchCommandNote
        }
        return out + [dispatchCommand]
    }

    /// The same three tools rebuilt on a live call's list after a command is saved, deleted or
    /// switched, so a keyword saved mid-call can be dispatched by name on the very next turn.
    static func refreshingCommands(in tools: [[String: Any]], keywords: [String],
                                   catalog: Catalog) -> [[String: Any]] {
        let ours: Set<String> = ["commands", "summarize", "dispatch_command"]
        let base = tools.filter { !ours.contains($0["name"] as? String ?? "") }.map { tool -> [String: Any] in
            guard tool["name"] as? String == "dispatch", let description = tool["description"] as? String,
                  description.hasSuffix(dispatchCommandNote) else { return tool }
            var plain = tool
            plain["description"] = String(description.dropLast(dispatchCommandNote.count))
            return plain
        }
        return addingCommands(to: base, keywords: keywords, dispatch: true, catalog: catalog)
    }

    static let dispatchCommandNote = " Saved commands use the separate `dispatch_command` tool. Never put a "
        + "saved-command request in `task`, even as a complete paraphrase."

    /// The first candidate that reads as a human first name, or nil. Fails closed: an address,
    /// a phone number or anything unreadable keeps the nameless greeting.
    static func greetingFirstName(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            let full = (candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if full.isEmpty || full.contains("@")
                || full.allSatisfy({ $0.isNumber || " +()-.".contains($0) }) { continue }
            // `Finn, Huckleberry` is a sorted display name, so the given name is after the comma.
            let given = full.contains(",") ? String(full[full.index(after: full.firstIndex(of: ",")!)...]) : full
            let first = given.trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            let name = String(first.drop { !$0.isLetter }.reversed().drop { !$0.isLetter && $0 != "'" && $0 != "-" }.reversed())
            guard (2...20).contains(name.count),
                  name.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else { continue }
            return name
        }
        return nil
    }

    /// The mail and calendar writes a dispatched job may call, Notion's tools when the job's
    /// profile has a working grant, and the connectors the live call has — Granola, Slack, GitHub
    /// and the profile's own MCP servers — so a job or a saved command can reach every tool the
    /// user can. No cancel and no Slack queue: both stay with the live call.
    static func workerTools(inboxes: [String], calendars: [String], draftsOnly: (String) -> Bool,
                            notion: Bool = false, granola: Bool = false, slack: Bool = false,
                            githubAccounts: [String] = [], customMCPTools: [[String: Any]] = [],
                            catalog: Catalog) -> [[String: Any]] {
        let accounts = Accounts(inboxes: inboxes, calendars: calendars)
        let sends = inboxes.contains { !draftsOnly($0) }
        let mail = ["count_messages", "find_person.worker", "create_draft", "archive_message", "trash_message",
                    "label_message", "mark_spam"] + (sends ? ["send_email"] : []) + ["forward_email"]
        return (inboxes.isEmpty ? [] : mail.map { catalog.tool($0, accounts) })
            + (calendars.isEmpty ? [] : [catalog.tool("respond_to_calendar_event", accounts)])
            + (notion ? NotionTools.names.map { catalog.tool($0) } : [])
            + (granola ? GranolaTools.names.map { catalog.tool($0) } : [])
            + (slack ? SlackTools.catalogOrder.filter { $0 != SlackTools.queueName }.map { catalog.tool($0) } : [])
            + GitHubTools.definitions(logins: githubAccounts, catalog: catalog)
            + customMCPTools
    }

    /// Whether the mail cache covers exactly the mailboxes being served: a missing one would make a
    /// partial answer sound complete, an extra one is the account-switch race.
    static func mailboxSetsMatch(_ served: [String], _ cached: [String]) -> Bool {
        func normalized(_ values: [String]) -> Set<String> {
            Set(values.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        }
        let servedSet = normalized(served)
        return !servedSet.isEmpty && servedSet == normalized(cached)
    }
}
