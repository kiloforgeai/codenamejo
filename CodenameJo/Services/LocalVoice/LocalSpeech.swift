import AVFoundation
import Combine
import FactoryKit
import Foundation

/// The local call's voice: `ParadeeTTS`, or `AVSpeechSynthesizer` when chosen or Paradee is not downloaded.
/// Each phrase is synthesized while the previous plays; `stop` makes the pending `speak` throw `CancellationError`.
@MainActor
class LocalSpeech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum ParadeeState: Equatable {
        case idle, loading, ready
        case failed(String)
    }

    struct PlaybackFailure: LocalizedError {
        let phase: String
        var errorDescription: String? { "Jo's system voice did not \(phase). Check Sound output or try a new session." }
    }

    static let rate: Float = 0.52
    static let sample = "Hi, I'm Jo. If you can hear me, voice playback is working."

    @Published var paradeeState: ParadeeState = .idle
    @Published var isPreviewing = false
    @Published var previewMessage: String?
    @Injected(\.localVoiceQueue) private var audioQueue
    private var previewTask: Task<Void, Never>?
    private var previewID: UUID?

    #if !targetEnvironment(macCatalyst)
    private let paradee = ParadeeTTS()
    #endif
    private let playback = PCMPlayback()
    private let synthesizer: AVSpeechSynthesizer
    private var playbackWatchdog: Task<Void, Never>?
    private var speechTrace: VoiceDiagnostics.Session?
    private var utteranceID: UUID?
    private var speechDidStart = false
    private var utterance: AVSpeechUtterance?
    private var finished: CheckedContinuation<Void, Error>?
    private var current: Task<Void, Error>?
    /// The last `stop`'s playback teardown, awaited before the next reply opens playback so
    /// the teardown cannot land on the new session.
    private var stopping: Task<Void, Never>?
    private var warming: Task<Void, Never>?

    init(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        super.init()
        synthesizer.delegate = self
        #if targetEnvironment(macCatalyst)
        // System speech owns its playback session instead of inheriting the microphone's aggregate device.
        synthesizer.usesApplicationAudioSession = false
        #endif
    }

    /// Downloads (first time only) and loads Paradee. Called at launch, because the local
    /// call is what answers when there is no connection, and by then it is too late to fetch.
    func warm() {
        #if !targetEnvironment(macCatalyst)
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
        #endif
    }

    /// Speaks phrases as they arrive and returns once the last has been heard. `onPhrase`
    /// fires as each phrase starts to be voiced, so a caller can record what was heard.
    func speak(_ phrases: AsyncThrowingStream<String, Error>, choice: LocalVoice = .current,
               diagnostics: VoiceDiagnostics.Session? = nil, onPhrase: @escaping (String) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        stopSpeech()
        #if targetEnvironment(macCatalyst)
        let paradeeReady = false
        #else
        let paradeeReady = choice == .paradee && paradeeState == .ready
        #endif
        if choice == .paradee, !paradeeReady {
            RealtimeLog.log("local-voice: paradee not ready (\(paradeeState)) — speaking in the system voice")
        }
        let stopping = self.stopping
        let task = Task { [weak self] in
            await stopping?.value
            guard let self else { return }
            if paradeeReady {
                #if !targetEnvironment(macCatalyst)
                try await speakParadee(phrases, onPhrase: onPhrase)
                #endif
            } else {
                for try await phrase in phrases {
                    try Task.checkCancellation()
                    onPhrase(phrase)
                    try await speakSystem(phrase, diagnostics: diagnostics)
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
    func speak(_ text: String, choice: LocalVoice = .current, diagnostics: VoiceDiagnostics.Session? = nil) async throws {
        try await speak(Self.stream(SpokenPhraseBuffer.phrases(of: text)), choice: choice, diagnostics: diagnostics)
    }

    func stopAndWait() async {
        stop()
        await stopping?.value
    }

    func stop() {
        previewID = nil
        previewTask?.cancel()
        previewTask = nil
        isPreviewing = false
        previewMessage = nil
        stopSpeech()
    }

    private func stopSpeech() {
        current?.cancel()
        current = nil
        playbackWatchdog?.cancel()
        playbackWatchdog = nil
        if let utteranceID {
            speechTrace?.record(.speechCancelled, ["utterance_id": utteranceID.uuidString, "reason": "stopped"])
        }
        self.utteranceID = nil
        speechTrace = nil
        utterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        finished?.resume(throwing: CancellationError())
        finished = nil
        let playback = self.playback
        stopping = Task { await playback.stop() }
    }

    /// Playback outside a call never opens an input device.
    func speakWithoutMicrophone(_ text: String, choice: LocalVoice = .current,
                                diagnostics: VoiceDiagnostics.Session? = nil) async throws {
        try await Container.shared.voiceAudioHandoff().wait()
        #if !targetEnvironment(macCatalyst)
        try await audioQueue.run("local speech playback session") {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        }
        #endif
        try Task.checkCancellation()
        try await speak(text, choice: choice, diagnostics: diagnostics)
    }

    /// The sample reports routing problems without changing the user's sound settings.
    func preview(_ choice: LocalVoice) {
        guard !isPreviewing else { return }
        if choice == .paradee, paradeeState != .ready { warm() }
        let id = UUID()
        previewID = id
        isPreviewing = true
        previewMessage = "Playing Jo's voice…"
        previewTask = Task { [weak self] in
            guard let self else { return }
            let trace = Container.shared.voiceDiagnostics().begin(engine: "speaker_test",
                userID: Container.shared.backend().userId)
            defer { trace.record(.sessionEnded) }
            do {
                let issue = try await audioQueue.run("speaker availability", AudioOutputStatus.issue)
                try Task.checkCancellation()
                if let issue { previewMessage = issue }
                try await speakWithoutMicrophone(Self.sample, choice: choice, diagnostics: trace)
                guard previewID == id else { return }
                previewMessage = issue ?? "Sample finished. Didn't hear it? Check Sound output in System Settings."
            } catch is CancellationError {
                guard previewID == id else { return }
                previewMessage = nil
            } catch {
                guard previewID == id else { return }
                previewMessage = "Jo couldn't play audio: \(error.localizedDescription)"
                RealtimeLog.log("local-voice: preview failed — \(error.localizedDescription)")
            }
            guard previewID == id else { return }
            isPreviewing = false
            previewTask = nil
        }
    }

    static func stream(_ phrases: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            phrases.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    // MARK: - Paradee

    #if !targetEnvironment(macCatalyst)
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

    #endif

    // MARK: - System voice

    private func speakSystem(_ text: String, diagnostics: VoiceDiagnostics.Session?) async throws {
        let utterance = AVSpeechUtterance(string: text)
        if let picked = LocalVoiceSettings.pick(from: LocalVoiceSettings.installed()) {
            utterance.voice = AVSpeechSynthesisVoice(identifier: picked.identifier)
        }
        utterance.rate = Self.rate
        utterance.prefersAssistiveTechnologySettings = false
        self.utterance = utterance
        self.speechTrace = diagnostics
        let id = UUID()
        utteranceID = id
        speechDidStart = false
        diagnostics?.record(.speechRequested, ["utterance_id": id.uuidString, "characters": String(text.count),
            "voice_id": utterance.voice?.identifier ?? "system_default"])
        playbackWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.utteranceID == id else { return }
            if !self.speechDidStart { self.failPlayback(id: id, phase: "start"); return }
            let remaining = min(120.0, max(15.0, Double(text.count) / 6.0))
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            self.failPlayback(id: id, phase: "finish")
        }
        try await withCheckedThrowingContinuation { continuation in
            finished = continuation
            synthesizer.speak(utterance)
        }
    }

    private func failPlayback(id: UUID, phase: String) {
        guard utteranceID == id else { return }
        speechTrace?.record(.speechFailed, ["utterance_id": id.uuidString, "phase": phase])
        utteranceID = nil
        utterance = nil
        speechTrace = nil
        synthesizer.stopSpeaking(at: .immediate)
        finished?.resume(throwing: PlaybackFailure(phase: phase))
        finished = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard utterance === self.utterance, let id = self.utteranceID else { return }
            self.speechDidStart = true
            self.speechTrace?.record(.speechStarted, ["utterance_id": id.uuidString])
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.complete(utterance, cancelled: false) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.complete(utterance, cancelled: true) }
    }

    private func complete(_ utterance: AVSpeechUtterance, cancelled: Bool) {
        guard utterance === self.utterance, let id = utteranceID else { return }
        playbackWatchdog?.cancel()
        playbackWatchdog = nil
        speechTrace?.record(cancelled ? .speechCancelled : .speechFinished, ["utterance_id": id.uuidString])
        self.utterance = nil
        utteranceID = nil
        speechTrace = nil
        if cancelled { finished?.resume(throwing: CancellationError()) }
        else { finished?.resume() }
        finished = nil
    }
}
