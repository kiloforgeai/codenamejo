import AVFoundation
import Combine
import Foundation

/// The local call's voice: `ParadeeTTS`, or `AVSpeechSynthesizer` when chosen or Paradee is not downloaded.
/// Each phrase is synthesized while the previous plays; `stop` makes the pending `speak` throw `CancellationError`.
@MainActor
final class LocalSpeech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum ParadeeState: Equatable {
        case idle, loading, ready
        case failed(String)
    }

    static let rate: Float = 0.52
    static let sample = "Hi, I'm Jo. You have three new emails and a meeting at ten thirty."

    @Published private(set) var paradeeState: ParadeeState = .idle

    private let paradee = ParadeeTTS()
    private let playback = PCMPlayback()
    private let synthesizer = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    private var finished: CheckedContinuation<Void, Error>?
    private var current: Task<Void, Error>?
    /// The last `stop`'s playback teardown, awaited before the next reply opens playback so
    /// the teardown cannot land on the new session.
    private var stopping: Task<Void, Never>?
    private var warming: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Downloads (first time only) and loads Paradee. Called at launch, because the local
    /// call is what answers when there is no connection, and by then it is too late to fetch.
    func warm() {
        guard warming == nil, paradeeState != .ready else { return }
        paradeeState = .loading
        warming = Task { [weak self] in
            guard let self else { return }
            do {
                try await paradee.initialize()
                paradeeState = .ready
            } catch {
                RealtimeLog.log("local-voice: paradee unavailable — \(error.localizedDescription)")
                paradeeState = .failed(error.localizedDescription)
            }
            warming = nil
        }
    }

    /// Speaks phrases as they arrive and returns once the last has been heard. `onPhrase`
    /// fires as each phrase starts to be voiced, so a caller can record what was heard.
    func speak(_ phrases: AsyncThrowingStream<String, Error>, choice: LocalVoice = .current,
               onPhrase: @escaping (String) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        stop()
        let paradeeReady = choice == .paradee && paradeeState == .ready
        if choice == .paradee, !paradeeReady {
            RealtimeLog.log("local-voice: paradee not ready (\(paradeeState)) — speaking in the system voice")
        }
        let stopping = self.stopping
        let task = Task { [weak self] in
            await stopping?.value
            guard let self else { return }
            if paradeeReady {
                try await speakParadee(phrases, onPhrase: onPhrase)
            } else {
                for try await phrase in phrases {
                    try Task.checkCancellation()
                    onPhrase(phrase)
                    try await speakSystem(phrase)
                }
            }
        }
        current = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// A finished piece of text, as phrases.
    func speak(_ text: String, choice: LocalVoice = .current) async throws {
        try await speak(Self.stream(SpokenPhraseBuffer.phrases(of: text)), choice: choice)
    }

    func stop() {
        current?.cancel()
        current = nil
        utterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        finished?.resume(throwing: CancellationError())
        finished = nil
        let playback = self.playback
        stopping = Task { await playback.stop() }
    }

    /// Settings' "hear a sample": not awaited. Outside a call the session is set to playback
    /// so the ring/silent switch does not mute it.
    func preview(_ choice: LocalVoice) {
        if choice == .paradee, paradeeState != .ready { warm() }
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .spokenAudio)
            try? session.setActive(true)
        }
        Task { try? await speak(Self.sample, choice: choice) }
    }

    static func stream(_ phrases: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            phrases.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    // MARK: - Paradee

    private func speakParadee(_ phrases: AsyncThrowingStream<String, Error>,
                              onPhrase: @escaping (String) -> Void) async throws {
        let session = try await playback.start()
        do {
            for try await phrase in phrases {
                // A phrase cut at a comma continues straight into the next one.
                let clause = phrase.last.map { ",;:—".contains($0) } ?? false
                var announced = false
                for phonemes in try await paradee.phonemeChunks(phrase) {
                    var samples = try await paradee.synthesize(phonemes: phonemes)
                    if clause { samples = ParadeeTTS.trimmingTrailingSilence(samples, keep: 2400) }
                    try Task.checkCancellation()
                    if !announced { announced = true; onPhrase(phrase) }
                    try await playback.append(samples, session: session)
                }
            }
            await playback.drain()
            try Task.checkCancellation()
            await playback.stop(session)
        } catch {
            await playback.stop(session)
            throw error
        }
    }

    // MARK: - System voice

    private func speakSystem(_ text: String) async throws {
        let utterance = AVSpeechUtterance(string: text)
        if let picked = LocalVoiceSettings.pick(from: LocalVoiceSettings.installed()) {
            utterance.voice = AVSpeechSynthesisVoice(identifier: picked.identifier)
        }
        utterance.rate = Self.rate
        utterance.prefersAssistiveTechnologySettings = false
        self.utterance = utterance
        try await withCheckedThrowingContinuation { continuation in
            finished = continuation
            synthesizer.speak(utterance)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard utterance === self.utterance else { return }
            self.utterance = nil
            self.finished?.resume()
            self.finished = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard utterance === self.utterance else { return }
            self.utterance = nil
            self.finished?.resume(throwing: CancellationError())
            self.finished = nil
        }
    }
}
