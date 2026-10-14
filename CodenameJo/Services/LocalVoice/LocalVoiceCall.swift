import FactoryKit
import Foundation

/// The call that stands in when the Live session cannot be reached, or on every dial in Fully local mode.
/// Stops listening while it speaks, since playback leaks into the mic; a tap on the orb interrupts instead.
@MainActor
final class LocalVoiceCall {
    enum Phase: Equatable {
        case idle, starting, listening, thinking, speaking, ended
    }

    struct NotReady: LocalizedError {
        var errorDescription: String? {
            "On-device speech recognition isn't ready. Check Speech Recognition for Codename Jo in Settings."
        }
    }

    typealias Brain = (String, [LocalVoiceBrain.Exchange], LocalVoiceBrain.Engine, String?, LocalVoiceBrain.Focus?)
        -> AsyncThrowingStream<String, Error>

    static let tick: Duration = .milliseconds(150)
    static let readyDeadline: Duration = .seconds(8)

    var onState: ((SessionState) -> Void)?
    var onUserTranscript: ((String, Bool) -> Void)?
    var onAssistantTranscript: ((String, Bool) -> Void)?
    var onTurnFailed: ((String) -> Void)?
    var onEndRequested: (() -> Void)?

    private(set) var phase: Phase = .idle
    private(set) var engine: LocalVoiceBrain.Engine?
    private(set) var history: [LocalVoiceBrain.Exchange] = []
    /// The email queue, when the call opens on the inbox. See `LocalInbox`.
    var inbox: LocalInbox?

    private let microphone: LocalMicrophone
    private let transcriber: LocalTranscriber
    private let speech: LocalSpeech
    private let detector: SemanticTurnDetector
    private let profileId: String?
    private let brain: Brain
    /// The words heard this turn, and the fallback end-of-turn rule when Smart Turn could not
    /// be prepared (its Silero model never downloaded): the words stop changing for 900 ms.
    private var policy = LocalTurnPolicy()
    private var smartTurn = false
    private var turnAudio: AsyncStream<[Float]>.Continuation?
    private var turnReader: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var turn: Task<Void, Never>?
    /// What has been voiced of the reply in progress, so an interruption records what was heard.
    private var heardReply = ""
    /// Who asked for the reply in progress; nil for the opening.
    private var turnUser: String?
    /// The reply in progress, replaced by an interrupt or the end of the call.
    private var turnID = UUID()
    /// A queue step is running; see `interrupt`.
    private var inboxBusy = false
    private var muted = false
    /// DEBUG only: typed turns standing in for the transcriber on a simulator, which has no
    /// on-device recognition. Same idea as `ValidationTurnDriver` for the Live client.
    private var script: [String] = {
        #if DEBUG
        return (ProcessInfo.processInfo.environment["LOCAL_VOICE_TURNS"] ?? "")
            .split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        #else
        return []
        #endif
    }()

    init(microphone: LocalMicrophone, speech: LocalSpeech, transcriber: LocalTranscriber = LocalTranscriber(),
         detector: SemanticTurnDetector = Container.shared.localTurnDetector(),
         profileId: String? = ProfileRuntime.snapshot?.profileId,
         brain: @escaping Brain = {
             LocalVoiceBrain.reply(to: $0, history: $1, engine: $2, profileId: $3, focus: $4)
         }) {
        self.microphone = microphone
        self.speech = speech
        self.transcriber = transcriber
        self.detector = detector
        self.profileId = profileId
        self.brain = brain
    }

