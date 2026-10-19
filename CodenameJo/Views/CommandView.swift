import AVFoundation
import Combine
import FactoryKit
import Speech
import SwiftUI

/// The screen's fixed measurements, outside the view because a generic type can't hold static storage.
private enum CommandLayout {
    /// Scroll anchor for the streaming answer.
    static let transcriptBottom = "transcript-bottom"
    /// Bottom edge, leading: `scrollTo` acts on both axes, so `.bottom`'s `x: 0.5` would
    /// horizontally centre the anchor whenever the content is wider than the viewport.
    static let followAnchor = UnitPoint(x: 0, y: 1)
    /// Sized to stay a comfortable hold target while leaving the middle of the
    /// screen to the answer.
    static let orbDiameter: CGFloat = 148
    /// How many hands-free dials still spell out that the buzz is the go-ahead.
    /// The end of a dial is silent, so the haptic is the only "talk now" signal.
    static let dialHintDials = 3
}

/// Everything the voice screen can do that isn't drawing.
protocol CommandViewHandler {
    // Unwired: nothing on this screen interrupts a reply — talking over it does.
    // func interrupt()
    func toggleConversationMute()
    func endConversation()
    func conversationTapped(viewModel: CommandViewModel)
    func memoTapped(viewModel: CommandViewModel)
    func memoFinishedOnItsOwn(_ url: URL)
    func sessionStateChanged(viewModel: CommandViewModel)
    func pendingLaunchChanged(viewModel: CommandViewModel)
    func pendingMemoChanged(viewModel: CommandViewModel)
    func signInResolved(viewModel: CommandViewModel)
}

/// Voice-only home: the orb's colour and motion are the status. A tap dials; mid-call it only
/// knocks the bead, and talking over the assistant interrupts it.
struct CommandView<Interactor: ViewWithModelLifecycleObserver<CommandViewModel> & CommandViewHandler>: View {
    @StateObject var viewModel: CommandViewModel
    @StateObject var interactor: Interactor

