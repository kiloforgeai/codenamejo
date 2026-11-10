import Foundation

/// Desktop confirmations come from the operation result, never from the next feed item.
@MainActor
enum LiveNarrationPolicy {
    static func confirmation(tool: String, result: String) -> String? {
        let tool = ToolNarration.canonical(tool)
        guard LiveWriteTarget.mailWrites.contains(tool)
            || ["send_email", "reply_email", "forward_email", "create_draft", "triage_next"].contains(tool) else { return nil }
        let receipt = result.components(separatedBy: "\n\nQueue:").first ?? result
        if receipt.hasPrefix(LocalDraftReview.notice) { return "Your draft is ready to review in Jo. Nothing has been sent." }
        if receipt.hasPrefix("Sent to ") { return "Reply sent." }
        if receipt.hasPrefix("Draft to "), receipt.contains(" saved in ") { return "Draft saved." }
        if receipt.hasPrefix("Sending to ") { return "Sending. Gmail has not confirmed it yet; check Activity for the receipt." }
        if receipt.hasPrefix("Saving a draft ") || receipt.hasPrefix("Drafting.") { return "The draft is pending. Check Activity for its receipt." }
        if receipt.hasPrefix("Archived.") { return "Archived." }
        if receipt.hasPrefix("Moved to Trash.") { return "Moved to Trash." }
        if receipt.hasPrefix("Marked as spam.") { return "Marked as spam." }
        if tool == "triage_next", !receipt.lowercased().contains("not executed"),
           let data = receipt.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) is [String: Any] { return "Moved to the next item." }
        if receipt.lowercased().contains("outcome is unknown") || receipt.lowercased().contains("outcome unknown") {
            return "The outcome is unknown. Check Activity before trying again."
        }
        if receipt.hasPrefix("Not executed:") || receipt.hasPrefix("NOT SENT") || receipt.hasPrefix("Nothing was sent") {
            return "That action was not executed. Check Activity for the reason and recovery options."
        }
        return "The action returned. Check Activity for its result."
    }

    static func answer(_ text: String) -> String {
        let marker = #"(?:^|(?<=[.!?])\s+)(?:up next\b|next up\b|(?:the |your )?next (?:email|message|item)\b|moving on\b)"#
        let end = text.range(of: marker, options: [.regularExpression, .caseInsensitive])?.lowerBound ?? text.endIndex
        return LiveClientBrain.withoutDispositionQuestion(String(text[..<end])).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A requested line permits only its own transcript, including deltas that split a word.
struct LiveSpeechAllowance {
    private let expected: String
    private var received = ""
    private(set) var finished = false
    private(set) var violated = false

    init(_ line: String) { expected = Self.normalized(line) }

    mutating func accept(_ fragment: String) -> String {
        guard !finished, !expected.isEmpty else { violated = true; return "" }
        let before = received.count
        let candidate = received + fragment
        let normalized = Self.normalized(candidate)
        if expected.hasPrefix(normalized) {
            received = candidate
            if normalized == expected { finished = true }
            return fragment
        }
        finished = true
        violated = true
        guard normalized.hasPrefix(expected + " ") else { return "" }
        let words = expected.split(separator: " ").count
        let regex = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)
        let matches = regex.matches(in: candidate, range: NSRange(candidate.startIndex..., in: candidate))
        guard matches.count >= words, let last = Range(matches[words - 1].range, in: candidate) else { return "" }
        var end = last.upperBound
        while end < candidate.endIndex, candidate[end].isPunctuation { end = candidate.index(after: end) }
        return String(candidate[..<end].dropFirst(before))
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}
