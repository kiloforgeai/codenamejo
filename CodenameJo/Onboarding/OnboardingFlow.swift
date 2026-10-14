import AVFoundation
import Combine
import FactoryKit
import Speech
import SwiftUI

// Onboarding coordinator on a `NavigationStack`: openAIKey, welcome, connectTools, drafts,
// notifications, microphone, speech, preparing. Container view: NO #Preview.

/// Moving between steps and finishing. Which steps exist depends on whether the user is signed in;
/// going back is the `NavigationStack`'s job.
protocol OnboardingFlowHandler {
    func advance(viewModel: OnboardingFlowViewModel)
    func logStepViewed(viewModel: OnboardingFlowViewModel)
}

struct OnboardingFlow<Interactor: ViewWithModelLifecycleObserver<OnboardingFlowViewModel> & OnboardingFlowHandler>: View {
    @StateObject var viewModel: OnboardingFlowViewModel
    @StateObject var interactor: Interactor

    /// `viewModel.steps[0]` is the root and `path` holds everything pushed on top, so depth is
    /// `path.count`. The OpenAI key step is the root.
    var body: some View {
        NavigationStack(path: $viewModel.path) {
            stepView(for: viewModel.steps[0])
                .navigationDestination(for: OnboardingFlowViewModel.Step.self) {
                    stepView(for: $0)
                }
        }
        .bind(observer: interactor, viewModel: viewModel)
        .onChange(of: viewModel.path) { _, _ in interactor.logStepViewed(viewModel: viewModel) }
    }

