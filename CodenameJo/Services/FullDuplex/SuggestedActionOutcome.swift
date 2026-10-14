import Foundation

/// Follows one spoken email suggestion to its outcome. An observer only: the call never reads it.
@MainActor
struct SuggestedActionTracker {
    typealias Identity = LiveEmailPresentation.Key.Identity

    enum Outcome: String {
        case accepted, declined
        case movedOn = "moved_on"
        case ended
    }

    struct Offer {
        let identity: Identity
        let question: String
        let conversationId: String?
    }

    private(set) var pending: Offer?
    private var offered: Set<Identity> = []
    /// Only an answer to the turn that said the suggestion counts, so a later yes/no is not ours.
    private var lastTurnAsked = false
    /// A tool can advance the queue before the answer's transcript finalizes; the answer decides.
    private var movedWhileAnswering = false

    /// Arms once per email per dial, when a completed assistant turn says the whole question.
    mutating func assistantSaid(_ transcript: String, current: (identity: Identity, question: String)?,
                                conversationId: String?) {
        if let pending {
            if !movedWhileAnswering { lastTurnAsked = Self.spoken(pending.question, in: transcript) }
            return
        }
        guard let current, Self.spoken(current.question, in: transcript),
              offered.insert(current.identity).inserted else {
            lastTurnAsked = false
            return
        }
        pending = Offer(identity: current.identity, question: current.question, conversationId: conversationId)
        lastTurnAsked = true
    }

    /// The suggestion this transcript would accept, without resolving it.
    func wouldAccept(_ transcript: String) -> Offer? {
        guard lastTurnAsked, let pending, Self.answer(to: transcript) == .accepted else { return nil }
        return pending
    }

    mutating func userSaid(_ transcript: String) -> (Outcome, Offer)? {
        defer { lastTurnAsked = false }
        guard lastTurnAsked else { return nil }
        if let outcome = Self.answer(to: transcript) { return take(outcome) }
        return movedWhileAnswering ? take(.movedOn) : nil
    }

    mutating func queueMoved(to identity: Identity?) -> (Outcome, Offer)? {
        guard pending != nil, pending?.identity != identity else { return nil }
        if lastTurnAsked {
            movedWhileAnswering = true
            return nil
        }
        return take(.movedOn)
    }

    mutating func ended() -> (Outcome, Offer)? { take(movedWhileAnswering ? .movedOn : .ended) }

    mutating func startDial() { self = SuggestedActionTracker() }

    private mutating func take(_ outcome: Outcome) -> (Outcome, Offer)? {
        guard let offer = pending else { return nil }
        pending = nil
        lastTurnAsked = false
        movedWhileAnswering = false
        return (outcome, offer)
    }

    static func spoken(_ question: String, in transcript: String) -> Bool {
        let question = FullDuplexVoiceClient.normalize(question)
        return !question.isEmpty && FullDuplexVoiceClient.normalize(transcript).contains(question)
    }

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
