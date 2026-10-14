import Foundation

/// A small, fail-closed authorization policy for count calls while the assistant walks mail.
enum EmailQueueCountPolicy {
    static func allows(utterance: String) -> Bool {
        let text = normalized(utterance)
        guard !text.isEmpty, !containsNegation(text) else { return false }

        let asksForQuantity = SpokenPhrases.countQuestions.contains { text.contains($0) }
        let namesMail = !words(in: text).isDisjoint(with: SpokenPhrases.mailNouns)
        return asksForQuantity && namesMail
    }

    static let refusal = "REFUSED — the user's latest words did not explicitly ask for a "
        + "mail count. Do not call count_messages again in this turn and do not mention "
        + "a count. Continue with the current queue message."

    private static func normalized(_ utterance: String) -> String {
        utterance
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .joined(separator: " ")
    }

    private static func words(in text: String) -> Set<String> {
        Set(text.split(separator: " ").map(String.init))
    }

    private static func containsNegation(_ text: String) -> Bool {
        SpokenPhrases.countNegations.contains { text.contains($0) }
    }
}
