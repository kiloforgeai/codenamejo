import Combine
import FactoryKit
import SwiftUI

/// The step where every tool gets connected: Google (required) and the optional connectors.
/// Continue stays disabled until a mailbox is connected.
protocol OnboardingConnectViewHandler {
    func connect(_ provider: ProfileConnectionProvider, viewModel: OnboardingConnectViewModel)
    func openGithubVerification(viewModel: OnboardingConnectViewModel)
    func cancelGithubConnect(viewModel: OnboardingConnectViewModel)
    func next(viewModel: OnboardingConnectViewModel)
}

struct OnboardingConnectView<Interactor: ViewWithModelLifecycleObserver<OnboardingConnectViewModel> & OnboardingConnectViewHandler>: View {
    @StateObject var viewModel: OnboardingConnectViewModel
    @StateObject var interactor: Interactor

    var body: some View {
        OnboardingScaffold {
            ScrollView {
                VStack(spacing: 0) {
                    LogoFan(providers: viewModel.providers)
                        .padding(.top, 20)
                    copy
                        .padding(.top, 24)
                    VStack(spacing: 10) {
                        ForEach(viewModel.providers) { row($0) }
                    }
                    .padding(.top, 28)
                }
                .padding(.horizontal, ConnectLayout.gutter)
                .padding(.bottom, 16)
                .animation(.snappy, value: viewModel.accounts)
                .animation(.snappy, value: viewModel.busyConnector)
                .animation(.snappy, value: viewModel.githubCode)
            }
            .scrollBounceBehavior(.basedOnSize)
        } footer: {
            VStack(spacing: 10) {
                OnboardingPrimaryButton(
                    title: "Continue",
                    isEnabled: viewModel.hasMailbox,
                    accessibilityID: "onboarding_connect_continue_button"
                ) {
                    interactor.next(viewModel: viewModel)
                }
                PrivacyDisclosureTeaser { viewModel.showingPrivacy = true }
            }
            .padding(.horizontal, ConnectLayout.gutter)
            .padding(.bottom, 8)
        }
        .navigationBarBackButtonHidden(true)
        .sheet(isPresented: $viewModel.showingPrivacy) {
            PrivacyDisclosureSheet()
        }
        .bind(observer: interactor, viewModel: viewModel)
    }

    private var copy: some View {
        VStack(spacing: 10) {
            Text("Bring your tools")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(OnboardingTheme.textPrimary)
                .multilineTextAlignment(.center)

            Text("Jo works across your inbox, calendar and the apps you already use. Google is required; the rest are up to you.")
                .font(.system(size: 15))
                .foregroundStyle(OnboardingTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ provider: ProfileConnectionProvider) -> some View {
        let accounts = viewModel.accounts[provider] ?? []
        let connected = !accounts.isEmpty
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ConnectorLogo(provider: provider, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(provider.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(OnboardingTheme.textPrimary)
                            .lineLimit(1)
                        if provider == .google {
                            Text("REQUIRED")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(OnboardingTheme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(OnboardingTheme.accent.opacity(0.12)))
                                .fixedSize()
                        }
                    }
                    Text(connected ? provider.connectedLabel(accounts) : provider.onboardingBlurb)
                        .font(.system(size: 13))
                        .foregroundStyle(OnboardingTheme.textSecondary)
                        .lineLimit(connected ? 1 : 2)
                        .minimumScaleFactor(connected ? 0.8 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                trailing(provider, connected: connected)
            }
            if provider == .github, let code = viewModel.githubCode {
                githubCode(code)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if viewModel.errorConnector == provider.busyKey, let error = viewModel.error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OnboardingTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(connected ? Color.green.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding_connect_\(provider.rawValue)")
    }

    @ViewBuilder
    private func trailing(_ provider: ProfileConnectionProvider, connected: Bool) -> some View {
        if connected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white, .green)
                .accessibilityLabel("Connected")
                .transition(.scale.combined(with: .opacity))
        } else if viewModel.busyConnector == provider.busyKey {
            ProgressView()
                .frame(width: 80, height: 32)
        } else {
            Button("Connect") { interactor.connect(provider, viewModel: viewModel) }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OnboardingTheme.onCTA)
                .frame(width: 80, height: 32)
                .background(Capsule().fill(OnboardingTheme.cta))
                .opacity(viewModel.busyConnector == nil ? 1 : 0.35)
                .disabled(viewModel.busyConnector != nil)
                .accessibilityIdentifier("onboarding_connect_\(provider.rawValue)_button")
        }
    }

    private func githubCode(_ code: GitHubDeviceFlow.Code) -> some View {
        VStack(spacing: 10) {
            Text("Enter this code on GitHub")
                .font(.system(size: 13))
                .foregroundStyle(OnboardingTheme.textSecondary)
            Text(code.userCode)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(OnboardingTheme.textPrimary)
                .textSelection(.enabled)
            HStack(spacing: 20) {
                Button("Copy code & open GitHub") { interactor.openGithubVerification(viewModel: viewModel) }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.accent)
                Button("Cancel", role: .cancel) { interactor.cancelGithubConnect(viewModel: viewModel) }
                    .font(.system(size: 14))
                    .foregroundStyle(OnboardingTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OnboardingTheme.background)
        )
    }
}

// MARK: - Logos

/// Each connector's mark on an app-icon tile.
private struct ConnectorLogo: View {
    let provider: ProfileConnectionProvider
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
        Group {
            switch provider {
            case .granola:
                Image("ConnectorGranola")
                    .resizable()
                    .scaledToFill()
            case .github:
                mark("ConnectorGitHub", scale: 0.58)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 0.09, green: 0.09, blue: 0.09))
            case .google:
                mark("GoogleG", scale: 0.52).tile()
            case .slack:
                mark("ConnectorSlack", scale: 0.52).tile()
            case .notion:
                mark("ConnectorNotion", scale: 0.56)
                    .foregroundStyle(.black)
                    .tile()
            case .custom:
                // Never listed here (a server needs an address, not a consent), drawn for completeness.
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.accent)
                    .tile()
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: size * 0.08, y: size * 0.04)
        .accessibilityHidden(true)
    }

    private func mark(_ name: String, scale: CGFloat) -> some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(width: size * scale, height: size * scale)
    }
}

