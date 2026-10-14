import AVFoundation
import Foundation
import Synchronization

final class WatchAudio: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.kiloforge.jo.watch-audio", qos: .userInitiated)
    private let queuedCapture = Atomic<Int>(0)
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var encoder = WatchPCMEncoder()
    private var callID: UUID?
    private var activating = false
    private var muted = false
    private var transmitting = false
    private var tapInstalled = false
    private var queuedPlayback = 0
    private var playbackSequence = WatchAudioSequence()
    private var observations: [NSObjectProtocol] = []

    func start(callID: UUID, send: @escaping @Sendable (WatchPacket) -> Void,
               failure: @escaping @Sendable (String) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !activating, self.callID == nil else {
                    continuation.resume(throwing: NSError(domain: "WatchAudio", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "The previous Watch audio session is still stopping. Try again shortly."
                    ]))
                    return
                }
                self.callID = callID
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .voiceChat, policy: .default, options: [])
                    activating = true
                    session.activate(options: []) { activated, error in
                        self.queue.async { [self] in
                            activating = false
                            guard self.callID == callID else {
                                tearDown()
                                continuation.resume(throwing: CancellationError())
                                return
                            }
                            guard activated, error == nil else {
                                tearDown()
                                continuation.resume(throwing: Self.startError(error ?? WatchAudioError.microphone,
                                                                              stage: "activating the audio session"))
                                return
                            }
                            do {
                                try configureEngine(callID: callID, send: send, failure: failure)
                                continuation.resume()
                            } catch {
                                tearDown()
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                } catch {
                    tearDown()
                    continuation.resume(throwing: Self.startError(error, stage: "configuring the audio session"))
                }
            }
        }
    }

    private func configureEngine(callID: UUID, send: @escaping @Sendable (WatchPacket) -> Void,
                                 failure: @escaping @Sendable (String) -> Void) throws {
        var stage = "enabling microphone voice processing"
        do {
            let engine = AVAudioEngine()
            self.engine = engine
            muted = false
            transmitting = false
            encoder = WatchPCMEncoder()
            playbackSequence = WatchAudioSequence()
            queuedPlayback = 0
            try engine.inputNode.setVoiceProcessingEnabled(true)
            let player = AVAudioPlayerNode()
            self.player = player
            engine.attach(player)
            let format = AVAudioFormat(standardFormatWithSampleRate: WatchPacket.sampleRate, channels: 1)!
            engine.connect(player, to: engine.mainMixerNode, format: format)
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw WatchAudioError.microphone
            }
            // Voice processing requires matching input and output I/O formats.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: inputFormat)
            engine.inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inputFormat.sampleRate / 10),
                                        format: inputFormat) { [weak self] buffer, _ in
                self?.capture(buffer, id: callID, send: send, failure: failure)
            }
            tapInstalled = true
            stage = "starting the microphone and speaker"
            engine.prepare()
            try engine.start()
            player.play()
            let center = NotificationCenter.default
            observations = [
                center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
                    guard let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                          type == AVAudioSession.InterruptionType.began.rawValue else { return }
                    failure("Watch audio was interrupted. Tap to start a new call.")
                },
                center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in
                    failure("Watch audio services restarted. Tap to start a new call.")
                }
            ]
        } catch { throw Self.startError(error, stage: stage) }
    }

    private static func startError(_ error: Error, stage: String) -> NSError {
        let underlying = error as NSError
        return NSError(domain: "WatchAudio", code: underlying.code, userInfo: [
            NSLocalizedDescriptionKey: "Watch failed while \(stage): \(underlying.localizedDescription) [\(underlying.domain)/\(underlying.code)]",
            NSUnderlyingErrorKey: error
        ])
    }

    private func capture(_ buffer: AVAudioPCMBuffer, id: UUID,
                         send: @escaping @Sendable (WatchPacket) -> Void,
                         failure: @escaping @Sendable (String) -> Void) {
        guard queuedCapture.wrappingAdd(1, ordering: .relaxed).oldValue < 20 else {
            queuedCapture.wrappingSubtract(1, ordering: .relaxed)
            failure(WatchAudioError.backlog.localizedDescription)
            return
        }
        guard let copy = WatchPCMEncoder.copy(buffer) else {
            queuedCapture.wrappingSubtract(1, ordering: .relaxed)
            failure(WatchAudioError.conversion.localizedDescription)
            return
        }
        queue.async { [self] in
            defer { queuedCapture.wrappingSubtract(1, ordering: .relaxed) }
            guard callID == id, transmitting else { return }
            if muted {
                for buffer in UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
            }
            do { try encoder.encode(copy, callID: id, send: send) }
            catch { failure(error.localizedDescription) }
        }
    }

    func play(_ packet: WatchPacket, failure: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            guard packet.validAudio, packet.callID == callID,
                  playbackSequence.accept(packet.sequence!), let bytes = packet.audio,
                  let player, let engine, engine.isRunning else { return }
            guard queuedPlayback < 8 else { failure(WatchAudioError.backlog.localizedDescription); return }
            let format = AVAudioFormat(standardFormatWithSampleRate: WatchPacket.sampleRate, channels: 1)!
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(WatchPacket.packetFrames)),
                  let samples = buffer.floatChannelData?[0] else {
                failure(WatchAudioError.conversion.localizedDescription)
                return
            }
            buffer.frameLength = buffer.frameCapacity
            bytes.withUnsafeBytes { bytes in
                for index in 0..<WatchPacket.packetFrames {
                    samples[index] = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
                }
            }
            queuedPlayback += 1
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async {
                    guard self?.callID == packet.callID else { return }
                    self?.queuedPlayback -= 1
                }
            }
        }
    }

    func setMuted(_ value: Bool) { queue.async { self.muted = value } }
    func beginSending() { queue.async { self.transmitting = true } }
    func stop() { queue.async { self.tearDown() } }

    private func tearDown() {
        callID = nil
        transmitting = false
        observations.forEach(NotificationCenter.default.removeObserver)
        observations = []
        if let engine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            player?.stop()
            engine.stop()
        }
        engine = nil
        tapInstalled = false
        player = nil
        queuedPlayback = 0
        guard !activating else { return }
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { print("watch: audio deactivation failed: \(error.localizedDescription)") }
    }
}
