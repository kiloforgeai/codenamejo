import FactoryKit
import Foundation

/// Reads back the writes the assistant performed, so the user can check them. Read-only: nothing
/// here is spoken, so nothing settles. Not `final`: `PreviewActionStore` overrides `history()`.
@MainActor
class ActionStore {
    /// Every recorded write, newest first by the latest timestamp a row carries, so pending rows don't sink.
    /// Unwired: nothing on the phone writes these rows yet.
    func history() async -> [ActionRecord] {
        return []
        /*
        do {
            let records = try await backend.fetch(ActionRecord.self, from: table)
            return records.sorted {
                ($0.completedAt ?? $0.startedAt ?? .distantPast)
                    > ($1.completedAt ?? $1.startedAt ?? .distantPast)
            }
        } catch {
            // A failed read costs one appearance of the panel; the next tries again.
            RealtimeLog.log("actions: could not read history — \(error.localizedDescription)")
            return []
        }
        */
    }
}
