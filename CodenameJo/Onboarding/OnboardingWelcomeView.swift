import AVFoundation
import AVKit
import Combine
import FactoryKit
import Speech
import SwiftUI

/// One screen in four phases: the value statement, the two voice permissions, the say-it
/// beat, then the ask for the inbox, whose Google consent also signs in.
protocol OnboardingWelcomeViewHandler {
    func startSignIn(viewModel: OnboardingWelcomeViewModel)
    func fixHearing(viewModel: OnboardingWelcomeViewModel)
    func allowMicrophone(viewModel: OnboardingWelcomeViewModel)
    func allowSpeech(viewModel: OnboardingWelcomeViewModel)
    func askForInbox(viewModel: OnboardingWelcomeViewModel)
    func connectGoogle(viewModel: OnboardingWelcomeViewModel)
    #if DEBUG
    /// Local builds only: walk past the Google connect without an account, so the
    /// rest of the flow can be exercised on a session that signed in another way.
    func skipConnect(viewModel: OnboardingWelcomeViewModel)
    #endif
}

struct OnboardingWelcomeView<Interactor: ViewWithModelLifecycleObserver<OnboardingWelcomeViewModel> & OnboardingWelcomeViewHandler>: View {
    @StateObject var viewModel: OnboardingWelcomeViewModel
    @StateObject var interactor: Interactor
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if viewModel.phase == .connect {
                    connectState
                } else if viewModel.phase == .sayIt {
                    OnboardingSayItViewComponent.make(
                        onNext: { interactor.askForInbox(viewModel: viewModel) }
                    )
                } else if viewModel.phase == .priming {
                    HStack(spacing: 20) {
                        VoiceOrb(state: viewModel.joSpeaking ? .responding : .disconnected, muted: false, holding: false, diameter: 66)
                            .allowsHitTesting(false)
                        SpeechIndicator(metering: viewModel.clipMetering)
                            .accessibilityLabel("Jo is speaking")
                    }
                    .padding(.top, 30)
                    Text("“I'm Jo. I run your workday.\nOnly thing is, I can't hear you yet.”")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(OnboardingTheme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 28)
                    Spacer()
                    VStack(spacing: 12) {
                        PermissionRow(
                            icon: "mic",
                            title: "Allow microphone",
                            subtitle: "To hear your voice",
                            granted: viewModel.micGranted,
                            isEnabled: viewModel.permissionsUnlocked && !viewModel.micAnswered && !viewModel.isAsking,
                            accessibilityID: "onboarding_welcome_allow_microphone"
                        ) {
                            interactor.allowMicrophone(viewModel: viewModel)
                        }
                        PermissionRow(
                            icon: "waveform",
                            title: "Allow speech recognition",
                            subtitle: "To transcribe on device",
                            granted: viewModel.speechGranted,
                            isEnabled: viewModel.permissionsUnlocked && !viewModel.speechAnswered && !viewModel.isAsking,
                            accessibilityID: "onboarding_welcome_allow_speech"
                        ) {
                            interactor.allowSpeech(viewModel: viewModel)
                        }
                    }
                    .padding(.bottom, 20)
                } else {
                    // No trailing spacer: the orb and the copy sit on the bottom of the
                    // clip, just above the CTA, rather than floating in its middle.
                    Spacer()
                    VoiceOrb(state: .disconnected, muted: false, holding: false, diameter: 132)
                        .frame(maxWidth: .infinity)
                        .allowsHitTesting(false)
                        .padding(.bottom, 28)
                    Text("A hands-free assistant\nfor your workday.")
                        .font(.system(size: 34, weight: .semibold))
                        .tracking(-1.2)
                        .lineSpacing(-1)
                        .foregroundStyle(OnboardingTheme.textPrimary)
                    Text("“Reply to Sarah, three o'clock works.” Just talk.")
                        .font(.system(size: 15))
                        .foregroundStyle(OnboardingTheme.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                        .padding(.bottom, 20)
                }
            }
            .padding(.horizontal, viewModel.phase == .sayIt ? 0 : WelcomeLayout.gutter)

