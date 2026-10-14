import AVFoundation
import CoreMedia
import Foundation
import Speech

/// How the on-device transcriber reports results. `.progressive` won by ear and the Settings picker went (#86);
/// the other cases stay so the comparison can be rerun in code.
enum LocalTranscriberMode: String {
    /// Apple's preset for live, progressively-refined transcription.
    case progressive
    /// Volatile results with nothing else asked for. The plain baseline.
    case volatile
    /// Volatile plus `.fastResults`. Reads as a stutter: earlier results get revised more often.
    case volatileFast

    static let current: LocalTranscriberMode = .progressive

    /// What this mode asks Apple for, logged at dial; a `Preset` is opaque until read back at runtime.
    var optionsDescription: String {
        let options: Set<SpeechTranscriber.ReportingOption>
        switch self {
        case .progressive: options = SpeechTranscriber.Preset.progressiveTranscription.reportingOptions
        case .volatile: options = [.volatileResults]
        case .volatileFast: options = [.volatileResults, .fastResults]
        }
        return options.map { String(describing: $0) }.sorted().joined(separator: "+")
    }

    func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        switch self {
        case .progressive:
            return SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        case .volatile:
            return SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [])
        case .volatileFast:
            return SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [])
        }
    }
}

/// Transcribes the user's half of a call on device with `SpeechAnalyzer`, from the post-AEC capture tap.
/// Display only: the model still hears audio, and server VAD still owns turn boundaries.
final class LocalTranscriber: NSObject, @unchecked Sendable {

    /// The turn's text so far, and whether it has settled. Same shape as `FullDuplexVoiceClient.onUserTranscript`.
    var onTranscript: ((_ text: String, _ isFinal: Bool) -> Void)?

    /// Whether the local path is producing words. False until the model is installed and the
    /// analyzer started, so the server transcript shows meanwhile.
    private(set) var isLive = false

    private let queue = DispatchQueue(label: "LocalTranscriber", qos: .userInitiated)

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputs: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var captureFormat: AVAudioFormat?

    /// Written and read on the same audio thread.
    private var captureRate: Double = 48_000

    /// Everything below is touched only on `queue`.
    private var finalizedText = ""
    private var volatileText = ""
    private var isMuted = false
    /// Publishing is paused but the accumulator is kept — see `setSuppressed`.
    private var isSuppressed = false

    /// Capture that arrived before the analyzer was ready, oldest first, so the opening words aren't lost.
    private var pending: [(samples: [Float], rate: Double)] = []
    private var pendingFrames = 0

    /// About three seconds at 48 kHz; a model download can't be buffered through.
    private static let maxPendingFrames = 144_000

    /// True from `start()` until `begin()` has either gone live or given up. The
    /// capture path keeps delivering across that window so `pending` can hold it.
    private var isStarting = false

    /// When `start()` was called, for the `local-stt: live` line's warm-up figure.
    private var startedAt: ContinuousClock.Instant?

    /// Frames handed to the analyzer: the audio clock every result's `range` is expressed against.
    private var framesFed: Int64 = 0

    /// The audio time the last turn was settled at. Apple finalises lazily, so a fragment from a
    /// settled turn can arrive later; results ending at or before this are dropped.
    private var turnBoundary: CMTime = .zero

    // MARK: - Lifecycle

    /// Whether this device can transcribe locally. Apple Intelligence hardware gates it beyond iOS 26.
    static var isSupported: Bool { SpeechTranscriber.isAvailable }

    private static func authorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    /// Starts the analyzer, downloading the language model if this is the first
    /// time. Safe to call when unsupported — it logs and leaves `isLive` false.
    func start() {
        guard Self.isSupported else {
            RealtimeLog.log("local-stt: unavailable on this device — staying on the server transcript")
            return
        }
        startedAt = .now
        isStarting = true
        Task {
            await self.begin()
            self.isStarting = false
            // Gave up rather than went live; nothing will consume the backlog.
            self.queue.async { if !self.isLive { self.dropPending() } }
        }
    }

    private func begin() async {
        // `SpeechAnalyzer` uses the `SFSpeechRecognizer` authorization. Denied falls back to the server transcript.
        guard await Self.authorized() else {
            RealtimeLog.log("local-stt: speech recognition not authorized — staying on the server transcript")
            return
        }

        let wanted = Locale(identifier: "en-US")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            RealtimeLog.log("local-stt: no supported locale matching \(wanted.identifier)")
            return
        }

