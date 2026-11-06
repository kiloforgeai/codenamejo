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
        XCTAssertEqual(events.count, 3, "The export includes two lifecycle events and their coverage manifest")
        XCTAssertTrue(events.allSatisfy { $0["user_id"] as? String == "first-user" })
        XCTAssertTrue(events.allSatisfy { $0["session_id"] as? String == first.id.uuidString })
    }

    func testRenderedSelectionAndWriteReceiptUseTheSameRedactedIdentity() {
        let selection = MailSelection(account: "OWNER@example.test", messageID: "same-id")
        let write = VoiceDiagnostics.targetIdentity(arguments: #"{"account":"owner@example.test","message_id":"same-id","label_id":"Label_42","thread_id":"thread"}"#)
        XCTAssertEqual(write, selection.canonical)
        XCTAssertEqual(selection, MailSelection(account: "owner@example.test", messageID: "same-id"))
        XCTAssertNotEqual(write, MailSelection(account: "other@example.test", messageID: "same-id").canonical)
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
        let rows = try rows(restored).filter { $0["event"] as? String != "sessionManifest" }
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
        let last = try XCTUnwrap(try rows(data).last { $0["event"] as? String == "liveResponse" })
        let fields = try XCTUnwrap(last["fields"] as? [String: String])
        XCTAssertEqual(fields, ["http_status": "403", "request_id": "req_test123", "provider_code": "model_not_found"])
    }

    func testRotationKeepsRecentCompleteEventsWithinTheStorageLimit() async throws {
        let folder = try directory()
        let log = VoiceDiagnostics(directory: folder, maximumBytes: 800, lifecycleMaximumBytes: 2400)
        let session = log.begin(engine: "live")
        for _ in 0..<100 { session.record(.microphoneStarted) }
        session.record(.sessionEnded)
        let data = try await log.snapshot()
        XCTAssertLessThanOrEqual(data.count, 8000)
        let all = try rows(data)
        let manifest = try XCTUnwrap(all.last?["fields"] as? [String: String])
        XCTAssertEqual(manifest["complete"], "false")
        XCTAssertEqual(manifest["core_complete"], "false")
        XCTAssertEqual(manifest["expected_events"], "102")
        XCTAssertGreaterThan(Int(manifest["dropped_events"] ?? "0") ?? 0, 0)
        let rows = all.filter { $0["event"] as? String != "sessionManifest" }
        XCTAssertEqual(rows.last?["event"] as? String, "sessionEnded")
        XCTAssertEqual(rows.last?["sequence"] as? Int, 102)
        XCTAssertLessThan(rows.count, 102)
        XCTAssertLessThanOrEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 6)
    }

    func testThreeRecentLifecycleTracesSurviveRenderChurnAndManifestReportsMissingRenders() async throws {
        let folder = try directory()
        let log = VoiceDiagnostics(directory: folder, maximumBytes: 1000)
        var ids: [String] = []
        for _ in 0..<4 {
            let session = log.begin(engine: "live", userID: "owner")
            ids.append(session.id.uuidString)
            session.record(.brainAttemptEnded, ["reason": "context_limit", "stage": "pre_request", "request_sent": "false", "total_bytes": "96001"])
            for revision in 0..<150 { session.record(.workspaceRendered, ["render_revision": String(revision)]) }
            session.record(.sessionEnded)
        }
        _ = try await log.snapshot(userID: "owner")
        let restored = VoiceDiagnostics(directory: folder, maximumBytes: 1000)
        let data = try await restored.snapshot(userID: "owner")
        let rows = try rows(data)
        let manifests = rows.filter { $0["event"] as? String == "sessionManifest" }
        XCTAssertEqual(Set(manifests.compactMap { $0["session_id"] as? String }), Set(ids.suffix(3)))
        for manifest in manifests {
            let fields = try XCTUnwrap(manifest["fields"] as? [String: String])
            XCTAssertEqual(fields["core_complete"], "true")
            XCTAssertEqual(fields["core_available"], "3")
            XCTAssertEqual(fields["complete"], "false")
            XCTAssertEqual(fields["expected_events"], "153")
            XCTAssertGreaterThan(Int(fields["dropped_events"] ?? "0") ?? 0, 0)
        }
        XCTAssertEqual(rows.filter { $0["event"] as? String == "brainAttemptEnded" }.count, 3)
        let exported = try SessionExport.append(records: [], jobs: [], to: data, includeContent: false)
        XCTAssertTrue(String(decoding: exported, as: UTF8.self).contains("missing_ranges"))
        let other = try await restored.snapshot(userID: "other")
        XCTAssertTrue(other.isEmpty)
        XCTAssertLessThanOrEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 10)
    }

    func testUnfinishedSessionIsNeverDeclaredCompleteAfterRestart() async throws {
        let folder = try directory()
        let log = VoiceDiagnostics(directory: folder)
        let session = log.begin(engine: "live")
        session.record(.brainAttemptEnded, ["reason": "context_limit", "currentSelection_bytes": "97000",
            "body": "private email", "provider_request_id": "sk-secret"])
        _ = try await log.snapshot()
        let data = try await VoiceDiagnostics(directory: folder).snapshot()
        let fields = try XCTUnwrap(try rows(data).last?["fields"] as? [String: String])
        XCTAssertEqual(fields["ended"], "false")
        XCTAssertEqual(fields["complete"], "false")
        XCTAssertEqual(fields["dropped_events"], "0")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private email"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sk-secret"))
    }
}
