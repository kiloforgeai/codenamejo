import UIKit

/// Press feedback for the orb, fired imperatively: `.sensoryFeedback` rides a view update, which a
/// busy main thread delays. `prepare()` warms the Taptic Engine, which is slow to start cold.
@MainActor
enum Haptics {

    /// `.light` for the progress ticks, which report rather than confirm — they
    /// must not feel like either edge of a turn.
    private static let tick = UIImpactFeedbackGenerator(style: .light)

    /// Call when the orb appears, so the first tick isn't the slow one.
    static func warmUp() {
        // The ticks re-prepare after each one, so this covers only the first.
        tick.prepare()
    }

    // MARK: - Placing a call

    /// The call is live and the user can talk; the one haptic that is a call to action. Two `.heavy`
    /// generators because impacts on one generator within ~50 ms coalesce into a single tap.
    static func callReady() {
        stopWaiting()
        callFirst.impactOccurred(intensity: 1.0)
        callSecond.prepare()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            callSecond.impactOccurred(intensity: 1.0)
        }
    }

    private static let callFirst = UIImpactFeedbackGenerator(style: .heavy)
    private static let callSecond = UIImpactFeedbackGenerator(style: .heavy)

    /// How often the waiting ticks fire. Slow enough not to nag over a multi-second
    /// dial, close enough together that the gaps don't read as the dial stalling.
    private static let waitInterval: Duration = .milliseconds(400)
    private static let waitTick = UIImpactFeedbackGenerator(style: .light)
    private static var waiting: Task<Void, Never>?

    /// Faint ticks while the call is placed, since the dial is silent. Faint so a tick never feels
    /// like `callReady()`'s confirmation.
    static func startWaiting() {
        guard waiting == nil else { return }
        waitTick.prepare()
        // Warm the ready thump now. It lands at the least predictable moment of the
        // dial, which is exactly when a cold Taptic Engine would make it late.
        callFirst.prepare()
        waiting = Task { @MainActor in
            // Bounded: a backgrounded dial can sit in `.connecting` with nothing to end it. The cap is
            // past the 15 s session-request timeout.
            for _ in 0..<Int(35_000 / 400) {
                try? await Task.sleep(for: waitInterval)
                guard !Task.isCancelled else { return }
                waitTick.impactOccurred(intensity: 0.3)
                waitTick.prepare()
            }
        }
    }

    static func stopWaiting() {
        waiting?.cancel()
        waiting = nil
    }

    /// A step of work started (a tool call). Faint: it fires several times a turn while the user waits.
    static func step() {
        tick.impactOccurred(intensity: 0.35)
        tick.prepare()
    }
}
