import Foundation

/// The English the app matches or speaks on its own, in one place.
///
/// Only phrases behind a decision the app has to enforce live here — a write it gates, a
/// hang-up it refuses, a continuation it owes. The policies that read them keep the decision;
/// this file keeps the words, so a phrasing change is an edit here and nowhere else. A rule the
/// model can apply on its own belongs in `prompts/`, not in this table.
enum SpokenPhrases {

    // MARK: - Ending the call

    /// Words that end the call even when the utterance also sounds like an RSVP. See
    /// `CalendarRSVPQueuePolicy.refusesEndSession`. Lowercased; matched as substrings.
    static let endCall = [
        "hang up", "end the call", "end this call", "end session", "end the session",
        "stop the call", "close the call", "wrap up", "goodbye", "bye for now",
    ]

    // MARK: - Calendar RSVP

    /// Phrases that answer an invitation, tried in order before `rsvpWords`. Lowercased;
    /// matched as substrings.
    static let rsvpPhrases: [(response: String, phrases: [String])] = [
        ("declined", ["say no", "rsvp no", "can't make it", "cannot make it",
                      "won't attend", "not attending"]),
        ("accepted", ["say yes", "rsvp yes", "i'll attend", "i will attend",
                      "going to attend"]),
    ]

    /// Single-word answers, as word-bounded patterns, tried in order.
    static let rsvpWords: [(response: String, pattern: String)] = [
        ("declined", #"\b(?:decline|declined|declining|reject|rejected|rejecting)\b"#),
        ("accepted", #"\b(?:accept|accepted|accepting)\b"#),
    ]

    // MARK: - Mail count

    /// A request for a quantity. `EmailQueueCountPolicy` also needs one of `mailNouns`.
    static let countQuestions = [
        "how many", "how much", "number of", "unread count", "message count",
        "email count", "mail count", "count my", "count the", "any unread",
    ]

    /// Whole words that make a quantity question about mail.
    static let mailNouns: Set<String> = [
        "unread", "email", "emails", "mail", "message", "messages", "inbox",
    ]

    /// Phrases that turn a count request into a refusal of one.
    static let countNegations = [
        "don't count", "do not count", "dont count", "never count",
        "not tell me how many", "don't tell me how many", "do not tell me how many",
    ]

    // MARK: - Trash

    /// Whole words that authorize `trash_message` while the queue is live.
    static let trashVerbs: Set<String> = [
        "delete", "deleted", "deleting", "trash", "trashed", "trashing",
        "discard", "discarded", "discarding",
    ]

    static let trashNegations = [
        "don't delete", "do not delete", "dont delete", "not delete",
        "don't trash", "do not trash", "dont trash", "not trash",
        "don't discard", "do not discard", "dont discard", "not discard",
    ]

    // MARK: - Stalls and receipts

    // Matched by `FullDuplexVoiceClient.announcesLookup`, `trailsWithAnnouncement` and
    // `deliveredReceipt` against `normalize`d text: lowercased, apostrophes stripped, so
    // "I'll" reads as "i ll".

    /// Announcements that carry no opener. Each is a phrase that buys time and
    /// nothing else, so unlike the openers below it needs no verb behind it.
    static let stallInterjections = [
        "one sec", "one moment", "just a sec", "just a second", "give me a moment",
        "give me a sec", "hang on", "hold on", "checking", "pulling up",
        "looking that up", "looking it up", "on it",
        // Opener-free handoff acks Live speaks: "Okay, archiving that." Only phrases that do
        // not occur as content words; "sending" and "handling" would match answers.
        "archiving", "taking care of", "doing that",
    ]

    /// Apostrophes are stripped by `normalize`, so "I'll" reads as "i ll".
    static let stallOpeners = [
        "i ll", "i will", "i m going to", "i am going to", "i can", "i should",
        "let me", "let s",
    ]

    /// Things this assistant can actually go and do. Multi-word entries are here
    /// because their first word is not one of them: `take` alone would match
    /// "I'll take that as a yes".
    ///
    /// `get` is deliberately absent — "I'll get back to you" is a promise, not a
    /// lookup, and it is far more likely on this path than "I'll get your inbox".
    /// The writes are present because a stalled "I'll send that" is a stall to
    /// continue; what keeps a *wrong* continuation safe there is the first sentence
    /// of the continuation's instruction, not this list.
    ///
    /// The last four are what a queue step actually says. The prompt's speak-first
    /// exception licenses an acknowledgement in front of an archive, and the model
    /// spends it on "I'll take care of that" rather than on `archive` — so every
    /// stall this path can produce was invisible to the list above it.
    static let stallVerbs = [
        "check", "pull", "look", "take a look", "have a look", "find", "fetch",
        "grab", "search", "read", "see", "run", "open", "dig", "review", "scan",
        "send", "post", "draft", "reply", "respond", "archive", "label",
        "schedule", "book", "create", "add", "update", "merge", "comment", "invite",
        "take care of", "handle", "deal with", "sort",
    ]

    /// Past tense only. Both spellings of `labelled`, because the model picks either and
    /// the app's own receipts use the double-l form (`GmailManageTools`).
    ///
    /// **`marked` arrived on 2026-08-12 with `mark_spam`, and its absence is what a name
    /// added to `answersBeforeActing` alone costs.** The tool shipped in that set without a
    /// verb here, so the suppression it was added for could never fire: measured on a test
    /// iPhone 17 Pro, three of four spam steps spoke "Marked it as spam. Next is …" — the
    /// designed turn, exactly — and all three were logged as having spoken without a receipt
    /// and given a continuation anyway. (The fourth promised, and that one is what the
    /// continuation is for.) `deliveredReceipt` is only consulted for the three tools
    /// in that set, which is why a word this general is safe here; and past tense still does
    /// the discriminating, because "I'll mark that as spam" says `mark`.
    static let receiptVerbs: Set<String> = [
        "archived", "deleted", "labelled", "labeled", "filed", "marked",
    ]

    // MARK: - Lines the app speaks itself

    /// Exact voice contract shared by every local quick-tip placement.
    static let coachingInvitation =
        "Hey, do you want to learn something new about Jo? You can say yes or no."

    /// The spoken archive receipt, once Gmail confirmed it or (live) once it is queued.
    static let archived = "Archived."
    /// The receipt for a queued archive off Live, where it may still be running.
    static let archiving = "Archiving."
}
