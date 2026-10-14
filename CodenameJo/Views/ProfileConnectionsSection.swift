import SwiftUI

enum ProfileConnectionProvider: String, CaseIterable, Identifiable {
    case google, slack, notion, granola, github, custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .google: "Google"
        case .slack: "Slack"
        case .notion: "Notion"
        case .granola: "Granola"
        case .github: "GitHub"
        case .custom: "Custom MCP"
        }
    }
    var icon: String {
        switch self {
        case .google: "envelope.fill"
        case .slack: "bubble.left.and.bubble.right.fill"
        case .notion: "doc.text.fill"
        case .granola: "text.bubble.fill"
        case .github: "chevron.left.forwardslash.chevron.right"
        case .custom: "puzzlepiece.extension.fill"
        }
    }
    var service: String {
        switch self {
        case .google: "Gmail"
        case .custom: "MCP"
        default: title
        }
    }

    @MainActor
    func state(in viewModel: ProfileViewModel) -> ProfileConnectionProviderState {
        let available: Bool
        let accounts: [String]
        let needsReauth: [String]
        switch self {
        case .google:
            available = viewModel.gmailAvailable
            accounts = viewModel.gmailAccounts
            needsReauth = viewModel.gmailNeedsReauth
        case .slack:
            // Hidden when the build has no Slack app (`JO_SLACK_CLIENT_ID` unset).
            available = viewModel.slackAvailable
            accounts = viewModel.slackAccounts
            needsReauth = viewModel.slackNeedsReauth
        case .notion:
            // Bound to the profile it was connected under.
            available = viewModel.notionMcpAvailable
            accounts = viewModel.notionMcpAccounts
            needsReauth = viewModel.notionMcpNeedsReauth
        case .granola:
            available = viewModel.granolaAvailable
            accounts = viewModel.granolaAccounts
            needsReauth = viewModel.granolaNeedsReauth
        case .github:
            // Not per profile: one GitHub connection serves every profile.
            available = viewModel.githubAvailable
            accounts = viewModel.githubAccounts
            needsReauth = viewModel.githubNeedsReauth
        case .custom:
            // The user's own servers, bound to the profile they were added under.
            available = viewModel.customMCPAvailable
            accounts = viewModel.customMCPServers.map(\.name)
            needsReauth = viewModel.customMCPServers.filter(\.needsReauth).map(\.name)
        }
        return ProfileConnectionProviderState(
            provider: self,
            available: available,
            accountCount: accounts.count,
            needsAttention: !needsReauth.isEmpty
        )
    }
}

struct ProfileConnectionProviderState: Equatable, Identifiable {
    let provider: ProfileConnectionProvider
    let available: Bool
    let accountCount: Int
    let needsAttention: Bool
    var id: ProfileConnectionProvider { provider }

    var summary: String {
        if needsAttention { return "Needs reconnecting" }
        if accountCount == 0 { return "Not connected" }
        let noun = provider == .custom ? "server" : "account"
        return accountCount == 1 ? "1 \(noun) connected" : "\(accountCount) \(noun)s connected"
    }
}

struct ProfileConnectionsSummaryView<Interactor: ViewWithModelLifecycleObserver<ProfileViewModel> & ProfileViewHandler>: View {
    @StateObject var viewModel: ProfileViewModel
    @StateObject var interactor: Interactor

    var body: some View {
        Section {
            if viewModel.hasLoadedConnections {
                ForEach(visibleProviders) { state in
                    let provider = state.provider
                    NavigationLink {
                        ProfileConnectionsComponent.make(provider: provider)
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Theme.serviceColor(for: provider.service).opacity(0.14))
                                Image(systemName: provider.icon)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.serviceColor(for: provider.service))
                            }
                            .frame(width: 34, height: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.title)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(state.summary)
                                    .font(.system(size: 12))
                                    .foregroundStyle(state.needsAttention ? Theme.warning : Theme.textTertiary)
                            }
                            Spacer(minLength: 8)
                        }
                        .padding(.vertical, 3)
                    }
                    .listRowBackground(Theme.surface)
                    .accessibilityIdentifier("profileConnectionProvider_\(provider.rawValue)")
                }
            } else if viewModel.connectionStatusLoadFailed {
                Button {
                    interactor.refreshConnections()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Couldn't load connections")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Tap to try again")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .listRowBackground(Theme.surface)
                .accessibilityIdentifier("profileConnectionsRetry")
            } else {
                HStack(spacing: 12) {
                    ProgressView().frame(width: 34, height: 34)
                    Text("Checking your connections…")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                }
                .listRowBackground(Theme.surface)
                .accessibilityIdentifier("profileConnectionsLoading")
            }
        } header: {
            SettingsRow.header("Connections")
        } footer: {
            SettingsRow.footer("Connections shown here belong to the active profile.")
        }
        .accessibilityIdentifier("profileConnectionsSection")
        .bind(observer: interactor, viewModel: viewModel)
    }

    private var visibleProviders: [ProfileConnectionProviderState] {
        ProfileConnectionProvider.allCases
            .map { $0.state(in: viewModel) }
            .filter(\.available)
    }
}

