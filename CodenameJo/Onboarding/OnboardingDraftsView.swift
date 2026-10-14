import Combine
import FactoryKit
import SwiftUI

/// Whether Jo sends mail or only drafts it (`DraftsOnly`). The stored flag is inverted: `true`
/// means Jo is not allowed to send.
protocol OnboardingDraftsViewHandler {
    func next(draftsOnly: Bool, viewModel: OnboardingDraftsViewModel)
}

struct OnboardingDraftsView<Interactor: ViewWithModelLifecycleObserver<OnboardingDraftsViewModel> & OnboardingDraftsViewHandler>: View {
    @StateObject var viewModel: OnboardingDraftsViewModel
    @StateObject var interactor: Interactor

    /// The default must match `DraftsOnly.isOn`'s own — a `false` here would draw a
    /// mailbox that sends while the broker drafted.
    @AppStorage(DraftsOnly.storageKey) private var draftsOnly = true

    var body: some View {
        OnboardingScaffold(
            title: "Can Jo send for you?",
            subtitle: "Choose whether Jo can send messages from your Gmail."
        ) {
            VStack(spacing: 12) {
                Spacer(minLength: 12)
                permissionOption(allowSending: true)
                permissionOption(allowSending: false)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, DraftsLayout.gutter)
        } footer: {
            VStack(spacing: 14) {
                Text("You can change this any time in Settings.")
                    .font(.system(size: 13))
                    .foregroundStyle(OnboardingTheme.textSecondary)
                // Disabled while the answer is being written back.
                OnboardingPrimaryButton(
                    title: "Continue",
                    isEnabled: viewModel.isReady && !viewModel.isSaving,
                    accessibilityID: "onboarding_drafts_continue_button"
                ) {
                    interactor.next(draftsOnly: draftsOnly, viewModel: viewModel)
                }
            }
            .padding(.horizontal, DraftsLayout.gutter)
            .padding(.bottom, 8)
        }
        // No back button; hiding the chevron also hides the edge-swipe pop.
        .navigationBarBackButtonHidden(true)
        .bind(observer: interactor, viewModel: viewModel)
    }

    /// Two neutral outcomes keep the send permission legible.
    private func permissionOption(allowSending: Bool) -> some View {
        let isSelected = draftsOnly == !allowSending
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                draftsOnly = !allowSending
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: allowSending ? "paperplane.fill" : "tray.and.arrow.down.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(OnboardingTheme.textSecondary.opacity(0.12)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(allowSending
                        ? "Allow Jo to send on your behalf"
                        : "Don’t allow Jo to send on your behalf")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(OnboardingTheme.textPrimary)

                    Text(allowSending
                        ? "Jo sends messages when you ask."
                        : "Jo saves messages to Gmail Drafts for you to send.")
                        .font(.system(size: 13))
                        .foregroundStyle(OnboardingTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(isSelected
                        ? OnboardingTheme.textPrimary
                        : OnboardingTheme.textSecondary.opacity(0.45))
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? OnboardingTheme.surface : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSelected ? OnboardingTheme.textPrimary : Theme.border,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(allowSending
            ? "onboarding_drafts_allow_sending"
            : "onboarding_drafts_dont_allow_sending")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Not movable until the account's value has loaded.
        .disabled(!viewModel.isReady)
        .opacity(viewModel.isReady ? 1 : 0.5)
    }
}

/// A generic view cannot hold static storage, so the screen's constants live here.
private enum DraftsLayout {
    static let gutter: CGFloat = 24
}

// MARK: - Component

@MainActor
struct OnboardingDraftsViewComponent {
    @ViewBuilder
    static func make(onNext: @escaping () -> Void) -> some View {
        OnboardingDraftsView(
            viewModel: OnboardingDraftsViewModel(),
            interactor: OnboardingDraftsViewInteractor(onNext: onNext)
        )
    }
}

// MARK: - View model

@MainActor
final class OnboardingDraftsViewModel: ViewModel {
    /// True once the account's profile has been applied, has failed, or there is no session. Never
    /// goes back to false: a later `.saving` is this screen's own write.
    @Published var isReady = false

    /// True while the choice is being pushed to the account.
    @Published var isSaving = false
}

// MARK: - Interactor

@MainActor
final class OnboardingDraftsViewInteractor: ViewModelInteractor<OnboardingDraftsViewModel> {
    @Injected(\.userProfile) private var userProfile
    /// For the one address this answer is about — see `next(draftsOnly:viewModel:)`.
    @Injected(\.connections) private var connections

    private let onNext: () -> Void
    /// One-shot: a second tap while the flush is in flight would advance twice and skip
    /// the finish work, the same race the connect and notification steps guard.
    private var advanced = false

    init(onNext: @escaping () -> Void) {
        self.onNext = onNext
        super.init()
    }

    @CancellableBuilder
    override func onViewAppear(viewModel: OnboardingDraftsViewModel) -> [AnyCancellable] {
        super.onViewAppear(viewModel: viewModel)
        // Usable immediately: this screen sits right behind sign-in, and the absent-key default is
        // the cautious one for an account reaching onboarding.
        viewModel.isReady = true
        userProfile.$hasSettled
            .receive(on: DispatchQueue.main)
            .sink { [weak viewModel] settled in
                if settled { viewModel?.isReady = true }
            }
    }
}

extension OnboardingDraftsViewInteractor: OnboardingDraftsViewHandler {
    /// One event at Continue, after the awaited write. Written for the inbox as well as the
    /// account, because a new inbox's explicit entry outranks the account flag.
    func next(draftsOnly: Bool, viewModel: OnboardingDraftsViewModel) {
        guard !advanced else { return }
        // Every connected inbox, not `first`: the Google path can land more than one, and a
        // screen that asked one question about "your mail" has answered it for all of them.
        for email in connections.gmailAccounts {
            DraftsOnly.set(draftsOnly, for: email)
        }
        viewModel.isSaving = true
        Task { [weak self, weak viewModel] in
            guard let self else { return }
            let saved = await self.userProfile.flush()
            viewModel?.isSaving = false
            // One emission, after the write, carrying whether it landed — logging
            // before and again on failure would double every failed user in the funnel.
            guard !self.advanced else { return }
            self.advanced = true
            self.onNext()
        }
    }
}

#if DEBUG
import Prefire

#Preview("OnboardingDraftsView") {
    OnboardingDraftsViewComponent.make(onNext: {})
        .snapshot(delay: 0.5)
}
#endif
