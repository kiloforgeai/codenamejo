import Foundation

struct LiveMailAuthorization {
    enum Operation: String, Hashable {
        case archive, trash, delete, spam, read, unread, label, star, unstar, send, draft, forward, next

        init?(tool: String) {
            switch ToolNarration.canonical(tool) {
            case "archive_message": self = .archive
            case "trash_message": self = .trash
            case "delete_message": self = .delete
            case "mark_spam", "spam_message", "report_spam": self = .spam
            case "mark_read": self = .read
            case "mark_unread": self = .unread
            case "label_message": self = .label
            case "star_message": self = .star
            case "unstar_message": self = .unstar
            case "send_email", "reply_email": self = .send
            case "create_draft": self = .draft
            case "forward_email": self = .forward
            case "triage_next": self = .next
            default: return nil
            }
        }
    }

    let operations: Set<Operation>

    init(_ request: String) {
        var allowed = Set<Operation>()
        let text = request.lowercased().replacingOccurrences(of: "’", with: "'")
        guard !LiveRequestRecovery.isFeedback(text),
              !Self.matches(text, #"^(?:what|why|which|when|where|who|how|should|did|does|do i|can i|could i|have you|is |are )\b"#),
              !Self.matches(text, #"\b(?:don't|dont|do not|never|instead|actually|unless|if|stop|cancel)\b"#) else {
            operations = []; return
        }
        // Quoted/dictated content cannot grant an additional operation.
        let intent = text.components(separatedBy: .init(charactersIn: "\"“”")).first ?? text
        let clauses = intent.components(separatedBy: .newlines).flatMap {
            $0.replacingOccurrences(of: #"\s+(?:and then|then|and)\s+|[.;]|,\s+"#, with: "\n", options: .regularExpression)
                .components(separatedBy: "\n")
        }
        for raw in clauses {
            var clause = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefixes = ["okay ", "ok ", "thanks ", "please ", "just ", "can you ", "could you ",
                            "would you ", "go ahead and ", "i want you to ", "let's "]
            while let prefix = prefixes.first(where: clause.hasPrefix) { clause.removeFirst(prefix.count) }
            clause = clause.trimmingCharacters(in: .punctuationCharacters)
            if let action = LiveFastAction.parse(clause), let operation = Operation(tool: action.rawValue) {
                allowed.insert(operation)
            }
            let actionPatterns: [(Operation, String)] = [
                (.archive, #"^(?:archive|file away|file (?:it|this|that)|get rid of|toss)\b"#),
                (.trash, #"^(?:trash|delete|move (?:it|this|that|the email) to (?:the )?trash)\b"#),
                (.delete, #"^permanently delete\b"#),
                (.spam, #"^(?:mark|report).{0,60}\b(?:spam|junk)\b"#),
                (.read, #"^mark\b.{0,60}\b(?:as )?read\b"#),
                (.unread, #"^mark\b.{0,60}\bunread\b"#),
                (.label, #"^(?:label|apply (?:the )?label|add (?:the )?label)\b"#),
                (.star, #"^star\b"#), (.unstar, #"^unstar\b"#),
                (.send, #"^(?:reply|respond|write back|send (?:it|this|that|(?:the|a|an) (?:reply|email|message|draft)))\b"#),
                (.draft, #"^(?:draft|compose|write (?:a |the )?(?:reply|email)|create (?:a |the )?draft|reply|respond)\b"#),
                (.forward, #"^forward\b"#),
                (.next, #"^(?:skip|next|move on|continue (?:the )?feed|go to (?:the )?next)\b"#)
            ]
            for (operation, pattern) in actionPatterns where Self.matches(clause, pattern) { allowed.insert(operation) }
            if Self.matches(clause, #"^(?:send|reply|respond|write|draft|compose|forward|create (?:a |the )?draft)\b"#) { break }
        }
        operations = allowed
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