    @ViewBuilder private func stepView(for step: OnboardingFlowViewModel.Step) -> some View {
        Group {
            switch step {
            case .welcome:
                OnboardingWelcomeViewComponent.make(
                    onNext: { interactor.advance(viewModel: viewModel) }
                )
                .navigationBarBackButtonHidden(true)

            case .connectTools:
                OnboardingConnectViewComponent.make(
                    onNext: { interactor.advance(viewModel: viewModel) }
                )

            case .openAIKey:
                OpenAIKeyView(onContinue: { interactor.advance(viewModel: viewModel) })

            case .drafts:
                OnboardingDraftsViewComponent.make(
                    onNext: { interactor.advance(viewModel: viewModel) }
                )

            case .notifications:
                OnboardingNotificationsViewComponent.make(
                    onNext: { interactor.advance(viewModel: viewModel) }
                )

            case .microphone:
                OnboardingMicrophoneViewComponent.make(
                    onNext: { interactor.advance(viewModel: viewModel) }
                )

            case .speech:
                OnboardingSpeechViewComponent.make(
                    onNext: { interactor.advance(viewModel: viewModel) }
                )

            case .preparing:
                OnboardingPreparingViewComponent.make(
                    onNext: { interactor.advance(viewModel: viewModel) }
                )
            }
        }
        // `.inline` and no `navigationTitle`, per the house rules: each screen names itself in its
        // content.
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Component

@MainActor
struct OnboardingFlowComponent {
    @ViewBuilder
    static func make() -> some View {
        OnboardingFlow(viewModel: OnboardingFlowViewModel(), interactor: OnboardingFlowInteractor())
    }
}

// MARK: - View model

@MainActor
final class OnboardingFlowViewModel: ViewModel {
    enum Step: Int, CaseIterable {
        case openAIKey, welcome, microphone, speech, connectTools,
             notifications, drafts, preparing

        static let flowSteps: [Step] = [
            // Before the welcome page's Google consent: connecting a mailbox starts AI mail
            // preparation, which the broker refuses until the phone holds a key.
            .openAIKey, .welcome, .microphone, .speech,
            .connectTools,
            .notifications,
            // .drafts,
            .preparing
        ]
    }

    /// The sequence, decided once by the interactor so signing in mid-flow can't shift indices.
    /// Never empty: the view indexes `steps[0]` for the stack's root.
    @Published var steps: [Step] = Step.flowSteps

    /// What the `NavigationStack` has pushed on top of the root; popping is the system's job.
    @Published var path: [Step] = []

    /// The step on screen: the last thing pushed, or the root when nothing is.
    var step: Step { path.last ?? steps[0] }
}

// MARK: - Interactor

@MainActor
final class OnboardingFlowInteractor: ViewModelInteractor<OnboardingFlowViewModel> {
    @Injected(\.backend) private var backend
    @Injected(\.connections) private var connections
    @Injected(\.userProfile) private var userProfile
    @Injected(\.voiceLauncher) private var voiceLauncher
    @Injected(\.realtimeService) private var realtimeService

    @CancellableBuilder
    override func onLoad(viewModel: OnboardingFlowViewModel) -> [AnyCancellable] {
        super.onLoad(viewModel: viewModel)
        // Sign-in is the second step, so the profile lands mid-flow. Everything in it
        // still applies; the onboarding gate inside it does not, until `finish` says so.
        userProfile.completesOnboarding = false
        let signedIn = backend.isSignedIn
        viewModel.steps = OnboardingFlowViewModel.Step.flowSteps
    }

    @CancellableBuilder
    override func onViewAppear(viewModel: OnboardingFlowViewModel) -> [AnyCancellable] {
        super.onViewAppear(viewModel: viewModel)
        logStepViewed(viewModel: viewModel)
    }

    /// One-shot: finishing twice would arm the first conversation twice.
    private var finished = false

    private func finish(viewModel: OnboardingFlowViewModel) {
        guard !finished else {
            RealtimeLog.log("onboarding: ignored a duplicate finish")
            return
        }
        finished = true
        // The flow is over, so an applied profile may decide this again.
        userProfile.completesOnboarding = true
        // If the preparing screen's session is up, ask it to speak; otherwise arm the greeting flag
        // for `CommandView`'s dial. Writing it after `speakOpening` fired would greet twice.
        if realtimeService.isConversing {
            realtimeService.speakOpening()
        } else {
            UserDefaults.standard.set(true, forKey: FullDuplexConfig.pendingGreetingKey)
        }
        voiceLauncher.requestLaunch(source: "onboarding")
        // The flag `RootView` gates on, through `OnboardingState`; `RootView`'s `@AppStorage`
        // observes it.
        OnboardingState.complete()
    }
}

extension OnboardingFlowInteractor: OnboardingFlowHandler {
    func advance(viewModel: OnboardingFlowViewModel) {
        // Guard: the drafts step's copy names Gmail Drafts. It only ever drops a later step, so the
        // snapshot on `steps` doesn't shift.
        if viewModel.step == .connectTools, connections.gmailAccounts.isEmpty {
            viewModel.steps.removeAll { $0 == .drafts }
        }
        // A permission already answered is dropped rather than shown and skipped.
        if AVAudioApplication.shared.recordPermission != .undetermined,
           !viewModel.path.contains(.microphone) {
            viewModel.steps.removeAll { $0 == .microphone }
        }
        if SFSpeechRecognizer.authorizationStatus() != .notDetermined,
           !viewModel.path.contains(.speech) {
            viewModel.steps.removeAll { $0 == .speech }
        }
        // Depth, not an index: the root isn't in `path`, so the step after the current
        // one is `steps[path.count + 1]`.
        let depth = viewModel.path.count
        guard depth < viewModel.steps.count - 1 else {
            finish(viewModel: viewModel)
            return
        }
        let next = viewModel.steps[depth + 1]
        // A screen rebuilt by the stack gets a fresh one-shot, so a step already on the stack is
        // never pushed twice here. Going back pops it, so forward works again.
        guard !viewModel.path.contains(next) else {
            RealtimeLog.log("onboarding: ignored a duplicate advance to \(next)")
            return
        }
        // The greeting flag, armed as the dial's screen is pushed.
        if next == .preparing {
            UserDefaults.standard.set(true, forKey: FullDuplexConfig.pendingGreetingKey)
        }
        viewModel.path.append(next)
    }

    /// The resolved sequence, logged once per move, so which steps a run has is readable off the
    /// device.
    private func logSteps(_ viewModel: OnboardingFlowViewModel) {
        RealtimeLog.log("onboarding: on \(viewModel.step) · "
            + "steps \(viewModel.steps.map(String.init(describing:)).joined(separator: " → "))")
    }

    func logStepViewed(viewModel: OnboardingFlowViewModel) {
        logSteps(viewModel)
    }
}
