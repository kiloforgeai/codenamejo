import CryptoKit
import Foundation
import os

/// Lifecycle logs exclude content; explicitly submitted feedback is stored separately by user.
final class VoiceDiagnostics: @unchecked Sendable {
    enum Event: String {
        case sessionStarted, sessionEnded, livePreparing, liveRequest, liveResponse, liveFailed
        case liveConnected, liveEvent, microphoneStarted, remoteAudioObserved
        case fallbackSelected, fallbackReady, fallbackFailed, audioReleased, turnStarted, turnFailed
        case speechRequested, speechStarted, speechFinished, speechCancelled, speechFailed
        case turnTransition, toolStarted, toolFinished, toolResultDelivered, brainRequest, brainResponse, brainAttemptEnded
        case jobStarted, jobFinished, jobDeferred, jobInjected, jobSpeechStarted, jobSpeechCompleted, jobSpeechCancelled, queueRecovery, calendarReceipt, modelAvailability, audioRouteChanged
        case workspaceRendered, presentationBound, playbackBoundary, offerTransition, resultSelected
        case feedRefresh
    }

    struct Session: Sendable {
        let id: UUID
        let conversationID: UUID?
        let userID: String?
        private let origin = ProcessInfo.processInfo.systemUptime
        fileprivate let owner: VoiceDiagnostics

        func record(_ event: Event, _ fields: [String: String] = [:]) {
            owner.record(session: self, event: event, fields: fields,
                         elapsed: Int((ProcessInfo.processInfo.systemUptime - origin) * 1000))
        }

        func target(_ value: String) -> String {
            SHA256.hash(data: Data((id.uuidString + value).utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    private let queue = DispatchQueue(label: "com.kiloforge.jo.voice-diagnostics", qos: .utility)
    private let logger = Logger(subsystem: "com.kiloforge.jo.desktop", category: "voice-session")
    private let directory: URL
    private let maximumBytes: Int
    private let lifecycleMaximumBytes: Int
    private let renderMaximumBytes: Int
    private let now: @Sendable () -> Date
    private struct RenderRun {
        var semantic: [String: String]
        var checkpoint: Double
        var baseRevision: String
        var first: [String: Any]?
        var last: [String: Any]?
    }
    private var renderRuns: [String: RenderRun] = [:]
    private var recentRenders: [String: [[String: Any]]] = [:]
    private struct Coverage: Codable {
        var sessionID: String
        var userID: String?
        var conversationID: String?
        var started: Double
        var ended: Double?
        var expected = 0
        var coreExpected = 0
        var firstSequence: Int
        var lastSequence: Int
        var evictionReason: String?
        var evictedAt: Double?
    }
    private var coverage: [String: Coverage] = [:]
    private let retainedFiles = 4
    // Conversation IDs group transport reconnects. Auxiliary traces have a separate budget.
    static let retainedConversations = 3
    static let retainedAuxiliaryTraces = 3
    static let retainedTracesPerConversation = 4
    static let retainedTombstones = 32
    private var sequence = 0
    private let version: String

    init(directory: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Jo", isDirectory: true), maximumBytes: Int = 512_000,
         lifecycleMaximumBytes: Int = 2_000_000, renderMaximumBytes: Int = 4_000_000,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.lifecycleMaximumBytes = lifecycleMaximumBytes
        self.renderMaximumBytes = renderMaximumBytes
        self.now = now
        version = "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")"
            + " (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"))"
    }

    func begin(conversationID: UUID? = nil, engine: String, userID: String? = nil) -> Session {
        let session = Session(id: UUID(), conversationID: conversationID, userID: userID, owner: self)
        session.record(.sessionStarted, ["engine": engine])
        return session
    }

    static func failure(_ error: Error) -> [String: String] {
        if let missing = error as? LivePrompt.MissingText {
            return ["reason": "missing_prompt", "resource": missing.name]
        }
        let error = error as NSError
        return ["error_domain": error.domain, "error_code": String(error.code)]
    }

