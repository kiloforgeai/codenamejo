import Foundation

struct MailSelection: Equatable, Hashable, Sendable {
    let account: String
    let messageID: String

    init(account: String, messageID: String) {
        self.account = account.lowercased()
        self.messageID = messageID
    }

    var canonical: String {
        GmailReadTools.json(["account": account.lowercased(), "message_id": messageID])
    }

    func matches(account: String, messageID: String) -> Bool {
        self.account.caseInsensitiveCompare(account) == .orderedSame && self.messageID == messageID
    }
}

struct RenderedFeedState: Equatable, Sendable {
    var profileID: String?
    var conversationID: UUID?
    var focus: MailSelection?
    var queueCurrent: MailSelection?
    var queueOrder: [String] = []
    var queueRevision = 0
    var queueScope = ""
    var response = ""
    var previousResponse = false
    var focusMode = false

    func permits(_ selection: MailSelection, profileID: String?) -> Bool {
        self.profileID == profileID && focus?.matches(account: selection.account, messageID: selection.messageID) == true
            && queueCurrent?.matches(account: selection.account, messageID: selection.messageID) == true
    }
}
