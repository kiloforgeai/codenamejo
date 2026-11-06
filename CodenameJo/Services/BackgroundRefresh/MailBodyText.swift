import Foundation

/// A Gmail MIME tree reduced to the words the user typed.
enum MailBodyText {
    static func isComplete(_ part: GmailAPI.FullPart?) -> Bool {
        guard let part else { return false }
        if !(part.filename ?? "").isEmpty { return true }
        if let children = part.parts, !children.isEmpty { return children.allSatisfy { isComplete($0) } }
        guard (part.mimeType ?? "").lowercased().hasPrefix("text/") else { return true }
        guard let encoded = part.body?.data, let data = GmailAPI.decodeBase64URL(encoded) else { return false }
        return part.body?.size.map { data.count >= $0 } ?? true
    }

    /// Prefer real plain text; replace empty bodies and HTML notices with inert HTML text.
    static func plainText(_ part: GmailAPI.FullPart?) -> String {
        guard let part else { return "" }
        var plain: [String] = []
        var html: [String] = []
        collect(part, plain: &plain, html: &html)
        let text = plain.joined(separator: "\n")
        let alternative = html.map(stripHTML).joined(separator: "\n")
        return preferHTML(over: text, alternative: alternative) ? alternative : text
    }

    static func preferHTML(over plain: String, alternative: String) -> Bool {
        !alternative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isHTMLPlaceholder(plain)
    }

    static func isHTMLPlaceholder(_ plain: String) -> Bool {
        let text = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        guard text.count <= 1_500 else { return false }
        let notice = #"^(?:your (?:e-?mail|mail) (?:software|client|program|application) (?:can(?:not|'t|’t)|does(?: not|n't|n’t)) (?:display|support|read|render) (?:this |the )?html|this (?:e-?mail|message) (?:is|was) (?:sent )?(?:in|as) html)\b"#
        if text.range(of: notice, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        let withoutURLs = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: [.regularExpression, .caseInsensitive])
        return withoutURLs.split(whereSeparator: \.isWhitespace).count <= 25
            && text.range(of: #"^(?:to )?(?:view|read) (?:this|the) (?:e-?mail|message)(?: online)?(?:,? please)? (?:in (?:your|a) (?:web )?browser|click|visit)\b"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func collect(_ part: GmailAPI.FullPart, plain: inout [String], html: inout [String]) {
        guard (part.filename ?? "").isEmpty else { return }
        let mime = (part.mimeType ?? "").lowercased()
        if let children = part.parts, !children.isEmpty {
            for child in children { collect(child, plain: &plain, html: &html) }
            return
        }
        guard let data = part.body?.data,
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
        LocalEmailPresentation.htmlToText(html)
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
