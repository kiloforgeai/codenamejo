// coverage-target: CodenameJo/Services/BackgroundRefresh/CalendarQuota.swift

import XCTest

@testable import CodenameJo

/// Calendar's own governor. Google bills it separately from Gmail and its documented
/// ceiling is 500 requests per 100 seconds; this client takes 60% of that sustained with a
/// ten-request bucket, so a background sync leaves headroom for the voice path's live
/// calendar reads.
///
/// Each case gets its own actor rather than `CalendarQuota.shared`: the deadline is
/// cumulative, so sharing one would make the result depend on what ran before it.
final class CalendarQuotaTests: XCTestCase {

    /// 500 × 0.6 / 100 = 3 requests per second sustained, 10 deep.
    private let burst = 10

    func testASingleRequestFromRestGoesOutWithoutWaiting() async {
        let quota = CalendarQuota()

        let started = Date()
        await quota.spend()

        // One `events.list` on an idle phone must not pay for the budget it is nowhere
        // near — the sustained rate is the lever here, not the bucket depth.
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testTheWholeBucketIsSpentWithoutHolding() async {
        let quota = CalendarQuota()

        let started = Date()
        for _ in 0..<burst { await quota.spend() }

        // Ten is the depth, and a sync pass that fits inside it should never sleep: one
        // `events.list` per connected account plus the odd second page is well under it.
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    func testTheRequestPastTheBucketIsHeldBackForRoughlyTheRateItCosts() async {
        let quota = CalendarQuota()
        for _ in 0..<burst { await quota.spend() }

        let started = Date()
        await quota.spend()
        let held = Date().timeIntervalSince(started)

        // At 3 requests a second, the eleventh call is a third of a second past the
        // bucket's edge and is made to wait for it. The upper bound is what says the wait
        // is the overrun rather than the whole backlog — holding for the full 3.67 s
        // deadline would stall a refresh pass that has a 25-second budget for everything.
        XCTAssertGreaterThan(held, 0.2)
        XCTAssertLessThan(held, 2.0)
    }
}
