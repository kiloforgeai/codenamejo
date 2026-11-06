import Foundation

/// Mailbox descriptions never create a selection. Only application queue/result payloads do.
enum LiveSelectionGrounding {
    struct Selection: Equatable {
        let known: Bool
        let identity: String?
        var isEmpty: Bool { known && identity == nil }
    }

    static func selection(_ text: String) -> Selection {
        if text.isEmpty || text == "No email selected." { return .init(known: true, identity: nil) }
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return .init(known: false, identity: nil)
        }
        guard json["done"] as? Bool != true, json["interstitial"] == nil,
              let item = json["item"] as? [String: Any],
              let account = item["account"] as? String, !account.isEmpty,
              let id = item["id"] as? String, !id.isEmpty else {
            return .init(known: true, identity: nil)
        }
        let thread = item["threadId"] as? String ?? ""
        let ids = (item["messages"] as? [[String: Any]])?.compactMap { $0["id"] as? String }.sorted() ?? [id]
        return .init(known: true, identity: [account.lowercased(), id, thread] .joined(separator: "|") + "|" + ids.joined(separator: ","))
    }

    static func unsupportedIntroduction(_ text: String, state: String) -> Bool {
        guard selection(state).isEmpty else { return false }
        let patterns = [
            #"\b(?:up next|next(?: email| message| item)?|the current (?:email|message)|this (?:email|message))\s+(?:is|from|about|asks|says)\b"#,
            #"\b(?:we have|we've got|you have|you've got)\s+(?:an?\s+)?[^.!?]{0,70}\b(?:email|message|notification)\s+(?:from|about|asking|waiting)\b"#,
            #"\bthere(?:'s| is)\s+(?:an?\s+)?[^.!?]{0,70}\b(?:email|notification)\s+(?:from|about|asking|waiting)\b"#
        ]
        return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    static func emptySearch(_ output: String) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              value["nextPageToken"] == nil, value["hasMore"] as? Bool != true else { return false }
        let lists = ["messages", "results", "matches"].compactMap { value[$0] as? [Any] }
        return !lists.isEmpty && lists.allSatisfy(\.isEmpty)
    }

    static let correction = "I described an email that isn't selected. Sorry. No email is selected right now; I'll use the feed's actual selection."
    static let noSelection = "No email is selected right now. Continue the feed or select a returned result before acting."
}
