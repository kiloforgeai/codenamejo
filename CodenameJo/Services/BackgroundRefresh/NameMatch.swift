import Foundation

/// Matching a spoken name against the people in the mailbox, by sound: speech errors are
/// sound-alike errors ("Shabha" for Sabha), far apart as strings.
enum NameMatch {
    /// Titles carry no identity but match half a directory as substrings.
    private static let honorifics: Set<String> = [
        "dr", "doctor", "mr", "mrs", "ms", "miss", "prof", "professor",
        "sir", "madam", "rev", "reverend", "capt", "captain", "lord", "lady"
    ]

    /// Long and short forms of one title, so "doctor" matches a "Dr" on the row.
    private static let titleForms: [String: String] = [
        "doctor": "dr", "professor": "prof", "reverend": "rev",
        "captain": "capt", "madam": "mrs"
    ]

    /// Words a spoken name picks up on the way in.
    private static let filler: Set<String> = [
        "and", "the", "at", "from", "to", "email", "mail", "a", "an"
    ]

    /// The searchable parts of a spoken name. Honorifics and filler are dropped
    /// unless that would leave nothing to search on.
    static func tokens(of name: String) -> [String] {
        let all = name.lowercased()
            .split(whereSeparator: {
                !$0.isLetter && !$0.isNumber && $0 != "@" && $0 != "." && $0 != "+"
            })
            .map(String.init)
            .filter { !$0.isEmpty }
        let named = all.filter { !honorifics.contains($0) && !filler.contains($0) }
        return (named.isEmpty ? all : named).map { titleForms[$0] ?? $0 }
    }

