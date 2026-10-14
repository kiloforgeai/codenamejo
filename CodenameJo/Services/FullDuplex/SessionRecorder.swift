import AVFoundation
import Foundation

/// Records both sides of a hands-free call to one stereo file: you on the left, the assistant on the right.
/// The mic uses the capture-processing delegate (post-AEC): in M144 a renderer on a local track is never called.
final class SessionRecorder: NSObject, @unchecked Sendable {

    /// 48 kHz stereo, libwebrtc's internal rate, so input usually needs no conversion.
    private static let sampleRate: Double = 48_000
    private static let channelCount: AVAudioChannelCount = 2

    /// How far behind the live edge the writer commits, so the other channel's audio for the same
    /// instant can still arrive. Encoded frames can't be backfilled.
    private static let writeLag: Duration = .milliseconds(400)

    /// Everything mutable lives behind this queue. The audio callbacks hop onto
    /// it, so the work done inside must stay short.
    private let queue = DispatchQueue(label: "SessionRecorder", qos: .utility)

    private var mic = Timeline()
    private var assistant = Timeline()

    private var file: AVAudioFile?
    private var startedAt: ContinuousClock.Instant?
    /// Absolute frame index of the next frame to be written out.
    private var framesWritten: AVAudioFramePosition = 0
    private var flushTimer: DispatchSourceTimer?

    /// Which side of the call a buffer belongs to.
    private enum Side { case mic, assistant }

    /// Rate the APM reported. Only touched on the capture thread.
    private var captureRate: Double = 48_000

    /// Whether each tap has ever delivered a buffer, so a silent recording says which tap never fired.
    private var micBufferSeen = false
    private var assistantBufferSeen = false


    private func noteFirstBuffer(_ side: Side, frames: Int, rate: Double) {
        switch side {
        case .mic:
            guard !micBufferSeen else { return }
            micBufferSeen = true
            RealtimeLog.log("recorder: FIRST MIC BUFFER — \(frames) frames @ \(Int(rate)) Hz")
        case .assistant:
            guard !assistantBufferSeen else { return }
            assistantBufferSeen = true
            RealtimeLog.log("recorder: FIRST ASSISTANT BUFFER — \(frames) frames @ \(Int(rate)) Hz")
        }
    }

    private(set) var url: URL?

    // MARK: - Lifecycle

