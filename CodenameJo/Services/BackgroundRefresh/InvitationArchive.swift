import Foundation

enum InvitationArchive {
    static func uid(in text: String) -> String? {
        let unfolded = text.replacingOccurrences(of: "\r\n ", with: "").replacingOccurrences(of: "\r\n\t", with: "")
        return unfolded.components(separatedBy: .newlines).first { $0.uppercased().hasPrefix("UID:") }
            .map { String($0.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func calendarParts(_ part: GmailAPI.FullPart) -> [GmailAPI.FullPart] {
        if part.mimeType?.lowercased() == "text/calendar" || part.filename?.lowercased().hasSuffix(".ics") == true { return [part] }
        return (part.parts ?? []).flatMap(calendarParts)
    }

    static func finish(_ receipt: FullDuplexBroker.ToolResult, args: [String: Any], event: [String: Any],
                       account: String) async -> FullDuplexBroker.ToolResult {
        guard receipt.ok == true, !receipt.deferred, args["response"] as? String == "accepted",
              args["keep_in_inbox"] as? Bool != true,
              let message = args["source_message_id"] as? String, !message.isEmpty,
              let source = args["source_account"] as? String, !source.isEmpty else { return receipt }
        do {
            guard source.caseInsensitiveCompare(account) == .orderedSame,
                  let eventUID = event["iCalUID"] as? String, !eventUID.isEmpty else {
                return .init(text: receipt.text + " The source email was kept because its invitation identity could not be verified.", ok: false)
            }
            _ = try GmailReadTools.targets(["account": source])
            let token = try await GmailReadTools.token(source)
            let mail = try await GmailAPI.fullMessage(token: token, id: message)
            var matched = false
            for part in mail.payload.map(calendarParts) ?? [] {
                let data: Data
                if let inline = part.body?.data { data = GmailAPI.decodeBase64URL(inline) ?? Data() }
                else if let attachment = part.body?.attachmentId {
                    data = try await GmailAPI.attachment(token: token, messageId: message, attachmentId: attachment)
                } else { continue }
                if uid(in: String(decoding: data, as: UTF8.self)) == eventUID { matched = true; break }
            }
            guard matched else {
                return .init(text: receipt.text + " The email was kept: its invitation did not match the accepted event.", ok: false)
            }
            if mail.labelIds?.contains("INBOX") == false {
                return .init(text: receipt.text + " The invitation email is already archived.", ok: true)
            }
            try Task.checkCancellation()
            let effects = GmailManageTools.Effects()
            _ = try await GmailManageTools.modify(token, account: source, id: message,
                add: [], remove: ["INBOX", "UNREAD"], effects)
            return .init(text: receipt.text + " Archived the invitation email.", ok: true, effects: effects.list)
        } catch {
            return .init(text: receipt.text + " The event is accepted; the source email remains unconfirmed. Retry only checking/archiving the email. " + error.localizedDescription, ok: false)
        }
    }
}
