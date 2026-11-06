import Foundation

enum ForwardRecipient {
    struct Resolution: Codable, Hashable, Sendable {
        let address: String
        let basis: String
        let sender: String
        let replyTo: String
    }

    static func resolve(_ to: String, source: MailMIME.ForwardSource, userRequest: String?) throws -> Resolution {
        let address = LocalCompose.bareAddress(to).lowercased()
        let sender = LocalCompose.bareAddress(source.from).lowercased()
        let replies = addresses(source.replyTo)
        let request = userRequest ?? ""
        let destination = NSRegularExpression.escapedPattern(for: address)
        let negative = request.range(of: #"\b(?:not|never|avoid|instead of|rather than|don.t)\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
        let explicit = !negative && request.range(of: #"\b(?:forward|send|copy)(?:\s+(?:it|this|that|the (?:email|message)))?\s+to\s+"#
            + destination + #"(?![A-Z0-9@_-]|\.[A-Z0-9])"#, options: [.regularExpression, .caseInsensitive]) != nil
        let isTransport = sender.range(of: #"^(?:no[._-]?reply|do[._-]?not[._-]?reply|notifications?|alerts?|mailer|billing)(?:[+._-][^@]*)?@"#,
            options: .regularExpression) != nil
        if !explicit && ((address == sender && (isTransport || replies.contains { $0 != sender }))
                         || (replies.contains(address) && replies.count > 1)) {
            throw GmailReadTools.Refusal(text: "NOT SENT — the source sender is \(source.from), with Reply-To: \(source.replyTo.isEmpty ? "none" : source.replyTo). "
                + "The sender display name does not establish the named person's address. Read the source/contact evidence and resolve the intended person; "
                + "ask which address if it conflicts. A prior exchange or recipient_confirmed flag cannot resolve this identity mismatch. "
                + "Only use this sender address if the user explicitly requests that address.")
        }
        return .init(address: address, basis: explicit ? "explicit_user_address" : replies.contains(address) ? "source_reply_to" : "selected_destination",
            sender: source.from, replyTo: source.replyTo)
    }

    static func addresses(_ text: String) -> [String] {
        let pattern = #"[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9.-]*[A-Z0-9])?\.[A-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return Array(Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]).lowercased() }
        })).sorted()
    }
}
