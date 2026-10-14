import ActivityKit
import Foundation

/// Owns the one Live Activity a hands-free call gets, requested at the dial. Phase and mute changes push at
/// once; everything else coalesces to `minInterval`, since ActivityKit silently drops over-budget updates.
@MainActor
final class LiveVoiceActivity {
    /// Built by the container (`\.liveActivity`, `.singleton`), not reached through
    /// a global — so `internal` rather than `private`.
    init() {}

    private var activity: Activity<VoiceActivityAttributes>?
    private var lastPushedAt = Date.distantPast
    private var lastPushed: VoiceActivityAttributes.ContentState?
    private var pending: VoiceActivityAttributes.ContentState?
    private var flush: Task<Void, Never>?
    /// The latest ActivityKit write, so `settle()` can await a push triggered from a `didSet`.
    private var inFlight: Task<Void, Never>?

    /// Twice a second. Fast enough that a transcript reads as live, slow enough
    /// that a two-minute conversation stays well inside ActivityKit's budget.
    private static let minInterval: TimeInterval = 0.5

    var isRunning: Bool { activity != nil }

    /// Whether the system will accept an activity. False when the user turned Live Activities off,
    /// in which case the caller declines to background itself.
    static var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: - Lifecycle

    func start(_ state: VoiceActivityAttributes.ContentState) {
        guard activity == nil, Self.isAvailable else { return }
        do {
            activity = try Activity.request(
                attributes: VoiceActivityAttributes(startedAt: Date()),
                content: .init(state: state, staleDate: nil),
                // No push token: every update is local, from the process the audio session keeps awake.
                pushType: nil
            )
            lastPushed = state
            lastPushedAt = Date()
            RealtimeLog.log("live-activity: started")
        } catch {
            // ActivityKit constrains only the request (e.g. `.visibility` when not foregrounded), so
            // this runs at the dial, not on the way off screen.
            RealtimeLog.log("live-activity: request failed — \(error.localizedDescription)")
        }
    }

    /// Returns the ActivityKit write so a caller about to lose execution can await the redraw.
    /// Only a straight-through push has one.
    @discardableResult
    func update(_ state: VoiceActivityAttributes.ContentState) -> Task<Void, Never>? {
        guard activity != nil else { return nil }
        guard state != lastPushed else { return nil }

        let phaseChanged = state.phase != lastPushed?.phase
            || state.isMuted != lastPushed?.isMuted
        let elapsed = Date().timeIntervalSince(lastPushedAt)

        if phaseChanged || elapsed >= Self.minInterval {
            return push(state)
        }

        // Too soon. Keep the newest state and land it when the window opens, so
        // the final words of an utterance are shown rather than swallowed.
        pending = state
        guard flush == nil else { return nil }
        let wait = Self.minInterval - elapsed
        flush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            // `try?` swallows the CancellationError, so check explicitly for `end()`'s cancel.
            guard !Task.isCancelled, let self else { return }
            self.flush = nil
            guard let queued = self.pending else { return }
            self.pending = nil
            guard self.activity != nil else { return }
            _ = self.push(queued)
        }
        return nil
    }

    /// Ends this activity and every orphan of our type a previous process left (ActivityKit hands them over).
    /// Returns the task so `EndBackgroundVoiceSessionIntent.perform()` can hold the process open until it lands.
    @discardableResult
    func end() -> Task<Void, Never> {
        flush?.cancel()
        flush = nil
        pending = nil
        inFlight = nil
        let owned = activity
        activity = nil
        lastPushed = nil
        // `.immediate`: a stale card offering Mute on a hung-up call is a dead control.
        return Task {
            if let owned {
                await owned.end(nil, dismissalPolicy: .immediate)
                RealtimeLog.log("live-activity: ended")
            }
            // Orphans from a previous process instance.
            for stray in Activity<VoiceActivityAttributes>.activities where stray.id != owned?.id {
                await stray.end(nil, dismissalPolicy: .immediate)
                RealtimeLog.log("live-activity: ended orphan from a previous process")
            }
        }
    }

    // MARK: - Internals

    /// Returns the ActivityKit write, for a caller on borrowed background time. `lastPushed` is stamped
    /// optimistically, so a write dropped at suspension is never retried.
    @discardableResult
    private func push(_ state: VoiceActivityAttributes.ContentState) -> Task<Void, Never>? {
        guard let activity else { return nil }
        lastPushed = state
        lastPushedAt = Date()
        let task = Task { await activity.update(.init(state: state, staleDate: nil)) }
        inFlight = task
        return task
    }

    /// Wait for the card to take the last state written. `ToggleBackgroundMuteIntent` needs this: execution
    /// isn't guaranteed once `perform` returns, and a Mute button that doesn't flip gets tapped again.
    func settle() async {
        await inFlight?.value
        inFlight = nil
    }
}
