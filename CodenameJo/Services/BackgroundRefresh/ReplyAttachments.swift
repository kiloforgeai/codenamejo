import Foundation
import FactoryKit

enum ReplyAttachments {
    struct Reference: Codable, Hashable, Sendable {
        let account: String
        let message_id: String
        let filename: String
        let attachment_id: String?
    }

    struct File: Codable, Equatable, Sendable {
        let filename: String
        let mimeType: String
        let bytes: Data
    }

    static func references(_ value: Any?) throws -> [Reference] {
        guard let value, !(value is NSNull) else { return [] }
        guard let rows = value as? [[String: Any]], rows.count <= 12,
              let data = try? JSONSerialization.data(withJSONObject: rows),
              let refs = try? JSONDecoder().decode([Reference].self, from: data),
              Set(refs.map { Reference(account: $0.account.lowercased(), message_id: $0.message_id,
                                      filename: $0.filename, attachment_id: $0.attachment_id) }).count == refs.count,
              refs.allSatisfy({ !$0.account.isEmpty && !$0.message_id.isEmpty && $0.message_id.count <= 200
                  && $0.message_id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
                  && ($0.attachment_id.map { !$0.isEmpty && $0.count <= 8192
                      && $0.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil } ?? true)
                  && !$0.filename.isEmpty && $0.filename.count <= 255
                  && $0.filename.rangeOfCharacter(from: .controlCharacters) == nil }) else {
            throw GmailReadTools.Refusal(text: "Nothing was sent. Choose up to 12 specific attachments using their original account, message ID and filename.")
        }
        return refs
    }

    static func load(_ refs: [Reference], accounts: [String],
                     read: (String, String) async throws -> GmailAPI.FullMessage,
                     attachment: (String, String, String) async throws -> Data,
                     validate: () async throws -> Void = {}) async throws -> [File] {
        var messages: [String: GmailAPI.FullMessage] = [:]
        var files: [File] = [], total = 0
        for ref in refs {
            try Task.checkCancellation()
            try await validate()
            guard let account = accounts.first(where: { $0.caseInsensitiveCompare(ref.account) == .orderedSame }) else {
                throw GmailReadTools.Refusal(text: "Nothing was sent. The attachment's source mailbox is not connected in this profile.")
            }
            let key = account.lowercased() + ":" + ref.message_id
            let message: GmailAPI.FullMessage
            if let cached = messages[key] { message = cached }
            else { message = try await read(account, ref.message_id); messages[key] = message }
            try await validate()
            guard message.id == ref.message_id else {
                throw GmailReadTools.Refusal(text: "Nothing was sent. The attachment lookup returned a different message.")
            }
            let matches = GmailReadTools.attachments(in: message.payload).filter {
                $0.filename == ref.filename && (ref.attachment_id == nil || $0.attachmentId == ref.attachment_id)
            }
            guard matches.count == 1, let file = matches.first,
                  ref.attachment_id != nil || file.data != nil,
                  file.size >= 0, file.size <= LocalForward.attachmentCap - total else {
                throw GmailReadTools.Refusal(text: "Nothing was sent. The requested attachment is missing, ambiguous, or too large. Read its metadata and choose the exact file.")
            }
            let bytes: Data
            if let data = file.data, let decoded = GmailAPI.decodeBase64URL(data) { bytes = decoded }
            else if let id = file.attachmentId { bytes = try await attachment(account, message.id, id) }
            else { throw GmailReadTools.Refusal(text: "Nothing was sent. The attachment's bytes are unavailable.") }
            try Task.checkCancellation()
            try await validate()
            guard bytes.count == file.size, total + bytes.count <= LocalForward.attachmentCap else {
                throw GmailReadTools.Refusal(text: "Nothing was sent. The attachment download was incomplete or too large.")
            }
            total += bytes.count
            files.append(.init(filename: file.filename, mimeType: file.mimeType, bytes: bytes))
        }
        return files
    }

    static func load(_ refs: [Reference]) async throws -> [File] {
        guard !refs.isEmpty else { return [] }
        let owner = await MainActor.run { Container.shared.backend().userId }
        let profile = ProfileRuntime.snapshot
        let accounts = ProfileRuntime.allowedMailAccounts(GoogleAccountStore.mailAccounts())
        return try await load(refs, accounts: accounts, read: { account, id in
            try await GmailAPI.fullMessage(token: GmailReadTools.token(account), id: id)
        }, attachment: { account, message, id in
            try await GmailAPI.attachment(token: GmailReadTools.token(account), messageId: message, attachmentId: id)
        }, validate: {
            let currentOwner = await MainActor.run { Container.shared.backend().userId }
            guard currentOwner == owner, ProfileRuntime.snapshot?.profileId == profile?.profileId,
                  ProfileRuntime.snapshot?.membershipRevision == profile?.membershipRevision,
                  ProfileRuntime.allowedMailAccounts(GoogleAccountStore.mailAccounts()) == accounts,
                  !MailHeadersOnly.withholdsBodies, ProfileRuntime.snapshot?.mailHeadersOnly != true else {
                throw GmailReadTools.Refusal(text: "Nothing was sent. The profile or attachment access changed; choose the source again.")
            }
        })
    }
}
