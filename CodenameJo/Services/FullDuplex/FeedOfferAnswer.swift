import Foundation

/// Strip only recognized non-speech ASR markers for routing. History keeps the original text.
enum SpokenAnswerText {
    static func words(_ transcript: String) -> [String] {
        let spoken = transcript.replacingOccurrences(
            of: #"\[\s*(?:inhale|inhales|exhale|exhales|breath|breathing|sigh|sighs)\s*\]"#,
            with: " ", options: [.regularExpression, .caseInsensitive])
        return spoken.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

enum FeedOfferAnswer {
    enum Outcome { case accepted, declined }
    private static let fillers: Set<String> = ["uh", "um", "er", "ah", "oh", "well", "so", "please"]
    private static let affirmatives: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "alright", "definitely",
    ]
    private static let negatives: Set<String> = ["no", "nope", "nah", "not", "don", "dont"]

    static func answer(to transcript: String) -> Outcome? {
        var words = SpokenAnswerText.words(transcript)
        while let first = words.first, fillers.contains(first) { words.removeFirst() }
        guard let first = words.first else { return nil }
        if negatives.contains(first) { return .declined }
        // A qualified yes must never bypass a refusal. "Sure, why not" is a bare assent.
        if words.suffix(2) == ["why", "not"] { words.removeLast(2) }
        if words.contains(where: negatives.contains) { return .declined }
        var requested = words
        while let first = requested.first, affirmatives.contains(first) || fillers.contains(first) { requested.removeFirst() }
        while let last = requested.last, ["please", "thanks"].contains(last) { requested.removeLast() }
        let feedRequests: Set<String> = [
            "let s do some cleanup", "lets do some cleanup", "let s do cleanup", "lets do cleanup",
            "do some cleanup", "do cleanup", "go through my inbox", "go through the inbox",
            "let s go through my inbox", "let s go through the inbox", "go through the feed",
            "let s go through the feed", "start the feed", "start my inbox",
        ]
        if feedRequests.contains(requested.joined(separator: " ")) { return .accepted }
        if words == ["do"] || words == ["do", "it"] || words == ["go", "ahead"] { return .accepted }
        guard affirmatives.contains(first), words.count <= 6 else { return nil }
        let assentWords = affirmatives.union(["go", "ahead", "do", "it", "please", "thanks", "thank", "you"])
        return words.allSatisfy(assentWords.contains) ? .accepted : nil
    }

    static func supersedesOffer(_ transcript: String) -> Bool {
        let words = SpokenAnswerText.words(transcript)
        let requests: Set<String> = ["archive", "delete", "trash", "spam", "reply", "send", "read", "find",
            "search", "show", "tell", "switch", "stop", "skip", "next", "later", "feedback", "schedule",
            "what", "where", "when", "why", "how", "can", "could", "would"]
        return words.contains(where: requests.contains)
    }
}

/// One offer survives non-answers, but can authorize work only once, within a bounded interval.
struct PendingFeedOffer: Equatable {
    enum Resolution: String { case accepted, declined, superseded, expired, waiting }
    let id = UUID()
    let openedAt: Date
    private(set) var consumed = false
    init(now: Date = .now) { openedAt = now }

    mutating func resolve(_ transcript: String, now: Date = .now) -> Resolution {
        guard !consumed else { return .expired }
        let result: Resolution
        if now.timeIntervalSince(openedAt) > 120 { result = .expired }
        else if let answer = FeedOfferAnswer.answer(to: transcript) {
            result = answer == .accepted ? .accepted : .declined
        } else { result = FeedOfferAnswer.supersedesOffer(transcript) ? .superseded : .waiting }
        consumed = result != .waiting
        return result
    }
}