    /// Observed directly: these change many times a second and are presentation data, so
    /// state flows straight through and behaviour goes to the interactor.
    @ObservedObject private var realtimeService = Container.shared.realtimeService()
    @ObservedObject private var connections = Container.shared.connections()
    @ObservedObject private var backend = Container.shared.backend()
    /// The offline note path: whether the mic is open and how many notes wait to be read back.
    @ObservedObject private var memoRecorder = Container.shared.memoRecorder()
    @ObservedObject private var memoQueue = Container.shared.memoQueue()
    /// Whether the main-screen Note action and external note controls are enabled.
    /// Absent falls back to the account default, as `VoiceSettings.voiceNotes` does.
    @AppStorage(VoiceSettings.Key.voiceNotes) private var voiceNotesChoice: Bool?
    @AppStorage(LocalVoiceSettings.allLocalKey) private var allLocal = false
    @AppStorage(VoiceNotesDefault.ownerKey) private var voiceNotesOwner: String?
    private var voiceNotesEnabled: Bool { VoiceNotesDefault.effective(voiceNotesChoice, owner: voiceNotesOwner) }
    @ObservedObject private var launcher = Container.shared.voiceLauncher()
    /// Read, never forced. The obsidian-pool treatment below only exists in dark mode.
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// Gesture tick, consumed by the haptic in the same frame it's set.
    @State private var tapCount = 0
    @State private var dockHeight: CGFloat = 0
    /// Hands-free dials placed; stops counting once past `CommandLayout.dialHintDials`.
    @AppStorage("voiceDialsPlaced") private var dialsPlaced = 0
    @StateObject private var profilesViewModel = WorkspaceProfilesViewModel()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if colorScheme == .dark {
                obsidianBackdrop
            }
            // Draws nothing here: it contributes the profile picker to this screen's
            // navigation bar, and keeps its sheet in ordinary content.
            WorkspaceProfilesComponent.make(viewModel: profilesViewModel)
            // No horizontal inset: a scroll view clips to its bounds, and the mercury thread must
            // reach both edges. The pane's `.contentMargins` supplies the text inset.
            voiceHero
        }
        .toolbar { callControls }
        .alert("Microphone Access Needed", isPresented: $viewModel.showMicDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Codename Jo needs microphone access to hear you. Enable it in Settings.")
        }
        // A note the mic closed at the two-minute cap; nothing else holds its URL.
        .onChange(of: memoRecorder.unclaimedURL) { _, url in
            guard let url else { return }
            interactor.memoFinishedOnItsOwn(url)
        }
        .alert(
            "Couldn't start the note",
            isPresented: Binding(
                get: { viewModel.memoRefusal != nil },
                set: { if !$0 { viewModel.memoRefusal = nil } })
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.memoRefusal ?? "")
        }
        // Refresh, connector state and the launch hand-off live in the interactor's `onViewAppear`.
        .bind(observer: interactor, viewModel: viewModel)
        .onChange(of: backend.isSignedIn) { _, signedIn in
            if signedIn { interactor.signInResolved(viewModel: viewModel) }
        }
        .onChange(of: realtimeService.sessionState) { _, _ in
            interactor.sessionStateChanged(viewModel: viewModel)
        }
        .onChange(of: launcher.pendingLaunch) { _, _ in
            interactor.pendingLaunchChanged(viewModel: viewModel)
        }
        .onChange(of: launcher.pendingMemo) { _, _ in
            interactor.pendingMemoChanged(viewModel: viewModel)
        }
    }

    // MARK: - Voice hero (the orb)

    /// Top chips, the answer in the middle, the orb at the bottom where the thumb is.
    private var voiceHero: some View {
        VStack(spacing: 0) {
            if connections.attentionCount > 0 {
                connectionAttentionBanner
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            GeometryReader { geometry in
                let minimumDockWidth = CommandLayout.orbDiameter + 48
                let usesColumns = geometry.size.width > geometry.size.height
                    && geometry.size.width >= minimumDockWidth * 2
                    && (horizontalSizeClass == .regular || verticalSizeClass == .compact)
                let visibleDockHeight = min(dockHeight, max(0, geometry.size.height * (usesColumns ? 1 : 0.5)))
                let layout = usesColumns
                    ? AnyLayout(HStackLayout(alignment: .bottom, spacing: 0))
                    : AnyLayout(ZStackLayout(alignment: .bottom))

                // Keep both views alive when folding or resizing during a call.
                layout {
                    transcriptPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentMargins(.bottom, usesColumns ? 0 : visibleDockHeight, for: .scrollContent)

                    ScrollView(.vertical) {
                        bottomDock
                            .padding(.horizontal, 24)
                            .frame(maxWidth: .infinity)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                dockHeight = $0
                            }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollClipDisabled(dockHeight <= visibleDockHeight)
                    .scrollIndicators(.hidden)
                    .defaultScrollAnchor(.bottom)
                    .frame(width: usesColumns ? min(320, max(minimumDockWidth, geometry.size.width * 0.4)) : nil,
                           height: visibleDockHeight)
                }
            }
        }
        .animation(.snappy, value: connections.attentionCount)
        .animation(
            accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2),
            value: realtimeService.feedFocus)
    }

    private func showFeedAccountLabels(for focus: FeedFocus) -> Bool {
        switch focus {
        case .email:
            return connections.gmailAccounts.count > 1
        case .calendar(.agenda(let events, _)):
            return Set(events.map(\.account).filter { !$0.isEmpty }).count > 1
        default:
            return false
        }
    }

    /// Opens the same profile sheet as the navigation-bar picker.
    private var connectionAttentionBanner: some View {
        Button {
            profilesViewModel.showSheet = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .bold))
                Text(connectionAttentionTitle)
                    .font(.system(size: 14, weight: .semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(Theme.warning)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .contentShape(Capsule())
            .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connectionAttentionBanner")
        .accessibilityLabel(connectionAttentionTitle)
        .accessibilityHint("Opens Settings")
    }

    private var connectionAttentionTitle: String {
        if let provider = connections.singleAttentionProviderName {
            return "Reconnect \(provider)"
        }
        return "Multiple connections need reconnecting"
    }

    /// The mercury thread showing the mic hears you. Its `-24` cancels the pane's content margin
    /// so it reaches both edges; the slot is reserved so the centred pane doesn't move.
    private var speechLevelSlot: some View {
        ZStack {
            if micHasTheFloor {
                SpeechIndicator(metering: realtimeService.metering)
                    .transition(.opacity)
            }
        }
        .frame(height: 30)
        .padding(.horizontal, -24)
        // 0.35 s: at 0.2 s the thread's appearance and exit read as a flash.
        .animation(.easeInOut(duration: 0.35), value: micHasTheFloor)
    }

    // MARK: - Transcript (the middle)

    /// The answer, auto-scrolling as text streams so a reply past the fold doesn't look stalled.
    private var transcriptPane: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    // The user's own words are deliberately not drawn; `speechLevelSlot` shows the mic level.
                    if let focus = realtimeService.feedFocus {
                        FeedFocusCard(
                            focus: focus,
                            showAccountLabels: showFeedAccountLabels(for: focus)
                        )
                        .id(focus)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                    }

                    speechLevelSlot

                    activityFeed

                    if !answerLine.isEmpty {
                        SpokenAnswer(text: answerLine)
                            .transition(.opacity)
                            .font(.system(size: 19, weight: .regular))
                            .lineSpacing(5)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Dimmed, not hidden, while it answers the previous question (`answerIsStale`).
                            .opacity(realtimeService.answerIsStale ? 0.35 : 1)
                            .animation(.easeInOut(duration: 0.25),
                                       value: realtimeService.answerIsStale)
                    }

                    Color.clear.frame(height: 1).id(CommandLayout.transcriptBottom)
                }
                // On the stack: a view can't animate its own arrival. Keyed on emptiness so streaming
                // deltas don't re-run the fade.
                .animation(.easeOut(duration: 0.28), value: answerLine.isEmpty)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The text inset lives here so the pane's frame can span the screen (see `speechLevelSlot`).
            .contentMargins(.horizontal, 24, for: .scrollContent)
            // Top-anchored so streaming text grows down and nothing re-centres under the reader.
            .defaultScrollAnchor(.topLeading)
            .onChange(of: answerLine) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(CommandLayout.transcriptBottom, anchor: CommandLayout.followAnchor)
                }
            }
        }
        .accessibilityIdentifier("transcriptPane")
    }

    /// A reserved line lets tool updates crossfade without moving the answer.
    private var activityFeed: some View {
        Text(" ")
            .font(.system(size: 17, weight: .medium))
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if let step = realtimeService.turnSteps.last(where: \.isRunning)
                    ?? realtimeService.turnSteps.last(where: \.failed)
                    ?? realtimeService.turnSteps.last {
                    HStack(spacing: 8) {
                        Group {
                            if step.isRunning && !accessibilityReduceMotion {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(Theme.conversing)
                            } else {
                                Image(systemName: step.outcome.symbol)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(
                                        step.outcome.isFailure
                                            ? Theme.error
                                            : (step.isRunning ? Theme.conversing : Theme.success))
                            }
                        }
                        .frame(width: 16, height: 16)
                        .accessibilityLabel(step.isRunning ? "In progress" : (step.failed ? "Failed" : "Completed"))

                        Image(systemName: step.sourceIcon ?? "circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textTertiary.opacity(0.7))
                            .frame(width: 16)
                            .opacity(step.sourceIcon == nil ? 0 : 1)
                            .accessibilityHidden(true)

                        Text(step.label)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(step.isRunning ? Theme.textPrimary : Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .shimmering(active: step.isRunning && !accessibilityReduceMotion)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let elapsed = step.elapsed {
                            Text(String(format: "%.1fs", elapsed))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.textTertiary.opacity(0.7))
                                .monospacedDigit()
                                .fixedSize()
                        }
                    }
                    .id("\(step.id)-\(step.isRunning)-\(step.failed)")
                    .transition(.opacity)
                    .accessibilityElement(children: .combine)
                }
            }
            .opacity(answerLine.isEmpty ? 1 : 0.45)
            .animation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2),
                       value: realtimeService.turnSteps)
            .animation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2),
                       value: answerLine.isEmpty)
            .accessibilityIdentifier("activityFeed")
    }

    // MARK: - Obsidian pool (dark mode only)

    /// A barely-there lift out of the black toward the bottom. White at 4%: more reads as a spotlight.
    private var obsidianBackdrop: some View {
        RadialGradient(
            colors: [Color.white.opacity(0.04), .clear],
            center: UnitPoint(x: 0.5, y: 1.08),
            startRadius: 0,
            endRadius: 460
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// The still liquid the bead rests on: a sheen and one ripple ring. Static so it doesn't
    /// compete with the bead's motion.
    private var orbPool: some View {
        ZStack {
            Ellipse()
                .fill(Color.white.opacity(0.10))
                .frame(width: CommandLayout.orbDiameter * 1.4, height: 50)
                .blur(radius: 22)
            Ellipse()
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
                .frame(width: CommandLayout.orbDiameter * 1.08, height: 30)
        }
        .offset(y: CommandLayout.orbDiameter / 2 - 6)
        .allowsHitTesting(false)
    }

    // MARK: - Bottom dock (thumb zone)

    private var bottomDock: some View {
        VStack(spacing: 14) {
            // A fixed-height slot, usually empty: words only for what the orb can't say. Reserved
            // so a notice appearing mid-turn doesn't move the orb under the thumb.
            ZStack {
                if let notice = statusNotice {
                    Text(notice)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .transition(.opacity)
                }
            }
            .frame(height: 22)
            .animation(.easeInOut(duration: 0.2), value: statusNotice)

            ZStack {
                if colorScheme == .dark {
                    orbPool
                }
                orbControl
                    // An overlay, not a ZStack sibling: overlay content never reports its size upward,
                    // so the droplets can't grow the dock and move the orb.
                    .overlay {
                        // Mounted only while a job is live: the droplets' 30 fps timeline otherwise
                        // ran for the whole call with nothing to draw.
                        if !realtimeService.liveDispatches.isEmpty {
                            DispatchDroplets(
                                jobs: realtimeService.liveDispatches,
                                orbDiameter: CommandLayout.orbDiameter,
                                // The bead's own colour via `mood`, so a droplet matches the bead in every state.
                                tint: VoiceOrb.mood(
                                    state: realtimeService.sessionState,
                                    muted: realtimeService.isMuted
                                ).tint
                            )
                        }
                    }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(dispatchAccessibilityValue)
        }
        .padding(.bottom, 32)
    }

    /// What the droplets mean for VoiceOver; on screen they are wordless.
    private var dispatchAccessibilityValue: String {
        let running = realtimeService.liveDispatches.filter { $0.finishedAt == nil }
        guard let newest = running.last else { return "" }
        // Five words, cut on a word boundary; the model's task sentences front-load the verb.
        let words = newest.task.split(separator: " ")
        let label = words.count > 5
            ? words.prefix(5).joined(separator: " ") + "…"
            : newest.task
        return running.count == 1
            ? "Working in the background: \(label)"
            : "\(running.count) jobs working in the background. Latest: \(label)"
    }

    /// Mute and End, as toolbar items at opposite ends of the bottom bar so a miss on one
    /// can't land on the other. End is the only way out of a call; the orb doesn't hang up.
    @ToolbarContentBuilder
    private var callControls: some ToolbarContent {

        ToolbarItemGroup(placement: .bottomBar) {
            // Hidden through the onboarding call's opening, which Jo owns; scoped to
            // `assistantOpensFirst` so other calls' email openings keep their controls.
            if realtimeService.isConversing && !viewModel.assistantOpensFirst {
                // Icons only; the label stays for VoiceOver. Mute's tint carries its state.
                Button {
                    interactor.toggleConversationMute()
                } label: {
                    // One `Label` with `.iconOnly`, never a branch or a bare `Image`: swapping view types blanks
                    // the button, and an `Image`-only label loses the 44 pt hit target the glass draws (FB20213961).
                    Label("Mute", systemImage: "mic.slash.fill")
                        .labelStyle(.iconOnly)
                        .opacity(realtimeService.isMuteSettling ? 0.4 : 1)
                }
                // The bead's muted violet, so the button and the orb say "mic closed" in one colour.
                .tint(realtimeService.isMuted ? OrbMood.muted.tint : Theme.textSecondary)
                .accessibilityLabel("Mute")
                // The settling animation means nothing to VoiceOver, so its state is said in words.
                .accessibilityValue(
                    realtimeService.isMuteSettling
                        ? (realtimeService.isMuted ? "Muting" : "Unmuting")
                        : (realtimeService.isMuted ? "On" : "Off")
                )
                .accessibilityIdentifier("muteButton")

                Spacer()

                Button {
                    interactor.endConversation()
                } label: {
                    // `xmark`, not a hung-up handset: the user tapped an orb, not a number. `.iconOnly` as on Mute.
                    Label("End call", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .tint(Theme.error)
                .accessibilityLabel("End call")
                .accessibilityIdentifier("endCallButton")
            } else if !realtimeService.isConversing {
                memoButton
            }
        }
    }

    /// Leave a note without dialling. If the setting changes during a recording,
    /// the elapsed Stop control remains available until the microphone closes.
    @ViewBuilder
    private var memoButton: some View {
        if memoRecorder.isRecording || (voiceNotesEnabled && connections.hasAnyConnector) {
            Button {
                interactor.memoTapped(viewModel: viewModel)
            } label: {
                if memoRecorder.isRecording {
                    Label(
                        String(format: "%d:%02d",
                               Int(memoRecorder.elapsed) / 60,
                               Int(memoRecorder.elapsed) % 60),
                        systemImage: "stop.circle.fill")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                } else {
                    Label("Note", systemImage: "mic.badge.plus")
                        .font(.system(size: 14))
                }
            }
            .tint(memoRecorder.isRecording ? Theme.error : Theme.textSecondary)
            .accessibilityLabel(memoRecorder.isRecording ? "Stop the note" : "Leave a note")
            .accessibilityIdentifier("memoButton")
        }
    }

    /// Nothing connected means a turn has no tool to answer with, so refuse the mic.
    /// Fully local mode needs no connector: the on-device model answers alone.
    private var canTalk: Bool { connections.hasAnyConnector || allLocal }

    /// What the orb draws: the mic is live before the session is, so it shows
    /// listening early. Only the drawing changes; every decision reads the real `sessionState`.
    private var orbState: SessionState {
        // Queue preparation draws as thinking; the session stays `.connecting` and the mic stays held.
        if isPreparingPersonalizedQueue { return .processing }
        guard realtimeService.micIsLive,
              !realtimeService.micHeldForOpening,
              realtimeService.sessionState == .connecting
        else { return realtimeService.sessionState }
        return .listening
    }

    private var isPreparingPersonalizedQueue: Bool {
        realtimeService.turnSteps.contains {
            $0.tool == "prepare_email_queue" && $0.isRunning
        }
    }

    private var orbControl: some View {
        Group {
            if !canTalk {
                // Inert orb — no gesture attached, so a press does nothing.
                VoiceOrb(state: .disconnected, muted: true, holding: false, diameter: CommandLayout.orbDiameter)
                    .opacity(0.4)
            } else {
                // Tap to dial; once the call is up a tap only knocks the bead (see `conversationTapped`).
                VoiceOrb(
                    state: orbState,
                    // A user mute wins; the automatic opening hold doesn't, so the queue load reads as thinking.
                    muted: realtimeService.isMuted
                        || (realtimeService.micHeldForOpening
                            && !isPreparingPersonalizedQueue),
                    holding: realtimeService.isConversing
                        && !realtimeService.isMuted
                        && !realtimeService.micHeldForOpening,
                    diameter: CommandLayout.orbDiameter,
                    // The same tick the haptic rides, so the bead rocks on exactly the
                    // taps the finger is told about — see `sensoryFeedback` below.
                    knock: tapCount
                )
                // Tap only, no drag recogniser: the orb sits in the root's horizontal paging `ScrollView`,
                // and a drag here would compete with swiping between panes.
                .onTapGesture {
                    tapCount += 1
                    interactor.conversationTapped(viewModel: viewModel)
                }
            }
        }
        // Dial haptics; `ConnectCue` sounds when the call opens. Keyed on leaving `.connecting`,
        // since `.listening` recurs after every reply.
        .onChange(of: realtimeService.sessionState) { was, now in
            // `isConversing` is set before `.connecting` is published, so it is what
            // separates a dial from `connect()`'s own momentary `.connecting`.
            if now == .connecting, realtimeService.isConversing {
                Haptics.startWaiting()
                // Counted per dial, not per connect: a failed dial still taught the hint.
                if dialsPlaced <= CommandLayout.dialHintDials { dialsPlaced += 1 }
                return
            }
            guard was == .connecting else { return }
            Haptics.stopWaiting()
            // Skipped when the ready cue already buzzed at mic-live (`FullDuplexVoiceClient.announceReady`).
            let alreadyInvited = realtimeService.micIsLive
            if now == .listening, !alreadyInvited { Haptics.callReady() }
        }
        // The haptic generators are warmed here because they are part of how this
        // control feels, not part of what it does.
        .onAppear { Haptics.warmUp() }
        // The tap — a dial, or, mid-call, the whole of what the tap does.
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.85), trigger: tapCount)
        .accessibilityIdentifier("voiceOrb")
    }

    /// Whether to draw the mic level: only on an unmuted call while listening or ready (the mic
    /// also hears the assistant). Reads `orbState` so it appears at mic-live.
    private var micHasTheFloor: Bool {
        // Jo is opening and the mic is shut — see `RealtimeService.micHeldForOpening`.
        guard !realtimeService.micHeldForOpening else { return false }
        guard realtimeService.isConversing, !realtimeService.isMuted else { return false }
        switch orbState {
        case .listening, .ready: return true
        default: return false
        }
    }

    /// The current answer, trimmed. `answerIsStale` dims it once a new turn starts.
    private var answerLine: String {
        // Trimmed: a reply's first delta can carry a leading space, which shows as an indent.
        realtimeService.responseText
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var statusColor: Color {
        guard canTalk else { return Theme.textTertiary }
        switch realtimeService.sessionState {
        case .ready: return Theme.textSecondary
        case .listening: return Theme.accent
        case .processing: return Theme.conversing
        case .responding: return Theme.success
        case .connecting: return Theme.conversing
        case .disconnected: return Theme.textSecondary
        case .error: return Theme.error
        }
    }

    /// The words above the orb, usually `nil`: only what the orb can't say — why it's inert,
    /// errors, mute, the first-dials teaching line, and a wait that has run long.
    private var statusNotice: String? {
        guard canTalk else { return "Connect a service to start" }
        if realtimeService.isConversing {
            if realtimeService.micHeldForOpening { return nil }
            if realtimeService.isMuted { return "Muted · tap Mute to talk" }
            if realtimeService.sessionState == .listening, let engine = realtimeService.localVoiceEngine {
                if allLocal { return "Fully local — on this phone" }
                if engine == .onDevice { return "No connection — on your phone's voice" }
                return "Live unavailable — on your phone's voice"
            }
            switch realtimeService.sessionState {
            case .processing:
                return realtimeService.isTakingLong ? "Still working on it…" : nil
            case .error(let m): return VoiceFailureText.friendly(m)
            case .connecting:
                // No hint on the onboarding call: the mic is held shut until Jo finishes its opening.
                // The mic is heard from mic-live, so the hint says go ahead rather than wait.
                guard !viewModel.assistantOpensFirst else { return nil }
                if realtimeService.micIsLive {
                    return dialsPlaced <= CommandLayout.dialHintDials
                        ? "Go ahead — I'm listening"
                        : nil
                }
                return dialsPlaced <= CommandLayout.dialHintDials
                    ? "Connecting — talk when you feel the buzz"
                    : nil
            default: return nil
            }
        }
        switch realtimeService.sessionState {
        case .processing:
            return realtimeService.isTakingLong ? "Still working on it…" : nil
        // Friendly text, not the transport's; the raw error stays in `RealtimeLog` and History.
        case .error(let message): return VoiceFailureText.friendly(message)
        case .disconnected, .ready, .connecting, .listening, .responding:
            return nil
        }
    }

}

// MARK: - Component

@MainActor
struct CommandViewComponent {
    @ViewBuilder
    static func make(
        viewModel: CommandViewModel? = nil,
        interactor: CommandViewInteractor? = nil
    ) -> some View {
        CommandView(viewModel: viewModel ?? makeViewModel(), interactor: interactor ?? CommandViewInteractor())
    }

    static func makeViewModel() -> CommandViewModel {
        let launcher = Container.shared.voiceLauncher()
        return CommandViewModel(
            assistantOpensFirst: launcher.pendingLaunch && launcher.launchSource == "onboarding")
    }
}

// MARK: - View model

/// The screen's own decisions; session state is read straight off `RealtimeService`.
@MainActor
final class CommandViewModel: ViewModel {
    /// The onboarding dial, where Jo speaks first: suppresses the talk-now hints because the mic
    /// is held shut until the opening ends. Cleared when the call first hands the user the floor.
    @Published var assistantOpensFirst: Bool
    @Published var showMicDenied = false
    /// Why a note couldn't be started. Published so a mic that failed to open doesn't look like silence.
    @Published var memoRefusal: String?

    init(assistantOpensFirst: Bool = false) {
        self.assistantOpensFirst = assistantOpensFirst
    }
}

// MARK: - Interactor

@MainActor
final class CommandViewInteractor: ViewModelInteractor<CommandViewModel> {
    @Injected(\.realtimeService) private var realtimeService
    @Injected(\.commandStore) private var commandStore
    @Injected(\.connections) private var connections
    @Injected(\.historyRouter) private var historyRouter
    @Injected(\.memoRecorder) private var memoRecorder
    @Injected(\.memoQueue) private var memoQueue

    @Injected(\.voiceLauncher) private var launcher
    /// Owns the dial; this interactor handles the screen's half (sheets, chips).
    @Injected(\.voiceCall) private var voiceCall

    @CancellableBuilder
    override func onLoad(viewModel: CommandViewModel) -> [AnyCancellable] {
        super.onLoad(viewModel: viewModel)

        // Screen-only hook: nil on a CarPlay launch, which can't show this. `[weak viewModel]`
        // because the coordinator is a singleton and would otherwise keep a dead screen's model alive.
        voiceCall.onMicrophoneDenied = { [weak viewModel] in viewModel?.showMicDenied = true }

        // Clear `assistantOpensFirst` on any live-to-idle transition, since CarPlay can dial without
        // this screen. Drop the initial value and duplicates: the first idle can race a pending launch.
        realtimeService.$isConversing
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak viewModel] _ in
                viewModel?.assistantOpensFirst = false
            }

        // The first `.listening` with no opening hold hands the floor to the user. A failed response
        // can publish `.listening` while still held, so the hold is checked at delivery.
        realtimeService.$sessionState
            .removeDuplicates()
            .dropFirst()
            .filter { $0 == .listening }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak viewModel] _ in
                guard self?.realtimeService.micHeldForOpening == false else { return }
                viewModel?.assistantOpensFirst = false
            }

        // The hold's no-audio watchdog releases without publishing `.listening`, so observe it too.
        realtimeService.$micHeldForOpening
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak viewModel] _ in
                viewModel?.assistantOpensFirst = false
            }
    }

    @CancellableBuilder
    override func onViewAppear(viewModel: CommandViewModel) -> [AnyCancellable] {
        super.onViewAppear(viewModel: viewModel)

        LaunchTiming.mark("command screen")
        // First: the Action Button arms the launch before this view exists, so `onChange` never fires.
        // Safe early because `hasAnyConnector` answers true until the connections have loaded.
        handlePendingLaunch(viewModel: viewModel)
        // A note waits on nothing remote, so this check plus `onChange` covers both arming orders.
        handlePendingMemo(viewModel: viewModel)
        // Build the client now (no network, ~200 ms on the main actor) so the first tap doesn't.
        // Must stay after `handlePendingLaunch`, whose dial makes this a no-op.
        Task { await self.realtimeService.connect() }
        Task {
            // Concurrent: neither read depends on the other or on a dial. The marks record when each
            // finished, so they don't sum to the leg.
            async let history: Void = self.commandStore.refresh()
            async let connectors: Void = self.connections.refresh()
            await history
            LaunchTiming.mark("history read (concurrent)")
            await connectors
            LaunchTiming.mark("connector read (concurrent)")
            self.handlePendingLaunch(viewModel: viewModel)
        }
    }

    // MARK: - Turn bookkeeping

    private func handlePendingLaunch(viewModel: CommandViewModel) {
        guard launcher.pendingLaunch else { return }
        let sessionState = realtimeService.sessionState

        // `.connecting` also covers `connect()` building the client before any call exists;
        // `.ready` is the first state that can dial.
        switch sessionState {
        case .connecting:
            if !realtimeService.isConversing { return }
            launcher.consume()
            return
        case .listening, .processing, .responding:
            // External launch surfaces do not silently redial after the current call ends.
            launcher.consume()
            // The onboarding call may have handed over the floor before these subscriptions existed.
            if sessionState == .listening, !realtimeService.micHeldForOpening {
                viewModel.assistantOpensFirst = false
            }
            return
        case .ready, .disconnected, .error:
            break
        }

        let opening: SessionOpening = .freshConversation()
        // Set here, not at the press: the launcher compiles into `JoLiveActivity`, which links no
        // packages and can't reach `DialTiming`.
        DialTiming.willDial(from: launcher.launchSource)
        // Read here: this is the one moment `launchSource` still describes the dial about to happen.
        // Only onboarding hides the call controls; email openings keep Mute and End.
        viewModel.assistantOpensFirst = launcher.launchSource == "onboarding"
        // No connector means the greeting would describe data it can't read. Consumed, not left
        // pending, so later state changes don't retry a call that can't work.
        guard connections.hasAnyConnector else {
            launcher.consume()
            viewModel.assistantOpensFirst = false
            voiceCall.abandonDial("no connector")
            return
        }
        switch sessionState {
        case .ready:
            launcher.consume()
            // `dial()`, not `connect()`, which does no network work. Through the permission gate; the
            // launch is already consumed, so a denial ends here.
            voiceCall.withMicPermission(
                onDenied: {
                    viewModel.assistantOpensFirst = false
                    self.voiceCall.abandonDial("microphone denied")
                }
            ) {
                // Zero after the first grant; its own leg so a first-run wait isn't mistaken for steady state.
                LaunchTiming.mark("mic gate")
                self.voiceCall.dial(opening: opening)
            }
        case .disconnected, .error:
            Task { await self.realtimeService.connect() }
        case .connecting, .listening, .processing, .responding:
            // Handled before dial bookkeeping above; retained for exhaustiveness.
            return
        }
    }
}

