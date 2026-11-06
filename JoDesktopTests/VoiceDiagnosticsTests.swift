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

    func testEmailReadProgressExportsWithoutSourceText() {
        let fields = VoiceDiagnostics.safeFields(["transition": "email_read_chunk_completed",
            "chunk_index": "2", "chunk_count": "8", "source_bytes": "6000", "completed_bytes": "1500",
            "cached": "false", "body": "PRIVATE SOURCE", "transcript": "PRIVATE SPEECH"])
        XCTAssertEqual(fields.count, 6)
        XCTAssertEqual(fields["completed_bytes"], "1500")
        XCTAssertNil(fields["body"])
        XCTAssertNil(fields["transcript"])
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

    func testThreeRecentLifecycleTracesAndSemanticRendersSurviveChurn() async throws {
        let folder = try directory()
        let log = VoiceDiagnostics(directory: folder, maximumBytes: 1000)
        var ids: [String] = []
        for _ in 0..<4 {
            let session = log.begin(conversationID: UUID(), engine: "live", userID: "owner")
            ids.append(session.id.uuidString)
            session.record(.brainAttemptEnded, ["reason": "context_limit", "stage": "pre_request", "request_sent": "false", "total_bytes": "96001"])
            for revision in 0..<150 { session.record(.workspaceRendered, ["render_revision": String(revision)]) }
            session.record(.sessionEnded)
        }
        _ = try await log.snapshot(userID: "owner")
        let restored = VoiceDiagnostics(directory: folder, maximumBytes: 1000)
        let data = try await restored.snapshot(userID: "owner")
        let rows = try rows(data)
        let manifests = rows.filter { $0["event"] as? String == "sessionManifest"
            && ($0["fields"] as? [String: String])?["retention_state"] == "retained" }
        XCTAssertEqual(Set(manifests.compactMap { $0["session_id"] as? String }), Set(ids.suffix(3)))
        for manifest in manifests {
            let fields = try XCTUnwrap(manifest["fields"] as? [String: String])
            XCTAssertEqual(fields["core_complete"], "true")
            XCTAssertEqual(fields["core_available"], "3")
            XCTAssertEqual(fields["complete"], "false")
            XCTAssertEqual(fields["expected_events"], "153")
            XCTAssertEqual(fields["dropped_events"], "0")
            XCTAssertEqual(fields["render_timeline_complete"], "true")
            XCTAssertGreaterThan(Int(fields["render_coalesced"] ?? "0") ?? 0, 0)
        }
        XCTAssertEqual(rows.filter { $0["event"] as? String == "brainAttemptEnded" }.count, 3)
        for id in ids.suffix(3) {
            XCTAssertTrue(rows.contains { row in
                row["session_id"] as? String == id && row["event"] as? String == "workspaceRendered"
                    && (row["fields"] as? [String: String])?["render_revision"] == "0"
            }, "Startup renders must survive later render churn")
        }
        let exported = try SessionExport.append(records: [], jobs: [], to: data, includeContent: false)
        XCTAssertTrue(String(decoding: exported, as: UTF8.self).contains("render_coalesced_ranges"))
        let other = try await restored.snapshot(userID: "other")
        XCTAssertTrue(other.isEmpty)
        XCTAssertLessThanOrEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 14)
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds = 0.0
        func set(_ value: Double) { lock.lock(); seconds = value; lock.unlock() }
        func date() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: 1_800_000_000 + seconds) }
    }

    func testFortyFiveMinuteTimelineAndEarlyMiddleLateFeedbackSurviveRestart() async throws {
        let folder = try directory(), clock = Clock()
        let log = VoiceDiagnostics(directory: folder, maximumBytes: 8192, now: { clock.date() })
        let session = log.begin(engine: "live", userID: "owner")
        let preview = log.begin(engine: "preview", userID: "other")
        let feedbackRevisions = [10, 1350, 2690]
        for second in 0..<2700 {
            clock.set(Double(second))
            let source = session.target("account-\(second / 450 % 2):message-\(second / 45)")
            session.record(.workspaceRendered, ["render_revision": String(second), "target_hash": source,
                "queue_target_hash": source, "reader_target_hash": source, "reader_state": second % 225 == 0 ? "loading" : "ready",
                "queue_revision": String(second / 45), "visible_count": "14", "job_states": "job:running",
                "actions_available": String(second % 225 != 0), "response_hash": session.target("delta-\(second)"),
                "body": "PRIVATE EMAIL"])
            if second % 30 == 0 {
                session.record(.turnTransition, ["transition": "user_input"])
                preview.record(.workspaceRendered, ["render_revision": String(second), "target_hash": preview.target("other-account")])
            }
            if feedbackRevisions.contains(second) {
                _ = try await log.saveFeedback("Feedback at \(second)", source: .button, userID: "owner",
                    context: .init(sessionID: session.id, renderRevision: second))
            }
        }
        session.record(.sessionEnded); preview.record(.sessionEnded)
        _ = try await log.snapshot(userID: "owner")
        let data = try await VoiceDiagnostics(directory: folder).snapshot(userID: "owner")
        let all = try rows(data)
        let manifest = try XCTUnwrap(all.first { $0["event"] as? String == "sessionManifest" }?["fields"] as? [String: String])
        XCTAssertEqual(manifest["core_complete"], "true")
        XCTAssertEqual(manifest["render_timeline_complete"], "true")
        XCTAssertEqual(manifest["dropped_events"], "0")
        XCTAssertEqual(manifest["render_expected"], "2700")
        XCTAssertGreaterThan(Int(manifest["render_coalesced"] ?? "0") ?? 0, 2000)
        let rendered = all.filter { $0["event"] as? String == "workspaceRendered" }
        for boundary in stride(from: 0, to: 2700, by: 45) {
            XCTAssertTrue(rendered.contains { ($0["fields"] as? [String: String])?["render_revision"] == String(boundary) })
        }
        let feedback = all.filter { $0["event"] as? String == "userFeedback" }
        XCTAssertEqual(feedback.count, 3)
        for note in feedback {
            let snapshot = try XCTUnwrap(note["render_snapshot"] as? [String: Any])
            XCTAssertEqual((snapshot["fields"] as? [String: String])?["render_revision"], (note["render_revision"] as? Int).map(String.init))
            XCTAssertEqual(note["render_snapshot_status"] as? String, "retained")
        }
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(preview.id.uuidString))
        let exported = try SessionExport.append(records: [], jobs: [], to: data, includeContent: false)
        let text = String(decoding: exported, as: UTF8.self)
        XCTAssertTrue(text.contains("render_snapshot")); XCTAssertTrue(text.contains("first_session_sequence"))
        XCTAssertFalse(text.contains("PRIVATE EMAIL")); XCTAssertFalse(text.contains("\"user_id\""))
        let bytes = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        XCTAssertLessThan(bytes, 1_500_000)
    }

    func testExhaustedRenderBudgetReportsLossWithoutSacrificingCoreOrFeedbackSnapshot() async throws {
        let log = VoiceDiagnostics(directory: try directory(), maximumBytes: 800, renderMaximumBytes: 800)
        let session = log.begin(engine: "live", userID: "owner")
        for revision in 0..<100 {
            session.record(.workspaceRendered, ["render_revision": String(revision), "queue_revision": String(revision)])
        }
        _ = try await log.saveFeedback("Inspect this state", source: .button, userID: "owner",
            context: .init(sessionID: session.id, renderRevision: 99))
        session.record(.sessionEnded)
        let all = try rows(try await log.snapshot(userID: "owner"))
        let fields = try XCTUnwrap(all.first { $0["event"] as? String == "sessionManifest" }?["fields"] as? [String: String])
        XCTAssertEqual(fields["core_complete"], "true")
        XCTAssertEqual(fields["render_timeline_complete"], "false")
        XCTAssertGreaterThan(Int(fields["dropped_events"] ?? "0") ?? 0, 0)
        XCTAssertEqual(all.last?["render_snapshot_status"] as? String, "retained")
    }

    func testFeedbackRevisionAfterRestartKeepsItsPinnedRender() async throws {
        let folder = try directory(), log = VoiceDiagnostics(directory: folder)
        let session = log.begin(engine: "live", userID: "owner")
        session.record(.workspaceRendered, ["render_revision": "1", "reader_state": "ready"])
        let context = FeedbackContext(sessionID: session.id, renderRevision: 1)
        let note = try await log.saveFeedback("First fragment", source: .voice, userID: "owner", context: context, persistence: .draft)
        let restored = VoiceDiagnostics(directory: folder)
        _ = try await restored.saveFeedback("First fragment plus clarification", source: .voice, userID: "owner", context: context,
            id: note, revision: 1)
        let all = try rows(try await restored.snapshot(userID: "owner"))
        let feedback = try XCTUnwrap(all.last { $0["event"] as? String == "userFeedback" })
        XCTAssertEqual(feedback["render_snapshot_status"] as? String, "retained")
        XCTAssertEqual(((feedback["render_snapshot"] as? [String: Any])?["fields"] as? [String: String])?["reader_state"], "ready")
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

    func testConversationsSurvivePreviewChurnAndEvictionKeepsCoverageAndPinnedFeedback() async throws {
        let folder = try directory(), clock = Clock()
        let log = VoiceDiagnostics(directory: folder, maximumBytes: 800, now: { clock.date() })
        var sessions: [VoiceDiagnostics.Session] = []
        for index in 0..<3 {
            clock.set(Double(index * 100))
            let session = log.begin(conversationID: UUID(), engine: "live", userID: "owner")
            sessions.append(session)
            session.record(.toolFinished, ["outcome": "success", "call_id": "receipt"])
            session.record(.workspaceRendered, ["render_revision": "1", "profile_hash": session.target("work"), "reader_state": "loading"])
            session.record(.workspaceRendered, ["render_revision": "2", "profile_hash": session.target("work"), "reader_state": "ready"])
            if index == 0 {
                _ = try await log.saveFeedback("Keep this context", source: .button, userID: "owner",
                    context: .init(sessionID: session.id, conversationID: session.conversationID, renderRevision: 2))
            }
            session.record(.sessionEnded)
            for preview in 0..<5 {
                clock.set(Double(index * 100 + preview + 1))
                let auxiliary = log.begin(engine: preview % 2 == 0 ? "desktop_feed" : "browser_inspection", userID: "owner")
                auxiliary.record(.feedRefresh, ["profile_hash": auxiliary.target("profile-" + String(preview))])
                auxiliary.record(.sessionEnded)
            }
        }
        let all = try rows(await log.snapshot(userID: "owner"))
        for session in sessions {
            let fields = try XCTUnwrap(all.first { $0["event"] as? String == "sessionManifest"
                && $0["session_id"] as? String == session.id.uuidString }?["fields"] as? [String: String])
            XCTAssertEqual(fields["retention_state"], "retained")
            XCTAssertEqual(fields["expected_events"], "5")
            XCTAssertEqual(fields["core_complete"], "true")
            XCTAssertEqual(fields["render_timeline_complete"], "true")
        }
        let restored = VoiceDiagnostics(directory: folder, maximumBytes: 800, now: { clock.date() })
        clock.set(400)
        let fourth = restored.begin(conversationID: UUID(), engine: "live", userID: "owner")
        fourth.record(.sessionEnded)
        let final = try rows(await restored.snapshot(userID: "owner"))
        let first = try XCTUnwrap(final.first { $0["event"] as? String == "sessionManifest"
            && $0["session_id"] as? String == sessions[0].id.uuidString }?["fields"] as? [String: String])
        XCTAssertEqual(first["retention_reason"], "conversation_limit")
        XCTAssertEqual(first["coverage_known"], "true")
        XCTAssertEqual(first["expected_events"], "5")
        XCTAssertEqual(first["core_expected"], "3")
        XCTAssertEqual(first["dropped_events"], "5")
        XCTAssertEqual(final.last?["render_snapshot_status"] as? String, "retained")
        let ids = try SessionExport.retainedConversationIDs(in: await restored.snapshot(userID: "owner"))
        XCTAssertEqual(ids, Set([sessions[1].conversationID!, sessions[2].conversationID!, fourth.conversationID!].map(\.uuidString)))
        let otherExport = try await restored.snapshot(userID: "other")
        XCTAssertTrue(otherExport.isEmpty)
    }

    func testActiveConversationIsProtectedUntilItEndsAndRestartDropsStaleLeases() async throws {
        let folder = try directory(), clock = Clock()
        let log = VoiceDiagnostics(directory: folder, maximumBytes: 800, now: { clock.date() })
        let active = log.begin(conversationID: UUID(), engine: "live", userID: "owner")
        for index in 1...4 {
            clock.set(Double(index))
            let session = log.begin(conversationID: UUID(), engine: "live", userID: "owner")
            session.record(.sessionEnded)
        }
        let current = try rows(await log.snapshot(userID: "owner"))
        XCTAssertEqual((current.first { $0["event"] as? String == "sessionManifest"
            && $0["session_id"] as? String == active.id.uuidString }?["fields"] as? [String: String])?["retention_state"], "retained")
        let restored = VoiceDiagnostics(directory: folder, now: { clock.date() })
        clock.set(10)
        let next = restored.begin(conversationID: UUID(), engine: "live", userID: "owner")
        next.record(.sessionEnded)
        let after = try rows(await restored.snapshot(userID: "owner"))
        let fields = try XCTUnwrap(after.first { $0["event"] as? String == "sessionManifest"
            && $0["session_id"] as? String == active.id.uuidString }?["fields"] as? [String: String])
        XCTAssertEqual(fields["retention_reason"], "conversation_limit")
        XCTAssertEqual(fields["ended"], "false")
        XCTAssertEqual(fields["complete"], "false")
    }

    func testReconnectAuxiliaryAndTombstoneBudgetsRemainBoundedAndUserScoped() async throws {
        let folder = try directory(), clock = Clock()
        let log = VoiceDiagnostics(directory: folder, maximumBytes: 800, now: { clock.date() })
        let conversation = UUID()
        for index in 0..<6 {
            clock.set(Double(index))
            let session = log.begin(conversationID: conversation, engine: "live", userID: "owner")
            session.record(.sessionEnded)
        }
        let late = log.begin(engine: "desktop_feed", userID: "owner")
        for index in 10..<55 {
            clock.set(Double(index))
            let session = log.begin(engine: "desktop_feed", userID: "owner")
            session.record(.sessionEnded)
        }
        // Even after its tombstone ages out, a late event may not recreate a complete trace.
        late.record(.feedRefresh)
        let data = try await log.snapshot(userID: "owner")
        let all = try rows(data)
        let retained = all.filter { $0["event"] as? String == "sessionManifest"
            && ($0["fields"] as? [String: String])?["retention_state"] == "retained" }
        XCTAssertEqual(retained.filter { $0["conversation_id"] as? String == conversation.uuidString }.count, 4)
        XCTAssertEqual(retained.filter { $0["conversation_id"] == nil }.count, 3)
        XCTAssertLessThanOrEqual(all.filter { ($0["fields"] as? [String: String])?["retention_state"] == "evicted" }.count, 32)
        XCTAssertLessThanOrEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 50)
        let other = log.begin(conversationID: UUID(), engine: "live", userID: "other")
        other.record(.sessionEnded)
        let theirs = try rows(await log.snapshot(userID: "other"))
        XCTAssertEqual(Set(theirs.compactMap { $0["session_id"] as? String }), [other.id.uuidString])
    }

    func testPostSessionFeedbackUsesKnownRenderAndRecordsUnavailableReasons() async throws {
        let folder = try directory(), log = VoiceDiagnostics(directory: folder), conversation = UUID()
        let session = log.begin(conversationID: conversation, engine: "live", userID: "owner")
        session.record(.workspaceRendered, ["render_revision": "864", "reader_state": "ready"])
        session.record(.sessionEnded)
        _ = try await log.snapshot(userID: "owner")
        let context = FeedbackContext(sessionID: session.id, conversationID: conversation, profileID: "work", renderRevision: 864)
        let at = Date()
        let recent = RecentFeedbackContext(context: context, userID: "owner", observedAt: at)
        let post = try XCTUnwrap(recent.afterSession(userID: "owner", profileID: "work", now: at.addingTimeInterval(25)))
        XCTAssertNil(recent.afterSession(userID: "other", profileID: "work", now: at))
        XCTAssertNil(recent.afterSession(userID: "owner", profileID: "personal", now: at))
        XCTAssertNil(recent.afterSession(userID: "owner", profileID: "work", now: at.addingTimeInterval(901)))
        let restored = VoiceDiagnostics(directory: folder)
        _ = try await restored.saveFeedback("Just after the session", source: .button, userID: "owner", context: post)
        _ = try await restored.saveFeedback("No known session", source: .button, userID: "owner", context: .init(renderRevision: 864))
        let notes = try rows(await restored.snapshot(userID: "owner")).filter { $0["event"] as? String == "userFeedback" }
        XCTAssertEqual(notes[0]["conversation_id"] as? String, conversation.uuidString)
        XCTAssertEqual(notes[0]["render_snapshot_status"] as? String, "retained")
        XCTAssertEqual(notes[0]["render_context_reason"] as? String, "recent_conversation_render")
        XCTAssertEqual(notes[1]["render_snapshot_status"] as? String, "unavailable")
        XCTAssertEqual(notes[1]["render_context_reason"] as? String, "no_session_context")
    }
}
