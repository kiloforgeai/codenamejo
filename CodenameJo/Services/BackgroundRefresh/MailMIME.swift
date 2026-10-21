import Foundation

/// The raw RFC 822 messages the phone hands Gmail.
enum MailMIME {
    /// Appended when `MailFooter.isOn`.
    static let footer = "Sent via Codename Jo 🪩 https://codenamejo.com"
    private static let htmlFooter = #"Sent via <a href="https://codenamejo.com">Codename Jo 🪩</a>"#

    /// One outgoing message, draft or send. `cc` and `bcc` are bare addresses or, for reply-all, the
    /// answered message's entries as written.
    struct Outgoing: Codable, Equatable, Sendable {
        var to: String
        var cc: [String] = []
        var bcc: [String] = []
        var subject: String
        var body: String
        var threadId: String?
        /// The Message-ID being answered, written to both `In-Reply-To` and `References`.
        var inReplyTo: String?
        var footer = false
    }

    /// Gmail supplies From, Date and Message-ID. Branded mail includes a linked HTML alternative.
    static func plain(_ message: Outgoing) -> String {
        var headers = ["To: \(message.to)"]
        if !message.cc.isEmpty { headers.append("Cc: \(message.cc.joined(separator: ", "))") }
        if !message.bcc.isEmpty { headers.append("Bcc: \(message.bcc.joined(separator: ", "))") }
        headers.append("Subject: \(encodeHeader(message.subject))")
        if !message.footer { headers.append("Content-Type: text/plain; charset=UTF-8") }
        if let inReplyTo = message.inReplyTo, !inReplyTo.isEmpty {
            headers.append("In-Reply-To: \(inReplyTo)")
            headers.append("References: \(inReplyTo)")
        }
        guard message.footer else {
            return base64url((headers + ["", message.body]).joined(separator: "\r\n"))
        }
        let boundary = "b_\(UUID().uuidString.lowercased())"
        headers += ["MIME-Version: 1.0", "Content-Type: multipart/alternative; boundary=\"\(boundary)\""]
        let parts = [("plain", "\(message.body)\n\n\(footer)"),
                     ("html", "\(plainHTML(message.body))\n<p>\(htmlFooter)</p>")]
        let body = parts.map { type, content in
            "--\(boundary)\r\nContent-Type: text/\(type); charset=UTF-8\r\n"
                + "Content-Transfer-Encoding: base64\r\n\r\n\(base64Lines(Data(content.utf8)))\r\n"
        }.joined() + "--\(boundary)--"
        return base64url((headers + ["", body]).joined(separator: "\r\n"))
    }

    // MARK: - Forwards

    /// The original message, read whole, for a forward to carry.
    struct ForwardSource: Equatable, Sendable {
        var from = ""
        var date = ""
        var subject = ""
        var to = ""
        /// Empty when the original had no Cc, and the block omits the row.
        var cc = ""
        /// The RFC 822 `Message-ID`, for `In-Reply-To` and `References` on the forward.
        var rfcMessageId = ""
        var threadId = ""
        /// The plain-text body, verbatim.
        var text = ""
        /// The original `text/html` part, untouched. Empty when there never was one.
        var html = ""
        var attachments: [Attachment] = []
    }

    struct Attachment: Equatable, Sendable {
        var filename: String
        var mimeType: String
        var size: Int
        /// Empty when the bytes came inline in `data`.
        var attachmentId: String
        var data: String? = nil
        /// Kept so an inline `cid:` image still renders in the forwarded copy.
        var contentId: String? = nil
    }

    struct Forward: Sendable {
        var to: String
        var cc: [String] = []
        /// The user's own words above the forwarded block.
        var note: String?
        var source: ForwardSource
        /// Already fetched and in the source's order: what is not here is not sent.
        var attachments: [(ref: Attachment, bytes: Data)] = []
        var footer = false
    }

