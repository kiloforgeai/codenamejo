import Foundation

@MainActor
final class EmailReadAloudController {
    typealias Source = (text: String, cached: Bool)
    var reading: EmailReadAloud?
    var fetch: (EmailReadAloud) async throws -> Source
    var isCurrent: (EmailReadAloud) -> Bool
    var speak: (String, @escaping () -> Bool) -> Void
    var stopSpeech: () -> Void
    var failure: (String) -> Void
    var trace: (EmailReadAloud, String) -> Void
    var fetchBound: TimeInterval = 45
    var playbackBound: TimeInterval = 90
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    var ownsSpeech: Bool {
        reading.map { [.fetching, .ready, .queued, .audible].contains($0.phase) } ?? false
    }

    init(fetch: @escaping (EmailReadAloud) async throws -> Source,
         isCurrent: @escaping (EmailReadAloud) -> Bool,
         speak: @escaping (String, @escaping () -> Bool) -> Void,
         stopSpeech: @escaping () -> Void, failure: @escaping (String) -> Void,
         trace: @escaping (EmailReadAloud, String) -> Void) {
        self.fetch = fetch; self.isCurrent = isCurrent; self.speak = speak
        self.stopSpeech = stopSpeech; self.failure = failure; self.trace = trace
    }

    func start(_ value: EmailReadAloud) {
        cancel()
        stopSpeech()
        reading = value
        trace(value, "requested")
        load()
    }

    func resume() {
        guard valid(), let reading, reading.phase != .completed else { return }
        stopSpeech()
        if reading.chunks.isEmpty { load() } else { queue() }
    }

    func pause() {
        guard ownsSpeech else { return }
        task?.cancel(); task = nil
        watchdog?.cancel(); watchdog = nil
        reading?.pause()
        stopSpeech()
        if let reading { trace(reading, "paused") }
    }

    func cancel() {
        task?.cancel(); task = nil
        watchdog?.cancel(); watchdog = nil
        let active = ownsSpeech
        if let reading { trace(reading, "cancelled") }
        reading = nil
        if active { stopSpeech() }
    }

    @discardableResult
    func valid() -> Bool {
        guard let reading else { return false }
        guard isCurrent(reading) else { cancel(); return false }
        return true
    }

    private func load() {
        guard valid(), var value = reading else { return }
        value.phase = .fetching; value.retryPending = false
        reading = value
        trace(value, "fetching")
        arm(fetchBound, id: value.id, message: "Loading the complete email timed out. Say yes to retry the same email.")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await fetch(value)
                guard !Task.isCancelled, reading?.id == value.id, valid() else { return }
                watchdog?.cancel(); watchdog = nil; task = nil
                reading?.install(source.text, cached: source.cached)
                if let reading { trace(reading, "source_complete") }
                queue()
            } catch {
                guard !Task.isCancelled, reading?.id == value.id, valid() else { return }
                fail("I couldn't load the complete email: \(error.localizedDescription) Say yes to retry the same email.")
            }
        }
    }

    private func queue() {
        guard valid(), let chunk = reading?.queue(), let value = reading else { return }
        trace(value, "chunk_queued")
        arm(playbackBound, id: value.id, message: "The reading didn't finish playing. Say yes to retry the unfinished passage.")
        speak(chunk) { [weak self] in
            guard let self, self.valid(), let current = self.reading else { return false }
            return current.id == value.id && current.cursor == value.cursor
                && [.queued, .audible].contains(current.phase)
        }
    }

    func audioStarted() {
        guard valid(), reading?.phase == .queued else { return }
        reading?.observeAudio()
        if let reading { trace(reading, "chunk_audible") }
    }

    func transcript(_ delta: String) {
        guard valid() else { return }
        reading?.observeTranscript(delta)
    }

    func audioStopped() {
        guard valid(), reading?.phase == .audible else { return }
        guard reading?.finishChunk() == true else {
            fail("I couldn't verify that the whole passage played. Say yes to retry the unfinished passage.")
            return
        }
        watchdog?.cancel(); watchdog = nil
        if let reading { trace(reading, reading.phase == .completed ? "completed" : "chunk_completed") }
        queue()
    }

    private func arm(_ seconds: TimeInterval, id: UUID, message: String) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, reading?.id == id, valid() else { return }
            fail(message)
        }
    }

    private func fail(_ message: String) {
        task?.cancel(); task = nil
        watchdog?.cancel(); watchdog = nil
        reading?.phase = .failed; reading?.retryPending = true
        stopSpeech()
        if let reading { trace(reading, "failed") }
        failure(message)
    }
}
