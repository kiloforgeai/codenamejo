import Foundation

/// One line of conversation the assistant is carrying as context.
struct MemoryTurn: Encodable, Equatable {
    let role: String    // "user" | "assistant"
    let text: String
}

/// A run of commands the user experienced as a single conversation.
struct Conversation: Identifiable, Equatable {
    let id: UUID
    /// Oldest first.
    var records: [CommandRecord]

    /// The opening question, which is what people recognise a conversation by.
    var title: String {
        records.first?.commandText ?? "Conversation"
    }

    var lastActivity: Date { records.last?.issuedAt ?? .distantPast }
    var exchangeCount: Int { records.count }

    /// The id a call can be dialled under, or nil for an untagged legacy thread. Don't use `id`:
    /// `group(_:)` falls back to the first record's own id, which nothing is filed under.
    var resumableId: UUID? { records.first?.conversationId }

    /// How long the conversation ran, first question to last answer. Zero for a single exchange.
    var duration: TimeInterval {
        guard let first = records.first?.issuedAt else { return 0 }
        return lastActivity.timeIntervalSince(first)
    }
}

extension Conversation {
    /// Gap after which silence reads as "that conversation ended".
    static let idleGap: TimeInterval = 30 * 60

    /// Group stored commands into conversations, most recent first. Records without a conversation
    /// id are split on a pause longer than `idleGap`.
    static func group(_ records: [CommandRecord], idleGap: TimeInterval = idleGap) -> [Conversation] {
        let ordered = records.sorted { $0.issuedAt < $1.issuedAt }
        var groups: [Conversation] = []

        for record in ordered {
            let previous = groups.last
            let continues: Bool
            if let id = record.conversationId {
                continues = previous?.id == id
            } else if let previous, previous.records.last?.conversationId == nil {
                // Untagged legacy record: same conversation if it followed
                // closely on another untagged one.
                continues = record.issuedAt.timeIntervalSince(previous.lastActivity) <= idleGap
            } else {
                continues = false
            }

            if continues, !groups.isEmpty {
                groups[groups.count - 1].records.append(record)
            } else {
                groups.append(Conversation(id: record.conversationId ?? record.id, records: [record]))
            }
        }
        return groups.reversed()
    }
}

extension Conversation {
    /// The conversation as shareable plain text. A failed turn is marked rather than rendered as
    /// something the assistant said.
    var transcript: String {
        let ordered = records.sorted { $0.issuedAt < $1.issuedAt }
        // A resumed conversation can span days; date the stamps only then.
        let spansDays = Set(ordered.map { Calendar.current.startOfDay(for: $0.issuedAt) }).count > 1

        var lines = [
            "Codename Jo conversation",
            (ordered.first?.issuedAt ?? lastActivity).formatted(date: .abbreviated, time: .shortened)
                + " · " + (exchangeCount == 1 ? "1 turn" : "\(exchangeCount) turns"),
        ]

        for record in ordered {
            let stamp = spansDays
                ? record.issuedAt.formatted(date: .abbreviated, time: .shortened)
                : record.issuedAt.formatted(date: .omitted, time: .shortened)
            // A cancelled or pending turn has no answer; an empty line would read as silence.
            let mark = record.status == .success ? "" : " — \(record.status.rawValue)"
            lines += [
                "",
                "[\(stamp)] You",
                record.commandText,
            ]
            // Between the question and the answer, which is where they happened.
            if let steps = record.toolSteps, !steps.isEmpty {
                lines.append("")
                lines += steps.map { step in
                    let time = step.milliseconds.map { " (\($0) ms)" } ?? ""
                    return "  · \(step.tool)\(time)"
                }
            }
            lines += [
                "",
                "[\(stamp)] Codename Jo\(mark)",
                record.responseText.isEmpty ? "(no reply)" : record.responseText,
            ]
        }
        return lines.joined(separator: "\n")
    }
}

/// Long-term conversation memory, rebuilt from `CommandStore`. Recent exchanges are carried newest
/// first within a character budget, and older turns are stamped with how long ago they happened.
enum ConversationMemory {
    /// Exchanges carried at most — roughly a long single sitting.
    static let maxExchanges = 12
    /// Total characters carried across all turns.
    static let maxCharacters = 6_000
    /// Per-reply cap. The gist is what context needs; one dumped inbox listing
    /// would otherwise eat the entire budget on its own.
    static let maxTurnCharacters = 700
    /// Turns younger than this are "now" and get no age stamp.
    static let freshWindow: TimeInterval = 5 * 60

    /// Rebuild conversation turns from stored commands, oldest first.
    static func turns(from records: [CommandRecord], now: Date = Date()) -> [MemoryTurn] {
        // A failed turn has an error string where the answer should be; leave it out.
        let answered: [CommandRecord] = records.filter { record in
            record.status == .success && !record.responseText.isEmpty
        }
        let ordered: [CommandRecord] = answered.sorted { $0.issuedAt < $1.issuedAt }
        let usable: [CommandRecord] = Array(ordered.suffix(maxExchanges))

        var turns: [MemoryTurn] = []
        var budget = maxCharacters
        // Spend the budget newest-first so what survives is what's most likely
        // to be referred to, then flip back to chronological order for the model.
        for record in usable.reversed() {
            let question = stamped(record.commandText, at: record.issuedAt, now: now)
            let answer = clipped(record.responseText)
            let cost = question.count + answer.count
            guard cost <= budget else { break }
            budget -= cost
            turns.append(MemoryTurn(role: "assistant", text: answer))
            turns.append(MemoryTurn(role: "user", text: question))
        }
        return turns.reversed()
    }

    /// How many exchanges `turns(from:)` would actually carry — for the UI,
    /// which should claim only what the model really receives.
    static func exchangeCount(from records: [CommandRecord], now: Date = Date()) -> Int {
        turns(from: records, now: now).count / 2
    }

    private static func stamped(_ text: String, at date: Date, now: Date) -> String {
        let age = now.timeIntervalSince(date)
        guard age > freshWindow else { return text }
        return "[\(ago(age))] \(text)"
    }

    private static func ago(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<3_600:   return "\(Int(seconds / 60))m ago"
        case ..<86_400:  return "\(Int(seconds / 3_600))h ago"
        default:         return "\(Int(seconds / 86_400))d ago"
        }
    }

    private static func clipped(_ text: String) -> String {
        guard text.count > maxTurnCharacters else { return text }
        return String(text.prefix(maxTurnCharacters)) + "…"
    }
}
