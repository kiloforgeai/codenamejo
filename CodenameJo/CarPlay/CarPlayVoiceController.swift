import AVFoundation
import CarPlay
import Combine
import FactoryKit
import SwiftUI
import UIKit

/// The car screen: one indicator and two buttons, per CarPlay's content rules. State changes are
/// coalesced because the template silently drops rapid ones.
@MainActor
final class CarPlayVoiceController {
    @Injected(\.realtimeService) private var realtimeService
    @Injected(\.voiceCall) private var voiceCall
    @Injected(\.accountBootstrap) private var accountBootstrap

    private let interfaceController: CPInterfaceController
    private var cancellables: Set<AnyCancellable> = []

    /// The car's own light/dark preference, which the orb is rendered against.
    private var contentStyle: UIUserInterfaceStyle

    /// Five states, the template's maximum. An errored session gets an alert instead, and a dial
    /// shows `thinking`.
    private enum Indicator: String {
        case idle
        case listening
        case thinking
        case speaking
        case muted
    }

    /// Mute is a voice control state; the button is a static `mic.slash.fill`. `CPButton.image` is
    /// readonly, and reassigning `actionButtons` on a presented template doesn't redraw.
    private var template: CPVoiceControlTemplate?

    /// Our own copy of the mute: `@Published` notifies in `willSet`, so re-reading
    /// `realtimeService.isMuted` from the sink gets the old value.
    private var muted = false

    /// The last session state seen, because a mute has to re-derive the indicator from it.
    /// Mute and phase arrive on two different publishers and the screen shows one thing.
    private var sessionState: SessionState = .disconnected

    // MARK: - Throttle

    private var lastActivatedAt = Date.distantPast
    private var pending: Indicator?
    private var flush: Task<Void, Never>?
    private var activeIndicator: Indicator?
    /// One alert at a time. Without this, a `.error` that republishes puts a second
    /// alert on top of the first and the driver taps OK twice.
    private var isPresentingRefusal = false

    /// Twice a second, matching `LiveVoiceActivity.minInterval`; Apple doesn't document the budget.
    private static let minInterval: TimeInterval = 0.5

    init(interfaceController: CPInterfaceController, contentStyle: UIUserInterfaceStyle) {
        self.interfaceController = interfaceController
        self.contentStyle = contentStyle
    }

    /// The car switched between light and dark. `CPVoiceControlState.image` is readonly, so the
    /// template is rebuilt and the live indicator re-activated.
    func contentStyleDidChange(_ style: UIUserInterfaceStyle) {
        guard style != contentStyle else { return }
        contentStyle = style
        RealtimeLog.log("carplay: content style → \(style == .dark ? "dark" : "light")")
        repaint()
    }

    /// Rebuild the template and re-present it, re-activating the live indicator because
    /// `setRootTemplate` starts on the first state it was given.
    private func repaint() {
        let resumed = activeIndicator
        let template = makeTemplate()
        self.template = template
        interfaceController.setRootTemplate(template, animated: false) { [weak self] success, _ in
            guard success, let self, let resumed, resumed != .idle else { return }
            self.activeIndicator = .idle
            self.activate(resumed)
        }
    }

    // MARK: - Lifecycle

    func start() {
        // First, because this launch may be the only launch: the app can come up on the car screen
        // alone.
        accountBootstrap.start()

        let template = makeTemplate()
        self.template = template
        // Everything else waits for the completion: a state or alert before the root lands has
        // no effect, and a nil completion makes a failed presentation throw.
        interfaceController.setRootTemplate(template, animated: false) { [weak self] success, error in
            guard let self else { return }
            guard success else {
                RealtimeLog.log("carplay: root template refused — "
                    + (error?.localizedDescription ?? "no reason given"))
                return
            }
            self.observeSession()
            self.requestCall()
        }
    }

    /// Dial, or say why not. Every route to a call goes through here so the refusal check always
    /// runs.
    private func requestCall() {
        if let refusal = Self.refusal() {
            present(refusal)
            return
        }
        // Voice is the primary modality on launch, so the tap on our icon dials; `dial()` refuses
        // if a call is already up. Its own entry point for dial timing.
        DialTiming.willDial(from: "carplay")
        voiceCall.beginVoice()
    }