struct ProfileConnectionsView<Interactor: ViewWithModelLifecycleObserver<ProfileViewModel> & ProfileViewHandler>: View {
    let provider: ProfileConnectionProvider
    @StateObject var viewModel: ProfileViewModel
    @StateObject var interactor: Interactor

    var body: some View {
        List { connectionsSection }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(provider.title)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("profileConnectionDetail_\(provider.rawValue)")
            .sheet(isPresented: $viewModel.showCustomMCPForm) {
                CustomMCPFormView(viewModel: viewModel, interactor: interactor)
            }
            .alert(
                "Disconnect \(viewModel.pendingGoogleRemoval ?? "")?",
                isPresented: Binding(
                    get: { viewModel.pendingGoogleRemoval != nil },
                    set: { if !$0 { viewModel.pendingGoogleRemoval = nil } }
                )
            ) {
                Button("Disconnect", role: .destructive) {
                    interactor.confirmRemoveGoogle(viewModel: viewModel)
                }
                Button("Cancel", role: .cancel) { viewModel.pendingGoogleRemoval = nil }
            } message: {
                Text("Codename Jo will stop reading this mailbox and its calendar, and the mail cached on this phone will be deleted. Your Google account is not affected — you can connect it again at any time.")
            }
            .bind(observer: interactor, viewModel: viewModel)
    }
}

@MainActor
enum ProfileConnectionsSummaryComponent {
    static func make() -> some View {
        ProfileConnectionsSummaryView(viewModel: ProfileViewModel(), interactor: ProfileViewInteractor())
    }
}

@MainActor
enum ProfileConnectionsComponent {
    static func make(provider: ProfileConnectionProvider) -> some View {
        ProfileConnectionsView(provider: provider, viewModel: ProfileViewModel(), interactor: ProfileViewInteractor())
    }
}

/// Profiles → Connections: one `Section` per provider, with its name in the header, and one
/// tappable thing per row. Rows go through the shared helpers below so the shapes stay alike.
extension ProfileConnectionsView {
    /// The four provider sections. Still one property so `ProfileView.body` reads
    /// as a list of sections, but it expands to four siblings rather than one.
    @ViewBuilder
    var connectionsSection: some View {
        if viewModel.hasLoadedConnections,
           provider.state(in: viewModel).available {
            if provider == .google { googleSection }
            if provider == .slack { slackSection }
            if provider == .notion { notionSection }
            if provider == .granola { granolaSection }
            if provider == .github { githubSection }
            if provider == .custom { customMCPSection }
        } else if viewModel.connectionStatusLoadFailed {
            detailLoadFailureSection
        } else if viewModel.hasLoadedConnections {
            providerUnavailableSection
        } else {
            checkingSection
        }
    }

    private var detailLoadFailureSection: some View {
        Section {
            Button {
                interactor.refreshConnections()
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
                    .font(ConnectionLayout.action)
                    .foregroundStyle(Theme.accent)
                    .frame(minHeight: ConnectionLayout.rowHeight)
            }
            .listRowBackground(Theme.surface)
            .accessibilityIdentifier("profileConnectionDetailRetry_\(provider.rawValue)")
        } header: {
            connectorHeader(provider.title, icon: provider.icon, service: provider.service)
        } footer: {
            Text("Codename Jo couldn't load this profile's connection status.")
                .font(ConnectionLayout.footer)
                .foregroundStyle(Theme.error)
        }
    }

