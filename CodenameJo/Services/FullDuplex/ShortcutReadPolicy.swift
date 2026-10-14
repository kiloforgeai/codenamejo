import Foundation

/// Limit message reads to the supported all-unread shortcut without widening a request.
enum ShortcutReadPolicy {
    private struct Arguments: Decodable {
        let about: String?
        let unread: Bool?
    }

    static func refusal(for argumentsJSON: String) -> String? {
        guard let arguments = try? JSONDecoder().decode(Arguments.self, from: Data(argumentsJSON.utf8)) else {
            return "The text-reading request had invalid arguments. No messages were read."
        }
        if let about = arguments.about?.trimmingCharacters(in: .whitespacesAndNewlines), !about.isEmpty {
            return "Reading texts from a specific contact is currently unavailable. No messages were read. "
                + "Jo can read everyone's unread texts from the past 24 hours, or send a text to a contact. "
                + "Do not replace this request with everyone's unread texts unless the user asks."
        }
        if arguments.unread == false {
            return "Reading already-read or all recent texts is currently unavailable. No messages were read. "
                + "Jo can read everyone's unread texts from the past 24 hours. Do not substitute that without asking."
        }
        return nil
    }
}
