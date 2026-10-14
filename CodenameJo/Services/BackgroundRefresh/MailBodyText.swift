import Foundation

/// A Gmail MIME tree reduced to the words the user typed.
enum MailBodyText {
    /// The best plain-text body in the tree: a `text/plain` leaf if there is one, else
    /// `text/html` with the tags taken out. Attachments and images are skipped.
    static func plainText(_ part: GmailAPI.FullPart?) -> String {
        guard let part else { return "" }
        var plain: [String] = []
        var html: [String] = []
        collect(part, plain: &plain, html: &html)
        if !plain.isEmpty { return plain.joined(separator: "\n") }
        return html.map(stripHTML).joined(separator: "\n")
    }

    private static func collect(_ part: GmailAPI.FullPart, plain: inout [String], html: inout [String]) {
        let mime = (part.mimeType ?? "").lowercased()
        if let children = part.parts, !children.isEmpty {
            for child in children { collect(child, plain: &plain, html: &html) }
            return
        }
        guard (part.filename ?? "").isEmpty, let data = part.body?.data,
              let text = decodeBase64URL(data) else { return }
        if mime.hasPrefix("text/plain") { plain.append(text) }
        else if mime.hasPrefix("text/html") { html.append(text) }
    }

    static func decodeBase64URL(_ value: String) -> String? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    static func stripHTML(_ html: String) -> String {
        var text = html
        for tag in ["br", "/p", "/div", "/li", "/tr", "/h1", "/h2", "/h3"] {
            text = text.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(
            of: "<(style|script)\\b[^>]*>[\\s\\S]*?</\\1>", with: "",
            options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text
    }
}

/// Quoted history and signature blocks, cut so a reply is only what the user wrote.
enum QuotedHistory {
    static func strip(_ body: String) -> String {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var cut = lines.count
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Gmail's attribution line, sometimes wrapped so "wrote:" lands on the next line.
            if trimmed.hasPrefix("On "), trimmed.hasSuffix("wrote:")
                || (lines.indices.contains(index + 1)
                    && lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix("wrote:")) {
                cut = index
                break
            }
            if trimmed.range(of: "^(-{2,}\\s*Original Message|_{5,}$|From: .+@)", options: .regularExpression) != nil {
                cut = index
                break
            }
            // Our own footer and the classic signature separator.
            if trimmed.hasPrefix("Sent via Codename Jo") || trimmed == "--" {
                cut = index
                break
            }
        }
        return lines[..<cut]
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
