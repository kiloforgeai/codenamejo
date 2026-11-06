import XCTest
@testable import CodenameJo

final class SessionExportRegressionTests: XCTestCase {
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
