import Foundation

/// Runs the audio graph's blocking CoreAudio calls off the main thread, in order. Serial so teardown
/// queues behind its bring-up; a `DispatchQueue` because Swift's cooperative pool must not be blocked.
final class AudioQueue {

    private let queue = DispatchQueue(
        label: "com.kiloforge.aurex.audio-graph",
        qos: .userInitiated
    )

    /// Run `work` on the audio queue and await it; the caller suspends, so the main run loop keeps turning.
    func run<T>(_ label: String, _ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let started = CFAbsoluteTimeGetCurrent()
                do {
                    let value = try work()
                    AudioTiming.note(label, since: started)
                    continuation.resume(returning: value)
                } catch {
                    AudioTiming.note(label, since: started, failure: error)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Enqueue `work` and return immediately, for teardown. Still serialised behind `run`.
    func detached(_ label: String, _ work: @escaping () -> Void) {
        queue.async {
            let started = CFAbsoluteTimeGetCurrent()
            work()
            AudioTiming.note(label, since: started)
        }
    }
}

/// What a blocking audio call costs, in milliseconds. `⚠︎` marks anything over a 60 Hz frame.
enum AudioTiming {

    /// One frame at 60 Hz, in milliseconds. ProMotion halves it, but 60 is the
    /// floor every device shares and a call under it is fine everywhere.
    private static let frameBudgetMs: Double = 1000.0 / 60.0

    /// How long a blocking audio call took, and whether it cost frames.
    static func note(_ label: String, since started: CFAbsoluteTime, failure: Error? = nil) {
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        let flag = ms > frameBudgetMs ? " ⚠︎" : ""
        if let failure {
            RealtimeLog.log("timing: \(label) failed after \(Self.format(ms))ms — \(failure.localizedDescription)")
        } else {
            RealtimeLog.log("timing: \(label) \(Self.format(ms))ms\(flag)")
        }
    }

    private static func format(_ ms: Double) -> String {
        String(format: "%.1f", ms)
    }
}