extension CommandViewInteractor: CommandViewHandler {
    // Unwired; see the protocol.
    // func interrupt() {
    //     realtimeService.interrupt()
    // }

    func toggleConversationMute() {
        let muted = !realtimeService.isMuted
        realtimeService.setConversationMuted(muted)
    }

    /// End the call and its conversation; the queue goes too, since it belongs to that conversation.
    func endConversation() {
        realtimeService.endConversation()
    }

    /// Tap to start a note, tap again to stop and queue it; the open-mic cap lives in `MemoRecorder`.
    /// `stop()` returns nil for a recording too short to keep, already deleted.
    func memoTapped(viewModel: CommandViewModel) {
        if memoRecorder.isRecording {
            Task {
                guard let url = await memoRecorder.stop() else { return }
                memoQueue.enqueue(url, profileId: memoRecorder.capturedProfileId)
                // Send is a separate, deliberate tap on a transcript the user has read —
                // see `MemoQueue`. All this does is point at where that happens.
                historyRouter.open(tab: .actions)
            }
            return
        }

        // No `onDenied`: there's no launch to abandon. The speech prompt this raises is wanted, since
        // `MemoTranscriber` transcribes long after the tap, where a permission sheet can't appear.
        voiceCall.withMicPermission {
            Task {
                do {
                    try await self.memoRecorder.start(id: UUID())
                } catch {
                    // Surfaced, never swallowed: a mic that silently failed to open looks like silence.
                    viewModel.memoRefusal = error.localizedDescription
                }
            }
        }
    }

