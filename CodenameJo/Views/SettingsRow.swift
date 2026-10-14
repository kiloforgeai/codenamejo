import SwiftUI

/// One definition of the settings row look, so the sections in the Settings list cannot drift apart.
enum SettingsRow {
    static func label(_ title: String, icon: String, detail: String) -> some View {
        Label(title: title, icon: icon, detail: detail)
    }

    /// A view rather than a builder so the icon column can scale with Dynamic Type.
    private struct Label: View {
        let title: String
        let icon: String
        let detail: String
        @ScaledMetric private var iconWidth: CGFloat = 24

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(Theme.accent)
                    .frame(width: iconWidth)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
        }
    }

    static func header(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(Theme.textPrimary)
            .textCase(nil)
    }

    static func footer(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.textTertiary)
    }
}
