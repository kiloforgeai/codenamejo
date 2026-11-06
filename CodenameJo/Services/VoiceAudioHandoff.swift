import Foundation

/// A new audio owner waits until every previous owner has released its devices.
@MainActor
final class VoiceAudioHandoff {
    private var pending: Task<Void, Never>?
    private var generation = 0

    func release(_ work: @escaping @MainActor () async -> Void) {
        let previous = pending
        generation += 1
        pending = Task {
            await previous?.value
            await work()
        }
    }

    func wait() async throws {
        while true {
            let observed = generation
            await pending?.value
            try Task.checkCancellation()
            if generation == observed { return }
        }
    }
}
