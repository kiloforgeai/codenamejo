import Foundation

/// Intent is independent of whether a job returns information or an action receipt.
enum DispatchScope: String, Codable {
    case independent
    case currentEmail = "current_email"

    static func refersToSelectedEmail(_ text: String) -> Bool {
        guard !LiveRequestRecovery.isFeedback(text),
              text.range(of: #"\b(?:unrelated|different email|another email|not about this)\b"#, options: [.regularExpression, .caseInsensitive]) == nil else { return false }
        return text.range(of: #"\b(?:part of this|(?:this|the selected|the current) (?:email|message)|(?:its|this sender's) (?:company|page|database)|file (?:it|this)|add (?:it|this) there)\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func explicitlyContinuesFeed(_ text: String) -> Bool {
        guard text.range(of: #"\b(?:don't|do not|not yet|never)\s+(?:move|go|continue|keep)\b"#,
            options: [.regularExpression, .caseInsensitive]) == nil else { return false }
        return text.range(of: #"\b(?:move on|go (?:on )?to the next|continue (?:with )?the feed|keep (?:going|moving)|while (?:we|i) (?:continue|move on))\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func pausesDecision(_ text: String) -> Bool {
        ["one second", "one sec", "hold on", "wait a second", "i m doing that now"]
            .contains { SpokenAnswerText.words(text).joined(separator: " ").contains($0) }
    }

    static func holdsDecision(related: Bool, continuing: Bool, savedCommand: Bool) -> Bool {
        related && !savedCommand && !continuing
    }

    static let independentNote = "This is an independent request, unrelated to the email being reviewed. "
        + "Leave the email queue and its current referent unchanged. Do not advance, re-present an email, "
        + "or say circling back. Answer the request when its result arrives."

    static func independentReport(task: String, result: String, ok: Bool?, standingStep: String?) -> String {
        "Background result for an independent request. Name its topic naturally and give the answer. "
            + independentNote
            + (ok == false ? " The work did not complete; explain what remains unresolved." : "")
            + "\nRequest: \(task)\nResult: \(result)"
            + (standingStep.map { "\nCurrent email context only; this is NOT what the result is about. "
                + "Any later email action refers to this current item, not the background request:\n" + $0 } ?? "")
    }
}
