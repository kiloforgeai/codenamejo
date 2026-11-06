import AVFoundation

private struct CueAudioGraph {
    let generation: Int
    let requestID: String
    let phase: String
    let diagnostics: VoiceDiagnostics.Session?
    let engine: AVAudioEngine
    let player: AVAudioPlayerNode

    func release() {
        player.stop()
        engine.stop()
        if player.engine != nil {
            engine.disconnectNodeOutput(player)
            engine.detach(player)
        }
        diagnostics?.record(.audioReleased, ["engine": "cue", "phase": phase, "request_id": requestID])
    }
}

/// Two-note cue for "you may talk now", inverted for "the call is down". It plays while libwebrtc owns the
/// session, so it never calls `setCategory`, `setActive(false)`, `engine.inputNode` or `RTCAudioSession`.
/// The end cue must play before teardown in `FullDuplexVoiceClient.stop()`; after `audio.deactivate()` it is silent.
@MainActor
final class ConnectCue {

    // MARK: - Shape

    // These are `nonisolated` so `DialTiming.connected()` can read them on libwebrtc's thread without a main-actor hop.

    /// Length of the rendered cue. Every timing below derives from it.
    private nonisolated static let length: Double = 0.60

    /// How long the cue occupies the speaker.
    nonisolated static var duration: Duration { .seconds(length) }

    /// Slack for the unmeasurable latency between `play()` and the first sample reaching the speaker.
    nonisolated static let tail: Duration = .milliseconds(150)

    /// How long the mic is held at zero gain so server VAD never hears the cue.
    /// Gain, not `setMuted` — see `FullDuplexTransport.setMicGain`.
    nonisolated static var micDeafWindow: Duration { duration + tail }

    /// `micDeafWindow` in ms. `DialTiming.connected()` fires before this window opens, so it adds this
    /// to report the wait the user actually sits through.
    nonisolated static var micDeafWindowMs: Double {
        let parts = micDeafWindow.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1_000_000_000_000_000
    }

    /// Fixed because `engine.outputNode` can report 0 Hz before the session is active; the mixer resamples.
    private static let sampleRate: Double = 48_000
    /// A4 → E5, a rising fifth.
    static let risingFifth: [(frequency: Double, at: Double)] = [
        (440.00, 0.00),
        (659.25, 0.14),
    ]

    /// E5 → A4: the same cue falling, so the end of a call is the same sound in the other direction.
    static let fallingFifth: [(frequency: Double, at: Double)] = [
        (659.25, 0.00),
        (440.00, 0.14),
    ]

    /// Which cue this instance plays, and what its log lines call it.
    private let notes: [(frequency: Double, at: Double)]
    private let label: String

    /// Defaults to the connect cue, so the existing call site reads as it did.
    init(notes: [(frequency: Double, at: Double)] = ConnectCue.risingFifth,
         label: String = "connect cue", queue: AudioQueue = AudioQueue()) {
        self.notes = notes
        self.label = label
        self.queue = queue
    }
    /// Sized so the second note's decay ends exactly at `length` — the buffer is silent
    /// at its end rather than approximately silent.
    private static let noteLength: Double = 0.46
    /// Exponential decay constant: what makes this a bell rather than a test tone.
    private static let decay: Double = 0.18
    /// 6 ms. Long enough not to click, short enough to still read as struck.
    private static let attack: Double = 0.006
    /// The last 30 ms of a note ramps to zero, so the buffer ends in real silence.
    private static let taper: Double = 0.030
    /// Amplitudes for the fundamental, octave and twelfth. The upper partials are what
    /// stop this sounding like a sine wave; kept low so it stays warm.
    private static let partials: [Float] = [1.0, 0.28, 0.09]
    /// Peak sample value. The buffer is normalised to it, so partials change the timbre, never the level.
    private static let peak: Float = 0.50

    /// Per instance, so the connect and end cues each cache their own buffer.
    private var cached: AVAudioPCMBuffer?

    // MARK: - Graph

    // Accessed only on AudioQueue, including creation and destruction.
    private nonisolated(unsafe) var graph: CueAudioGraph?
    private let queue: AudioQueue
    private let instanceID = UUID().uuidString
    private var generation = 0
    private var audibleGeneration: Int?
    var diagnostics: VoiceDiagnostics.Session?

    nonisolated static func validOutput(sampleRate: Double, channels: UInt32) -> Bool {
        sampleRate.isFinite && sampleRate > 0 && channels > 0
    }

    // MARK: - Lifecycle

