import Combine
import Foundation
import Network

/// Whether this phone currently has a network path.
/// Drives affordances only and fires no work. `.satisfied` means the OS has a route, not that
/// anything will answer, so callers still handle failure.
@MainActor
final class Connectivity: ObservableObject {

    /// Starts `true` so launch doesn't flash an offline state before the first path callback.
    @Published private(set) var isOnline = true

    /// Cellular or a personal hotspot. Not acted on today; published because the memo
    /// UI is where "not now, you're on cell" would eventually belong.
    @Published private(set) var isExpensive = false

    private let monitor = NWPathMonitor()
    /// `NWPathMonitor` requires its own queue and must not be given the main one — its
    /// callbacks arrive from the network stack.
    private let queue = DispatchQueue(label: "com.kiloforge.aurex.connectivity")
    private var started = false

    /// Idempotent, because it is called from `onViewAppear` and that fires on every
    /// return to the screen. Starting a second monitor would leak the first.
    func start() {
        guard !started else { return }
        started = true

        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            Task { @MainActor in
                self?.apply(online: online, expensive: expensive)
            }
        }
        monitor.start(queue: queue)
    }

    private func apply(online: Bool, expensive: Bool) {
        isExpensive = expensive
        guard isOnline != online else { return }
        isOnline = online
        RealtimeLog.log("network: \(online ? "online" : "offline")")
    }
}