    private func observeSession() {
        realtimeService.$sessionState
            .sink { [weak self] state in
                guard let self else { return }
                self.sessionState = state
                self.show(self.indicator(for: state))
                if case .error(let message) = state { self.present(.callFailed(message)) }
            }
            .store(in: &cancellables)

        // The delivered value is stored rather than read back off the service — see `muted`. The
        // indicator is re-derived from the last phase, so unmuting mid-answer lands on `speaking`.
        realtimeService.$isMuted
            .removeDuplicates()
            .sink { [weak self] muted in
                guard let self else { return }
                self.muted = muted
                RealtimeLog.log("carplay: \(muted ? "muted" : "live")")
                self.show(self.indicator(for: self.sessionState))
            }
            .store(in: &cancellables)
    }

    func stop() {
        flush?.cancel()
        flush = nil
        cancellables.removeAll()
    }

    // MARK: - The template

    private func makeTemplate() -> CPVoiceControlTemplate {
        let style = contentStyle
        // The pair the phone draws, in the phone's colours: a tinted slash is harder to misread at
        // arm's length than the glyph alone.
        let mute = CPButton(image: Self.symbol("mic.slash.fill")) { [weak self] _ in
            guard let self else { return }
            self.realtimeService.setConversationMuted(!self.realtimeService.isMuted)
        }
        mute.title = "Mute"

        let end = CPButton(image: Self.symbol("phone.down.fill")) { [weak self] _ in
            self?.realtimeService.endConversation()
        }
        end.title = "End"

        // Through `requestCall()`, not straight to `beginVoice()` — see it for why.
        let start = CPButton(image: Self.symbol("mic.fill")) { [weak self] _ in
            self?.requestCall()
        }
        start.title = "Talk"

        // Idle carries Talk and no title; the live states carry Mute, End and one word each.
        // `actionButtons` hangs off the state, and an indicator has no tap handler.
        let idle = Self.state(.idle, nil, .ready, inCall: false, style)
        idle.actionButtons = [start]

        // Each live state renders its own orb (~7 MB per sequence), so a glance can tell working
        // from answering. Muted gets the grey, near-still bead.
        let live: [(Indicator, [String], UIImage?)] = [
            (.listening, ["Listening"],
             CarPlayOrb.animatedImage(state: .listening, inCall: true, style: style)),
            (.thinking, ["Working on it", "Working"],
             CarPlayOrb.animatedImage(state: .processing, inCall: true, style: style)),
            (.speaking, ["Speaking"],
             CarPlayOrb.animatedImage(state: .responding, inCall: true, style: style)),
            // The word is the point, and it is the plainest one available. No second
            // variant: "Muted" fits any car screen there is.
            (.muted, ["Muted"],
             CarPlayOrb.animatedImage(state: .ready, inCall: false, muted: true, style: style)),
        ]
        let liveStates = live.map { indicator, titles, image in
            let state = CPVoiceControlState(
                identifier: indicator.rawValue,
                titleVariants: titles,
                image: image,
                repeats: true
            )
            state.actionButtons = Array(
                [mute, end].prefix(CPVoiceControlState.maximumActionButtonCount)
            )
            return state
        }

        // Idle first: the template begins on the first state specified.
        activeIndicator = .idle
        return CPVoiceControlTemplate(voiceControlStates: [idle] + liveStates)
    }

    private static func state(
        _ indicator: Indicator,
        _ titleVariants: [String]?,
        _ session: SessionState,
        inCall: Bool,
        _ style: UIUserInterfaceStyle
    ) -> CPVoiceControlState {
        // `titleVariants` is ordered longest to shortest; the template picks the longest that fits.
        CPVoiceControlState(
            identifier: indicator.rawValue,
            titleVariants: titleVariants,
            image: CarPlayOrb.animatedImage(state: session, inCall: inCall, style: style),
            // `true`: the breathing swell is a loop, not a one-shot. `false` here would
            // play the orb's breath once and then sit still for the rest of the call.
            repeats: true
        )
    }

