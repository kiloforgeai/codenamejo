import Combine
import FactoryKit
import SwiftUI
import UIKit

@main
struct CodenameJoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    /// The user's chosen appearance, bound straight to the key the Settings picker
    /// writes so a change there re-renders the window immediately.
    @AppStorage(AppearanceSetting.storageKey) private var appearance = AppearanceSetting.system

    init() {
        // First line of our own code that runs, so this leg covers dyld, the Swift runtime and
        // framework loads. See `LaunchTiming`.
        LaunchTiming.mark("pre-main")
        // Before the upgrade reset: it signs out, and being signed in is how a key saved before
        // the note existed is told from one a deleted install left.
        OpenAIKeyService.dropIfLeftByDeletedInstall()
        PhoneAuthUpgrade.runIfNeeded {
            Container.shared.backend().signOut()
            RealtimeLog.log("auth: phone-only upgrade reset completed")
        }
        LaunchTiming.mark("app init")
    }

    var body: some Scene {
        WindowGroup {
            // Nothing injected: every screen resolves what it needs from the container.
            RootViewComponent.make()
                // The Home Screen note widget deep-links aurex://memo (see `MemoDeepLink`).
                // Controls can't open the app by URL; they run `StartVoiceSessionIntent`.
                .onOpenURL { url in
                    if Container.shared.shortcutActions().handle(url) {
                        return
                    }
                    if MemoDeepLink.matches(url) {
                        Container.shared.voiceLauncher().requestMemo()
                    }
                }
                // Applied here, at the window root, and nowhere else; `.system` resolves to `nil`.
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}


struct RootView<Interactor: ViewWithModelLifecycleObserver<RootViewModel> & RootViewHandler>: View {
    @StateObject var viewModel: RootViewModel
    @StateObject var interactor: Interactor
    @AppStorage(OnboardingState.storageKey) private var hasCompletedOnboarding = false
    /// The gate itself, observed rather than mirrored.
    @ObservedObject private var backend = Container.shared.backend()

    var body: some View {
        Group {
            if !hasCompletedOnboarding {
                OnboardingFlowComponent.make()
            } else if !backend.isSignedIn {
                Step1SignInViewComponent.make(onComplete: {})
            } else {
                ContentView()
            }
        }
        .bind(observer: interactor, viewModel: viewModel)
    }
}

// MARK: - Component

@MainActor
struct RootViewComponent {
    @ViewBuilder
    static func make() -> some View {
        RootView(viewModel: RootViewModel(), interactor: RootViewInteractor())
    }
}

// MARK: - View model

/// The root has no presentation state of its own; the view model gives the interactor somewhere
/// to report to.
@MainActor
final class RootViewModel: ViewModel {}

/// What happens once, at launch.
protocol RootViewHandler {}

// MARK: - Interactor

@MainActor
final class RootViewInteractor: ViewModelInteractor<RootViewModel>, RootViewHandler {
    /// What a call needs started, wherever the launch came from. `userProfile` was
    /// injected here and is not any more — it starts through this.
    @Injected(\.accountBootstrap) private var accountBootstrap
    @Injected(\.backend) private var backend
    @Injected(\.connectivity) private var connectivity
    @Injected(\.memoQueue) private var memoQueue
    @Injected(\.memoTranscriber) private var memoTranscriber

    @CancellableBuilder
    override func onViewAppear(viewModel: RootViewModel) -> [AnyCancellable] {
        super.onViewAppear(viewModel: viewModel)
        // The root has drawn, so the sign-in gate has resolved and a first frame is on screen.
        LaunchTiming.mark("first frame")
        // What a call needs started, shared with CarPlay launches, which never reach this method.
        accountBootstrap.start()
        // The account's cached answers, refreshed on launch and on sign-in, so they are fresh even
        // if Settings is never opened.
        backend.$isSignedIn
            .removeDuplicates()
            .filter { $0 }
            .sink { [backend] _ in
                _ = backend.sessionUser()
            }

        // The offline note path starts here and nowhere else. The `$isOnline` sink stays inside the
        // `if` because `isOnline` starts true.
        if VoiceSettings.voiceNotes {
            // Three things, in the order they depend on each other.
            connectivity.start()
            // Reconcile before anything else touches the queue, so a send in flight when the app
            // died isn't sent twice.
            Task { await self.memoQueue.reconcile() }
            // Fetch the speech model now, while there is probably a network, and transcribe any
            // notes that were waiting for it.
            Task {
                await self.memoTranscriber.ensureModel()
                // Transcribing ends by draining, so this covers both "a note was waiting
                // on the model" and "a note was waiting on a network" in one pass.
                await self.memoQueue.transcribePending()
            }
            // The network came back: drain waiting notes. `removeDuplicates` because the monitor
            // republishes on any path change, and a Wi-Fi-to-cell switch must not restart a drain.
            connectivity.$isOnline
                .removeDuplicates()
                .filter { $0 }
                .sink { [memoQueue, memoTranscriber] _ in
                    Task {
                        // The model may still be missing if the app has only ever run offline.
                        await memoTranscriber.ensureModel()
                        await memoQueue.transcribePending()
                    }
                }
        }
    }
}