            if viewModel.phase == .connect {
                SelectAllHelpButton { viewModel.showingSelectAllVideo = true }
                    .padding(.bottom, 36)
            }
            if viewModel.phase != .sayIt {
                OnboardingPrimaryButton(
                    title: buttonTitle,
                    isEnabled: !viewModel.isAsking,
                    accessibilityID: "onboarding_welcome_get_started"
                ) {
                    switch viewModel.phase {
                    case .connect: interactor.connectGoogle(viewModel: viewModel)
                    case .priming: interactor.fixHearing(viewModel: viewModel)
                    default: interactor.startSignIn(viewModel: viewModel)
                    }
                }
                .padding(.horizontal, WelcomeLayout.gutter)
                .padding(.bottom, viewModel.phase == .connect ? 14 : 8)
            }
            if viewModel.phase == .connect {
                VStack(spacing: 6) {
                    Text("Any account works. Disconnect anytime.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                    PrivacyDisclosureTeaser { viewModel.showingPrivacy = true }
                    #if DEBUG
                    Button("Skip connecting (debug)") { interactor.skipConnect(viewModel: viewModel) }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OnboardingTheme.textSecondary)
                        .padding(.top, 4)
                        .accessibilityIdentifier("onboarding_connect_skip_debug")
                    #endif
                }
                .padding(.bottom, 8)
                if let error = viewModel.error {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.error)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, WelcomeLayout.gutter)
                        .padding(.bottom, 8)
                }
            }
        }
        // The video reads as a dark ground, so the first phase borrows the dark palette
        // whatever the phone is set to — white headline, white CTA.
        .environment(\.colorScheme, viewModel.phase == .start ? .dark : colorScheme)
        // The environment override alone leaves the status bar dark-on-video.
        .preferredColorScheme(viewModel.phase == .start ? .dark : nil)
        .background {
            if viewModel.phase == .start {
                welcomeBackdrop
            } else {
                OnboardingTheme.background.ignoresSafeArea()
            }
        }
        .sheet(isPresented: $viewModel.showingSelectAllVideo) {
            SelectAllVideoSheet()
        }
        .sheet(isPresented: $viewModel.showingPrivacy) {
            PrivacyDisclosureSheet()
        }
        .alert("Not hearing Jo?", isPresented: $viewModel.showVolumeAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Turn on or turn up your volume.")
        }
        .bind(observer: interactor, viewModel: viewModel)
    }

    /// Full-bleed clip under a scrim that darkens hardest where the copy and the CTA sit.
    private var welcomeBackdrop: some View {
        // Overlays rather than a ZStack: every layer takes the black ground's size, so an
        // aspect-filled image or clip crops to the screen instead of widening the stack.
        Color.black
            .overlay {
                // Under the clip so the first frame is up before playback starts, and so a
                // snapshot that never decodes a frame still gets the picture.
                if let poster = UIImage(named: "welcomeloopposter") {
                    Image(uiImage: poster)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay { LoopingVideoBackground(resource: "welcomeloop") }
            .overlay {
                LinearGradient(
                    // The ramp starts well above the orb, so its shadow sits on an already-dark
                    // ground; the top half is left clear for the clip.
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.50),
                        .init(color: .black.opacity(0.62), location: 0.60),
                        .init(color: .black.opacity(0.85), location: 0.70),
                        .init(color: .black.opacity(0.95), location: 0.79),
                        .init(color: .black.opacity(0.99), location: 0.89),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipped()
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    private var buttonTitle: String {
        switch viewModel.phase {
        case .start: return "Start"
        case .priming: return "Let's fix that"
        case .sayIt: return ""
        case .connect: return "Connect Gmail"
        }
    }

    private var connectState: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 20) {
                VoiceOrb(state: viewModel.joSpeaking ? .responding : .disconnected, muted: false, holding: false, diameter: 66)
                    .allowsHitTesting(false)
                SpeechIndicator(metering: viewModel.clipMetering)
                    .accessibilityLabel("Jo is speaking")
            }
            .padding(.top, 30)
            // Jo can delete mail, so the promise is permission, not an absolute never.
            // `jo3.wav` speaks this line — re-record it whenever this text changes.
            Text("“First I'd need your inbox.\n\nI'll read it, file the junk, and reply to whatever you tell me to.\n\nI never send anything you didn't ask for, and I only delete with your permission.”")
                .foregroundStyle(OnboardingTheme.textPrimary)
                .font(.system(size: 22, weight: .semibold))
                .lineSpacing(3)
                .padding(.top, 28)
            Spacer()
        }
    }
}

