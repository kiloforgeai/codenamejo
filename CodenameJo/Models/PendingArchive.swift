import Foundation

/// Accepted durable work, distinct from provider-confirmed Gmail effects.
struct PendingArchive: Codable, Equatable, Sendable {
    let id: String
    let account: String
    let messageId: String
    let threadId: String?
    var operation: String? = nil

    var isSpam: Bool { operation == "mark_spam" }
    var isTrash: Bool { operation == "trash_message" }
    var isMessageScoped: Bool { isSpam || isTrash }

    func matches(account: String, ids: [String], threadId: String?) -> Bool {
        self.account.caseInsensitiveCompare(account) == .orderedSame
            && (ids.contains(messageId) || (!isMessageScoped && self.threadId != nil && self.threadId == threadId))
    }
}

struct ArchiveRetryStatus: Decodable, Sendable {
    let pending: [PendingArchive]
    // Optional for compatibility with brokers that only report pending jobs.
    var succeeded: [PendingArchive]? = nil
}

enum ArchiveReceiptPolicy {
    static func receipt(succeeded: Bool, pending: PendingArchive?, live: Bool = false) -> String? {
        if pending != nil { return live ? SpokenPhrases.archived : SpokenPhrases.archiving }
        return succeeded ? SpokenPhrases.archived : nil
    }
}
