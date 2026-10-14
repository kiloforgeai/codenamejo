import AVFoundation
import Foundation
import Synchronization

final class WatchVoiceInputDriver: NSObject, VoiceInputDriver, RTCAudioCustomProcessingDelegate,
                                   RTCAudioRenderer, @unchecked Sendable {
    let callID: UUID
    private let link: WatchLink
    private let failure: @Sendable (String) -> Void
    private let input = WatchSampleBuffer()
    private let outputQueue = DispatchQueue(label: "com.kiloforge.jo.watch-output", qos: .userInitiated)
    private let closed = Atomic<Bool>(false)
    private let queuedBuffers = Atomic<Int>(0)
    private let capturedAudio = Atomic<Bool>(false)
    private var encoder = WatchPCMEncoder()
    private var sampleRate = 48_000.0
    private var inputSequence = WatchAudioSequence()
    private let receivedAudio = Atomic<Bool>(false)
    private let trackLock = NSLock()
    private var attachedTrack: RTCAudioTrack?
    private var sentAudio = false

    init(callID: UUID, link: WatchLink, failure: @escaping @Sendable (String) -> Void) {
        self.callID = callID
        self.link = link
        self.failure = failure
    }

    func accept(_ packet: WatchPacket) {
        guard !closed.load(ordering: .relaxed), packet.validAudio, packet.callID == callID,
              inputSequence.accept(packet.sequence!), let audio = packet.audio else { return }
        if !receivedAudio.exchange(true, ordering: .releasing) {
            RealtimeLog.log("watch: microphone packets arriving at iPhone")
        }
        if !input.append(audio) { failure(WatchAudioError.backlog.localizedDescription) }
    }

    func install(on tap: CaptureTapFanout) { tap.replaceInput(with: self) }
    func prepare() async {}
    func setMuted(_ muted: Bool) { input.setMuted(muted) }
    func attach(to track: RTCAudioTrack) {
        trackLock.lock()
        defer { trackLock.unlock() }
        track.source.volume = 0
        guard !closed.load(ordering: .acquiring), attachedTrack?.trackId != track.trackId else { return }
        attachedTrack?.remove(self)
        attachedTrack = track
        track.add(self)
        RealtimeLog.log("watch: attached reply renderer to track \(track.trackId)")
    }
    func detach(from track: RTCAudioTrack) {
        trackLock.lock()
        defer { trackLock.unlock() }
        guard attachedTrack?.trackId == track.trackId else { return }
        attachedTrack?.remove(self)
        attachedTrack = nil
    }
    @MainActor func start(settled: @escaping @MainActor () -> Bool) {}
    @MainActor func receive(_ frame: Data) {}
    @MainActor func stop() {}

    func close() {
        closed.store(true, ordering: .releasing)
        input.setMuted(true)
    }

    func audioProcessingInitialize(sampleRate: Int, channels: Int) { self.sampleRate = Double(sampleRate) }
    func audioProcessingRelease() {}
    func audioProcessingProcess(audioBuffer: RTCAudioBuffer) {
        guard audioBuffer.channels > 0 else { return }
        if !capturedAudio.exchange(true, ordering: .relaxed) {
            outputQueue.async { RealtimeLog.log("watch: WebRTC is consuming Watch microphone audio") }
        }
        let output = audioBuffer.rawBuffer(forChannel: 0)
        input.fill(output, count: audioBuffer.frames, sampleRate: sampleRate)
        for channel in 1..<audioBuffer.channels {
            audioBuffer.rawBuffer(forChannel: channel).update(from: output, count: audioBuffer.frames)
        }
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        // The first microphone packet confirms the Watch audio engine is ready for replies.
        guard !closed.load(ordering: .acquiring), receivedAudio.load(ordering: .acquiring) else { return }
        guard queuedBuffers.wrappingAdd(1, ordering: .relaxed).oldValue < 50 else {
            queuedBuffers.wrappingSubtract(1, ordering: .relaxed)
            failure(WatchAudioError.backlog.localizedDescription)
            return
        }
        guard let copy = WatchPCMEncoder.copy(pcmBuffer) else {
            queuedBuffers.wrappingSubtract(1, ordering: .relaxed)
            failure(WatchAudioError.conversion.localizedDescription)
            return
        }
        outputQueue.async { [self] in
            defer { queuedBuffers.wrappingSubtract(1, ordering: .relaxed) }
            guard !closed.load(ordering: .acquiring) else { return }
            if !sentAudio {
                sentAudio = true
                RealtimeLog.log("watch: reply audio renderer running on iPhone")
            }
            do { try encoder.encode(copy, callID: callID, send: link.send) }
            catch { failure(error.localizedDescription) }
        }
    }
}

final class WatchAudioRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var driver: WatchVoiceInputDriver?

    func install(_ driver: WatchVoiceInputDriver?) {
        lock.lock()
        self.driver = driver
        lock.unlock()
    }

    func inputDriver() -> any VoiceInputDriver {
        lock.lock()
        defer { lock.unlock() }
        if let driver { return driver }
        return MicrophoneInputDriver()
    }

    func audioConfiguration() -> any VoiceAudioConfiguration {
        lock.lock()
        defer { lock.unlock() }
        if driver != nil { return WatchVoiceAudioConfiguration() }
        return DeviceVoiceAudioConfiguration()
    }
}
