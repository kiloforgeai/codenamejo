import FactoryKit
import XCTest
@testable import CodenameJo

@MainActor
final class DispatchAttemptHistoryTests: XCTestCase {
    override func setUp() async throws { Container.shared.manager.push(); ProfileRuntime.install(nil) }
    override func tearDown() async throws { Scope.singleton.reset(); Container.shared.manager.pop(); ProfileRuntime.install(nil) }

    func testEveryEarlyDispatchRefusalPersistsWithOriginAndReasonAfterReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let context = LocalContextStore(url: folder.appendingPathComponent("history.sqlite"))
        defer { try? context.dbPool?.close(); try? FileManager.default.removeItem(at: folder) }
        let diagnostics = VoiceDiagnostics(directory: folder.appendingPathComponent("logs"))
        let service = RealtimeService(), client = FullDuplexVoiceClient(localContext: context)
        Container.shared.realtimeService.register { service }
        service.bindLiveHistory(client)
        client.dispatchScopeRequired = true
        client.diagnostics = diagnostics.begin(engine: "live", userID: "fixture-owner")
        let cases: [(String, String, String)] = [
            ("[sniffing]", #"{"task":"Search secret page","scope":"independent"}"#, "non_request"),
            ("Search Example Workspace", #"{"task":"Search Example Workspace"}"#, "scope_required"),
            ("Search Example Workspace", #"{"task":"","scope":"independent"}"#, "task_empty"),
            ("Research this email", #"{"task":"Research source","scope":"current_email"}"#, "source_missing"),
            ("Run missing command", #"{"command":"missing-fixture-command"}"#, "command_not_found")
        ]
        var accepted = 0
        client.onDispatchStarted = { _, _ in accepted += 1 }
        for (index, entry) in cases.enumerated() {
            client.handle(.liveUserActivity)
            client.handle(.liveInputText(entry.0))
            client.latestCompletedUserUtterance = entry.0
            let id = client.historyTurnID
            client.startDispatch(callId: "refused-\(index)", argumentsJSON: entry.1)
            client.startDispatch(callId: "refused-\(index)", argumentsJSON: entry.1)
            client.handle(.event(.assistantTranscriptDelta(itemId: "speech-\(index)", delta: "I will search now.", spoken: true)))
            client.emitFinalTranscript(); client.checkpointHistory()
            let record = try XCTUnwrap(service.lastCompletedTurn)
            XCTAssertEqual(record.id, id)
            XCTAssertEqual(record.status, .failed)
            XCTAssertEqual(record.toolSteps?.count, 1)
            XCTAssertEqual(record.toolSteps?.first?.outcome, "refused")
            XCTAssertEqual(record.toolSteps?.first?.reason, entry.2)
            XCTAssertNotNil(record.toolSteps?.first?.milliseconds)
            XCTAssertEqual(record.toolSteps?.first?.tool, index == 4 ? "dispatch_command" : "dispatch")
            try await TurnStore(database: context.dbPool).save(.init(record, userId: "fixture-owner"))
            try await TurnStore(database: context.dbPool).save(.init(CommandRecord(id: id,
                commandText: entry.0, status: .conversational), userId: "fixture-owner"))
        }
        XCTAssertEqual(accepted, 0)
        XCTAssertTrue(client.dispatchTasks.isEmpty)
        let reopened = LocalContextStore(url: folder.appendingPathComponent("history.sqlite"))
        defer { try? reopened.dbPool?.close() }
        let rows = try await TurnStore(database: reopened.dbPool).history(owner: "fixture-owner")
        XCTAssertEqual(rows.count, cases.count)
        XCTAssertTrue(rows.allSatisfy { $0.status == .failed && $0.toolSteps?.count == 1 })
        let export = String(decoding: try SessionExport.append(records: rows, jobs: [],
            to: try await diagnostics.snapshot(userID: "fixture-owner"), includeContent: false), as: UTF8.self)
        for entry in cases { XCTAssertTrue(export.contains(entry.2)) }
        for secret in ["Example Workspace", "secret page", "fixture-owner", "missing-fixture-command"] {
            XCTAssertFalse(export.contains(secret), secret)
        }
    }

    func testAdapterRefusalBeforeExecutorAlsoReachesDurableHistory() async throws {
        let service = RealtimeService(), client = FullDuplexVoiceClient()
        service.bindLiveHistory(client)
        client.handle(.liveUserActivity); client.handle(.liveInputText("Search the project"))
        let original = client.historyTurnID
        var finished = false
        let adapter = LiveSessionAdapter(wire: { _ in }, emit: { if case .liveInputFinished = $0 { finished = true } })
        defer { adapter.close() }
        adapter.onDispatchRefused = { call, reason in client.recordAdapterDispatchRefusal(call, turn: adapter.turn(for: call.delegation) ?? 1, reason: reason) }
        func receive(_ event: [String: Any]) throws { adapter.receive(try JSONSerialization.data(withJSONObject: event)) }
        try receive(["type": "session.started"])
        try receive(["type": "session.input_transcript.delta", "delta": "Search the project", "start_ms": 100, "end_ms": 200])
        for _ in 0..<400 where !finished { try await Task.sleep(for: .milliseconds(5)) }
        try receive(["type": "session.delegation.created", "offset_ms": 200, "delegation": ["id": "d", "response_id": "r"]])
        try receive(["type": "response.event", "event": ["type": "response.created", "response": ["id": "r"]]])
        try receive(["type": "session.input_transcript.delta", "delta": "Actually stop", "start_ms": 4000, "end_ms": 4100])
        try receive(["type": "response.event", "event": ["type": "response.output_item.done", "response_id": "r",
            "item": ["type": "function_call", "call_id": "late", "name": "dispatch", "arguments": "{}"]]])
        XCTAssertEqual(service.lastCompletedTurn?.id, original)
        XCTAssertEqual(service.lastCompletedTurn?.status, .failed)
        XCTAssertEqual(service.lastCompletedTurn?.toolSteps?.first?.reason, "stale_or_unsettled_request")
        XCTAssertTrue(client.dispatchTasks.isEmpty)
    }

    func testCapacityAndUnavailableSourceProduceNoJobAndDurableRefusal() throws {
        let service = RealtimeService(), client = FullDuplexVoiceClient()
        Container.shared.realtimeService.register { service }
        service.bindLiveHistory(client)
        client.handle(.liveUserActivity); client.handle(.liveInputText("Research the project"))
        client.latestCompletedUserUtterance = "Research the project"
        for index in 0..<FullDuplexVoiceClient.maxLiveDispatches { client.dispatchTasks["busy-\(index)"] = Task {} }
        client.startDispatch(callId: "capacity", argumentsJSON: #"{"task":"Research the project","scope":"independent"}"#)
        XCTAssertEqual(service.lastCompletedTurn?.toolSteps?.last?.reason, "capacity_limit")
        client.dispatchTasks = [:]
        client.handle(.liveUserActivity); client.handle(.liveInputText("Research this email"))
        client.standingStep = #"{"done":false,"item":{"account":"owner@example.test","id":"a","threadId":"t"}}"#
        client.startDispatch(callId: "account", argumentsJSON: #"{"task":"Research source","scope":"current_email","account":"other@example.test"}"#)
        XCTAssertEqual(service.lastCompletedTurn?.toolSteps?.last?.reason, "account_mismatch")
        XCTAssertTrue(client.dispatchTasks.isEmpty)
    }

    func testAcceptedAndTerminalOutcomesStayWithOriginalTurnWithoutDuplicateSteps() {
        for status in [CommandRecord.CommandStatus.success, .failed, .cancelled, .unknown] {
            let service = RealtimeService(), client = FullDuplexVoiceClient()
            service.bindLiveHistory(client)
            client.handle(.liveUserActivity); client.handle(.liveInputText("Find Project notes"))
            let original = client.historyTurnID
            client.beginDispatchAttempt(callID: "call", tool: "dispatch_command")
            client.postDispatchOutput(callId: "call", output: "Started.")
            XCTAssertEqual(service.lastCompletedTurn?.status, .pending)
            client.handle(.event(.assistantTranscriptDelta(itemId: "ack", delta: "Started.", spoken: true)))
            client.emitFinalTranscript(); client.checkpointHistory()
            XCTAssertEqual(service.lastCompletedTurn?.toolSteps?.first?.outcome, "accepted")
            client.handle(.liveUserActivity); client.handle(.liveInputText("What is next?"))
            client.recordDispatchAttempt(callID: "call", status: status, reason: "worker_" + status.rawValue)
            client.recordDispatchAttempt(callID: "call", status: status, reason: "worker_" + status.rawValue)
            XCTAssertEqual(service.lastCompletedTurn?.id, original)
            XCTAssertEqual(service.lastCompletedTurn?.status, status)
            XCTAssertEqual(service.lastCompletedTurn?.toolSteps?.count, 1)
            XCTAssertEqual(service.lastCompletedTurn?.toolSteps?.first?.outcome, status.rawValue)
            let stale = CommandRecord(id: original, commandText: "Find Project notes", status: .conversational)
                .preservingTerminalAttempts(from: service.lastCompletedTurn)
            XCTAssertEqual(stale.status, status)
            XCTAssertEqual(stale.toolSteps?.first?.outcome, status.rawValue)
        }
    }
}
