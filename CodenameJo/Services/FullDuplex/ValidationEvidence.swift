#if DEBUG
import Foundation
import os

final class ValidationEvidence: VoiceEvidence, @unchecked Sendable {
    let runID: String?
    private let queue = DispatchQueue(label: "jo.validation.evidence", qos: .utility)
    private let logger = Logger(subsystem: "validation", category: "evidence")
    private let directory: URL?
    private var sequence = 0
    private var failures: [String] = []

    init(runID: String? = ProcessInfo.processInfo.environment["VALIDATION_RUN_ID"]) {
        self.runID = runID.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        directory = self.runID.map {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Validation/\($0)", isDirectory: true)
        }
    }

    func record(_ kind: String, _ fields: [String: Any] = [:]) {
        guard let directory, let runID else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        let time = Date().timeIntervalSince1970
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                sequence += 1
                let row: [String: Any] = ["runId": runID, "sequence": sequence, "kind": kind,
                    "uptime": uptime, "time": time, "fields": fields]
                var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                data.append(0x0A)
                let path = directory.appendingPathComponent("events.jsonl")
                if !FileManager.default.fileExists(atPath: path.path) {
                    try Data().write(to: path, options: .atomic)
                }
                let file = try FileHandle(forWritingTo: path)
                defer { try? file.close() }
                try file.seekToEnd()
                try file.write(contentsOf: data)
            } catch {
                failures.append("event_write: \(error.localizedDescription)")
                logger.error("validation evidence write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func receive(_ data: Data) {
        guard runID != nil,
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        let allowed = ["type", "delta", "start_ms", "end_ms", "client_event_id", "response_id", "delegation_id", "error"]
        record("live.inbound", event.filter { allowed.contains($0.key) })
        if type == "response.event", let nested = event["event"] as? [String: Any] {
            record("live.backend", nested.filter { ["type", "response_id", "item", "response"].contains($0.key) })
        }
    }

    func retainRecording(_ source: URL, completion: @escaping () -> Void) {
        guard let directory else { completion(); return }
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(source.lastPathComponent))
            } catch {
                failures.append("recording_copy: \(error.localizedDescription)")
                logger.error("validation recording copy failed: \(error.localizedDescription, privacy: .public)")
            }
            do {
                let manifest: [String: Any] = ["runId": runID ?? "", "recording": source.lastPathComponent,
                    "failures": failures, "complete": failures.isEmpty]
                try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent("complete.json"), options: .atomic)
            } catch {
                logger.error("validation manifest write failed: \(error.localizedDescription, privacy: .public)")
            }
            completion()
        }
    }
}
#endif
