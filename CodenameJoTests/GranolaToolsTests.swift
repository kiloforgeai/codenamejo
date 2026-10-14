import FactoryKit
import XCTest
@testable import CodenameJo

final class GranolaToolsTests: XCTestCase {
    private func grant(_ id: String, label: String, needsReauth: Bool = false) -> RemoteMCPGrant {
        RemoteMCPGrant(id: id, label: label, profileId: "p1", accessToken: "a-\(id)", refreshToken: "r-\(id)",
                       expiresAt: Date().addingTimeInterval(3600), needsReauth: needsReauth, clientId: "c1",
                       tokenEndpoint: "https://mcp-auth.granola.ai/oauth2/token",
                       resource: "https://mcp.granola.ai/mcp", grantedAt: Date())
    }

    /// Records every call and answers from `answers[tool]`.
    private final class Recorder: @unchecked Sendable {
        var calls: [(grant: String, tool: String, args: [String: Any])] = []
        var answers: [String: RemoteMCPToolResult] = [:]
        var error: Error?
        var call: GranolaTools.Call {
            { grant, tool, args in
                self.calls.append((grant.id, tool, args))
                if let error = self.error { throw error }
                return self.answers[tool] ?? RemoteMCPToolResult(text: "", isError: false)
            }
        }
    }

    func testListingMapsMineOnlyToGranolasInvolvement() async {
        let recorder = Recorder()
        recorder.answers["list_meetings"] = .init(text: "<meetings/>", isError: false)
        let result = await GranolaTools.run(name: "granola_list_meetings",
                                            input: ["time_range": "this_week", "mine_only": true],
                                            grants: [grant("g1", label: "a@x.test")], call: recorder.call)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(recorder.calls.map(\.tool), ["list_meetings"])
        let args = recorder.calls[0].args
        XCTAssertNil(args["mine_only"])
        XCTAssertEqual(args["time_range"] as? String, "this_week")
        XCTAssertEqual(args["involvement"] as? [String: Bool], ["captured_by_me": true, "listed_as_participant": true])
    }