    /// Open a file for a call. Returns nil rather than throwing: a recording must never take a call down.
    @discardableResult
    func start(conversationId: String?) -> URL? {
        queue.sync { () -> URL? in
            guard file == nil else { return url }

            let url = Self.makeURL(conversationId: conversationId)
            // AAC m4a, ~64 kbps stereo: about 480 KB for a ten-minute call.
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: Self.channelCount,
                AVEncoderBitRateKey: 64_000,
            ]

            do {
                file = try AVAudioFile(forWriting: url, settings: settings)
            } catch {
                RealtimeLog.log("recorder: could not open \(url.lastPathComponent) — \(error.localizedDescription)")
                return nil
            }

            self.url = url
            startedAt = ContinuousClock.now
            framesWritten = 0
            mic.reset()
            assistant.reset()
            startFlushing()
            RealtimeLog.log("recorder: recording to \(url.lastPathComponent)")
            return url
        }
    }

    /// Close the file and return it. Safe to call more than once.
    @discardableResult
    func stop() -> URL? {
        queue.sync { () -> URL? in
            guard file != nil else { return url }
            flushTimer?.cancel()
            flushTimer = nil

            // Commit everything still buffered, with no lag.
            flush(upTo: max(mic.endFrame, assistant.endFrame))

            let seconds = Double(framesWritten) / Self.sampleRate
            file = nil
            startedAt = nil
            // A recording that received nothing is still a correctly-sized file of silence.
            let mic = micBufferSeen ? "mic ok" : "MIC SILENT"
            let assistant = assistantBufferSeen ? "assistant ok" : "ASSISTANT SILENT"
            RealtimeLog.log(String(format: "recorder: stopped — %.1fs, %@, %@", seconds, mic, assistant))
            micBufferSeen = false
            assistantBufferSeen = false
            return url
        }
    }

    // MARK: - Writing

    private func startFlushing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, let startedAt else { return }
            let elapsed = ContinuousClock.now - startedAt - Self.writeLag
            self.flush(upTo: self.frameIndex(for: elapsed))
        }
        timer.resume()
        flushTimer = timer
    }

    /// Interleave and write every frame up to `target`, padding either channel
    /// with silence where it has nothing.
    private func flush(upTo target: AVAudioFramePosition) {
        guard let file, target > framesWritten else { return }
        let count = AVAudioFrameCount(target - framesWritten)

        guard let format = AVAudioFormat(
                standardFormatWithSampleRate: Self.sampleRate,
                channels: Self.channelCount),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let channels = buffer.floatChannelData
        else { return }

        buffer.frameLength = count
        mic.read(from: framesWritten, count: Int(count), into: channels[0])
        assistant.read(from: framesWritten, count: Int(count), into: channels[1])

        do {
            try file.write(from: buffer)
            framesWritten = target
            // Nothing before the write head can ever be needed again.
            mic.discard(before: framesWritten)
            assistant.discard(before: framesWritten)
        } catch {
            RealtimeLog.log("recorder: write failed — \(error.localizedDescription)")
        }
    }

    /// Where a buffer arriving now belongs on the timeline.
    private func frameIndex(for elapsed: Duration) -> AVAudioFramePosition {
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) * 1e-18
        return AVAudioFramePosition((seconds * Self.sampleRate).rounded())
    }

    /// Land mono samples on one channel's timeline. Callers pass a copy: libwebrtc buffers are
    /// valid only for the duration of the callback.
    private func append(_ samples: [Float], to side: Side) {
        queue.async { [weak self] in
            guard let self, self.file != nil, let startedAt = self.startedAt else { return }
            let at = self.frameIndex(for: ContinuousClock.now - startedAt)
            // Frames behind the write head are already encoded; drop late buffers.
            guard at >= self.framesWritten else { return }
            switch side {
            case .mic: self.mic.write(samples, arrivingAt: at)
            case .assistant: self.assistant.write(samples, arrivingAt: at)
            }
        }
    }

    // MARK: - Format conversion

    /// Downmix to mono and rate-convert to 48 kHz by linear interpolation. Not `AVAudioConverter`:
    /// it is stateful, and the two callers run on different realtime threads with no lock.
    static func resampleToMono(_ input: [Float], channels: Int, from rate: Double) -> [Float] {
        var mono: [Float]
        if channels <= 1 {
            mono = input
        } else {
            let frames = input.count / channels
            mono = [Float](repeating: 0, count: frames)
            // Interleaved, so average across each frame's channels.
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += input[f * channels + c] }
                mono[f] = sum / Float(channels)
            }
        }

        guard rate != sampleRate, rate > 0, mono.count > 1 else { return mono }

        let ratio = sampleRate / rate
        let outCount = Int((Double(mono.count) * ratio).rounded())
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let position = Double(i) / ratio
            let low = Int(position)
            let high = min(low + 1, mono.count - 1)
            let t = Float(position - Double(low))
            out[i] = mono[low] * (1 - t) + mono[high] * t
        }
        return out
    }

    // MARK: - File naming

    /// Application Support, not Documents: these should be neither user-visible nor backed up.
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        var mutable = base
        try? mutable.setResourceValues(resources)
        return base
    }

    private static func makeURL(conversationId: String?) -> URL {
        // Conversation id to match the transcript; timestamp so two calls don't collide.
        let stamp = DateFormatter.recordingStamp.string(from: Date())
        let id = conversationId ?? "untagged"
        return directory.appendingPathComponent("\(stamp)_\(id).m4a")
    }
}

// MARK: - RTCAudioRenderer (the assistant's voice)

extension SessionRecorder: RTCAudioRenderer {

    func render(pcmBuffer: AVAudioPCMBuffer) {
        let frames = Int(pcmBuffer.frameLength)
        guard frames > 0 else { return }
        let format = pcmBuffer.format
        let channels = Int(format.channelCount)

        // libwebrtc delivers int16, not float; float is the exception.
        var samples: [Float]

        if let ints = pcmBuffer.int16ChannelData {
            samples = [Float](repeating: 0, count: frames * channels)
            if channels == 1 {
                for f in 0..<frames { samples[f] = Float(ints[0][f]) / 32_768.0 }
            } else {
                for c in 0..<channels {
                    for f in 0..<frames {
                        samples[f * channels + c] = Float(ints[c][f]) / 32_768.0
                    }
                }
            }
        } else if let data = pcmBuffer.floatChannelData {
            // `floatChannelData` is non-interleaved; flatten to the interleaved shape `resampleToMono` expects.
            if channels == 1 {
                samples = Array(UnsafeBufferPointer(start: data[0], count: frames))
            } else {
                samples = [Float](repeating: 0, count: frames * channels)
                for c in 0..<channels {
                    for f in 0..<frames { samples[f * channels + c] = data[c][f] }
                }
            }
        } else {
            // Logged once, not per buffer.
            if !assistantBufferSeen {
                RealtimeLog.log("recorder: assistant buffer is neither int16 nor float (\(pcmBuffer.format)) — channel will be silent")
                assistantBufferSeen = true
            }
            return
        }

        noteFirstBuffer(.assistant, frames: frames, rate: format.sampleRate)
        append(Self.resampleToMono(samples, channels: channels, from: format.sampleRate),
               to: .assistant)
    }
}