    /// `raghav+tag@x.com` → `raghav@x.com`. Gmail ignores dots in the local part,
    /// so `first.last@` and `firstlast@` are one mailbox.
    static func canonicalAddress(_ email: String) -> String {
        let parts = email.lowercased().trimmingCharacters(in: .whitespaces)
            .split(separator: "@", maxSplits: 1)
        guard let rawLocal = parts.first else { return "" }
        let local = rawLocal.split(separator: "+", maxSplits: 1)[0]
            .replacingOccurrences(of: ".", with: "")
        return parts.count > 1 ? "\(local)@\(parts[1])" : local
    }

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]

    /// The word as it sounds: a primary key and an alternate softening the digraphs speech blurs
    /// ("shabha" is X against "sabha"'s S in one, equal in the other).
    static func keys(_ word: String) -> [String] {
        let primary = encode(word)
        let alternate = primary.replacingOccurrences(of: "X", with: "S")
            .replacingOccurrences(of: "0", with: "T")
        return alternate == primary ? [primary] : [primary, alternate]
    }

    private static func encode(_ word: String) -> String {
        var w = Array(word.lowercased().filter { $0.isLetter })
        guard !w.isEmpty else { return "" }
        // Silent leading pairs — Knight, Gnome, Pneumatic, Wright, Psalm.
        if w.count >= 2, ["kn", "gn", "pn", "wr", "ps"].contains(String(w.prefix(2))) {
            w.removeFirst()
        }
        if w.first == "x" { w[0] = "s" }

        var out = ""
        var i = 0
        while i < w.count {
            let c = w[i]
            let next: Character = i + 1 < w.count ? w[i + 1] : " "
            let after: Character = i + 2 < w.count ? w[i + 2] : " "
            let prev: Character = i > 0 ? w[i - 1] : " "
            if c == prev, c != "c" { i += 1; continue }

            switch c {
            case "a", "e", "i", "o", "u":
                if i == 0 { out += "A" }
            case "b": out += "P"
            case "c":
                if next == "h" { out += "X"; i += 1 }
                else if next == "i" || next == "e" || next == "y" { out += "S" }
                else { out += "K" }
            case "d":
                if next == "g" { out += "J"; i += 1 } else { out += "T" }
            case "g":
                if next == "h" { out += "K"; i += 1 }
                else if next == "n" { out += "N"; i += 1 }
                else if next == "i" || next == "e" || next == "y" { out += "J" }
                else { out += "K" }
            case "f", "v": out += "F"
            case "j": out += "J"
            case "k", "q": out += "K"
            case "l": out += "L"
            case "m", "n": out += "M"   // M and N collide readily in speech
            case "p":
                if next == "h" { out += "F"; i += 1 } else { out += "P" }
            case "r": out += "R"
            case "s":
                if next == "h" { out += "X"; i += 1 }
                else if next == "c", after == "h" { out += "X"; i += 2 }
                else { out += "S" }
            case "t":
                if next == "h" { out += "0"; i += 1 }
                else if next == "i", after == "o" || after == "a" { out += "X"; i += 1 }
                else { out += "T" }
            case "w", "y":
                if vowels.contains(next) { out.append(Character(c.uppercased())) }
            case "x": out += "KS"
            case "z": out += "S"
            case "h":
                if vowels.contains(prev), vowels.contains(next) { out += "H" }
            default: break
            }
            i += 1
        }
        return out
    }

    /// Jaro-Winkler, in `[0, 1]` — the secondary signal, tuned for typographic
    /// error where the phonetic key is tuned for sound-alikes.
    static func jaroWinkler(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        let window = max(0, max(x.count, y.count) / 2 - 1)
        var xFlags = [Bool](repeating: false, count: x.count)
        var yFlags = [Bool](repeating: false, count: y.count)
        var matches = 0

        for i in x.indices {
            // The window can start past the end of `y` when `x` is the longer
            // string, and an unclamped range traps.
            let lower = max(0, i - window)
            let upper = min(i + window + 1, y.count)
            guard lower < upper else { continue }
            for j in lower..<upper where !yFlags[j] && x[i] == y[j] {
                xFlags[i] = true
                yFlags[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }

        var transpositions = 0
        var k = 0
        for i in x.indices where xFlags[i] {
            while k < yFlags.count, !yFlags[k] { k += 1 }
            guard k < y.count else { break }
            if x[i] != y[k] { transpositions += 1 }
            k += 1
        }
        let m = Double(matches)
        let jaro = (m / Double(x.count) + m / Double(y.count)
            + (m - Double(transpositions) / 2) / m) / 3

        var prefix = 0
        while prefix < 4, prefix < x.count, prefix < y.count, x[prefix] == y[prefix] {
            prefix += 1
        }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }

    /// The strongest tier a single token reached. Not derived from the score: two phonetic hits
    /// outscore one exact hit.
    enum Tier: String { case name, soundsLike, loose }

    /// How well a candidate answers `tokens`, and which tier reached it.
    static func quality(
        name displayName: String, email: String, tokens: [String]
    ) -> (score: Double, tier: Tier) {
        guard !tokens.isEmpty else { return (0, .loose) }
        let lower = email.lowercased()
        let local = lower.split(separator: "@").first.map(String.init) ?? ""

        // An address as the query is an identity test, not a search.
        let addresses = tokens.filter { $0.contains("@") }
        if !addresses.isEmpty {
            let hit = addresses.contains { canonicalAddress($0) == canonicalAddress(lower) }
            return hit ? (2, .name) : (0, .loose)
        }

        let words = Set(Self.tokens(of: displayName) + Self.tokens(of: local))
            .flatMap { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }
        let wordKeys = Set(words.flatMap(keys).filter { !$0.isEmpty })

        var best = 0.0
        var matched = 0
        for token in tokens {
            let tokenKeys = keys(token).filter { !$0.isEmpty }
            let quality: Double
            if words.contains(token) {
                quality = 1
            } else if token.count >= 3, words.contains(where: { $0.hasPrefix(token) }) {
                quality = 0.7
            } else if words.contains(where: { word in
                // A short key needs similar lengths: interior vowels drop, so "seb" and "sabha"
                // both encode to SP.
                let wordKeys = keys(word)
                guard tokenKeys.contains(where: { wordKeys.contains($0) }) else { return false }
                return (wordKeys.first?.count ?? 0) >= 3 || abs(word.count - token.count) <= 1
            }) {
                quality = 0.6
            } else if words.contains(where: {
                abs($0.count - token.count) <= 2 && jaroWinkler(token, $0) >= 0.9
            }) {
                quality = 0.45
            } else {
                quality = 0
            }
            if quality > 0 { matched += 1 }
            best = max(best, quality)
        }
        guard matched > 0 else { return (0, .loose) }
        let tier: Tier = best >= 0.7 ? .name : best >= 0.6 ? .soundsLike : .loose
        return (best + Double(matched) / Double(tokens.count), tier)
    }
}
