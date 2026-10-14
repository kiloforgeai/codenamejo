#if DEBUG
import Foundation
import FactoryKit

final class InjectedVoiceInputDriver: VoiceInputDriver, @unchecked Sendable {
    private let injector: CaptureInjector
    @MainActor private lazy var turns = Container.shared.validationTurnDriver()

    init(injector: CaptureInjector) { self.injector = injector }
    func install(on tap: CaptureTapFanout) { tap.add(injector) }
    func prepare() async { await injector.prepareFixtures() }
    func setMuted(_ muted: Bool) { injector.setMuted(muted) }
    func attach(to track: RTCAudioTrack) { track.add(injector) }
    func detach(from track: RTCAudioTrack) { track.remove(injector) }
    @MainActor func start(settled: @escaping @MainActor () -> Bool) { turns.start(injector: injector, settled: settled) }
    @MainActor func receive(_ frame: Data) { turns.receive(frame) }
    @MainActor func stop() { turns.stop() }
}
#endif
