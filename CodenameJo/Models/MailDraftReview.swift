import Foundation

/// Exact outgoing content retained on this device until the user saves the reviewed revision.
struct MailDraftReview: Codable, Hashable, Sendable {
    var message: MailMIME.Outgoing
    var originalRaw: String?
    var revision = 1
    let archiveAfterSave: Bool
    let attachmentAccounts: [String]
    let membershipRevision: Int?

    var raw: String { originalRaw ?? MailMIME.plain(message) }
}
