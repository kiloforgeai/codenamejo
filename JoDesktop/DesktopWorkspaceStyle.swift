#if targetEnvironment(macCatalyst)
import SwiftUI

enum DesktopWorkspaceStyle {
    static let accent = Color(uiColor: .systemBlue)
    static let brand = Color("JoBrand")
    static let canvas = Color(uiColor: .systemBackground)
    static let inset = Color(uiColor: .secondarySystemBackground)
    static let line = Color.primary.opacity(0.09)

    static func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }
}

struct DesktopToolbarButton: View {
    let title: String
    let symbol: String
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32).contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? DesktopWorkspaceStyle.accent : .secondary)
        .background(active ? DesktopWorkspaceStyle.accent.opacity(0.1) : hovering ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .accessibilityLabel(title).help(title)
    }
}
#endif