    private static let allowedFields: Set<String> = [
        "engine", "model", "brain_model", "reason", "resource", "error_domain", "error_code",
        "http_status", "request_id", "provider_code", "event_type", "sample_rate", "output_ports", "output_channels",
        "utterance_id", "characters", "voice_id", "phase", "response_status", "ice_candidates",
        "task_revision", "input_source", "turn_id", "input_turn", "delegation_id", "call_id", "job_id", "tool", "target_hash", "outcome", "duration_ms",
        "queue_revision", "transition", "input_tokens", "cached_tokens", "output_tokens", "instructions_bytes",
        "tools_bytes", "context_bytes", "input_bytes", "pending_calls", "pending_responses", "time_zone",
        "pending_context", "backend_starting", "active_call", "active_fast_call", "input_finalized",
        "speech_pending", "button_block_reason", "function_task_active",
        "chunk_index", "chunk_count", "source_bytes", "completed_bytes", "cached",
        "browser_step", "browser_url_hash",
        "calendar_workflow_id", "calendar_reply_state", "calendar_invite_state",
            "composition_id", "composition_revision", "target_confirmed", "inspection_only", "narration_mode",
        "continuation_owed", "continuation_owner", "pending_phase",
        "action_error_visible", "action_error_hash",
        "reference_now", "range_start", "range_end", "clock_bytes", "requestClock_bytes", "calendarWindow_bytes", "calendarCoverage_bytes",
        "calendar_count", "covered_calendars", "result_age_seconds",
        "requested_start", "requested_end", "stored_start", "stored_end", "available", "provider_request_id", "provider_response_id",
        "render_revision", "queue_scope", "observation_phase", "window_id", "profile_hash", "response_hash",
        "inserted_count", "updated_count", "removed_count",
        "response_role", "focus_mode", "visible_count", "queue_target_hash", "queue_order", "mismatch",
        "response_item_id", "playback_id", "selection_state", "displayed_position", "displayed_total", "job_states", "attribution",
        "raw_target_hash", "raw_focus_state", "display_branch", "sidebar_source", "session_phase", "handoff_reason",
        "voice_target_hash", "action_anchor_hash", "conversation_hash", "source_present", "source_key_valid", "action_anchor_present", "parse_reason",
        "requested_tuple_hash", "fetched_thread_hash",
        "reader_target_hash", "reader_state", "actions_available", "clear_reason", "activity_id",
        "base_render_revision", "first_session_sequence", "last_session_sequence", "first_render_revision", "last_render_revision",
        "render_expected", "render_available", "render_coalesced", "render_coalesced_ranges", "render_timeline_complete",
        "stage", "recovery", "request_sent", "byte_limit", "total_bytes", "tool_result_bytes",
        "currentSelection_bytes", "requestSelection_bytes", "latestAssistant_bytes", "pendingQuestion_bytes",
        "questionSelection_bytes", "recordedActions_bytes", "completedJobs_bytes", "applicationUpdates_bytes",
        "current_turn_bytes", "selectionStatus_bytes", "selectionRule_bytes",
        "expected_events", "available_events", "expected_range", "available_ranges", "missing_ranges",
        "missing_range_count", "dropped_events", "core_expected", "core_available", "core_complete",
        "complete", "ended", "started_at", "ended_at", "first_sequence", "last_sequence", "coverage_known",
        "retention_state", "retention_reason", "evicted_at"
    ]

    static func safeFields(_ fields: [String: String]) -> [String: String] {
        fields.filter { key, value in
            allowedFields.contains(key) && !value.isEmpty && value.count <= (["queue_order", "job_states", "available_ranges", "missing_ranges", "render_coalesced_ranges"].contains(key) ? 4096 : 160)
                && (key != "queue_order" || value.range(of: "^[a-f0-9,]+$", options: .regularExpression) != nil)
                && !value.lowercased().contains("sk-") && !value.lowercased().contains("bearer")
                && value.range(of: "^[A-Za-z0-9_.:/(), +-]+$", options: .regularExpression) != nil
        }
    }

