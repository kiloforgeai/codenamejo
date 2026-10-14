import Foundation

/// Intent is independent of whether a job returns information or an action receipt.
enum DispatchScope: String, Codable {
    case independent
    case currentEmail = "current_email"

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
