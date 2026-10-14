import AppIntents
import Foundation

/// Compare stable sender identities; a display name alone cannot identify a contact.
enum ShortcutSenderIdentity {
    static func matches(_ actual: IntentPerson, expected: IntentPerson) -> Bool {
        if case .contact(let expectedID) = expected.identifier,
           case .contact(let actualID) = actual.identifier,
           !expectedID.isEmpty, actualID == expectedID { return true }
        let expectedHandles = Set(([expected.handle].compactMap { $0 } + expected.aliases).compactMap(key))
        let actualHandles = ([actual.handle].compactMap { $0 } + actual.aliases).compactMap(key)
        return actualHandles.contains { expectedHandles.contains($0) }
    }

    private static func key(_ handle: IntentPerson.Handle) -> String? {
        switch handle.value {
        case .phoneNumber(let value):
            let digits = value.filter(\.isNumber)
            return digits.count >= 7 ? "phone:" + digits : nil
        case .emailAddress(let value):
            let email = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return email.isEmpty ? nil : "email:" + email
        case .applicationDefined: return nil
        @unknown default: return nil
        }
    }
}

enum ShortcutReadError: LocalizedError {
    case missingContact
    case missingIdentities
    case wrongSender

    var errorDescription: String? {
        switch self {
        case .missingContact:
            "The shortcut did not resolve the requested contact. Run Get Jo Contact before finding messages."
        case .missingIdentities:
            "The shortcut must return each message's Sender identity and Body together. Update Jo Messages."
        case .wrongSender:
            "The shortcut returned a message from another or unverifiable sender. Check its Sender filter; Jo did not read these messages."
        }
    }
}
