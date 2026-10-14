import Foundation
// WebRTC `RTC…` types come from `WebRTCAliases.swift`.

/// Mic level from the capture tap, for the part of a dial before WebRTC's `audioLevel` exists.
/// Peak sample over 32,768, close enough to libwebrtc's stat to share `SpeechIndicator`'s scale.
final class MicLevelTap: NSObject, RTCAudioCustomProcessingDelegate, @unchecked Sendable {

    /// Written from the audio thread, read from the level poll.
    private let lock = NSLock()
    /// Loudest sample seen since the last read, in webrtc's int16-ranged floats.
    private var peak: Float = 0
    private var muted = false
    private var capturedAudio = false

    var hasCapturedAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return capturedAudio
    }

    /// Peak since the last read, 0…1; reading clears it, so there must be only one reader.
    var level: Double {
        lock.lock()
        let value = peak
        peak = 0
        lock.unlock()
        return min(Double(value) / 32_768.0, 1)
    }

    /// Muted while the ready cue plays: our `AVAudioEngine` renders it outside libwebrtc's
    /// echo reference, so it reaches this tap.
    func setMuted(_ value: Bool) {
        lock.lock()
        muted = value
        if value { peak = 0 }
        lock.unlock()
    }

    // MARK: - RTCAudioCustomProcessingDelegate

    func audioProcessingInitialize(sampleRate: Int, channels: Int) {}

    func audioProcessingProcess(audioBuffer: RTCAudioBuffer) {
        let frames = audioBuffer.frames
        guard frames > 0, audioBuffer.channels > 0 else { return }
        // Channel 0 only; webrtc's floats are int16-ranged.
        let raw = audioBuffer.rawBuffer(forChannel: 0)
        var frame: Float = 0
        for index in 0..<frames { frame = max(frame, abs(raw[index])) }
        recordCapturePeak(frame)
    }

    func recordCapturePeak(_ frame: Float) {
        lock.lock()
        capturedAudio = true
        if !muted { peak = max(peak, frame) }
        lock.unlock()
    }

    func audioProcessingRelease() {}
}