/// A glowing "show me" pill: the one tap on Google's consent sheet people miss.
private struct SelectAllHelpButton: View {
    let action: () -> Void
    @State private var glowing = false

    var body: some View {
        Button(action: action) {
            Label("Show me how", systemImage: "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OnboardingTheme.textPrimary)
                .padding(.horizontal, 18)
                .frame(height: 40)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: Theme.accent.opacity(glowing ? 0.9 : 0.35), radius: glowing ? 18 : 8)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                glowing = true
            }
        }
        .accessibilityIdentifier("onboarding_select_all_help")
    }
}

/// The bundled clip of Google's consent sheet, looping and muted.
private struct SelectAllVideoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Example only")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.textTertiary)
                Text("On Google's screen, tap Select all, then Continue")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Text("This is a demo video. Nothing here is tappable.")
                    .font(.system(size: 14))
                    .foregroundStyle(OnboardingTheme.textSecondary)
            }
            .padding(.top, 24)
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(.horizontal, 40)
                    .allowsHitTesting(false)
            }
            Spacer(minLength: 0)
            OnboardingPrimaryButton(title: "Got it", accessibilityID: "onboarding_select_all_done") {
                dismiss()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .background(OnboardingTheme.background.ignoresSafeArea())
        .onAppear {
            guard player == nil, let url = Bundle.main.url(forResource: "gmailselection", withExtension: "mov") else { return }
            let item = AVPlayerItem(url: url)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            looper = AVPlayerLooper(player: queue, templateItem: item)
            queue.play()
            player = queue
        }
        .onDisappear { player?.pause() }
    }
}

/// The two grants behind "I can't hear you yet", named before the system alerts appear. A row
/// disables once answered, because iOS raises each alert once per install.
private struct PermissionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let granted: Bool
    var isEnabled: Bool = true
    var accessibilityID: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) { content }
            .buttonStyle(PermissionRowButtonStyle())
            .disabled(!isEnabled)
            .accessibilityIdentifier(accessibilityID)
    }

    private var content: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(OnboardingTheme.textPrimary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(OnboardingTheme.textSecondary)
            }
            Spacer()
            Image(systemName: "checkmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(OnboardingTheme.accent)
                .opacity(granted ? 1 : 0)
                .scaleEffect(granted ? 1 : 0.6)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(OnboardingTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .animation(.spring(duration: 0.35), value: granted)
    }
}

/// Press feedback for the permission rows; `.plain` gives none.
private struct PermissionRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private enum WelcomeLayout {
    static let gutter: CGFloat = 24
}

// MARK: - Component

@MainActor
struct OnboardingWelcomeViewComponent {
    @ViewBuilder
    static func make(onNext: @escaping () -> Void) -> some View {
        OnboardingWelcomeView(
            viewModel: OnboardingWelcomeViewModel(),
            interactor: OnboardingWelcomeViewInteractor(onNext: onNext)
        )
    }
}

// MARK: - View model

@MainActor
final class OnboardingWelcomeViewModel: ViewModel {
    enum Phase { case start, priming, sayIt, connect }
    @Published var phase: Phase = .start
    @Published var isAsking = false
    @Published var joSpeaking = false
    @Published var micGranted = false
    @Published var speechGranted = false
    /// Answered either way — `granted` alone cannot tell an untouched row from a denied
    /// one, and only an untouched row is still worth a tap.
    @Published var micAnswered = false
    @Published var speechAnswered = false
    /// The permission rows stay shut until Jo is halfway through saying what they are for.
    @Published var permissionsUnlocked = false
    /// Level feed for the priming screen's thread, driven by the intro clip rather
    /// than a call. Held here so only `SpeechIndicator` pays the 10 Hz invalidation.
    let clipMetering = VoiceMetering()
    @Published var error: String?
    @Published var showingSelectAllVideo = false
    @Published var showingPrivacy = false
    /// Raised when the output volume is near zero as one of Jo's clips starts.
    @Published var showVolumeAlert = false
}

