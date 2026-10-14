import FactoryKit

extension Container {
    var watchAudio: Factory<WatchAudio> { self { WatchAudio() }.singleton }
    var watchCall: Factory<WatchCallService> {
        self { MainActor.assumeIsolated { WatchCallService() } }.singleton
    }
}
