import FactoryKit
import XCTest
@testable import CodenameJo

final class SessionExportRegressionTests: XCTestCase {
    @MainActor
    func testRetainedConversationsExportAllProfilesWithReceiptsButNeverOtherUsers() async throws {
        Container.shared.manager.push()
        let previousProfile = ProfileRuntime.snapshot
        ProfileRuntime.install(nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let context = LocalContextStore(url: folder.appendingPathComponent("context.sqlite"))
        defer {
            try? context.dbPool?.close(); try? FileManager.default.removeItem(at: folder)
            Scope.singleton.reset(); Container.shared.manager.pop(); ProfileRuntime.install(previousProfile)
        }
        let backend = BackendService(restoringSession: false)
        backend.userId = "owner"
        Container.shared.backend.register { backend }
        let turns = TurnStore(database: context.dbPool)
        let conversations = [UUID(), UUID(), UUID()]
        let log = VoiceDiagnostics(directory: folder.appendingPathComponent("logs"))
        var records: [CommandRecord] = [], jobs: [DispatchJob] = []
        for (index, conversation) in conversations.enumerated() {
            let session = log.begin(conversationID: conversation, engine: "live", userID: "owner")
            let record = CommandRecord(commandText: "Private request", responseText: "Private result", status: .success, conversationId: conversation)
            records.append(record)
            try await turns.save(.init(record, userId: index == 0 ? "owner" : "owner:profile:p" + String(index)))
            session.record(.toolFinished, ["call_id": record.id.uuidString, "outcome": "success"])
            session.record(.sessionEnded)
            _ = try await log.saveFeedback("Private feedback", source: .button, userID: "owner",
                context: .init(sessionID: session.id, conversationID: conversation, turnID: record.id.uuidString))
            jobs.append(.init(id: UUID(), task: "Private task", state: "done", userId: "owner", conversationId: conversation,
                turnId: record.id.uuidString, receipts: [.init(callId: record.id.uuidString, tool: "archive_message", outcome: "success")]))
        }
        let intruder = CommandRecord(commandText: "Other user's secret", status: .success, conversationId: conversations[0])
        try await turns.save(.init(intruder, userId: "owner-other:profile:p1"))
        jobs.append(.init(id: UUID(), task: "Other user's secret", state: "done", userId: "other", conversationId: conversations[0]))
        let file = folder.appendingPathComponent("jobs.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(jobs).write(to: file)
        let store = DispatchJobStore(url: file)
        let logs = try await log.snapshot(userID: "owner")
        let ids = try SessionExport.retainedConversationIDs(in: logs)
        let history = try await turns.diagnosticHistory(userID: "owner", conversations: ids)
        let receipts = store.diagnosticHistory(conversations: ids)
        XCTAssertEqual(Set(history.map(\.id)), Set(records.map(\.id)))
        XCTAssertEqual(receipts.count, 3)
        let full = String(decoding: try SessionExport.append(records: history, jobs: receipts, to: logs, includeContent: true), as: UTF8.self)
        let safe = String(decoding: try SessionExport.append(records: history, jobs: receipts, to: logs, includeContent: false), as: UTF8.self)
        for id in conversations { XCTAssertTrue(full.contains(id.uuidString)); XCTAssertTrue(safe.contains(id.uuidString)) }
        XCTAssertTrue(full.contains("Private feedback")); XCTAssertTrue(full.contains("Private request"))
        XCTAssertFalse(full.contains("Other user's secret")); XCTAssertFalse(safe.contains("Private"))
        XCTAssertTrue(safe.contains("diagnostic_conversation_ids")); XCTAssertTrue(safe.contains("retention_state"))
    }

    func testDefaultExportRemovesFeedbackAndOperationContentButKeepsCorrelation() throws {
        let conversation = UUID(), turn = UUID(), job = UUID()
        var record = CommandRecord(id: turn, commandText: "Private request", responseText: "Private answer",
            status: .partial, conversationId: conversation)
        record.profile_id = "private-profile"
        let target = String(repeating: "a", count: 64)
        let work = DispatchJob(id: job, task: "Private task", state: "partial", result: "Private result",
            profileId: "private-profile", userId: "private-owner@example.test", conversationId: conversation,
            turnId: turn.uuidString, receipts: [.init(callId: "call-1", tool: "archive_message", outcome: "success", targetHash: target)],
            historyOwner: "private-owner@example.test:profile:private-profile",
            operation: .init(tool: "archive_message", account: "private-owner@example.test", messageID: "private-message-id"),
            foregroundContinuation: true)
        let feedback: [String: Any] = ["event": "userFeedback", "feedback_id": "feedback-1",
            "conversation_id": conversation.uuidString, "user_id": "private-owner@example.test",
            "profile_id": "private-profile", "message": "Private feedback about an email", "source": "button",
            "future_content_field": "private-message-id"]
        let logs = try JSONSerialization.data(withJSONObject: feedback)
        let safe = try SessionExport.append(records: [record], jobs: [work], to: logs, includeContent: false)
        let text = String(decoding: safe, as: UTF8.self)
        XCTAssertFalse(text.lowercased().contains("private"))
        XCTAssertTrue(text.contains("feedback_metadata"))
        XCTAssertTrue(text.contains("feedback-1"))
        XCTAssertTrue(text.contains(target))
        XCTAssertTrue(text.contains(conversation.uuidString))
        XCTAssertTrue(text.contains(turn.uuidString))
        XCTAssertTrue(text.contains(job.uuidString))
        let rows = try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let note = try XCTUnwrap(rows.first { $0["event"] as? String == "feedback_metadata" })
        let jobRow = try XCTUnwrap(rows.first { $0["event"] as? String == "job_metadata" }?["record"] as? [String: Any])
        XCTAssertEqual(note["owner_hash"] as? String, jobRow["owner_hash"] as? String)
        XCTAssertEqual(note["profile_hash"] as? String, jobRow["profile_hash"] as? String)
        XCTAssertEqual(jobRow["foregroundContinuation"] as? Bool, true)
        let full = String(decoding: try SessionExport.append(records: [record], jobs: [work], to: logs, includeContent: true), as: UTF8.self)
        XCTAssertTrue(full.contains("Private feedback"))
        XCTAssertTrue(full.contains("Private request"))
        XCTAssertTrue(full.contains("private-message-id"))
        XCTAssertTrue(full.contains("export_manifest"))
        XCTAssertEqual(full.split(separator: "\n").count, 4)
    }

    func testNestedProviderFailureKeepsRequestIdentityWithoutErrorContent() throws {
        let fields = try XCTUnwrap(VoiceDiagnostics.protocolFields(["type": "response.event",
            "delegation_id": "delegation-1", "event": ["type": "response.failed", "request_id": "req-provider",
                "response": ["id": "response-1", "status": "failed", "status_details": [
                    "error": ["code": "rate_limit", "message": "Private provider error text"]]]]]))
        XCTAssertEqual(fields["provider_request_id"], "req-provider")
        XCTAssertEqual(fields["provider_response_id"], "response-1")
        XCTAssertEqual(fields["delegation_id"], "delegation-1")
        XCTAssertEqual(fields["provider_code"], "rate_limit")
        XCTAssertFalse(fields.values.contains { $0.contains("Private") })
    }
}
