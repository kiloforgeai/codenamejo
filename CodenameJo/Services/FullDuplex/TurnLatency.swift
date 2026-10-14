import Foundation

/// How long the user waited, on one turn, between stopping talking and hearing
/// an answer.
///
/// **Not the same number as `CommandRecord.durationSeconds`, which is why this
/// exists.** That one is timed from the user's *first* word to the assistant's
/// last, so it grows with how long the question was and with how long the answer
/// ran — a chatty reply reads as a slow one. What the experience turns on is the
/// silence in the middle, and nothing measured it.
///
/// Three marks rather than one, because the wait has three different causes and
/// they are fixed in different places: `toResponseCreatedMs` is the server
/// deciding to answer at all, `toFirstTokenMs` is the model producing its first
/// word (a tool call lands between these two and is what usually stretches them),
/// and `toFirstAudioMs` is the one the user actually feels. Kept in milliseconds
/// as `Int` because that is what the tool steps beside them already store.
struct TurnLatency: Equatable, Codable, Hashable {
    var toResponseCreatedMs: Int?
    var toFirstTokenMs: Int?
    var toFirstAudioMs: Int?

    /// **The two transcript legs are timed from different marks, deliberately,
    /// because they answer different questions and one alone misleads.**
    ///
    /// Both exist to settle whether transcribing on the phone is faster than the
    /// round trip to `gpt-live-transcribe` — a claim that is structurally obvious
    /// (a full RTT is deleted) and has never been measured, which in this
    /// codebase is the state that precedes being wrong. They are directly
    /// comparable across the two paths, so pointing a build at an old broker and
    /// a new one gives the answer.
    ///
    /// - `toFirstTranscriptMs` runs from **speech started**: how long after you
    ///   begin talking the first words appear. This is the live lag, and it is
    ///   where the round trip is expected to show up.
    /// - `toFinalTranscriptMs` runs from **speech stopped**, like every other leg
    ///   here: how long after you finish the settled text exists. This is what
    ///   History and the hang-up phrase wait on — and the one place the local
    ///   path is knowingly *slower*, because `LocalTranscriber.settleGrace` holds
    ///   it for 450 ms so Apple's finaliser can catch the last few words.
    var toFirstTranscriptMs: Int?
    var toFinalTranscriptMs: Int?

    /// Which path produced the two numbers above. Without it they are a pair of
    /// milliseconds with nothing to compare against — the whole point is the
    /// difference between the phone and the round trip, and that is not
    /// recoverable from the build number once both are in the field.
    var transcribedOnDevice: Bool?

    /// Where this turn sat in the call — 1 for the first ask, counting every turn
    /// rather than every *timed* one.
    ///
    /// **Counting only timed turns is the trap this exists to avoid.** Dispatch turns
    /// and failed commands carry no latency by design, so an ordinal assigned where a
    /// latency exists promotes a half-warm turn 2 into position 1 and flattens the
    /// very step the number is for.
    ///
    /// Its absence is why a 1.2-second regression on the most-noticed turn in the
    /// product went unmeasured for eight days and had to be reconstructed in SQL
    /// against `app_records`.
    var turnIndex: Int?

    /// Milliseconds from the call connecting to this turn's mark. Separates "the first
    /// turn is slow" from "the first ten seconds of a call are slow" — indistinguishable
    /// on `turnIndex` alone.
    var sinceConnectMs: Int?

    /// How long turn detection sat on the end of the utterance before the server
    /// admitted the turn was over: `input_audio_buffer.speech_stopped` arriving, minus
    /// the phone's own last-word timestamp.
    ///
    /// **This is the one leg that is outside every other number here.** All the legs
    /// above are measured *from* `speech_stopped`, which is the event this measures the
    /// arrival of — so eagerness, `silence_duration_ms` and `prefix_padding_ms` had
    /// never appeared in any latency figure this app records, on any turn. They are a
    /// straight addition to what the user waits, and unlike the first-turn penalty they
    /// are paid on every turn: first device readings were a **median of 462 ms, mean
    /// 504 ms, range 19–898 ms** over 17 turns at `eagerness: high`.
    ///
    /// Includes one network hop and is only as good as the on-device transcriber's last
    /// result, so read it as an upper bound. Nil when nothing was transcribed locally.
    var vadWaitMs: Int?

    /// Live only: the share of the speaker's 128k context in use; OpenAI swaps the engine at 0.9.
    var contextUsageRatio: Double?

    /// Nothing was measured — the turn was echo, or was cut off before it spoke.
    /// A record with this is not worth storing, and `isEmpty` is what decides.
    ///
    /// **The transcript legs are deliberately not part of this test.** A turn that
    /// produced words but no answer is still a turn nobody got a reply to, and
    /// counting it as measured would start storing records this has always
    /// dropped — a behaviour change smuggled in behind an instrumentation one.
    var isEmpty: Bool {
        toResponseCreatedMs == nil && toFirstTokenMs == nil && toFirstAudioMs == nil
    }
}
