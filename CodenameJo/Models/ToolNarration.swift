import Foundation

/// What the assistant shows while a tool runs: one table feeds the step row and the Live Activity
/// detail line. A new connector isn't done until its tool names are in the table.
enum ToolNarration {

    /// Present tense for the running row, past tense for the finished one.
    private struct Phrasing {
        let present: String
        let past: String
    }

    /// Keyed on the tools' wire names, verbatim; a typo silently falls back to the wire name.
    /// Each phrasing is what a person would say, not what the tool is called.
    private static let table: [String: Phrasing] = [
        // The context tools are deliberately not phrased here: `fallback` already reads them right.
        // Gmail
        "search_messages": Phrasing(present: "checking your inbox", past: "searched your inbox"),
        // Answered from the phone's mail cache; phrased like `search_messages` because the user
        // doesn't care which store answered.
        "search_recent": Phrasing(present: "checking your inbox", past: "checked your inbox"),
        // Answered on the phone out of its own drafts cache — see `DraftSearch`.
        "search_drafts": Phrasing(present: "checking your drafts", past: "checked your drafts"),
        "count_messages": Phrasing(present: "counting", past: "counted your mail"),
        "current_time": Phrasing(present: "checking the time", past: "checked the time"),
        "get_message": Phrasing(present: "reading it", past: "read the message"),
        "get_thread": Phrasing(present: "reading the thread", past: "read the thread"),
        // No filename: the step row is one clause wide.
        "read_attachment": Phrasing(present: "reading the attachment", past: "read the attachment"),
        // Resolving a name into an address before composing. Kept short because it runs in front of
        // what the user asked for.
        "find_person": Phrasing(present: "finding their address", past: "found their address"),
        "create_draft": Phrasing(present: "writing that up", past: "saved a draft"),
        "send_email": Phrasing(present: "sending", past: "sent it"),
        // A phone-executed Apple Shortcut rather than a Gmail write. The wording stays
        // about the user's action; the step's icon is what distinguishes the transport.
        "send_text": Phrasing(present: "sending the text", past: "handed it to Messages"),
        "read_texts": Phrasing(present: "reading your texts", past: "read your texts"),
        "find_contact": Phrasing(present: "looking them up in Contacts", past: "found them in Contacts"),
        // Puts an existing draft out as written, phrased apart from `send_email` so the row says
        // which.
        "send_draft": Phrasing(present: "sending your draft", past: "sent your draft"),
        // The original message with its attachments, not a retyped copy.
        "forward_email": Phrasing(present: "forwarding", past: "forwarded it"),
        "archive_message": Phrasing(present: "archiving", past: "archived it"),
        "trash_message": Phrasing(present: "deleting it", past: "deleted it"),
        // The undo of the line above. Not in `FullDuplexVoiceClient.answersBeforeActing`: a
        // correction is spoken from the receipt.
        "unarchive_message": Phrasing(present: "putting it back", past: "put it back"),
        "label_message": Phrasing(present: "labelling it", past: "labelled it"),
        // Gmail's Report spam. Not "reporting it", which reads as a report filed with us.
        "mark_spam": Phrasing(present: "marking it spam", past: "marked it spam"),
        // One call that unsubscribes, writes a rule and clears the backlog, named for the
        // unsubscribe. The spoken reply says which of its outcomes happened.
        "unsubscribe_sender": Phrasing(present: "unsubscribing", past: "unsubscribed"),
        // A standing rule, not this message: the user said "from now on", not "filter".
        "create_mailbox_filter": Phrasing(present: "setting up the rule", past: "set up the rule"),
        // The name this tool had before it was renamed to say what it acts on, kept so a
        // step recorded under the old name does not read "create filter".
        "create_filter": Phrasing(present: "setting up the rule", past: "set up the rule"),
        // Switching one of the three filing rules, or reading them back. Phrased like
        // `create_mailbox_filter`; the icon tells the two apart.
        "set_rule": Phrasing(present: "changing your rules", past: "changed your rules"),
        // The email queue (`canonical()` strips `gmail_`). The table never sees arguments, so the
        // phrasing fits starting, next, skip and back alike.
        "triage_next": Phrasing(present: "getting the next one", past: "moved on"),
        // Separate from `triage_next`: preparing the opening snapshot doesn't move the queue, so it
        // must never inherit that tool's completed label.
        "prepare_email_queue": Phrasing(
            present: "Loading personalized queue…", past: "Personalized queue ready"),
        // Calendar
        "list_calendar_events": Phrasing(present: "checking your calendar", past: "checked your calendar"),
        // Answered from the phone's calendar cache (`CalendarSearch`); phrased like
        // `list_calendar_events`.
        "search_calendar": Phrasing(present: "checking your calendar", past: "checked your calendar"),
        "create_calendar_event": Phrasing(present: "adding it", past: "added the event"),
        // One row for accept, decline and tentative: the table never sees the arguments.
        "respond_to_calendar_event": Phrasing(present: "answering the invite", past: "answered the invite"),
        // One row for every kind of edit, for the same reason.
        "update_calendar_event": Phrasing(present: "updating the event", past: "updated the event"),
        // "Cancelling", not "deleting": every guest gets a cancellation, and it can't be taken
        // back.
        "cancel_calendar_event": Phrasing(present: "cancelling the event", past: "cancelled the event"),
        // Notion — the hosted MCP's own hyphenated names, phrased as notes and pages rather than
        // "Notion".
        "notion-search": Phrasing(present: "looking through your notes", past: "searched your notes"),
        "notion-fetch": Phrasing(present: "reading the page", past: "read the page"),
        "notion-query-data-sources": Phrasing(present: "reading the database", past: "read your database"),
        "notion-create-pages": Phrasing(present: "writing the note", past: "wrote the note"),
        "notion-update-page": Phrasing(present: "updating it", past: "updated it"),
        "notion-get-comments": Phrasing(present: "reading the comments", past: "read the comments"),
        "notion-create-comment": Phrasing(present: "leaving a comment", past: "left a comment"),
        "notion-list-recent-pages": Phrasing(present: "checking what's recent", past: "checked your recent pages"),
        // No phrasing for `notion-get-async-task`: it polls work already narrated.
        // Granola. Our names; the phone relays them to Granola's MCP.
        "granola_list_meetings": Phrasing(present: "checking your meetings", past: "checked your meetings"),
        "granola_get_meeting": Phrasing(present: "reading the meeting notes", past: "read the meeting notes"),
        "granola_action_items": Phrasing(present: "collecting the action items", past: "collected the action items"),
        // GitHub. Vendor-hosted, so these names belong to GitHub's MCP server.
        "get_me": Phrasing(present: "checking your account", past: "found your account"),
        // Resolves a spoken repo name into owner/name before the read the user asked for; kept
        // short.
        "search_repositories": Phrasing(present: "finding the repo", past: "found the repo"),
        // GitHub reads are one tool per entity with a `method` argument the frame doesn't carry, so
        // one clause covers the diff, the reviews and the checks alike.
        "list_pull_requests": Phrasing(present: "checking your pull requests", past: "checked your pull requests"),
        "search_pull_requests": Phrasing(present: "looking for pull requests", past: "searched pull requests"),
        "pull_request_read": Phrasing(present: "reading the pull request", past: "read the pull request"),
        "list_issues": Phrasing(present: "checking issues", past: "checked issues"),
        "search_issues": Phrasing(present: "looking for issues", past: "searched issues"),
        "issue_read": Phrasing(present: "reading the issue", past: "read the issue"),
        "list_label": Phrasing(present: "checking the labels", past: "checked the labels"),
        "list_notifications": Phrasing(present: "checking what needs you", past: "checked your notifications"),
        "get_notification_details": Phrasing(present: "opening the notification", past: "read the notification"),
        "actions_list": Phrasing(present: "checking CI", past: "checked CI"),
        "actions_get": Phrasing(present: "checking that run", past: "checked the run"),
        "get_job_logs": Phrasing(present: "reading the logs", past: "read the logs"),
        "list_commits": Phrasing(present: "checking commits", past: "checked commits"),
        "get_commit": Phrasing(present: "reading the commit", past: "read the commit"),
        "get_file_contents": Phrasing(present: "reading the file", past: "read the file"),
        "search_code": Phrasing(present: "searching the code", past: "searched the code"),
        // The GitHub writes, present tense because the write is running. The frame doesn't carry
        // the method, so each is phrased for its common case; the spoken reply names what happened.
        "merge_pull_request": Phrasing(present: "merging", past: "merged it"),
        "issue_write": Phrasing(present: "filing the issue", past: "filed the issue"),
        "add_issue_comment": Phrasing(present: "adding the comment", past: "added the comment"),
        "actions_run_trigger": Phrasing(present: "starting the run", past: "started the run"),
        "update_pull_request": Phrasing(present: "updating the pull request", past: "updated the pull request"),
        // Slack. Nothing says "in Slack": the hash glyph on the step row does.
        "slack_triage_next": Phrasing(present: "checking your Slack", past: "checked your Slack"),
        "slack_read_channel": Phrasing(present: "catching up on the channel", past: "caught up on the channel"),
        "slack_read_thread": Phrasing(present: "catching up on the thread", past: "caught up on the thread"),
        "slack_search_public_and_private": Phrasing(present: "searching Slack", past: "searched Slack"),
        "slack_search_channels": Phrasing(present: "finding the channel", past: "found the channel"),
        "slack_search_users": Phrasing(present: "looking them up", past: "found them"),
        "slack_read_user_profile": Phrasing(present: "checking who that is", past: "checked who that is"),
        "slack_list_channel_members": Phrasing(present: "checking who's in there", past: "checked who's in there"),
        "slack_send_message": Phrasing(present: "posting it", past: "posted it"),
        "slack_add_reaction": Phrasing(present: "reacting to it", past: "reacted to it"),
        "slack_schedule_message": Phrasing(present: "scheduling it", past: "scheduled it"),
        "slack_mark_read": Phrasing(present: "marking it read", past: "marked it read"),
        "slack_mark_unread": Phrasing(present: "putting it back to unread", past: "put it back to unread"),
        // Hands a whole job to a second agent, phrased for what the user asked for. The step
        // doesn't span the wait: `RealtimeService` clears `turnSteps` on the next user turn.
        "dispatch": Phrasing(present: "working on that", past: "finished looking"),
        // Searching the web, on the phone (`WebSearchTool`) or in a dispatched job; both arrive as
        // `web_search`.
        "web_search": Phrasing(present: "searching the web", past: "searched the web"),
        // Hanging up at the model's request; a visible step, so a claimed hang-up is provably asked
        // for.
        "end_session": Phrasing(present: "ending the call", past: "ending the call"),
        "stop_listening": Phrasing(present: "muting", past: "muted"),
        "commands": Phrasing(present: "checking your commands", past: "checked your commands"),
        "summarize": Phrasing(present: "summing up", past: "summed up"),
        "dispatch_command": Phrasing(present: "running your command", past: "ran your command"),
    ]

