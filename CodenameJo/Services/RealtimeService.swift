import FactoryKit
import Foundation
import AVFoundation
import UIKit
import os

// MARK: - Logging

/// Lightweight console logger for the realtime connection flow. Prints to
/// stdout (visible in the Xcode console) with a grep-able prefix.
enum RealtimeLog {
    static func log(_ message: String) {
        print("🎙️[Realtime] \(message)")
    }
}

// MARK: - Metering

/// The mic and far-end levels.
///
/// **Its own object, and the separation is the whole point.** `ObservableObject`
/// has no per-property tracking — any `@Published` write invalidates every view
/// observing the object, whether or not that view's body reads the property. Levels
/// arrive every `AudioLevelReader.interval` (100 ms) for the length of a call,
/// and on `RealtimeService` that re-evaluated `CommandView` ten times a second —
/// including `.toolbar { callControls }`, so the bottom bar was rebuilt on every
/// tick. Waste, and worth removing.
///
/// `SpeechIndicator` is the one reader, and `CommandView` passes this object to it
/// without observing it.
///
/// `audioLevel` — a `Float` mirror of `levels.mic` — went with this move rather
/// than coming along: it had no reader at all, only writers.
@MainActor final class VoiceMetering: ObservableObject {
    @Published var levels = AudioLevels()
}

// MARK: - Session state

enum SessionState: Equatable {
    case disconnected
    case connecting
    case ready        // connected and idle, awaiting user input
    case listening    // user is speaking
    case processing   // command sent, model is reasoning
    case responding   // model is speaking the response
    case error(String)

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .ready: return "Ready"
        case .listening: return "Listening..."
        case .processing: return "Processing..."
        case .responding: return "Responding..."
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var isActive: Bool {
        switch self {
        case .listening, .processing, .responding: return true
        default: return false
        }
    }
}

// MARK: - RealtimeService

/// Drives the voice session. Owns the published `SessionState` the UI renders and
/// delegates the call itself to `FullDuplexVoiceClient`.
///
/// **There is one voice path and nothing selects it.** There were three — a
/// half-duplex Call mode over WebRTC, and two turn-based modes (Apple STT → the
/// broker → Apple TTS) that differed only in SSE versus one-shot HTTP — behind a
/// `RealtimeTransport` enum, a navbar dropdown and a hands-free toggle. All of it
/// is gone: hold-to-talk had been the fallback rather than the default since
/// 2026-08-03, and Call mode was unreachable by construction long before that
/// (`runnableCases` never contained it, so `current` could never return it). What
/// remains is the hands-free Realtime call, which is what every user was on.
@MainActor
class RealtimeService: ObservableObject {
    @Published var sessionState: SessionState = .disconnected {
        didSet {
            guard oldValue != sessionState else { return }
            armThinkingTimer()
            // An error ends the card rather than being drawn on it. `Phase` has no
            // error case on purpose: there is nothing the Lock Screen could offer
            // that would fix it, so the alternative is a Mute button on a call that
            // is already gone — a control that looks live and does nothing, which is
            // the failure mode this app keeps paying for. Taking the activity away is
            // honest: the user opens Codename Jo, where the error is actually reported.
            if case .error = sessionState {
                if isBackgroundSessionActive {
                    endBackgroundSession(reason: "call errored off-screen", endingCall: true)
                } else {
                    // On screen, so the error is already reported where it can be
                    // acted on and the call's own teardown belongs to whoever set
                    // this state — but the card still has to go, because since the
                    // dial-time start it is up during foregrounded calls too.
                    liveActivity.end()
                }
            }
            syncLiveActivity()
            // A state change is a turn happening, which is the definition of not
            // idle. Re-armed here rather than in `syncLiveActivity()` because that
            // runs on every partial transcript and re-arming a `Timer` several
            // times a second to express "the user is still here" is a lot of work
            // for a ten-minute deadline.
            noteBackgroundActivity()
        }
    }
    // **The user's own words are not published from here, deliberately.** There
    // was a `transcript` — what the user is saying, cumulative for the turn in
    // flight — and an `awaitingSpokenWords` flag that blanked it between
    // sentences. Both existed for one reader, the line at the top of
    // `CommandView.transcriptPane`, and that line was removed on instruction.
    // The phone still transcribes: `lastCommandText` below is what History
    // files, and `SpokenCommand` still reads the finals to hang up. Nothing
    // reads the words as they arrive.
    @Published var responseText: String = "" {
        didSet { syncLiveActivity() }
    }
    /// The answer on screen belongs to a question that has already been superseded.
    ///
    /// Set when the user starts speaking, cleared by the next reply's first delta. It
    /// exists because the previous answer is worth keeping on screen — it is what the
    /// user is often still reading, or referring to — but must not read as a reply to
    /// the sentence they are in the middle of. `CommandView` dims rather than hides,
    /// which is the difference between "this is old" and "the screen went blank".
    @Published private(set) var answerIsStale = false
    /// The user has closed their own microphone. Feeds the Live Activity because
    /// off-screen it is the *only* thing distinguishing a call that can hear you
    /// from one that can't — the mic is otherwise open for the whole session.
    /// True while an automatic opening holds the microphone shut — both the first call
    /// after onboarding and a returning user's fresh email queue. The screen draws no speech
    /// thread against it: nothing is being heard, and an indicator over a shut mic is a lie.
    @Published private(set) var micHeldForOpening = false

    /// The opening greeting is audible. The last onboarding screen waits on this rather
    /// than on a duration — the first-turn prefill has measured 1.4–2.2 s and dismissing on
    /// a timer put the user on a silent orb for the difference.
    @Published private(set) var openingSpoken = false

    @Published var isMuted: Bool = false {
        didSet { syncLiveActivity() }
    }
    @Published var lastCommandText: String = ""
    @Published var lastResponseText: String = ""
    @Published var lastServiceName: String = "General"
    @Published var lastDuration: Double = 0
    /// The finished turn's tool steps, snapshotted for the same reason
    /// `lastResponseText` is: `turnSteps` is cleared when the *next* turn commits,
    /// and the save happens off a state transition that can land after that.
    @Published var lastTurnSteps: [CommandRecord.ToolStep] = []
    /// How long the turn in flight made the user wait before it spoke, filled in by
    /// the client at the first sound of the answer.
    ///
    /// Snapshotted into the record by `finalizeTurn` and cleared there, so a turn
    /// that produced no measurement — an echo, or a reply cut off before it made a
    /// sound — cannot inherit the previous turn's number.
    @Published private(set) var lastTurnLatency: TurnLatency?
    /// Live backend responses since the last stored row; they finish after the acknowledgement, so they land on the receipt.
    private var pendingBrainSteps: [CommandRecord.BrainStep] = []

    /// The turn that just finished — one immutable value, every field belonging to
    /// the same exchange.
    ///
    /// **This exists because assembling the record at save time was a race.** The
    /// record used to be built from `lastCommandText`, `lastResponseText`,
    /// `lastTurnSteps` and `lastDuration` — four published properties that advance
    /// at different moments — read from inside an async `Task` scheduled off a
    /// state transition, so the values it saw were whatever they held whenever
    /// that task got its turn on the main actor. `lastCommandText` advances as
    /// soon as the *next* question starts transcribing while the other three
    /// advance only here, so a save landing in that window filed the new question
    /// against the previous answer, with the previous turn's tools attached.
    ///
    /// It was field-visible in an exported transcript (2026-08-04): every question
    /// stored twice, once wrongly. Worse on a poor connection, because every gap
    /// it races is widened by late events — which is where it was first noticed.
    ///
    /// Nothing is assembled now. The fields are read once, here, where they are
    /// known to belong together, and the save consumes the finished value.
    @Published private(set) var lastCompletedTurn: CommandRecord?

    /// A tool that can have moved the email queue's cursor just returned.
    ///
    /// **Not `lastCompletedTurn`, which is what the chip used to watch.** The cursor
    /// moves when the *tool* lands; the turn then runs for several more seconds while
    /// the model reads the message out. So "Queue 2 of 9" sat on screen for the whole
    /// of the turn that was reading message three — the number was only ever right in
    /// the silence between turns, which is the one moment nobody is looking at it.
    ///
    /// A `Date` rather than a `Bool` or a counter because the only thing downstream
    /// wants is an edge, and a timestamp is one that survives being read twice.
    @Published private(set) var queueCursorMovedAt: Date?

    /// What the assistant did during the turn in progress, oldest first.
    ///
    /// `didSet` feeds the Live Activity: with the app off-screen the step feed is
    /// the only thing that distinguishes "reasoning" from "reading your mail",
    /// and a Lock Screen that says "Thinking" for eleven seconds reads as stuck.
    ///
    /// Per turn, not per session: this is a record of one wait, and it is cleared
    /// when the next one starts. What survives is the answer, in `CommandStore`.
    ///
    /// Steps for GitHub and Slack arrive already finished — their tools run inside
    /// the vendor's turn and the broker only learns of them once the round is over
    /// — so those appear late rather than live. That is a property of hosted MCP,
    /// not a bug here. See `ToolNarration`.
    /// Dispatched jobs this session has going, and the ones that have just come
    /// back. The droplets around the orb are drawn from this and nothing else.
    ///
    /// **Kept here rather than on `DispatchJobStore` on purpose.** That store answers
    /// a different question — which *finished* answers nobody has heard yet, read
    /// once at connect — and says in its own header that it deliberately publishes
    /// nothing because it has no screen. This is the live half: jobs of the current
    /// call, held only while there is something to draw, and never read back from the
    /// table. Two questions, two owners.
    ///
    /// **Not cleared by `turnSteps = []`**, which is the whole reason it exists. A
    /// dispatch outlives the turn that started it by design, and the step chips are
    /// cleared on every committed user turn — so a chip could never survive the user
    /// saying the next thing, which for a dispatch is immediately.
    @Published var liveDispatches: [LiveDispatch] = []

    /// One dispatched job as the orb draws it.
    ///
    /// Deliberately not `DispatchJob`: that model is a row the broker wrote, with
    /// optional dates and a raw `String` state it must round-trip losslessly. This
    /// is what the current call knows about a job it started itself, where the id
    /// and the start are facts rather than fields that might be nil.
    struct LiveDispatch: Identifiable, Equatable {
        let id: UUID
        let task: String
        let startedAt: Date
        /// Which place around the bead this droplet occupies, held for its whole
        /// life.
        ///
        /// **Position used to come from the index in the drawn array, and that is a
        /// bug rather than a shortcut.** Drop the first of two droplets and the
        /// second inherits index 0 — so a bead sitting quietly on the left flank
        /// jumps to the right one the instant its neighbour leaves, which reads as a
        /// new droplet appearing rather than an old one moving. A slot claimed at
        /// birth means a droplet never moves because of something that happened to a
        /// different droplet.
        let slot: Int
        /// Set when the answer reaches the conversation. The droplet shrinks away
        /// over the following moment and is then dropped.
        var finishedAt: Date?

        init(id: UUID, task: String, slot: Int, startedAt: Date = Date()) {
            self.id = id
            self.task = task
            self.slot = slot
            self.startedAt = startedAt
        }

        /// Presumed dead. Same tolerance the recovery path uses — nothing resumes a
        /// dispatch, so age is the only evidence there is.
        func isStale(asOf now: Date = Date()) -> Bool {
            finishedAt == nil
                && now.timeIntervalSince(startedAt) > DispatchJob.runningTolerance
        }
    }