// MARK: - Interactor

@MainActor
final class OnboardingWelcomeViewInteractor: ViewModelInteractor<OnboardingWelcomeViewModel> {
    @Injected(\.voiceCall) private var voiceCall
    @Injected(\.onboardingAudioQueue) private var audioQueue
    private let onNext: () -> Void
    private var player: AVAudioPlayer?
    private var playbackStart: Task<Void, Never>?
    private var speakingTimer: Task<Void, Never>?
    private var unlockTimer: Task<Void, Never>?
    private let signInModel = Step1SignInViewModel()
    private lazy var signIn = Step1SignInViewInteractor(onComplete: { [weak self] in self?.onNext() })
    private var signInObservers: [AnyCancellable] = []

    init(onNext: @escaping () -> Void) {
        self.onNext = onNext
        super.init()
    }

    override func onViewDisappear(viewModel: OnboardingWelcomeViewModel) {
        super.onViewDisappear(viewModel: viewModel)
        stopClip(viewModel: viewModel)
        player = nil
    }
}

extension OnboardingWelcomeViewInteractor: OnboardingWelcomeViewHandler {
    /// Sign-in happens at the end, in the Google consent that connects the inbox.
    func startSignIn(viewModel: OnboardingWelcomeViewModel) {
        viewModel.phase = .priming
        primeVoice(viewModel: viewModel)
    }

    private func primeVoice(viewModel: OnboardingWelcomeViewModel) {
        syncPermissions(viewModel)
        play("jo1", viewModel: viewModel)
    }

    /// Read back off the system rather than inferred from a callback, so a grant, a denial
    /// and an ask that raised no alert all land the same way.
    private func syncPermissions(_ viewModel: OnboardingWelcomeViewModel?) {
        guard let viewModel else { return }
        let mic = AVAudioApplication.shared.recordPermission
        viewModel.micGranted = mic == .granted
        viewModel.micAnswered = mic != .undetermined
        let speech = SFSpeechRecognizer.authorizationStatus()
        viewModel.speechGranted = speech == .authorized
        viewModel.speechAnswered = speech != .notDetermined
    }

    /// Raises the alert only when unanswered, then continues either way — so a caller can
    /// ask blind, and `microphoneAsked` is logged once per install, not once per route.
    private func askMicrophone(_ viewModel: OnboardingWelcomeViewModel?, then: @escaping () -> Void) {
        guard AVAudioApplication.shared.recordPermission == .undetermined else {
            then()
            return
        }
        voiceCall.requestMicrophoneOnly(
            onDenied: { [weak self, weak viewModel] in
                self?.syncPermissions(viewModel)
                then()
            }
        ) { [weak self, weak viewModel] in
            self?.syncPermissions(viewModel)
            then()
        }
    }

    /// The speech half of `askMicrophone`, with the same already-answered no-op.
    private func askSpeech(_ viewModel: OnboardingWelcomeViewModel?, then: @escaping () -> Void) {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else {
            then()
            return
        }
        voiceCall.withSpeechPermission { [weak self, weak viewModel] in
            let granted = SFSpeechRecognizer.authorizationStatus() == .authorized
            self?.syncPermissions(viewModel)
            then()
        }
    }

    func askForInbox(viewModel: OnboardingWelcomeViewModel) {
        viewModel.phase = .connect
        play("jo3", viewModel: viewModel)
    }

    func connectGoogle(viewModel: OnboardingWelcomeViewModel) {
        stopClip(viewModel: viewModel)
        if signInObservers.isEmpty {
            signInObservers = [
                signInModel.$isWorking.sink { [weak viewModel] in viewModel?.isAsking = $0 },
                signInModel.$error.sink { [weak viewModel] in viewModel?.error = $0 },
            ]
        }
        signIn.handleGoogle(viewModel: signInModel)
    }