    func testListingTagsEachAccountWhenThereAreSeveral() async throws {
        let recorder = Recorder()
        recorder.answers["list_meetings"] = .init(text: "<meetings/>", isError: false)
        let result = await GranolaTools.run(name: "granola_list_meetings", input: [:],
                                            grants: [grant("g1", label: "a@x.test"), grant("g2", label: "b@x.test")],
                                            call: recorder.call)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [[String: String]])
        XCTAssertEqual(rows.map { $0["account"] }, ["a@x.test", "b@x.test"])
        XCTAssertEqual(recorder.calls.map(\.grant), ["g1", "g2"])
    }

    func testAMeetingReadNeedsOneToTenIds() async {
        let recorder = Recorder()
        let grants = [grant("g1", label: "a@x.test")]
        for bad: [String: Any] in [[:], ["meeting_ids": []], ["meeting_ids": [" "]],
                                   ["meeting_ids": (0..<11).map { "m\($0)" }]] {
            let result = await GranolaTools.run(name: "granola_get_meeting", input: bad, grants: grants, call: recorder.call)
            XCTAssertTrue(result.isError)
        }
        XCTAssertTrue(recorder.calls.isEmpty)

        recorder.answers["get_meetings"] = .init(text: "<meeting id=\"m1\"/>", isError: false)
        let ok = await GranolaTools.run(name: "granola_get_meeting", input: ["meeting_ids": ["m1"]],
                                        grants: grants, call: recorder.call)
        XCTAssertFalse(ok.isError)
        XCTAssertEqual(recorder.calls.map(\.tool), ["get_meetings"])
    }

    func testActionItemsReadEveryNextStepsHeadingAndItsOwners() async throws {
        let recorder = Recorder()
        recorder.answers["list_meetings"] = .init(text: """
            <meetings><meeting id="m1" title="Cico sync" date="2026-10-06"></meeting>
            <meeting id="m2" title="Standup" date="2026-10-07"></meeting></meetings>
            """, isError: false)
        recorder.answers["get_meetings"] = .init(text: """
            <meeting id="m1" title="Cico sync" date="Oct 6"><summary># Pricing
            - talked
            # Docs and Next Steps
            - **Send the contract** (Josh)
              Detail line about why.
            - **Review contractor docs (Patrick, Josh)**
            - Book the venue
            # Misc
            - not an action</summary></meeting>
            <meeting id="m2" title="Standup &amp; review" date="Oct 7"><summary># Notes
            - nothing here</summary></meeting>
            """, isError: false)
        let result = await GranolaTools.run(name: "granola_action_items", input: ["mine_only": true],
                                            grants: [grant("g1", label: "a@x.test")], call: recorder.call)
        XCTAssertFalse(result.isError)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
        XCTAssertEqual(json["count"] as? Int, 3)
        let items = try XCTUnwrap(json["items"] as? [[String: String]])
        XCTAssertEqual(items.map { $0["item"] }, ["Send the contract", "Review contractor docs", "Book the venue"])
        XCTAssertEqual(items.map { $0["owner"] }, ["Josh", "Patrick, Josh", nil])
        XCTAssertEqual(items.first?["meeting"], "Cico sync")
        XCTAssertEqual(json["meetingsWithNoActionItems"] as? [String], ["Standup & review"])
        XCTAssertEqual(recorder.calls.map(\.tool), ["list_meetings", "get_meetings"])
        XCTAssertEqual(recorder.calls[1].args["meeting_ids"] as? [String], ["m1", "m2"])
        XCTAssertNotNil(recorder.calls[0].args["involvement"])
    }

    func testActionItemsWithNoMeetingsSaySo() async throws {
        let recorder = Recorder()
        recorder.answers["list_meetings"] = .init(text: "No meetings found.", isError: false)
        let result = await GranolaTools.run(name: "granola_action_items", input: [:],
                                            grants: [grant("g1", label: "a@x.test")], call: recorder.call)
        XCTAssertTrue(result.text.contains("\"count\":0"))
        XCTAssertEqual(recorder.calls.count, 1)
    }

    func testARefusedGrantAsksForAReconnect() async {
        let recorder = Recorder()
        recorder.error = RemoteMCPError.unauthorized(status: 401)
        let result = await GranolaTools.run(name: "granola_get_meeting", input: ["meeting_ids": ["m1"]],
                                            grants: [grant("g1", label: "a@x.test")], call: recorder.call)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("reconnect Granola in Settings"))
    }

    func testGranolasOwnErrorTextReachesTheModel() async {
        let recorder = Recorder()
        recorder.answers["get_meetings"] = .init(text: "Transcripts need a paid plan.", isError: true)
        let result = await GranolaTools.run(name: "granola_get_meeting", input: ["meeting_ids": ["m1"]],
                                            grants: [grant("g1", label: "a@x.test")], call: recorder.call)
        XCTAssertEqual(result.text, "Transcripts need a paid plan.")
        XCTAssertTrue(result.isError)
    }

    func testNoGrantMeansConnectInSettings() async {
        let result = await GranolaTools.run(name: "granola_list_meetings", input: [:], grants: [], call: Recorder().call)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("connect Granola in Settings"))
    }

    func testTheAccountLabelComesFromGetAccountInfo() {
        XCTAssertEqual(GranolaConnector.email(in: #"{"email":"ana@x.test","workspace":"W"}"#), "ana@x.test")
        XCTAssertEqual(GranolaConnector.email(in: #"{"account":{"email":"bo@x.test"}}"#), "bo@x.test")
        XCTAssertEqual(GranolaConnector.email(in: "Signed in as cy@x.test (Acme)"), "cy@x.test")
        XCTAssertNil(GranolaConnector.email(in: "no address"))
    }

    func testSignInAsksForARefreshToken() {
        XCTAssertEqual(RemoteMCPService.granola.endpoint.absoluteString, "https://mcp.granola.ai/mcp")
        XCTAssertTrue(RemoteMCPService.granola.scope?.split(separator: " ").contains("offline_access") == true)
    }
}

final class GranolaSessionTests: XCTestCase {
    func testToolsSkillAndReauthFollowTheGrants() throws {
        let catalog = LiveSessionSetup.Catalog.bundled
        var state = LiveSessionSetup.State(inboxes: ["a@x.test"])
        let off = LiveSessionSetup.resolve(.init(), state, catalog: catalog)
        XCTAssertFalse(off.tools.contains { ($0["name"] as? String)?.hasPrefix("granola_") == true })
        XCTAssertNil(off.prompt["granolaNeedsReauth"])

        state.granola = true
        state.granolaNeedsReauth = ["old@x.test"]
        let on = LiveSessionSetup.resolve(.init(), state, catalog: catalog)
        XCTAssertEqual(on.tools.compactMap { $0["name"] as? String }.suffix(3), GranolaTools.names)
        XCTAssertEqual(on.prompt["skills"] as? [String], ["email", "granola"])
        XCTAssertEqual(on.prompt["granolaNeedsReauth"] as? [String], ["old@x.test"])
        XCTAssertTrue(GranolaTools.names.allSatisfy(LiveFastAction.feedIndependent.contains))
    }

    func testThePromptCarriesTheSkillAndTheReconnectNote() throws {
        let facts = LivePrompt.Facts(["skills": ["granola"], "granolaNeedsReauth": ["old@x.test"]])
        let brain = try LivePrompt.brainInstructions(facts, timeZone: "UTC")
        XCTAssertTrue(brain.contains("granola_action_items"))
        XCTAssertTrue(brain.contains("their Granola connection (old@x.test)"))
        let healthy = try LivePrompt.brainInstructions(LivePrompt.Facts(["skills": ["email"]]), timeZone: "UTC")
        XCTAssertFalse(healthy.contains("Granola"))
    }

    func testGranolaLessonsWaitForAConnection() {
        let defaults = UserDefaults(suiteName: "GranolaSessionTests.\(UUID().uuidString)")!
        let catalog = ["granola_meetings", "granola_action_items", "dispatch"]
            .map { CoachingRotation.Lesson(capability: $0, copy: "copy") }
        XCTAssertEqual(CoachingRotation.plan(.init(), catalog: catalog, defaults: defaults).lessons.map(\.capability),
                       ["dispatch"])
        XCTAssertEqual(CoachingRotation.plan(.init(hasGranola: true), catalog: catalog, defaults: defaults)
            .lessons.map(\.capability), ["granola_meetings", "granola_action_items", "dispatch"])
        XCTAssertNotNil(CoachingRotation.copy(for: "granola_action_items"))
    }

    func testTheBrokerRunsGranolaToolsOnThePhone() async {
        let storage = InMemoryRemoteMCPGrantStorage()
        Container.shared.remoteMCPGrantStorage.register { storage }
        defer { Container.shared.remoteMCPGrantStorage.reset() }
        let result = await FullDuplexBroker.runTool(name: "granola_list_meetings", argumentsJSON: "{}")
        XCTAssertEqual(result.ok, false)
        XCTAssertTrue(result.text.contains("connect Granola in Settings"))
    }

    func testSignOutForgetsEveryGranolaGrant() {
        let storage = InMemoryRemoteMCPGrantStorage()
        Container.shared.remoteMCPGrantStorage.register { storage }
        defer { Container.shared.remoteMCPGrantStorage.reset() }
        RemoteMCPGrantStore.save(RemoteMCPGrant(
            id: "g1", label: "a@x.test", profileId: nil, accessToken: "a", refreshToken: "r",
            expiresAt: Date(), clientId: "c", tokenEndpoint: "https://t.test", resource: "https://mcp.granola.ai/mcp",
            grantedAt: Date()), .granola)
        RemoteMCPGrantStore.saveRegistration(.init(clientId: "c", redirectURI: RemoteMCPService.redirectURI,
                                                   authorizationServer: "https://mcp-auth.granola.ai"), .granola)
        GranolaConnector.forget()
        XCTAssertTrue(RemoteMCPGrantStore.grants(.granola).isEmpty)
        XCTAssertNil(RemoteMCPGrantStore.registration(.granola))
    }

    @MainActor
    func testABrokenGranolaRowAsksForAttention() {
        let connections = ConnectionsService()
        connections.hasLoadedStatus = true
        connections.granolaAccounts = ["notes@x.test"]
        connections.granolaNeedsReauth = ["notes@x.test"]
        XCTAssertTrue(connections.hasAnyConnector)
        XCTAssertEqual(connections.singleAttentionProviderName, "Granola")
        XCTAssertTrue(connections.connectedServices.contains("Granola"))
    }
}
