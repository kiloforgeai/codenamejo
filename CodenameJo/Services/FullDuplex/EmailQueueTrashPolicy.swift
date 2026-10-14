import Foundation

enum EmailQueueTrashPolicy {
    static func allows(utterance: String) -> Bool {
        let text = normalized(utterance)
        guard !text.isEmpty, !containsNegation(text) else { return false }
        return !words(in: text).isDisjoint(with: SpokenPhrases.trashVerbs)
    }

    static let refusal = "REFUSED — the user's latest words did not explicitly say delete, "
        + "trash or discard. Do not call trash_message again in this turn. If they explicitly "
        + "asked to archive, call archive_message instead; otherwise continue with triage_next."

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
        SpokenPhrases.trashNegations.contains { text.contains($0) }
    }
}
