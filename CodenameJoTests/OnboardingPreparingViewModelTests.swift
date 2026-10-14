import XCTest
@testable import CodenameJo

// coverage-target: CodenameJo/Onboarding/OnboardingPreparingView.swift

/// The last onboarding screen reports four steps and three tallies. Its view model owns the
/// only decision on that screen — which row is done, which is running and which has not
/// started — and the rows read it straight. A wrong answer here shows a finished step still
/// spinning, or a step spinning that has not begun, on the screen a new user is watching
/// while the first call is armed.
@MainActor
final class OnboardingPreparingViewModelTests: XCTestCase {

    func testFreshScreenOpensOnTheFirstStepWithNothingCounted() {
        let model = OnboardingPreparingViewModel()
        XCTAssertEqual(model.steps, [.unread, .newsletters, .spam, .handing])
        XCTAssertEqual(model.index, 0)
        XCTAssertEqual(model.fraction, 0)
        XCTAssertFalse(model.waitingForJo)
        XCTAssertNil(model.unreadCount)
        XCTAssertNil(model.newsletterCount)
        XCTAssertNil(model.spamCount, "Spam never reaches the cache, so it has no count to open with")
        XCTAssertNil(model.inboxLabel)
    }

    func testTheRowAtTheIndexIsTheOneRunning() {
        let model = OnboardingPreparingViewModel()
        model.index = 2
        guard case .running = model.state(of: 2) else {
            return XCTFail("The row the index names is the one being worked on")
        }
    }

    func testEveryRowBeforeTheIndexIsDone() {
        let model = OnboardingPreparingViewModel()
        model.index = 2
        for position in 0..<2 {
            guard case .done = model.state(of: position) else {
                return XCTFail("Row \(position) is behind the index and has finished")
            }
        }
    }

    func testEveryRowAfterTheIndexIsStillPending() {
        let model = OnboardingPreparingViewModel()
        model.index = 1
        for position in 2..<model.steps.count {
            guard case .pending = model.state(of: position) else {
                return XCTFail("Row \(position) is ahead of the index and has not started")
            }
        }
    }

    func testTheFirstRowIsRunningBeforeAnythingHasFinished() {
        let model = OnboardingPreparingViewModel()
        guard case .running = model.state(of: 0) else {
            return XCTFail("At index 0 the first row is the one in flight, not a finished one")
        }
        guard case .pending = model.state(of: 1) else {
            return XCTFail("Nothing behind the first row has started yet")
        }
    }

    func testPastTheLastRowNothingIsLeftRunning() {
        let model = OnboardingPreparingViewModel()
        model.index = model.steps.count
        for position in 0..<model.steps.count {
            guard case .done = model.state(of: position) else {
                return XCTFail("Row \(position) must read as finished once the index has passed it")
            }
        }
    }

    func testEachCountingRowReadsItsOwnTally() {
        let model = OnboardingPreparingViewModel()
        model.unreadCount = 31
        model.newsletterCount = 4
        model.spamCount = 0
        XCTAssertEqual(model.count(for: .unread), 31)
        XCTAssertEqual(model.count(for: .newsletters), 4)
        XCTAssertEqual(model.count(for: .spam), 0, "Zero is an answer, not an absent tally")
    }

    func testTheHandingRowNeverCarriesACount() {
        let model = OnboardingPreparingViewModel()
        model.unreadCount = 31
        model.newsletterCount = 4
        model.spamCount = 2
        XCTAssertNil(model.count(for: .handing))
        XCTAssertNil(OnboardingPreparingViewModel.Step.handing.countTitle,
                     "A row that is only ever a phase has no number to label")
    }

    func testEveryRowNamesItselfDistinctlyWhileItRuns() {
        let titles = OnboardingPreparingViewModel.Step.allRows.map(\.runningTitle)
        XCTAssertEqual(titles, [
            "Reading your unread mail",
            "Finding newsletters",
            "Checking for spam",
            "Handing it to Jo",
        ])
        XCTAssertEqual(Set(titles).count, titles.count, "Two rows sharing a title read as a stall")
    }

    func testOnlyTheCountingRowsOfferACountTitle() {
        XCTAssertEqual(OnboardingPreparingViewModel.Step.unread.countTitle, "Unread")
        XCTAssertEqual(OnboardingPreparingViewModel.Step.newsletters.countTitle, "Newsletters found")
        XCTAssertEqual(OnboardingPreparingViewModel.Step.spam.countTitle, "Spam found")
        XCTAssertNil(OnboardingPreparingViewModel.Step.handing.countTitle)
    }
}

private extension OnboardingPreparingViewModel.Step {
    /// The rows in the order the screen runs them. `Step` is `Hashable` rather than
    /// `CaseIterable`, so the order is named here rather than derived.
    static var allRows: [OnboardingPreparingViewModel.Step] {
        [.unread, .newsletters, .spam, .handing]
    }
}
