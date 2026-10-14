#if DEBUG
import AVFoundation
import Foundation
import FactoryKit
import Synchronization
import os

/// DEBUG-only: speaks `INJECT_AUDIO` wav fixtures into the capture path, one per assistant turn.
/// It sits downstream of Voice-Processing I/O, so it tests neither the microphone, AEC nor barge-in.
final class CaptureInjector: NSObject, RTCAudioCustomProcessingDelegate, @unchecked Sendable {

    /// `RealtimeLog` never reaches the unified log; XCUITest reads this one.
    private static let logger = Logger(
        subsystem: "validation", category: "injector")

    /// Bundled wav basenames to speak in order, e.g. `INJECT_AUDIO=ask-fixture,yes-fixture`.
    /// `static let` because it is read on a realtime thread.
    static let fixtureNames: [String] = {
        (ProcessInfo.processInfo.environment["INJECT_AUDIO"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }()

    static var isEnabled: Bool { !fixtureNames.isEmpty }

    /// Silence from the assistant that counts as "your turn".
    private static let replyGapSeconds: Double = 0.8

    /// Assistant level (±1.0) above which it is speaking; silence sits near 0.001.
    private static let speakingLevel: Float = 0.01

    /// The tap goes live before the model is listening; anything said sooner is lost.
    private static let armAfterSeconds: Double = 4

    /// The fixtures as they ship, 48 kHz, int16 scale.
    private var fixtures48k: [[Float]] = []
    private var preparedRates: [Int: [[Float]]] = [:]

    /// Selected from precomputed buffers using the actual callback rate.
    private var clips: [[Float]] = []

    // MARK: Capture-thread state

    private let validation = Container.shared.voiceEvidence().runID != nil
    private let released = Atomic<Int>(0)
    private let muted = Atomic<Bool>(false)
    private let startedCount = Atomic<Int>(0)
    private let finishedCount = Atomic<Int>(0)
    private let observedRate = Atomic<Int>(0)
    private let invalidClip = Atomic<Bool>(false)
    private let lastAudio = Atomic<UInt64>(0)
    private let initialized = Atomic<Bool>(false)

    var validationStatus: (started: Int, finished: Int, rate: Int, failed: Bool, lastAudio: UInt64) {
        (startedCount.load(ordering: .relaxed), finishedCount.load(ordering: .relaxed),
         observedRate.load(ordering: .relaxed), invalidClip.load(ordering: .relaxed), lastAudio.load(ordering: .relaxed))
    }

    func releaseValidationClip(_ count: Int) { released.store(count, ordering: .releasing) }
    func setMuted(_ value: Bool) { muted.store(value, ordering: .relaxed) }
    private var clipIndex = 0
    private var cursor = 0
    private var captureRate: Double = 48_000
    private var framesSeen = 0
    private var armed = false

    // MARK: Render-thread state

    private var assistantHeard = false
    private var silentFrames = 0
    private var renderRate: Double = 48_000
    private var wasAwaiting = false

    /// The only value crossing the two audio threads: render sets it, capture consumes it.
    private let replyFinished = Atomic<Bool>(false)

    /// Set from a clip's end until its answer is heard, so unprompted speech isn't taken as the reply.
    private let awaitingReply = Atomic<Bool>(false)

    override init() {
        super.init()
        if !Self.isEnabled {
            Self.logger.notice("injector: idle — INJECT_AUDIO not set")
        }
    }

    func prepareFixtures() async {
        guard Self.isEnabled else { return }
        let prepared = await Task.detached(priority: .userInitiated) {
            let source = Self.fixtureNames.map { Self.load($0) }
            let rates = [8_000, 16_000, 32_000, 44_100, 48_000, 96_000]
            return (source, Dictionary(uniqueKeysWithValues: rates.map { rate in
                (rate, source.map { Self.resample($0, from: 48_000, to: Double(rate)) })
            }))
        }.value
        fixtures48k = prepared.0
        preparedRates = prepared.1
    }

    /// ±1.0 float from the file, scaled to the ±32768 the APM works in.
    private static func load(_ name: String) -> [Float] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            logger.notice("injector: fixture '\(name, privacy: .public)' missing from bundle")
            return []
        }
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0, file.length <= 48_000 * 180 else { return [] }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)),
                file.processingFormat.sampleRate == 48_000
            else {
                logger.notice("injector: '\(name, privacy: .public)' is not 48 kHz")
                return []
            }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0] else { return [] }
            let count = Int(buffer.frameLength)
            var scaled = [Float](repeating: 0, count: count)
            for i in 0..<count { scaled[i] = channel[i] * 32_768.0 }
            logger.notice(
                "injector: loaded '\(name, privacy: .public)' — \(Double(count) / 48_000.0)s")
            return scaled
        } catch {
            logger.notice(
                "injector: '\(name, privacy: .public)' failed — \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Linear interpolation with no low-pass; it aliases, which is fine for speech intelligibility.
    private static func resample(_ input: [Float], from: Double, to: Double) -> [Float] {
        guard !input.isEmpty, from != to, from > 0, to > 0 else { return input }
        let ratio = to / from
        let count = Int(Double(input.count) * ratio)
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let source = Double(i) / ratio
            let low = Int(source)
            let fraction = Float(source - Double(low))
            let a = input[min(low, input.count - 1)]
            let b = input[min(low + 1, input.count - 1)]
            out[i] = a + (b - a) * fraction
        }
        return out
    }

    // MARK: - Capture side: what the model hears

    func audioProcessingInitialize(sampleRate: Int, channels: Int) {
        guard Self.isEnabled else { return }
        if validation && initialized.exchange(true, ordering: .relaxed) {
            if observedRate.load(ordering: .relaxed) == sampleRate { return }
            if released.load(ordering: .acquiring) > 0 {
                invalidClip.store(true, ordering: .relaxed)
                clips = []
                return
            }
        }
        observedRate.store(sampleRate, ordering: .relaxed)
        captureRate = Double(sampleRate)
        clips = preparedRates[sampleRate] ?? []
        invalidClip.store(clips.isEmpty || clips.contains(where: \.isEmpty), ordering: .relaxed)
        clipIndex = 0
        cursor = 0
        framesSeen = 0
        armed = false
        replyFinished.store(false, ordering: .relaxed)
        awaitingReply.store(false, ordering: .relaxed)
        Self.logger.notice(
            "injector: tap live — \(sampleRate) Hz, \(channels) ch, \(self.clips.count) clip(s)")
    }

    func audioProcessingProcess(audioBuffer: RTCAudioBuffer) {
        guard Self.isEnabled else { return }
        let frames = audioBuffer.frames
        guard frames > 0 else { return }
        for channel in 0..<audioBuffer.channels {
            audioBuffer.rawBuffer(forChannel: channel).update(repeating: 0, count: frames)
        }
        guard !muted.load(ordering: .relaxed), !clips.isEmpty else { return }

        framesSeen += frames
        let ready = validation ? released.load(ordering: .acquiring) > 0
            : Double(framesSeen) >= Self.armAfterSeconds * captureRate
        guard armed || ready else { return }
        if !armed {
            startedCount.store(1, ordering: .relaxed)
            armed = true
            Self.logger.notice("injector: armed, speaking clip 1 of \(self.clips.count)")
        }

        // Once armed, every path writes the whole buffer: the microphone stays replaced for the call.
        let clip = clipIndex < clips.count ? clips[clipIndex] : []

        if cursor >= clip.count, clipIndex < clips.count {
            // First frame past the end: start listening, discarding any reply
            // that was already over. Only then does a finish count as ours.
            if !awaitingReply.load(ordering: .relaxed) {
                replyFinished.store(false, ordering: .relaxed)
                finishedCount.store(clipIndex + 1, ordering: .relaxed)
                awaitingReply.store(true, ordering: .relaxed)
                Self.logger.notice("injector: clip \(self.clipIndex + 1) spoken — waiting for the answer")
            } else if validation ? released.load(ordering: .acquiring) > clipIndex + 1
                : replyFinished.exchange(false, ordering: .relaxed) {
                awaitingReply.store(false, ordering: .relaxed)
                clipIndex += 1
                cursor = 0
                if clipIndex < clips.count {
                    startedCount.store(clipIndex + 1, ordering: .relaxed)
                    Self.logger.notice(
                        "injector: reply over — speaking clip \(self.clipIndex + 1) of \(self.clips.count)")
                } else {
                    Self.logger.notice("injector: script finished")
                }
            }
        }

        let current = clipIndex < clips.count ? clips[clipIndex] : []
        for channel in 0..<audioBuffer.channels {
            let out = audioBuffer.rawBuffer(forChannel: channel)
            for i in 0..<frames {
                let index = cursor + i
                out[i] = index < current.count ? current[index] : 0
            }
        }
        if cursor < current.count { cursor += frames }
    }

    func audioProcessingRelease() {
        guard Self.isEnabled else { return }
        Self.logger.notice("injector: tap released")
    }
}