// MARK: - RTCAudioCustomProcessingDelegate (the microphone, post-AEC)

extension SessionRecorder: RTCAudioCustomProcessingDelegate {

    /// The only place the APM reports its rate; it runs on the same thread as `audioProcessingProcess`.
    func audioProcessingInitialize(sampleRate: Int, channels: Int) {
        captureRate = Double(sampleRate)
        RealtimeLog.log("recorder: capture tap live — \(sampleRate) Hz, \(channels) ch")
    }

    func audioProcessingProcess(audioBuffer: RTCAudioBuffer) {
        let frames = audioBuffer.frames
        guard frames > 0, audioBuffer.channels > 0 else { return }

        // Mono mic, so channel 0 only. `rawBufferForChannel` holds floats on the int16 scale (±32768);
        // clamp after scaling, since APM can exceed full scale and the AAC encoder distorts above ±1.0.
        let raw = audioBuffer.rawBuffer(forChannel: 0)
        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames { samples[i] = max(-1, min(1, raw[i] / 32_768.0)) }

        noteFirstBuffer(.mic, frames: frames, rate: captureRate)
        append(Self.resampleToMono(samples, channels: 1, from: captureRate), to: .mic)
    }

    func audioProcessingRelease() {
        RealtimeLog.log("recorder: capture tap released")
    }
}

// MARK: - Timeline

private extension SessionRecorder {

    /// One channel's audio, addressed by absolute frame index rather than arrival order.
    struct Timeline {
        /// Sample rate the capture side reported, for logging only — conversion
        /// is handled per-buffer.
        var inputRate: Double = 48_000

        private var samples: [Float] = []
        private var origin: AVAudioFramePosition = 0

        /// One past the last frame we hold.
        var endFrame: AVAudioFramePosition { origin + AVAudioFramePosition(samples.count) }

        mutating func reset() {
            samples.removeAll(keepingCapacity: true)
            origin = 0
            nextFrame = nil
        }

        /// Where the next contiguous buffer belongs. Both taps deliver 480 frames every 10 ms, and
        /// placing each by arrival time overlaps or gaps frames because jitter exceeds that spacing.
        private var nextFrame: AVAudioFramePosition?

        mutating func write(_ incoming: [Float], arrivingAt arrival: AVAudioFramePosition) {
            guard !incoming.isEmpty else { return }

            // The wall clock only places where a stream starts or resumes.
            let placement: AVAudioFramePosition
            if let next = nextFrame, abs(arrival - next) < Self.reanchorThreshold {
                // Common case: this chunk follows the last; counting keeps it sample-continuous.
                placement = next
            } else {
                // First buffer, or the tap stopped (renderer is silent between replies): re-anchor to the clock.
                placement = arrival
            }

            if samples.isEmpty { origin = placement }
            let offset = Int(placement - origin)
            guard offset >= 0 else { return }

            if offset > samples.count {
                samples.append(contentsOf: repeatElement(0, count: offset - samples.count))
            }

            if offset == samples.count {
                samples.append(contentsOf: incoming)
            } else {
                // Overwrite, never sum: summing overlapping frames doubles amplitude into clipping.
                for (i, value) in incoming.enumerated() {
                    let index = offset + i
                    if index < samples.count { samples[index] = value } else { samples.append(value) }
                }
            }

            nextFrame = placement + AVAudioFramePosition(incoming.count)
        }

    /// 250 ms of clock-vs-count drift: above scheduling jitter, below a pause between replies.
        private static let reanchorThreshold: AVAudioFramePosition = 12_000

        /// Copy `count` frames starting at absolute `frame`, zero-filling
        /// anything we don't hold.
        func read(from frame: AVAudioFramePosition, count: Int, into destination: UnsafeMutablePointer<Float>) {
            destination.update(repeating: 0, count: count)
            let offset = Int(frame - origin)
            guard offset < samples.count else { return }

            let start = max(0, offset)
            let available = min(count - (start - offset), samples.count - start)
            guard available > 0 else { return }

            samples.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                (destination + (start - offset)).update(from: base + start, count: available)
            }
        }

        mutating func discard(before frame: AVAudioFramePosition) {
            let drop = Int(frame - origin)
            guard drop > 0 else { return }
            if drop >= samples.count {
                samples.removeAll(keepingCapacity: true)
                origin = frame
            } else {
                samples.removeFirst(drop)
                origin = frame
            }
        }
    }
}

private extension DateFormatter {
    /// No colons (they break AirDrop and shells), and sortable so `ls` reads chronologically.
    static let recordingStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
}
