import AVFoundation

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
         label: String = "connect cue") {
        self.notes = notes
        self.label = label
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

    /// `nonisolated(unsafe)` because `engine.start()` and `stop()` block, so they run
    /// on `AudioQueue` while the main thread keeps the orb animating.
    private nonisolated(unsafe) let engine = AVAudioEngine()
    private nonisolated(unsafe) let player = AVAudioPlayerNode()
    private let queue = AudioQueue()

    /// Bumped by every `play()` and `stop()` so an overtaken cue can recognise itself and do nothing.
    private var generation = 0
    private var audible = false

    // MARK: - Lifecycle

    /// Plays the cue once, then releases the graph. Returns when the speaker is free, which tells the caller
    /// how long to hold the mic at zero gain.
    func play() async {
        generation += 1
        let mine = generation

        guard let buffer = cueBuffer() else {
            RealtimeLog.log("\(label): skipped — could not build the cue")
            return
        }

        let format = buffer.format
        let started = (try? await queue.run("\(label) start") { [engine, player] in
            // No `setCategory` or `setActive`: libwebrtc owns the session.
            if player.engine == nil { engine.attach(player) }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
            return true
        }) ?? false

        guard started else {
            RealtimeLog.log("\(label): not playing — engine unavailable")
            return
        }

        // The call can end while the engine is coming up.
        guard generation == mine else {
            await releaseGraph()
            RealtimeLog.log("\(label): call ended during bring-up — graph released")
            return
        }

        player.volume = 1
        // One-shot, so it is never cut mid-note.
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        player.play()
        audible = true
        // "Earpiece" here means something reconfigured the session.
        RealtimeLog.log("\(label): playing on \(AudioRoute.describeCurrentRoute())")

        try? await Task.sleep(for: Self.micDeafWindow)
        // `stop()` overtook us and has already released the graph.
        guard generation == mine else { return }
        audible = false
        await releaseGraph()
    }

    /// Silence and release early — the call ended while the cue was still playing.
    func stop() async {
        generation += 1
        guard audible else { return }
        audible = false

        // Ramp instead of cutting, to avoid a click.
        let steps = 6
        for step in (0..<steps).reversed() {
            player.volume = Float(step) / Float(steps)
            try? await Task.sleep(for: .milliseconds(8))
        }

        await releaseGraph()
        RealtimeLog.log("\(label): stopped")
    }

    private func releaseGraph() async {
        _ = try? await queue.run("\(label) release") { [engine, player] in
            player.stop()
            engine.stop()
            engine.disconnectNodeOutput(player)
            engine.detach(player)
            // No `setActive(false)`: this runs under a live call, and the ADM needs an active session.
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