    private var providerUnavailableSection: some View {
        Section {
            HStack(spacing: ConnectionLayout.rowSpacing) {
                Image(systemName: provider.icon)
                    .font(ConnectionLayout.icon)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: ConnectionLayout.iconColumn)
                Text("Not available for this profile")
                    .font(ConnectionLayout.title)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .frame(minHeight: ConnectionLayout.rowHeight)
            .listRowBackground(Theme.surface)
            .accessibilityIdentifier("profileConnectionUnavailable_\(provider.rawValue)")
        }
    }

    // MARK: - Google

    /// One Google connection covers mail and calendar: calendar is a capability, not a connector.
    @ViewBuilder
    private var googleSection: some View {
        if viewModel.gmailAvailable {
            Section {
                ForEach(viewModel.gmailAccounts, id: \.self) { email in
                    // The subtitle names only what is missing, in order: a revoked grant, missing scopes, then
                    // no grant on this phone (absent from background mail refresh). Any of them turns it amber.
                    let hasCalendar = interactor.hasCalendar(email)
                    let hasFilters = interactor.hasFilters(email)
                    let broken = viewModel.gmailNeedsReauth.contains(email)
                    let onDevice = interactor.hasDeviceGrant(email)
                    let isSignedInAccount = viewModel.accountEmail?
                        .caseInsensitiveCompare(email) == .orderedSame
                    let missing = [
                        hasCalendar ? nil : "calendar",
                        hasFilters ? nil : "rules",
                    ].compactMap { $0 }
                    connectorAccountRow(
                        icon: "envelope.fill",
                        service: "Gmail",
                        title: email,
                        subtitle: broken
                            ? "Needs reconnecting"
                            : (missing.isEmpty
                                ? (onDevice
                                    ? "Mail, calendar and rules"
                                    : "Reconnect to use this inbox offline")
                                : "Reconnect to add \(missing.joined(separator: " and "))"),
                        needsAttention: broken || !missing.isEmpty || !onDevice,
                        identifier: "gmailAccountRow_\(email)",
                        menu: {
                            // Re-runs consent for this address, so a scope change doesn't need Remove then Add.
                            Button("Reconnect") {
                                interactor.reconnectGoogle(email, viewModel: viewModel)
                            }
                            .accessibilityIdentifier("reconnectGmail_\(email)")

                            // The signed-in account cannot be disconnected: the session rests on it. Shown disabled,
                            // not hidden, because a missing item reads as a bug.
                            if isSignedInAccount {
                                Button("Signed in with this account") { }
                                    .disabled(true)
                            } else {
                                Button("Disconnect", role: .destructive) {
                                    interactor.removeGoogle(email, viewModel: viewModel)
                                }
                            }
                        }
                    )
                }

                // "Google", not "Gmail": one consent grants mail and calendar together.
                connectorConnectButton(
                    title: viewModel.gmailAccounts.isEmpty
                        ? "Connect Google account"
                        : "Add Google account",
                    connector: "gmail",
                    identifier: "connectGmailButton",
                    action: { interactor.connectGoogle(viewModel: viewModel) }
                )

                connectorDetailRow(
                    name: "Google",
                    icon: "envelope.fill",
                    service: "Gmail",
                    capabilities: .google(inboxes: viewModel.gmailAccounts),
                    summary: ConnectorCopy.google,
                    identifier: "googleDetailRow"
                )
            } header: {
                connectorHeader("Google", icon: "envelope.fill", service: "Gmail")
            } footer: {
                // Kept for `connectionError`; the prose lives behind "What it can do".
                connectorFooter(connector: "gmail")
            }
        }
    }

    // MARK: - GitHub

