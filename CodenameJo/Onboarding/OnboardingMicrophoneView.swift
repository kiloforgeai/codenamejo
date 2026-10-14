import AVFoundation
import Combine
import FactoryKit
import SwiftUI

/// The microphone ask, as its own step, just before `finish` arms the first call. A "Don't Allow"
/// is only recoverable in iOS Settings, so the screen explains it first. No skip, no back.
protocol OnboardingMicrophoneViewHandler {
    func allow(viewModel: OnboardingMicrophoneViewModel)
}

struct OnboardingMicrophoneView<Interactor: ViewWithModelLifecycleObserver<OnboardingMicrophoneViewModel> & OnboardingMicrophoneViewHandler>: View {
    @StateObject var viewModel: OnboardingMicrophoneViewModel
    @StateObject var interactor: Interactor

    /// The scaffold with no title or subtitle, so the copy is centred under the art.
    var body: some View {
        OnboardingScaffold {
            VStack(spacing: 0) {
                // Two equal spacers centre the art and copy above the footer.
                Spacer(minLength: 12)
                listeningState
                copy
                    .padding(.top, 28)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, MicrophoneLayout.gutter)
        } footer: {
            OnboardingPrimaryButton(
                title: "Continue",
                isEnabled: !viewModel.isRequesting,
                accessibilityID: "onboarding_microphone_allow_button"
            ) {
                interactor.allow(viewModel: viewModel)
            }
            .padding(.horizontal, MicrophoneLayout.gutter)
            .padding(.bottom, 8)
        }
        // The notifications ask behind this one is spent; hiding the button hides the edge swipe
        // too.
        .navigationBarBackButtonHidden(true)
        .bind(observer: interactor, viewModel: viewModel)
    }

    // MARK: - The art

    /// The exact production state, rather than an abstract microphone illustration, so
    /// this screen also teaches the visual cue people will rely on after onboarding.
    private var listeningState: some View {
        VStack(spacing: 22) {
            VoiceOrb(
                state: .listening,
                muted: false,
                holding: false,
                diameter: MicrophoneLayout.orbDiameter
            )
            .allowsHitTesting(false)

            HStack(spacing: 8) {
                Circle()
                    .fill(OrbMood.listening.tint)
                    .frame(width: 8, height: 8)

                Text("ON · LISTENING")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(OnboardingTheme.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preview of Jo on and listening")
        }
    }

    // MARK: - The copy

    private var copy: some View {
        VStack(spacing: 12) {
            Text("Jo stays on")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(OnboardingTheme.textPrimary)
                .multilineTextAlignment(.center)

            Text("When Jo glows gold, it’s listening. When the glow is gone, Jo is off. Continue to allow microphone access.")
                .font(.system(size: 15))
                .foregroundStyle(OnboardingTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A generic view cannot hold static storage, so the screen's constants live here —
/// same arrangement as `DemoLayout` and `CommandLayout`.
private enum MicrophoneLayout {
    static let gutter: CGFloat = 24
    static let orbDiameter: CGFloat = 136
}

// MARK: - Component

@MainActor
struct OnboardingMicrophoneViewComponent {
    @ViewBuilder
    static func make(onNext: @escaping () -> Void) -> some View {
        OnboardingMicrophoneView(
            viewModel: OnboardingMicrophoneViewModel(),
            interactor: OnboardingMicrophoneViewInteractor(onNext: onNext)
        )
    }
}

// MARK: - View model

@MainActor
final class OnboardingMicrophoneViewModel: ViewModel {
    /// True from the tap until both alerts have been answered; the alerts are the feedback.
    @Published var isRequesting = false
}

// MARK: - Interactor

@MainActor
final class OnboardingMicrophoneViewInteractor: ViewModelInteractor<OnboardingMicrophoneViewModel> {
    /// Through `voiceCall.withMicPermission`, which every mic path uses and which also asks for
    /// speech recognition afterwards.
    @Injected(\.voiceCall) private var voiceCall

    private let onNext: () -> Void
    /// One-shot: the auto-advance and a second tap would otherwise both advance and re-arm the
    /// call.
    private var advanced = false

    init(onNext: @escaping () -> Void) {
        self.onNext = onNext
        super.init()
    }

    @CancellableBuilder
    override func onViewAppear(viewModel: OnboardingMicrophoneViewModel) -> [AnyCancellable] {
        super.onViewAppear(viewModel: viewModel)
        // Already granted: skip the screen, there is nothing left to ask.
        if AVAudioApplication.shared.recordPermission == .granted {
            advanceOnce()
        }
    }

    private func advanceOnce() {
        guard !advanced else { return }
        advanced = true
        onNext()
    }
}

extension OnboardingMicrophoneViewInteractor: OnboardingMicrophoneViewHandler {
    /// Advance on either answer: the alert can't be shown again. A denial resurfaces at the dial as
    /// `CommandView`'s "Microphone Access Needed" sheet.
    func allow(viewModel: OnboardingMicrophoneViewModel) {
        viewModel.isRequesting = true
        voiceCall.requestMicrophoneOnly(
            onDenied: { [weak self, weak viewModel] in
                viewModel?.isRequesting = false
                self?.advanceOnce()
            }
        ) { [weak self, weak viewModel] in
            viewModel?.isRequesting = false
            self?.advanceOnce()
        }
    }
}

#if DEBUG
import Prefire

// Prefire-ignored: a permission screen isn't an App Store screenshot. `PreviewLoader` matches the
// marker's literal text, so naming it inside a preview block you want kept disables that block.

#Preview("OnboardingMicrophoneView") {
    OnboardingMicrophoneViewComponent.make(onNext: {})
        .prefireIgnored()
}

// The state between the tap and the answer: the button disabled while the system alerts are up.
#Preview("OnboardingMicrophoneView — asking") {
    OnboardingMicrophoneView(
        viewModel: {
            let viewModel = OnboardingMicrophoneViewModel()
            viewModel.isRequesting = true
            return viewModel
        }(),
        interactor: OnboardingMicrophoneViewInteractor(onNext: {})
    )
    .prefireIgnored()
}
#endif
