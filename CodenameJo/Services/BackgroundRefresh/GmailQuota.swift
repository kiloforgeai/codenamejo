import Foundation
import FactoryKit

/// Token bucket that keeps Gmail requests under the per-user rate limit (250 units/s; `messages.get` costs 5).
/// Uses 60% of it because the broker's Gmail reads share the same user's quota.
actor GmailQuota {
    static var shared: GmailQuota { Container.shared.gmailQuota() }

    /// Google's documented per-user ceiling.
    private static let unitsPerSecond = 250.0

    /// The sustained share of the ceiling; the rest is headroom for the broker and retries.
    private static let budgetFraction = 0.6

    /// Bucket depth: twenty `messages.get`. Depth plus one second's refill is exactly 250 units;
    /// raising it would let a burst exceed Google's ceiling.
    private static let burstUnits = 100.0

    /// The sustained spend rate, in units per second.
    private static var rate: Double { unitsPerSecond * budgetFraction }

    /// How far ahead of now `availableAt` may sit before a caller has to wait, in seconds.
    private static var burstSeconds: Double { burstUnits / rate }

    /// What each call costs, from Google's published table.
    enum Cost {
        static let list = 5
        static let get = 5
        static let profile = 1
    }

    /// When everything spent so far is paid for. A caller waits only for backlog beyond `burstSeconds`.
    private var availableAt = Date.distantPast

    /// Wait until `units` can be spent, then account for them.
    func spend(_ units: Int) async {
        let now = Date()
        // Clamped to `now` so idle credit never exceeds `burstSeconds`.
        let backlogEnds = max(now, availableAt).addingTimeInterval(Double(units) / Self.rate)
        availableAt = backlogEnds

        let wait = backlogEnds.timeIntervalSince(now) - Self.burstSeconds
        guard wait > 0 else { return }
        RealtimeLog.log(
            "gmail: \(units)u over budget — holding \(Int(wait * 1000))ms")
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    }

    /// Spend for a batch of `count` messages.
    func spendBatch(of count: Int) async {
        await spend(count * Cost.get)
    }

    /// Called when Gmail refuses anyway, to push the next call further out.
    /// Truncated exponential backoff with jitter, so retries after a shared 429 don't fire together.
    func penalise(attempt: Int) async {
        let capped = min(attempt, 5)
        let base = pow(2.0, Double(capped))
        let jitter = Double.random(in: 0...0.5)
        let delay = min(base + jitter, 30)
        availableAt = max(availableAt, Date().addingTimeInterval(delay))
        RealtimeLog.log("gmail: backing off \(String(format: "%.1f", delay))s after a refusal")
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
}
