import Foundation

/// What the Live speaker may say at a coaching checkpoint.
///
/// `LiveSpokenStepContract` declines a step carrying `coaching` because its wording is the
/// backend's. The backend authors nothing the user hears on Live, so without a line here the
/// speaker composes the tip out of the checkpoint's own policy note.
enum LiveCoachingSpeakerContract {
    /// A step whose whole content is policy for the delegation backend.
    static let backendOnly = ""

    /// Through `interstitialPayload`, because a checkpoint reached by archive, draft, send or a
    /// calendar action arrives as a spoken receipt with the queue JSON appended, not as bare JSON.
    static func coaching(in step: String) -> [String: Any]? {
        FullDuplexVoiceClient.interstitialPayload(in: step)?["coaching"] as? [String: Any]
    }

    /// The invitation and nothing else. A checkpoint always carries one now (`LocalTriageQueue`);
    /// the flag is still read so a payload without it never asks for permission it did not mention.
    static func invitation(step: String) -> String? {
        guard coaching(in: step)?["interactive"] as? Bool == true else { return nil }
        return #"Say exactly this, then stop: "\#(SpokenPhrases.coachingInvitation)""#
    }

    /// The preloaded lesson, verbatim. Nil unless the checkpoint carries one for local playback.
    static func lessonSpeech(step: String) -> String? {
        guard let coaching = coaching(in: step),
              coaching["delivery"] as? String == "local_playback",
              let lesson = coaching["lesson"] as? [String: Any],
              let speech = (lesson["speech"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !speech.isEmpty else { return nil }
        return speech
    }

    static func capability(step: String) -> String? {
        (coaching(in: step)?["lesson"] as? [String: Any])?["capability"] as? String
    }
}

/// A bare yes or no at a coaching checkpoint, so the phone can play its own preloaded tip and step
/// its own queue rather than spend a backend turn on each.
///
/// Deliberately narrower than intent recognition, for the reason `CalendarRSVPQueuePolicy` gives:
/// anything unmatched falls through to the model, which is what happens today.
enum LiveCoachingAnswer {
    case accepted
    case declined

    private static let affirmatives: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "alright", "definitely", "please",
    ]
    /// "Skip" and "later" are absent on purpose: at a checkpoint they are as likely to be about
    /// the email as the tip, and guessing wrong walks the user past mail they never heard.
    private static let negatives: Set<String> = ["no", "nope", "nah", "not"]
    /// A word that makes the utterance a request rather than an answer, however it opens.
    private static let commands: Set<String> = [
        "archive", "read", "reply", "draft", "send", "forward", "delete", "trash", "spam",
        "next", "back", "unsubscribe", "label", "snooze", "schedule", "find", "search", "tell",
        "skip", "keep", "go", "move", "continue",
    ]

    /// The answer is the first word, and a bare answer is a short one. "Yeah, sure" and "yes go
    /// ahead" are the same answer as "yes"; "yes, archive this one" is a request and is not ours.
    private static let fillers: Set<String> = ["uh", "um", "er", "ah", "oh", "well", "so", "i"]

    /// A verb that asks for the lesson itself: "you can tell me something new about Jo" is a yes.
    private static let requestVerbs: Set<String> = ["tell", "teach", "show", "give", "hit"]

    static func parse(_ transcript: String) -> Self? {
        var words = transcript.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        while let first = words.first, fillers.contains(first) { words.removeFirst() }
        if asksForTheTip(words) { return .accepted }
        // "Go ahead" is consent; "go" alone stays a command.
        if let index = words.firstIndex(of: "go"), words.dropFirst(index + 1).first == "ahead" {
            words.removeSubrange(index...index + 1)
            if words.isEmpty { return .accepted }
        }
        guard (1...3).contains(words.count), !words.contains(where: commands.contains),
              let first = words.first else { return nil }
        if affirmatives.contains(first) { return .accepted }
        if negatives.contains(first) { return .declined }
        return nil
    }

    /// Named by what it asks for — the tip, a lesson, "something new", or a bare "tell me" — so
    /// "tell me about this email" still falls through, as does any other command or a negative.
    private static func asksForTheTip(_ words: [String]) -> Bool {
        guard words.count <= 10, words.contains(where: requestVerbs.contains),
              !words.contains(where: { commands.contains($0) && !requestVerbs.contains($0) }),
              !words.contains(where: { negatives.contains($0) || $0 == "don" || $0 == "dont" })
        else { return false }
        let somethingNew = zip(words, words.dropFirst()).contains { $0 == "something" && $1 == "new" }
        let bare = words.count <= 4 && words.last == "me"
        return bare || somethingNew || words.contains("tip") || words.contains("lesson")
    }
}
