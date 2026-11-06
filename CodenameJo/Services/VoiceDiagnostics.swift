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
    }

    struct Session: Sendable {
        let id: UUID
        let conversationID: UUID?
        let userID: String?
        private let origin = Date()
        fileprivate let owner: VoiceDiagnostics

        func record(_ event: Event, _ fields: [String: String] = [:]) {
            owner.record(session: self, event: event, fields: fields,
                         elapsed: Int(Date().timeIntervalSince(origin) * 1000))
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
        "http_status", "request_id", "provider_code", "event_type", "sample_rate", "output_ports",
        "utterance_id", "characters", "voice_id", "phase", "response_status", "ice_candidates"
    ]

    static func safeFields(_ fields: [String: String]) -> [String: String] {
        fields.filter { key, value in
            allowedFields.contains(key) && !value.isEmpty && value.count <= 160
                && !value.lowercased().contains("sk-") && !value.lowercased().contains("bearer")
                && value.range(of: "^[A-Za-z0-9_.:/(), -]+$", options: .regularExpression) != nil
        }
    }

    private func record(session: Session, event: Event, fields: [String: String], elapsed: Int) {
        let timestamp = Date().timeIntervalSince1970
        let safe = Self.safeFields(fields)
        queue.async { [self] in
            sequence += 1
            var row: [String: Any] = ["timestamp": timestamp, "elapsed_ms": elapsed,
                "sequence": sequence, "session_id": session.id.uuidString,
                "event": event.rawValue, "app_version": version, "fields": safe]
            if let conversationID = session.conversationID { row["conversation_id"] = conversationID.uuidString }
            if let userID = session.userID { row["user_id"] = userID }
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
