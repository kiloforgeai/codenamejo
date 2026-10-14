import SwiftUI

/// Which appearance the app draws in: the system's, or one the user pinned. Applied once at
/// the window root; `.system` resolves to `nil`, which hands control back to the system.
enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearanceSetting"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// What `.preferredColorScheme` is handed. `nil` is not "unset" — it is the
    /// documented way to say "no preference, follow the system."
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