private extension View {
    /// The white ground the full-colour marks sit on, in both appearances.
    func tile() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white)
    }
}

/// The connectors fanned out like cards in a hand, Google in the middle and on top.
private struct LogoFan: View {
    let providers: [ProfileConnectionProvider]

    var body: some View {
        let others = providers.filter { $0 != .google }
        let half = others.count / 2
        let ordered = Array(others.prefix(half)) + [.google] + Array(others.dropFirst(half))
        let center = Double(ordered.count - 1) / 2
        HStack(spacing: -12) {
            ForEach(Array(ordered.enumerated()), id: \.element) { index, provider in
                let distance = Double(index) - center
                ConnectorLogo(provider: provider, size: provider == .google ? 72 : 56)
                    .rotationEffect(.degrees(distance * 7))
                    .offset(y: abs(distance) * 7)
                    .zIndex(-abs(distance))
            }
        }
        .frame(height: 92)
    }
}

/// A generic view cannot hold static storage, so the screen's constants live here.
private enum ConnectLayout {
    static let gutter: CGFloat = 24
}

extension ProfileConnectionProvider {
    /// `ConnectionsService.busyConnector`'s and `errorConnector`'s name for this provider.
    var busyKey: String {
        switch self {
        case .google: "gmail"
        case .notion: "notion-mcp"
        case .custom: "custom-mcp"
        default: rawValue
        }
    }

    /// What a connected row says: the account in words that name what it is. Notion's grant
    /// is labelled "Notion" rather than by workspace, so it just says it's connected.
    func connectedLabel(_ accounts: [String]) -> String {
        let named = accounts.filter { $0 != title }
        guard !named.isEmpty else { return "Connected" }
        switch self {
        case .slack: return named.map { "\($0) workspace" }.joined(separator: ", ")
        case .github: return named.map { "@\($0)" }.joined(separator: ", ")
        default: return named.joined(separator: ", ")
        }
    }

    var onboardingBlurb: String {
        switch self {
        case .google: "Gmail and Calendar"
        case .slack: "Read and reply to messages"
        case .notion: "Search and edit your pages"
        case .granola: "Ask about your meetings"
        case .github: "Issues and pull requests"
        case .custom: "Your own MCP servers"
        }
    }
}

// MARK: - Component

@MainActor
struct OnboardingConnectViewComponent {
    @ViewBuilder
    static func make(onNext: @escaping () -> Void) -> some View {
        OnboardingConnectView(
            viewModel: OnboardingConnectViewModel(),
            interactor: OnboardingConnectViewInteractor(onNext: onNext)
        )
    }
}

