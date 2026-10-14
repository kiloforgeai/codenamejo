import Foundation

/// How a stored row is described. Keys come from words, not raw `arguments`: a tool whose
/// arguments are empty (`gmail_triage_next`) would otherwise overwrite one row forever.
enum LocalContextKeys {
    /// The advertised names of the reads worth keeping. Never a write: its output is a receipt, and
    /// `triage_next` is cached per message instead. A name for a parked connector is harmless here.
    static var cached: Set<String> { MailHeadersOnly.withholdsBodies ? headersOnlyCached : allCached }

    /// The two body reads, which are the only names that move.
    private static let bodyReads: Set<String> = ["gmail_get_message", "gmail_get_thread"]
    private static let allCached = cachedNames.union(bodyReads)
    private static let headersOnlyCached = cachedNames

    private static let cachedNames: Set<String> = [
        // The body reads are in `bodyReads`, so a headers-only account never stores a body.
        "gmail_count_messages", "gmail_search_messages", "gmail_find_person",
        // Calendar reads are absent: `CalendarStore` caches them, and a second copy here would drift.
        // The Slack reads, run on this phone.
        "slack_read_channel", "slack_read_thread", "slack_search_public_and_private",
        "slack_read_user_profile", "slack_list_channel_members", "slack_search_users",
        "slack_search_channels",
        // GITHUB_CACHED_TOOLS
        "github_search_repositories", "github_search_code", "github_list_pull_requests",
        "github_pull_request_read", "github_search_pull_requests", "github_list_issues",
        "github_issue_read", "github_search_issues", "github_list_commits",
        "github_get_commit", "github_get_file_contents", "github_actions_list",
        "github_actions_get", "github_get_job_logs", "github_list_notifications",
        "github_get_notification_details", "github_list_label",
        // NOTION_CACHED_TOOLS
        "notion-search", "notion-fetch", "notion-query-data-sources",
        "notion-get-comments", "notion-list-recent-pages",
    ]

    /// The queue read that caches per message rather than per call.
    static let triageTools: Set<String> = ["gmail_triage_next"]

    /// Whether this result is data rather than prose. It keeps refusals and write receipts out,
    /// including `gmail_archive_message`'s prose with JSON appended.
    static func isData(_ output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("[") || trimmed.hasPrefix("{")
    }

    /// The message ids a write acted on, read from its arguments, so an existing row can record
    /// what was done to it. An archived message is answerable only from its stored copy.
    static func actedMessageIds(in argumentsJSON: String) -> [String] {
        let args = object(from: argumentsJSON)
        var ids: [String] = []
        for key in ["message_id", "messageId", "id", "thread_id"] {
            if let one = args[key] as? String, !one.isEmpty { ids.append(one) }
            if let many = args[key] as? [String] { ids.append(contentsOf: many.filter { !$0.isEmpty }) }
        }
        return ids
    }

    /// What a write did, past tense and short, as appended to a message's row and read back later.
    static func actionNote(for tool: String) -> String? {
        switch ToolNarration.canonical(tool) {
        case "archive_message", "archive_matching": return "archived"
        case "trash_message": return "deleted"
        // Deliberately overwrites the row's "archived" note.
        case "unarchive_message": return "put back in the inbox"
        case "label_message": return "labelled"
        case "mark_spam": return "reported as spam"
        case "send_email": return nil
        default: return nil
        }
    }
    /// A row's key from a read's arguments. Reads whose arguments are only ids are keyed from
    /// their output instead. `tool` is the advertised name, used verbatim in the trailing tag.
    static func describe(tool: String, argumentsJSON: String) -> String {
        let args = object(from: argumentsJSON)
        let query = args["query"] as? String ?? ""
        let tag = " [\(tool)]"
        func string(_ key: String) -> String { args[key] as? String ?? "" }
        switch ToolNarration.canonical(tool) {
        case "count_messages": return "how many messages match \(query)\(tag)"
        case "search_messages": return "mail matching \(query)\(tag)"
        case "get_message": return "the message \(string("message_id"))\(tag)"
        case "get_thread": return "the thread \(string("thread_id"))\(tag)"
        case "read_attachment":
            return "the attachment on message \(string("message_id"))\(tag)"
        case "find_person": return "the email address for \(string("name"))\(tag)"
        default:
            // Keyed by name alone, so each call replaces the last. Add a case to make rows accumulate.
            return tool
        }
    }

    /// One email's row description.
    static func describe(email: [String: Any], tool: String) -> String {
        let from = email["from"] as? String ?? ""
        let subject = email["subject"] as? String ?? ""
        return "the email from \(from) about \"\(subject)\" [\(tool)]"
    }

    /// Every object in the output with an `id` and a `from` or `subject`, one row each.
    /// Requiring `id` excludes `gmail_triage_next`'s id-less `next` preview.
    static func emails(in outputJSON: String) -> [[String: Any]] {
        var found: [[String: Any]] = []
        var seen = Set<String>()
        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let id = dictionary["id"] as? String, !id.isEmpty,
                   dictionary["from"] != nil || dictionary["subject"] != nil,
                   !seen.contains(id) {
                    seen.insert(id)
                    found.append(dictionary)
                }
                for nested in dictionary.values { walk(nested) }
            } else if let array = value as? [Any] {
                for nested in array { walk(nested) }
            }
        }
        walk(parsed(outputJSON) ?? [:])
        return found
    }

    /// `output` arrives as a JSON *string* inside the item, so it is parsed twice.
    static func parsed(_ json: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    static func object(from json: String) -> [String: Any] {
        parsed(json) as? [String: Any] ?? [:]
    }

    /// Re-serialise one message for storage, keys verbatim as the tool sent them.
    static func json(for object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}