    /// The two-minute cap closed the mic. Queued like a tapped note, without jumping to History.
    func memoFinishedOnItsOwn(_ url: URL) {
        memoQueue.enqueue(url, profileId: memoRecorder.capturedProfileId)
        memoRecorder.unclaimedURL = nil
        RealtimeLog.log("memos: the two-minute cap closed the microphone")
    }

    /// Tap the orb to dial. Once the call is up a tap only knocks the bead; End ends the call
    /// and talking over a reply interrupts it.
    func conversationTapped(viewModel: CommandViewModel) {
        // Mid-call the knock and haptic already answered the tap; a local call interrupts instead.
        if realtimeService.isLocalVoice { realtimeService.interruptLocalVoice(); return }
        guard !realtimeService.isConversing else { return }
        // A self-placed dial: Jo doesn't open it, and `handlePendingLaunch` never runs for a tap.
        viewModel.assistantOpensFirst = false
        // Tagged so analytics can separate orb taps from Lock Screen presses, which also paid for a launch.
        DialTiming.willDial(from: "orb")
        // `LaunchTiming` otherwise sees only launcher-armed dials; a no-op unless the app just came up.
        LaunchTiming.armedByOrb()
        voiceCall.activateVoice()
    }

    /// `VoiceSessionLauncher.pendingLaunch` is a request aimed at this screen, its only consumer.
    func sessionStateChanged(viewModel: CommandViewModel) {
        handlePendingLaunch(viewModel: viewModel)
    }

