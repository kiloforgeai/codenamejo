import Foundation

/// Whether this account is restricted to message headers. This is the switch; `GmailAPI` and
/// `auth:lib/gmail.ts` enforce it. Absent reads as off.
enum MailHeadersOnly {
    static let storageKey = "mailHeadersOnly"

    /// The stored setting. Absent reads as off — see the type comment.
    static var isOn: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? false
    }

    /// Whether a body (or a snippet) may be fetched right now; the predicate every fetch site
    /// reads.
    static var withholdsBodies: Bool { isOn }

    /// The door for the privacy sheet's toggle and anything else holding an answer to write.
    static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: storageKey)
    }

    /// A snippet as the model may see it. Applied at hand-off rather than storage, because
    /// `MailStore` keeps snippets cached before the switch was turned on.
    static func snippet(_ value: String?) -> String {
        withholdsBodies ? "" : (value ?? "")
    }
}