    private func play(_ clip: String, viewModel: OnboardingWelcomeViewModel) {
        playbackStart?.cancel()
        speakingTimer?.cancel()
        unlockTimer?.cancel()
        player?.stop()
        guard let url = Bundle.main.url(forResource: clip, withExtension: "wav") else {
            viewModel.permissionsUnlocked = true
            return
        }
        playbackStart = Task { [weak self, weak viewModel] in
            guard !Task.isCancelled, let self, let viewModel else { return }
            do {
                try await audioQueue.run("onboarding playback-only session") {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: .spokenAudio)
                    try session.setActive(true)
                }
                guard !Task.isCancelled else { return }
                let player = try AVAudioPlayer(contentsOf: url)
                self.player = player
                if OnboardingVolume.isTooLow { viewModel.showVolumeAlert = true }
                player.play()
                RealtimeLog.log("onboarding: \(clip) playback-only — microphone input disabled")
                speakingTimer = JoClipMeter.feed(player, into: viewModel.clipMetering) { [weak viewModel] in
                    viewModel?.joSpeaking = $0
                }
                unlockTimer = Task { [weak viewModel] in
                    try? await Task.sleep(for: .seconds(player.duration / 2))
                    guard !Task.isCancelled else { return }
                    viewModel?.permissionsUnlocked = true
                }
            } catch {
                guard !Task.isCancelled else { return }
                RealtimeLog.log("onboarding: intro clip failed: \(error.localizedDescription)")
                viewModel.permissionsUnlocked = true
            }
        }
    }

    private func stopClip(viewModel: OnboardingWelcomeViewModel) {
        playbackStart?.cancel()
        playbackStart = nil
        speakingTimer?.cancel()
        unlockTimer?.cancel()
        viewModel.permissionsUnlocked = true
        player?.stop()
        viewModel.joSpeaking = false
        speakingTimer = JoClipMeter.drain(viewModel.clipMetering)
    }

    /// Whatever is still unanswered, one alert at a time, then the say-it state. Both asks
    /// no-op on a permission a row tap already spent.
    func fixHearing(viewModel: OnboardingWelcomeViewModel) {
        guard !viewModel.isAsking else { return }
        viewModel.isAsking = true
        stopClip(viewModel: viewModel)
        // The beat below lets a check be seen landing; there is none when both rows are done.
        let raising = AVAudioApplication.shared.recordPermission == .undetermined
            || SFSpeechRecognizer.authorizationStatus() == .notDetermined
        askMicrophone(viewModel) { [weak self, weak viewModel] in
            self?.askSpeech(viewModel) {
                Task { @MainActor in
                    if raising { try? await Task.sleep(for: .milliseconds(600)) }
                    viewModel?.isAsking = false
                    viewModel?.phase = .sayIt
                }
            }
        }
    }

    /// One row, one alert. `isAsking` holds the CTA and the other row, so two alerts can
    /// never be in flight at once.
    func allowMicrophone(viewModel: OnboardingWelcomeViewModel) {
        guard !viewModel.isAsking else { return }
        viewModel.isAsking = true
        stopClip(viewModel: viewModel)
        askMicrophone(viewModel) { [weak self, weak viewModel] in self?.finishRowTap(viewModel) }
    }

    func allowSpeech(viewModel: OnboardingWelcomeViewModel) {
        guard !viewModel.isAsking else { return }
        viewModel.isAsking = true
        stopClip(viewModel: viewModel)
        askSpeech(viewModel) { [weak self, weak viewModel] in self?.finishRowTap(viewModel) }
    }

    /// Both checks landed turns the page; a denial leaves "Let's fix that" as the way on.
    /// `isAsking` holds through the beat so the CTA cannot advance a second time.
    private func finishRowTap(_ viewModel: OnboardingWelcomeViewModel?) {
        guard let viewModel else { return }
        guard viewModel.micGranted, viewModel.speechGranted else {
            viewModel.isAsking = false
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            viewModel.isAsking = false
            viewModel.phase = .sayIt
        }
    }

    #if DEBUG
    func skipConnect(viewModel: OnboardingWelcomeViewModel) {
        stopClip(viewModel: viewModel)
        onNext()
    }
    #endif
}

#if DEBUG
import Prefire

#Preview("OnboardingWelcomeView") {
    OnboardingWelcomeViewComponent.make(onNext: {})
        .snapshot(delay: 0.5)
}
#endif