// MARK: - View model

@MainActor
final class OnboardingConnectViewModel: ViewModel {
    /// The providers this build offers, Google first. Google is always listed.
    @Published var providers: [ProfileConnectionProvider] = [.google]
    @Published var accounts: [ProfileConnectionProvider: [String]] = [:]
    @Published var busyConnector: String?
    @Published var error: String?
    @Published var errorConnector: String?
    @Published var githubCode: GitHubDeviceFlow.Code?
    @Published var showingPrivacy = false

    var hasMailbox: Bool { !(accounts[.google] ?? []).isEmpty }
}

// MARK: - Interactor

@MainActor
final class OnboardingConnectViewInteractor: ViewModelInteractor<OnboardingConnectViewModel> {
    @Injected(\.connections) private var connections

    private let onNext: () -> Void
    /// One-shot: a double tap on Continue must not advance the flow twice.
    private var advanced = false
    /// Whether a mailbox existed when this screen last read the service.
    private var hadMailbox: Bool?

    init(onNext: @escaping () -> Void) {
        self.onNext = onNext
        super.init()
    }

    @CancellableBuilder
    override func onViewAppear(viewModel: OnboardingConnectViewModel) -> [AnyCancellable] {
        super.onViewAppear(viewModel: viewModel)
        // `objectWillChange` fires before the write; the main-queue hop reads after it.
        connections.objectWillChange
            .receive(on: DispatchQueue.main)
            .prepend(())
            .sink { [weak self, weak viewModel] _ in
                guard let self, let viewModel else { return }
                self.apply(to: viewModel)
            }
        Task { await connections.refresh() }
    }

    private func apply(to viewModel: OnboardingConnectViewModel) {
        let available: [ProfileConnectionProvider: Bool] = [
            .slack: connections.slackAvailable,
            .notion: connections.notionMcpAvailable,
            .granola: connections.granolaAvailable,
            .github: connections.githubAvailable,
        ]
        viewModel.providers = ProfileConnectionProvider.allCases.filter { $0 == .google || available[$0] == true }
        viewModel.accounts = [
            .google: connections.gmailAccounts,
            .slack: connections.slackAccounts,
            .notion: connections.notionMcpAccounts,
            .granola: connections.granolaAccounts,
            .github: connections.githubAccounts,
        ]
        viewModel.busyConnector = connections.busyConnector
        viewModel.error = connections.errorMessage
        viewModel.errorConnector = connections.errorConnector
        viewModel.githubCode = connections.githubPendingCode

        guard connections.hasLoadedStatus else { return }
        let hasMailbox = !connections.gmailAccounts.isEmpty
        // A mailbox connected on this screen gets the first fill a sign-in would have run;
        // one that arrived connected from the welcome page already had it.
        if hadMailbox == false, hasMailbox {
            Task.detached(priority: .utility) {
                await BackgroundMailRefresh.run(trigger: .signIn)
            }
        }
        hadMailbox = hasMailbox
    }
}

extension OnboardingConnectViewInteractor: OnboardingConnectViewHandler {
    func connect(_ provider: ProfileConnectionProvider, viewModel: OnboardingConnectViewModel) {
        // Each consent reports back through the service's published state, observed above.
        switch provider {
        case .google: connections.connectGmail()
        case .slack: connections.connectSlack()
        case .notion: connections.connectNotionMcp()
        case .granola: connections.connectGranola()
        case .github: connections.connectGithub()
        // Added by address in Settings → Connections → Custom MCP; onboarding never lists it.
        case .custom: RealtimeLog.log("onboarding: custom MCP is added in Settings, not here")
        }
    }

    func openGithubVerification(viewModel: OnboardingConnectViewModel) {
        guard let code = viewModel.githubCode else { return }
        UIPasteboard.general.string = code.userCode
        UIApplication.shared.open(code.verificationURL)
    }

    func cancelGithubConnect(viewModel: OnboardingConnectViewModel) {
        connections.cancelGithubConnect()
    }

    func next(viewModel: OnboardingConnectViewModel) {
        guard viewModel.hasMailbox, !advanced else { return }
        advanced = true
        onNext()
    }
}

#if DEBUG
import Prefire

#Preview("OnboardingConnectView") {
    OnboardingConnectViewComponent.make(onNext: {})
        .snapshot(delay: 0.5)
}
#endif
