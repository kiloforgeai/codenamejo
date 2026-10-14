import Foundation

/// A draft Gmail throttled, held as a `pending_mail_writes` row on this phone. The queue moves
/// on; the write lands later.
struct PendingDraft: Codable, Equatable, Sendable {
    let id: String
    let account: String
    let to: String
    let threadId: String?
}

// The receipt is `LocalCompose`'s sentence: it opens "Drafting." and carries clauses only the
// write knows, such as a standing rule that could not file the original.
