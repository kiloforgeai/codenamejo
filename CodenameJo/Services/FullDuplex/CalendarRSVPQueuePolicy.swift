import Foundation

/// Turns a clear RSVP request into a queue-owned action only when the calendar result and
/// the email on screen describe the same invitation. This is deliberately narrower than
/// conversational intent recognition: a false negative asks the user to clarify, while a
/// false positive notifies an organizer.
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

    static func matchesInvitation(
        eventSummary: String?, eventAccount: String,
        emailSubject: String, emailAccount: String
    ) -> Bool {
        guard eventAccount.caseInsensitiveCompare(emailAccount) == .orderedSame,
              let summary = eventSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
              summary.count >= 2 else { return false }
        let subject = emailSubject.lowercased()
        return subject.contains("invitation:") && subject.contains(summary.lowercased())
    }

    static func brokerAccepted(output: String, response: String, brokerVerdict: Bool?) -> Bool {
        if let brokerVerdict { return brokerVerdict }
        if output.hasPrefix("Accepted \"") || output.hasPrefix("Declined \"") { return true }
        return output.contains(" was already \(response) on ")
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
