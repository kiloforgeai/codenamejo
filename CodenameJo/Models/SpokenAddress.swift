import Foundation

/// Rewrites a spoken email address ("rob at kiloforge dot com") as a written one for the screen.
enum SpokenAddress {
    // A spoken "dot" is the guard: prose says "at", almost never "dot".
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}'’._%+@-])([A-Za-z0-9][A-Za-z0-9_%+-]*(?:(?:\s+dot\s+|\.)[A-Za-z0-9_%+-]+)*)(\s+at\s+|\s*@\s*)([A-Za-z0-9][A-Za-z0-9-]*(?:(?:\s+dot\s+|\.)[A-Za-z0-9][A-Za-z0-9-]*)+)"#,
        options: [.caseInsensitive])

    // "It's live at kiloforge dot com" names a site, not an address.
    private static let notALocalPart: Set<String> = [
        "a", "all", "also", "am", "an", "anyone", "are", "available", "back", "be", "been", "being",
        "down", "everyone", "free", "go", "here", "him", "her", "hosted", "in", "is", "it",
        "listed", "live", "look", "looking", "me", "meet", "more", "now", "off", "on", "online",
        "only", "open", "out", "over", "posted", "someone", "stay", "them", "there", "up", "us",
        "was", "were", "work", "working", "you",
    ]

    private static let addressCues: Set<String> = [
        "address", "bcc", "cc", "contact", "email", "emailed", "from", "reach", "to",
    ]
    // "It's launching at kiloforge dot com": these count only in a reply about an address, or opening one.
    private static let weakCues: Set<String> = ["is", "it's", "it’s"]

    static func written(_ text: String) -> String {
        guard text.range(of: "dot", options: .caseInsensitive) != nil || text.contains("@") else { return text }
        let source = text as NSString
        var replacements: [(NSRange, String)] = []
        var previousEnd: Int?
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let local = source.substring(with: match.range(at: 1))
            let separator = source.substring(with: match.range(at: 2))
            let domain = source.substring(with: match.range(at: 3))
            // A spoken "at" needs a spoken "dot" and an address cue: "sign up at kiloforge dot com" is a site.
            if !separator.contains("@") {
                let gap = previousEnd.map { source.substring(with: NSRange(location: $0, length: match.range.location - $0)) }
                let chained = gap.map(isConjunction) ?? false
                let firstLabel = joined(domain).split(separator: ".").first.map(String.init) ?? ""
                if notALocalPart.contains(local.lowercased()) || joined(domain) == domain
                    || local.caseInsensitiveCompare(firstLabel) == .orderedSame
                    || !(chained || cuesAnAddress(source.substring(to: match.range.location), local: local, in: text)) { continue }
            }
            replacements.append((match.range, joined(local) + "@" + joined(domain).lowercased()))
            previousEnd = match.range.location + match.range.length
        }
        var result = text
        for (range, address) in replacements.reversed() {
            result = (result as NSString).replacingCharacters(in: range, with: address)
        }
        return result
    }

    private static func cuesAnAddress(_ before: String, local: String, in text: String) -> Bool {
        let words = before.split(whereSeparator: \.isWhitespace)
        guard let last = words.last else { return true }
        let cue = last.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":,;?"))
        if addressCues.contains(cue) { return true }
        guard weakCues.contains(cue) else { return false }
        if text.range(of: #"\b(email|address)"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        let lower = local.lowercased()
        return words.count == 1 && !["ed", "ing", "er"].contains(where: lower.hasSuffix)
    }

    // "rob at acme dot com and maya at …": the second address follows the first.
    private static func isConjunction(_ gap: String) -> Bool {
        ["and", "or", ""].contains(gap.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces)))
    }

    private static func joined(_ part: String) -> String {
        part.replacingOccurrences(of: #"\s+dot\s+"#, with: ".", options: [.regularExpression, .caseInsensitive])
    }
}
