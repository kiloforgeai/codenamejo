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
        case turnTransition, toolStarted, toolFinished, brainRequest, brainResponse
        case jobStarted, jobFinished, jobDeferred, jobInjected, jobSpeechStarted, jobSpeechCancelled, queueRecovery, calendarReceipt, modelAvailability, audioRouteChanged
        case workspaceRendered, presentationBound, playbackBoundary, offerTransition, resultSelected
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
    private let retainedFiles = 4
    private var sequence = 0
    private let version: String

    init(directory: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Jo", isDirectory: true), maximumBytes: Int = 512_000) {
        self.directory = directory
        self.maximumBytes = maximumBytes
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
        "turn_id", "input_turn", "delegation_id", "call_id", "job_id", "tool", "target_hash", "outcome", "duration_ms",
        "queue_revision", "transition", "input_tokens", "cached_tokens", "output_tokens", "instructions_bytes",
        "tools_bytes", "context_bytes", "input_bytes", "pending_calls", "pending_responses", "time_zone",
        "requested_start", "requested_end", "stored_start", "stored_end", "available", "provider_request_id", "provider_response_id",
        "render_revision", "queue_scope", "observation_phase", "window_id", "profile_hash", "response_hash",
        "response_role", "focus_mode", "visible_count", "queue_target_hash", "queue_order", "mismatch",
        "response_item_id", "playback_id", "selection_state", "displayed_position", "displayed_total", "job_states", "attribution"
    ]

    static func safeFields(_ fields: [String: String]) -> [String: String] {
        fields.filter { key, value in
            allowedFields.contains(key) && !value.isEmpty && value.count <= (["queue_order", "job_states"].contains(key) ? 4096 : 160)
                && (key != "queue_order" || value.range(of: "^[a-f0-9,]+$", options: .regularExpression) != nil)
                && !value.lowercased().contains("sk-") && !value.lowercased().contains("bearer")
                && value.range(of: "^[A-Za-z0-9_.:/(), +-]+$", options: .regularExpression) != nil
        }
    }

    private func record(session: Session, event: Event, fields: [String: String], elapsed: Int) {
        let timestamp = Date().timeIntervalSince1970
        let safe = Self.safeFields(fields)
        queue.async { [self] in
            sequence += 1
            var row: [String: Any] = ["timestamp": timestamp, "elapsed_ms": elapsed,
                "sequence": sequence, "session_id": session.id.uuidString,
                "event": event.rawValue, "app_version": version, "schema_version": 2,
                "source_revision": Bundle.main.infoDictionary?["JoSourceRevision"] as? String ?? "unknown", "fields": safe]
            if let userID = session.userID { row["user_id"] = userID }
            if let conversationID = session.conversationID { row["conversation_id"] = conversationID.uuidString }
            do {
                var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                let line = String(decoding: data, as: UTF8.self)
                logger.notice("\(line, privacy: .public)")
                data.append(0x0a)
                try append(data, prefix: "voice-session")
            } catch {
                logger.error("Voice diagnostic write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func path(_ index: Int, prefix: String = "voice-session") -> URL {
        directory.appendingPathComponent("\(prefix)-\(index).jsonl")
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
                      context: FeedbackContext) async throws -> UUID {
        let message = try FeedbackText.validated(message)
        guard !userID.isEmpty else { throw FeedbackError.signedOut }
        let id = UUID()
        let timestamp = Date().timeIntervalSince1970
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    var row: [String: Any] = ["event": "userFeedback", "feedback_id": id.uuidString,
                        "timestamp": timestamp, "app_version": version, "user_id": userID,
                        "source": source.rawValue, "message": message, "engine": context.engine,
                        "session_state": context.state]
                    if let value = context.sessionID { row["session_id"] = value.uuidString }
                    if let value = context.conversationID { row["conversation_id"] = value.uuidString }
                    if let value = context.profileID { row["profile_id"] = value }
                    if let value = context.renderRevision { row["render_revision"] = value }
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
                    for index in (0..<retainedFiles).reversed() where FileManager.default.fileExists(atPath: path(index).path) {
                        let file = try Data(contentsOf: path(index))
                        for line in file.split(separator: 0x0a) {
                            guard let row = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                                  row["user_id"] as? String == userID else { continue }
                            data.append(contentsOf: line)
                            data.append(0x0a)
                        }
                    }
                    if let userID, !userID.isEmpty {
                        let prefix = Self.feedbackPrefix(userID: userID)
                        for index in (0..<retainedFiles).reversed() {
                            let file = path(index, prefix: prefix)
                            if FileManager.default.fileExists(atPath: file.path) {
                                data.append(try Data(contentsOf: file))
                            }
                        }
                    }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