    /// GitHub through its device flow: while a sign-in waits, the section shows the code to
    /// enter on GitHub. A token GitHub refused keeps its row, marked, so Reconnect has a home.
    @ViewBuilder
    private var githubSection: some View {
        if viewModel.githubAvailable {
            Section {
                ForEach(viewModel.githubAccounts, id: \.self) { login in
                    let broken = viewModel.githubNeedsReauth.contains(login)
                    connectorAccountRow(
                        icon: "chevron.left.forwardslash.chevron.right",
                        service: "GitHub",
                        title: "@\(login)",
                        subtitle: broken ? "Needs reconnecting" : nil,
                        needsAttention: broken,
                        identifier: "githubAccountRow_\(login)",
                        menu: {
                            Button("Reconnect") {
                                interactor.connectGithub(viewModel: viewModel)
                            }
                            .accessibilityIdentifier("reconnectGithub_\(login)")

                            Button("Remove", role: .destructive) {
                                interactor.removeGithub(login, viewModel: viewModel)
                            }
                        }
                    )
                }

                if let code = viewModel.githubPendingCode {
                    githubCodeRows(code)
                } else {
                    connectorConnectButton(
                        title: viewModel.githubAccounts.isEmpty
                            ? "Connect GitHub"
                            : "Add GitHub account",
                        connector: "github",
                        identifier: "connectGithubButton",
                        action: { interactor.connectGithub(viewModel: viewModel) }
                    )
                }

                connectorDetailRow(
                    name: "GitHub",
                    icon: "chevron.left.forwardslash.chevron.right",
                    service: "GitHub",
                    capabilities: .github,
                    summary: ConnectorCopy.github,
                    identifier: "githubDetailRow"
                )
            } header: {
                connectorHeader(
                    "GitHub",
                    icon: "chevron.left.forwardslash.chevron.right",
                    service: "GitHub"
                )
            } footer: {
                connectorFooter(
                    "Shared by every profile. Removing an account deletes its token from this phone; "
                        + "revoke the app under GitHub Settings → Applications to end the grant.",
                    connector: "github"
                )
            }
        }
    }

