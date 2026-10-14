import Foundation

/// Compact the model-facing copy; queue storage and full-message retrieval keep their original data.
enum LiveCompactContext {
    static func text(_ text: String) -> String {
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
               let encoded = try? JSONSerialization.data(withJSONObject: compact(object), options: [.sortedKeys]) {
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

    private static func compact(_ value: Any) -> Any {
        if let array = value as? [Any] { return array.map(compact) }
        guard var object = value as? [String: Any] else { return value }
        if var item = object["item"] as? [String: Any], item["id"] != nil, item["account"] != nil {
            item = compactItem(item)
            if item["bodySummary"] != nil { item.removeValue(forKey: "snippet") }
            object["item"] = item
            object["contentAccess"] = "The prepared bodySummary covers the selected conversation and latest reply. "
                + "If absent or more detail is needed, retrieve the selected message IDs; summaryMessages and exchangeContext are context, not action targets. "
                + "Never use the representative ID to choose a reply in an ambiguous group."
        }
        for (key, value) in object {
            if key == "pinned_feed", let text = value as? String { object[key] = self.text(text) }
            else if key != "item" { object[key] = compact(value) }
        }
        return object
    }
}