    /// Add a droplet, in the lowest place nothing else is standing in.
    ///
    /// Reuses a slot freed by a droplet that has already gone, so three dispatches
    /// one after another occupy 0, 1, 2 rather than marching off the screen.
    private func addLiveDispatch(id: UUID, task: String) {
        let taken = Set(liveDispatches.filter { $0.finishedAt == nil }.map(\.slot))
        let slot = (0...).first { !taken.contains($0) } ?? 0
        liveDispatches.append(LiveDispatch(id: id, task: task, slot: slot))
    }

    /// Mark a droplet as come home, then sweep it once it has finished playing, so the last
    /// droplet of a call does not keep the overlay mounted for the rest of it.
    private func finishLiveDispatch(_ id: UUID) {
        guard let index = liveDispatches.firstIndex(where: { $0.id == id }) else { return }
        liveDispatches[index].finishedAt = Date()
        // Long enough for the merge to play out, and for a stale droplet to dissolve. Both are
        // sub-second; two is slack, not a deadline.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.liveDispatches.removeAll { $0.id == id }
        }
    }

    @Published var turnSteps: [TurnStep] = [] {
        didSet { syncLiveActivity() }
    }

    /// The Live Activity's visual card. Display-only — it draws what the last tool found
    /// and offers nothing to tap.
    @Published var liveCard: VoiceActivityAttributes.Card? {
        didSet { syncLiveActivity() }
    }

    /// Foreground-only detail for the automatic Feed. Kept separate from `liveCard` so
    /// sender, subject, and calendar content never enter the Live Activity contract.
    @Published var feedFocus: FeedFocus?

    /// Take a card from the client. One shape reaches this, so it is an assignment.
    private func showCard(_ card: VoiceActivityAttributes.Card?) {
        liveCard = card
    }

    /// Take the card down.
    ///
    /// **Called from every teardown and from the start of a conversation**, because the
    /// two are not the same path: `endConversation()` does not go through `disconnect()`,
    /// so a hang-up left `liveCard` set and the next dial opened on the previous call's
    /// sender.
    private func clearCard() {
        liveCard = nil
    }

    private func clearFeedFocus() {
        feedFocus = nil
    }

    // MARK: - Pause awareness (PRD §4.3)

    /// The ring around the orb used to show how far through a pause the endpointer
    /// was, because a turn-based session decided for itself when the user had
    /// stopped talking and a silent wait read as a hang. Server VAD owns that
    /// decision now and doesn't report progress toward it, so `endpointProgress`
    /// and `isHoldingForPause` were published values nothing could ever write.
    ///
    /// The model has been working long enough that silence needs explaining.
    @Published var isTakingLong: Bool = false
    /// Fires `isTakingLong` a few seconds into `.processing`.
    private var thinkingTimer: Timer?
    /// Long enough that a fast answer never trips it, short enough that a slow
    /// one doesn't feel broken.
    private static let takingLongAfter: TimeInterval = 3.5

    /// Dispatched answers the broker recorded, read once per hands-free connect so an
    /// answer whose call ended isn't lost. `@Injected` rather than a `.shared`
    /// singleton because this store never existed as one — the direction
    /// `Container+App.swift` describes, applied to a new dependency rather than
    /// retrofitted to an old one.
    @Injected(\.dispatchJobs) private var dispatchJobs
    /// Notes left with no network. Held here only to keep one from posting during a
    /// call — this service never reads their answers, and must not: `recover()` is the
    /// single deliverer, and a second one would speak the same answer twice.
    @Injected(\.memoQueue) private var memoQueue

    /// The queue has a durable cursor as well as the chip drawn by the view. Ending a
    /// call must pause both from this shared service so the phone button, a spoken
    /// hang-up, CarPlay and the Lock Screen all have identical semantics.
    @Injected(\.localTriage) private var localTriage
    @Injected(\.triageQueue) private var triageQueue

    /// Auth, for the token the hands-free client mints its session with.
    @Injected(\.backend) private var backend

    /// The Lock Screen card a backgrounded call is controlled from. Injected
    /// rather than `LiveVoiceActivity.shared`, which no longer exists — see
    /// `Container+App.swift`.
    @Injected(\.liveActivity) private var liveActivity

    private var commandStartTime: Date?

    /// The hands-free call (OpenAI Realtime over WebRTC, full duplex).
    private var fullDuplex: FullDuplexVoiceClient?
    /// The local call standing in for a Live one. Nil for the whole of a Realtime call.
    private var localVoice: LocalVoiceCall?
    /// Which brain the local call is on, published so the screen can say which mode this is.
    @Published private(set) var localVoiceEngine: LocalVoiceBrain.Engine?
    var isLocalVoice: Bool { localVoiceEngine != nil }

    func installProfileDossier(_ dossier: ProfileDossierContext?, profileId: String) {
        guard ProfileRuntime.snapshot?.profileId == profileId else { return }
        fullDuplex?.installProfileDossier(dossier, profileId: profileId)
    }


    // MARK: - "Still thinking" affordance (PRD §4.3)

    /// Silence while the model works is indistinguishable from a dead session.
    /// After a few seconds, say so — the alternative is the user repeating
    /// themselves into a request that was already running.
    private func armThinkingTimer() {
        thinkingTimer?.invalidate()
        thinkingTimer = nil
        guard sessionState == .processing else {
            if isTakingLong { isTakingLong = false }
            return
        }
        isTakingLong = false
        let timer = Timer(timeInterval: Self.takingLongAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sessionState == .processing else { return }
                self.isTakingLong = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        thinkingTimer = timer
    }

    // MARK: - Connect / disconnect

    func connect() async {
        guard sessionState == .disconnected || {
            if case .error = sessionState { return true }; return false
        }() else { return }

        sessionState = .connecting
        responseText = ""
        answerIsStale = false
        turnSteps = []
        RealtimeLog.log("connect() start")

        // Deliberately no network and no audio here — `connect()` only has to
        // resolve fast enough for the orb to become tappable, and the tap is what
        // dials. Everything expensive (session setup, the SDP handshake, the VPIO
        // pre-roll) lives in `startFullDuplexConversation()`.
        //
        // It used to also warm an `AVAudioEngine` and load an on-device TTS voice
        // here, because a hold-to-talk press paid ~200 ms for the input unit and a
        // reply spoken before its voice finished loading came out in the wrong one.
        // Neither exists on a Realtime call: the mic belongs to WebRTC, and the
        // reply is the model's own voice.
        connectFullDuplex()
        sessionState = .ready
        RealtimeLog.log("connect() → ready")
        // Expected to be near zero — there is deliberately no network here. Marked
        // anyway because "the session takes a moment to come up" is one of the things
        // the launch wait has been blamed on, and a leg reading 3ms settles it.
        LaunchTiming.mark("session ready")
    }

    func disconnect() {
        // Before the client goes: `endBackgroundSession` reaches through it to hang
        // up the call, and a nil client can't.
        endBackgroundSession(reason: "session disconnected", endingCall: true)
        fullDuplex?.stop()
        fullDuplex = nil
        turnFailure = nil
        metering.levels = AudioLevels()
        commandStartTime = nil
        isMuted = false
        clearMuteSettling()
        turnSteps = []
        // The card goes with the call. A queue position over a dead session is the same
        // dead control this file has spent its bug budget on.
        clearCard()
        clearFeedFocus()
        isConversing = false
        memoryTurns = 0
        // No client, no call, so no conversation — same reasoning as `endConversation`.
        activeConversationId = nil
        sessionState = .disconnected
        responseText = ""
        answerIsStale = false
    }

    // MARK: - The Realtime call (OpenAI, over WebRTC, full duplex)

    /// The audio levels from the running full-duplex call. Only written while a
    /// full-duplex call is up.
    ///
    /// **A nested object, not a `@Published` property here** — see
    /// `VoiceMetering` for what that cost the Mute button. `let`, so the reference
    /// never changes and observing the service never means observing these.
    let metering = VoiceMetering()

    /// A single turn failed while the call stayed up — a rate limit, a refusal.
    ///
    /// Separate from `sessionState = .error`, which ends the session: this is
    /// recoverable and usually clears within seconds, and dropping a working call
    /// over it would be a far worse answer than a line of text.
    @Published var turnFailure: String?

    /// `activeFullDuplex` and `handsFreeSetting` stood here. Both existed to answer
    /// "which of the two clients is this session", which is no longer a question
    /// anything can ask — and the second existed only because `UserDefaults`
    /// publishes nothing, so a screen bound to the hands-free key kept whichever
    /// gesture it was first drawn with. There is one client and one gesture.

    /// Wire the client up. Deliberately no network here: `connect()` is expected to
    /// resolve fast so the orb becomes tappable, and the tap is what dials.
    private func connectFullDuplex() {
        let client = FullDuplexVoiceClient(
            // The id the broker scopes its session context on, and the same one every
            // `CommandRecord` already carries — so a cached lookup and the turns of the
            // conversation that caused it line up.
            conversationId: { [weak self] in self?.activeConversationId?.uuidString },
            // Read at the moment a handoff happens, not captured: a queue starts and ends
            // several turns after this client is built. See `liveQueueStanding`.
            queueStanding: { [weak self] in self?.liveQueueStanding() }
        )
        fullDuplex = client

        // The ends nobody performed. Not guarded on `isConversing` like the state
        // callbacks below: a server-side close is precisely the case where the app still
        // believes the call is up, so filtering on that belief would drop the one event
        // it exists to catch.
        client.onEnded = { [weak self] reason in
            guard let self else { return }
            // A dropped transport or a server-side close mid-call is what the local call is
            // for; the conversation keeps its id and carries on in the phone's own voice.
            if self.isConversing, self.localVoice == nil,
               reason == ConversationRecord.Reason.transportFailure || reason == ConversationRecord.Reason.closedByServer,
               let engine = self.localVoiceEngine(after: reason) {
                self.fullDuplex?.stop()
                self.beginLocalVoice(engine: engine, reason: reason)
                return
            }
            self.finishConversation(reason: reason)
            self.clearFeedFocus()
            // **The queue resumes here too, and not only from `endConversation`.** The
            // pause exists because a note posting mid-call is an agent the dispatch
            // budget cannot see — and once the far side has closed the session there is
            // no such agent, whatever the app still believes. Wired only to the End
            // button, a server-side close left notes unsendable until somebody happened
            // to press it: the transport was gone, so nothing was going to send them,
            // and nothing on screen said so.
            //
            // Not folded into `finishConversation`, which is where both paths meet but
            // is guarded to fire once per conversation — an `onEnded` that arrived first
            // would make the End button's call return early and take the resume with it.
            self.resumeMemoQueue()
        }

        client.onState = { [weak self] state in
            guard let self, self.isConversing else { return }
            // `.listening` covers both "nobody is talking" and "the user is
            // mid-sentence"; server VAD owns that distinction and the UI doesn't
            // need it. What it does need is that a finished turn lands on
            // `.listening` rather than `.ready`, because the mic never closed —
            // which is also what makes `CommandView` file the turn in History.
            self.sessionState = state
        }
        client.onUserTranscript = { [weak self] text, isFinal in
            guard let self else { return }
            if !text.isEmpty, self.feedFocus?.isSettled == true {
                self.fullDuplex?.dismissSettledFeedFocus()
            }
            // Any new words mean the user has moved on; whatever failed is history.
            self.turnFailure = nil
            // Timed from the first word rather than the last, and definitely not
            // from the completed transcript — transcription lands after the user
            // has stopped talking, so timing from there would report every turn as
            // faster than it was.
            if self.commandStartTime == nil { self.commandStartTime = Date() }
            if !text.isEmpty { self.lastCommandText = text }
        }
        client.onAssistantTranscript = { [weak self] text, isFinal in
            // `stopWithEndCue` keeps the audio session alive briefly for the falling
            // tone. Ignore any transcript frame already in flight during that window;
            // otherwise End clears the answer and a late delta draws it again.
            guard let self, self.isConversing else { return }
            self.responseText = SpokenAddress.written(text)
            // The reply that replaces the stale one has arrived, so it is no longer
            // stale — done on every delta rather than on a "response started" event
            // because this is the first thing that puts *new* words on screen.
            self.answerIsStale = false
            // A tool call ends a Realtime response without ending the turn, so
            // "final" here means the model has actually stopped — the client
            // withholds it while a continuation is in flight.
            if isFinal { self.finalizeTurn() }
        }
        client.onUserTurnCommitted = { [weak self] in
            // The step chips describe *one* wait and are cleared when the next one
            // starts — the same contract as the turn-based path's `onUtteranceSent`.
            // Without this they persisted across turns, so a turn that ran no tools
            // at all still showed "search email ids ✓ / batch read email ✓" from
            // two questions ago, which reads as work that never happened.
            self?.turnSteps = []
        }
        // The model asked to hang up and has finished saying goodbye.
        //
        // **`endBySpokenCommand()`, not `endConversation()`, and the name is now half
        // wrong.** What that method actually does is end the background stint *before*
        // the call rather than after — the inversion a hang-up with no `perform()` to
        // borrow time from needs, so ActivityKit's IPC runs before the audio session
        // that keeps this process alive goes away. A model-requested end has exactly the
        // same problem: it can arrive with the phone locked and the app backgrounded,
        // where the only thing holding the process up is the audio session it is about
        // to tear down. Reusing it is the point rather than an accident.
        client.onEndRequested = { [weak self] in
            guard let self, self.isConversing else { return }
            Task { await self.endBySpokenCommand() }
        }
        client.onMuteRequested = { [weak self] in
            guard let self, self.isConversing else { return }
            self.setConversationMuted(true)
        }
        client.onToolUse = { [weak self] name in
            guard let self else { return }
            self.beginStep(name)
        }
        client.onToolDone = { [weak self] name in
            // No timing is reported on this path. Zero means "we don't know".
            self?.completeStep(name, milliseconds: 0)
            // A tool ran, so the mail cache may no longer be true. **Flag only, and
            // deliberately no pass from here** (2026-08-20): the reconciliation belongs to
            // `didBecomeActive`, where it already lives. This just makes sure the next one
            // is not thrown away by `launchThrottle`.
            BackgroundMailRefresh.noteMailboxMayBeStale()
            // Same flag, same reasoning, independent cache — see
            // `BackgroundCalendarRefresh.calendarMayBeStale`'s header for why this is not
            // shared with the mail flag above.
            BackgroundCalendarRefresh.noteCalendarMayBeStale()
            // The carve-out from "no pass from here" (#753): `didBecomeActive` can't fire
            // mid-call, so the pull runs here — delayed, and debounced to one pending pass.
            if BackgroundCalendarRefresh.isCalendarWrite(name) {
                self?.calendarPullTask?.cancel()
                self?.calendarPullTask = Task {
                    do {
                        try await Task.sleep(
                            for: .seconds(BackgroundCalendarRefresh.toolWriteDelay))
                    } catch { return }
                    await BackgroundCalendarRefresh.run(trigger: .toolWrite)
                }
            }
        }
        client.onToolFailed = { [weak self] name in
            self?.failStep(name)
        }
        client.onCard = { [weak self] card in
            self?.showCard(card)
        }
        client.onFeedFocus = { [weak self] focus in
            self?.feedFocus = focus
        }
        client.onOpeningHold = { [weak self] held in
            self?.micHeldForOpening = held
        }
        client.onOpeningSpoken = { [weak self] in
            self?.openingSpoken = true
        }
        client.onEmailQueuePrepared = { [weak self] in
            self?.queueCursorMovedAt = Date()
            self?.completeStep("prepare_email_queue", milliseconds: 0)
        }
        // **The previous answer comes down when the next question starts, not when
        // the reply ends.** `answerLine` used to hide the answer on `.listening`,
        // which in hands-free is the state the call returns to the instant a reply
        // finishes — so the answer vanished a beat after being spoken and the screen
        // went blank while the user was still reading it. Clearing here instead keeps
        // it up until there is a new question to replace it.
        //
        // Fired on every `speech_started`, including the ones `onBargeIn` also
        // handles; that closure runs first and finalizes the interrupted turn, so the
        // clear can never take a reply out of History. `lastResponseText` is what the
        // record is built from and is untouched by either.
        client.onUserSpeechStarted = { [weak self] in
            guard let self else { return }
            // **The answer stays up, and only goes grey** (2026-08-18, on instruction).
            // This used to clear `responseText` outright, so the reply the user was
            // reading vanished the instant they opened their mouth — including when
            // they were only saying "thanks" or starting a follow-up that referred to
            // it. The reason it cleared was that a live answer next to a new question
            // reads as the answer *to* that question; `answerIsStale` says the same
            // thing by dimming it, and the new reply replaces it on its first delta.
            //
            // Nothing about History changes: `lastResponseText` is what the record is
            // built from and neither this nor `onBargeIn` touches it.
            self.answerIsStale = true
            self.turnSteps = []
        }
        // **There was an `onUserSpeechOnset` here and it has gone with the line it
        // served.** It fired off the capture tap's energy — earlier than Apple's
        // first word and well before the server's VAD — for one purpose: to take
        // the previous sentence off screen the instant the user started the next
        // one, because nothing else cleared that line, it was only overwritten.
        // With the user's words no longer drawn, there is nothing to clear, and the
        // whole onset detector went with it (`LocalTranscriber`).
        client.onMicLive = { [weak self] in
            self?.micIsLive = true
        }
        client.onTurnLatency = { [weak self] latency in
            self?.lastTurnLatency = latency
        }
        client.onBrainStep = { [weak self] step in
            self?.pendingBrainSteps.append(step)
        }
        client.onLevels = { [weak self] levels in
            self?.metering.levels = levels
        }
        client.onTurnFailed = { [weak self] message in
            guard let self else { return }
            // The call is fine; this one turn produced nothing. Say so and go back
            // to listening, rather than leaving the orb spinning on "Thinking…"
            // over a response that will never speak.
            self.turnFailure = message
            self.turnSteps = []
            // The first time a mid-call failure has left the device. `voice_dial_failed`
            // cannot cover this: it is gated on the call not yet having connected.
        }
        client.onDispatchStarted = { [weak self] jobId, task in
            self?.addLiveDispatch(id: jobId, task: task)
        }
        client.onJobDelivered = { [weak self] jobId in
            // Fire-and-forget, and the direction it fails in is deliberate: a delete
            // that doesn't happen means the answer is offered again on the next
            // connect, which costs one repeated sentence. Awaiting it here would put a
            // network write in the middle of delivering an answer.
            Task { await self?.dispatchJobs.settle(jobId) }
            // The droplet merges as the answer is spoken, because this fires from
            // `drainDispatchReports` — the same statement that hands the text to the
            // conversation. That coincidence is the point: a merge a second early or
            // late reads as an unrelated animation.
            self?.finishLiveDispatch(jobId)
        }
        client.onError = { [weak self] message in
            guard let self else { return }
            RealtimeLog.log("fullduplex: onError \(message)")
            // `onEnded` already moved this call onto the local path for a transport failure.
            if self.localVoice != nil { return }
            // A failure before the call ever opened is a dial that didn't happen; one
            // after it is a call that broke. Only the first belongs in the pair that
            // `voice_session_started` opens, and mixing them is what would make that
            // number unreadable. This is the path the connect watchdog arrives on.

            // Hang the call up. `.error` clears the session as far as the screen is
            // concerned — the Mute and End buttons are drawn off `isConversing` —
            // so leaving the peer connection up would strand a live microphone with
            // no control that can close it, and the next tap would dial a *second*
            // call on top of the first. Idempotent when the transport already tore
            // itself down, which is the common case.
            self.fullDuplex?.stop()
            self.isConversing = false
            self.sessionState = .error(message)
        }
    }

    // MARK: - Turn steps

    /// A tool has started.
    private func beginStep(_ tool: String) {
        // Close whatever was open first. With a broker that sends completion frames
        // this closes nothing, but without one the only evidence a step finished is
        // that the next one started.
        closeOpenSteps()
        turnSteps.append(TurnStep(tool: tool))
        Haptics.step()
    }

    /// A tool returned, with how long it took when something measured it — zero when
    /// nothing did.
    ///
    /// Matched to the most recent *running* step with that name, so a tool called
    /// twice in one turn closes the right one.
    private func completeStep(_ tool: String, milliseconds: Int) {
        // **Before the guard, deliberately.** The queue signal is about the tool having
        // landed, not about this view's bookkeeping — and the guard below returns early
        // whenever no running step matches, which is exactly the case where the chip
        // would be left showing a stale position with nothing to correct it.
        if TriageQueueStore.advancesQueue(tool) { queueCursorMovedAt = Date() }

        guard let index = turnSteps.lastIndex(where: { $0.tool == tool && $0.isRunning })
        else { return }
        turnSteps[index].endedAt = Date()
        turnSteps[index].serverMilliseconds = milliseconds
    }

    /// Mark the most recent step for this tool as refused.
    ///
    /// **Searches finished steps, not running ones**, which is the opposite of
    /// `completeStep` and is why this is its own method rather than a flag on that one:
    /// the completion event and the result arrive separately and in that order, so by the
    /// time the refusal is known the step has already stopped.
    ///
    /// `lastIndex` matters when one tool is called twice in a turn — a refused send
    /// followed by a successful retry is exactly that — and the flag has to land on the
    /// call it belongs to rather than on whichever ran first.
    private func failStep(_ tool: String) {
        guard let index = turnSteps.lastIndex(where: { $0.tool == tool && !$0.failed })
        else { return }
        turnSteps[index].failed = true
    }

    /// How long after the last queue step the user is still considered mid-queue.
    ///
    /// **The same five minutes the old server's queue used, and for the same reason**:
    /// nothing anywhere clears a queue the user *stopped*. "Stop", "that's enough" are
    /// answered in prose and call no tool, so this chip keeps a live position until something
    /// replaces it. Without a window, every dispatch for the rest of the call would be told to
    /// go back to a message the user finished with twenty minutes ago.
    ///
    /// Measured from `queueCursorMovedAt`, which is set when a mover tool lands in *this*
    /// session.
    private static let queueStillBeingWalked: TimeInterval = 5 * 60

    /// Where the user is standing in a live queue, for the one aside the broker cannot reach.
    ///
    /// `nil` in three cases, and each of them is a wrong sentence avoided: no queue step has
    /// landed in this session (so nothing knows a queue is being walked), the last one was long
    /// enough ago that the queue was stopped rather than paused, or the queue has run out.
    ///
    /// **Reads the chip's own copy rather than asking the broker.** It is refreshed on every
    /// tool that can move the cursor, which is exactly when this can change. The answer here
    /// only decides *whether* a handoff earns a queue suffix; when it says a mail queue is
    /// live, the client does then pay one broker round trip before "Started" — deliberately,
    /// because the advance has to be in the acknowledgement (see `startDispatch`) — so what
    /// staying local buys is every other dispatch skipping the network entirely. The cost is
    /// that a position which failed to refresh is a position stated one behind; the number is
    /// not spoken, so what that costs is the model going back to the message before the
    /// current one, which the ids in its next tool result correct.
    private func liveQueueStanding() -> TriageQueueStore.QueueProgress? {
        guard let movedAt = queueCursorMovedAt,
              Date().timeIntervalSince(movedAt) < Self.queueStillBeingWalked,
              let standing = Container.shared.triageQueue().progress,
              !standing.done
        else { return nil }
        return standing
    }

    /// Nothing is running any more.
    private func closeOpenSteps() {
        let now = Date()
        for index in turnSteps.indices where turnSteps[index].isRunning {
            turnSteps[index].endedAt = now
        }
    }

    // MARK: - Background session (Live Activity: Mute + End)

    /// True while a hands-free call is running with Codename Jo off-screen: the WebRTC
    /// call is held, the process is kept alive by `UIBackgroundModes: audio`, and
    /// the Live Activity's Mute and End buttons are the only way to reach it.
    ///
    /// **Narrower than "the card is up", since the dial-time start.** The activity
    /// lives for the whole call; this is only the off-screen stint, which is what the
    /// ten-minute idle timeout is bounded by. Foregrounding clears it and leaves the
    /// card alone (`endBackgroundStint`).
    ///
    /// Not `private(set)`, for the same reason the domain stores aren't — the
    /// preview subclass seeds it.
    @Published var isBackgroundSessionActive = false

    /// Ends a stint nobody came back to.
    ///
    /// The standing cost of a background call is real and worth bounding: a lit
    /// recording indicator, `.duckOthers` holding everyone else's audio down, a
    /// process iOS is not allowed to reclaim, and — unlike the turn-based stint
    /// this replaced — a per-minute Realtime bill that runs whether anyone is
    /// talking or not. Ten minutes is long enough that a quiet stretch on a
    /// commute doesn't kill the call and short enough that a phone left in a
    /// pocket doesn't hold the microphone all afternoon. Re-opening the app puts
    /// the orb back in charge of a call that is still up.
    private var backgroundIdleTimer: Timer?
    private static let backgroundIdleTimeout: TimeInterval = 600

    /// When this call last went off-screen, or `nil` while it is on screen.
    private var offScreenSince: Date?

    /// Off-screen seconds this call has accumulated, across every stint of it.
    private var backgroundSeconds: TimeInterval = 0

    /// What could reach Mute and End while off-screen, latest wins, or `nil` for a call
    /// that never left the screen. `carPlayDisconnected()` updates it on a handover.
    private var backgroundSurface: String?

    /// Whether a car screen was attached at any point in this call. The surface above
    /// cannot say it: a drive with the phone awake spends no time off-screen at all.
    private var sawCarPlay = false

    /// The values `backgroundSurface` takes, in one place — they are read in a dashboard
    /// breakdown, so a second spelling of one is a silently split result.
    enum BackgroundSurface {
        static let liveActivity = "live_activity"
        static let carPlay = "carplay"
        static let unattended = "none"
    }

    /// Start the off-screen clock, and note what was in charge while it runs.
    private func beginOffScreenClock() {
        guard offScreenSince == nil else { return }
        offScreenSince = Date()
        if CarPlayPresence.isConnected {
            backgroundSurface = BackgroundSurface.carPlay
        } else {
            backgroundSurface = liveActivity.isRunning
                ? BackgroundSurface.liveActivity
                : BackgroundSurface.unattended
        }
    }

    /// Bank the open stint. Also called at the end of a call, since the ends most worth
    /// measuring — the idle timeout, the Lock Screen's End — happen off-screen.
    private func endOffScreenClock() {
        guard let offScreenSince else { return }
        backgroundSeconds += Date().timeIntervalSince(offScreenSince)
        self.offScreenSince = nil
    }

    /// When the device last locked during this call, or `nil` while it is unlocked.
    private var lockedSince: Date?

    /// Seconds this call spent on a locked device. A phone with no passcode never reports
    /// a lock at all, so this is a floor on hands-free use rather than a rate.
    private var lockedSeconds: TimeInterval = 0

    private func beginLockedClock() {
        guard lockedSince == nil else { return }
        lockedSince = Date()
    }

    private func endLockedClock() {
        guard let lockedSince else { return }
        lockedSeconds += Date().timeIntervalSince(lockedSince)
        self.lockedSince = nil
    }

    private var lifecycleObservers: [NSObjectProtocol] = []

    init() {
        observeAppLifecycle()
        // Also here, not only on `didBecomeActive`: this service is resolved from
        // the container, and if that happens after the app is already active the
        // notification has been and gone. The warmer's own interval guard makes the
        // overlapping case a no-op rather than two handshakes.
        ConnectionWarmer.warm()
    }

    /// Whether this session is one that can survive going off-screen — and therefore
    /// whether it gets a card, which is now requested long before it goes anywhere.
    ///
    /// Two things have to hold:
    /// - **A call, actually up.** `fullDuplex` plus `isConversing` — the call is
    ///   what survives backgrounding, and there is nothing to hold or to control
    ///   without one. A connected-but-not-dialled session goes off-screen costing
    ///   nothing, as does a disconnected or errored one.
    /// - **A control surface.** Live Activities enabled, *or* a car screen attached.
    ///   Off with no car is a legitimate setting, and a background call with no
    ///   control surface is a hot microphone with a meter running.
    ///
    /// **The car satisfies that reasoning rather than working around it**, which is
    /// why this is an `||` and not a special case. The clause was never about
    /// ActivityKit: it is about there being somewhere the user can reach Mute and End
    /// while the phone is not the thing in front of them. A CarPlay scene showing this
    /// call, with both buttons on it, is a *better* answer to that than a Lock Screen
    /// card — so a driver who has switched Live Activities off must still get a call
    /// that survives the screen going dark.
    private var canRunInBackground: Bool {
        guard fullDuplex != nil, isConversing else { return false }
        switch sessionState {
        case .disconnected, .error: return false
        // `.connecting` is included on purpose: a call still dialling is a live session
        // the user should be able to hang up from the Lock Screen.
        case .connecting, .ready, .listening, .processing, .responding: break
        }
        return LiveVoiceActivity.isAvailable || CarPlayPresence.isConnected
    }

    /// **The card is not created here any more, and that is the fix.** It used to
    /// be requested on `willResignActive`, which was reasoned about as "the last
    /// moment the app is still foreground". It is better read as the *first* moment
    /// it might not be, and the difference decided whether the feature worked:
    ///
    /// - Home button or app switcher: resign-active arrives while the app is still
    ///   rendered mid-animation, `Activity.request` sees a foreground app, and the
    ///   card appears. Lock the phone afterwards and it is already there.
    /// - Locking the screen directly: the display goes off and iOS calls the app
    ///   backgrounded almost at once, so the request throws
    ///   `ActivityAuthorizationError.visibility` — "started from the background".
    ///   Which is the one path that matters, and the one that failed.
    ///
    /// The margin is thin enough that the delivery of this notification is part of
    /// it: `queue: .main` *enqueues* the block rather than running it on the post
    /// (that is what passing `nil` does), so the handler is a run-loop turn late.
    ///
    /// So the request moved to where there is no race at all — `startConversation`,
    /// the moment the dial connects, with the app unambiguously on screen — and the
    /// card stays up for the whole call, foregrounded included. This is what every
    /// app with a working Lock Screen card does; a ride-share activity is requested
    /// when the ride starts, not when you pocket the phone. ActivityKit's foreground
    /// rule only constrains *starting* an activity, never keeping one.
    ///
    /// What is left here is the *stint* — the off-screen ten-minute idle bound —
    /// plus a retry of the request for a call whose dial-time attempt failed.
    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ handler: @escaping () -> Void) -> NSObjectProtocol {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
        }
        lifecycleObservers = [
            observe(UIApplication.willResignActiveNotification) { [weak self] in
                self?.beginBackgroundSession()
            },
            // `didEnterBackground`, not the `willResignActive` above it: only this one
            // means the app left the screen, not a Control Centre pull it comes back from.
            observe(UIApplication.didEnterBackgroundNotification) { [weak self] in
                self?.beginOffScreenClock()
            },
            // Data protection evicting its key, which is the nearest public signal to a
            // dark screen: no API reports display power. Lands ~10 s after the lock.
            observe(UIApplication.protectedDataWillBecomeUnavailableNotification) { [weak self] in
                self?.beginLockedClock()
            },
            observe(UIApplication.protectedDataDidBecomeAvailableNotification) { [weak self] in
                self?.endLockedClock()
            },
            observe(UIApplication.didBecomeActiveNotification) { [weak self] in
                self?.endOffScreenClock()
                // Back on screen: the orb and the in-app mute button are the
                // controls again. The call itself keeps running — foregrounding is
                // not hanging up — and neither is the card taken down, because
                // re-requesting it on the way back out is the race this stopped
                // running.
                self?.endBackgroundStint(reason: "app foregrounded")
                // The tap may be seconds away. Opening the connections now takes a
                // measured ~320 ms off the first dial of a launch — see
                // `ConnectionWarmer`. Fire and forget; nothing waits on it.
                ConnectionWarmer.warm()
            },
        ]
    }

    /// Put the card up for a call that is up.
    ///
    /// **Called from the foreground, the moment the dial connects** — see
    /// `observeAppLifecycle` for why that and not on the way out. Idempotent: the
    /// `isRunning` check is what makes the backgrounding retry free when the card is
    /// already there, which is the normal case.
    private func startLiveActivity(_ why: String) {
        guard !liveActivity.isRunning, canRunInBackground else { return }
        // **Never while a car screen is showing this call.** The card would be noise on
        // the Lock Screen behind a head unit that already carries the same Mute and End —
        // and it is the *request* that arms the ten-minute idle timer, so declining here
        // is also what stops a commute being hung up at a red light.
        //
        // Here rather than at the call sites because this is now the one place a card is
        // ever requested, which is what made the CarPlay case a two-line change instead of
        // a flag threaded through `beginBackgroundSession`.
        if CarPlayPresence.isConnected {
            RealtimeLog.log("live-activity: skipped (\(why)) — the car screen is the control surface")
            return
        }
        // No resting card: the queue is the card, and it appears when the walk starts.
        liveActivity.start(liveActivityState)
        guard liveActivity.isRunning else {
            // A failed request means no Mute and no End once the app goes off
            // screen, and a call the user cannot reach is one they cannot hang up
            // either — which bills by the minute. `start` has already logged why.
            RealtimeLog.log("live-activity: not up (\(why)) — an off-screen call would be unattended")
            return
        }
        RealtimeLog.log("live-activity: up (\(why))")
    }

    private func beginBackgroundSession() {
        guard !isBackgroundSessionActive, canRunInBackground else { return }
        // Normally a no-op: the card went up when the dial connected. This is the
        // retry for the calls where it didn't — Live Activities switched on
        // mid-call, or a request that failed on its own terms — and it is the
        // fallback now rather than the mechanism, so it runs in the one place that
        // is still foreground-ish and no longer has to be relied on there.
        startLiveActivity("backgrounding")
        // **A car claims the stint without a card, and deliberately without the idle
        // timer.** `startLiveActivity` declined to put one up (see it), so the
        // `isRunning` check below would refuse a call that has a perfectly good control
        // surface — the car's own screen, carrying the same Mute and End.
        //
        // Skipping `noteBackgroundActivity()` is the other half: ten minutes of silence
        // ending a call is right for a phone in a pocket and wrong for a commute, where
        // it is a hang-up in slow traffic. What bounds a car call instead is the scene
        // going away — `carPlayDisconnected()` — which is a real end-of-drive signal
        // where a quiet stretch is not.
        if CarPlayPresence.isConnected {
            isBackgroundSessionActive = true
            RealtimeLog.log("background: call held — the car screen is the control surface")
            return
        }
        // Only claim the stint if there is a control surface for it. Without one
        // the ten-minute clock would hang up a call the user has no card to see.
        guard liveActivity.isRunning else {
            RealtimeLog.log("background: no Live Activity — call runs on unattended")
            return
        }
        isBackgroundSessionActive = true
        noteBackgroundActivity()
        RealtimeLog.log("background: call held — Live Activity is the control surface")
    }

    /// The app came back on screen: stand the stint down and **leave the card up.**
    ///
    /// The two used to be one thing, and separating them is what lets the card
    /// outlive a trip through the foreground. What ends here is only the off-screen
    /// part — the ten-minute idle timeout, which exists to bound a call nobody is
    /// looking at and would be wrong to run against one on screen.
    private func endBackgroundStint(reason: String) {
        // No call, so any card is an orphan: an activity only exists while a live
        // call holds its process, so one standing over no call is left from a
        // session that is already gone. Same sweep `AppDelegate` does at launch,
        // for the case where this process outlived the call instead.
        guard isConversing else {
            endBackgroundSession(reason: reason, endingCall: false)
            return
        }
        backgroundIdleTimer?.invalidate()
        backgroundIdleTimer = nil
        guard isBackgroundSessionActive else { return }
        isBackgroundSessionActive = false
        RealtimeLog.log("background: stint ended (\(reason)) — card stays with the call")
    }

    /// Stand the stint down.
    ///
    /// `endingCall` is false when the app has simply returned to the foreground —
    /// the call keeps running, because that is what a foregrounded session does and
    /// the orb is now its control. It is true when the stint ends while still
    /// off-screen (the End button, the idle timeout, an error), which is the only
    /// case where the call itself has to be hung up: nothing else would, and a
    /// dismissed activity over a live call is a microphone with no way back to it.
    /// Returns the Live Activity dismissal task so the End intent can await the
    /// card actually leaving the Lock Screen before its process is allowed to
    /// suspend — see `LiveVoiceActivity.end()` for why that await is load-bearing.
    @discardableResult
    func endBackgroundSession(reason: String, endingCall: Bool) -> Task<Void, Never> {
        backgroundIdleTimer?.invalidate()
        backgroundIdleTimer = nil
        // The activity teardown runs before the `isBackgroundSessionActive`
        // guard, unconditionally. If the process died with a card up, the fresh
        // process relaunched to service the End intent has this flag at its
        // initial `false` while the orphaned card is still on the Lock Screen —
        // gating the teardown behind the guard is what made the X button
        // permanently inert there. `end()` with nothing to end is a cheap no-op.
        let dismissal = liveActivity.end()
        guard isBackgroundSessionActive else { return dismissal }
        // Cleared before `endConversation()`, which calls back here — the guard
        // above is what makes that re-entry a no-op rather than a loop.
        isBackgroundSessionActive = false
        // `idle` is the ten-minute off-screen timeout, and it is the one path through
        // here that nobody chose — everything else arrived because the user or an error
        // ended the call. Filing it as a hang-up would make the timeout invisible in
        // exactly the data written to measure it.
        if endingCall {
            endConversation(reason: reason == "idle"
                ? ConversationRecord.Reason.backgroundTimeout
                : ConversationRecord.Reason.userEnded)
        }
        RealtimeLog.log("background: stint ended (\(reason))")
        return dismissal
    }

    /// Restart the ten-minute clock. Called on every state change and every
    /// button press.
    ///
    /// **A no-op while a car is attached.** `beginBackgroundSession` never arms the
    /// timer on that path, but this is reached from two other places — every session
    /// state change and the Mute button — and either would arm it behind that
    /// decision's back. Belt and braces on purpose: the failure it prevents is a
    /// commute hung up at a red light.
    private func noteBackgroundActivity() {
        guard isBackgroundSessionActive, !CarPlayPresence.isConnected else { return }
        armIdleTimer()
    }

    /// The clock itself, without the guards above.
    ///
    /// **Separate because `carPlayDisconnected()` has to reach it.** That method runs
    /// inside the scene's own disconnect callback, where `CarPlayPresence.isConnected`
    /// may still answer true — so going through `noteBackgroundActivity()` would silently
    /// skip arming the timer for a call it has just handed to the Lock Screen. It would
    /// have healed on the next session state change, which is not a thing to leave to
    /// chance for a timer whose whole job is bounding an unattended microphone.
    private func armIdleTimer() {
        backgroundIdleTimer?.invalidate()
        let timer = Timer(timeInterval: Self.backgroundIdleTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                // `_ =`: the returned dismissal task matters to the End intent,
                // not to a timer — and the single-expression closure would
                // otherwise return it, breaking `assumeIsolated`'s inference.
                _ = self?.endBackgroundSession(reason: "idle", endingCall: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        backgroundIdleTimer = timer
    }

    /// A car screen arrived: note it, and relabel an open stint. Nothing else moves — a
    /// car call never arms the idle timer, and any card that is up stays up.
    func carPlayConnected() {
        guard isConversing else { return }
        sawCarPlay = true
        if offScreenSince != nil { backgroundSurface = BackgroundSurface.carPlay }
    }

    /// The car screen has gone away. Find the call another control surface, or end it.
    ///
    /// **This is what replaces the ten-minute idle timer for a CarPlay call**, and it is
    /// the same invariant from the other end: a call that survives off-screen must have
    /// somewhere the user can reach Mute and End. Unplugging removes the surface the
    /// stint was claimed with, so one of three things is true and each has an answer:
    ///
    /// 1. **The app is on screen** — the orb has the call, exactly as it does when a
    ///    backgrounded call is foregrounded. Nothing to do but release the stint.
    /// 2. **It isn't, but Live Activities are available** — hand over to the Lock Screen
    ///    card, which is the ordinary off-screen path, and arm the idle timer on the way.
    ///    That is correct here: a phone in a pocket is exactly what that timeout was
    ///    written for, and the car is no longer the thing bounding the call.
    /// 3. **Neither** — there is nowhere to hang up from, so hang up.
    ///
    /// **The handover is spelled out rather than calling `beginBackgroundSession()` or
    /// `startLiveActivity(_:)`, and that is a correctness fix rather than a style
    /// choice.** Both of those ask `CarPlayPresence.isConnected`, and this runs inside the
    /// scene's *own* disconnect callback — where the scene may still be present in
    /// `UIApplication.connectedScenes`. Going through either would decline the card and
    /// claim the stint anyway, leaving a call running with its control surface already
    /// gone: precisely the hot-microphone-with-a-meter-running state `canRunInBackground`
    /// exists to refuse. So the card is requested directly here, and only here.
    ///
    /// **Not simply "end the call on disconnect", which was the first instinct.** That
    /// would hang up on a driver who parked, unplugged, and carried on the conversation
    /// walking to the door — and worse, an ignition cycle that drops and re-attaches the
    /// scene would cost the call each time. Only case 3 ends it, and case 3 is the one
    /// where the alternative is a hot microphone nobody can reach.
    ///
    /// Unverified on hardware: what `willResignActiveNotification` does with an active
    /// CarPlay scene and a locked phone. If resign-active fires on unplug *before* this,
    /// case 2 has already happened by the time we get here and `beginBackgroundSession`
    /// is a no-op on its own guard — which is harmless, but means the log line below is
    /// the thing to read on a real head unit.
    func carPlayDisconnected() {
        guard isConversing else { return }
        // Released before the re-run, because `beginBackgroundSession` guards on it —
        // this stint's surface is the thing that just disappeared.
        backgroundIdleTimer?.invalidate()
        backgroundIdleTimer = nil
        isBackgroundSessionActive = false

        if UIApplication.shared.applicationState == .active {
            RealtimeLog.log("carplay: unplugged with the app on screen — the orb has the call")
            return
        }

        if LiveVoiceActivity.isAvailable {
            liveActivity.start(liveActivityState)
            if liveActivity.isRunning {
                isBackgroundSessionActive = true
                // The stint carries on, so the clock is not reopened — but the surface it
                // was opened with is the one that just went away.
                backgroundSurface = BackgroundSurface.liveActivity
                // `armIdleTimer()`, not `noteBackgroundActivity()` — see that method.
                armIdleTimer()
                RealtimeLog.log("carplay: unplugged — the Live Activity has the call")
                return
            }
        }

        RealtimeLog.log("carplay: unplugged with no other control surface — hanging up")
        endConversation(reason: ConversationRecord.Reason.carPlayDisconnected)
    }

    /// The Live Activity's Mute button.
    ///
    /// The same call as the in-app mute button, and deliberately nothing more:
    /// `setConversationMuted` closes the `RTCAudioTrack` and leaves the call, its
    /// context and the assistant's half of the turn exactly where they were. It is
    /// not an interrupt — a hands-free reply is cut off by talking over it, and a
    /// mute that also silenced the assistant would take away the one thing this
    /// button is for: staying in the call while somebody in the room talks to you.
    ///
    /// **Async, and that is not decoration.** The mic closes synchronously, but
    /// the Live Activity redraw that says so is an async write into ActivityKit,
    /// spawned from `isMuted`'s `didSet`. The intent calling this is running on
    /// background time the system reclaims the instant its `perform` returns, so
    /// without the `settle()` the write raced suspension and was dropped about as
    /// often as not — leaving a button labelled "Mute" over an already-muted mic.
    /// The next tap then unmutes, in the room the user muted for. Same failure
    /// mode the End button had, fixed the same way (2026-08-10).
    func toggleBackgroundMute() async {
        noteBackgroundActivity()
        setConversationMuted(!isMuted)
        await liveActivity.settle()
    }

    /// What the Lock Screen should show right now.
    ///
    /// `isMuted` is carried separately from the phase because the two are
    /// orthogonal here: a muted call still reports `.speaking` while the assistant
    /// finishes its answer, and the button has to say Unmute throughout.
    private var liveActivityState: VoiceActivityAttributes.ContentState {
        let phase: VoiceActivityAttributes.Phase
        switch sessionState {
        case .connecting: phase = .connecting
        case .processing: phase = .thinking
        case .responding: phase = .speaking
        // The mic on this path is open for the whole call, so anything that isn't
        // the model working is the call listening. `.ready`, `.disconnected` and
        // `.error` are only reachable as the call is being torn down, at which
        // point the activity is already on its way out.
        case .listening, .ready, .disconnected, .error: phase = .listening
        }

        // No transcript is sent. There was a `line` here — the live transcript
        // while listening, the answer once there was one — and it was removed
        // on instruction: a Lock Screen is a public surface, and echoing
        // dictation onto it shows half a conversation to whoever is looking at
        // the phone. The saving is not only privacy: that field changed as
        // words arrived, so the activity was pushed twice a second for its whole
        // life. It now updates only when the phase, the mute flag or the
        // running tool changes.
        return VoiceActivityAttributes.ContentState(
            phase: phase,
            isMuted: isMuted,
            detail: turnSteps.last(where: \.isRunning)?.label,
            card: liveCard
        )
    }

    /// **Not gated on the stint any more.** The card is up for the whole call now,
    /// so a phase change while the app is on screen is a phase change the Dynamic
    /// Island is showing — and the state it holds has to be right the instant the
    /// phone is locked, not half a second after. `update` no-ops when there is no
    /// activity, which is the only guard this needs.
    private func syncLiveActivity() {
        liveActivity.update(liveActivityState)
    }

    // MARK: - The call

    /// True while a call is up: the mic is open across turns and server VAD takes
    /// them. There is no other kind of session.
    ///
    /// **The `didSet` is what keeps `micIsLive` honest.** This flag is cleared from five
    /// places — teardown, two error paths, a failed reconnect and a failed dial — and a
    /// microphone flag that had to be remembered at each of them would be forgotten at
    /// one of them. Derived here instead, so "no call" can only ever mean "no live mic".
    @Published var isConversing: Bool = false {
        didSet {
            if !isConversing, micIsLive { micIsLive = false }
            // The end cue may keep the audio client alive for another fraction of a
            // second, but the screen has already left the call. Do not let the client's
            // late opening-release callback keep the idle orb in its purple muted state.
            if !isConversing, micHeldForOpening { micHeldForOpening = false }
        }
    }

    /// True once the microphone is open and the phone is transcribing — which happens
    /// **during** the dial, roughly 150 ms after the tap, not at `.listening`.
    ///
    /// It exists because the screen was telling the user to wait through a stretch in
    /// which the phone could hear them perfectly well. `CommandView` reads it to invite
    /// speech at the earliest honest moment instead of at the moment the network is
    /// ready. See `FullDuplexVoiceClient.announceReady`.
    @Published var micIsLive: Bool = false

    /// Dial the call.
    ///
    /// Everything expensive is here rather than in `connect()`: session setup, the
    /// SDP handshake, and the 400 ms VPIO pre-roll the echo canceller needs before
    /// any audio plays. `isConversing` is published up front so the tap redraws
    /// immediately, then corrected if the call refuses to come up.
    /// Dial into `conversationId`.
    ///
    /// **The conversation is a parameter, not something read out of the air.** The caller
    /// starts one (`beginConversation()`) and passes its id here, so the session's own
    /// scope, every `CommandRecord` it files, its dispatches and its stored context are all
    /// the same id by construction. When it was ambient, the mint captured it at dial time
    /// while everything else followed the live value, and anything that changed it mid-call
    /// split one call into two — which is what happened on 2026-08-13.
    /// Speak the first-call opening into a session already established. See
    /// `FullDuplexVoiceClient.speakOpening`.
    /// Hold the first-call opening until the flow ends. See
    /// `FullDuplexVoiceClient.deferOpening`.
    func deferOpening() { fullDuplex?.deferOpening() }

    func speakOpening() { fullDuplex?.speakOpening() }

    /// - Parameter announcingConnect: `false` suppresses the dial cue and its haptic, for a
    ///   call placed programmatically rather than by a tap. See
    ///   `FullDuplexVoiceClient.start(announcingConnect:)`.
    func startConversation(
        in conversationId: UUID,
        announcingConnect: Bool = true,
        opening: SessionOpening = .none
    ) {
        guard let client = fullDuplex, !isConversing else { return }
        activeConversationId = conversationId
        isConversing = true
        isMuted = false
        clearMuteSettling()
        // A memo posting mid-call would be a write-capable agent that `maxLiveDispatches`
        // cannot see — that cap counts only the dispatches this call started. Set before
        // anything can await, so there is no window where a Send tap slips through.
        memoQueue.isPaused = true
        sessionState = .connecting
        responseText = ""
        answerIsStale = false
        turnSteps = []
        // Ahead of the queue step: a fully local call has no mail to prepare.
        if LocalVoiceSettings.allLocal {
            guard LocalVoiceBrain.onDeviceAvailable else {
                let failure = LocalVoiceBrain.NoOnDeviceModel()
                RealtimeLog.log("local-voice: all-local chosen but \(failure.localizedDescription)")
                isConversing = false
                clearFeedFocus()
                resumeMemoQueue()
                sessionState = .error(failure.localizedDescription)
                return
            }
            beginLocalVoice(engine: .onDevice, reason: "fully local mode")
            return
        }
        if opening == .emailQueue {
            beginStep("prepare_email_queue")
        }
        Task { [weak self] in
            do {
                try await client.start(announcingConnect: announcingConnect, opening: opening)
                // Ended during the handshake, and the consequence if it isn't
                // caught is a call nobody is in, holding the microphone open.
                guard let self, self.isConversing else {
                    RealtimeLog.log("fullduplex: ended before it connected — closing the call")
                    client.stop()
                    return
                }
                RealtimeLog.log("fullduplex: connected")
                // **The Lock Screen card goes up here, on a foreground app, and
                // stays up for the whole call.** Requesting it on the way out
                // instead is what made locking the phone directly show nothing:
                // ActivityKit refuses a request from a background app and a
                // display-off lock backgrounds this one before the notification
                // handler runs. See `observeAppLifecycle`.
                self.startLiveActivity("dial connected")
                // Recovery runs inside the client so it can join the automatic opening.
                // A memo that finishes after that read is recovered on the next dial.
                if self.memoQueue.hasSendingItems {
                    RealtimeLog.log("memos: a note is still posting — its answer lands "
                        + "on the next connect, not this one")
                }
            } catch {
                RealtimeLog.log("fullduplex: start failed \(error.localizedDescription)")
                if let self, self.isConversing, let engine = self.localVoiceEngine(after: error.localizedDescription) {
                    self.beginLocalVoice(engine: engine, reason: "dial failed: \(error.localizedDescription)")
                    return
                }
                self?.isConversing = false
                self?.clearFeedFocus()
                // Without this a dial that never connected leaves notes unsendable for
                // the rest of the launch, with nothing on screen to say why. Drains as
                // well as resumes, which is free when the dial failed for want of a
                // network: `drain()` returns at its own `isOnline` guard.
                self?.resumeMemoQueue()
                self?.sessionState = .error(error.localizedDescription)
            }
        }
    }

    /// - Parameter reason: what to file the conversation's row under. Defaults to the
    ///   user having done it, which is true of the End button, the Live Activity and a
    ///   spoken "end session" — the off-screen idle timeout passes its own, because a
    ///   call that timed out is not a call somebody hung up.
    func endConversation(reason: String = ConversationRecord.Reason.userEnded) {
        // The call is the background stint's whole reason to exist, so it cannot
        // outlive it. Ending here rather than only from the End button covers the
        // other direction too — a Siri intent or a foregrounded tap that hangs up
        // while an activity is somehow still live. `endingCall: false` because that
        // is what is happening on the next line; the guard in there stops the
        // recursion either way.
        endBackgroundSession(reason: "call ended", endingCall: false)
        // **Before `stop()`, deliberately.** Tearing down raises `onEnded` from the
        // transport, and whichever reason lands first is the one kept — so recording the
        // user's intent here is what stops a hang-up being filed as a transport failure
        // it actually caused.
        finishConversation(reason: reason)
        // Pause the durable queue on the same action that ends the call, not on the
        // next dial. The latter is too late: a queued continuation can advance and
        // inject "moved on" during the end-cue window. `pauseForConversationEnd`
        // checkpoints the current message before taking the in-memory walk down.
        triageQueue.clear()
        let queue = localTriage
        let store = Container.shared.mailStore()
        Task { await queue.pauseForConversationEnd(store: store) }
        // **`stopWithEndCue`, not `stop`** — this is the one path that is a person
        // leaving a conversation, so it is the one that gets the sound. It returns
        // before the transport is actually down; everything below runs against a call
        // that has ~0.75 s left to sound, which is why the screen leaves the call at
        // once and the tone plays out behind it. See that method for why the other
        // three callers of `stop()` must not move.
        fullDuplex?.stopWithEndCue()
        stopLocalVoice()
        isConversing = false
        // See `clearCard()`: this path does not reach `disconnect()`, so without it the
        // next dial opens on the last call's card.
        clearCard()
        clearFeedFocus()
        // Clear completed tool status when the call and durable queue end.
        turnSteps = []
        // The droplets go with the call: a job that outlives it reports through the next
        // dial's digest, not a bead orbiting a dead session.
        liveDispatches = []
        // The microphone and the dispatch budget are both free again — so anything that
        // arrived during the call, or was stopped part-way through a drain by it, goes
        // now rather than waiting for the next launch.
        resumeMemoQueue()
        isMuted = false
        clearMuteSettling()
        responseText = ""
        answerIsStale = false
        sessionState = .ready
        // **The conversation ends with the call.** Cleared after `stop()`, deliberately:
        // a turn that finalizes on the way down still files against the conversation it
        // belonged to. From here there is no conversation until the next dial starts one,
        // so nothing — a late queue refresh, a recovered dispatch — can file under a
        // thread whose call is over.
        RealtimeLog.log("conversation: ended \(activeConversationId?.uuidString ?? "none")")
        activeConversationId = nil
    }

    /// Hang up because the user said so, which is not the same call as the button.
    ///
    /// **The card is dismissed first, and awaited, before the call comes down.** The
    /// other order is the bug: `endConversation()` spawns the Live Activity dismissal
    /// and drops the task, then `stop()` deactivates the audio session — the only
    /// thing keeping a backgrounded process alive — so the process can be suspended
    /// before ActivityKit's IPC runs, leaving a card on the Lock Screen offering Mute
    /// and End on a call that is already dead. `LiveVoiceActivity.end()` documents
    /// that race; this is the same one from a new direction.
    ///
    /// The Live Activity's own End button gets away with dismissing last because
    /// `EndBackgroundVoiceSessionIntent.perform()` awaits the task and the system
    /// keeps the process alive for exactly as long as `perform` runs. **A spoken
    /// command has no `perform` to borrow time from**, so the only thing holding this
    /// process up is the audio session it is about to tear down — hence the
    /// inversion, which needs no borrowed time at all.
    ///
    /// `endingCall: false` because the next line does that. Correct foregrounded too:
    /// with no stint running, `endBackgroundSession` sweeps for orphans and returns
    /// early, and awaiting that costs nothing.
    ///
    /// `settle()` is not the tool here — `end()` clears `inFlight`, so there would be
    /// nothing left to await.
    func endBySpokenCommand() async {
        await endBackgroundSession(reason: "ended by voice", endingCall: false).value
        endConversation()
    }

    /// The microphone track is still catching up with the button.
    ///
    /// **Vestigial since 2026-08-26 and kept deliberately.** It was written when
    /// unmuting brought libwebrtc's recording audio unit back up and the mic was not
    /// live for up to 290 ms after the tap. Mute is now a zeroed capture buffer, so
    /// there is no gap and this can no longer become true. Left wired rather than
    /// removed — a working surface, and its removal is its own change.
    @Published private(set) var isMuteSettling = false

    /// Which toggle the spinner belongs to. Rapid taps mean an *earlier* call can
    /// settle after a later one was issued, and without this its completion would
    /// clear the spinner the later tap is still waiting on.
    private var muteGeneration = 0
    private var muteSettleTask: Task<Void, Never>?

    /// The one pending post-write calendar pull — see `onToolDone`. Kept so a burst of
    /// calendar writes debounces to a single pass timed off the last one.
    private var calendarPullTask: Task<Void, Never>?

    /// Drop any spinner the call left behind.
    ///
    /// Every path that forces `isMuted` back to false — dial, hang up, teardown —
    /// goes through here, because those assign the flag directly rather than calling
    /// `setConversationMuted`, and a toggle in flight when the call goes down has
    /// nothing left to report.
    private func clearMuteSettling() {
        muteGeneration &+= 1
        muteSettleTask?.cancel()
        muteSettleTask = nil
        isMuteSettling = false
    }

    /// How long a toggle may take before it is worth saying so.
    ///
    /// Both directions are now a flag write and land far inside this, so nothing is
    /// ever shown — a spinner that appears and vanishes within a frame or two reads
    /// as a glitch. Unmute used to be the slow one; see `isMuteSettling`.
    private static let muteSettleGrace: Duration = .milliseconds(150)

    /// Mute mid-conversation so the assistant can finish without being cut off.
    /// Not the same as ending: the session and its context stay.
    func setConversationMuted(_ muted: Bool) {
        isMuted = muted
        localVoice?.setMuted(muted)

        muteGeneration &+= 1
        let generation = muteGeneration
        muteSettleTask?.cancel()
        muteSettleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.muteSettleGrace)
            guard !Task.isCancelled, let self, self.muteGeneration == generation else { return }
            self.isMuteSettling = true
        }

        // Muting zeroes the capture buffer rather than closing the track — see
        // `CaptureTapFanout.muted`. Closing it stopped the audio unit on this build,
        // and coming back out of that is what cut Jo off mid-answer.
        fullDuplex?.setMuted(muted) { [weak self] in
            guard let self, self.muteGeneration == generation else { return }
            self.muteSettleTask?.cancel()
            self.isMuteSettling = false
        }
        // No transport means no call, so nothing will ever settle it.
        if fullDuplex == nil {
            muteSettleTask?.cancel()
            isMuteSettling = false
        }
        RealtimeLog.log("conversation: mic \(muted ? "muted" : "live")")
    }

    /// Stop the assistant mid-response.
    ///
    /// What was already said stays on screen and stays in the assistant's
    /// memory. Someone who taps the orb mid-reply has heard enough, not decided
    /// the answer never happened — wiping it means they can't read the half they
    /// wanted, and the follow-up ("what was that second one?") arrives with no
    /// context.
    /// The turn is finalized so a stopped answer lands in History like any other.
    func interrupt() {
        RealtimeLog.log("interrupt() at state=\(sessionState.label)")
        let wasWorking = sessionState == .responding || sessionState == .processing
        fullDuplex?.interrupt()
        // A tap on the orb mid-reply: the user cut it off, so the stored answer
        // is marked the same way a spoken barge-in is.
        //
        // **`commandStartTime` decides, not the state**, for the reason `onBargeIn`
        // gives at its own guard: `finalizeTurn` clears it, so a nil one means this
        // turn is already filed. `.responding` outlives the answer — the audio is
        // still draining and `output_audio_buffer` owns the transition to
        // `.listening` — so a tap during the tail passed `wasWorking` on a finished
        // turn and filed it a second time, marked interrupted and with no duration.
        // That is about a fifth of the duplicate rows in the store as of 2026-08-14; the
        // rest came from the double final this fixes alongside.
        if wasWorking, commandStartTime != nil { finalizeTurn(interrupted: true) }
        // A conversation's mic never closed, so idle here is still listening.
        sessionState = isConversing ? .listening : .ready
    }

    // MARK: - Conversation memory

    /// Exchanges the assistant is carrying as context. Published so the screen
    /// can say so — the UI shows one turn at a time, which reads as amnesia, and
    /// a user who doesn't believe they're remembered repeats themselves.
    @Published var memoryTurns: Int = 0

    /// The conversation this session's turns belong to — **`nil` when there isn't one.**
    /// Stamped onto every saved `CommandRecord` so History can group them and a later
    /// session can pick the same thread back up.
    ///
    /// **This was `= UUID()`, and that was the bug.** It gave the service a conversation
    /// from the moment it was constructed, before anything had dialled — so an id existed
    /// that no call was ever minted against, and everything that reads this with no call
    /// up (the queue refresh on appear, a turn save, a recovered dispatch) filed under it.
    /// It arrived on 2026-07-26 with long-term memory (`b9efd61`), where it was
    /// reasonable: a conversation was then a client-side grouping of stored records and
    /// nothing minted anything. A conversation is a *call* now, so the id cannot predate
    /// one. It is created by `beginConversation()` and handed to `startConversation(in:)`,
    /// which is the only thing that passes it to the call — and cleared when the call ends.
    ///
    /// Optional rather than a sentinel because `nil` is the state the callers have to
    /// handle anyway: no conversation means no queue to refresh and no thread to file
    /// against, and both of those are answers, not edge cases.
    @Published private(set) var activeConversationId: UUID?

    /// Set only by History's Resume action. A leftover active id after a failed call is
    /// conversation identity, not evidence that the user asked to continue it.
    private var pendingResumeConversationId: UUID?

    func takePendingResumeConversationId() -> UUID? {
        defer { pendingResumeConversationId = nil }
        return pendingResumeConversationId
    }

    /// Adopt a stored conversation as this session's context.
    ///
    /// **The id is what does the work.** A Realtime session cannot be handed a
    /// transcript: it is set up fresh on every dial from instructions, tools and audio
    /// config, with no field that means "carry on from there". What it does take is
    /// `activeConversationId` — read at dial time by `connectFullDuplex`'s closure — and
    /// the session's stored context is scoped to it, so the resumed conversation's earlier
    /// turns and cached lookups are what `search_context` finds. The turns reach the model
    /// by being *searchable*, not by being carried, which is why nothing is injected here.
    ///
    /// The turn-based path did carry them, assembling its own request per turn from
    /// a seeded list. `ConversationMemory` survives it because
    /// this still needs the exchange count: `memoryTurns` is what dismisses the
    /// resume card and reveals the "New" chip, so reporting 0 here would leave
    /// Continue with no way to start fresh.
    /// - Returns: whether the conversation was adopted. **False means don't dial** — the
    ///   caller is about to ask for a call and there is no conversation to put it in.
    @discardableResult
    func resume(_ conversation: Conversation) -> Bool {
        // **A thread with no conversation id cannot be resumed, and nothing is invented
        // here.** Legacy untagged records are grouped on a pause and given the first
        // record's own id to be `Identifiable` with; dialling under it would scope the
        // call to a value no turn, no context row and no queue cursor has ever seen.
        // History doesn't offer Resume on those rows, so this is the second gate rather
        // than the message — refusing loudly in the log and changing nothing.
        guard let id = conversation.resumableId else {
            RealtimeLog.log("memory: cannot resume \(conversation.id) — no conversation id")
            return false
        }
        pendingResumeConversationId = id
        activeConversationId = id
        memoryTurns = ConversationMemory.turns(from: conversation.records).count / 2
        responseText = ""
        answerIsStale = false
        RealtimeLog.log("memory: resumed conversation \(conversation.id) with "
            + "\(memoryTurns) exchanges (reachable by conversation id)")
        // A call already up keeps the scope it was minted with. Resuming from the
        // History sheet mid-call therefore files the *next* turns under the resumed
        // conversation and leaves this call searching the one it dialled for. Logged rather than blocked —
        // hanging up a live call to change a scope is the worse of the two surprises.
        if isConversing {
            RealtimeLog.log("memory: the running call keeps its minted scope — the "
                + "resumed conversation is searchable from the next dial")
        }
        return true
    }

    /// Start a conversation and hand back its id, for the caller to pass to the dial.
    ///
    /// **The id is created here and nowhere else.** A dial is what makes a conversation,
    /// so the sequence is: begin one, take its id, pass it into
    /// `startConversation(in:)`, which is what carries it into the call and makes the id
    /// the *voice agent's* session scope too. Returning it rather than
    /// leaving the caller to read the property back is the point: an ambient id read at
    /// two different moments is exactly how one call ended up filed as two.
    ///
    /// History keeps every past turn — only the context the assistant reasons with resets.
    /// - Parameter id: the conversation's id, when it was allocated before this call.
    ///   **This is how a prewarmed mint keeps the one-id rule rather than breaking it.**
    ///   A dial that starts its session setup early has to know the id before the
    ///   conversation's state is reset, because the id is what the session is scoped
    ///   on. Allocating the `UUID` at the press and handing it in here is still
    ///   one id, created once, travelling in one direction — what 2026-08-13 cost was an
    ///   *ambient* id read at two different moments, which this is not.
    /// - Parameter continuing: this id already had a conversation — a resume, or a call
    ///   that dropped without anybody ending it. Derived rather than passed, because the
    ///   caller's answer and this property's are the same answer and two of them drift.
    @discardableResult
    func beginConversation(id: UUID = UUID()) -> UUID {
        let continuing = id == activeConversationId
        activeConversationId = id
        responseText = ""
        answerIsStale = false
        lastCommandText = ""
        lastResponseText = ""
        turnSteps = []
        // Before `startLiveActivity` asks for the resting card, so this can only clear a
        // card from a previous call and never the one this dial is about to draw.
        clearCard()
        clearFeedFocus()
        // The count `resume(_:)` worked out from the stored turns survives a continued
        // dial; a new conversation has none by definition.
        if !continuing { memoryTurns = 0 }
        // **A continued conversation has to be endable again.** `finishConversation`
        // fires once per id and remembers which ones it has written, so an id that
        // ended earlier in this app run — the drop that caused the re-dial, or the
        // conversation History resumed — would never record the end of *this* call and
        // its row would read as live forever.
        endedConversations.remove(id)
        Container.shared.voiceCall().conversationStarted(id)
        RealtimeLog.log("conversation: \(continuing ? "continued" : "started") \(id)")
        recordConversationStart(id)
        return id
    }

    // MARK: - The conversation's own row

    /// Conversations already written as ended, so the second path to arrive is a no-op.
    ///
    /// **Both paths genuinely fire.** `endConversation()` calls `fullDuplex?.stop()`,
    /// which tears down, and a teardown that came from a transport failure raises
    /// `onEnded` on its own — so a call can reach this twice with two different reasons.
    /// First writer wins, because the first one is the one that knows *why*: a user who
    /// pressed End caused the transport close that follows, not the other way round.
    private var endedConversations: Set<UUID> = []

    /// Record that a call began.
    ///
    /// Written at dial rather than at the end, so a call the app never comes back from —
    /// a crash, a force-quit — still leaves evidence it happened. That row keeps
    /// `endedAt` nil forever, which is why nothing may read a nil end as "still live".
    ///
    /// **A continued conversation rewrites its row, and that is the intended reading.**
    /// One id can now span two calls — a resume, or a re-dial after a drop — and the row
    /// describes *one* call, so it describes the live one: `startedAt` moves to this dial
    /// and the earlier `endedAt` is cleared. Both consumers want exactly that, since both
    /// ask about the call happening now — is the call that dispatched this job over, and
    /// how long has this one been up against the 60-minute cap. The thread's own span is
    /// derived from its turns in `Conversation`, and is unaffected.
    private func recordConversationStart(_ id: UUID) {
        let startedAt = Date()
        // The off-screen clock is per call, and it opens here rather than only on
        // `didEnterBackground` because a call dialled from a shortcut can start off-screen.
        backgroundSeconds = 0
        backgroundSurface = nil
        offScreenSince = nil
        sawCarPlay = CarPlayPresence.isConnected
        lockedSeconds = 0
        lockedSince = nil
        if !UIApplication.shared.isProtectedDataAvailable { beginLockedClock() }
        // `.background` and not merely "not active": a shortcut foregrounding the app
        // dials through an `.inactive` transition that never left the screen.
        if UIApplication.shared.applicationState == .background { beginOffScreenClock() }
    }

    /// Record that a call ended, once, with the first reason offered.
    ///
    /// **Called from both the button and the SDK, and it has to be.** `endConversation()`
    /// covers what the user did — End, the Live Activity, the background timeout — and is
    /// the only place that knows the intent. `onEnded` covers what happened *to* the
    /// call: a dead transport, and the far side closing the session, which is OpenAI's
    /// 60-minute cap and is invisible from every other vantage point in the app. Wiring
    /// only one of them would systematically lose the ends that matter most.
    ///
    /// **`reconnect` is excluded at the source**, not here: `teardown` is the first half
    /// of a reconnect, so `onEnded` is deliberately not raised on that path. A guard in
    /// this method could not tell the difference.
    func finishConversation(reason: String) {
        guard let id = activeConversationId, !endedConversations.contains(id) else { return }
        endedConversations.insert(id)
        if let owner = backend.userId {
            Container.shared.voiceCall().conversationEnded(id, owner: owner)
        }
        RealtimeLog.log("conversation: recording end of \(id) — \(reason)")
        // The same three numbers the row carries, sent where a dashboard can reach them.
        // This method already fires exactly once per conversation — the guard above is what
        // makes that true — so it is the one safe place to count a call.
        endOffScreenClock()
        endLockedClock()
        // The four numbers the event carries, where a device console can read them back.
        RealtimeLog.log("""
            conversation: \(Int(backgroundSeconds))s off-screen, \(Int(lockedSeconds))s locked, \
            surface \(backgroundSurface ?? "none — on screen throughout"), carplay \(sawCarPlay)
            """)
        pendingBrainSteps = []
        backgroundSeconds = 0
        backgroundSurface = nil
        lockedSeconds = 0
        sawCarPlay = false
    }

    /// Let queued notes send again, and send them.
    ///
    /// The counterpart to the `isPaused` set at dial. Called from every way a call
    /// stops being live — the End button and its relatives through `endConversation`,
    /// a close performed by the far side through `onEnded`, and a dial that never
    /// connected from the `catch` in `startConversation`. Idempotent, and cheap when
    /// there is nothing to do: `drain()` returns at its own guard on an empty queue.
    ///
    /// **Three callers rather than one, because the three know different things and no
    /// single point sees all of them.** `finishConversation` looks like the place —
    /// it is the documented meeting point of the button and the SDK — but it fires once
    /// per conversation by design, so putting the resume there would drop it whenever
    /// the two paths raced, which is exactly the failure being fixed.
    private func resumeMemoQueue() {
        memoQueue.isPaused = false
        Task { [memoQueue] in await memoQueue.drain() }
    }

    // MARK: - Turn finalize

    /// - Parameter interrupted: the user cut this reply off. Only the *stored*
    ///   copy is marked — `responseText` is what the screen is showing, and
    ///   stamping that would put the marker in front of the user.
    private func finalizeTurn(interrupted: Bool = false) {
        lastResponseText = interrupted
            ? responseText + CommandRecord.interruptedMarker
            : responseText
        // Close anything still open first: an interrupted turn leaves a running
        // step behind, and a step with no end reads as a tool that never returned.
        closeOpenSteps()
        lastTurnSteps = turnSteps.map { step in
            CommandRecord.ToolStep(
                tool: step.tool,
                // 0 is the "we don't know" the hosted-MCP path reports, not a
                // measurement — see `CommandRecord.ToolStep.milliseconds`.
                milliseconds: step.serverMilliseconds.flatMap { $0 > 0 ? $0 : nil }
            )
        }
        lastServiceName = Self.inferService(from: lastCommandText)
        let duration = commandStartTime.map { Date().timeIntervalSince($0) } ?? 0
        lastDuration = duration
        // Read and cleared together with the rest of the turn's fields, for the
        // reason `lastCompletedTurn` exists at all: a value left standing outlives
        // the exchange it belongs to and gets filed against the next one.
        let latency = lastTurnLatency
        lastTurnLatency = nil
        commandStartTime = nil

        // A turn with nothing said back isn't a turn worth filing — the old save
        // guarded on this too, and it is the one place that can still decline.
        guard !lastResponseText.isEmpty else { return }
        let brainSteps = pendingBrainSteps
        pendingBrainSteps = []
        lastCompletedTurn = CommandRecord(
            commandText: lastCommandText.isEmpty ? "Voice command" : lastCommandText,
            responseText: lastResponseText,
            serviceName: lastServiceName,
            serviceIcon: CommandRecord.icon(for: lastServiceName),
            status: .success,
            durationSeconds: duration,
            conversationId: activeConversationId,
            toolSteps: lastTurnSteps.isEmpty ? nil : lastTurnSteps,
            latency: latency,
            brainSteps: brainSteps.isEmpty ? nil : brainSteps
        )
    }

    // MARK: - Service inference

    /// Which service a turn gets filed under in History.
    ///
    /// **Only the services the assistant can actually reach.** It used to guess
    /// between eleven, five of which have never been connectable — "what are my
    /// open issues" filed as Linear, "post that" as Typefully, "which file" as
    /// Drive — and every one of those labels became a filter chip on the History
    /// screen offering to narrow a list by a service that does not exist here.
    /// A service joins this ladder through its connector's `inferenceKeywords`;
    /// `ConnectionsService.connectedServices` is what then decides whether its
    /// chip appears.
    ///
    /// Still a keyword guess on the user's words, and still rough — it labels a
    /// row, it does not route anything. Two keywords went with the services that
    /// owned them rather than being dropped: "issue" and "pr" are GitHub's. `pr` is matched with a trailing space because bare
    /// `contains("pr")` hits "approve", "print" and "surprise"; `app` and `ci`
    /// are gone for the same reason ("happening", "decide") and were never worth
    /// the false positives.
    /// `static` and internal rather than private: History's Dispatch panel files
    /// each job under the same ladder (a dispatch row carries no service of its
    /// own, only the task's words), and two keyword ladders would drift.
    static func inferService(from text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("email") || lower.contains("gmail") || lower.contains("inbox")
            || lower.contains("mail") { return "Gmail" }
        for connector in ConnectorRegistry.all where connector.historyIcon != nil
            && connector.inferenceKeywords.contains(where: lower.contains) {
            return connector.displayName
        }
        if lower.contains("calendar") || lower.contains("meeting") || lower.contains("schedule")
            || lower.contains("invite") || lower.contains("invitation")
            || lower.contains("event") { return "Calendar" }
        // No `Kiloforge` branch since 2026-08-19: the operator-only MCP that made
        // "build" and "testflight" mean something came off the mint, so a turn
        // labelled that way would name a service nothing can reach. Unlike GitHub
        // and Notion — kept here because a question about a pull request is still
        // about a pull request — there is no user-facing subject left to label.
        // `CommandRecord.knownServices` keeps the row so stored turns still draw.
        return "General"
    }
}

