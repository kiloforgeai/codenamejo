import AVFoundation
import Combine
import FactoryKit
import Speech
import SwiftUI
import UserNotifications

/// The notification permission step, on every path. "Not now" advances without showing the system
/// alert, so the one-time ask stays available later from Settings.
protocol OnboardingNotificationsViewHandler {
    func enable(viewModel: OnboardingNotificationsViewModel)
    func skip(viewModel: OnboardingNotificationsViewModel)
}

struct OnboardingNotificationsView<Interactor: ViewWithModelLifecycleObserver<OnboardingNotificationsViewModel> & OnboardingNotificationsViewHandler>: View {
    @StateObject var viewModel: OnboardingNotificationsViewModel
    @StateObject var interactor: Interactor

    /// Jo asks herself, over a phone showing the notification she wants to send. Skip is in the
    /// navbar, away from the primary button, since this permission can only be asked once.
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 20) {
                    VoiceOrb(state: viewModel.joSpeaking ? .responding : .disconnected, muted: false, holding: false, diameter: 66)
                        .allowsHitTesting(false)
                    SpeechIndicator(metering: viewModel.clipMetering)
                        .accessibilityLabel("Jo is speaking")
                }
                .padding(.top, 30)
                Text("“I'm going to go through your inbox and find any relevant to-dos. Can I notify you when I'm done?”")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 28)
                LockScreenMockup()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 24)
            }
            .padding(.horizontal, 24)
            OnboardingPrimaryButton(
                title: "Turn on notifications",
                isEnabled: !viewModel.isRequesting,
                accessibilityID: "onboarding_notifications_enable_button"
            ) {
                interactor.enable(viewModel: viewModel)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .background(OnboardingTheme.background.ignoresSafeArea())
        // No back button: Skip is the way past a one-shot ask, and hiding the chevron hides the
        // edge swipe.
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Skip") { interactor.skip(viewModel: viewModel) }
                    .font(.system(size: 15))
                    .foregroundStyle(OnboardingTheme.textSecondary)
                    .accessibilityIdentifier("onboarding_notifications_skip_button")
            }
        }
        .bind(observer: interactor, viewModel: viewModel)
    }

}

// MARK: - The phone

/// An iPhone with one notification on its Lock Screen, bleeding off the bottom of the page. Drawn,
/// with every dimension a fraction of the frame's width.
struct LockScreenMockup: View {
    /// One `dispatch_finished` push in the shape the broker sent:
    /// the answer itself, not "tap to see", titled with Jo reporting she finished.
    private let title = "Codename Jo went through your inbox"
    private let message =
        "3 to-dos: Sarah needs the deck by three, renew the DocuSign seat, reply to Apple about the build."

    /// How much of the phone's height has to show. On a short screen the frame narrows
    /// to keep that much visible instead of cutting the notification off.
    private let visibleAspect: CGFloat = 1.3
    /// iPhone 17: 2.164:1, and 0.132 of the width to the corner.
    private let bodyAspect: CGFloat = 2.164
    private let cornerFraction: CGFloat = 0.132

    var body: some View {
        GeometryReader { geo in
            let w = max(80, min(geo.size.width - 48, max(geo.size.height, 120) / visibleAspect))
            phone(width: w)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
                // The cut where the phone runs off the page is a fade, not a hard line.
                .mask(
                    LinearGradient(
                        stops: [.init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    private func phone(width w: CGFloat) -> some View {
        let bezel = w * 0.019
        let corner = w * cornerFraction
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.52), Color(white: 0.24), Color(white: 0.42)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: max(0.5, w * 0.003))
                )
            screen(width: w, bezel: bezel, corner: corner)
        }
        .frame(width: w, height: w * bodyAspect)
        .overlay(alignment: .topLeading) { sideButtons(width: w) }
    }

    private func screen(width w: CGFloat, bezel: CGFloat, corner: CGFloat) -> some View {
        VStack(spacing: 0) {
            statusBar(width: w)
            clock(width: w)
            notification(width: w)
                .padding(.top, w * 0.075)
            Spacer(minLength: 0)
        }
        .frame(width: w - bezel * 2, height: w * bodyAspect - bezel * 2)
        // The wallpaper is the app's own hero wash, so the mocked phone is in the
        // appearance the real one is in: pale lavender in light, deep purple in dark.
        .background(Theme.heroGradient)
        .clipShape(RoundedRectangle(cornerRadius: corner - bezel, style: .continuous))
        .padding(bezel)
    }

    /// The Dynamic Island, with the Lock Screen's own status bar either side of it.
    private func statusBar(width w: CGFloat) -> some View {
        HStack(spacing: w * 0.02) {
            Spacer()
            Capsule(style: .continuous)
                .fill(Color.black)
                .frame(width: w * 0.318, height: w * 0.094)
            Spacer()
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: w * 0.012) {
                Image(systemName: "wifi")
                Image(systemName: "battery.75")
            }
            .font(.system(size: w * 0.032, weight: .semibold))
            .foregroundStyle(Theme.textPrimary.opacity(0.85))
            .padding(.trailing, w * 0.075)
        }
        .padding(.top, w * 0.028)
    }

