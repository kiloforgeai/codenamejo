import Foundation

enum ThreadQueue {
    static let storageKey = "threadQueue"
    /// What an absent key means, here and wherever a profile's preferences are read directly.
    static let defaultValue = true

    static var isOn: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? defaultValue
    }
}
