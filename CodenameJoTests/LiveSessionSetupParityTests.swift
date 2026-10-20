import XCTest
@testable import CodenameJo

/// The phone builds the session the server's `/api/realtime-token` and worker catalog built for
/// the same flags. `Fixtures/live-session-parity.json` was dumped by running that server code.
final class LiveSessionSetupParityTests: XCTestCase {
    private func fixture() throws -> [String: [[String: Any]]] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "live-session-parity", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [[String: Any]]])
    }

    /// Both sides through JSON, so Swift literals and parsed values compare alike.
    private func json(_ value: Any) throws -> NSObject {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
            options: .fragmentsAllowed) as? NSObject)
    }

    private func state(_ raw: [String: Any]) -> LiveSessionSetup.State {
        let policy = raw["sendPolicy"] as? [String: Any]
        let fallback = policy?["fallback"] as? Bool ?? true
        let byAccount = policy?["byAccount"] as? [String: Bool] ?? [:]
        var state = LiveSessionSetup.State(
            inboxes: raw["inboxes"] as? [String] ?? [], calendars: raw["calendars"] as? [String] ?? [],
            needsReauth: raw["needsReauth"] as? [String] ?? [], unreachable: raw["unreachable"] as? [String] ?? [],
            draftsOnly: { byAccount[$0.lowercased()] ?? fallback },
            triageScope: raw["triageScope"] as? String)
        // The fixture's per-connector keys, as the old server wrote them, onto each connector's standing.
        func status(working: [String], needsReauth: [String]) -> ConnectorStatus {
            ConnectorStatus(accounts: working + needsReauth, needsReauth: needsReauth)
        }
        state.connectors[NotionConnector.id] = status(working: raw["notion"] as? Bool == true ? ["Notion"] : [],
                                                      needsReauth: raw["notionNeedsReauth"] as? [String] ?? [])
        state.connectors[GranolaConnector.id] = status(working: raw["granola"] as? Bool == true ? ["granola"] : [],
                                                       needsReauth: raw["granolaNeedsReauth"] as? [String] ?? [])
        state.connectors[GitHubConnector.id] = status(working: raw["githubAccounts"] as? [String] ?? [],
                                                      needsReauth: raw["githubNeedsReauth"] as? [String] ?? [])
        // Phone-only scenarios: Slack was never the old server's, so these two were written here.
        state.connectors[SlackConnector.id] = status(working: raw["slackWorkspaces"] as? [String] ?? [],
                                                     needsReauth: raw["slackNeedsReauth"] as? [String] ?? [])
        return state
    }

    private func request(_ raw: [String: Any]) -> LiveSessionSetup.Request {
        var request = LiveSessionSetup.Request()
        request.opening = (raw["opening"] as? String).flatMap(SessionOpening.init(rawValue:)) ?? .none
        if let run = raw["onboardingRun"] as? [String: Any] {
            request.onboardingRun = (run["mailMode"] as? Bool == true, run["resume"] as? Bool == true,
                                     run["opening"] as? String ?? "")
        }
        request.dispatch = raw["dispatch"] as? Bool == true
        request.shortcutText = raw["shortcutText"] as? Bool == true
        request.shortcutRead = raw["shortcutRead"] as? Bool == true
        request.coachingLessons = raw["coachingLessons"] as? Int ?? 0
        request.cachedMailboxes = raw["unreadAccounts"] as? [String] ?? []
        if request.opening == .emailQueue {
            request.sequentialFeed = raw["sequentialFeed"] as? Bool == true
            request.calendarFeedDue = raw["calendarFeedDue"] as? Bool == true
            request.feedItems = raw["feedItems"] as? Bool == true
        }
        return request
    }

    private func assertSameTools(_ phone: [[String: Any]], _ server: [Any], _ scenario: String) throws {
        let phoneNames = phone.compactMap { $0["name"] as? String }
        let serverNames = server.compactMap { ($0 as? [String: Any])?["name"] as? String }
        XCTAssertEqual(phoneNames, serverNames, "\(scenario): tool names and order")
        for (mine, theirs) in zip(phone, server) {
            let name = mine["name"] as? String ?? "?"
            let theirs = theirs as? [String: Any] ?? [:]
            for key in Set(mine.keys).union(theirs.keys) {
                XCTAssertEqual(try json(mine[key] ?? NSNull()), try json(theirs[key] ?? NSNull()),
                               "\(scenario): \(name).\(key)")
            }
        }
    }

    func testThePhoneBuildsTheServersLiveToolsPromptFactsAndAnswers() throws {
        let catalog = LiveSessionSetup.Catalog.bundled
        let scenarios = try XCTUnwrap(fixture()["mint"])
        XCTAssertGreaterThanOrEqual(scenarios.count, 6)
        for scenario in scenarios {
            let name = scenario["name"] as? String ?? "?"
            let setup = LiveSessionSetup.resolve(
                request(scenario["request"] as? [String: Any] ?? [:]),
                state(scenario["state"] as? [String: Any] ?? [:]), catalog: catalog)
            try assertSameTools(setup.tools, scenario["tools"] as? [Any] ?? [], name)
            XCTAssertEqual(setup.fastActions, scenario["fastActions"] as? [String], "\(name): fastActions")
            XCTAssertEqual(try json(setup.prompt), try json(scenario["prompt"] ?? [:]), "\(name): prompt facts")

            let echoes = try XCTUnwrap(scenario["echoes"] as? [String: Any])
            let dispatch = (scenario["request"] as? [String: Any])?["dispatch"] as? Bool == true
            let shortcutText = (scenario["request"] as? [String: Any])?["shortcutText"] as? Bool == true
            let shortcutRead = (scenario["request"] as? [String: Any])?["shortcutRead"] as? Bool == true
            let phone: [String: Any] = [
                "openingMode": setup.openingMode.rawValue, "sequentialFeed": setup.sequentialFeed,
                "interactiveCoaching": setup.interactiveCoaching, "localCoachingDelivery": setup.localCoachingDelivery,
                "calendarFeedDue": setup.calendarFeedDue, "feedBriefing": setup.feedBriefing,
                "dispatch": dispatch, "dispatchScope": dispatch, "localContext": true, "scopedContext": true,
                "localMail": setup.localMail, "localDrafts": setup.localMail, "localCalendar": false,
                "localTriage": true, "localClock": true, "endSession": true, "stopListening": true,
                "shortcutText": shortcutText, "shortcutRead": shortcutRead, "phoneContacts": true,
                "model": LivePrompt.speakerModel,
            ]
            XCTAssertEqual(try json(phone), try json(echoes), "\(name): capability answers")
            XCTAssertEqual(scenario["emailPreparation"] as? Bool, true)
        }
    }

    func testDispatchWorkersGetTheServersWriteTools() throws {
        let catalog = LiveSessionSetup.Catalog.bundled
        for scenario in try XCTUnwrap(fixture()["worker"]) {
            let name = scenario["name"] as? String ?? "?"
            let raw = scenario["state"] as? [String: Any] ?? [:]
            let state = state(raw)
            let tools = LiveSessionSetup.workerTools(inboxes: state.inboxes, calendars: state.calendars,
                                                     draftsOnly: state.draftsOnly, connectors: state.connectors, catalog: catalog)
            try assertSameTools(tools, scenario["tools"] as? [Any] ?? [], name)
        }
    }

    func testCoverageNeedsTheSameMailboxSet() {
        XCTAssertTrue(LiveSessionSetup.mailboxSetsMatch(["A@x.test", "b@x.test"], [" b@x.test", "a@x.test", "a@x.test"]))
        XCTAssertFalse(LiveSessionSetup.mailboxSetsMatch(["a@x.test"], ["a@x.test", "b@x.test"]))
        XCTAssertFalse(LiveSessionSetup.mailboxSetsMatch([], []))
    }
}
