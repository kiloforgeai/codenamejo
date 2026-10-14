import FactoryKit
import Foundation

/// The setup a call needs that `RootViewInteractor.onViewAppear` does, for launches with no view
/// (a CarPlay-only launch). Only call-critical work belongs here; `userProfile.start()` is idempotent.
@MainActor
final class AccountBootstrap {
    @Injected(\.userProfile) private var userProfile
    @Injected(\.connections) private var connections

    func start() {
        userProfile.start()
        // Guarded because `CommandViewInteractor.onViewAppear` refreshes too; this only has
        // to cover a launch where no view appears.
        if !connections.hasLoadedStatus {
            Task { await self.connections.refresh() }
        }
    }
}
