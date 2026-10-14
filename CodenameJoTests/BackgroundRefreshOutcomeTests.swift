import XCTest
@testable import CodenameJo

/// A background pass is invisible, so these rows are the only way to tell "it ran and
/// failed" from "it never ran".
final class BackgroundRefreshOutcomeTests: XCTestCase {

    // MARK: - Counts

    func testOnlyASyncedPassReportsACountAndWhetherItSeeded() {
        let seeded = BackgroundRefreshLog.Outcome.synced(cached: 986, seeded: true)
        XCTAssertEqual(seeded.cachedCount, 986)
        XCTAssertEqual(seeded.wasSeed, true)

        let delta = BackgroundRefreshLog.Outcome.synced(cached: 0, seeded: false)
        // Zero is a real answer — a seeded pass that wrote nothing is not the same as a
        // pass that never asked.
        XCTAssertEqual(delta.cachedCount, 0)
        XCTAssertEqual(delta.wasSeed, false)

        for outcome in [BackgroundRefreshLog.Outcome.upToDate, .expired,
                        .credentialFailed("x"), .fetchFailed("y")] {
            XCTAssertNil(outcome.cachedCount, outcome.label)
            XCTAssertNil(outcome.wasSeed, outcome.label)
        }
    }

    func testTheLabelSaysWhetherItWasAFirstFillOrADelta() {
        XCTAssertEqual(BackgroundRefreshLog.Outcome.synced(cached: 4, seeded: true).label,
                       "seeded 4 message(s)")
        XCTAssertEqual(BackgroundRefreshLog.Outcome.synced(cached: 4, seeded: false).label,
                       "delta 4 message(s)")
        XCTAssertEqual(BackgroundRefreshLog.Outcome.expired.label, "expired")
    }

    // MARK: - Skips

    func testASkipCarriesItsOwnPhrase() {
        XCTAssertEqual(BackgroundRefreshLog.Skip.signedOut.logPhrase, "signed out")
        XCTAssertEqual(BackgroundRefreshLog.Skip.alreadyRunning.logPhrase,
                       "a pass is already running")
        XCTAssertEqual(BackgroundRefreshLog.Skip.throttled(secondsAgo: 42).logPhrase,
                       "last pass 42s ago")
    }

    func testOnlyAThrottledSkipKnowsHowLongAgoTheLastPassWas() {
        XCTAssertEqual(BackgroundRefreshLog.Skip.throttled(secondsAgo: 7).secondsAgo, 7)
        XCTAssertNil(BackgroundRefreshLog.Skip.signedOut.secondsAgo)
        XCTAssertNil(BackgroundRefreshLog.Skip.alreadyRunning.secondsAgo)
    }

    // MARK: - The stored row

    func testAnEntrySurvivesARoundTripWithItsOutcomeIntact() throws {
        let entry = BackgroundRefreshLog.Entry(
            at: Date(timeIntervalSince1970: 1_788_777_000),
            trigger: .silentPush,
            outcome: .synced(cached: 12, seeded: false),
            ms: 2_410)
        let data = try JSONEncoder().encode(entry)
        let back = try JSONDecoder().decode(BackgroundRefreshLog.Entry.self, from: data)

        XCTAssertEqual(back.at, entry.at)
        XCTAssertEqual(back.trigger, .silentPush)
        XCTAssertEqual(back.ms, 2_410)
        XCTAssertEqual(back.outcome, .synced(cached: 12, seeded: false))
        // `id` is the timestamp, which is what keeps twenty rows distinct in a list.
        XCTAssertEqual(back.id, entry.at)
    }

    func testTheTriggerWireNamesAreTheOnesTheStoredHistoryAlreadyUses() {
        // Renaming one would stop old rows in the stored history from decoding.
        XCTAssertEqual(BackgroundRefreshLog.Trigger.silentPush.rawValue, "push")
        XCTAssertEqual(BackgroundRefreshLog.Trigger.launch.rawValue, "launch")
        XCTAssertEqual(BackgroundRefreshLog.Trigger.signIn.rawValue, "signin")
        XCTAssertEqual(BackgroundRefreshLog.Trigger.manual.rawValue, "manual")
        XCTAssertEqual(BackgroundRefreshLog.Trigger.toolWrite.rawValue, "toolwrite")
        XCTAssertEqual(BackgroundRefreshLog.Trigger.staleRead.rawValue, "staleread")
    }

    func testTheHistoryIsBoundedSoTheDefaultsPlistStaysSmall() {
        XCTAssertEqual(BackgroundRefreshLog.limit, 20)
    }
}