    /// HTML originals and branded forwards include both alternatives; attachments use a mixed wrapper.
    /// Base64 part bodies keep MIME boundaries out of the content.
    static func forward(_ fwd: Forward, boundary: () -> String = { "b_\(UUID().uuidString.lowercased())" }) -> String {
        let src = fwd.source
        let stripped = src.subject.replacingOccurrences(of: #"^\s*((re|fwd?):\s*)+"#, with: "",
                                                        options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = "Fwd: \(stripped.isEmpty ? "(no subject)" : stripped)"
        let note = fwd.note.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let block = forwardBlock(src)

        let textBody = (note.map { "\($0)\n\n" } ?? "") + "\(block.text)\n\n\(src.text)"
            + (fwd.footer ? "\n\n\(footer)" : "")
        let htmlDoc = src.html.isEmpty && !fwd.footer ? "" : (note.map { "<p>\(escapeHTML($0))</p>\n" } ?? "")
            + "\(block.html)\n\(src.html.isEmpty ? plainHTML(src.text) : src.html)"
            + (fwd.footer ? "\n<p>\(htmlFooter)</p>" : "")

        func leaf(_ headers: [String], _ content: String) -> String { (headers + ["", content]).joined(separator: "\r\n") }
        func multipart(_ subtype: String, _ parts: [String]) -> String {
            let marker = boundary()
            return (["Content-Type: multipart/\(subtype); boundary=\"\(marker)\"", ""]
                + parts.map { "--\(marker)\r\n\($0)" } + ["--\(marker)--"]).joined(separator: "\r\n")
        }
        let textPart = leaf(["Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64"],
                            base64Lines(Data(textBody.utf8)))
        let htmlPart = htmlDoc.isEmpty ? "" : leaf(
            ["Content-Type: text/html; charset=UTF-8", "Content-Transfer-Encoding: base64"], base64Lines(Data(htmlDoc.utf8)))
        func attachmentPart(_ ref: Attachment, _ bytes: Data) -> String {
            let printable = ref.filename.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
            let name = printable
                ? ref.filename.replacingOccurrences(of: #"(["\\])"#, with: #"\\$1"#, options: .regularExpression)
                : encodeHeader(ref.filename)
            var headers = ["Content-Type: \(ref.mimeType); name=\"\(name)\"",
                           "Content-Disposition: \(ref.contentId == nil ? "attachment" : "inline"); filename=\"\(name)\"",
                           "Content-Transfer-Encoding: base64"]
            if let contentId = ref.contentId { headers.append("Content-ID: \(contentId)") }
            return leaf(headers, base64Lines(bytes))
        }
        let body = htmlPart.isEmpty ? textPart : multipart("alternative", [textPart, htmlPart])
        let message = fwd.attachments.isEmpty ? body
            : multipart("mixed", [body] + fwd.attachments.map { attachmentPart($0.ref, $0.bytes) })

        var headers = ["To: \(fwd.to)"]
        if !fwd.cc.isEmpty { headers.append("Cc: \(fwd.cc.joined(separator: ", "))") }
        headers += ["Subject: \(encodeHeader(subject))", "MIME-Version: 1.0"]
        if !src.rfcMessageId.isEmpty {
            headers += ["In-Reply-To: \(src.rfcMessageId)", "References: \(src.rfcMessageId)"]
        }
        return base64url((headers + [message]).joined(separator: "\r\n"))
    }

    /// The "---------- Forwarded message ---------" block, worded as Gmail's own.
    static func forwardBlock(_ source: ForwardSource) -> (text: String, html: String) {
        var rows = [("From", source.from), ("Date", source.date), ("Subject", source.subject), ("To", source.to)]
        if !source.cc.isEmpty { rows.append(("Cc", source.cc)) }
        let text = (["---------- Forwarded message ---------"] + rows.map { "\($0.0): \($0.1)" }).joined(separator: "\n")
        let html = "<p>---------- Forwarded message ---------<br>\n"
            + rows.map { "\($0.0): \(escapeHTML($0.1))" }.joined(separator: "<br>\n") + "</p>"
        return (text, html)
    }

    /// RFC 2045 base64, standard alphabet, a CRLF after every full 76-character line.
    static func base64Lines(_ data: Data) -> String {
        let encoded = data.base64EncodedString()
        var out = ""
        var line = encoded.startIndex
        while encoded.distance(from: line, to: encoded.endIndex) >= 76 {
            let end = encoded.index(line, offsetBy: 76)
            out += String(encoded[line..<end]) + "\r\n"
            line = end
        }
        return out + String(encoded[line...])
    }

    private static func plainHTML(_ text: String) -> String {
        "<div style=\"white-space: pre-wrap;\">\(escapeHTML(text))</div>"
    }

    /// `&` before `<`, or the escape rewrites its own output.
    static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Gmail's raw envelope: base64url with the `=` padding kept.
    static func base64url(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    /// RFC 2047 `B` encoding (standard base64, not base64url) for anything outside printable ASCII.
    static func encodeHeader(_ value: String) -> String {
        if value.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) { return value }
        return "=?UTF-8?B?\(Data(value.utf8).base64EncodedString())?="
    }
}
