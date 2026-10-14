import Foundation

protocol VoiceAudioConfiguration: Sendable {
    var deviceModule: RTCAudioDeviceModuleType { get }
    var bypassVoiceProcessing: Bool { get }
    var usesPhoneAudio: Bool { get }
    func configure(factory: RTCPeerConnectionFactory) throws
    func prepare() async throws
    func close()
}

extension VoiceAudioConfiguration {
    var usesPhoneAudio: Bool { true }
    func configure(factory: RTCPeerConnectionFactory) throws {}
}

struct DeviceVoiceAudioConfiguration: VoiceAudioConfiguration {
    let deviceModule: RTCAudioDeviceModuleType = .platformDefault
    let bypassVoiceProcessing = false
    func prepare() async throws {}
    func close() {}
}

#if DEBUG && targetEnvironment(simulator)
import AVFoundation
import FactoryKit

final class SimulatorVoiceAudioConfiguration: VoiceAudioConfiguration, @unchecked Sendable {
    let deviceModule: RTCAudioDeviceModuleType = .audioEngine
    let bypassVoiceProcessing = true
    @Injected(\.voiceTransportQueue) private var queue
    private var active = false
    private let stateLock = NSLock()
    private var closed = false

    private func checkOpen() throws {
        try stateLock.withLock {
            guard !closed else { throw CancellationError() }
        }
    }

    func prepare() async throws {
        try await queue.run("simulator audio activation") { [self] in
            try checkOpen()
            guard !active else { return }
            let rtc = RTCAudioSession.sharedInstance()
            rtc.lockForConfiguration()
            defer { rtc.unlockForConfiguration() }
            let config = RTCAudioSessionConfiguration.webRTC()
            config.category = AVAudioSession.Category.playAndRecord.rawValue
            config.mode = AVAudioSession.Mode.default.rawValue
            config.categoryOptions = []
            try rtc.setConfiguration(config, active: true)
            active = true
        }
        try Task.checkCancellation()
        try checkOpen()
    }

    // Called on voiceTransportQueue after the peer has closed.
    func close() {
        stateLock.withLock { closed = true }
        deactivate()
    }

    private func deactivate() {
        guard active else { return }
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        do {
            try rtc.setActive(false)
            active = false
        } catch {
            Container.shared.voiceEvidence().record("scenario.failed", ["reason": "simulator audio deactivation failed: \(error.localizedDescription)"])
            RealtimeLog.log("simulator audio deactivation failed: \(error.localizedDescription)")
        }
    }
}
#endif
