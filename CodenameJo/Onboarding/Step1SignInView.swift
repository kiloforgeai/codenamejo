import Combine
import FactoryKit
import SwiftUI

protocol Step1SignInViewHandler {
    func handleGoogle(viewModel: Step1SignInViewModel)
}

struct Step1SignInView<Interactor: ViewWithModelLifecycleObserver<Step1SignInViewModel> & Step1SignInViewHandler>: View {
    @StateObject var viewModel: Step1SignInViewModel
    @StateObject var interactor: Interactor
    let onComplete: () -> Void

    /// The explanation is centred by spacers with the Google button in the thumb zone. No fields,
    /// so a plain VStack rather than a ScrollView.
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 14) {
                // Explain Google's permission request before presenting its consent sheet.
                Text(SignInTheme.headline)
                    .font(.system(size: 32, weight: .semibold, design: SignInTheme.headlineDesign))
                    .tracking(-0.8)
                    .foregroundStyle(SignInTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    // Exactly two lines, shrinking rather than wrapping again on an SE.
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(SignInTheme.subheadline)
                    .font(.system(size: 15))
                    .foregroundStyle(SignInTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)

                HStack(spacing: 10) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(SignInTheme.casaAccent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("CASA certified")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SignInTheme.textPrimary)
                        Text("Security-assessed for access to Google user data.")
                            .font(.system(size: 12))
                            .foregroundStyle(SignInTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(SignInTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(SignInTheme.textPrimary.opacity(0.08), lineWidth: 1)
                )
                .accessibilityElement(children: .combine)

                PrivacyDisclosureTeaser { viewModel.showingPrivacy = true }
            }

            Spacer()

            if let error = viewModel.error {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            VStack(spacing: 12) {
                if GoogleTokenServer.isConfigured {
                    Button { interactor.handleGoogle(viewModel: viewModel) } label: {
                        HStack(spacing: 10) {
                            Image("GoogleG")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 18, height: 18)
                            Text("Continue with Google")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Color(red: 0.13, green: 0.13, blue: 0.13))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(.black.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .disabled(viewModel.isWorking)
                    .accessibilityIdentifier("onboarding_google_signin_button")
                }

                // No spinner here: a conditional view in this stack moves the buttons under the
                // thumb. A busy state must reserve its own space.
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: viewModel.error)
        .background(
            // Flat: plain system white or black, like every onboarding screen.
            SignInTheme.background.ignoresSafeArea()
        )
        .sheet(isPresented: $viewModel.showingPrivacy) {
            PrivacyDisclosureSheet()
        }
    }
}

// MARK: - Component

@MainActor
struct Step1SignInViewComponent {
    @ViewBuilder
    static func make(onComplete: @escaping () -> Void) -> some View {
        Step1SignInView(
            viewModel: Step1SignInViewModel(),
            interactor: Step1SignInViewInteractor(onComplete: onComplete),
            onComplete: onComplete
        )
    }
}

// MARK: - View model

@MainActor
final class Step1SignInViewModel: ViewModel {
    @Published var isWorking = false
    @Published var error: String?
    @Published var showingPrivacy = false
}

// MARK: - Interactor

@MainActor
final class Step1SignInViewInteractor: ViewModelInteractor<Step1SignInViewModel> {
    @Injected(\.backend) private var backend
    @Injected(\.connections) private var connections

    /// Sign-in finishing is the parent flow's business, held as a closure because the destination
    /// differs by caller.
    private let onComplete: () -> Void

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        super.init()
    }
}

extension Step1SignInViewInteractor: Step1SignInViewHandler {
    /// The one consent: identity plus Gmail and Calendar, through the token server. Its grant is
    /// the sign-in — there is no account server.
    func handleGoogle(viewModel: Step1SignInViewModel) {
        viewModel.isWorking = true
        viewModel.error = nil
        Task {
            switch await GoogleSignInFlow.run(hint: nil, isPrimary: GoogleCredential.storedAccounts().isEmpty) {
            case .failure(.cancelled):
                viewModel.isWorking = false
                return
            case .failure(.failed(let message)):
                viewModel.isWorking = false
                viewModel.error = message
                return
            case .success:
                break
            }
            if !self.backend.isSignedIn {
                do {
                    try await self.backend.completeSignIn()
                } catch {
                    viewModel.isWorking = false
                    viewModel.error = error.localizedDescription
                    return
                }
            }
            // This sync caches snippets, so the headers-only answer must already be in hand: it is
            // chosen in `PrivacyDisclosureSheet` before the consent, and every fetch path reads it.
            await self.connections.refresh()
            Task.detached(priority: .utility) {
                await BackgroundMailRefresh.run(trigger: .signIn)
            }
            viewModel.isWorking = false
            self.onComplete()
        }
    }
}

// MARK: - Branding
// Sign-in screen copy and colors; the colors delegate to the app's `Theme`.
private enum SignInTheme {
    // Google consent copy ties each requested service to work Jo performs.
    static let headlineRaw       = "Connect Google\nsecurely"
    static let subheadlineRaw    = "Google will ask you to approve Gmail and Calendar access so Jo can prioritize your work, draft replies, and manage your schedule."
    // Headline font design: "default", "rounded", "serif", or "monospaced".
    static let fontDesignRaw     = "default"

    // Resolved values, delegated to the app's adaptive `Theme`.
    /// The system background, matching `OnboardingTheme.background`.
    static let background      = Color(uiColor: .systemBackground)
    static let surface         = Theme.surfaceSecondary
    static let textPrimary     = Theme.textPrimary
    static let textSecondary   = Theme.textSecondary
    static let casaAccent      = Theme.success

    static var headline: String {
        resolved(headlineRaw) ?? "Welcome"
    }
    static var subheadline: String {
        resolved(subheadlineRaw) ?? "Sign in to save your data securely across devices."
    }
    static var headlineDesign: Font.Design {
        switch fontDesignRaw {
        case "rounded":    return .rounded
        case "serif":      return .serif
        case "monospaced": return .monospaced
        default:           return .default
        }
    }

    /// nil for an empty or unreplaced (`__…__`) placeholder, so callers can
    /// substitute their own default.
    private static func resolved(_ value: String) -> String? {
        (value.isEmpty || value.hasPrefix("__")) ? nil : value
    }
}
