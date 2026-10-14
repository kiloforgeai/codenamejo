import Foundation

/// Something the user asked to hear each morning, looked up once a local day on their own key.
struct FeedItem: Codable, Equatable, Sendable {
    var id: String
    var label: String
    var query: String
    var answer: String?
    var fetchedAt: Date?
    var attemptedAt: Date?
}

/// `feed_items`, and the morning briefing it feeds. Kept in `UserDefaults`, account-wide.
@MainActor
enum FeedItems {
    static let name = "feed_items"
    static let limit = 5
    /// Local hour from which an item is due for the day's answer.
    static let prepareHour = 5
    nonisolated static let storageKey = "feedItems"

    nonisolated static func all(defaults: UserDefaults = .standard) -> [FeedItem] {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([FeedItem].self, from: $0) } ?? []
    }

    static func save(_ items: [FeedItem], defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(items), forKey: storageKey)
    }

    /// Answers fetched today; anything older stays unsaid rather than passing for this morning's.
    nonisolated static func todaysAnswers(now: Date = Date(), calendar: Calendar = .current,
                                          defaults: UserDefaults = .standard) -> [String] {
        all(defaults: defaults).compactMap { item in
            guard let answer = item.answer, let fetched = item.fetchedAt,
                  calendar.isDate(fetched, inSameDayAs: now) else { return nil }
            return answer
        }
    }

    static func run(argumentsJSON: String, defaults: UserDefaults = .standard) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        var items = all(defaults: defaults)
        switch args["action"] as? String {
        case "add":
            let wanted = (args["items"] as? [[String: Any]] ?? []).compactMap { entry -> (String, String)? in
                let label = String((entry["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                let query = String((entry["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
                return label.isEmpty || query.isEmpty ? nil : (label, query)
            }
            guard !wanted.isEmpty else { return "NOT ADDED — add needs `items`, each with a `label` and a `query`." }
            let room = max(limit - items.count, 0)
            guard room > 0 else {
                return "NOT ADDED — their feed already has \(limit) items, the most it holds. Offer to remove one first."
            }
            let added = wanted.prefix(room).map { FeedItem(id: UUID().uuidString, label: $0.0, query: $0.1) }
            items += added
            save(items, defaults: defaults)
            // Looked up after the reply, so the next dial has today's answer without this turn waiting.
            Task { await refresh(ids: Set(added.map(\.id)), defaults: defaults) }
            let skipped = wanted.count - added.count
            return "Added to their morning feed: \(added.map(\.label).joined(separator: ", "))."
                + (skipped > 0 ? " \(skipped) more did not fit; the feed holds \(limit)." : "")
        case "remove":
            let match = String((args["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard !match.isEmpty else { return "NOT REMOVED — say which item to remove." }
            let removed = items.filter {
                $0.label.localizedCaseInsensitiveContains(match) || $0.query.localizedCaseInsensitiveContains(match)
            }
            guard !removed.isEmpty else { return "NOT REMOVED — nothing in their feed matches \"\(match)\"." }
            save(items.filter { item in !removed.contains { $0.id == item.id } }, defaults: defaults)
            return "Removed from their morning feed: \(removed.map(\.label).joined(separator: ", "))."
        default:
            return items.isEmpty ? "Their morning feed has nothing added yet."
                : "Their morning feed has: \(items.map(\.label).joined(separator: ", "))."
        }
    }

    private static var refreshing = false

    /// Looks up every item due today, one at a time; called when the app comes to the front.
    static func refreshDue(now: Date = Date(), calendar: Calendar = .current) async {
        guard calendar.component(.hour, from: now) >= prepareHour else { return }
        let due = all().filter { item in
            (item.fetchedAt.map { !calendar.isDate($0, inSameDayAs: now) } ?? true)
                && (item.attemptedAt.map { now.timeIntervalSince($0) > 3600 } ?? true)
        }
        await refresh(ids: Set(due.map(\.id)))
    }

    private static func refresh(ids: Set<String>, defaults: UserDefaults = .standard) async {
        guard !ids.isEmpty, !refreshing, OpenAIKeyService.current?.isEmpty == false else { return }
        refreshing = true
        defer { refreshing = false }
        for item in all(defaults: defaults) where ids.contains(item.id) {
            let answer = (try? await WebSearchTool.search(item.query)).flatMap(cleanAnswer)
            var items = all(defaults: defaults)
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { continue }
            items[index].attemptedAt = Date()
            if let answer {
                items[index].answer = answer
                items[index].fetchedAt = Date()
            }
            save(items, defaults: defaults)
            RealtimeLog.log("feed: \(item.label) \(answer == nil ? "not answered" : "answered")")
        }
    }

    nonisolated private static let selfTalk = #"\b(results?|sources?|context|information|snippets?)\b[^.!?]*\b(you )?(provided|given|shared|supplied)\b"#
    nonisolated private static let leadIn = #"^(based on|according to|from)\s+(the\s+)?(search\s+)?(results?|sources?|information|context)(\s+you)?(\s+(provided|given|shared|supplied))?,\s*"#
    nonisolated private static let notFound = #"^(i|we)\b[^.!?]*\b(couldn'?t|could not|can'?t|cannot|was unable to|am unable to|don'?t have|do not have)\b"#

    /// The answer worth speaking, or nil when only the search model's talk about itself is left.
    nonisolated static func cleanAnswer(_ text: String) -> String? {
        let marked = text.replacingOccurrences(of: #"(?<=[.!?])\s+"#, with: "\u{1}", options: .regularExpression)
        let kept = marked.split(separator: "\u{1}").compactMap { raw -> String? in
            var sentence = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: leadIn, with: "", options: [.regularExpression, .caseInsensitive])
            sentence = sentence.prefix(1).uppercased() + sentence.dropFirst()
            let matches = { (pattern: String) in
                sentence.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }
            return sentence.isEmpty || matches(selfTalk) || matches(notFound) ? nil : sentence
        }
        let answer = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? nil : answer
    }
}
