import XCTest
@testable import CodenameJo

/// The Gmail token bucket: a burst after an idle stretch, and pacing once that burst is spent.
///
/// It was a spacing limiter before it was a bucket, and the difference was measured — twelve
/// `messages.get` starting 366 ms apart with no request in flight for most of it, in front of
/// a user waiting for the assistant to speak. So the two properties are tested separately:
/// spending the depth must not sleep at all, and spending past it must actually wait.
///
/// A fresh actor per test rather than the container's singleton — a shared deadline carried
/// between tests is the one thing that would make these order-dependent.
final class GmailQuotaTests: XCTestCase {

    /// `Cost.get` is 5 units, and the documented depth is 100 — twenty messages.
    private let burstMessages = 20

    private func elapsed(_ work: () async -> Void) async -> TimeInterval {
        let started = Date()
        await work()
        return Date().timeIntervalSince(started)
    }

    // MARK: - The burst

    func testAnIdleBucketPaysForTwentyMessagesWithoutSleeping() async {
        let quota = GmailQuota()

        let seconds = await elapsed {
            for _ in 0..<burstMessages { await quota.spend(GmailQuota.Cost.get) }
        }

        XCTAssertLessThan(
            seconds, 0.5,
            "the depth is what a section build spends before the assistant can speak")
    }

    func testABatchSpendsTheSameAsItsMessagesOneAtATime() async {
        let batched = GmailQuota()
        let single = GmailQuota()

        let batchedSeconds = await elapsed { await batched.spendBatch(of: burstMessages) }
        let singleSeconds = await elapsed {
            for _ in 0..<burstMessages { await single.spend(GmailQuota.Cost.get) }
        }

        XCTAssertLessThan(batchedSeconds, 0.5)
        XCTAssertLessThan(singleSeconds, 0.5)
    }

    // MARK: - Past the burst

    /// 250 units at the sustained 150/sec is 1.67 s of backlog, of which the depth absorbs
    /// 0.67 s. The remaining second is the governor doing the thing it was built for.
    func testSpendingPastTheDepthWaitsForTheSustainedRate() async {
        let quota = GmailQuota()

        let seconds = await elapsed { await quota.spend(250) }

        XCTAssertGreaterThan(
            seconds, 0.9, "a 900-message backfill still paces at 60% of the ceiling")
    }

    /// The bucket is shared, so the backlog one caller leaves behind is a wait the next one
    /// inherits — that is what stops two overlapping passes from being no governor at all.
    func testABacklogLeftByOneCallerIsPaidForByTheNext() async {
        let quota = GmailQuota()
        await quota.spendBatch(of: burstMessages)

        let seconds = await elapsed { await quota.spend(150) }

        XCTAssertGreaterThan(seconds, 0.9)
    }

    func testSpendingNothingCostsNothing() async {
        let quota = GmailQuota()

        let seconds = await elapsed { await quota.spend(0) }

        XCTAssertLessThan(seconds, 0.5)
    }
}