        let mode = LocalTranscriberMode.current
        let transcriber = mode.makeTranscriber(locale: locale)

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                RealtimeLog.log("local-stt: downloading the \(locale.identifier) model")
                try await request.downloadAndInstall()
            }
        } catch {
            // Never swallowed: a dead recogniser and a quiet user look identical.
            RealtimeLog.log("local-stt: model install failed — \(error.localizedDescription)")
            return
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            RealtimeLog.log("local-stt: no compatible audio format")
            return
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        await Self.biasTowardEndCallPhrases(analyzer)
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            RealtimeLog.log("local-stt: analyzer failed to start — \(error.localizedDescription)")
            continuation.finish()
            return
        }

        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = format
        self.inputs = continuation
        self.isLive = true
        // Warm-up is audio the analyzer could not hear; `pending` covers it.
        let warmUp = startedAt.map { "\(ContinuousClock.now - $0)" } ?? "unknown"
        RealtimeLog.log("local-stt: live — \(locale.identifier) at \(Int(format.sampleRate)) Hz"
            + " · mode \(mode.rawValue) [\(mode.optionsDescription)] · warm-up \(warmUp)")
        queue.async { self.drainPending() }

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    let range = result.range
                    let isFinal = result.isFinal
                    self.queue.async { self.absorb(text: text, isFinal: isFinal, range: range) }
                }
            } catch {
                RealtimeLog.log("local-stt: results stream failed — \(error.localizedDescription)")
                self?.isLive = false
            }
        }
    }

    /// Biases the analyzer toward the end-call phrases `SpokenCommand` acts on. Set before `start` so the
    /// first utterance is biased too; a failure is logged and swallowed, since the transcript still works.
    private static func biasTowardEndCallPhrases(_ analyzer: SpeechAnalyzer) async {
        let context = AnalysisContext()
        // End-call phrases plus product vocabulary; `contextualStrings` takes one list per locale.
        let phrases = SpokenCommand.biasingPhrases + SpokenCommand.vocabularyPhrases
        context.contextualStrings = [.general: phrases]
        do {
            try await analyzer.setContext(context)
            RealtimeLog.log(
                "local-stt: biased toward \(phrases.count) phrases — "
                    + "\(SpokenCommand.biasingPhrases.count) end-call, "
                    + "\(SpokenCommand.vocabularyPhrases.count) vocabulary")
        } catch {
            RealtimeLog.log("local-stt: end-call bias not applied — \(error.localizedDescription)")
        }
    }

    /// Tears the analyzer down at the end of a call.
    func stop() {
        isLive = false
        resultsTask?.cancel()
        inputs?.finish()
        inputs = nil
        let analyzer = self.analyzer
        self.analyzer = nil
        transcriber = nil
        converter = nil
        Task { try? await analyzer?.finalizeAndFinishThroughEndOfInput() }
        queue.async {
            self.finalizedText = ""
            self.volatileText = ""
            self.isSuppressed = false
            self.dropPending()
        }
    }

    // MARK: - Turn boundaries, owned by server VAD

    /// Audio from somewhere other than the WebRTC capture tap: mono floats in -1…1 at `rate`.
    func ingest(_ samples: [Float], rate: Double) {
        guard isLive || isStarting else { return }
        queue.async { self.feed(samples, rate: rate) }
    }

    /// Finalizes everything fed so far and returns the turn's text; later results for this audio
    /// are dropped via `turnBoundary`.
    func settle() async -> String {
        let (analyzer, end): (SpeechAnalyzer?, CMTime) = queue.sync {
            (self.analyzer, CMTime(value: framesFed, timescale: CMTimeScale(analyzerFormat?.sampleRate ?? 16_000)))
        }
        try? await analyzer?.finalize(through: end)
        // The results loop hands the finals to `queue` asynchronously; give it a moment.
        try? await Task.sleep(for: .milliseconds(40))
        return queue.sync {
            turnBoundary = end
            return combined
        }
    }

    /// Forgets everything heard so far, including undelivered results for audio already fed.
    func discardThroughNow() {
        queue.async {
            self.turnBoundary = CMTime(value: self.framesFed,
                                       timescale: CMTimeScale(self.analyzerFormat?.sampleRate ?? 16_000))
            self.finalizedText = ""
            self.volatileText = ""
        }
    }

    /// Mute hides the words but leaves the recogniser running: the capture tap is upstream of the mute switch.
    func setMuted(_ muted: Bool) {
        queue.async {
            self.isMuted = muted
            guard !muted else { return }
            // Words spoken while muted are cleared so they can't merge into the next turn.
            self.finalizedText = ""
            self.volatileText = ""
        }
    }

    /// Stop publishing while keeping the accumulator, unlike `setMuted`, which discards.
    /// The connect cue uses it to keep its own notes off screen while inviting speech.
    func setSuppressed(_ suppressed: Bool) {
        queue.async {
            self.isSuppressed = suppressed
            guard !suppressed else { return }
            // Flushed now: a sentence finished inside the window produces no later result.
            let text = self.combined
            guard !self.isMuted, !text.isEmpty else { return }
            Task { @MainActor in self.onTranscript?(text, false) }
        }
    }

    // MARK: - Results

    private var combined: String {
        (finalizedText + " " + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Apple finalises in pieces rather than per utterance, so a turn is the
    /// concatenation of its finalised fragments plus whatever is still volatile.
    private func absorb(text: String, isFinal: Bool, range: CMTimeRange) {
        // Audio from an already-settled turn; see `turnBoundary`.
        if range.end <= turnBoundary { return }
        if isFinal {
            finalizedText = (finalizedText + " " + text).trimmingCharacters(in: .whitespacesAndNewlines)
            volatileText = ""
        } else {
            volatileText = text
        }
        // Still absorbed while muted or suppressed, but not published.
        guard !isMuted, !isSuppressed else { return }
        let combined = self.combined
        guard !combined.isEmpty else { return }
        Task { @MainActor in self.onTranscript?(combined, false) }
    }

    // MARK: - Audio in

    /// Hand the backlog to the analyzer in capture order, then forget it.
    private func drainPending() {
        guard !pending.isEmpty else { return }
        let held = pending
        let frames = pendingFrames
        pending = []
        pendingFrames = 0
        for chunk in held { feed(chunk.samples, rate: chunk.rate) }
        RealtimeLog.log("local-stt: fed \(frames) frames captured before the analyzer was ready")
    }

    private func dropPending() {
        guard !pending.isEmpty else { return }
        RealtimeLog.log("local-stt: dropped \(pendingFrames) frames — the analyzer never came up")
        pending = []
        pendingFrames = 0
    }

    private func feed(_ samples: [Float], rate: Double) {
        guard let analyzerFormat, let inputs else {
            // Held for the analyzer; when full, stop taking rather than evict the sentence's head.
            guard pendingFrames + samples.count <= Self.maxPendingFrames else { return }
            pending.append((samples, rate))
            pendingFrames += samples.count
            return
        }

        if captureFormat?.sampleRate != rate {
            captureFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
            converter = nil
        }
        guard let captureFormat else { return }
        if converter == nil {
            converter = AVAudioConverter(from: captureFormat, to: analyzerFormat)
        }
        guard let converter,
              let source = AVAudioPCMBuffer(
                pcmFormat: captureFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = source.floatChannelData
        else { return }

        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer in
            channel[0].update(from: buffer.baseAddress!, count: samples.count)
        }

        // One frame of slack: the converter can emit one more than the ratio suggests.
        let ratio = analyzerFormat.sampleRate / captureFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let error {
            RealtimeLog.log("local-stt: convert failed — \(error.localizedDescription)")
            return
        }
        guard output.frameLength > 0 else { return }
        // Timestamped so each result's range can be compared against `turnBoundary`.
        let start = CMTime(value: framesFed, timescale: CMTimeScale(analyzerFormat.sampleRate))
        framesFed += Int64(output.frameLength)
        inputs.yield(AnalyzerInput(buffer: output, bufferStartTime: start))
    }
}

// MARK: - RTCAudioCustomProcessingDelegate (the microphone, post-AEC)

extension LocalTranscriber: RTCAudioCustomProcessingDelegate {

    func audioProcessingInitialize(sampleRate: Int, channels: Int) {
        captureRate = Double(sampleRate)
    }

    func audioProcessingProcess(audioBuffer: RTCAudioBuffer) {
        // `isStarting` keeps the warm-up from eating the opening words: `feed` holds them.
        guard isLive || isStarting else { return }
        let frames = audioBuffer.frames
        guard frames > 0, audioBuffer.channels > 0 else { return }

        // Channel 0, scaled off webrtc's int16-ranged floats, as in `SessionRecorder`.
        let raw = audioBuffer.rawBuffer(forChannel: 0)
        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            samples[i] = max(-1, min(1, raw[i] / 32_768.0))
        }

        let rate = captureRate
        queue.async {
            self.feed(samples, rate: rate)
        }
    }

    func audioProcessingRelease() {}
}
