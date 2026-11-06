import Foundation

/// A local presentation preference, independent of microphone permission or mute.
enum WorkSessionMode: String, CaseIterable, Identifiable {
    case atComputer = "at_computer"
    case away
    static let storageKey = "workSessionNarrationMode"
    var id: String { rawValue }
    var label: String { self == .atComputer ? "At computer" : "Away" }
    var automaticNarration: Bool { self == .away }
    static func stored(in defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .away
    }
    static var current: Self {
        #if targetEnvironment(macCatalyst)
        stored(in: .standard)
        #else
        .away
        #endif
    }
}