    /// The code and the two things to do with it. Not disabled while busy: the sign-in in
    /// flight is the thing these rows serve.
    @ViewBuilder
    private func githubCodeRows(_ code: GitHubDeviceFlow.Code) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enter this code on GitHub")
                .font(ConnectionLayout.subtitle)
                .foregroundStyle(Theme.textTertiary)
            Text(code.userCode)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .accessibilityIdentifier("githubUserCode")
        }
        .frame(maxWidth: .infinity, minHeight: ConnectionLayout.rowHeight, alignment: .leading)
        .listRowBackground(Theme.surface)
        .fullWidthSeparator()

        Button {
            interactor.openGithubVerification(viewModel: viewModel)
        } label: {
            HStack(spacing: ConnectionLayout.rowSpacing) {
                ProgressView().frame(width: ConnectionLayout.iconColumn)
                Text("Copy code and open GitHub")
                    .font(ConnectionLayout.action)
                    .foregroundStyle(Theme.accent)
                Spacer()
            }
            .frame(minHeight: ConnectionLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .listRowBackground(Theme.surface)
        .fullWidthSeparator()
        .accessibilityIdentifier("openGithubVerification")

        Button("Cancel", role: .cancel) {
            interactor.cancelGithubConnect(viewModel: viewModel)
        }
        .font(ConnectionLayout.action)
        .frame(minHeight: ConnectionLayout.detailRowHeight)
        .listRowBackground(Theme.surface)
        .accessibilityIdentifier("cancelGithubConnect")
    }

    // MARK: - Notion

    /// Notion, reaching the user's whole workspace. A rejected background renewal leaves the row
    /// connected but broken, so Reconnect means replacing the credential.
    @ViewBuilder
    private var notionSection: some View {
        if viewModel.notionMcpAvailable {
            Section {
                ForEach(viewModel.notionMcpAccounts, id: \.self) { workspace in
                    let broken = viewModel.notionMcpNeedsReauth.contains(workspace)
                    connectorAccountRow(
                        icon: "doc.text.fill",
                        service: "Notion",
                        title: workspace,
                        // Nothing at all in the healthy case.
                        subtitle: broken ? "Needs reconnecting" : nil,
                        needsAttention: broken,
                        identifier: "notionMcpAccountRow_\(workspace)",
                        menu: {
                            Button(broken ? "Reconnect" : "Replace connection") {
                                interactor.connectNotionMcp(viewModel: viewModel)
                            }
                            .accessibilityIdentifier("reconnectNotionMcp_\(workspace)")

                            Button("Remove", role: .destructive) {
                                interactor.removeNotionMcp(workspace, viewModel: viewModel)
                            }
                        }
                    )
                }

                // One row once connected: the broker keys every workspace's credential on "Notion",
                // so a second Connect would replace, not add. Reconnect lives in the row's menu.
                if viewModel.notionMcpAccounts.isEmpty {
                    connectorConnectButton(
                        title: "Connect Notion",
                        connector: "notion-mcp",
                        identifier: "connectNotionMcpButton",
                        action: { interactor.connectNotionMcp(viewModel: viewModel) }
                    )
                }

                connectorDetailRow(
                    name: "Notion",
                    icon: "doc.text.fill",
                    service: "Notion",
                    capabilities: .notion,
                    summary: ConnectorCopy.notion,
                    identifier: "notionDetailRow"
                )
            } header: {
                connectorHeader("Notion", icon: "doc.text.fill", service: "Notion")
            } footer: {
                connectorFooter(connector: "notion-mcp")
            }
        }
    }

    // MARK: - Granola

    @ViewBuilder
    private var granolaSection: some View {
        if viewModel.granolaAvailable {
            Section {
                ForEach(viewModel.granolaAccounts, id: \.self) { account in
                    let broken = viewModel.granolaNeedsReauth.contains(account)
                    connectorAccountRow(
                        icon: "text.bubble.fill",
                        service: "Granola",
                        title: account,
                        subtitle: broken ? "Needs reconnecting" : nil,
                        needsAttention: broken,
                        identifier: "granolaAccountRow_\(account)",
                        menu: {
                            Button(broken ? "Reconnect" : "Replace connection") {
                                interactor.reconnectGranola(account, viewModel: viewModel)
                            }
                            .accessibilityIdentifier("reconnectGranola_\(account)")

                            Button("Remove", role: .destructive) {
                                interactor.removeGranola(account, viewModel: viewModel)
                            }
                        }
                    )
                }

                if viewModel.granolaAccounts.isEmpty {
                    connectorConnectButton(
                        title: "Connect Granola",
                        connector: "granola",
                        identifier: "connectGranolaButton",
                        action: { interactor.connectGranola(viewModel: viewModel) }
                    )
                }

                connectorDetailRow(
                    name: "Granola",
                    icon: "text.bubble.fill",
                    service: "Granola",
                    capabilities: .granola,
                    summary: ConnectorCopy.granola,
                    identifier: "granolaDetailRow"
                )
            } header: {
                connectorHeader("Granola", icon: "text.bubble.fill", service: "Granola")
            } footer: {
                connectorFooter(connector: "granola")
            }
        }
    }

    // MARK: - Custom MCP

    /// One row per server the user added, each with Reconnect, Refresh tools and Remove; a
    /// "What it can do" row per server, since each lists its own tools.
    @ViewBuilder
    private var customMCPSection: some View {
        if viewModel.customMCPAvailable {
            Section {
                ForEach(viewModel.customMCPServers) { server in
                    connectorAccountRow(
                        icon: "puzzlepiece.extension.fill",
                        service: "MCP",
                        title: server.name,
                        subtitle: server.subtitle,
                        needsAttention: server.needsReauth,
                        identifier: "customMCPRow_\(server.id)",
                        menu: {
                            Button("Reconnect") {
                                interactor.reconnectCustomMCP(server, viewModel: viewModel)
                            }
                            .accessibilityIdentifier("reconnectCustomMCP_\(server.id)")

                            Button("Refresh tools") {
                                interactor.refreshCustomMCPTools(server, viewModel: viewModel)
                            }

                            Button("Remove", role: .destructive) {
                                interactor.removeCustomMCP(server, viewModel: viewModel)
                            }
                        }
                    )
                }

                connectorConnectButton(
                    title: "Add MCP server",
                    connector: "custom-mcp",
                    identifier: "addCustomMCPButton",
                    action: { interactor.beginAddCustomMCP(viewModel: viewModel) }
                )

                ForEach(viewModel.customMCPServers) { server in
                    connectorDetailRow(
                        name: server.name,
                        icon: "puzzlepiece.extension.fill",
                        service: "MCP",
                        capabilities: server.capabilities,
                        summary: ConnectorCopy.customMCP(server),
                        title: "What \(server.name) can do",
                        identifier: "customMCPDetailRow_\(server.id)"
                    )
                }
            } header: {
                connectorHeader("Custom MCP", icon: "puzzlepiece.extension.fill", service: "MCP")
            } footer: {
                connectorFooter(ConnectorCopy.customMCP, connector: "custom-mcp")
            }
        }
    }

    // MARK: - Before the answer arrives

    /// Shown until the connections have loaded; otherwise every section is hidden on a cold launch.
    private var checkingSection: some View {
        Section {
            HStack(spacing: ConnectionLayout.rowSpacing) {
                ProgressView().frame(width: ConnectionLayout.iconColumn)
                Text("Checking your connections…")
                    .font(ConnectionLayout.title)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .listRowBackground(Theme.surface)
            .accessibilityIdentifier("connectionsLoadingRow")
        } header: {
            connectorHeader("Connections", icon: "link", service: "")
        }
    }

    // MARK: - Row shapes

    /// One connected account as one hit target: the `Menu` wraps the whole row. Remove lives only
    /// in the menu because the root pager's horizontal ScrollView claims swipes first.
    @ViewBuilder
    func connectorAccountRow<MenuContent: View>(
        icon: String,
        service: String,
        title: String,
        subtitle: String? = nil,
        needsAttention: Bool = false,
        identifier: String,
        @ViewBuilder menu: () -> MenuContent
    ) -> some View {
        Menu {
            menu()
        } label: {
            HStack(spacing: ConnectionLayout.rowSpacing) {
                Image(systemName: icon)
                    .font(ConnectionLayout.icon)
                    .foregroundStyle(Theme.serviceColor(for: service))
                    .frame(width: ConnectionLayout.iconColumn)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(ConnectionLayout.title)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(ConnectionLayout.subtitle)
                            .foregroundStyle(needsAttention ? Theme.warning : Theme.textTertiary)
                    }
                }
                Spacer()
                Image(systemName: "ellipsis.circle")
                    .font(ConnectionLayout.icon)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: ConnectionLayout.tapTarget, height: ConnectionLayout.tapTarget)
            }
            .frame(minHeight: ConnectionLayout.rowHeight)
            // Makes the gaps between icon, labels and glyph tappable.
            .contentShape(Rectangle())
        }
        .disabled(viewModel.isConnectionBusy)
        .listRowBackground(Theme.surface)
        .fullWidthSeparator()
        .accessibilityIdentifier(identifier)
    }

    /// The Connect / Add row at the foot of a provider's section. The spinner is keyed on
    /// `connector` so it shows on the provider actually working.
    func connectorConnectButton(
        title: String,
        connector: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: ConnectionLayout.rowSpacing) {
                if viewModel.busyConnector == connector {
                    ProgressView().frame(width: ConnectionLayout.iconColumn)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(ConnectionLayout.icon)
                        .foregroundStyle(Theme.accent)
                        .frame(width: ConnectionLayout.iconColumn)
                }
                Text(title)
                    .font(ConnectionLayout.action)
                    .foregroundStyle(Theme.accent)
                Spacer()
            }
            .frame(minHeight: ConnectionLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .disabled(viewModel.isConnectionBusy)
        .listRowBackground(Theme.surface)
        .fullWidthSeparator()
        .accessibilityIdentifier(identifier)
    }

    func connectorDetailRow(
        name: String,
        icon: String,
        service: String,
        capabilities: [ConnectorCapability],
        summary: String? = nil,
        title: String = "What it can do",
        identifier: String
    ) -> some View {
        NavigationLink {
            ConnectorDetailViewComponent.make(
                name: name,
                service: service,
                capabilities: capabilities,
                summary: summary
            )
        } label: {
            HStack(spacing: ConnectionLayout.rowSpacing) {
                Image(systemName: "list.bullet")
                    .font(ConnectionLayout.icon)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: ConnectionLayout.iconColumn)
                Text(title)
                    .font(ConnectionLayout.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            // Half height: a way out of the section, not one of the things in it.
            .frame(minHeight: ConnectionLayout.detailRowHeight)
            .contentShape(Rectangle())
        }
        .listRowBackground(Theme.surface)
        .fullWidthSeparator()
        .accessibilityIdentifier(identifier)
    }

    /// The provider's name. The icon repeats the row tint so a section stays identifiable while scrolled.
    func connectorHeader(
        _ name: String,
        icon: String,
        service: String,
        restriction: (text: String, identifier: String)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(service.isEmpty
                                     ? Theme.textTertiary
                                     : Theme.serviceColor(for: service))
                Text(name)
                    // Tracking dropped with the size. Letter-spacing that far open is a
                    // small-caps device; at 17pt it just looks stretched.
                    .font(ConnectionLayout.header)
                    .foregroundStyle(Theme.textPrimary)
            }

            if let restriction {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                    Text(restriction.text)
                        .font(ConnectionLayout.footer)
                }
                .foregroundStyle(Theme.warning)
                .accessibilityIdentifier(restriction.identifier)
            }
        }
        .textCase(nil)
    }

    /// One provider's footer: what it's for, its pilot restriction, then any error it produced.
    @ViewBuilder
    func connectorFooter(
        _ text: String? = nil,
        connector: String,
        restriction: (text: String, identifier: String)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let text {
                Text(text)
                    .font(ConnectionLayout.footer)
                    .foregroundStyle(Theme.textTertiary)
            }

            if let restriction {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                    Text(restriction.text)
                        .font(ConnectionLayout.footer)
                }
                .foregroundStyle(Theme.warning)
                .accessibilityIdentifier(restriction.identifier)
            }

            if let error = viewModel.connectionError,
               viewModel.connectionErrorConnector == connector {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(error)
                        .font(ConnectionLayout.footer)
                }
                .foregroundStyle(Theme.error)
                .accessibilityIdentifier("connectionError_\(connector)")
            }
        }
    }
}

