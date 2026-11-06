#if targetEnvironment(macCatalyst)
import SwiftUI

struct DesktopConnectionsView<Interactor: ViewWithModelLifecycleObserver<ProfileViewModel> & ProfileViewHandler>: View {
    @StateObject var viewModel: ProfileViewModel
    @StateObject var interactor: Interactor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connections")
                        .font(.largeTitle.bold())
                        .foregroundStyle(Theme.textPrimary)
                    Text("Bring your work into Jo. Manage accounts and add the services you use.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if viewModel.hasLoadedConnections {
                    providerGroup("Connected", states: providers.filter { $0.accountCount > 0 || $0.needsAttention })
                    providerGroup("Available services", states: providers.filter { $0.accountCount == 0 && !$0.needsAttention })
                    if providers.isEmpty {
                        ContentUnavailableView("No services available", systemImage: "link",
                            description: Text("There are no connections available for this profile."))
                    }
                } else if viewModel.connectionStatusLoadFailed {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Couldn't load connections", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Try again to check the accounts connected to this profile.")
                            .foregroundStyle(Theme.textSecondary)
                        Button("Try again") { interactor.refreshConnections() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("profileConnectionsRetry")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Checking your connections…").foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("profileConnectionsLoading")
                }

                Label {
                    Text("Connections belong to your active profile. GitHub is shared across profiles.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "person.crop.circle")
                }
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Theme.background)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("desktopConnections")
        .bind(observer: interactor, viewModel: viewModel)
    }

    private var providers: [ProfileConnectionProviderState] {
        ProfileConnectionProvider.allCases.map { $0.state(in: viewModel) }.filter(\.available)
    }

    @ViewBuilder
    private func providerGroup(_ title: String, states: [ProfileConnectionProviderState]) -> some View {
        if !states.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(states) { state in
                        NavigationLink {
                            ProfileConnectionsComponent.make(provider: state.provider)
                        } label: {
                            DesktopConnectionRow(state: state)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(state.provider.title)
                        .accessibilityValue(state.summary)
                        .accessibilityHint("Manage \(state.provider.title) connections")
                        .accessibilityIdentifier("profileConnectionProvider_\(state.provider.rawValue)")
                        if state.id != states.last?.id {
                            Divider().padding(.leading, 80)
                        }
                    }
                }
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border, lineWidth: 1))
            }
        }
    }
}

private struct DesktopConnectionRow: View {
    let state: ProfileConnectionProviderState
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: state.provider.icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 44, height: 44)
                .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(state.provider.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.accountCount > 0 || state.needsAttention {
                    Label(state.summary, systemImage: state.needsAttention ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(state.needsAttention ? Theme.warning : Theme.textSecondary)
                }
            }
            Spacer(minLength: 12)
            Text(state.needsAttention ? "Reconnect" : state.accountCount > 0 ? "Manage" : "Connect")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Theme.surfaceSecondary : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var iconColor: Color {
        if state.provider == .github { return Theme.textPrimary }
        if state.provider == .slack && colorScheme == .dark { return Color(red: 0.72, green: 0.50, blue: 0.86) }
        return Theme.serviceColor(for: state.provider.service)
    }

    private var detail: String {
        switch state.provider {
        case .google: "Gmail and Google Calendar"
        case .slack: "Messages and conversations"
        case .notion: "Pages and workspace knowledge"
        case .granola: "Meeting notes and transcripts"
        case .github: "Repositories, issues, and pull requests"
        case .custom: "Your own tools and MCP servers"
        }
    }
}

enum DesktopConnectionsComponent {
    @MainActor
    static func make() -> some View {
        DesktopConnectionsView(viewModel: ProfileViewModel(), interactor: ProfileViewInteractor())
    }
}
#endif
