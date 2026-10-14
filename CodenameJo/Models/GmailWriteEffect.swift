import Foundation

struct GmailWriteEffect: Codable, Equatable, Sendable {
    let account: String
    let scope: String
    let threadId: String?
    let messageIds: [String]
    let messageIdsComplete: Bool
    let operation: String
    var addLabelIds: [String]? = nil
    var removeLabelIds: [String]? = nil

    var added: Set<String> {
        Set(addLabelIds ?? []).union(operation == "trash" ? ["TRASH"] : [])
    }

    var removed: Set<String> {
        Set(removeLabelIds ?? []).union(operation == "trash" ? ["INBOX"] : [])
            .union(operation == "untrash" ? ["TRASH"] : [])
    }

    var removesFromInbox: Bool {
        ["delete", "batchDelete"].contains(operation) || removed.contains("INBOX")
            || !added.isDisjoint(with: ["TRASH", "SPAM"])
    }

    var isDeletion: Bool { ["delete", "batchDelete"].contains(operation) }

    static func hasFailure(in object: Any) -> Bool {
        let dictionary: [String: Any]
        if let raw = object as? String, let data = raw.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { dictionary = decoded }
        else if let decoded = object as? [String: Any] { dictionary = decoded }
        else { return false }
        if let error = dictionary["error"], !(error is NSNull) { return true }
        if dictionary["isError"] as? Bool == true || dictionary["ok"] as? Bool == false { return true }
        return ["structuredContent", "output"].contains { key in dictionary[key].map { hasFailure(in: $0) } ?? false }
    }

    static func decodeEffects(in object: Any) -> [GmailWriteEffect]? {
        let dictionary: [String: Any]
        if let raw = object as? String, let data = raw.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dictionary = decoded
        } else if let decoded = object as? [String: Any] {
            dictionary = decoded
        } else { return nil }
        if let structured = dictionary["structuredContent"], let effects = decodeEffects(in: structured) {
            return effects
        }
        if let raw = dictionary["effects"] {
            do {
                let data = try JSONSerialization.data(withJSONObject: raw)
                let effects = try JSONDecoder().decode([GmailWriteEffect].self, from: data)
                guard effects.allSatisfy({ !$0.account.isEmpty && ["message", "thread"].contains($0.scope)
                    && ($0.scope != "thread" || !($0.threadId ?? "").isEmpty) }) else {
                    RealtimeLog.log("gmail effects: invalid mailbox or scope")
                    return []
                }
                return effects
            } catch {
                RealtimeLog.log("gmail effects: invalid response — \(error)")
                return []
            }
        }
        if let output = dictionary["output"] { return decodeEffects(in: output) }
        return nil
    }
}
