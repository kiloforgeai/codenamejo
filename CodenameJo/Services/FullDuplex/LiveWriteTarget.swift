import Foundation

enum LiveWriteTarget {
    static let mailWrites: Set<String> = ["archive_message", "label_message", "mark_read", "mark_unread",
        "trash_message", "delete_message", "spam_message", "mark_spam", "report_spam", "star_message", "unstar_message"]

    static func requiresCurrentRequest(_ tool: String) -> Bool {
        let name = ToolNarration.canonical(tool)
        return mailWrites.contains(name) || ["dispatch", "dispatch_command", "triage_next",
            "send_email", "forward_email", "reply_email", "create_draft",
            "respond_to_calendar_event", "create_calendar_event", "update_calendar_event",
            "cancel_calendar_event"].contains(name)
    }

    static func refusal(tool: String, arguments: String, messageID: String, account: String) -> String? {
        let name = tool.hasPrefix("gmail_") ? String(tool.dropFirst(6)) : tool
        guard mailWrites.contains(name),
              let args = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else { return nil }
        let ids = (args["message_ids"] as? [String] ?? []) + [args["message_id"] as? String].compactMap { $0 }
        let named = args["account"] as? String
        guard ids.contains(where: { $0 != messageID }) || named.map({ $0.caseInsensitiveCompare(account) != .orderedSame }) == true else { return nil }
        return "Not executed: this write targets a different email or account from the user's current selection/confirmation. Use the originally confirmed message; background results do not retarget it."
    }
}
