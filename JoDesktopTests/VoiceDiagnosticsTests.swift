import XCTest
@testable import CodenameJo

final class VoiceDiagnosticsTests: XCTestCase {
    func testExportDoesNotIncludeAnotherAccountsLifecycleEvents() async throws {
        let log = VoiceDiagnostics(directory: try directory())
        let first = log.begin(engine: "live", userID: "first-user")
        _ = log.begin(engine: "live", userID: "second-user")
        _ = log.begin(engine: "speaker_test")
        first.record(.sessionEnded)
        let data = try await log.snapshot(userID: "first-user")
        let events = try rows(data)
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0["user_id"] as? String == "first-user" })
        XCTAssertTrue(events.allSatisfy { $0["session_id"] as? String == first.id.uuidString })
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func rows(_ data: Data) throws -> [[String: Any]] {
        try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func testSessionIdentitySurvivesAnotherSessionAndReopeningTheLog() async throws {
        let folder = try directory()
        let log = VoiceDiagnostics(directory: folder)
        let conversation = UUID()
        let first = log.begin(conversationID: conversation, engine: "live")
        let second = log.begin(engine: "speaker_test")
        first.record(.liveFailed, ["reason": "missing_prompt"])
        second.record(.speechFinished)
        _ = try await log.snapshot()
        let restored = try await VoiceDiagnostics(directory: folder).snapshot()
        let rows = try rows(restored)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[2]["session_id"] as? String, first.id.uuidString)
        XCTAssertEqual(rows[2]["conversation_id"] as? String, conversation.uuidString)
        XCTAssertEqual(rows[3]["session_id"] as? String, second.id.uuidString)
        XCTAssertNotNil(rows[2]["elapsed_ms"])
    }

    func testExportExcludesContentAndCredentialsButKeepsProviderDiagnostics() async throws {
        let log = VoiceDiagnostics(directory: try directory())
        let session = log.begin(engine: "live")
        session.record(.liveResponse, ["http_status": "403", "request_id": "req_test123",
            "provider_code": "model_not_found", "transcript": "private conversation",
            "authorization": "Bearer secret", "reason": "sk-secret", "model": "Bearer secret"])
        let data = try await log.snapshot()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("private conversation"))
        XCTAssertFalse(text.contains("secret"))
        let last = try XCTUnwrap(try rows(data).last)
        let fields = try XCTUnwrap(last["fields"] as? [String: String])
        XCTAssertEqual(fields, ["http_status": "403", "request_id": "req_test123", "provider_code": "model_not_found"])
    }

    func testRotationKeepsRecentCompleteEventsWithinTheStorageLimit() async throws {
        let folder = try directory()
        let log = VoiceDiagnostics(directory: folder, maximumBytes: 800)
        let session = log.begin(engine: "live")
        for _ in 0..<100 { session.record(.microphoneStarted) }
        session.record(.sessionEnded)
        let data = try await log.snapshot()
        XCTAssertLessThanOrEqual(data.count, 3200)
        let rows = try rows(data)
        XCTAssertEqual(rows.last?["event"] as? String, "sessionEnded")
        XCTAssertEqual(rows.last?["sequence"] as? Int, 102)
        XCTAssertLessThan(rows.count, 102)
        XCTAssertLessThanOrEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 4)
    }
}
