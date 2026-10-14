import Foundation

protocol VoiceInputDriver: Sendable {
    func install(on tap: CaptureTapFanout)
    func prepare() async
    func setMuted(_ muted: Bool)
    func attach(to track: RTCAudioTrack)
    func detach(from track: RTCAudioTrack)
    @MainActor func start(settled: @escaping @MainActor () -> Bool)
    @MainActor func receive(_ frame: Data)
    @MainActor func stop()
}

struct MicrophoneInputDriver: VoiceInputDriver {
    func install(on tap: CaptureTapFanout) {}
    func prepare() async {}
    func setMuted(_ muted: Bool) {}
    func attach(to track: RTCAudioTrack) {}
    func detach(from track: RTCAudioTrack) {}
    @MainActor func start(settled: @escaping @MainActor () -> Bool) {}
    @MainActor func receive(_ frame: Data) {}
    @MainActor func stop() {}
}
