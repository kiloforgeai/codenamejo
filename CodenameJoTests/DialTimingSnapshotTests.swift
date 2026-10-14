// coverage-target: CodenameJo/Views/DialTimingSection.swift

import XCTest

@testable import CodenameJo

/// Settings → Admin → Dial timing reads two instruments that nothing can observe.
///
/// `LaunchTiming` and `DialTiming` are lock-guarded statics written from libwebrtc's
/// threads, so the section copies both at once rather than binding to them — which is also
/// what stops the launch half and the dial half being read a frame apart and describing two
/// different dials. These tests hold the copy honest: every field the snapshot carries has
/// to equal what its instrument says at the moment `current()` runs, and the stored history
/// summary has to be the median over the rows actually on disk rather than the last dial.
///
/// The dial history is `UserDefaults`-backed, so it is saved and restored around each test.
@MainActor
final class DialTimingSnapshotTests: XCTestCase {

    /// `DialTiming.historyKey` is private; the literal is the coupling this test accepts so
    /// the stored shape is exercised rather than a re-implementation of it.
    private let historyKey = "dialTiming.recent"
    private var savedHistory: Data?

    override func setUp() {
        super.setUp()
        savedHistory = UserDefaults.standard.data(forKey: historyKey)
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    override func tearDown() {
        if let savedHistory {
            UserDefaults.standard.set(savedHistory, forKey: historyKey)
        } else {
            UserDefaults.standard.removeObject(forKey: historyKey)
        }
        super.tearDown()
    }

    private func record(_ totalMs: Double, entryPoint: String = "orb") -> DialTiming.Record {
        DialTiming.Record(
            at: Date(timeIntervalSince1970: totalMs),
            totalMs: totalMs,
            hearableMs: totalMs + 750,
            micLiveMs: nil,
            entryPoint: entryPoint,
            wasCold: nil,
            legLabels: [],
            legMs: [])
    }

    private func store(_ records: [DialTiming.Record]) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(records), forKey: historyKey)
    }

    // MARK: - The empty snapshot

    /// The value the view model opens on, before anything has dialled. Every field is
    /// absent rather than zero, because a zero millisecond leg is a measurement and an
    /// unmeasured leg is not.
    func testAnUnreadSnapshotCarriesNoDialAtAllAndReadsAsAnOrbTap() {
        let snapshot = DialTimingSnapshot()
        XCTAssertTrue(snapshot.launchLegs.isEmpty)
        XCTAssertTrue(snapshot.dialLegs.isEmpty)
        XCTAssertNil(snapshot.toDialMs)
        XCTAssertNil(snapshot.toTalkMs)
        XCTAssertNil(snapshot.dialTotalMs)
        XCTAssertNil(snapshot.toolsMs)
        XCTAssertNil(snapshot.wasCold)
        XCTAssertNil(snapshot.micLiveMs)
        XCTAssertNil(snapshot.hearableMs)
        XCTAssertNil(snapshot.medianMs)
        XCTAssertEqual(snapshot.recordedDials, 0)
        XCTAssertEqual(snapshot.entryPoint, "orb",
                       "The orb is the assumed entry point until a press says otherwise")
    }

    // MARK: - One read of both instruments

    func testCurrentCopiesTheDialInstrumentVerbatim() {
        let snapshot = DialTimingSnapshot.current()
        XCTAssertEqual(snapshot.dialLegs.map(\.label), DialTiming.lastDial.map(\.label))
        XCTAssertEqual(snapshot.dialLegs.map(\.ms), DialTiming.lastDial.map(\.ms))
        XCTAssertEqual(snapshot.dialTotalMs, DialTiming.lastTotalMs)
        XCTAssertEqual(snapshot.toolsMs, DialTiming.lastToolsMs)
        XCTAssertEqual(snapshot.micLiveMs, DialTiming.lastMicLiveMs)
        XCTAssertEqual(snapshot.hearableMs, DialTiming.lastHearableMs)
        XCTAssertEqual(snapshot.entryPoint, DialTiming.lastEntryPoint)
    }

    func testCurrentCopiesTheLaunchInstrumentVerbatim() {
        let snapshot = DialTimingSnapshot.current()
        XCTAssertEqual(snapshot.launchLegs.map(\.label), LaunchTiming.lastLaunch.map(\.label))
        XCTAssertEqual(snapshot.launchLegs.map(\.ms), LaunchTiming.lastLaunch.map(\.ms))
        XCTAssertEqual(snapshot.toDialMs, LaunchTiming.lastToDialMs)
        XCTAssertEqual(snapshot.toTalkMs, LaunchTiming.lastToTalkMs)
        XCTAssertEqual(snapshot.wasCold, LaunchTiming.lastWasCold)
    }

    // MARK: - The stored history summary

    /// The median is the only summary worth reading on a path whose SDP leg swings
    /// untouched, so the snapshot has to take it from the rows on disk.
    func testCurrentReportsTheStoredHistorysSizeAndItsMedian() throws {
        try store([record(400), record(1_200), record(800)])

        let snapshot = DialTimingSnapshot.current()

        XCTAssertEqual(snapshot.recordedDials, 3)
        XCTAssertEqual(snapshot.medianMs, 800,
                       "The middle of the sorted pool, not the newest and not the mean")
    }

    func testAnUnreadableHistoryCostsTheSummaryAndNotTheScreen() {
        UserDefaults.standard.set(Data("not a dial history".utf8), forKey: historyKey)

        let snapshot = DialTimingSnapshot.current()

        XCTAssertEqual(snapshot.recordedDials, 0)
        XCTAssertNil(snapshot.medianMs, "No rows means no median, rather than zero")
    }
}
