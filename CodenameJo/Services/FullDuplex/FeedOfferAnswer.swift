import Foundation

@MainActor
enum FeedOfferAnswer {
    enum Outcome { case accepted, declined }

    private static let fillers: Set<String> = ["uh", "um", "er", "ah", "oh", "well", "so"]
    private static let affirmatives: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "alright", "definitely",
    ]
    // `normalize` turns "don't" into "don t".
    private static let negatives: Set<String> = ["no", "nope", "nah", "not", "don", "dont"]
    /// A yes that goes on to skip ("okay, next") is not taking the offer.
    private static let skips: Set<String> = ["skip", "next", "later"]

    /// Judged by the opening word, so "sure, why not" is a yes; "please" only softens what follows.
    static func answer(to transcript: String) -> Outcome? {
        var words = FullDuplexVoiceClient.normalize(transcript).split(separator: " ").map(String.init)
        while let first = words.first, fillers.contains(first) || first == "please" { words.removeFirst() }
        guard let first = words.first else { return nil }
        if negatives.contains(first) { return .declined }
        guard !words.contains(where: skips.contains) else { return nil }
        if affirmatives.contains(first) || words == ["do"] || words.starts(with: ["go", "ahead"])
            || words.starts(with: ["do", "it"]) { return .accepted }
        return nil
    }
}