    func pendingLaunchChanged(viewModel: CommandViewModel) {
        handlePendingLaunch(viewModel: viewModel)
    }

    func pendingMemoChanged(viewModel: CommandViewModel) {
        handlePendingMemo(viewModel: viewModel)
    }

    /// A note asked for from outside the app (memo control, Siri, Shortcuts, `aurex://memo`).
    /// Consumed on first sight: unlike a dial it waits on nothing; a second press stops and queues it.
    private func handlePendingMemo(viewModel: CommandViewModel) {
        guard launcher.pendingMemo else { return }
        launcher.consumeMemo()
        // Keep an already-open microphone stoppable even if the setting changed while
        // it was recording; the setting only refuses a new capture.
        guard memoRecorder.isRecording || VoiceSettings.voiceNotes else {
            RealtimeLog.log("memos: external request dropped — Voice notes is off")
            viewModel.memoRefusal = "Turn on Voice notes in Settings → Voice to leave a note."
            return
        }
        // `hasAnyConnector` reads true before the connections have loaded, so a cold offline launch passes.
        guard connections.hasAnyConnector else {
            RealtimeLog.log("memos: external request dropped — no connector")
            return
        }
        // Both armed means two presses raced a launch: the call wins, since its audio session
        // would tear up a recording. Same wording as `MemoRecorder.Refusal.callIsLive`.
        guard !launcher.pendingLaunch else {
            viewModel.memoRefusal = "Finish the call before leaving a note."
            return
        }
        memoTapped(viewModel: viewModel)
    }

    /// `onViewAppear` can beat the Keychain token restore, so the connector fetch repeats
    /// once sign-in resolves.
    func signInResolved(viewModel: CommandViewModel) {
        Task { await self.connections.refresh() }
    }
}

// MARK: - Feed focus

