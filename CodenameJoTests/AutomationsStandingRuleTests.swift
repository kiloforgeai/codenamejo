import XCTest
@testable import CodenameJo

// coverage-target: CodenameJo/Views/AutomationsView.swift

/// The Rules half of Automations owns three switches that move the user's mail without
/// being asked. The screen reads them through `AutomationsViewInteractor.switchedOn()` and
/// writes them through `setRule`, straight into the `UserDefaults` keys `UserProfileStore`
/// mirrors onto the account — so a rule switched here and one switched mid-call by
/// `set_rule` land in the same place. A rule that reads on when it is off is a rule the
/// user never agreed to.
@MainActor
final class AutomationsStandingRuleTests: XCTestCase {

    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for rule in StandingRule.allCases {
            if let value = UserDefaults.standard.object(forKey: rule.storageKey) {
                saved[rule.storageKey] = value
            }
            UserDefaults.standard.removeObject(forKey: rule.storageKey)
        }
    }

    override func tearDown() {
        for rule in StandingRule.allCases {
            if let value = saved[rule.storageKey] {
                UserDefaults.standard.set(value, forKey: rule.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: rule.storageKey)
            }
        }
        saved = [:]
        super.tearDown()
    }

    func testAnAccountThatHasNeverAnsweredHasNoRuleSwitchedOn() {
        XCTAssertEqual(AutomationsViewInteractor.switchedOn(), [],
                       "A rule the user has never seen must not start moving their mail")
    }

    func testSwitchingOneRuleOnLeavesTheOtherTwoOff() {
        UserDefaults.standard.set(true, forKey: StandingRule.archiveAfterReply.storageKey)
        XCTAssertEqual(AutomationsViewInteractor.switchedOn(), [.archiveAfterReply])
    }

    func testAnExplicitFalseReadsTheSameAsNeverAnswered() {
        for rule in StandingRule.allCases {
            UserDefaults.standard.set(false, forKey: rule.storageKey)
        }
        XCTAssertEqual(AutomationsViewInteractor.switchedOn(), [])
    }

    func testAllThreeRulesCanBeOnAtOnce() {
        for rule in StandingRule.allCases {
            UserDefaults.standard.set(true, forKey: rule.storageKey)
        }
        XCTAssertEqual(AutomationsViewInteractor.switchedOn(), Set(StandingRule.allCases))
    }

    func testSwitchingARuleOnWritesTheKeyTheAccountMirrors() {
        let model = AutomationsViewModel()
        AutomationsViewInteractor().setRule(.archiveAfterForward, enabled: true, viewModel: model)
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: StandingRule.archiveAfterForward.storageKey) as? Bool,
            true)
        XCTAssertEqual(model.rules, [.archiveAfterForward],
                       "The row redraws off the recomputed set, not off the tap")
    }

    func testSwitchingARuleBackOffRemovesItAndKeepsTheRest() {
        let model = AutomationsViewModel()
        let interactor = AutomationsViewInteractor()
        interactor.setRule(.archiveAfterForward, enabled: true, viewModel: model)
        interactor.setRule(.archiveAfterLabel, enabled: true, viewModel: model)
        interactor.setRule(.archiveAfterForward, enabled: false, viewModel: model)
        XCTAssertEqual(model.rules, [.archiveAfterLabel])
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: StandingRule.archiveAfterForward.storageKey) as? Bool,
            false,
            "Switching off writes false rather than forgetting the answer")
    }
}