extension View {
    func fullWidthSeparator() -> some View {
        self
            .padding(.horizontal, ConnectionLayout.rowInset)
            .listRowInsets(EdgeInsets())
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}

enum ConnectorCopy {
    static let github =
        "Catches you up on pull requests, reviews and CI, and can tidy a pull request up — draft it, "
            + "retitle it, close it. It can also merge one, file or comment on an issue, and start a CI run; "
            + "those are read back to you before they go. It cannot push code or approve a review."

    static let notion =
        "Finds and reads your pages and databases, captures a note where you say, and "
            + "marks things done. Writes go as soon as you ask, without a confirmation. It "
            + "can add to a page and set its properties, and never deletes or rewrites one."

    static let granola =
        "Lets you ask what was said, decided or promised in a meeting and get an answer "
            + "from your own Granola notes, including what everyone took away as an action "
            + "item. It reads and never writes: nothing here can change or delete a note."

    static let google =
        "One account covers mail and calendar. Add more to triage several inboxes. "
            + "Sending goes as soon as you ask, without a confirmation — it says every "
            + "address it used, copies included."

    static let customMCP =
        "Any MCP server with an https address. Jo calls it from this phone with the credential "
            + "you give it, and every tool it lists is one you can ask for by voice. Nothing about "
            + "the server goes through a server of ours."