    /// The clause spoken while the tool runs, and the label on the running row.
    static func progressLabel(for tool: String) -> String {
        // A user's own tool reads as its bare name: one called `search_messages` is not our inbox search.
        if CustomMCPTools.isCustomTool(tool) { return fallback(tool) }
        return table[canonical(tool)]?.present ?? fallback(tool)
    }

    /// The label once the step has closed.
    static func doneLabel(for tool: String) -> String {
        if CustomMCPTools.isCustomTool(tool) { return fallback(tool) }
        return table[canonical(tool)]?.past ?? fallback(tool)
    }

    /// Did this tool answer with a refusal? Refused calls still complete, so the phone's write
    /// tools open with `NOT SENT — …`; markers are ones a success receipt never opens with.
    static func isRefusal(_ output: String) -> Bool {
        let head = output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)
        let lowered = head.lowercased()
        if lowered.hasPrefix("not ") { return true }          // NOT SENT, NOT SAVED, …
        if lowered.hasPrefix("no ") { return true }           // "No subject — …"
        if lowered.hasPrefix("couldn't") || lowered.hasPrefix("could not") { return true }
        if lowered.hasPrefix("there is no") { return true }
        if lowered.hasPrefix("a command can't") { return true }
        return false
    }

    /// Which service a step is talking to, as an SF Symbol. Matched on substrings and prefixes, so
    /// a vendor rename loses a glyph and nothing else; the `notion` test has to come early.
    static func sourceIcon(for tool: String) -> String? {
        if CustomMCPTools.isCustomTool(tool) { return "puzzlepiece.extension.fill" }
        if canonical(tool) == "list_profiles" { return "person.crop.circle.fill" }
        if canonical(tool) == "current_time" { return "clock" }
        if canonical(tool) == "dispatch" { return "magnifyingglass" }
        if canonical(tool) == "search_recent" { return "magnifyingglass" }
        if canonical(tool) == "mark_spam" { return "exclamationmark.shield" }
        if canonical(tool) == "unsubscribe_sender" { return "bell.slash" }
        if canonical(tool) == "triage_next" { return "arrow.right.circle" }
        if tool.hasPrefix("slack_") { return "number" }
        if tool.hasPrefix("notion") { return "note.text" }
        if tool.hasPrefix("granola_") { return "text.bubble.fill" }
        // GitHub by prefix, ahead of the mail test, which would claim names containing "thread" and
        // the like.
        if tool.hasPrefix("github_") { return "chevron.left.forwardslash.chevron.right" }
        // Exact match: "search" appears in many other tool names.
        if tool == "web_search" { return "globe" }
        // Must precede the mail bucket, so a context tool never reads as a fresh Gmail read.
        if tool.hasSuffix("_context") { return "brain" }
        // The user's own commands, before the mail bucket: a command lookup is not a Gmail read.
        if canonical(tool) == "commands" { return "wand.and.sparkles" }
        // Saying the answer at the end of a command.
        if canonical(tool) == "summarize" { return "text.bubble" }
        // The same glyph as the red button and the Live Activity's End.
        if canonical(tool) == "end_session" { return "phone.down.fill" }
        if canonical(tool) == "stop_listening" { return "mic.slash.fill" }
        if canonical(tool) == "send_text" { return "message.fill" }
        if canonical(tool) == "read_texts" { return "text.bubble" }
        if canonical(tool) == "find_contact" { return "person.crop.circle" }
        // A standing mail rule gets a funnel; exact match because "filter" is a common word. The
        // pre-rename name still matches, for calls dialled before the rename.
        if ["create_mailbox_filter", "create_filter"].contains(canonical(tool)) {
            return "line.3.horizontal.decrease.circle"
        }
        // Exact match on the canonical name: `contains("attach")` would catch other connectors'
        // files.
        if canonical(tool) == "read_attachment" { return "paperclip" }
        // The assistant's own standing rules; a different glyph from `create_mailbox_filter`, since
        // they share its phrasing.
        if canonical(tool) == "set_rule" {
            return "text.badge.checkmark"
        }
        // `person` is a mail marker for `find_person`; safe only because the `slack_` test runs
        // first.
        if ["message", "thread", "draft", "email", "person"].contains(where: tool.contains) {
            return "envelope"
        }
        if tool.contains("calendar") { return "calendar" }
        if tool.contains("note") { return "note.text" }
        let code = [
            "pull_request", "issue", "commit", "actions_", "job_logs",
            "file_contents", "search_code", "notification", "get_me", "list_label",
            "repositor",
        ]
        if code.contains(where: tool.contains) { return "chevron.left.forwardslash.chevron.right" }
        return nil
    }

    /// An unmapped tool still has to read as something: the bare name, without the `slack_` prefix.
    private static func fallback(_ tool: String) -> String {
        return canonical(tool).replacingOccurrences(of: "_", with: " ")
    }

    /// The bare tool name, with the server's connector prefix (`gmail_`, `github_`, `slack_`)
    /// removed. Shared with `TriageQueueStore.advancesQueue` so the two matchers never disagree.
    static func canonical(_ tool: String) -> String {
        for prefix in ["gmail_", "github_"] where tool.hasPrefix(prefix) {
            return String(tool.dropFirst(prefix.count))
        }
        // A user's own server: `mcp_<server>_<tool>` reads as the tool alone.
        if CustomMCPTools.isCustomTool(tool) { return CustomMCPTools.bareName(tool) }
        return tool
    }
}
