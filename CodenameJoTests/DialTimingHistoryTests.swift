import XCTest
@testable import CodenameJo

/// The stored dial history is the only instrument that survives a relaunch, and the median
/// over it is what a connect-path change is judged against. A filter that quietly matches
/// the wrong rows, or a decode that fails soft, turns "did this get better" into a number
/// nobody can question.
final class DialTimingHistoryTests: XCTestCase {

    /// `DialTiming.historyKey` is private; the literal is the coupling this test accepts so
    /// the stored shape is exercised rather than a re-implementation of it.
    private let historyKey = "dialTiming.recent"
    private var saved: Data?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.data(forKey: historyKey)
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: historyKey)
        } else {
            UserDefaults.standard.removeObject(forKey: historyKey)
        }
        super.tearDown()
    }

    private func record(
        _ totalMs: Double, entryPoint: String = "orb", wasCold: Bool? = nil,
        legs: [(String, Double)] = []
    ) -> DialTiming.Record {
        DialTiming.Record(
            at: Date(timeIntervalSince1970: totalMs),
            totalMs: totalMs,
            hearableMs: totalMs + 750,
            micLiveMs: nil,
            entryPoint: entryPoint,
            wasCold: wasCold,
            legLabels: legs.map(\.0),
            legMs: legs.map(\.1))
    }

    private func store(_ records: [DialTiming.Record]) {
        UserDefaults.standard.set(try! JSONEncoder().encode(records), forKey: historyKey)
    }

    // MARK: - Reading the history back

    func testNoStoredHistoryIsAnEmptyListAndNoMedian() {
        XCTAssertTrue(DialTiming.recent.isEmpty)
        XCTAssertNil(DialTiming.medianTotalMs())
    }

    func testUnreadableHistoryReadsAsEmptyRatherThanCrashing() {
        // A shape change between builds must cost the instrument, not the dial.
        UserDefaults.standard.set(Data("not a dial history".utf8), forKey: historyKey)
        XCTAssertTrue(DialTiming.recent.isEmpty)
        XCTAssertNil(DialTiming.medianTotalMs())
    }

    func testStoredDialsComeBackInTheOrderTheyWereWritten() {
        store([record(2_400), record(1_800)])
        XCTAssertEqual(DialTiming.recent.map(\.totalMs), [2_400, 1_800])
    }

    // MARK: - The median

    func testTheMedianIsTakenOverTheSortedPoolNotTheStoredOrder() {
        store([record(3_000), record(1_000), record(2_000)])
        XCTAssertEqual(DialTiming.medianTotalMs(), 2_000)
    }

    func testAnEvenPoolTakesTheUpperOfTheTwoMiddleDials() {
        // `pool[count / 2]`, so four dials answer with the third. Pinned because a change
        // to averaging the pair would move every quoted figure without touching a caller.
        store([record(100), record(200), record(300), record(400)])
        XCTAssertEqual(DialTiming.medianTotalMs(), 300)
    }

    func testASingleDialIsItsOwnMedian() {
        store([record(1_234)])
        XCTAssertEqual(DialTiming.medianTotalMs(), 1_234)
    }

    func testTheEntryPointFilterOnlyCountsThatSurface() {
        // A Lock Screen press pays for a process launch; mixing it into the orb's numbers
        // is two distributions added together.
        store([record(1_000, entryPoint: "orb"),
               record(5_000, entryPoint: "control"),
               record(1_200, entryPoint: "orb")])
        XCTAssertEqual(DialTiming.medianTotalMs(entryPoint: "orb"), 1_200)
        XCTAssertEqual(DialTiming.medianTotalMs(entryPoint: "control"), 5_000)
        XCTAssertNil(DialTiming.medianTotalMs(entryPoint: "carplay"))
        // No filter means every surface.
        XCTAssertEqual(DialTiming.medianTotalMs(), 1_200)
    }

    func testColdOnlyExcludesWarmDialsAndDialsThatNeverKnew() {
        // `nil` is "not knowable", and a guess is worse than an absence — a warm dial filed
        // as cold is what makes a median lie.
        store([record(1_000, wasCold: false),
               record(4_000, wasCold: true),
               record(9_000, wasCold: nil)])
        XCTAssertEqual(DialTiming.medianTotalMs(coldOnly: true), 4_000)
    }

    func testColdOnlyWithNoColdDialsHasNoAnswer() {
        store([record(1_000, wasCold: false), record(2_000, wasCold: nil)])
        XCTAssertNil(DialTiming.medianTotalMs(coldOnly: true))
    }

    func testTheTwoFiltersCompose() {
        store([record(1_000, entryPoint: "orb", wasCold: true),
               record(8_000, entryPoint: "control", wasCold: true),
               record(2_000, entryPoint: "orb", wasCold: false)])
        XCTAssertEqual(DialTiming.medianTotalMs(entryPoint: "orb", coldOnly: true), 1_000)
    }

    // MARK: - A record's legs

    func testLegsAreRebuiltInOrderFromTheTwoStoredArrays() {
        // A dictionary would lose the order, which is the only thing that makes a
        // breakdown readable.
        let stored = record(2_410, legs: [("mint", 1_180), ("SDP", 520), ("ICE", 310)])
        store([stored])
        let legs = DialTiming.recent.first?.legs ?? []
        XCTAssertEqual(legs.map(\.label), ["mint", "SDP", "ICE"])
        XCTAssertEqual(legs.map(\.ms), [1_180, 520, 310])
    }

    func testARecordWithNoLegsHasNoLegs() {
        store([record(900)])
        XCTAssertEqual(DialTiming.recent.first?.legs.count, 0)
    }

    // MARK: - Formatting

    func testMillisecondsAreRoundedToWholeNumbers() {
        // Locale-independent: two digits carry no grouping separator anywhere.
        XCTAssertEqual(DialTiming.format(12.4), "12")
        XCTAssertEqual(DialTiming.format(12.6), "13")
        XCTAssertEqual(DialTiming.format(0), "0")
    }

    func testRoundingHappensBeforeFormattingSoTheDigitsAreTheRoundedOnes() {
        // Three digits still carry no grouping separator in any locale, so these compare
        // exactly while staying independent of where the test runs.
        XCTAssertEqual(DialTiming.format(999.4), "999")
        XCTAssertEqual(DialTiming.format(476.5), "477")
        XCTAssertEqual(DialTiming.format(100.5), "101")
    }
}
