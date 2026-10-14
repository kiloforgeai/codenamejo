import AVFoundation
import Combine
import FactoryKit
import Speech
import SwiftUI

/// The first utterance: Jo asks for one line out loud, and hearing "inbox" advances. A skip fades
/// in after five silent seconds, since a denied microphone reads silence forever.
protocol OnboardingSayItViewHandler {
    func skip(viewModel: OnboardingSayItViewModel)
}

struct OnboardingSayItView<Interactor: ViewWithModelLifecycleObserver<OnboardingSayItViewModel> & OnboardingSayItViewHandler>: View {
    @StateObject var viewModel: OnboardingSayItViewModel
    @StateObject var interactor: Interactor

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 20) {
                    VoiceOrb(state: viewModel.joSpeaking ? .responding : .listening, muted: false, holding: false, diameter: 66)
                        .allowsHitTesting(false)
                    SpeechIndicator(metering: viewModel.clipMetering)
                        .accessibilityLabel("Jo is speaking")
                }
                .padding(.top, 30)

                Text("“Go ahead. Say below phrase out loud.”")
                    .foregroundStyle(OnboardingTheme.textPrimary)
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.top, 28)

                sayThisBox
                    .padding(.top, 28)

                Text("Not alone? Hold it to your ear.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                Spacer()

                ZStack {
                    if viewModel.showSkip {
                        Button {
                            interactor.skip(viewModel: viewModel)
                        } label: {
                            Text("Skip for now")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(OnboardingTheme.textSecondary)
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                        .accessibilityIdentifier("onboarding_sayit_skip")
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .padding(.top, 6)
                .padding(.bottom, 12)
                .animation(.easeInOut(duration: 0.25), value: viewModel.showSkip)
            }
            .padding(.horizontal, SayItLayout.gutter)
        }
        .bind(observer: interactor, viewModel: viewModel)
        .alert("Not hearing Jo?", isPresented: $viewModel.showVolumeAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Turn on or turn up your volume.")
        }
    }

    private var sayThisBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SAY THIS")
                .font(.system(size: 12, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.textTertiary)
            Text("“Hey Jo, what's sitting in my inbox?”")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(SayItLayout.amber)
                .fixedSize(horizontal: false, vertical: true)
            micBars
                .padding(.top, 12)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(Theme.border)
        }
    }

    // Twelve bars, each a fixed share of the live level so the shape reads as speech.
    private var micBars: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(SayItLayout.barShape.enumerated()), id: \.offset) { _, share in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(SayItLayout.amber.opacity(0.9))
                    .frame(width: 3, height: max(4, 22 * share * CGFloat(0.2 + viewModel.level)))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 22)
        .animation(.easeOut(duration: 0.08), value: viewModel.level)
    }
}

// One audio session for every onboarding clip and the say-it meter; not `.voiceChat`, which halves
// clip volume. `outputVolume` is read-only, so each clip screen checks it and says so.
enum OnboardingVolume {
    /// At or below this the clip is inaudible; not strictly zero, because a hair above it is too.
    static let low: Float = 0.1

    static var isTooLow: Bool {
        AVAudioSession.sharedInstance().outputVolume <= low
    }
}

enum OnboardingAudioSession {
    static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setActive(true)
    }
}

private enum SayItLayout {
    static let gutter: CGFloat = 24
    static let amber = Color(red: 0.914, green: 0.706, blue: 0.298)
    static let barShape: [CGFloat] = [0.25, 0.5, 0.85, 0.4, 0.65, 1.0, 0.3, 0.6, 0.8, 0.45, 0.2, 0.55]
    /// Mic level that counts as the user talking over Jo, above the echo of her own clip.
    static let bargeInLevel: Double = 0.55
}

// MARK: - Component

@MainActor
struct OnboardingSayItViewComponent {
    @ViewBuilder
    static func make(onNext: @escaping () -> Void) -> some View {
        OnboardingSayItView(
            viewModel: OnboardingSayItViewModel(),
            interactor: OnboardingSayItViewInteractor(onNext: onNext)
        )
    }
}

// MARK: - View model

@MainActor
final class OnboardingSayItViewModel: ViewModel {
    /// Smoothed mic level, 0…1.
    @Published var level: Double = 0
    @Published var joSpeaking = false
    @Published var showSkip = false
    /// Raised when the output volume is near zero as Jo's clip starts.
    @Published var showVolumeAlert = false
    /// Level feed for the header thread while Jo's clip plays; see `JoClipMeter`.
    let clipMetering = VoiceMetering()
}

// MARK: - Interactor

@MainActor
final class OnboardingSayItViewInteractor: ViewModelInteractor<OnboardingSayItViewModel> {
    @Injected(\.onboardingAudioQueue) private var audioQueue
    private let onNext: () -> Void
    private var player: AVAudioPlayer?
    private var joFeed: Task<Void, Never>?
    private var introStart: Task<Void, Never>?
    private var skipTimer: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var advanced = false

    init(onNext: @escaping () -> Void) {
        self.onNext = onNext
        super.init()
    }