/// The pinned visual referent for Jo's automatic Feed; it has no controls.
/// Constants live outside the view because a generic view can't hold static storage.
private enum FeedFocusCardStyle {
    static let radius = Theme.radiusLarge
    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
    // Dark glass over black needs more colour and a brighter edge to read as a card.
    static func tintOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.32 : 0.13
    }
    static func hairlineOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.22 : 0.28
    }
}

struct FeedFocusCard: View {
    let focus: FeedFocus
    let showAccountLabels: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(stageColor)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 10) {
                header
                content
                footer
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Hug the content: the bar's Rectangle would otherwise claim every spare point.
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(FeedFocusCardStyle.shape)
        // Same glass as the toolbar capsules, tinted lavender inside the material; a
        // hairline highlight and a shadow softer than the buttons' keep it ambient.
        .glassEffect(
            .regular.tint(Theme.amethyst.opacity(FeedFocusCardStyle.tintOpacity(colorScheme))),
            in: FeedFocusCardStyle.shape)
        .overlay {
            FeedFocusCardStyle.shape
                .strokeBorder(.white.opacity(FeedFocusCardStyle.hairlineOpacity(colorScheme)), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 14, y: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("feedFocusCard")
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: stageIcon)
                .font(.system(size: 12, weight: .bold))
            Text(stageLabel)
                .font(.system(size: 12, weight: .bold))
                .tracking(0.7)
            Spacer(minLength: 8)
            if let accountLabel {
                Text(accountLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .foregroundStyle(stageColor)
    }

    @ViewBuilder
    private var content: some View {
        switch focus {
        case .email(let email):
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displaySender(email.sender))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let received = email.received {
                        Text(receivedText(received))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Text(email.subject)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if !email.snippet.isEmpty {
                    // Markdown parsing also decodes the HTML entities Gmail leaves in snippets.
                    Text(markdown(email.snippet))
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(2)
                        .lineLimit(3)
                }
            }

        case .emailStatus(let status):
            statusContent(status)

        case .slack(let slack):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(slack.name)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(unreadText(slack))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                ForEach(Array(slack.messages.enumerated()), id: \.offset) { _, message in
                    (Text(message.from + ": ").fontWeight(.semibold) + Text(message.text))
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }

        case .slackStatus(let status):
            switch status {
            case .complete:
                statusContent(title: "Slack complete", detail: "You're through this Slack queue.")
            case .stopped:
                statusContent(title: "Slack stopped", detail: "The rest of the Slack queue is left as it was.")
            }

        case .tip(let tip):
            Text(tip.copy)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(2)
                .lineLimit(3)

        case .about(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("• \(item)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                }
            }

        case .calendar(.loading):
            statusContent(
                title: "Checking your calendar",
                detail: "Looking at the rest of today.")

        case .calendar(.agenda(let events, let partial)):
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(events.prefix(3).enumerated()), id: \.offset) { _, event in
                    calendarRow(event)
                }
                if events.count > 3 {
                    Text("+\(events.count - 3) more")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(stageColor)
                }
                if partial {
                    Text("Some connected calendars were unavailable.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.warning)
                }
            }

        case .calendar(.empty(let partial)):
            statusContent(
                title: "Calendar clear",
                detail: partial
                    ? "No events found; some calendars were unavailable."
                    : "Nothing else is scheduled today.")

        case .calendar(.unavailable):
            statusContent(
                title: "Calendar unavailable",
                detail: "Jo couldn't confirm the rest of today's schedule.")

        case .complete(let summary):
            statusContent(title: "Feed complete", detail: summaryText(summary))
        }
    }

    /// Queue progress under an email, with the thread standing when the message has one.
    @ViewBuilder
    private var footer: some View {
        if case .email(let email) = focus {
            VStack(alignment: .leading, spacing: 8) {
                if let kind = email.threadKind, let messageCount = email.threadMessageCount, messageCount > 1 {
                    Label(kind == "threadSummary" ? "Thread summary · already read"
                          : "Thread · \(messageCount) messages",
                          systemImage: "bubble.left.and.bubble.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("threadExchangeLabel")
                } else if email.threadKind == nil, let index = email.threadIndex, let count = email.threadCount, count > 1 {
                    Label("Message \(index) of \(count) in this thread", systemImage: "bubble.left.and.bubble.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if let total = email.pageTotal {
                    progressBar(position: email.position, total: total)
                }
            }
        } else if case .slack(let slack) = focus, let total = slack.total, total > 0 {
            progressBar(position: slack.position, total: total)
        }
    }

    private func unreadText(_ slack: FeedFocus.Slack) -> String {
        "\(slack.unread)\(slack.more ? "+" : "") unread"
    }

    private func progressBar(position: Int, total: Int) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(stageColor.opacity(0.18))
                Capsule()
                    .fill(stageColor)
                    .frame(width: proxy.size.width
                        * CGFloat(min(max(position, 0), total)) / CGFloat(total))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func receivedText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let week = calendar.date(byAdding: .day, value: -6, to: .now), date > week {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func statusContent(_ status: FeedFocus.EmailStatus) -> some View {
        switch status {
        case .complete:
            return statusContent(
                title: "Email complete", detail: "You're through this email queue.")
        case .empty:
            return statusContent(
                title: "Inbox clear", detail: "No unread email to review.")
        case .unavailable:
            return statusContent(
                title: "Email unavailable", detail: "Jo couldn't prepare the email queue.")
        }
    }

    private func statusContent(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(detail)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
        }
    }

    private func calendarRow(_ event: FeedFocus.CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(eventTime(event))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(stageColor)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(event.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if showAccountLabels, !event.account.isEmpty {
                        Text(event.account)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let location = event.location {
                    Text(location)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var stageLabel: String {
        switch focus {
        case .email(let email):
            if let total = email.pageTotal {
                return "EMAIL \(email.position) OF \(total)"
            }
            return "EMAIL \(email.position)"
        case .emailStatus: return "EMAIL"
        case .slack(let slack):
            if let total = slack.total, total > 0 {
                return "SLACK \(slack.position) OF \(total)"
            }
            return "SLACK \(slack.position)"
        case .slackStatus: return "SLACK"
        case .tip: return "QUICK TIP"
        case .about: return "ABOUT YOU"
        case .calendar: return "CALENDAR"
        case .complete: return "FEED"
        }
    }

    private var stageIcon: String {
        switch focus {
        case .email, .emailStatus: return "envelope.fill"
        case .slack, .slackStatus: return "number.square.fill"
        case .tip: return "lightbulb.fill"
        case .about: return "person.fill"
        case .calendar: return "calendar"
        case .complete: return "checkmark.circle.fill"
        }
    }

    private var stageColor: Color {
        switch focus {
        case .email, .emailStatus: return Theme.serviceColor(for: "Gmail")
        case .slack, .slackStatus: return Theme.serviceColor(for: "Slack")
        case .tip: return Theme.amethyst
        case .about: return Theme.textSecondary
        case .calendar: return Theme.serviceColor(for: "Calendar")
        case .complete: return Theme.success
        }
    }

    private var accountLabel: String? {
        if case .slack(let slack) = focus {
            return slack.showsWorkspace && !slack.workspace.isEmpty ? slack.workspace : nil
        }
        guard showAccountLabels, case .email(let email) = focus,
              !email.account.isEmpty else { return nil }
        return email.account
    }

    private func eventTime(_ event: FeedFocus.CalendarEvent) -> String {
        guard !event.allDay else { return "All day" }
        guard let start = event.start else { return "Time TBD" }
        return start.formatted(date: .omitted, time: .shortened)
    }

    private func displaySender(_ raw: String) -> String {
        guard let bracket = raw.firstIndex(of: "<") else { return raw }
        let name = raw[..<bracket]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\""))
        return name.isEmpty ? raw : name
    }

    private func summaryText(_ summary: FeedFocus.Summary) -> String {
        var parts: [String] = []
        switch summary.email {
        case .notRun: break
        case .reviewing, .complete: parts.append("Email reviewed")
        case .empty: parts.append("No unread email")
        case .unavailable: parts.append("Email unavailable")
        }
        if summary.slack != .notRun { parts.append("Slack reviewed") }
        if summary.tipShown { parts.append("Quick tip covered") }
        switch summary.calendar {
        case .notRun: break
        case .pending: parts.append("Calendar unavailable")
        case .agenda(let count, let partial):
            parts.append("\(count) calendar event\(count == 1 ? "" : "s")"
                + (partial ? ", partial" : ""))
        case .empty(let partial):
            parts.append(partial ? "Calendar partly checked; no events found" : "Calendar clear")
        case .unavailable: parts.append("Calendar unavailable")
        }
        return parts.isEmpty ? "The available Feed stages are finished." : parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        switch focus {
        case .email(let email):
            var parts = [stageLabel, "From \(displaySender(email.sender))", email.subject]
            if !email.snippet.isEmpty { parts.append(email.snippet) }
            if showAccountLabels, !email.account.isEmpty {
                parts.append("Account \(email.account)")
            }
            return parts.joined(separator: ". ")
        case .emailStatus(let status):
            switch status {
            case .complete: return "Email complete. You're through this email queue."
            case .empty: return "Inbox clear. No unread email to review."
            case .unavailable: return "Email unavailable. Jo couldn't prepare the email queue."
            }
        case .slack(let slack):
            var parts = [stageLabel, slack.name, unreadText(slack)]
            if slack.showsWorkspace, !slack.workspace.isEmpty { parts.append("Workspace \(slack.workspace)") }
            parts += slack.messages.map { "\($0.from): \($0.text)" }
            return parts.joined(separator: ". ")
        case .slackStatus(.complete):
            return "Slack complete. You're through this Slack queue."
        case .slackStatus(.stopped):
            return "Slack stopped. The rest of the Slack queue is left as it was."
        case .tip(let tip):
            return "Quick tip. \(tip.copy)"
        case .about(let items):
            return "About you. " + items.joined(separator: ". ")
        case .calendar(.loading):
            return "Calendar. Checking the rest of today."
        case .calendar(.agenda(let events, let partial)):
            let agenda = events.map { event in
                [eventTime(event), event.title, event.location].compactMap { $0 }
                    .joined(separator: ", ")
            }.joined(separator: ". ")
            return "Calendar. \(agenda)"
                + (partial ? ". Some connected calendars were unavailable." : "")
        case .calendar(.empty(let partial)):
            return partial
                ? "Calendar. No events found; some calendars were unavailable."
                : "Calendar clear. Nothing else is scheduled today."
        case .calendar(.unavailable):
            return "Calendar unavailable. Jo couldn't confirm the rest of today's schedule."
        case .complete(let summary):
            return "Feed complete. \(summaryText(summary))"
        }
    }
}

// MARK: - The answer

/// The streaming answer, drawn in the primary colour as its words arrive. GPT Live's
/// delivery outruns any fixed cadence, so arrival is the cue rather than a paced walk.
private struct SpokenAnswer: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(Theme.textPrimary)
            .accessibilityLabel(text)
    }
}

// MARK: - Voice Orb

/// The single dominant control: a bead of liquid mercury rendered by `MercuryOrb3D`.
/// State colours and motion follow the `mercury-icon-states.html` design study; see `mood`.
struct VoiceOrb: View {
    let state: SessionState
    let muted: Bool
    let holding: Bool
    /// Diameter of the orb itself.
    var diameter: CGFloat = 170
    /// Each increment from the call site knocks the bead once on its bobble spring: the press
    /// feedback. Defaults to 0 where the orb is a mark, not a control.
    var knock: Int = 0

    /// The stage overdraws, so it's an overlay on a `Color.clear` of the real size: layout and
    /// tap target stay at `diameter`. Hit testing is off on the SceneKit view.
    var body: some View {
        Color.clear
            .frame(width: diameter, height: diameter)
            .overlay {
                MercuryOrb3D(mood: mood, tint: mood.tint, knock: knock)
                    .frame(
                        width: diameter * MercuryOrbScene.stageScale,
                        height: diameter * MercuryOrbScene.stageScale
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(Circle())
    }

    private var mood: OrbMood { Self.mood(state: state, muted: muted) }

    /// `SessionState` + mute folded onto the design's moods; mute wins. Static because the orb,
    /// the dispatch droplets and CarPlay must agree.
    static func mood(state: SessionState, muted: Bool) -> OrbMood {
        if muted && (state.isActive || state == .connecting) { return .muted }
        switch state {
        case .listening: return .listening
        case .processing: return .thinking
        case .responding: return .responding
        case .connecting: return .connecting
        case .error: return .error
        case .ready: return muted ? .muted : .ready
        case .disconnected: return .ready
        }
    }

}

/// Beads of mercury split off the orb, one per running dispatch: work that left the conversation
/// and is still going. `dispatchCap` must match `FullDuplexVoiceClient.maxLiveDispatches`.
private struct DispatchDroplets: View {
    let jobs: [RealtimeService.LiveDispatch]
    let orbDiameter: CGFloat
    /// The bead's own colour, from `VoiceOrb.mood(state:muted:)`.
    let tint: Color

    /// How long the droplet takes to shrink away once its answer has landed.
    private static let mergeDuration: TimeInterval = 0.45
    /// How long a dead job's droplet takes to dissolve.
    private static let dissolveDuration: TimeInterval = 1.4
    /// 44pt is the visual diameter. The droplet is an indicator, not a control;
    /// only the main orb accepts taps.
    private static let dropletDiameter: CGFloat = 44
    /// Vertical step between rows: a full droplet plus 12pt of air, so targets don't share an edge.
    private static let rowStep: CGFloat = 56
    /// Clearance between the bead's edge and the droplet's.
    private static let orbitGap: CGFloat = 40
    /// Mirrors `FullDuplexVoiceClient.maxLiveDispatches`, which is private to the client.
    private static let dispatchCap = 2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let now = context.date
            let t = now.timeIntervalSinceReferenceDate
            let shown = Array(jobs.filter { phase(of: $0, at: now) != nil }.prefix(Self.dispatchCap))
            ZStack {
                ForEach(shown) { job in
                    if let phase = phase(of: job, at: now) {
                        droplet(phase: phase, slot: job.slot, t: t)
                    }
                }
            }
        }
    }

    /// What this droplet is doing right now, or nil when it shouldn't be drawn.
    private enum Phase {
        /// Running. Orbiting, and going nowhere.
        case orbiting
        /// Coming home, 0…1. The answer is being spoken over the top of this.
        case merging(Double)
        /// Presumed dead and nothing coming back, 0…1.
        case dissolving(Double)
    }

    private func phase(of job: RealtimeService.LiveDispatch, at now: Date) -> Phase? {
        if let finishedAt = job.finishedAt {
            let since = now.timeIntervalSince(finishedAt)
            guard since < Self.mergeDuration else { return nil }
            return .merging(max(0, since) / Self.mergeDuration)
        }
        guard job.isStale(asOf: now) else { return .orbiting }
        // Timed from the moment it *became* stale rather than from the start, so the
        // dissolve plays once at the right time instead of being already over.
        let dead = now.timeIntervalSince(job.startedAt) - DispatchJob.runningTolerance
        guard dead < Self.dissolveDuration else { return nil }
        return .dissolving(max(0, dead) / Self.dissolveDuration)
    }

    /// One bead, out to the side of the orb: the flanks are the only clear space, as the status
    /// slot sits directly above the bead.
    private func droplet(phase: Phase, slot: Int, t: TimeInterval) -> some View {
        // Alternate sides, then step down a row. Driven by `slot`, held for the droplet's life,
        // so nothing moves when a neighbour leaves.
        let side: CGFloat = slot % 2 == 0 ? 1 : -1
        let row = CGFloat(slot / 2)
        let orbit = orbDiameter / 2 + Self.orbitGap
        // Its own slow bob, on a phase nothing else uses. Small enough that it can't
        // eat into the clearance between one droplet and the next.
        let bob = 3 * sin(t * 0.9 + Double(slot) * 2.1)
        let home = CGPoint(x: side * orbit, y: row * Self.rowStep - 8 + bob)

        let position: CGPoint
        let scale: CGFloat
        let opacity: Double
        switch phase {
        case .orbiting:
            position = home
            scale = 1
            opacity = 1
        case .merging(let p):
            // Shrinks in place, onto its own spot.
            position = home
            scale = 1 - p
            opacity = 1 - pow(p, 3)
        case .dissolving(let p):
            position = CGPoint(x: home.x, y: home.y + 14 * p)
            scale = 1 - 0.4 * p
            opacity = 1 - p
        }

        // Split out and explicitly typed: inlined, this chain times out the type checker.
        let bead: some View = mercuryBead(fading: fade(for: phase))
        return bead
            .scaleEffect(scale)
            .opacity(opacity)
            .offset(x: position.x, y: position.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// One droplet's metal: the orb's own scene at a fifth of the size, resting (`OrbMood.droplet`)
    /// and uncoloured. Each is its own `SCNView`, so `dispatchCap` bounds the renderer count.
    private func mercuryBead(fading: Double) -> some View {
        Color.clear
            .frame(width: Self.dropletDiameter, height: Self.dropletDiameter)
            .overlay {
                MercuryOrb3D(mood: .droplet, tint: tint, knock: 0)
                    .frame(
                        width: Self.dropletDiameter * MercuryOrbScene.stageScale,
                        height: Self.dropletDiameter * MercuryOrbScene.stageScale
                    )
                    .allowsHitTesting(false)
            }
            .saturation(1 - fading)
    }

    /// How far this phase has drained the colour out of the bead, 0…1.
    /// A dying job desaturates rather than switching to a grey of its own.
    private func fade(for phase: Phase) -> Double {
        switch phase {
        case .orbiting, .merging: return 0
        case .dissolving(let p): return p
        }
    }
}

#if DEBUG
import Prefire

#Preview("CommandView") {
    PreviewCommandViewHost()
        .snapshot(delay: 0.5)
}

#Preview("CommandView · Expanded", traits: .fixedLayout(width: 800, height: 600)) {
    PreviewCommandViewHost()
        .environment(\.horizontalSizeClass, .regular)
        .environment(\.verticalSizeClass, .regular)
        .prefireIgnored()
}

#Preview("CommandView · Narrow window", traits: .fixedLayout(width: 320, height: 480)) {
    PreviewCommandViewHost()
        .environment(\.horizontalSizeClass, .compact)
        .environment(\.verticalSizeClass, .regular)
        .prefireIgnored()
}

#Preview("CommandView · Short window", traits: .fixedLayout(width: 700, height: 320)) {
    PreviewCommandViewHost()
        .environment(\.horizontalSizeClass, .compact)
        .environment(\.verticalSizeClass, .compact)
        .prefireIgnored()
}

#Preview("Feed Focus · Long email") {
    FeedFocusCard(
        focus: .email(FeedFocus.Email(
            sender: "Alexandria Montgomery-Smith <alexandria@northwind-books.example>",
            subject: "Final production schedule, revised delivery windows, and launch approvals",
            snippet: "I've attached the latest schedule and highlighted the three decisions that still need your review before tomorrow morning.",
            account: "work@example.com",
            position: 7,
            total: 12,
            received: .now.addingTimeInterval(-5_400),
            threadIndex: 2,
            threadCount: 3
        )),
        showAccountLabels: true
    )
    .padding(24)
    .frame(width: 390)
    .background(Theme.background)
    .prefireIgnored()
}

