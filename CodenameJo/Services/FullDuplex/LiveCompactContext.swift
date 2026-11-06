import Foundation

/// Compact the model-facing copy; queue storage and full-message retrieval keep their original data.
enum LiveCompactContext {
    static let shortened = " [Content shortened; retrieve the source before assuming anything is absent.]"
    private static let identityKeys: Set<String> = ["id", "account", "threadId", "messageId", "message_id", "thread_id", "messageIDs", "selectedIDs", "selected_ids", "call_id", "source_call_id", "job_id", "exchangeId", "archiveGroupId", "groupKind", "status", "outcome", "state"]

    /// Shrink content leaves, never IDs or group membership. Oversized identities fail closed.
    static func bounded(_ text: String, bytes: Int, includeEmailContent: Bool = true) -> String {
        let compacted = self.text(text, includeEmailContent: includeEmailContent)
        guard LiveOpenAI.bytes(compacted) > bytes else { return compacted }
        guard let object = try? JSONSerialization.jsonObject(with: Data(compacted.utf8)) else {
            return FeedEmailContent.prefix(compacted, bytes: max(0, bytes / 6 - shortened.utf8.count)) + shortened
        }
        var smallest = compacted
        for limit in [4096, 2048, 1024, 512, 128, 0] {
            var bounded = shrink(object, stringBytes: limit)
            if var fields = bounded as? [String: Any] {
                fields["contextNotice"] = shortened.trimmingCharacters(in: .whitespaces)
                bounded = fields
            } else {
                bounded = ["value": bounded, "contextShortened": true,
                           "contextNotice": shortened.trimmingCharacters(in: .whitespaces)]
            }
            if let data = try? JSONSerialization.data(withJSONObject: bounded, options: [.sortedKeys]),
               let candidate = String(data: data, encoding: .utf8) {
                if LiveOpenAI.bytes(candidate) < LiveOpenAI.bytes(smallest) { smallest = candidate }
                if LiveOpenAI.bytes(candidate) <= bytes { return candidate }
            }
        }
        return smallest
    }

    static func selectionReference(_ text: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let item = object["item"] as? [String: Any] else {
            return bounded(text, bytes: 2_000, includeEmailContent: false)
        }
        let keys: Set<String> = ["id", "account", "threadId", "exchangeId", "groupKind", "archiveGroupId",
                                 "alreadyDone", "hasDraft", "selectedIDs", "selected_ids"]
        var selected = item.filter { keys.contains($0.key) }
        if let members = item["messages"] as? [[String: Any]] {
            selected["messages"] = members.map { $0.filter { identityKeys.contains($0.key) } }
        }
        var reference = object.filter { ["done", "interstitial", "cleanup", "onboarding", "coaching"].contains($0.key) }
        reference["item"] = selected
        reference["contextNotice"] = "Selection reference only. Read currentSelection or retrieve the source for content."
        guard let data = try? JSONSerialization.data(withJSONObject: reference, options: [.sortedKeys]) else {
            return bounded(text, bytes: 2_000, includeEmailContent: false)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func shrink(_ value: Any, stringBytes: Int, identity: Bool = false) -> Any {
        if identity { return value }
        if let text = value as? String {
            return text.utf8.count > stringBytes ? FeedEmailContent.prefix(text, bytes: stringBytes) : text
        }
        if let array = value as? [Any] { return array.map { shrink($0, stringBytes: stringBytes) } }
        guard var object = value as? [String: Any] else { return value }
        var changed = false
        for (key, child) in object {
            let next = shrink(child, stringBytes: stringBytes, identity: identityKeys.contains(key))
            if LiveOpenAI.bytes(next) != LiveOpenAI.bytes(child) { changed = true }
            object[key] = next
        }
        if changed {
            object["contextShortened"] = true
            if object["textComplete"] != nil { object["textComplete"] = false }
        }
        return object
    }

    static func text(_ text: String, includeEmailContent: Bool = true) -> String {
        var result = ""
        var cursor = text.startIndex
        while let start = text[cursor...].firstIndex(of: "{") {
            result += text[cursor..<start]
            var depth = 0
            var quoted = false
            var escaped = false
            var end: String.Index?
            for index in text[start...] .indices {
                let character = text[index]
                if quoted {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { quoted = false }
                } else if character == "\"" { quoted = true }
                else if character == "{" { depth += 1 }
                else if character == "}" {
                    depth -= 1
                    if depth == 0 { end = text.index(after: index); break }
                }
            }
            guard let end else { result += text[start...]; return result }
            let original = String(text[start..<end])
            if let data = original.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data),
               let encoded = try? JSONSerialization.data(withJSONObject: compact(object, includeEmailContent: includeEmailContent), options: [.sortedKeys]) {
                result += String(decoding: encoded, as: UTF8.self)
            } else { result += original }
            cursor = end
        }
        return result + text[cursor...]
    }

    private static func compactItem(_ item: [String: Any]) -> [String: Any] {
        var item = item
        for key in ["messages", "summaryMessages", "exchangeContext"] {
            guard let source = item[key] as? [[String: Any]],
                  source.allSatisfy({ $0["id"] is String }) else { continue }
            item[key] = source.map { member in
                member.filter { !["snippet", "body", "bodyText", "bodyHtml", "html", "plainText"].contains($0.key) }
            }
        }
        if let conversations = item["conversations"] as? [[String: Any]] {
            item["conversations"] = conversations.map(compactItem)
        }
        return item
    }

    private static func compact(_ value: Any, includeEmailContent: Bool) -> Any {
        if let array = value as? [Any] { return array.map { compact($0, includeEmailContent: includeEmailContent) } }
        guard var object = value as? [String: Any] else { return value }
        if var item = object["item"] as? [String: Any], item["id"] != nil, item["account"] != nil {
            item = compactItem(item)
            if !includeEmailContent { item.removeValue(forKey: "emailContent") }
            if item["bodySummary"] != nil { item.removeValue(forKey: "snippet") }
            object["item"] = item
            object["contentAccess"] = (item["emailContent"] == nil ? "" : FeedEmailContent.guidance) + "The prepared bodySummary covers the selected conversation and latest reply. "
                + "If absent or more detail is needed, retrieve the selected message IDs; summaryMessages and exchangeContext are context, not action targets. "
                + "Never use the representative ID to choose a reply in an ambiguous group."
        }
        for (key, value) in object {
            if key == "pinned_feed", let text = value as? String { object[key] = self.text(text, includeEmailContent: includeEmailContent) }
            else if key != "item" { object[key] = compact(value, includeEmailContent: includeEmailContent) }
        }
        return object
    }
}
