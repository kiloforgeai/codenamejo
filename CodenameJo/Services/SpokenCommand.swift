import Foundation

/// A spoken phrase that controls the app, matched on the device against the user's own transcript.
/// Whole utterance only, never a substring: a fixed list trades misses for no false hang-ups.
enum SpokenCommand: Equatable {

    /// Hang up. The same operation as the red button and the Live Activity's X.
    case endCall

    /// The phrase, matched whole. `nil` for everything else, which is nearly
    /// everything the user ever says.
    static func match(_ text: String) -> SpokenCommand? {
        let phrase = normalized(text)
        guard !phrase.isEmpty else { return nil }
        return endCallPhrases.contains(phrase) ? .endCall : nil
    }

    // MARK: - Internals

    /// Every accepted wording, normalized (`i'm` is `im`). No `mute`/`unmute`: a muted track sends
    /// silence, so "unmute" could never be heard.
    private static let endCallPhrases: Set<String> = [
        "end the chat", "im done with the chat",
        "end chat", "im done with the call",
        "im done", "i am done",
        "end the call", "end call",
        "end the session", "end session",
        "stop the session", "stop session",
        "end the conversation", "end conversation",
        "hang up", "hang up the call",
        "goodbye",
    ]

    /// The same phrases as a person writes them, for the on-device transcriber's contextual bias.
    /// Written twice because the set above stores the normalized `im`; add a phrase to both.
    static let biasingPhrases: [String] = [
        "end the chat", "I'm done with the chat",
        "end chat", "I'm done with the call",
        "I'm done", "I am done",
        "end the call", "end call",
        "end the session", "end session",
        "stop the session", "stop session",
        "end the conversation", "end conversation",
        "hang up", "hang up the call",
        "goodbye",
    ]

    /// The mail words users actually say, handed to the analyzer alongside `biasingPhrases`. Keep it
    /// short: a long list dilutes the hint.
    static let vocabularyPhrases: [String] = [
        // The queue, which is most of what gets said out loud.
        "email queue", "start my email queue",
        "unread", "inbox", "my inbox",
        // The verbs, as spoken.
        "archive", "archive it", "archive it please", "archive please",
        "unarchive", "label it", "unlabel",
        "mark as spam", "unsubscribe", "draft", "forward",
        "skip", "next one", "read it out",
    ]

    /// Stripped from the ends only, so "okay, I'm done, thanks" reaches the set as "im done".
    private static let filler: Set<String> = [
        "okay", "ok", "alright", "right", "so", "now", "well",
        "um", "uh", "er", "please", "thanks", "thank", "you", "hey",
    ]

    /// Deleted outright by `normalized`, rather than becoming a space like every
    /// other non-letter. See that method for why the two cases differ.
    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{02BC}"]

    /// Lowercase, letters and spaces only, filler trimmed off each end. Apostrophes (`'`, `’`, `ʼ`) are
    /// deleted since they sit inside a word; every other non-letter becomes a space.
    private static func normalized(_ text: String) -> String {
        let letters = text.lowercased()
            .filter { !Self.apostrophes.contains($0) }
            .map { character -> Character in character.isLetter ? character : " " }
        var words = String(letters).split(separator: " ").map(String.init)
        while let first = words.first, filler.contains(first) { words.removeFirst() }
        while let last = words.last, filler.contains(last) { words.removeLast() }
        return words.joined(separator: " ")
    }
}