// MARK: - Render side: hearing the assistant finish

extension CaptureInjector: RTCAudioRenderer {

    /// Level only, to hear the assistant stop. libwebrtc renders int16, so check `int16ChannelData` first.
    func render(pcmBuffer: AVAudioPCMBuffer) {
        guard Self.isEnabled else { return }
        let frames = Int(pcmBuffer.frameLength)
        guard frames > 0 else { return }
        renderRate = pcmBuffer.format.sampleRate

        // Speech already in flight when the clip ended is not an answer to it.
        let awaiting = awaitingReply.load(ordering: .relaxed)
        if awaiting != wasAwaiting {
            wasAwaiting = awaiting
            assistantHeard = false
            silentFrames = 0
        }
        guard awaiting || validation else { return }

        var sum: Float = 0
        if let ints = pcmBuffer.int16ChannelData {
            for f in 0..<frames {
                let v = Float(ints[0][f]) / 32_768.0
                sum += v * v
            }
        } else if let floats = pcmBuffer.floatChannelData {
            for f in 0..<frames { sum += floats[0][f] * floats[0][f] }
        } else {
            return
        }
        let rms = (sum / Float(frames)).squareRoot()

        if rms > Self.speakingLevel {
            lastAudio.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
            assistantHeard = true
            silentFrames = 0
        } else if assistantHeard {
            silentFrames += frames
            if Double(silentFrames) >= Self.replyGapSeconds * renderRate {
                assistantHeard = false
                silentFrames = 0
                replyFinished.store(true, ordering: .relaxed)
            }
        }
    }
}
#endif
