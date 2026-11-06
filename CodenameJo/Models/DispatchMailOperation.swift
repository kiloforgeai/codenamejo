import Foundation

struct DispatchMailOperation: Codable, Hashable, Sendable {
    let tool: String
    let account: String
    let messageID: String

    static func archiveRequest(_ utterance: String, account: String, messageID: String) -> Self? {
        let words = utterance.lowercased().split(whereSeparator: { !$0.isLetter }).joined(separator: " ")
        let pattern = "^(?:please |okay |ok |you can |go ahead and )?archive(?: (?:it|this|that|this email|that email|the email|this message|that message))?(?: please)?(?: and (?:move on|go to the next(?: one| email)?|next(?: one| email)?))?$"
        guard !account.isEmpty, !messageID.isEmpty, words.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return .init(tool: "archive_message", account: account.lowercased(), messageID: messageID)
    }

    var arguments: String { GmailReadTools.json(["account": account, "message_id": messageID]) }
}
