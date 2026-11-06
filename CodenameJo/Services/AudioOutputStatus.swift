import AVFoundation
#if targetEnvironment(macCatalyst)
import CoreAudio
#endif

enum AudioOutputStatus {
    static func issue() -> String? {
        #if targetEnvironment(macCatalyst)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                               &address, 0, nil, &size, &device)
        guard status == noErr else {
            RealtimeLog.log("audio: output device query failed (\(status))")
            return "Couldn't check the speakers. Check Sound output in System Settings."
        }
        guard device != kAudioObjectUnknown else {
            return "No speaker or headphones are available. Choose an output in System Settings → Sound."
        }
        address.mScope = kAudioDevicePropertyScopeOutput
        address.mSelector = kAudioDevicePropertyMute
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &address),
           AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr,
           muted != 0 {
            return "Your Mac's sound output is muted. Unmute it in System Settings → Sound, then try again."
        }
        address.mSelector = kAudioDevicePropertyVolumeScalar
        var volume: Float32 = 1
        size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(device, &address),
           AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr,
           volume <= 0.1 {
            return "Your Mac's output volume is very low. Turn it up in System Settings → Sound."
        }
        return nil
        #else
        return AVAudioSession.sharedInstance().outputVolume <= 0.1 ? "Turn on or turn up your volume." : nil
        #endif
    }
}