    /// The detail screen's summary for one server: what Jo does with it, and the caveat that the
    /// tools are the server's own.
    static func customMCP(_ server: CustomMCPServerStatus) -> String {
        "Jo offers \(server.toolCount == 1 ? "this tool" : "these \(server.toolCount) tools") exactly as "
            + "\(server.name) lists them, and runs them as you ask. What each one changes is up to that "
            + "server; ask Jo to read a result back before relying on it."
    }
}

/// Screen constants for Connections. A separate enum because the generic `ProfileView` cannot hold static storage.
enum ConnectionLayout {
    static let iconColumn: CGFloat = 28
    static let rowSpacing: CGFloat = 12

    static let rowHeight: CGFloat = 88

    static let detailRowHeight: CGFloat = 30

    /// The horizontal margin `fullWidthSeparator()` puts back on row content after zeroing
    /// `listRowInsets`. Matches the list's own default so nothing shifts.
    static let rowInset: CGFloat = 16

    static let tapTarget: CGFloat = 44

    static let icon = Font.system(size: 20)
    static let title = Font.system(size: 17)
    static let action = Font.system(size: 17, weight: .medium)
    static let subtitle = Font.system(size: 13)
    static let footer = Font.system(size: 12)
    static let header = Font.system(size: 17, weight: .semibold)
}
