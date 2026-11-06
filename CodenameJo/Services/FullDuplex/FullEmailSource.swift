import Foundation

enum FullEmailSource {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static let maximumBytes = 4_000_000

    static func completeInlinePlain(_ part: GmailAPI.FullPart?) -> Bool {
        guard let part, part.mimeType == "text/plain", (part.filename ?? "").isEmpty,
              part.parts?.isEmpty != false, let encoded = part.body?.data,
              let data = GmailAPI.decodeBase64URL(encoded), String(data: data, encoding: .utf8) != nil else { return false }
        return data.count >= (part.body?.size ?? 0)
    }

    static func read(selection: MailSelection, threadID: String, prepared: FeedEmailContent.Message?,
                     fetch: () async throws -> GmailAPI.FullMessage,
                     attachment: (String) async throws -> Data) async throws -> (text: String, cached: Bool) {
        if let prepared, prepared.id == selection.messageID, prepared.threadId == threadID,
           prepared.textComplete, prepared.fullReadComplete == true, !prepared.text.isEmpty {
            return (prepared.text, true)
        }
        let message = try await fetch()
        try Task.checkCancellation()
        guard message.id == selection.messageID, message.threadId == threadID else {
            throw Failure(message: "Google returned a different message. Select the original email and retry.")
        }
        let text = try await body(message.payload, attachment: attachment)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "This message has no readable text body. Open it in Gmail to view its attachments or images.")
        }
        guard text.utf8.count <= maximumBytes else {
            throw Failure(message: "This email is too large to load here. Open it in Gmail to read the complete message.")
        }
        return (text, false)
    }

    private static func body(_ part: GmailAPI.FullPart?, attachment: (String) async throws -> Data) async throws -> String {
        guard let part, (part.filename ?? "").isEmpty else { return "" }
        try Task.checkCancellation()
        let mime = (part.mimeType ?? "").lowercased().components(separatedBy: ";")[0]
        if let children = part.parts, !children.isEmpty {
            if mime == "multipart/alternative" {
                let plainIndex = children.firstIndex { ($0.mimeType ?? "").lowercased().hasPrefix("text/plain") }
                let plain = try await body(plainIndex.map { children[$0] }, attachment: attachment)
                if plainIndex != nil, !MailBodyText.isHTMLPlaceholder(plain) { return plain }
                for (index, child) in children.enumerated() where index != plainIndex {
                    let alternative = try await body(child, attachment: attachment)
                    if MailBodyText.preferHTML(over: plain, alternative: alternative) { return alternative }
                }
                return plain
            }
            var pieces: [String] = [], bytes = 0
            for child in children {
                let text = try await body(child, attachment: attachment)
                bytes += text.utf8.count
                guard bytes <= maximumBytes else { throw Failure(message: "This email is too large to load here. Open it in Gmail.") }
                if !text.isEmpty { pieces.append(text) }
            }
            return pieces.joined(separator: "\n\n")
        }
        guard ["text/plain", "text/html"].contains(mime) else { return "" }
        guard (part.body?.size ?? 0) <= maximumBytes else { throw Failure(message: "This email is too large to load here. Open it in Gmail.") }
        let data: Data
        if let encoded = part.body?.data, let decoded = GmailAPI.decodeBase64URL(encoded), !decoded.isEmpty {
            data = decoded
        } else if let id = part.body?.attachmentId {
            data = try await attachment(id)
        } else if part.body?.size == 0 {
            return ""
        } else {
            throw Failure(message: "Google returned an incomplete email body. Retry to load it again.")
        }
        guard data.count >= (part.body?.size ?? 0), data.count <= maximumBytes else {
            throw Failure(message: "The email body was incomplete or too large. Open it in Gmail or retry loading it.")
        }
        let contentType = part.headers?.first { $0.name.lowercased() == "content-type" }?.value.lowercased() ?? ""
        let encoding: String.Encoding = contentType.contains("charset=iso-8859-1") || contentType.contains("charset=\"iso-8859-1\"") ? .isoLatin1
            : contentType.contains("windows-1252") ? .windowsCP1252 : contentType.contains("utf-16") ? .utf16 : .utf8
        guard let source = String(data: data, encoding: encoding) else {
            throw Failure(message: "The complete email text could not be decoded. Open it in Gmail to read the message.")
        }
        return mime == "text/html" ? LocalEmailPresentation.htmlToText(source, includeLinkTargets: true) : source
    }
}
