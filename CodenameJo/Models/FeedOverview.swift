import Foundation

struct FeedOverview: Hashable, Sendable {
    struct Entry: Hashable, Sendable {
        let sender: String
        let subject: String
        let reason: String?
    }

    let id: String
    let entries: [Entry]

    init?(payload: [String: Any]) {
        guard let id = payload["id"] as? String,
              let rows = payload["entries"] as? [[String: Any]] else { return nil }
        let entries = rows.compactMap { row -> Entry? in
            guard let sender = row["identity"] as? String, !sender.isEmpty,
                  let subject = row["subject"] as? String else { return nil }
            return Entry(sender: sender, subject: subject,
                         reason: (row["why"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        guard !entries.isEmpty else { return nil }
        self.id = id
        self.entries = entries
    }

    var title: String { entries.count == 1 ? "One thing that matters" : "\(entries.count) things that matter" }

    var speech: String {
        let count = ["One", "Two", "Three", "Four", "Five"][min(entries.count, 5) - 1]
        let lead = entries.count == 1 ? "One thing matters most this week: " : "\(count) things matter most this week: "
        return lead + entries.map { "\($0.sender), \($0.reason ?? $0.subject)" }.joined(separator: "; ")
            + ". Say next to begin."
    }

    var payload: [String: Any] {
        ["id": id, "entries": entries.map { entry -> [String: Any] in
            var row: [String: Any] = ["identity": entry.sender, "subject": entry.subject]
            if let reason = entry.reason { row["why"] = reason }
            return row
        }]
    }

    var step: String {
        let object: [String: Any] = ["done": false, "overview": payload, "script": speech,
            "note": "This overview is the current feed item. Say its script and stop. No email is selected yet. "
                + "When the user says next or asks to begin, call triage_next once to present the first email. "
                + "Do not archive, mark read, or advance any email while presenting this overview."]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