    /// A button glyph, an SF Symbol so Mute and End keep their conventional shapes.
    /// `.alwaysTemplate` so the car's content style tints them.
    private static func symbol(_ name: String) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: 48, weight: .medium)
        return (UIImage(systemName: name, withConfiguration: configuration)
            ?? UIImage(systemName: "mic", withConfiguration: configuration)
            ?? UIImage())
            .withRenderingMode(.alwaysTemplate)
    }

    // MARK: - State mapping

    /// `.ready` and `.error` map to idle: no call. Mute outranks every phase inside a call, and
    /// only inside one, because `isMuted` outlives the call that set it.
    private func indicator(for state: SessionState) -> Indicator {
        switch state {
        case .disconnected, .ready, .error: return .idle
        // `.connecting` no longer has a state of its own — see `Indicator`.
        case .connecting: return muted ? .muted : .thinking
        case .listening: return muted ? .muted : .listening
        case .processing: return muted ? .muted : .thinking
        case .responding: return muted ? .muted : .speaking
        }
    }

    private func show(_ indicator: Indicator) {
        guard indicator != activeIndicator else { return }

        let elapsed = Date().timeIntervalSince(lastActivatedAt)
        guard elapsed < Self.minInterval else {
            activate(indicator)
            return
        }

        // Too soon for the system to accept it. Keep the newest and land it when the
        // window opens — a dropped final change is the one that reads as a hung app.
        pending = indicator
        guard flush == nil else { return }
        let wait = Self.minInterval - elapsed
        flush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            // `try?` swallows the sleep's CancellationError, so without this check `stop()` cancels
            // nothing.
            guard !Task.isCancelled, let self else { return }
            self.flush = nil
            guard let queued = self.pending else { return }
            self.pending = nil
            self.activate(queued)
        }
    }

    private func activate(_ indicator: Indicator) {
        activeIndicator = indicator
        lastActivatedAt = Date()
        template?.activateVoiceControlState(withIdentifier: indicator.rawValue)
    }

    // MARK: - Degraded states

    /// Why this car cannot place a call. CarPlay rules: state the condition, never tell the driver
    /// to pick up the iPhone — no "open the app", no "go to Settings", no "tap".
    private enum Refusal {
        case notSetUp
        case signedOut
        case noMicrophone
        case callFailed(String)

        /// Longest first — `CPAlertTemplate` "will display the longest string that fits
        /// in the available space on the current size of the car screen."
        var titleVariants: [String] {
            switch self {
            case .notSetUp:
                return ["Codename Jo isn't set up on this phone yet", "Not set up yet"]
            case .signedOut:
                return ["Codename Jo isn't signed in on this phone", "Not signed in"]
            case .noMicrophone:
                return ["Codename Jo doesn't have permission to use the microphone",
                        "No microphone access"]
            case .callFailed(let message):
                // A transport or setup failure, not mail. Second variant for a narrow screen.
                return ["The call couldn't continue — \(message)", "The call ended"]
            }
        }
    }

    /// Onboarding, then sign-in, then the mic — the phone's gate order. `.undetermined` counts as
    /// refused: the system prompt would appear on the handset, out of the driver's reach.
    private static func refusal() -> Refusal? {
        guard OnboardingState.isComplete else { return .notSetUp }
        guard Container.shared.backend().isSignedIn else { return .signedOut }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            return .noMicrophone
        }
        return nil
    }

    /// Present a refusal, once. Dismissing it drops back to idle with Talk, so the driver can
    /// retry.
    private func present(_ refusal: Refusal) {
        guard !isPresentingRefusal else { return }
        isPresentingRefusal = true
        RealtimeLog.log("carplay: refused — \(refusal.titleVariants.last ?? "")")
        let dismiss = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.isPresentingRefusal = false
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }
        let alert = CPAlertTemplate(titleVariants: refusal.titleVariants, actions: [dismiss])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }
}
