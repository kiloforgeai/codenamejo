import Foundation

/// Recognises a clear accept or decline in what the user just said. Deliberately narrower than
/// conversational intent recognition.
enum CalendarRSVPQueuePolicy {
    static func response(in utterance: String) -> String? {
        let text = utterance.lowercased()
        for (response, candidates) in SpokenPhrases.rsvpPhrases
            where candidates.contains(where: text.contains) {
            return response
        }
        for (response, pattern) in SpokenPhrases.rsvpWords
            where text.range(of: pattern, options: .regularExpression) != nil {
            return response
        }
        return nil
    }

    /// `end_session` is model-selected, so keep calendar decision words from becoming an
    /// irreversible hang-up. This happened twice on device: "decline hi test" produced a
    /// goodbye instead of `respond_to_calendar_event`. An explicit call-ending phrase still
    /// wins; this only rejects the accidental interpretation of accept/no as leave.
    static func refusesEndSession(for utterance: String) -> Bool {
        guard response(in: utterance) != nil else { return false }
        let text = utterance.lowercased()
        return !SpokenPhrases.endCall.contains(where: text.contains)
    }
}
