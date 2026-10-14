import Foundation

/// Keeps Calendar requests under Google's per-user limit, a budget separate from Gmail's.
/// Live voice reads share the quota, so background sync uses only part of it.
actor CalendarQuota {
    static let shared = CalendarQuota()

    /// Google's documented per-user ceiling.
    private static let requestsPerHundredSeconds = 500.0

    /// The share of it this client will use, sustained.
    private static let budgetFraction = 0.6

    /// The bucket's depth after an idle stretch. One sync pass sends about one `events.list` per
    /// account, so the sustained rate does the governing.
    private static let burstRequests = 10.0

    private static var rate: Double { requestsPerHundredSeconds * budgetFraction / 100.0 }
    private static var burstSeconds: Double { burstRequests / rate }

    /// When everything spent so far will have been paid for — see `GmailQuota.availableAt`
    /// for why this is a deadline rather than a token count.
    private var availableAt = Date.distantPast

    /// Wait until `requests` more calls can go out, then account for them. Called before the
    /// request: accounting afterwards only describes damage it did not prevent.
    func spend(_ requests: Int = 1) async {
        let now = Date()
        let backlogEnds = max(now, availableAt).addingTimeInterval(Double(requests) / Self.rate)
        availableAt = backlogEnds
        let wait = backlogEnds.timeIntervalSince(now) - Self.burstSeconds
        guard wait > 0 else { return }
        RealtimeLog.log("calendar: \(requests) request(s) over budget — holding \(Int(wait * 1000))ms")
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    }
}
