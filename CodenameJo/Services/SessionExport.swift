import CryptoKit
import Foundation

enum SessionExport {
    static func retainedConversationIDs(in diagnostics: Data) throws -> Set<String> {
        Set(try diagnostics.split(separator: 0x0a).compactMap { raw in
            let row = try JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any]
            guard row?["event"] as? String == "sessionManifest",
                  (row?["fields"] as? [String: String])?["retention_state"] == "retained" else { return nil }
            return row?["conversation_id"] as? String
        })
    }

    static func append(records: [CommandRecord], jobs: [DispatchJob], to diagnostics: Data,
                       includeContent: Bool) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        let salt = UUID().uuidString
        func hash(_ value: String) -> String {
            SHA256.hash(data: Data((salt + value).utf8)).map { String(format: "%02x", $0) }.joined()
        }
        func scope(_ value: [String: Any]) -> [String: Any] {
            var value = value
            for (key, replacement) in [("user_id", "owner_hash"), ("profile_id", "profile_hash")] {
                if let id = value.removeValue(forKey: key) as? String { value[replacement] = hash(id) }
            }
            return value
        }
        func line(_ value: [String: Any]) throws {
            if !data.isEmpty, data.last != 0x0a { data.append(0x0a) }
            data.append(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
            data.append(0x0a)
        }
        func append(_ event: String, _ record: [String: Any]) throws {
            try line(["event": event, "schema_version": 2, "record": record])
        }
        try append("export_manifest", ["includes_content": includeContent,
            "diagnostic_conversation_ids": try retainedConversationIDs(in: diagnostics).sorted(),
            "diagnostic_retention": ["recent_conversations": VoiceDiagnostics.retainedConversations,
                "additional_active_conversations": VoiceDiagnostics.retainedConversations,
                "auxiliary_traces": VoiceDiagnostics.retainedAuxiliaryTraces,
                "traces_per_conversation": VoiceDiagnostics.retainedTracesPerConversation,
                "eviction_tombstones": VoiceDiagnostics.retainedTombstones],
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "app_build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "source_revision": Bundle.main.infoDictionary?["JoSourceRevision"] as? String ?? "unknown",
            "timing_definitions": ["issuedAt": "transcript record time, not word or playback timing",
            "durationSeconds": "exchange duration, not silent latency", "latency": "measured turn phases; missing values are unknown",
            "speechRequested": "speech scheduled", "speechStarted": "audio playback started",
            "toolResultDelivered": "result supplied to the model; not an action outcome"]])
        if includeContent {
            data.append(diagnostics)
        } else {
            for raw in diagnostics.split(separator: 0x0a) {
                let original = try JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any] ?? [:]
                var value = scope(original.filter { diagnosticKeys.contains($0.key) })
                if original["event"] as? String == "userFeedback" {
                    value["event"] = "feedback_metadata"
                    value["characters"] = (original["message"] as? String)?.count ?? 0
                }
                if let fields = value["fields"] as? [String: String] {
                    value["fields"] = VoiceDiagnostics.safeFields(fields)
                }
                if let snapshot = original["render_snapshot"] as? [String: Any] {
                    var safe = scope(snapshot.filter { diagnosticKeys.contains($0.key) })
                    safe["fields"] = VoiceDiagnostics.safeFields(snapshot["fields"] as? [String: String] ?? [:])
                    value["render_snapshot"] = safe
                }
                try line(value)
            }
        }
        for record in records {
            var value = try JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any] ?? [:]
            if !includeContent {
                value = scope(value.filter { historyKeys.contains($0.key) })
            }
            try append(includeContent ? "history_export" : "history_metadata", value)
        }
        for job in jobs {
            var value = try JSONSerialization.jsonObject(with: encoder.encode(job)) as? [String: Any] ?? [:]
            if !includeContent {
                value = scope(value.filter { jobKeys.contains($0.key) })
                if let operation = job.operation {
                    value["operation"] = ["tool": operation.tool,
                        "target_hash": job.receipts?.compactMap(\.targetHash).first
                            ?? hash(MailSelection(account: operation.account, messageID: operation.messageID).canonical)]
                }
                if let input = job.context?.input, ["voice", "button", "keyboard", "typed", "unknown"].contains(input) { value["input_source"] = input }
            }
            try append(includeContent ? "job_export" : "job_metadata", value)
        }
        return data
    }

    private static let diagnosticKeys: Set<String> = ["event", "timestamp", "elapsed_ms", "sequence", "session_sequence", "core_sequence",
        "session_id", "conversation_id", "app_version", "schema_version", "source_revision", "fields",
        "feedback_id", "fragment_turn_ids", "source", "engine", "session_state", "render_revision", "render_snapshot_status", "render_context_reason", "turn_id", "user_id", "profile_id"]
    private static let historyKeys: Set<String> = ["id", "serviceName", "serviceIcon", "status", "durationSeconds",
        "issuedAt", "profile_id", "conversationId", "toolSteps", "latency", "brainSteps", "feedbackID"]
    private static let jobKeys: Set<String> = ["id", "state", "receipts", "user_id", "conversation_id", "turn_id",
        "started_at", "completed_at", "delivered_at", "profile_id", "report_back", "foregroundContinuation"]
}
