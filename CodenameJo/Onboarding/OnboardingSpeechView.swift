import Combine
import FactoryKit
import Speech
import SwiftUI

/// The speech-recognition ask, on its own screen after the microphone. It never blocks: a denial
/// costs the transcript and History, not the call, and Continue advances on either answer.
protocol OnboardingSpeechViewHandler {
    func allow(viewModel: OnboardingSpeechViewModel)
}

struct OnboardingSpeechView<Interactor: ViewWithModelLifecycleObserver<OnboardingSpeechViewModel> & OnboardingSpeechViewHandler>: View {
    @StateObject var viewModel: OnboardingSpeechViewModel
    @StateObject var interactor: Interactor

    /// Titleless scaffold, art over centred copy — the microphone screen's layout,
    /// because these two are one pair.
    var body: some View {
        OnboardingScaffold {
            VStack(spacing: 0) {
                Spacer(minLength: 12)
                PrioritizedListArt()
                copy
                    .padding(.top, 28)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, SpeechLayout.gutter)
        } footer: {
            OnboardingPrimaryButton(
                title: "Continue",
                isEnabled: !viewModel.isRequesting,
                accessibilityID: "onboarding_speech_allow_button"
            ) {
                interactor.allow(viewModel: viewModel)
            }
            .padding(.horizontal, SpeechLayout.gutter)
            .padding(.bottom, 8)
        }
        // The microphone ask behind this one is spent, so returning to it offers nothing
        // — same reason that screen hides its own button.
        .navigationBarBackButtonHidden(true)
        .bind(observer: interactor, viewModel: viewModel)
    }

    private var copy: some View {
        VStack(spacing: 12) {
            Text("Your to-do list, prioritized")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(OnboardingTheme.textPrimary)
                .multilineTextAlignment(.center)

            Text("Jo builds it around your Gmail, Calendar, and automations, then helps you work through it by voice. Continue to allow speech recognition.")
                .font(.system(size: 15))
                .foregroundStyle(OnboardingTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A generic view cannot hold static storage, so the screen's constants live here.
private enum SpeechLayout {
    static let gutter: CGFloat = 24
    static let listWidth: CGFloat = 310
}

// MARK: - Art

/// A prioritized list: one done row, one being handled by voice, one queued.
private struct PrioritizedListArt: View {
    private enum RowState: Equatable {
        case done, active, queued
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("PRIORITIZED FOR YOU")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(OnboardingTheme.textSecondary)

                Spacer(minLength: 8)

                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.accent)
                Text("2 OF 3")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.textSecondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)

            Divider()

            priorityRow(
                position: 1,
                symbol: "envelope.fill",
                title: "Reply to design review",
                source: "Gmail",
                state: .done
            )
            Divider().padding(.leading, 54)
            priorityRow(
                position: 2,
                symbol: "calendar",
                title: "Prep for customer call",
                source: "Calendar · 10:30 AM",
                state: .active
            )
            Divider().padding(.leading, 54)
            priorityRow(
                position: 3,
                symbol: "bolt.fill",
                title: "Send weekly update",
                source: "Automation",
                state: .queued
            )
        }
        .frame(maxWidth: SpeechLayout.listWidth)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OnboardingTheme.background)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 16, y: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Prioritized to-do list. Gmail reply complete. Customer call preparation "
                + "active by voice. Weekly update automation next."
        )
    }

    private func priorityRow(
        position: Int,
        symbol: String,
        title: String,
        source: String,
        state: RowState
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(state == .active
                        ? OnboardingTheme.accent.opacity(0.22)
                        : OnboardingTheme.surface)
                    .frame(width: 30, height: 30)

                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(OnboardingTheme.textSecondary)
                } else {
                    Text("\(position)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OnboardingTheme.textPrimary)
                }
            }

            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(OnboardingTheme.textPrimary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OnboardingTheme.textPrimary)
                    .lineLimit(1)
                Text(source)
                    .font(.system(size: 11))
                    .foregroundStyle(OnboardingTheme.textSecondary)
            }

            Spacer(minLength: 4)

            if state == .active {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.accent)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .background(state == .active ? OnboardingTheme.accent.opacity(0.08) : Color.clear)
        .opacity(state == .done ? 0.62 : 1)
    }
}

// MARK: - Component

@MainActor
struct OnboardingSpeechViewComponent {
    @ViewBuilder
    static func make(onNext: @escaping () -> Void) -> some View {
        OnboardingSpeechView(
            viewModel: OnboardingSpeechViewModel(),
            interactor: OnboardingSpeechViewInteractor(onNext: onNext)
        )
    }
}

// MARK: - View model

@MainActor
final class OnboardingSpeechViewModel: ViewModel {
    /// True from the tap until the alert is answered. The alert is the feedback, so
    /// there is nothing else on the screen to say so.
    @Published var isRequesting = false
}

// MARK: - Interactor

@MainActor
final class OnboardingSpeechViewInteractor: ViewModelInteractor<OnboardingSpeechViewModel> {
    /// `voiceCall` rather than `SFSpeechRecognizer` directly, for the reason the
    /// microphone step gives: one place asks, and it is the one every other path uses.
    @Injected(\.voiceCall) private var voiceCall

    private let onNext: () -> Void
    private var advanced = false

    init(onNext: @escaping () -> Void) {
        self.onNext = onNext
        super.init()
    }

    @CancellableBuilder
    override func onViewAppear(viewModel: OnboardingSpeechViewModel) -> [AnyCancellable] {
        super.onViewAppear(viewModel: viewModel)
        // Already answered: there is nothing left to ask.
        if SFSpeechRecognizer.authorizationStatus() != .notDetermined {
            advanceOnce()
        }
    }

    private func advanceOnce() {
        guard !advanced else { return }
        advanced = true
        onNext()
    }
}

extension OnboardingSpeechViewInteractor: OnboardingSpeechViewHandler {
    func allow(viewModel: OnboardingSpeechViewModel) {
        viewModel.isRequesting = true
        voiceCall.withSpeechPermission { [weak self, weak viewModel] in
            viewModel?.isRequesting = false
            let granted = SFSpeechRecognizer.authorizationStatus() == .authorized
            self?.advanceOnce()
        }
    }
}

#if DEBUG
import Prefire

// Prefire-ignored for the reason in `OnboardingMicrophoneView`'s previews note.

#Preview("OnboardingSpeechView") {
    OnboardingSpeechViewComponent.make(onNext: {})
        .prefireIgnored()
}
#endif
