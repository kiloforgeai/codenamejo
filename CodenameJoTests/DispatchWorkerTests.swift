import XCTest
@testable import CodenameJo

final class DispatchWorkerTests: XCTestCase {
    private let raw = #"{"account":" owner@example.test ","threadId":" thread ","id":" representative ","from":" Sender ","subject":" Topic "}"#
    private let prefix = "Current queue context, not a resolved action target. "

    func testTargetsNormalizeOneMessageAndRefuseWhatIsNotOne() throws {
        let target = try XCTUnwrap(DispatchWorker.target(standingOnJSON: raw, facts: []))
        XCTAssertEqual(target["account"] as? String, "owner@example.test")
        XCTAssertEqual(target["id"] as? String, "representative")
        XCTAssertEqual(target["from"] as? String, "Sender")
        XCTAssertEqual(target["subject"] as? String, "Topic")
        for value in ["null", "1", "[]", "{}", #"{"from":" "}"#, #"{"from":42}"#, "{"] {
            XCTAssertNil(DispatchWorker.target(standingOnJSON: value, facts: []), value)
        }
    }

    func testAGroupStaysUnresolvedAndOneBadMemberRefusesIt() throws {
        let group = #"{"account":"a@example.test","threadId":"t","messages":[{"id":" one ","from":" Alice ","subject":"First"},{"id":"two","from":"Bob","subject":"Second"}]}"#
        let target = try XCTUnwrap(DispatchWorker.target(standingOnJSON: group, facts: []))
        XCTAssertEqual(target["id"] as? String, "")
        XCTAssertEqual(target["from"] as? String, "")
        XCTAssertEqual((target["messages"] as? [[String: Any]])?.first?["id"] as? String, "one")
        let bad = #"{"messages":[{"id":"good","from":"Bob"},{"id":"","from":"Alice"}]}"#
        XCTAssertNil(DispatchWorker.target(standingOnJSON: bad, facts: []))
        XCTAssertNil(DispatchWorker.target(standingOnJSON: #"{"from":"Bob","messages":[]}"#, facts: []))
    }

    func testQueueFactsOverrideTheRawTargetAndNeverFallBack() {
        let fact = prefix + #"{"from":"Fact sender","id":"fact-id"}"#
        XCTAssertEqual(DispatchWorker.target(standingOnJSON: raw, facts: ["Unrelated", fact])?["id"] as? String, "fact-id")
        XCTAssertEqual(DispatchWorker.target(standingOnJSON: raw, facts: ["Unrelated"])?["id"] as? String, "representative")
        for broken in ["broken", "{", "null", #"{"messages":[]}"#] {
            XCTAssertNil(DispatchWorker.target(standingOnJSON: raw, facts: [prefix + broken, fact]))
        }
    }

    func testReceiptsNeedAnExplicitCompletionRecord() {
        XCTAssertEqual(DispatchWorker.actionResult(#"{"completed":true,"report":"  Archived it.\n"}"#, writeFailed: false).text, "Archived it.")
        XCTAssertTrue(DispatchWorker.actionResult(#"{"completed":true,"report":"Archived it."}"#, writeFailed: false).ok)
        XCTAssertFalse(DispatchWorker.actionResult(#"{"completed":true,"report":"Sent."}"#, writeFailed: true).ok)
        XCTAssertFalse(DispatchWorker.actionResult(#"{"completed":false,"report":"Need the address."}"#, writeFailed: false).ok)
        for raw in [#"{"completed":true,"report":"#, "Done.", "", "null", "[]", "true", #"{"completed":true,"report":" "}"#] {
            let result = DispatchWorker.actionResult(raw, writeFailed: false)
            XCTAssertFalse(result.ok, raw)
            XCTAssertTrue(result.text.contains("did not confirm"), raw)
        }
    }

    @MainActor
    func testWorkerPromptIsTheBaseWithTheWorkerSectionAndReceiptsAddTheSchemaRule() throws {
        let answer = try DispatchWorker.instructions(receipt: false, mail: true, calendar: false)
        XCTAssertTrue(answer.hasPrefix("# Role"))
        XCTAssertTrue(answer.contains("# You are working alone"))
        XCTAssertFalse(answer.contains("Return a JSON object with completed and report"))
        let receipt = try DispatchWorker.instructions(receipt: true, mail: true, calendar: false)
        XCTAssertTrue(receipt.contains("Return a JSON object with completed and report"))
    }

    @MainActor
    func testIndependentJobsCarryNoEmailReferentAndEmailJobsDo() throws {
        let job = DispatchWorker.Job(id: UUID(), task: "Weather", facts: ["Sarah is sarah@example.test"], standingOnJSON: raw)
        let current = try DispatchWorker.context(job, target: DispatchWorker.target(standingOnJSON: raw, facts: []),
                                                 mail: ["owner@example.test"], calendar: [])
        XCTAssertTrue(current.contains("# The message this job was handed over about"))
        XCTAssertTrue(current.contains("- message_id: representative"))
        XCTAssertTrue(current.contains("- Sarah is sarah@example.test"))
        XCTAssertTrue(current.contains("their own email address: owner@example.test"))
        XCTAssertTrue(current.hasPrefix("Clock: it is "))
        let independent = try DispatchWorker.context(job, target: nil, mail: [], calendar: [])
        XCTAssertFalse(independent.contains("handed over about"))
        XCTAssertFalse(independent.contains("# Who the user is"))
    }

    @MainActor
    func testAnOldNoteSaysWhenItWasSpokenAndAFreshOneDoesNot() throws {
        var job = DispatchWorker.Job(id: UUID(), task: "Remind me")
        let now = Date()
        job.authoredAt = now.addingTimeInterval(-90 * 60)
        let old = try DispatchWorker.context(job, target: nil, mail: [], calendar: [], now: now)
        XCTAssertTrue(old.contains("# This request was made earlier"))
        XCTAssertTrue(old.contains("1 hour and 30 minutes ago"))
        job.authoredAt = now.addingTimeInterval(-60)
        XCTAssertFalse(try DispatchWorker.context(job, target: nil, mail: [], calendar: [], now: now)
            .contains("made earlier"))
    }

    @MainActor
    func testTheCalendarCreateToolCarriesTheInviteNote() {
        let tools = DispatchWorker.tools(mail: [], calendar: ["owner@example.test"], relay: [])
        let create = tools.first { $0["name"] as? String == CalendarTools.create }
        XCTAssertTrue((create?["description"] as? String ?? "").contains("that was the yes"))
        XCTAssertTrue(tools.contains { $0["type"] as? String == "web_search" })
    }

    func testConnectorToolsReachTheWorkerOnlyWhenConnected() throws {
        let catalog = LiveSessionSetup.Catalog.bundled
        let mcp: [String: Any] = ["type": "function", "name": "mcp_acme_file_issue", "parameters": ["type": "object"]]
        let all = LiveSessionSetup.workerTools(inboxes: ["owner@example.test"], calendars: [], draftsOnly: { _ in true },
                                               notion: true, granola: true, slack: true, githubAccounts: ["octo"],
                                               customMCPTools: [mcp], catalog: catalog)
        let names = all.compactMap { $0["name"] as? String }
        for name in GranolaTools.names + GitHubTools.readTools + GitHubTools.writeTools + NotionTools.names
            + ["slack_read_channel", "slack_send_message", "mcp_acme_file_issue"] {
            XCTAssertTrue(names.contains(name), name)
        }
        XCTAssertEqual(Set(names).count, names.count, "no tool is declared twice")
        // The queues and the one cancel stay with the live call.
        for kept in [SlackTools.queueName, "triage_next", "cancel_calendar_event"] {
            XCTAssertFalse(names.contains(kept), kept)
        }
        let plain = LiveSessionSetup.workerTools(inboxes: ["owner@example.test"], calendars: [], draftsOnly: { _ in true },
                                                 catalog: catalog).compactMap { $0["name"] as? String }
        XCTAssertFalse(plain.contains { name in ["granola_", "slack_", "github_", "mcp_"].contains { name.hasPrefix($0) } })
    }

    @MainActor
    func testWorkerInstructionsCarryTheSkillsOfTheConnectorsItHas() throws {
        let plain = try DispatchWorker.instructions(receipt: false, mail: true, calendar: false)
        for marker in ["# Slack", "# Code", "# Meetings", "# Notes", "own tool servers"] {
            XCTAssertFalse(plain.contains(marker), marker)
        }
        let full = try DispatchWorker.instructions(receipt: false, mail: true, calendar: false, notion: true,
                                                   granola: true, slack: true, github: true, customMCP: ["Acme"])
        for marker in ["# Slack", "# Code", "# Meetings", "# Notes", "own tool servers to this app: Acme"] {
            XCTAssertTrue(full.contains(marker), marker)
        }
        // The worker's own section comes last, so its reading of "ask the user" wins.
        let worker = try XCTUnwrap(full.range(of: "# You are working alone"))
        XCTAssertLessThan(try XCTUnwrap(full.range(of: "# Code")).lowerBound, worker.lowerBound)
        XCTAssertLessThan(try XCTUnwrap(full.range(of: "own tool servers")).lowerBound, worker.lowerBound)
    }

    func testOnlyMailAndCalendarToolsTakeThePinnedAccount() {
        for name in ["send_email", "archive_message", GmailReadTools.search, CalendarTools.create, "find_person",
                     "respond_to_calendar_event"] {
            XCTAssertTrue(DispatchWorker.takesMailAccount(name), name)
        }
        for name in ["github_get_me", "mcp_acme_file_issue", "slack_send_message", "slack_read_channel",
                     "granola_list_meetings", "notion-search"] {
            XCTAssertFalse(DispatchWorker.takesMailAccount(name), name)
        }
    }
}

final class DispatchJobStoreTests: XCTestCase {
    @MainActor
    func testRowsAreScopedToTheirProfileAndSurviveAReload() async throws {
        defer { ProfileRuntime.install(nil) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DispatchJobStore(url: url)
        let personal = UUID(), work = UUID()
        store.begin(id: personal, task: "Personal note", profileId: "personal")
        store.begin(id: work, task: "Work note", profileId: "work")
        store.finish(work, state: "done", result: "Archived.", reportBack: false)

        ProfileRuntime.install(.init(profileId: "personal", isDefault: false))
        let reloaded = DispatchJobStore(url: url)
        let personalRows = await reloaded.history()
        XCTAssertEqual(personalRows.map(\.id), [personal])
        ProfileRuntime.install(.init(profileId: "work", isDefault: false))
        let workRows = await reloaded.history()
        let row = try XCTUnwrap(workRows.first)
        XCTAssertEqual(row.result, "Archived.")
        XCTAssertEqual(row.reportBack, false)
        let recovered = await reloaded.recover()
        XCTAssertTrue(recovered.isEmpty, "a silent success is not recovered")
    }

    @MainActor
    func testAnUnheardAnswerIsRecoveredOnceSettled() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DispatchJobStore(url: url)
        let id = UUID()
        store.begin(id: id, task: "Look up", profileId: nil)
        store.finish(id, state: "done", result: "Thursday at two.")
        let first = await store.recover()
        XCTAssertEqual(first.map(\.id), [id])
        await store.settle(id)
        let second = await store.recover()
        XCTAssertTrue(second.isEmpty)
        let rows = await store.history()
        XCTAssertNotNil(rows.first?.deliveredAt)
    }
}