    /// The device's own date and time, refreshed on the minute — the mockup is of the
    /// phone in the user's hand, so a canned 9:41 would be the one false thing on it.
    private func clock(width w: CGFloat) -> some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: w * 0.008) {
                Text(Self.dateFormatter.string(from: context.date))
                    .font(.system(size: w * 0.042, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text(Self.timeFormatter.string(from: context.date))
                    .font(.system(size: w * 0.20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .padding(.top, w * 0.06)
    }

    /// "Thursday, 11 September", in the user's own locale and order.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return formatter
    }()

    /// The Lock Screen clock: 12- or 24-hour by the device's setting, and never AM/PM,
    /// which iOS leaves off the big clock.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        let localized = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h"
        formatter.dateFormat = localized.contains("H") ? "H:mm" : "h:mm"
        return formatter
    }()

    private func notification(width w: CGFloat) -> some View {
        HStack(alignment: .top, spacing: w * 0.032) {
            Image("BeadMark")
                .resizable()
                .scaledToFill()
                .frame(width: w * 0.105, height: w * 0.105)
                .clipShape(RoundedRectangle(cornerRadius: w * 0.026, style: .continuous))
            VStack(alignment: .leading, spacing: w * 0.008) {
                HStack(alignment: .firstTextBaseline, spacing: w * 0.02) {
                    Text(title)
                        .font(.system(size: w * 0.042, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text("now")
                        .font(.system(size: w * 0.032))
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(message)
                    .font(.system(size: w * 0.038))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(w * 0.035)
        // Glass, like the banner iOS 26 actually draws — it takes the wallpaper under
        // it, so it lands right in both appearances without a colour of its own.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: w * 0.058, style: .continuous))
        .padding(.horizontal, w * 0.035)
    }

    /// Volume and silence on the left, side button on the right, drawn half under the
    /// frame so only the machined edge shows.
    private func sideButtons(width w: CGFloat) -> some View {
        let thickness = w * 0.012
        return ZStack(alignment: .topLeading) {
            button(w: thickness, h: w * 0.058).offset(x: -thickness / 2, y: w * 0.30)
            button(w: thickness, h: w * 0.105).offset(x: -thickness / 2, y: w * 0.40)
            button(w: thickness, h: w * 0.105).offset(x: -thickness / 2, y: w * 0.53)
            button(w: thickness, h: w * 0.145).offset(x: w - thickness / 2, y: w * 0.46)
        }
    }

    private func button(w: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: w / 2, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.46), Color(white: 0.26)], startPoint: .top, endPoint: .bottom))
            .frame(width: w, height: h)
    }
}

// MARK: - Component

@MainActor
struct OnboardingNotificationsViewComponent {
    @ViewBuilder
    static func make(onNext: @escaping () -> Void) -> some View {
        OnboardingNotificationsView(
            viewModel: OnboardingNotificationsViewModel(),
            interactor: OnboardingNotificationsViewInteractor(onNext: onNext)
        )
    }
}

// MARK: - View model

@MainActor
final class OnboardingNotificationsViewModel: ViewModel {
    /// True while the system alert is up. Only disables the button — there is
    /// nothing to report, because the alert is the feedback.
    @Published var isRequesting = false

    @Published var joSpeaking = false
    /// Level feed for the header thread while Jo's clip plays; see `JoClipMeter`.
    let clipMetering = VoiceMetering()
}

// MARK: - Interactor

@MainActor
final class OnboardingNotificationsViewInteractor: ViewModelInteractor<OnboardingNotificationsViewModel> {
    @Injected(\.pushNotifications) private var push

    private let onNext: () -> Void
    private var player: AVAudioPlayer?
    private var joFeed: Task<Void, Never>?
    /// One-shot: the alert dismissing and a tap on "Not now" race, and advancing twice skips the
    /// finish work.
    private var advanced = false
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var heardYes = false
    private weak var viewModel: OnboardingNotificationsViewModel?

    init(onNext: @escaping () -> Void) {
        self.onNext = onNext
        super.init()
    }

    @CancellableBuilder
    override func onViewAppear(viewModel: OnboardingNotificationsViewModel) -> [AnyCancellable] {
        super.onViewAppear(viewModel: viewModel)
        // Already granted on a previous run of the flow: skip the screen.
        Task { [weak self] in
            guard let self else { return }
            await self.push.refresh()
            if self.push.isEnabled { self.advanceOnce() }
        }
        playClip(viewModel: viewModel)
    }

    override func onViewDisappear(viewModel: OnboardingNotificationsViewModel) {
        super.onViewDisappear(viewModel: viewModel)
        stopClip(viewModel: viewModel)
        player = nil
    }

    private func playClip(viewModel: OnboardingNotificationsViewModel) {
        guard let url = Bundle.main.url(forResource: "jo4", withExtension: "wav") else { return }
        do {
            try OnboardingAudioSession.activate()
            let player = try AVAudioPlayer(contentsOf: url)
            self.player = player
            player.play()
            self.viewModel = viewModel
            startListening()
            joFeed = JoClipMeter.feed(player, into: viewModel.clipMetering) { [weak viewModel] in
                viewModel?.joSpeaking = $0
            }
        } catch {
            RealtimeLog.log("onboarding: notifications clip failed: \(error.localizedDescription)")
        }
    }

    // Jo asks a yes/no question, so a spoken yes does what the button does. Opened with
    // the clip so it can be answered over her; no recogniser means button only.
    private func startListening() {
        guard engine == nil,
              SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable
        else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.contextualStrings = ["yes", "mm-hmm"]
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            RealtimeLog.log("onboarding: notifications mic failed — \(error.localizedDescription)")
            return
        }
        self.engine = engine
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let heard = result?.bestTranscription.formattedString else { return }
            Task { @MainActor [weak self] in self?.hear(heard) }
        }
    }

    private static let affirmatives: Set<String> = [
        "yes", "yeah", "yea", "ya", "yep", "yup", "sure", "okay", "ok", "alright",
        "absolutely", "definitely", "please", "mhm", "mhmm", "mmhmm", "uhhuh",
    ]

    // Whole words, so "yesterday" is not a yes; in-word punctuation is dropped so "mm-hmm" is one.
    private func hear(_ transcript: String) {
        guard !heardYes, !advanced, let viewModel else { return }
        let words = transcript.lowercased().split(whereSeparator: \.isWhitespace).map { $0.filter(\.isLetter) }
        guard words.contains(where: Self.affirmatives.contains) else { return }
        heardYes = true
        enable(viewModel: viewModel)
    }

    private func stopListening() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func stopClip(viewModel: OnboardingNotificationsViewModel) {
        stopListening()
        joFeed?.cancel()
        player?.stop()
        viewModel.joSpeaking = false
        joFeed = JoClipMeter.drain(viewModel.clipMetering)
    }

    private func advanceOnce() {
        guard !advanced else { return }
        advanced = true
        stopListening()
        onNext()
    }
}

extension OnboardingNotificationsViewInteractor: OnboardingNotificationsViewHandler {
    func enable(viewModel: OnboardingNotificationsViewModel) {
        stopClip(viewModel: viewModel)
        viewModel.isRequesting = true
        Task { [weak self, weak viewModel] in
            guard let self else { return }
            let status = await self.push.request()
            viewModel?.isRequesting = false
            // Advance on either answer: the system alert is gone and can't be shown again.
            self.advanceOnce()
        }
    }

    func skip(viewModel: OnboardingNotificationsViewModel) {
        stopClip(viewModel: viewModel)
        advanceOnce()
    }
}

#if DEBUG
import Prefire

#Preview("OnboardingNotificationsView") {
    OnboardingNotificationsViewComponent.make(onNext: {})
        .snapshot(delay: 0.5)
}
#endif
