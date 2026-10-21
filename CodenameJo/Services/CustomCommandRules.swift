import Foundation

/// What a saved command may be: its keyword, its steps, and whether a background run owes an
/// answer or a receipt. Pure functions, so the store and the tests share one boundary.
///
/// These checks ran on the server until 2026-10-11; they are the phone's now, with the same
/// order and the same refusal sentences. Every refusal is a sentence the model speaks, because
/// it is the user's phrasing that has to change, not something that failed.
enum CustomCommandRules {
    /// A phrase is a fine trigger — "candidate screen" — but a sentence is a description, and
    /// storing one leaves the user with something they cannot say back.
    static let keywordMaxWords = 4

    /// Lowercased, trimmed, inner runs of whitespace collapsed. One function for every writer
    /// and every reader, so a keyword is never unmatchable by the thing that stored it.
    static func normalise(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Return only the named command; unrelated steps must never enter a run's context.
    static func run(keyword raw: String, commands: [CustomCommand]) -> Result<String, Refusal> {
        let keyword = normalise(raw)
        guard !keyword.isEmpty else {
            return .failure(Refusal("Specify the saved command's exact keyword. No command was run."))
        }
        guard let command = commands.first(where: { $0.keyword == keyword }) else {
            return .failure(Refusal("There is no saved command called \"\(keyword)\". No command was run. Do not guess another command."))
        }
        guard command.enabled else {
            return .failure(Refusal("\"\(keyword)\" is switched off. No command was run."))
        }
        guard !command.actions.isEmpty else {
            return .failure(Refusal("\"\(keyword)\" has no steps. No command was run."))
        }
        let steps = command.actions.enumerated().map { "  \($0.offset + 1). \($0.element.line)" }
            .joined(separator: "\n")
        return .success("The saved command \"\(keyword)\". The numbered steps are the only instructions — "
            + "do those, in order, and nothing else. Saying the keyword was the user's yes: run every step "
            + "without reading it back or waiting for a confirming turn, then say what each one did. "
            + "Keep the original email IDs and account for all steps about that email, even if an earlier "
            + "step advances the queue. Never apply a remaining step to the next email.\n" + steps)
    }

    // MARK: - Steps

    /// **Every tool, labelled with whether a command may use it as a step.** Not a safety gate
    /// — confirmation belongs on the tools themselves — but the switchboard: a tool that is not
    /// in this table is not allowed, so a new capability is off until somebody decides otherwise.
    /// Custom MCP tools (`mcp_…`) are allowed by prefix, since their names are the user's own.
    static let tools: [String: Bool] = [
        // Mail
        "search_recent": true, "search_drafts": true, "count_messages": true,
        GmailReadTools.search: true, GmailReadTools.getMessage: true, GmailReadTools.getThread: true,
        GmailReadTools.readAttachment: true,
        "archive_message": true, "trash_message": true, "label_message": true, "mark_spam": true,
        "create_draft": true, "send_email": true, "forward_email": true,
        GmailManageTools.listLabels: true, GmailManageTools.renameLabel: true, GmailManageTools.deleteLabel: true,
        GmailManageTools.unlabel: true, GmailManageTools.unarchive: true, GmailManageTools.modifyMatching: true,
        GmailManageTools.unsubscribe: true, GmailManageTools.sendDraft: true, GmailManageTools.deleteDraft: true,
        GmailManageTools.listFilters: true, GmailManageTools.createFilter: true, GmailManageTools.deleteFilter: true,
        // Resolves a name to an address. The model reaches for it as an unasked hedge, which a
        // saved command then runs every time; it stays available in conversation.
        "find_person": false,
        // Moves the queue cursor, which a replayed command must not do.
        "triage_next": false,

        // Calendar
        CalendarTools.list: true, CalendarTools.create: true, CalendarTools.update: true,
        "respond_to_calendar_event": true, "cancel_calendar_event": true,

        // The web, and the memory reads
        "web_search": true, "search_context": true, "list_calls": true,
        // Bookkeeping the assistant does for itself.
        "save_context": false, "forget_context": false,

        // Slack
        "slack_read_channel": true, "slack_read_thread": true, "slack_search_public_and_private": true,
        "slack_search_channels": true, "slack_search_users": true, "slack_read_user_profile": true,
        "slack_list_channel_members": true, "slack_send_message": true, "slack_add_reaction": true,
        "slack_schedule_message": true, "slack_mark_read": true, "slack_mark_unread": true,
        SlackTools.queueName: false,

        // Granola
        "granola_list_meetings": true, "granola_get_meeting": true, "granola_action_items": true,

        // GitHub
        "github_get_me": true, "github_search_repositories": true, "github_list_pull_requests": true,
        "github_pull_request_read": true, "github_search_pull_requests": true, "github_list_issues": true,
        "github_issue_read": true, "github_search_issues": true, "github_list_commits": true,
        "github_get_commit": true, "github_get_file_contents": true, "github_search_code": true,
        "github_actions_list": true, "github_actions_get": true, "github_get_job_logs": true,
        "github_list_notifications": true, "github_get_notification_details": true, "github_list_label": true,
        "github_merge_pull_request": true, "github_issue_write": true, "github_add_issue_comment": true,
        "github_update_pull_request": true, "github_actions_run_trigger": true,

        // A step that switches a rule switches it again on every run, including back on.
        "set_rule": false,
        // Each would change something every time the keyword is said.
        "feed_items": false, "coach_capability": false,
        "switch_profile": false, "create_profile": false, "rename_profile": false,
        "end_session": false, "stop_listening": false,
        // A command that edits, lists or runs commands can rewrite or invoke itself.
        "commands": false, "dispatch": false, "dispatch_command": false,

        // Saying the answer: the last step of nearly every command.
        "summarize": true,
    ]

    static func allows(_ tool: String) -> Bool {
        tools[tool] ?? tool.hasPrefix(CustomMCPTools.prefix)
    }

    /// The step `enum`: every allowed tool, plus this session's own custom MCP tools.
    ///
    /// **Not narrowed to the tools this call happens to have.** Which tools a call gets depends on
    /// how it opened — an inbox opening with coaching leaves `web_search` to dispatch — and a
    /// command outlives the call it was dictated in. Narrowing made "look the company up on the
    /// web" unsavable in exactly those calls. A step this call lacks fails when it runs, honestly.
    static func allowedNames(in sessionTools: [String]) -> [String] {
        var seen = Set<String>()
        let custom = sessionTools.filter { $0.hasPrefix(CustomMCPTools.prefix) && seen.insert($0).inserted }
        return tools.filter(\.value).keys.sorted() + custom
    }

    /// Writes whose useful result is only confirmation that they landed. A background run is a
    /// receipt only when **every** step is one of these; reads, `summarize`, mixed workflows and
    /// custom MCP tools fail toward an answer, because reading too much is recoverable and
    /// collapsing requested information to "finished" is not.
    static let receiptTools: Set<String> = [
        "archive_message", "trash_message", "label_message", "mark_spam",
        "create_draft", "send_email", "forward_email",
        GmailManageTools.renameLabel, GmailManageTools.deleteLabel, GmailManageTools.unlabel,
        GmailManageTools.unarchive, GmailManageTools.modifyMatching, GmailManageTools.unsubscribe,
        GmailManageTools.sendDraft, GmailManageTools.deleteDraft,
        GmailManageTools.createFilter, GmailManageTools.deleteFilter,
        CalendarTools.create, CalendarTools.update, "respond_to_calendar_event", "cancel_calendar_event",
        "slack_send_message", "slack_add_reaction", "slack_schedule_message", "slack_mark_read", "slack_mark_unread",
        "github_merge_pull_request", "github_issue_write", "github_add_issue_comment",
        "github_update_pull_request", "github_actions_run_trigger",
    ]

    static func dispatchExpects(_ actions: [CommandAction]) -> LocalTriageQueue.Outcome.Shape {
        !actions.isEmpty && actions.allSatisfy { receiptTools.contains($0.tool.lowercased()) } ? .receipt : .answer
    }

    /// Keep the steps that say something. A step **shaped** wrong (no tool) is dropped — a
    /// command worth having with two of its three steps should not be lost over the third. A
    /// step naming a tool a command may not call is **refused by name**: dropping it would save
    /// a command that does less than the user was told.
    static func clean(_ actions: [CommandAction]) -> Result<[CommandAction], Refusal> {
        var steps: [CommandAction] = []
        for action in actions {
            let tool = action.tool.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tool.isEmpty else { continue }
            guard allows(tool) else {
                return .failure(Refusal("A command can't \(describe(tool)) as one of its steps. Leave that step "
                    + "out and save the rest, or tell the user to ask for it in the moment instead."))
            }
            steps.append(CommandAction(tool: tool, detail: action.detail.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return .success(steps)
    }

    /// The offending step in words: the model says this out loud, and a tool name is an id.
    private static func describe(_ tool: String) -> String {
        if tool.contains("triage") { return "walk the queue" }
        if tool.contains("command") || tool.hasPrefix("dispatch") { return "change your commands" }
        if tool.contains("context") { return "manage its own memory" }
        return "do that"
    }

    // MARK: - Keywords

    /// Phrases the assistant already answers to. A command named for one would quietly stop the
    /// built-in from working — and the hang-up phrases are swallowed by `SpokenCommand` before the
    /// model hears them, so a command named for one could never run. Stored apostrophe-free.
    static let reserved: Set<String> = [
        "dispatch", "next", "next one", "skip", "go back", "back", "stop", "commute mode", "recap",
        "summary", "mute", "end", "add to inbox", "go", "move on",
        "end session", "end the session", "end call", "end the call", "end chat", "end the chat",
        "end conversation", "end the conversation", "hang up", "hang up the call", "goodbye",
        "im done", "i am done", "im done with the call", "im done with the chat", "thats all for now",
        "stop listening", "thats enough", "that is enough", "enough",
        "check my email", "check my mail", "check my inbox", "archive", "archive it", "unsubscribe",
        "help", "tutorial",
    ]

    static func isReserved(_ keyword: String) -> Bool {
        reserved.contains(keyword.replacingOccurrences(of: "['\u{2019}\u{02BC}]", with: "", options: .regularExpression))
    }

    struct Refusal: Error, Equatable {
        let sentence: String
        init(_ sentence: String) { self.sentence = sentence }
    }

    /// A save's keyword and steps, checked in the order the server checked them. On success the
    /// keyword is normalised and the steps cleaned.
    static func validateSave(keyword raw: String, actions: [CommandAction])
        -> Result<(keyword: String, actions: [CommandAction]), Refusal> {
        let keyword = normalise(raw)
        let cleaned: [CommandAction]
        switch clean(actions) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let steps): cleaned = steps
        }
        if keyword.isEmpty { return .failure(Refusal("A command needs a keyword to answer to.")) }
        let words = keyword.split(separator: " ")
        if words.count > keywordMaxWords {
            return .failure(Refusal("A command keyword can be up to \(keywordMaxWords) words, and \"\(keyword)\" is "
                + "\(words.count). Suggest a shorter word or phrase for it — \"\(words.suffix(2).joined(separator: " "))\" "
                + "would work — and save it again once they agree."))
        }
        if cleaned.isEmpty {
            return .failure(Refusal("\"\(raw.trimmingCharacters(in: .whitespacesAndNewlines))\" has no steps. Say what it "
                + "should actually do — which tools to call, in order — and save it again."))
        }
        if isReserved(keyword) {
            return .failure(Refusal("\"\(keyword)\" is already how the user asks for something built in, so it "
                + "can't be a command. Suggest another word or phrase."))
        }
        return .success((keyword, cleaned))
    }
}
