import Foundation

struct EmailPreview: Equatable {
    let text: String
    let quoted: String

    init(snippet: String) {
        let decoded = LocalEmailPresentation.decodeEntities(snippet)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let parts = LocalEmailPresentation.splitQuoted(decoded)
        text = parts.own
        quoted = parts.quoted
    }

    static func gmailURL(account: String, messageID: String?) -> URL? {
        guard !account.isEmpty, let messageID, !messageID.isEmpty else { return nil }
        var url = URLComponents(string: "https://mail.google.com/mail/")
        url?.queryItems = [URLQueryItem(name: "authuser", value: account)]
        url?.fragment = "all/" + messageID
        return url?.url
    }
}
