import AVFoundation
import LiveKitWebRTC

final class WatchVoiceAudioConfiguration: NSObject, VoiceAudioConfiguration,
                                         LKRTCAudioDeviceModuleDelegate, @unchecked Sendable {
    let deviceModule: RTCAudioDeviceModuleType = .audioEngine
    let bypassVoiceProcessing = true
    let usesPhoneAudio = false

    func prepare() async throws {}
    func close() {}

    func configure(factory: RTCPeerConnectionFactory) throws {
        let module = factory.audioDeviceModule
        module.observer = self
        let result = module.setManualRenderingMode(true)
        guard result == 0 else {
            throw NSError(domain: "WatchAudio", code: result, userInfo: [
                NSLocalizedDescriptionKey: "Could not start the Watch audio relay (\(result))."
            ])
        }
        RealtimeLog.log("watch: WebRTC manual audio rendering enabled")
    }

    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, didCreateEngine engine: AVAudioEngine) -> Int { 0 }
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, willEnableEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool,
                           isVoiceProcessingEnabled: Bool) -> Int { 0 }
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, willStartEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int { 0 }
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, didStopEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int { 0 }
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, didDisableEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int { 0 }
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine) -> Int { 0 }
    func audioDeviceModuleDidUpdateDevices(_ module: LKRTCAudioDeviceModule) {}
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule,
                           didReceiveSpeechActivityEvent event: LKRTCSpeechActivityEvent) {}

    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, engine: AVAudioEngine,
                           configureInputFromSource source: AVAudioNode?, toDestination destination: AVAudioNode,
                           format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        // Clock the capture processor; WatchVoiceInputDriver replaces this silence with Watch PCM.
        let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate,
                                         channels: format.channelCount)!
        let clock = AVAudioSourceNode(format: sourceFormat) { isSilence, _, _, buffers in
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            isSilence.pointee = true
            return noErr
        }
        engine.attach(clock)
        engine.connect(clock, to: engine.mainMixerNode, format: sourceFormat)
        return 0
    }

    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, engine: AVAudioEngine,
                           configureOutputFromSource source: AVAudioNode, toDestination destination: AVAudioNode?,
                           format: AVAudioFormat, context: [AnyHashable: Any]) -> Int { 0 }
}
