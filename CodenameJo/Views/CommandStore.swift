import FactoryKit
import Foundation

/// The current user's command history, kept on this phone in `TurnStore`.
@MainActor
class CommandStore: ObservableObject {
    @Published var commands: [CommandRecord] = []
    @Published var isLoading = false

    /// Injected rather than `BackendService.shared`, so a test or a preview can
    /// give this store a backend of its own.
    @Injected(\.backend) private var backend
    @Injected(\.localContext) private var localContext

    private var turns: TurnStore { TurnStore(database: localContext.dbPool) }

    /// Re-read History for the active profile.
    func refresh() async {
        // **Signed out means no history.** The rows of an account that just left are
        // purged in the background and must not be drawn meanwhile.
        guard backend.isSignedIn else {
            RealtimeLog.log("history: signed out — no refresh")
            commands = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        let owner = Container.shared.workspaceProfiles().contextOwner
        do {
            let stored = try await turns.history(owner: owner)
            // A sign-out or profile switch during the read leaves this answer to the next one.
            guard owner == Container.shared.workspaceProfiles().contextOwner else { return }
            commands = stored
        } catch {
            RealtimeLog.log("history refresh failed: \(error)")
            commands = []
        }
    }

    /// Store a finished turn. Returns whether it was stored, so the caller can queue a retry.
    @discardableResult
    func save(_ record: CommandRecord, expectedUserId: String? = nil) async -> Bool {
        if let expectedUserId, backend.userId != expectedUserId { return false }
        guard let accountOwner = backend.userId else { return false }
        let owner = accountOwner + (record.profile_id.map { ":profile:" + $0 } ?? "")
        var saved = false
        do {
            try await turns.save(TurnStore.Turn(record, userId: owner))
            saved = true
        } catch {
            RealtimeLog.log("history: turn \(record.id) not stored — \(error)")
        }
        await refresh()
        return saved
    }

    func delete(_ record: CommandRecord) async {
        do {
            try await turns.remove(id: record.id)
        } catch {
            RealtimeLog.log("history: turn \(record.id) not deleted — \(error)")
        }
        await refresh()
    }
}