    @CancellableBuilder
    override func onViewAppear(viewModel: OnboardingSayItViewModel) -> [AnyCancellable] {
        super.onViewAppear(viewModel: viewModel)
        introStart = Task { [weak self, weak viewModel] in
            guard !Task.isCancelled, let self, let viewModel else { return }
            do {
                // Finish any preceding playback-only setup before opening the microphone.
                try await audioQueue.run("onboarding microphone handoff") {}
                guard !Task.isCancelled, !advanced else { return }
                playIntroThenListen(viewModel: viewModel)
            } catch {
                RealtimeLog.log("onboarding: microphone handoff failed: \(error.localizedDescription)")
                viewModel.showSkip = true
            }
        }
        Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self, weak viewModel] _ in
                guard let self, let viewModel else { return }
                self.tick(viewModel: viewModel)
            }
    }

    override func onViewDisappear(viewModel: OnboardingSayItViewModel) {
        super.onViewDisappear(viewModel: viewModel)
        introStart?.cancel()
        joFeed?.cancel()
        skipTimer?.cancel()
        viewModel.joSpeaking = false
        player?.stop()
        player = nil
        stopListening()
    }

    // The mic is open from the first frame so the user can talk over Jo: speaking through
    // the clip cuts it off (see `stopJo`).
    private func playIntroThenListen(viewModel: OnboardingSayItViewModel) {
        guard let url = Bundle.main.url(forResource: "jo2", withExtension: "wav") else {
            startListening()
            scheduleSkip(viewModel: viewModel)
            return
        }
        do {
            try OnboardingAudioSession.activate()
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            startListening()
            // The screen and the audio route both need a beat to settle — playing on the
            // same frame as the appear swallowed Jo's first word.
            introStart = Task { [weak self, weak viewModel] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self, let viewModel else { return }
                if OnboardingVolume.isTooLow { viewModel.showVolumeAlert = true }
                player.play()
                self.joFeed = JoClipMeter.feed(player, into: viewModel.clipMetering) { [weak self, weak viewModel] speaking in
                    viewModel?.joSpeaking = speaking
                    if !speaking { self?.scheduleSkip(viewModel: viewModel) }
                }
            }
        } catch {
            RealtimeLog.log("onboarding: say-it clip failed: \(error.localizedDescription)")
            startListening()
            scheduleSkip(viewModel: viewModel)
        }
    }

    // The way out when nothing will ever be heard: a denied mic reads silence, so
    // neither advance path can fire. Five quiet seconds after Jo finishes, offer it.
    private func scheduleSkip(viewModel: OnboardingSayItViewModel?) {
        skipTimer?.cancel()
        skipTimer = Task { [weak viewModel] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { viewModel?.showSkip = true }
        }
    }

    // On-device recognition of the one line; the same tap feeds the level meter. Without
    // a recogniser (permission denied, no model) the meter alone advances on 0.6 s of speech.
    private func startListening() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let request = SFSpeechAudioBufferRecognitionRequest()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.level(of: buffer)
            Task { @MainActor [weak self] in self?.pendingLevel = level }
        }
        do {
            try OnboardingAudioSession.activate()
            engine.prepare()
            try engine.start()
        } catch {
            RealtimeLog.log("onboarding: say-it mic failed — \(error.localizedDescription)")
            return
        }
        self.engine = engine

        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable
        else {
            RealtimeLog.log("onboarding: say-it recogniser unavailable — level meter only")
            return
        }
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.contextualStrings = ["Hey Jo", "Jo", "inbox"]
        self.request = request
        self.recognizer = recognizer
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    let heard = result.bestTranscription.formattedString.lowercased()
                    if heard.contains("inbox") { self.advanceOnce() }
                }
                if let error, !self.advanced {
                    RealtimeLog.log("onboarding: say-it recognition error — \(error.localizedDescription)")
                }
            }
        }
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

    private var pendingLevel: Double = 0
    private var speechHeard: TimeInterval = 0
    private var bargeIn: TimeInterval = 0

    private func tick(viewModel: OnboardingSayItViewModel) {
        guard engine != nil else { return }
        viewModel.level = viewModel.level * 0.6 + pendingLevel * 0.4

        // Barge-in: Jo's own playback reads about 0.2 at the mic, so anything this far
        // above that floor is the user, and she stops talking.
        if player?.isPlaying == true {
            if pendingLevel > SayItLayout.bargeInLevel {
                bargeIn += 0.05
                if bargeIn >= 0.15 { stopJo(viewModel: viewModel) }
            } else {
                bargeIn = 0
            }
            return
        }

        guard recognizer == nil else { return }
        if pendingLevel > 0.45 {
            speechHeard += 0.05
            if speechHeard >= 0.6 { advanceOnce() }
        }
    }

    // Cuts the clip off mid-word and leaves the mic open; the screen still advances on
    // "inbox", or on the meter when there is no recogniser.
    private func stopJo(viewModel: OnboardingSayItViewModel) {
        introStart?.cancel()
        joFeed?.cancel()
        player?.stop()
        viewModel.joSpeaking = false
        _ = JoClipMeter.drain(viewModel.clipMetering)
        scheduleSkip(viewModel: viewModel)
    }

    // RMS of the buffer mapped so a quiet room sits near 0 and speech near 1.
    private nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let db = 20 * log10(max(rms, 1e-6))
        return Double(min(1, max(0, (db + 50) / 40)))
    }

    private func advanceOnce() {
        finish()
    }

    private func finish() {
        guard !advanced else { return }
        advanced = true
        skipTimer?.cancel()
        introStart?.cancel()
        joFeed?.cancel()
        player?.stop()
        stopListening()
        onNext()
    }
}

extension OnboardingSayItViewInteractor: OnboardingSayItViewHandler {
    func skip(viewModel: OnboardingSayItViewModel) {
        finish()
    }
}

#if DEBUG
import Prefire

#Preview("OnboardingSayItView") {
    OnboardingSayItViewComponent.make(onNext: {})
        .prefireIgnored()
}
#endif
