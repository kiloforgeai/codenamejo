import Foundation

struct EmailReadAloud {
    enum Intent { case start, pause, resume, retry }
    enum Phase: String { case fetching, ready, queued, audible, paused, failed, completed }
    let id = UUID()
    let selection: MailSelection
    let threadID: String
    let profileID: String?
    let ownerID: String?
    var phase: Phase = .fetching
    var chunks: [String] = []
    var cursor = 0
    var completedBytes = 0
    var heardAudio = false
    var transcript = ""
    var sourceBytes = 0
    var cached = false
    var retryPending = false

    static func intent(_ text: String, retryPending: Bool) -> Intent? {
        var words = SpokenAnswerText.words(text)
        while let first = words.first, ["okay", "ok", "yeah", "please"].contains(first) { words.removeFirst() }
        if words.starts(with: ["can", "you"]) || words.starts(with: ["could", "you"]) || words.starts(with: ["would", "you"]) { words.removeFirst(2) }
        if words.first == "please" { words.removeFirst() }
        if words.last == "please" { words.removeLast() }
        let value = words.joined(separator: " ")
        if ["read the whole email", "read the whole email to me", "read this email", "read this email to me",
            "read this to me", "read it to me", "read it in full", "read the full email", "read the entire email",
            "read the entire email to me", "read this email in full"].contains(value) { return .start }
        if ["pause", "stop", "stop reading", "pause reading", "pause the reading"].contains(value) { return .pause }
        if ["resume", "resume reading", "continue reading", "keep reading", "read the rest"].contains(value) { return .resume }
        if retryPending, ["yes", "yes please", "try again", "retry", "yes try again"].contains(value) { return .retry }
        return nil
    }

    mutating func install(_ text: String, cached: Bool) {
        chunks = Self.split(text)
        sourceBytes = text.utf8.count
        self.cached = cached
        cursor = 0; completedBytes = 0; retryPending = false; phase = .ready
    }
    mutating func queue() -> String? {
        guard chunks.indices.contains(cursor), [.ready, .paused, .failed].contains(phase) else { return nil }
        phase = .queued; heardAudio = false; transcript = ""; retryPending = false
        return chunks[cursor]
    }
    mutating func observeAudio() { if phase == .queued || phase == .audible { heardAudio = true; phase = .audible } }
    mutating func observeTranscript(_ delta: String) {
        if phase == .queued || phase == .audible { transcript += delta }
    }
    mutating func finishChunk() -> Bool {
        guard phase == .audible, heardAudio, chunks.indices.contains(cursor),
              Self.words(transcript) == Self.words(chunks[cursor]) else { return false }
        completedBytes += chunks[cursor].utf8.count
        cursor += 1; phase = cursor == chunks.count ? .completed : .ready
        return true
    }
    mutating func pause() {
        guard phase != .completed else { return }
        phase = .paused; retryPending = false
    }
    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    static func split(_ text: String, maximumBytes: Int = 800) -> [String] {
        var remaining = text[...], chunks: [String] = []
        while !remaining.isEmpty {
            var end = remaining.startIndex, bytes = 0, boundary: String.Index?
            while end < remaining.endIndex {
                let next = remaining.index(after: end)
                let size = remaining[end..<next].utf8.count
                if bytes + size > maximumBytes, end > remaining.startIndex { break }
                bytes += size
                if remaining[end].isWhitespace { boundary = next }
                end = next
            }
            if end < remaining.endIndex, let boundary { end = boundary }
            chunks.append(String(remaining[..<end]))
            remaining = remaining[end...]
        }
        return chunks
    }
}
