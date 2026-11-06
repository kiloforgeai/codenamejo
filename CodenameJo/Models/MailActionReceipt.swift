import CryptoKit
import Foundation

struct MailActionReceipt: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case send, draft, forward, draftForward
        var isDraft: Bool { self == .draft || self == .draftForward }
        var isForward: Bool { self == .forward || self == .draftForward }
    }
    enum State: String, Codable, Sendable {
        case review, discarded, pending, queued, sent, draft, failed, unknown
        var label: String {
            switch self {
            case .review: return "Review draft"
            case .discarded: return "Draft discarded"
            case .pending, .queued: return "Pending"
            case .sent: return "Sent"
            case .draft: return "Draft saved"
            case .failed: return "Failed"
            case .unknown: return "Outcome unknown"
            }
        }
    }
    struct Attachment: Codable, Hashable, Sendable {
        let filename: String
        let mimeType: String
        let size: Int
        let sha256: String
    }
    let kind: Kind
    var state: State = .pending
    let account: String
    let to: String
    let cc: [String]
    let bcc: [String]
    var subject: String
    var body: String
    let threadID: String?
    let replyMessageID: String?
    let inReplyTo: String?
    let attachments: [Attachment]
    let parentJobID: UUID?
    let requestKey: String?
    var providerID: String?
    var providerMessageID: String?
    var providerThreadID: String?
    var forwardResolution: ForwardRecipient.Resolution?
    var forwardNote: String?
    var forwardHTML: String?
    var omittedAttachments: [OmittedAttachment]?
    var archiveState: String?
    /// A typed local preflight refusal is safe to resume; a failed/unknown provider write is not.
    var replyPreflight: Bool?
    var requestedReplySource: DispatchJob.MailOrigin?

    struct OmittedAttachment: Codable, Hashable, Sendable {
        let filename: String
        let mimeType: String
        let size: Int
        let reason: String
    }

    init(kind: Kind, account: String, message: MailMIME.Outgoing, replyMessageID: String?,
         parentJobID: UUID? = nil, requestKey: String? = nil) {
        self.kind = kind; self.account = account; to = message.to; cc = message.cc; bcc = message.bcc
        subject = message.subject; body = message.body + (message.footer ? "\n\n" + MailMIME.footer : "")
        threadID = message.threadId; self.replyMessageID = replyMessageID; inReplyTo = message.inReplyTo
        attachments = (message.attachments ?? []).map { .init(filename: $0.filename, mimeType: $0.mimeType,
            size: $0.bytes.count, sha256: SHA256.hash(data: $0.bytes).map { String(format: "%02x", $0) }.joined()) }
        self.parentJobID = parentJobID; self.requestKey = requestKey
    }

    var confirmed: Bool { state == .sent || state == .draft }
    var tool: String { kind.isForward ? "forward_email" : kind.isDraft ? "create_draft" : "send_email" }
    var statusLabel: String {
        if kind.isForward && state == .sent { return "Forwarded" }
        if kind.isForward && state == .draft { return "Draft forward saved" }
        return state.label
    }
    var title: String {
        if kind.isForward { return statusLabel + " · " + to }
        if state == .sent { return (threadID == nil ? "Sent to " : "Replied to ") + to }
        return state.label + " · " + to
    }
    var providerURL: URL? { EmailPreview.gmailURL(account: account, messageID: providerMessageID) }

    static func failureState(_ error: Error, attempted: Bool) -> State {
        guard attempted else { return .failed }
        switch error {
        case GmailAPI.Failure.throttled, GmailAPI.Failure.unauthorized: return .failed
        case GmailAPI.Failure.http(let status) where (400..<500).contains(status) && status != 408: return .failed
        default: return .unknown
        }
    }
}
