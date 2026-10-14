import AVFoundation
import Foundation

/// The microphone for a local call: an `AVAudioEngine` tap on its own play-and-record session, set every start.
/// Default mode, not voice chat, which makes the reply sound thin; session and engine work runs on `AudioQueue`.
final class LocalMicrophone {
    struct Unavailable: LocalizedError {
        var errorDescription: String? { "The microphone isn't available right now." }
    }

    private let queue: AudioQueue
    private var engine: AVAudioEngine?

    init(queue: AudioQueue) {
        self.queue = queue
    }

    /// Mono samples in -1…1 at the hardware rate, and the same audio at 16 kHz for turn
    /// detection, from the audio thread.
    func start(onSamples: @escaping ([Float], Double) -> Void,
               onTurnAudio: @escaping ([Float]) -> Void = { _ in }) async throws {
        try await queue.run("local-voice mic start") { [weak self] in
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let hardware = input.outputFormat(forBus: 0)
            guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw Unavailable() }
            let rate = hardware.sampleRate
            let turnFormat = AVAudioFormat(standardFormatWithSampleRate: SemanticTurnDetector.sampleRate, channels: 1)!
            let turnConverter = AVAudioConverter(from: hardware, to: turnFormat)
            input.installTap(onBus: 0, bufferSize: 2048, format: hardware) { buffer, _ in
                let frames = Int(buffer.frameLength)
                guard frames > 0, let channel = buffer.floatChannelData?[0] else { return }
                onSamples(Array(UnsafeBufferPointer(start: channel, count: frames)), rate)
                let capacity = AVAudioFrameCount(Double(frames) * turnFormat.sampleRate / rate) + 32
                guard let turnConverter,
                      let turnBuffer = AVAudioPCMBuffer(pcmFormat: turnFormat, frameCapacity: capacity) else { return }
                var supplied = false
                var error: NSError?
                turnConverter.convert(to: turnBuffer, error: &error) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true
                    status.pointee = .haveData
                    return buffer
                }
                if error == nil, turnBuffer.frameLength > 0, let turn = turnBuffer.floatChannelData?[0] {
                    onTurnAudio(Array(UnsafeBufferPointer(start: turn, count: Int(turnBuffer.frameLength))))
                }
            }
            engine.prepare()
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw error
            }
            self?.engine = engine
            RealtimeLog.log(String(format: "local-voice: mic live at %.0f Hz", rate))
        }
    }

    func stop() async {
        try? await queue.run("local-voice mic stop") { [weak self] in
            guard let engine = self?.engine else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self?.engine = nil
        }
    }

    /// Hands the session back so the next Live dial starts from a clean one.
    func release() async {
        try? await queue.run("local-voice session release") {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