    private func record(session: Session, event: Event, fields: [String: String], elapsed: Int) {
        let timestamp = now().timeIntervalSince1970
        let safe = Self.safeFields(fields)
        queue.async { [self] in
            sequence += 1
            let id = session.id.uuidString
            var span = coverage[id] ?? Coverage(sessionID: id, userID: session.userID,
                conversationID: session.conversationID?.uuidString, started: timestamp,
                firstSequence: sequence, lastSequence: sequence)
            if coverage[id] == nil, event != .sessionStarted {
                span.evictionReason = "coverage_expired"; span.evictedAt = timestamp
            }
            span.expected += 1
            if event != .workspaceRendered { span.coreExpected += 1 }
            span.lastSequence = sequence
            if event == .sessionEnded { span.ended = timestamp }
            coverage[id] = span
            var row: [String: Any] = ["timestamp": timestamp, "elapsed_ms": elapsed,
                "sequence": sequence, "session_id": session.id.uuidString,
                "session_sequence": span.expected,
                "event": event.rawValue, "app_version": version, "schema_version": 2,
                "source_revision": Bundle.main.infoDictionary?["JoSourceRevision"] as? String ?? "unknown", "fields": safe]
            if let userID = session.userID { row["user_id"] = userID }
            if let conversationID = session.conversationID { row["conversation_id"] = conversationID.uuidString }
            if event != .workspaceRendered { row["core_sequence"] = span.coreExpected }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let manifest = sessionPath(span, suffix: "json")
                try JSONEncoder().encode(span).write(to: manifest, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
                var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                let line = String(decoding: data, as: UTF8.self)
                logger.notice("\(line, privacy: .public)")
                data.append(0x0a)
                if span.evictionReason != nil {
                    // Late completion of an evicted auxiliary trace must not resurrect its files.
                } else if event == .workspaceRendered {
                    var recent = recentRenders[id, default: []]
                    recent.append(row)
                    recentRenders[id] = Array(recent.suffix(512))
                    // Text deltas and observation counters do not change what is selected or
                    // actionable. Checkpoint them every ten seconds; retain all other changes.
                    let semantic = safe.filter { !["render_revision", "response_hash", "observation_phase"].contains($0.key) }
                    if var run = renderRuns[id], run.semantic == semantic, timestamp - run.checkpoint < 10 {
                        if run.first == nil { run.first = row }
                        run.last = row
                        renderRuns[id] = run
                    } else {
                        try flushRenderRun(span)
                        try appendRender(data, span: span)
                        renderRuns[id] = .init(semantic: semantic, checkpoint: timestamp, baseRevision: safe["render_revision"] ?? "unknown")
                    }
                } else {
                    try flushRenderRun(span)
                    let file = sessionPath(span, suffix: "jsonl")
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if size + data.count <= lifecycleMaximumBytes { try appendFile(data, file: file, durable: true) }
                }
                try append(data, prefix: "voice-session")
                if event == .sessionStarted || event == .sessionEnded || span.evictionReason == "coverage_expired" {
                    try pruneSessions(userID: session.userID)
                }
            } catch {
                logger.error("Voice diagnostic write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func appendRender(_ data: Data, span: Coverage) throws {
        let file = sessionPath(span, suffix: "renders.jsonl")
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size + data.count <= renderMaximumBytes { try appendFile(data, file: file, durable: true) }
    }

    private func flushRenderRun(_ span: Coverage) throws {
        guard var run = renderRuns[span.sessionID], let first = run.first, var last = run.last else { return }
        last["event"] = "renderCoalesced"
        last["fields"] = ["reason": "unchanged_semantic_state", "base_render_revision": run.baseRevision,
            "first_session_sequence": String(first["session_sequence"] as? Int ?? 0),
            "last_session_sequence": String(last["session_sequence"] as? Int ?? 0),
            "first_render_revision": (first["fields"] as? [String: String])?["render_revision"] ?? "unknown",
            "last_render_revision": (last["fields"] as? [String: String])?["render_revision"] ?? "unknown",
            "started_at": String(first["timestamp"] as? Double ?? 0),
            "ended_at": String(last["timestamp"] as? Double ?? 0)]
        var data = try JSONSerialization.data(withJSONObject: last, options: [.sortedKeys]); data.append(0x0a)
        try appendRender(data, span: span)
        run.first = nil; run.last = nil
        renderRuns[span.sessionID] = run
    }

    private func path(_ index: Int, prefix: String = "voice-session") -> URL {
        directory.appendingPathComponent("\(prefix)-\(index).jsonl")
    }

    private func sessionPrefix(_ userID: String?) -> String {
        "lifecycle-" + Self.feedbackPrefix(userID: userID ?? "anonymous") + "-"
    }

    private func sessionPath(_ span: Coverage, suffix: String) -> URL {
        directory.appendingPathComponent(sessionPrefix(span.userID) + span.sessionID + "." + suffix)
    }

    private func retainedSessions(userID: String?) throws -> [Coverage] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(sessionPrefix(userID)) && $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(Coverage.self, from: Data(contentsOf: $0)) }
            .filter { $0.userID == userID }.sorted {
                $0.started == $1.started ? $0.firstSequence > $1.firstSequence : $0.started > $1.started
            }
    }

    private func pruneSessions(userID: String?) throws {
        let spans = try retainedSessions(userID: userID)
        let live = spans.filter { $0.evictionReason == nil }
        var conversations: [String] = []
        for span in live {
            if let id = span.conversationID, !conversations.contains(id) { conversations.append(id) }
        }
        // Up to three in-process active conversations are protected in addition to the
        // recent set. Stale open manifests from a previous launch are not active leases.
        let active = Set(live.filter { coverage[$0.sessionID] != nil && $0.ended == nil }
            .compactMap(\.conversationID))
        let protected = Set(conversations.filter { active.contains($0) }.prefix(Self.retainedConversations))
        let keepConversations = Set(conversations.prefix(Self.retainedConversations)).union(protected)
        var counts: [String: Int] = [:]
        var auxiliary = 0
        for var span in live {
            let reason: String?
            if let conversation = span.conversationID {
                counts[conversation, default: 0] += 1
                reason = !keepConversations.contains(conversation) ? "conversation_limit"
                    : counts[conversation, default: 0] > Self.retainedTracesPerConversation ? "conversation_trace_limit" : nil
            } else {
                auxiliary += 1
                reason = auxiliary > Self.retainedAuxiliaryTraces ? "auxiliary_limit" : nil
            }
            guard let reason else { continue }
            span.evictionReason = reason; span.evictedAt = now().timeIntervalSince1970
            coverage[span.sessionID] = span
            try JSONEncoder().encode(span).write(to: sessionPath(span, suffix: "json"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionPath(span, suffix: "json").path)
            renderRuns.removeValue(forKey: span.sessionID)
            recentRenders.removeValue(forKey: span.sessionID)
            for suffix in ["jsonl", "renders.jsonl"] {
                let file = sessionPath(span, suffix: suffix)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
        }
        let tombstones = try retainedSessions(userID: userID).filter { $0.evictionReason != nil }
        for span in tombstones.dropFirst(Self.retainedTombstones) {
            coverage.removeValue(forKey: span.sessionID)
            try FileManager.default.removeItem(at: sessionPath(span, suffix: "json"))
        }
    }

    private static func ranges(_ numbers: [Int]) -> [String] {
        var result: [String] = []
        var start: Int?, end = 0
        for number in numbers {
            if let first = start, number != end + 1 {
                result.append(first == end ? String(first) : "\(first):\(end)")
                start = nil
            }
            if start == nil { start = number }
            end = number
        }
        if let start { result.append(start == end ? String(start) : "\(start):\(end)") }
        return result
    }

    private func manifest(_ span: Coverage, rows: [[String: Any]]) -> [String: Any] {
        let rows = rows.filter { $0["session_id"] as? String == span.sessionID }
        let observations = rows.filter { $0["event"] as? String != "renderCoalesced" }
        let present = Set(observations.compactMap { $0["session_sequence"] as? Int })
        var coalesced = Set<Int>()
        for row in rows where row["event"] as? String == "renderCoalesced" {
            let fields = row["fields"] as? [String: String] ?? [:]
            if let first = fields["first_session_sequence"].flatMap(Int.init),
               let last = fields["last_session_sequence"].flatMap(Int.init), first > 0, last >= first, last <= span.expected {
                coalesced.formUnion(first...last)
            }
        }
        let represented = present.union(coalesced)
        let core = Set(rows.compactMap { $0["core_sequence"] as? Int })
        let missing = Self.ranges((1...max(1, span.expected)).filter { !represented.contains($0) })
        let availableRanges = Self.ranges(present.sorted()).prefix(200).joined(separator: ",")
        let ended = span.ended.map { String($0) } ?? "unknown"
        var fields: [String: String] = ["expected_events": String(span.expected), "available_events": String(present.count),
            "expected_range": "1:\(span.expected)", "available_ranges": availableRanges,
            "missing_ranges": missing.prefix(200).joined(separator: ","), "missing_range_count": String(missing.count),
            "dropped_events": String(max(0, span.expected - represented.count)),
            "render_expected": String(span.expected - span.coreExpected),
            "render_available": String(observations.filter { $0["event"] as? String == "workspaceRendered" }.count),
            "render_coalesced": String(coalesced.subtracting(present).count),
            "render_coalesced_ranges": Self.ranges(coalesced.subtracting(present).sorted()).prefix(200).joined(separator: ","),
            "render_timeline_complete": String(represented.count == span.expected && span.ended != nil),
            "core_expected": String(span.coreExpected), "core_available": String(core.count),
            "core_complete": String(core.count == span.coreExpected && span.ended != nil),
            "complete": String(present.count == span.expected && span.ended != nil), "coverage_known": "true",
            "ended": String(span.ended != nil), "started_at": String(span.started), "ended_at": ended,
            "first_sequence": String(span.firstSequence), "last_sequence": String(span.lastSequence)]
        fields["retention_state"] = span.evictionReason == nil ? "retained" : "evicted"
        fields["retention_reason"] = span.evictionReason
        fields["evicted_at"] = span.evictedAt.map { String($0) }
        if span.evictionReason == "coverage_expired" {
            fields = ["coverage_known": "false", "complete": "false", "core_complete": "false",
                "available_events": String(present.count), "retention_state": "evicted",
                "retention_reason": "coverage_expired", "reason": "outside_tombstone_budget"]
        }
        var value: [String: Any] = ["event": "sessionManifest", "session_id": span.sessionID,
            "timestamp": span.started, "fields": fields]
        value["user_id"] = span.userID
        value["conversation_id"] = span.conversationID
        return value
    }

    static func protocolFields(_ event: [String: Any]) -> [String: String]? {
        guard let outer = event["type"] as? String else { return nil }
        let nested = event["event"] as? [String: Any] ?? event
        let type = nested["type"] as? String ?? outer
        guard !type.hasSuffix(".delta"), !type.contains("audio.delta") else { return nil }
        let accepted = type.hasPrefix("session.") || type.hasPrefix("response.")
            || type.hasPrefix("input_audio_buffer.") || type == "error"
        guard accepted else { return nil }
        var fields = ["event_type": type]
        fields["delegation_id"] = event["delegation_id"] as? String
        let response = nested["response"] as? [String: Any] ?? [:]
        fields["request_id"] = response["id"] as? String
        fields["response_status"] = response["status"] as? String
        let details = response["status_details"] as? [String: Any] ?? [:]
        let error = nested["error"] as? [String: Any] ?? details["error"] as? [String: Any] ?? [:]
        fields["provider_code"] = error["code"] as? String
        fields["provider_request_id"] = nested["request_id"] as? String ?? error["request_id"] as? String
        fields["provider_response_id"] = response["id"] as? String
        return safeFields(fields)
    }

    static func targetIdentity(arguments: String) -> String? {
        guard let args = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else { return nil }
        if let account = args["account"] as? String, let id = args["message_id"] as? String {
            return MailSelection(account: account, messageID: id).canonical
        }
        let target = args.filter { ["message_id", "message_ids", "thread_id", "event_id", "account", "label_id", "source_message_id", "source_account"].contains($0.key) }
        guard !target.isEmpty, let data = try? JSONSerialization.data(withJSONObject: target, options: .sortedKeys) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func feedbackPrefix(userID: String) -> String {
        "feedback-" + SHA256.hash(data: Data(userID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func append(_ data: Data, prefix: String, durable: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = path(0, prefix: prefix)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size + data.count > maximumBytes { try rotate(prefix: prefix) }
        try appendFile(data, file: file, durable: durable)
    }

    private func appendFile(_ data: Data, file: URL, durable: Bool) throws {
        if !FileManager.default.fileExists(atPath: file.path) {
            try Data().write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        if durable { try handle.synchronize() }
    }

    func saveFeedback(_ message: String, source: FeedbackSource, userID: String,
                      context: FeedbackContext, id: UUID = UUID(), revision: Int = 0,
                      persistence: FeedbackPersistence = .saved) async throws -> UUID {
        let message = try FeedbackText.validated(message)
        guard !userID.isEmpty else { throw FeedbackError.signedOut }
        let timestamp = now().timeIntervalSince1970
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    var row: [String: Any] = ["event": "userFeedback", "feedback_id": id.uuidString,
                        "timestamp": timestamp, "app_version": version, "user_id": userID,
                        "source": source.rawValue, "message": message, "engine": context.engine,
                        "session_state": context.state, "revision": revision, "feedback_state": persistence.rawValue]
                    if let value = context.sessionID { row["session_id"] = value.uuidString }
                    if let value = context.conversationID { row["conversation_id"] = value.uuidString }
                    if let value = context.profileID { row["profile_id"] = value }
                    if let value = context.renderRevision { row["render_revision"] = value }
                    row["render_snapshot_status"] = "unavailable"
                    row["render_context_reason"] = context.renderContextReason
                        ?? (context.sessionID == nil ? "no_session_context" : context.renderRevision == nil ? "no_render_revision" : "render_not_retained")
                    if let session = context.sessionID?.uuidString, let revision = context.renderRevision {
                        var snapshot = recentRenders[session]?.last {
                            $0["user_id"] as? String == userID && ($0["fields"] as? [String: String])?["render_revision"] == String(revision)
                        }
                        // A long feedback draft or a restart must not discard the snapshot
                        // already pinned by an earlier revision of this same note.
                        if snapshot == nil {
                            for index in 0..<retainedFiles {
                                guard let file = try? Data(contentsOf: path(index, prefix: Self.feedbackPrefix(userID: userID))) else { continue }
                                for line in file.split(separator: 0x0a).reversed() {
                                    guard let prior = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                                          prior["feedback_id"] as? String == id.uuidString,
                                          prior["user_id"] as? String == userID,
                                          prior["session_id"] as? String == session,
                                          prior["render_revision"] as? Int == revision,
                                          let pinned = prior["render_snapshot"] as? [String: Any] else { continue }
                                    snapshot = pinned; break
                                }
                                if snapshot != nil { break }
                            }
                        }
                        if snapshot == nil,
                           let span = try retainedSessions(userID: userID).first(where: { $0.sessionID == session }),
                           let data = try? Data(contentsOf: sessionPath(span, suffix: "renders.jsonl")) {
                            snapshot = data.split(separator: 0x0a).reversed().compactMap {
                                try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
                            }.first {
                                $0["event"] as? String == "workspaceRendered" && $0["user_id"] as? String == userID
                                    && ($0["fields"] as? [String: String])?["render_revision"] == String(revision)
                            }
                        }
                        row["render_snapshot"] = snapshot
                        row["render_snapshot_status"] = snapshot == nil ? "unavailable" : "retained"
                        if snapshot == nil { row["render_context_reason"] = "render_not_retained" }
                        else if context.renderContextReason == nil { row["render_context_reason"] = "exact_session_render" }
                    }
                    if let value = context.turnID { row["turn_id"] = value }
                    if let value = context.fragmentTurnIDs { row["fragment_turn_ids"] = value }
                    var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                    data.append(0x0a)
                    try append(data, prefix: Self.feedbackPrefix(userID: userID), durable: true)
                    logger.notice("User feedback saved: \(id.uuidString, privacy: .public)")
                    continuation.resume(returning: id)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func rotate(prefix: String) throws {
        let files = FileManager.default
        if files.fileExists(atPath: path(retainedFiles - 1, prefix: prefix).path) {
            try files.removeItem(at: path(retainedFiles - 1, prefix: prefix))
        }
        for index in stride(from: retainedFiles - 2, through: 0, by: -1) {
            if files.fileExists(atPath: path(index, prefix: prefix).path) {
                try files.moveItem(at: path(index, prefix: prefix), to: path(index + 1, prefix: prefix))
            }
        }
    }

    func snapshot(userID: String? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    var data = Data()
                    var rows: [[String: Any]] = []
                    var seen = Set<String>()
                    func collect(_ file: Data) throws {
                        for line in file.split(separator: 0x0a) {
                            guard let row = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                                  row["user_id"] as? String == userID else { continue }
                            let key = "\(row["session_id"] ?? "unknown"):\(row["sequence"] ?? 0):\(row["event"] ?? "unknown")"
                            if seen.insert(key).inserted { rows.append(row) }
                        }
                    }
                    for index in (0..<retainedFiles).reversed() where FileManager.default.fileExists(atPath: path(index).path) {
                        try collect(Data(contentsOf: path(index)))
                    }
                    let spans = try retainedSessions(userID: userID)
                    for span in spans {
                        try flushRenderRun(span)
                        for suffix in ["jsonl", "renders.jsonl"] {
                            let file = sessionPath(span, suffix: suffix)
                            if FileManager.default.fileExists(atPath: file.path) { try collect(Data(contentsOf: file)) }
                        }
                    }
                    rows.sort {
                        let a = $0["timestamp"] as? Double ?? 0, b = $1["timestamp"] as? Double ?? 0
                        return a == b ? ($0["sequence"] as? Int ?? 0) < ($1["sequence"] as? Int ?? 0) : a < b
                    }
                    let known = Set(spans.map(\.sessionID))
                    let older = Dictionary(grouping: rows.filter { !known.contains($0["session_id"] as? String ?? "") },
                        by: { $0["session_id"] as? String ?? "unknown" }).map { id, entries -> [String: Any] in
                            var row: [String: Any] = ["event": "sessionManifest", "session_id": id,
                                "fields": ["coverage_known": "false", "complete": "false", "core_complete": "false",
                                    "available_events": String(entries.count), "reason": "outside_retained_coverage"]]
                            row["user_id"] = userID
                            row["conversation_id"] = entries.first?["conversation_id"]
                            return row
                        }
                    for row in rows + spans.reversed().map({ manifest($0, rows: rows) }) + older {
                        data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
                        data.append(0x0a)
                    }
                    if let userID, !userID.isEmpty {
                        let prefix = Self.feedbackPrefix(userID: userID)
                        var notes: [String: [String: Any]] = [:]
                        for index in (0..<retainedFiles).reversed() {
                            let file = path(index, prefix: prefix)
                            if FileManager.default.fileExists(atPath: file.path) {
                                for line in try Data(contentsOf: file).split(separator: 0x0a) {
                                    guard let row = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                                          row["user_id"] as? String == userID,
                                          let id = row["feedback_id"] as? String else { continue }
                                    if (row["revision"] as? Int ?? 0) >= (notes[id]?["revision"] as? Int ?? 0) { notes[id] = row }
                                }
                            }
                        }
                        for row in notes.values.sorted(by: { ($0["timestamp"] as? Double ?? 0) < ($1["timestamp"] as? Double ?? 0) })
                            where row["feedback_state"] as? String != FeedbackPersistence.cancelled.rawValue {
                            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
                            data.append(0x0a)
                        }
                    }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