#Preview("Feed Focus · Slack conversation") {
    FeedFocusCard(
        focus: .slack(FeedFocus.Slack(
            name: "the deploys channel",
            workspace: "Acme",
            showsWorkspace: true,
            unread: 8,
            more: true,
            messages: [
                .init(from: "Sam", text: "Preview build is up, can someone check the onboarding flow on a small phone?"),
                .init(from: "Deploy bot", text: "Deployment ready."),
                .init(from: "Sam", text: "Also the queue card looks off in dark mode."),
            ],
            position: 2,
            total: 5
        )),
        showAccountLabels: false
    )
    .padding(24)
    .frame(width: 390)
    .background(Theme.background)
    .prefireIgnored()
}

#Preview("Feed Focus · Multi-account calendar") {
    FeedFocusCard(
        focus: .calendar(.agenda(events: [
            FeedFocus.CalendarEvent(
                id: "1", account: "work@example.com", title: "Design review",
                location: "Studio", start: .now, end: nil, allDay: false),
            FeedFocus.CalendarEvent(
                id: "2", account: "personal@example.com", title: "Dinner with Sam",
                location: "Downtown", start: .now.addingTimeInterval(3_600),
                end: nil, allDay: false),
            FeedFocus.CalendarEvent(
                id: "3", account: "work@example.com", title: "Planning",
                location: "Office", start: .now.addingTimeInterval(7_200),
                end: nil, allDay: false),
            FeedFocus.CalendarEvent(
                id: "4", account: "personal@example.com", title: "Flight check-in",
                location: nil, start: .now.addingTimeInterval(10_800),
                end: nil, allDay: false),
        ], partial: false)),
        showAccountLabels: true
    )
    .padding(24)
    .frame(width: 390)
    .background(Theme.background)
    .prefireIgnored()
}

#Preview("Feed Focus · Completion · Accessibility") {
    FeedFocusCard(
        focus: .complete(FeedFocus.Summary(
            email: .empty,
            tipShown: true,
            calendar: .unavailable
        )),
        showAccountLabels: false
    )
    .padding(24)
    .frame(width: 390)
    .background(Theme.background)
    .environment(\.dynamicTypeSize, .accessibility2)
    .prefireIgnored()
}
#endif
