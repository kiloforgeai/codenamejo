import FactoryKit
import XCTest

@testable import CodenameJo

/// `set_rule` and `feed_items`, answered on the phone.
@MainActor
final class LocalSettingsToolsTests: XCTestCase {

    private func scratchDefaults() -> UserDefaults {
        let name = "LocalSettingsToolsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testARuleSwitchesOnlyOnABooleanAndReadsBack() {
        let defaults = scratchDefaults()
        XCTAssertTrue(StandingRuleTool.run(argumentsJSON: #"{"rule":"archive_everything","enabled":true}"#,
                                           defaults: defaults).hasPrefix("NOT CHANGED"))
        XCTAssertTrue(StandingRuleTool.run(argumentsJSON: #"{"rule":"archive_after_reply","enabled":1}"#,
                                           defaults: defaults).contains("is off"), "a number is not a switch")
        let on = StandingRuleTool.run(argumentsJSON: #"{"rule":"archive_after_reply","enabled":true}"#, defaults: defaults)
        XCTAssertTrue(on.hasPrefix(#"Rule "Archive after replying" is now on."#), on)
        XCTAssertTrue(defaults.bool(forKey: StandingRule.archiveAfterReply.storageKey))
        let all = StandingRuleTool.run(argumentsJSON: "{}", defaults: defaults)
        XCTAssertTrue(all.contains("- Archive after replying: on") && all.contains("- Archive after forwarding: off"), all)
        XCTAssertTrue(StandingRuleTool.run(argumentsJSON: #"{"rule":"archive_after_reply","enabled":false}"#,
                                           defaults: defaults).contains("nothing already filed comes back"))
    }

    func testTheFeedHoldsFiveItemsAndRemovesByWord() {
        let defaults = scratchDefaults()
        XCTAssertTrue(FeedItems.run(argumentsJSON: #"{"action":"add"}"#, defaults: defaults).hasPrefix("NOT ADDED"))
        let added = FeedItems.run(argumentsJSON: #"{"action":"add","items":[{"label":"Nvidia","query":"NVIDIA closing price"},{"label":"SF weather","query":"weather in San Francisco today"}]}"#,
                                  defaults: defaults)
        XCTAssertEqual(added, "Added to their morning feed: Nvidia, SF weather.")
        XCTAssertEqual(FeedItems.run(argumentsJSON: #"{"action":"list"}"#, defaults: defaults),
                       "Their morning feed has: Nvidia, SF weather.")
        let more = (1...4).map { #"{"label":"Item \#($0)","query":"query \#($0)"}"# }.joined(separator: ",")
        XCTAssertTrue(FeedItems.run(argumentsJSON: #"{"action":"add","items":[\#(more)]}"#, defaults: defaults)
            .contains("1 more did not fit"))
        XCTAssertEqual(FeedItems.run(argumentsJSON: #"{"action":"remove","label":"weather"}"#, defaults: defaults),
                       "Removed from their morning feed: SF weather.")
        XCTAssertTrue(FeedItems.run(argumentsJSON: #"{"action":"remove","label":"cricket"}"#, defaults: defaults)
            .hasPrefix("NOT REMOVED"))
        XCTAssertEqual(FeedItems.all(defaults: defaults).count, 4)
    }

    func testOnlyTodaysAnswersReachTheGreeting() {
        let defaults = scratchDefaults()
        let now = Date()
        FeedItems.save([
            FeedItem(id: "a", label: "A", query: "a", answer: "Fresh.", fetchedAt: now),
            FeedItem(id: "b", label: "B", query: "b", answer: "Stale.", fetchedAt: now.addingTimeInterval(-2 * 86_400)),
            FeedItem(id: "c", label: "C", query: "c"),
        ], defaults: defaults)
        XCTAssertEqual(FeedItems.todaysAnswers(now: now, defaults: defaults), ["Fresh."])
    }

    func testTheSearchModelTalkingAboutItselfIsDropped() {
        XCTAssertEqual(FeedItems.cleanAnswer(
            "NVIDIA closed at $224.58, down $0.93, or 0.41%, from the previous close. "
                + "I couldn’t find a current closing price for Cisco in the results you provided."),
            "NVIDIA closed at $224.58, down $0.93, or 0.41%, from the previous close.")
        XCTAssertEqual(FeedItems.cleanAnswer("Based on the sources provided, Cisco closed at $64.10. It rose 1%."),
                       "Cisco closed at $64.10. It rose 1%.")
        XCTAssertNil(FeedItems.cleanAnswer("I couldn't find today's forecast for Springfield."))
        XCTAssertNil(FeedItems.cleanAnswer(""))
        XCTAssertEqual(FeedItems.cleanAnswer("Cisco closed at $64.10"), "Cisco closed at $64.10")
    }
}
