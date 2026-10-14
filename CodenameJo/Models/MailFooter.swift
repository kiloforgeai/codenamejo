import Foundation

/// Whether mail Jo sends ends with a "Sent via Codename Jo" line. Off by default.
/// An absent key means off, matching the broker, so the two ends agree.
enum MailFooter {
    static let storageKey = "mailFooterEnabled"

    static var isOn: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? false
    }
}
