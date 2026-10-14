import Foundation

/// Splits a reply into phrases at sentence ends; the first may also end at a clause break
/// after three or more words, so the first sound arrives before the first full stop.
struct SpokenPhraseBuffer {
    private(set) var pending = ""
    private var emitted = false

    mutating func append(_ text: String) -> [String] {
        pending += text
        var phrases: [String] = []
        while let boundary = pending.indices.first(where: { index in
            if pending[index] == "\n" { return true }
            let next = pending.index(after: index)
            guard next < pending.endIndex, pending[next].isWhitespace else { return false }
            if ".!?".contains(pending[index]) { return true }
            return !emitted && ",;:—".contains(pending[index])
                && pending[..<index].split(whereSeparator: \.isWhitespace).count >= 3
        }) {
            let end = pending.index(after: boundary)
            let phrase = String(pending[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending = String(pending[end...])
            if !phrase.isEmpty { phrases.append(phrase); emitted = true }
        }
        return phrases
    }

    mutating func finish() -> String {
        defer { pending = "" }
        return pending.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The whole of a finished reply as phrases.
    static func phrases(of text: String) -> [String] {
        var buffer = SpokenPhraseBuffer()
        var out = buffer.append(text)
        let tail = buffer.finish()
        if !tail.isEmpty { out.append(tail) }
        return out
    }
}