    /// Plays the cue once, then releases the graph. Returns when the speaker is free, which tells the caller
    /// how long to hold the mic at zero gain.
    func play() async {
        generation += 1
        let mine = generation
        let requestID = "cue-\(instanceID)-\(mine)"
        let trace = diagnostics, phase = label
        guard let buffer = cueBuffer() else {
            trace?.record(.speechFailed, ["engine": "cue", "phase": phase, "request_id": requestID,
                "reason": "buffer_unavailable"])
            return
        }
        do {
            let started = try await queue.run("\(label) start and play") { [self] in
                graph?.release()
                let engine = AVAudioEngine(), player = AVAudioPlayerNode()
                graph = CueAudioGraph(generation: mine, requestID: requestID, phase: phase,
                    diagnostics: trace, engine: engine, player: player)
                let hardware = engine.outputNode.outputFormat(forBus: 0)
                trace?.record(.speechRequested, ["engine": "cue", "phase": phase, "request_id": requestID,
                    "sample_rate": String(hardware.sampleRate), "output_channels": String(hardware.channelCount)])
                guard Self.validOutput(sampleRate: hardware.sampleRate, channels: hardware.channelCount) else { return false }
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
                engine.prepare()
                try engine.start()
                player.volume = 1
                player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
                player.play()
                return true
            }
            guard started else {
                trace?.record(.speechFailed, ["engine": "cue", "phase": phase, "request_id": requestID,
                    "reason": "invalid_output_format"])
                await releaseGraph(generation: mine)
                return
            }
        } catch {
            trace?.record(.speechFailed, VoiceDiagnostics.failure(error).merging([
                "engine": "cue", "phase": phase, "request_id": requestID, "reason": "engine_start_failed"
            ]) { _, new in new })
            await releaseGraph(generation: mine)
            return
        }
        guard generation == mine, !Task.isCancelled else {
            await releaseGraph(generation: mine)
            trace?.record(.speechCancelled, ["engine": "cue", "phase": phase, "request_id": requestID,
                "reason": "superseded_during_start"])
            return
        }
        audibleGeneration = mine
        trace?.record(.speechStarted, ["engine": "cue", "phase": phase, "request_id": requestID])
        do { try await Task.sleep(for: Self.micDeafWindow) }
        catch {
            if audibleGeneration == mine { audibleGeneration = nil }
            await releaseGraph(generation: mine)
            trace?.record(.speechCancelled, ["engine": "cue", "phase": phase, "request_id": requestID,
                "reason": "task_cancelled"])
            return
        }
        guard generation == mine else { return }
        audibleGeneration = nil
        await releaseGraph(generation: mine)
        trace?.record(generation == mine ? .speechFinished : .speechCancelled,
            ["engine": "cue", "phase": phase, "request_id": requestID])
    }

    func stop() async {
        let mine = generation
        generation += 1
        if audibleGeneration == mine {
            audibleGeneration = nil
            for step in (0..<6).reversed() {
                do {
                    try await queue.run("\(label) fade") { [self] in
                        guard let graph, graph.generation == mine else { return }
                        graph.player.volume = Float(step) / 6
                    }
                    try await Task.sleep(for: .milliseconds(8))
                } catch { break }
            }
            diagnostics?.record(.speechCancelled, ["engine": "cue", "phase": label,
                "request_id": "cue-\(instanceID)-\(mine)", "reason": "stopped"])
        }
        await releaseGraph(generation: mine)
    }

    private func releaseGraph(generation: Int) async {
        do {
            try await queue.run("\(label) release") { [self] in
                guard let graph, graph.generation == generation else { return }
                graph.release()
                self.graph = nil
            }
        } catch {
            diagnostics?.record(.speechFailed, VoiceDiagnostics.failure(error).merging([
                "engine": "cue", "phase": label, "reason": "release_failed"
            ]) { _, new in new })
        }
    }

    // MARK: - Synthesis

    private func cueBuffer() -> AVAudioPCMBuffer? {
        if let cached { return cached }
        guard let format = AVAudioFormat(
                standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(Self.length * Self.sampleRate)),
              let channel = buffer.floatChannelData else { return nil }

        let frames = Int(buffer.frameCapacity)
        buffer.frameLength = buffer.frameCapacity
        let samples = channel[0]
        samples.update(repeating: 0, count: frames)
        for note in notes {
            Self.render(note, into: samples, frames: frames)
        }
        Self.normalise(samples, frames: frames)

        cached = buffer
        return buffer
    }

    /// One bell, summed (not assigned) into the cue at its offset; the notes overlap on purpose.
    private static func render(
        _ note: (frequency: Double, at: Double),
        into samples: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        let start = Int(note.at * sampleRate)
        let length = Int(noteLength * sampleRate)
        let taperFrames = max(1, Int(taper * sampleRate))

        for frame in 0..<length {
            let index = start + frame
            // The buffer is sized so this never trips; it guards a raw-pointer write.
            guard index < frames else { break }

            let seconds = Double(frame) / sampleRate
            var envelope = seconds < attack
                ? seconds / attack
                : exp(-(seconds - attack) / decay)
            if frame > length - taperFrames {
                envelope *= Double(length - frame) / Double(taperFrames)
            }

            var value: Float = 0
            for (harmonic, amplitude) in partials.enumerated() {
                let frequency = note.frequency * Double(harmonic + 1)
                value += amplitude * Float(sin(2 * .pi * frequency * seconds))
            }

            samples[index] += value * Float(envelope)
        }
    }

    /// Scales the cue so its loudest sample is exactly `peak`; the summed partials would otherwise clip.
    private static func normalise(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        var loudest: Float = 0
        for index in 0..<frames { loudest = max(loudest, abs(samples[index])) }
        guard loudest > 0 else { return }
        let scale = peak / loudest
        for index in 0..<frames { samples[index] *= scale }
    }
}
