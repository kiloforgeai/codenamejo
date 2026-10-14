// coverage-target: CodenameJo/Views/PreviewSupport.swift

import XCTest
@testable import CodenameJo

/// The Dispatch and Actions fixtures behind History's two panels.
///
/// Every `#Preview` in this app becomes an App Store screenshot, and these two stores
/// are the only place the panels' states come from: nothing in a preview has a backend
/// to read. Each fixture set is written to hold *one row of every state the panel can
/// draw* — the done-but-unheard badge, a job inside its budget, a job past tolerance, a
/// failure, a delivered answer; a write with a link, a write that legitimately has none,
/// a refusal, and a `pending` row past tolerance. A fixture quietly dropped or flipped
/// takes a state out of the screenshot and out of review with it, and nothing else in
/// the build notices.
///
/// The two overrides matter as much as the data: a preview must never settle or recover
/// a row, because the base implementations write to the backend.
@MainActor
final class PreviewPanelFixtureTests: XCTestCase {

    /// Connectors whose tools are unwired, so no fixture may advertise them — a
    /// screenshot of a row for a service the app cannot call is a promise it cannot keep.
    private let unwired = ["github", "notion"]

    // MARK: - Dispatch

    func testThePreviewDispatchPanelNeverRecoversAnything() async {
        let recovered = await PreviewDispatchJobStore().recover()

        XCTAssertTrue(recovered.isEmpty,
                      "recover() settles and prunes as it reads; a preview has no backend to write to")
    }

    /// Settling is what marks an answer heard. In a preview it must change nothing —
    /// drawing the panel is not someone listening to it.
    func testSettlingAPreviewJobLeavesTheSeededHistoryUntouched() async {
        let store = PreviewDispatchJobStore()
        let before = await store.history()
        let undelivered = before.first { $0.deliveredAt == nil }

        await store.settle(undelivered?.id ?? UUID())
        let after = await store.history()

        XCTAssertEqual(before.count, after.count)
        XCTAssertEqual(after.filter { $0.deliveredAt == nil }.count,
                       before.filter { $0.deliveredAt == nil }.count)
    }

    func testTheDispatchPanelSeedsEveryStateItCanDraw() async {
        let jobs = await PreviewDispatchJobStore().history()

        XCTAssertTrue(jobs.contains(where: \.isDone), "No done row means no answer in the screenshot")
        XCTAssertTrue(jobs.contains(where: \.isRunning))
        XCTAssertTrue(jobs.contains(where: \.didFail), "A failure is the row the panel exists for")
    }

    /// Two running rows, deliberately: one working inside its budget and one past
    /// `runningTolerance`, which is the only thing that separates "still going" from
    /// "never finished" — nothing resumes a dispatch.
    func testOneRunningJobIsStillInsideItsBudgetAndOneIsPastTolerance() async {
        let now = Date()
        let running = await PreviewDispatchJobStore().history().filter(\.isRunning)

        let ages = running.map { now.timeIntervalSince($0.startedAt ?? now) }
        XCTAssertEqual(ages.filter { $0 < DispatchJob.runningTolerance }.count, 1)
        XCTAssertEqual(ages.filter { $0 > DispatchJob.runningTolerance }.count, 1)
    }

    /// `result` is the prose that gets spoken if a job is recovered a session later. A
    /// settled row without one is a row the panel can only draw as blank.
    func testEverySettledDispatchJobCarriesItsAnswerAndEveryRunningOneDoesNot() async {
        for job in await PreviewDispatchJobStore().history() {
            if job.isRunning {
                XCTAssertNil(job.result, "A running job has nothing to say yet")
                XCTAssertNil(job.completedAt)
            } else {
                XCTAssertNotNil(job.result, "\(job.state) row with no result draws an empty answer")
                XCTAssertNotNil(job.completedAt)
            }
        }
    }

