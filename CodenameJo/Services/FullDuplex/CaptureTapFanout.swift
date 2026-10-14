import Foundation
import Synchronization

/// Shares libwebrtc's single `capturePostProcessingDelegate` slot among consumers, and applies Mute.
/// Runs on the realtime audio thread; `sinks` is written only before the call connects, so needs no lock.
final class CaptureTapFanout: NSObject, RTCAudioCustomProcessingDelegate, @unchecked Sendable {

    /// Held strongly: the APM's delegate property is `weak`.
    private var sinks: [RTCAudioCustomProcessingDelegate] = []
    private var inputReplacement: RTCAudioCustomProcessingDelegate?

    func replaceInput(with input: RTCAudioCustomProcessingDelegate) {
        inputReplacement = input
    }

    /// Zeroes the capture buffer instead of disabling the track: on LiveKit's build `isEnabled = false`
    /// restarts the VPIO unit and stops the uplink, and server VAD needs packets to keep flowing.
    private let muted = Atomic<Bool>(false)

    func setMuted(_ isMuted: Bool) {
        muted.store(isMuted, ordering: .relaxed)
    }

    func add(_ sink: RTCAudioCustomProcessingDelegate) {
        sinks.append(sink)
    }

    func audioProcessingInitialize(sampleRate: Int, channels: Int) {
        inputReplacement?.audioProcessingInitialize(sampleRate: sampleRate, channels: channels)
        for sink in sinks { sink.audioProcessingInitialize(sampleRate: sampleRate, channels: channels) }
    }

    func audioProcessingProcess(audioBuffer: RTCAudioBuffer) {
        inputReplacement?.audioProcessingProcess(audioBuffer: audioBuffer)
        // Before the sinks, so a muted call is not recorded or transcribed either.
        if muted.load(ordering: .relaxed) {
            let frames = audioBuffer.frames
            if frames > 0 {
                for channel in 0..<audioBuffer.channels {
                    audioBuffer.rawBuffer(forChannel: channel).update(repeating: 0, count: frames)
                }
            }
        }
        for sink in sinks { sink.audioProcessingProcess(audioBuffer: audioBuffer) }
    }

    func audioProcessingRelease() {
        inputReplacement?.audioProcessingRelease()
        for sink in sinks { sink.audioProcessingRelease() }
    }
}