// MARK: - Local voice

extension RealtimeService {
    /// Which brain a local call would get now, or nil when a local call must not stand in:
    /// the failure was the microphone itself, or there is nothing to answer with.
    func localVoiceEngine(after failure: String) -> LocalVoiceBrain.Engine? {
        let text = failure.lowercased()
        if text.contains("microphone") || text.contains("permission") { return nil }
        let connectivity = Container.shared.connectivity()
        connectivity.start()
        let hasKey = !(OpenAIKeyService.current ?? "").isEmpty
        return LocalVoiceBrain.engine(hasKey: hasKey, online: connectivity.isOnline,
                                      onDeviceAvailable: LocalVoiceBrain.onDeviceAvailable)
    }

    /// Opens the local call on the conversation that is already in progress.
    func beginLocalVoice(engine: LocalVoiceBrain.Engine, reason: String) {
        RealtimeLog.log("local-voice: standing in for Live on \(engine.rawValue) — \(reason)")
        let call = LocalVoiceCall(microphone: LocalMicrophone(queue: Container.shared.localVoiceQueue()),
                                  speech: Container.shared.localSpeech(),
                                  conversationId: activeConversationId?.uuidString)
        if LocalInbox.isAvailable {
            let inbox = LocalInbox(engine: engine, conversationId: activeConversationId?.uuidString)
            inbox.onFocus = { [weak self] focus in
                guard let self, self.isConversing, self.localVoice === call else { return }
                self.feedFocus = focus
            }
            call.inbox = inbox
        }
        localVoice = call
        localVoiceEngine = engine
        turnFailure = nil
        sessionState = .connecting
        call.onState = { [weak self] state in
            guard let self, self.isConversing, self.localVoice === call else { return }
            self.sessionState = state
        }
        call.onUserTranscript = { [weak self] text, _ in
            guard let self else { return }
            self.turnFailure = nil
            if self.commandStartTime == nil { self.commandStartTime = Date() }
            if !text.isEmpty { self.lastCommandText = text }
        }
        call.onAssistantTranscript = { [weak self] text, isFinal in
            guard let self, self.isConversing else { return }
            self.responseText = SpokenAddress.written(text)
            self.answerIsStale = false
            if isFinal { self.finalizeTurn() }
        }
        call.onTurnFailed = { [weak self] message in
            self?.turnFailure = message
            self?.turnSteps = []
        }
        call.onEndRequested = { [weak self] in
            guard let self, self.isConversing else { return }
            Task { await self.endBySpokenCommand() }
        }
        Task { [weak self] in
            do {
                try await call.start(engine: engine)
                guard let self, self.isConversing, self.localVoice === call else {
                    await call.stop()
                    return
                }
                self.micIsLive = true
                self.startLiveActivity("local voice connected")
            } catch {
                guard let self, self.localVoice === call else { return }
                RealtimeLog.log("local-voice: start failed \(error.localizedDescription)")
                self.stopLocalVoice()
                self.isConversing = false
                self.clearFeedFocus()
                self.resumeMemoQueue()
                self.sessionState = .error(error.localizedDescription)
            }
        }
    }

    func stopLocalVoice() {
        guard let call = localVoice else { return }
        localVoice = nil
        localVoiceEngine = nil
        Task { await call.stop() }
    }

    /// The orb, tapped while the local call is speaking: stop and listen.
    func interruptLocalVoice() {
        localVoice?.interrupt()
    }
}
