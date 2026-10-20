import Foundation

enum LiveFastAction: String {
    case archive = "archive_message"
    case trash = "trash_message"
    case spam = "mark_spam"
    case next = "triage_next"

    static func parse(_ transcript: String) -> Self? {
        var text = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let requestQuestion = text.hasSuffix("?") && ["can you ", "could you ", "would you "]
            .contains(where: { text.hasPrefix($0) })
        if requestQuestion { text.removeLast() }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!,"))
        text = text.replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let interjections = ["awesome", "okay", "ok", "thanks", "thank you", "yeah", "yep", "sure"]
        while let word = interjections.first(where: { text.hasPrefix($0 + ". ") }) {
            text.removeFirst(word.count + 2)
        }
        let prefixes = ["i think we can ", "go ahead and ", "can you ", "could you ", "would you ",
                        "you can ", "we can ", "let's ", "lets ", "please ", "just ", "then ", "can "]
            + interjections.map { $0 + " " }
        while let prefix = prefixes.first(where: { text.hasPrefix($0) }) {
            text.removeFirst(prefix.count)
        }
        while let suffix = [" please", " for me", " as well", " too"].first(where: { text.hasSuffix($0) }) {
            text.removeLast(suffix.count)
        }
        switch text {
        case "archive", "archive it", "archive this", "archive that", "archive this one", "archive that one",
             "archive this email", "archive that email": return .archive
        case "mark as spam", "mark it as spam", "mark this as spam", "mark that as spam",
             "mark this email as spam", "mark that email as spam", "report spam", "report it as spam",
             "report this as spam", "report this email as spam", "this is spam", "that's spam",
             "that is spam", "mark as junk", "mark it as junk", "mark this as junk": return .spam
        case "delete it", "delete this", "delete that", "delete this email", "delete that email",
             "trash it", "trash this", "trash that", "move it to trash", "put it in the trash": return .trash
        case "next", "next email", "go next", "go to next", "move on to the next one",
             "skip", "skip this", "skip it", "skip this one", "skip this email": return .next
        default: return nil
        }
    }

    /// The phone's own tools that read no message, thread or account from the step and never move
    /// the cursor, so a feed that changed mid-turn is no reason to refuse them. Mail writes never
    /// belong here; a connector answers for its own tools (`Connector.isFeedIndependent`).
    static let feedIndependent: Set<String> = [
        "current_time", "list_calendar_events", "search_calendar", "coach_capability",
        "set_rule", "web_search", "search_context", "save_context", "forget_context",
    ]

    static func allowsFollowup(name: String, arguments: String, step: String?) -> Bool {
        if feedIndependent.contains(name) || ConnectorRegistry.owner(of: name)?.isFeedIndependent(name) == true {
            return true
        }
        guard let step, let key = LiveEmailPresentation.Key.step(step),
              let args = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              (args["account"] as? String)?.lowercased() == key.account else { return false }
        if ["gmail_get_message", "get_message"].contains(name),
           let id = args["message_id"] as? String ?? args["id"] as? String {
            return key.messageIDs.contains(id)
        }
        if ["gmail_get_thread", "get_thread"].contains(name),
           let id = args["thread_id"] as? String ?? args["id"] as? String {
            return key.exchangeId.isEmpty && id == key.threadId
        }
        return false
    }

    struct Anchor {
        let key: LiveEmailPresentation.Key
        let profileId: String
        let revision: Int

        func matches(step: String?, profileId: String?, revision: Int) -> Bool {
            self.profileId == profileId && self.revision == revision
                && step.flatMap(LiveEmailPresentation.Key.step) == key
        }
    }
}