    func start(engine: LocalVoiceBrain.Engine) async throws {
        guard phase == .idle else { return }
        phase = .starting
        self.engine = engine
        smartTurn = await detector.isReady
        if !smartTurn {
            // Launch's prepare may still be running, or failed offline; one more try costs little.
            smartTurn = (try? await detector.prepare()) != nil
        }
        // Ended while the detector prepared (its first use downloads Silero): open nothing.
        guard phase == .starting else { return }
        RealtimeLog.log("local-voice: end of turn by \(smartTurn ? "Smart Turn" : "the 900 ms silence window")")
        transcriber.onTranscript = { [weak self] text, _ in self?.heard(text) }
        transcriber.start()
        let (audio, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(100))
        turnAudio = continuation
        if smartTurn { readTurnAudio(audio) }
        do {
            try await microphone.start(
                onSamples: { [weak transcriber] samples, rate in transcriber?.ingest(samples, rate: rate) },
                onTurnAudio: { continuation.yield($0) })
            let deadline = ContinuousClock.now + Self.readyDeadline
            while !transcriber.isLive, script.isEmpty {
                guard ContinuousClock.now < deadline, phase == .starting else { throw NotReady() }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            phase = .ended
            await teardown()
            throw error
        }
        guard phase == .starting else {
            // Ended while the mic came up; `stop` ran before there was a mic to close.
            await teardown()
            return
        }
        RealtimeLog.log("local-voice: call open on \(engine.rawValue)")
        guard let inbox else { listen(); return }
        phase = .thinking
        onState?(.processing)
        let started = ContinuousClock.now
        inboxBusy = true
        turn = Task { [weak self] in
            let line = await inbox.open()
            self?.inboxBusy = false
            guard !Task.isCancelled, let self, self.phase == .thinking else { return }
            guard let line else { self.listen(); return }
            await self.speakTurn(user: nil, started: started) { LocalSpeech.stream([line]) }
        }
    }

    func stop() async {
        guard phase != .ended else { return }
        phase = .ended
        await teardown()
    }

    private func teardown() async {
        turnID = UUID()
        ticker?.cancel()
        ticker = nil
        turn?.cancel()
        turn = nil
        turnAudio?.finish()
        turnAudio = nil
        turnReader?.cancel()
        turnReader = nil
        speech.stop()
        transcriber.onTranscript = nil
        transcriber.stop()
        await microphone.stop()
        await microphone.release()
        RealtimeLog.log("local-voice: call closed after \(history.count) turn(s)")
    }

    /// The Mute control: the transcriber hears nothing until it is unmuted.
    func setMuted(_ value: Bool) {
        muted = value
        if phase == .listening { transcriber.setMuted(value) }
        if value { policy.reset() }
    }

    /// A tap while the assistant is thinking or talking: stop and listen.
    func interrupt() {
        guard phase == .speaking || phase == .thinking else { return }
        // A queue step in flight moves the card whatever happens to the turn, so the tap
        // waits for it rather than leave the screen on an email Jo never read out.
        guard !inboxBusy else { return }
        RealtimeLog.log("local-voice: interrupted by tap")
        turnID = UUID()
        speech.stop()
        turn?.cancel()
        turn = nil
        if let user = turnUser, !heardReply.isEmpty {
            history.append(LocalVoiceBrain.Exchange(
                user: user, assistant: heardReply + " [The user interrupted the response.]"))
            onAssistantTranscript?(heardReply, true)
        }
        listen()
    }

    // MARK: - The loop

    private func listen() {
        guard phase != .ended else { return }
        phase = .listening
        policy.reset()
        heardReply = ""
        // Jo's own voice reached the microphone, and the recogniser may still deliver it.
        transcriber.discardThroughNow()
        transcriber.setMuted(muted)
        onState?(.listening)
        if smartTurn {
            let detector = detector
            Task { await detector.reset() }
        }
        if !script.isEmpty {
            let line = script.removeFirst()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.phase == .listening else { return }
                RealtimeLog.log("local-voice: scripted turn \"\(line)\"")
                self.heard(line)
                self.endTurn(settled: line)
            }
            return
        }
        guard !smartTurn else { return }
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tick)
                guard let self, !Task.isCancelled, self.phase == .listening else { return }
                if self.policy.isComplete(at: .now) { self.endTurn(settled: self.policy.text) }
            }
        }
    }

    /// Smart Turn's reader: 16 kHz audio in, end of turn out. Audio outside listening is
    /// dropped, so the call's own voice never reaches the detector.
    private func readTurnAudio(_ audio: AsyncStream<[Float]>) {
        let detector = detector
        turnReader = Task { [weak self] in
            for await samples in audio {
                guard let self, !Task.isCancelled else { return }
                guard self.phase == .listening, !self.muted else { continue }
                do {
                    guard try await detector.consume(samples), self.phase == .listening else { continue }
                } catch is CancellationError {
                    return
                } catch {
                    RealtimeLog.log("local-voice: turn detector failed — \(error.localizedDescription); "
                        + "falling back to the silence window")
                    self.smartTurn = false
                    self.listen()
                    return
                }
                guard !self.policy.text.isEmpty else {
                    // A cough or a door: sound without words is not a turn.
                    await detector.reset()
                    continue
                }
                self.phase = .thinking
                let settled = await self.transcriber.settle()
                guard self.phase == .thinking else { continue }
                self.endTurn(settled: settled.isEmpty ? self.policy.text : settled)
            }
        }
    }

    private func heard(_ text: String) {
        guard phase == .listening else { return }
        policy.observe(text, at: .now)
        if !policy.text.isEmpty { onUserTranscript?(policy.text, false) }
    }

    private func endTurn(settled user: String) {
        ticker?.cancel()
        ticker = nil
        policy.reset()
        transcriber.setMuted(true)
        guard !user.isEmpty else { listen(); return }
        onUserTranscript?(user, true)
        if SpokenCommand.match(user) == .endCall {
            RealtimeLog.log("local-voice: spoken end")
            onEndRequested?()
            return
        }
        guard let engine else { return }
        phase = .thinking
        onState?(.processing)
        let started = ContinuousClock.now
        turn = Task { [weak self] in
            guard let self else { return }
            let inbox = self.inbox
            self.inboxBusy = inbox?.current != nil
            let command = inbox?.current != nil ? await inbox?.command(user) : nil
            self.inboxBusy = false
            guard !Task.isCancelled, self.phase == .thinking else { return }
            await self.speakTurn(user: user, started: started) {
                if let command { return LocalSpeech.stream([command]) }
                if let inbox, inbox.current != nil, engine == .onDevice { return inbox.answer(user) }
                let focus = inbox?.openAIContext
                return self.brain(user, self.history, engine, self.profileId,
                                  focus.map { LocalVoiceBrain.Focus(cursor: $0.cursor, standingOn: $0.standingOn, note: $0.note) })
            }
        }
    }

    /// One reply, spoken as it is written, then back to listening. `user` is nil for the
    /// call's own opening, which no one asked for and which is not part of the history.
    private func speakTurn(user: String?, started: ContinuousClock.Instant,
                           deltas: () -> AsyncThrowingStream<String, Error>) async {
        turnUser = user
        let id = UUID()
        turnID = id
        do {
            let reply = try await speakReply(deltas(), started: started)
            guard !Task.isCancelled, phase == .speaking || phase == .thinking else { return }
            guard !reply.isEmpty else { throw LocalVoiceBrain.EmptyReply() }
            if let user { history.append(LocalVoiceBrain.Exchange(user: user, assistant: reply)) }
            onAssistantTranscript?(reply, true)
            listen()
        } catch is CancellationError {
            // Not from an interrupt or the end of the call, which replace `turnID`: a stale
            // playback teardown or the like. The turn is over either way, so listen.
            if id == turnID, phase == .thinking || phase == .speaking { listen() }
        } catch {
            guard phase == .thinking || phase == .speaking else { return }
            RealtimeLog.log("local-voice: turn failed — \(error.localizedDescription)")
            onTurnFailed?(error.localizedDescription)
            phase = .speaking
            onState?(.responding)
            try? await speech.speak("Sorry, that didn't go through. Try again.")
            guard phase == .speaking else { return }
            listen()
        }
    }

    /// The reply, phrase by phrase into the voice as it is written. Returns what was spoken.
    private func speakReply(_ deltas: AsyncThrowingStream<String, Error>,
                            started: ContinuousClock.Instant) async throws -> String {
        let (phrases, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let producer = Task {
            var buffer = SpokenPhraseBuffer()
            do {
                for try await delta in deltas {
                    try Task.checkCancellation()
                    buffer.append(delta).forEach { continuation.yield($0) }
                }
                let tail = buffer.finish()
                if !tail.isEmpty { continuation.yield(tail) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        defer { producer.cancel() }
        heardReply = ""
        try await speech.speak(phrases) { [weak self] phrase in
            guard let self, self.phase == .thinking || self.phase == .speaking else { return }
            if self.phase == .thinking {
                RealtimeLog.log("local-voice: first audio \(ContinuousClock.now - started) after the turn ended")
                self.phase = .speaking
                self.onState?(.responding)
            }
            self.heardReply = (self.heardReply + " " + phrase).trimmingCharacters(in: .whitespaces)
            self.onAssistantTranscript?(self.heardReply, false)
        }
        try Task.checkCancellation()
        return heardReply
    }
}
