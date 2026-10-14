import Foundation

/// `web_search`, declared by `LiveSessionSetup` and run here on the user's key with OpenAI's
/// hosted search.
enum WebSearchTool {
    static let name = "web_search"

    /// Sized for speech. Never illustrate the source rule with a real outlet: the model cites it.
    static let instructions = [
        "Search the web and answer in one or two short spoken sentences.",
        "Your answer is read out loud by a voice assistant, so: no markdown, no bullets, no URLs,",
        "no ids, no citation brackets, and no figure longer than a person would say aloud.",
        "Name the source, using its real name, only when who said it matters. Give one best figure",
        "rather than a range across sources.",
        "If the search turns up nothing, say so plainly. Never guess, and never answer from",
        "memory alone on anything that could have changed.",
    ].joined(separator: " ")

    /// Errors come back as text the model can speak, never as a throw.
    static func run(argumentsJSON: String, interactiveCoaching: Bool) async -> (output: String, failed: Bool) {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ("web_search needs a `query` — say what to find out.", true) }
        if let refusal = calendarRefusal(query) { return (refusal, false) }
        if interactiveCoaching, args["user_requested"] as? Bool != true {
            return ("NOT SEARCHED — web search cannot supply a Jo coaching lesson; the queue already "
                + "carries it. Only retry web_search with user_requested true when the user's own words "
                + "asked for a web lookup.", false)
        }
        do {
            let text = try await search(query)
            guard !text.isEmpty else { return ("Nothing came back for \"\(query)\".", true) }
            return (text, false)
        } catch {
            return ("That search failed: \(error.localizedDescription)", true)
        }
    }

    /// One hosted search on the user's key, citation markers removed.
    static func search(_ query: String) async throws -> String {
        stripCitations(try await LiveOpenAI.read(
            [["type": "input_text", "text": query]], instructions: instructions,
            tools: [["type": "web_search", "search_context_size": "low"]], timeout: 20))
    }

    /// `[12]` and `[12][14]` read aloud are unmistakably broken; nothing else is touched.
    static func stripCitations(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*(?:\[\d+\])+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let calendarObject =
        #"\b(?:my|the user's)?\s*(?:google\s+)?calendar\b|\bcalendar\s+(?:event|invite|invitation|meeting|appointment)\b"#
    private static let calendarOperation =
        #"\b(?:create|add|block|hold|book|reserve|schedule|put|move|reschedule|update|cancel|delete|accept|decline|respond|list|read|check|show|find)\b"#
    private static let researchRequest =
        #"\b(?:how(?:\s+do|\s+to)?|guide|instructions?|documentation|docs|tutorial|help article|research|news|outage)\b"#

    /// A query that substitutes for a personal Calendar operation; Calendar docs or news stay searchable.
    static func calendarRefusal(_ query: String) -> String? {
        let normal = query.lowercased().replacingOccurrences(of: "[’‘]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        func matches(_ pattern: String) -> Bool {
            normal.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        guard matches(calendarObject), matches(calendarOperation), !matches(researchRequest) else { return nil }
        return "NOT SEARCHED — web search cannot read, create, or change the user's calendar. Use the "
            + "available Calendar tool directly. If no Calendar tool is available, say the account "
            + "is not connected; do not substitute a web answer."
    }
}