    /// The unheard badge is the panel's whole reason for existing, and a delivered row
    /// is what it must not look like. Both have to be in the same screenshot.
    func testTheDispatchFixturesHoldBothAnUnheardAnswerAndADeliveredOne() async {
        let done = await PreviewDispatchJobStore().history().filter(\.isDone)

        XCTAssertTrue(done.contains { $0.deliveredAt == nil }, "Nothing would wear the badge")
        XCTAssertTrue(done.contains { $0.deliveredAt != nil })
    }

    func testEveryDispatchFixtureIsADistinctRow() async {
        let jobs = await PreviewDispatchJobStore().history()

        XCTAssertEqual(Set(jobs.map(\.id)).count, jobs.count, "Identifiable rows sharing an id drop one")
        XCTAssertTrue(jobs.allSatisfy { !$0.task.isEmpty })
    }

    // MARK: - Actions

    /// The case the Actions panel was built for: the assistant said "labelled" out loud
    /// and Gmail then refused. A failure has to carry the reason and cannot carry a link.
    func testTheActionsFixturesHoldAFailureThatExplainsItselfAndLinksNowhere() async {
        let failed = await PreviewActionStore().history().filter { $0.state == "failed" }

        XCTAssertFalse(failed.isEmpty, "The refusal is the row the panel exists for")
        for record in failed {
            XCTAssertNotNil(record.detail, "A failure with no reason is unactionable")
            XCTAssertNil(record.url, "A write that did not happen has nothing to show")
        }
    }

    /// A `pending` row past `pendingTolerance` is a write that was spoken as done and
    /// never confirmed — the "Unconfirmed" state, which is only reviewable if a fixture
    /// actually reaches it.
    func testAPendingActionIsSeededOldEnoughToReadAsUnconfirmed() async {
        let pending = await PreviewActionStore().history().filter(\.isPending)

        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.isAbandoned(asOf: Date()), true,
                       "Seeded inside the tolerance it would draw as still in flight")
        XCTAssertNil(pending.first?.completedAt)
    }

    /// An absent link has to read as a stated fact rather than as a broken row, so the
    /// fixtures carry a settled write with a link and a settled write without one.
    func testSettledActionsCoverBothALinkedWriteAndAnHonestlyUnlinkedOne() async {
        let done = await PreviewActionStore().history().filter { $0.state == "done" }

        XCTAssertTrue(done.contains { $0.url != nil })
        XCTAssertTrue(done.contains { $0.url == nil },
                      "A draft and a scheduled message cannot be linked; that case has to be visible")
    }

    /// "Archived" means nothing across four connected mailboxes, which is why the row
    /// names its account — and why more than one account has to appear in the fixtures.
    func testTheActionFixturesSpanMoreThanOneAccount() async {
        let records = await PreviewActionStore().history()

        XCTAssertGreaterThan(Set(records.map(\.account)).count, 1)
        XCTAssertTrue(records.allSatisfy { !$0.account.isEmpty && !$0.summary.isEmpty })
    }

    func testNoSeededActionAdvertisesAnUnwiredConnector() async {
        let connectors = await PreviewActionStore().history().map { $0.connector.lowercased() }

        for connector in unwired {
            XCTAssertFalse(connectors.contains(connector),
                           "\(connector) is unwired; a row for it promises a write the app cannot make")
        }
    }

    /// Every settled row carries both ends of its timing, and a write cannot complete
    /// before it started — the panel sorts on these and a reversed pair reorders it.
    func testEverySettledActionIsTimedForwards() async throws {
        for record in await PreviewActionStore().history() where !record.isPending {
            let started = try XCTUnwrap(record.startedAt, "\(record.tool) never started")
            let completed = try XCTUnwrap(record.completedAt, "\(record.tool) never settled")
            XCTAssertGreaterThanOrEqual(completed, started, "\(record.tool) completes before it starts")
        }
    }

    func testEveryActionFixtureIsADistinctRow() async {
        let records = await PreviewActionStore().history()

        XCTAssertEqual(Set(records.map(\.id)).count, records.count)
        XCTAssertGreaterThan(records.count, 1)
    }
}
