import SwiftUI

/// Visual constants. Colors live in `Assets.xcassets` with Light and Dark variants; this enum is
/// the typed accessor plus code-only tokens.
enum Theme {
    // MARK: - Background surfaces
    /// Primary background — near-white (light) / obsidian near-black (dark). In dark mode the
    /// only color is state (recording red, conversing gold, success green).
    static let background = Color("ThemeBackground")
    /// Elevated surface (cards, sheets)
    static let surface = Color("ThemeSurface")
    /// Secondary surface (input fields, inactive rows)
    static let surfaceSecondary = Color("ThemeSurfaceSecondary")
    /// Dividers and borders
    static let border = Color("ThemeBorder")

    // MARK: - Brand accent
    /// Sole accent — Amethyst (light) / quicksilver (dark). Pair anything drawn on an accent fill
    /// with `onAccent`: `.white` vanishes on quicksilver.
    static let accent = Color("ThemeAccent")
    /// Text and glyphs on an accent-filled control — white (light) / near-black
    /// (dark, where the accent itself is near-white).
    static let onAccent = Color("ThemeOnAccent")
    /// Amethyst — mid-purple for secondary interactive elements (constant, reads on both)
    static let amethyst = Color(red: 0.443, green: 0.298, blue: 0.714)

    // MARK: - Text (resolve per appearance)
    /// Primary text — near-black (light) / near-white (dark)
    static let textPrimary = Color("ThemeTextPrimary")
    /// Secondary text
    static let textSecondary = Color("ThemeTextSecondary")
    /// Tertiary text
    static let textTertiary = Color("ThemeTextTertiary")

    // MARK: - Semantic (constant across appearances)
    static let success = Color(red: 0.30, green: 0.70, blue: 0.48)
    /// A switched-on Toggle. Green in both appearances, because the dark accent is
    /// near-white and an on switch read the same as a blank one.
    static let toggleOn = success
    static let warning = Color(red: 0.90, green: 0.62, blue: 0.15)
    static let error = Color(red: 0.90, green: 0.28, blue: 0.32)
    /// The session's working color: open mic, connecting, thinking. `JoLiveActivity`'s
    /// `VoicePalette` mirrors it by hand, since the extension can't read the catalog.
    static let conversing = Color("ThemeConversing")

    // MARK: - Gradients
    /// Hero card fill — pale lavender wash (light) / deep purple (dark).
    /// On-card text uses `textPrimary`/`textSecondary`, so both stay legible.
    static let heroGradient = LinearGradient(
        colors: [Color("ThemeHeroTop"), Color("ThemeHeroBottom")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Corner radii (Superhuman: only 8 and 16)
    static let radiusLarge: CGFloat = 16

    // MARK: - Service color mapping
    static func serviceColor(for name: String) -> Color {
        switch name {
        case "Gmail": return Color(red: 0.84, green: 0.25, blue: 0.20)
        case "Slack": return Color(red: 0.44, green: 0.15, blue: 0.58)
        case "Linear": return Color(red: 0.35, green: 0.35, blue: 0.95)
        case "Asana": return Color(red: 0.95, green: 0.35, blue: 0.50)
        case "Notion": return Color(red: 0.55, green: 0.55, blue: 0.55)
        case "Calendar": return Color(red: 0.20, green: 0.60, blue: 0.95)
        case "Drive": return Color(red: 0.20, green: 0.72, blue: 0.45)
        case "Mercury": return Color(red: 0.20, green: 0.65, blue: 0.88)
        case "Typefully": return Color(red: 0.20, green: 0.52, blue: 0.95)
        case "GitHub": return Color(red: 0.14, green: 0.16, blue: 0.18)
        case "Kiloforge": return accent
        case "MCP": return accent
        default: return amethyst
        }
    }
}
