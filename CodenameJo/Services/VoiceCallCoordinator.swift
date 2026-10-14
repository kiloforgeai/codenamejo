import AVFoundation
import Combine
import FactoryKit
import Foundation
import Speech

/// The only place this app dials, shared by the phone screen and CarPlay. It also owns the pending
/// dial and the finished/failed turn saves, which must work with no view attached.
@MainActor
final class VoiceCallCoordinator {
    @Injected(\.realtimeService) private var realtimeService
    @Injected(\.commandStore) private var commandStore
    @Injected(\.triageQueue) private var triageQueue
    @Injected(\.backend) private var backend
    @Injected(\.turnSaveOutbox) private var turnOutbox
    @Injected(\.profileDossier) private var profileDossier
    private var turnSaves: [UUID: (conversation: UUID, record: CommandRecord, task: Task<CommandRecord?, Never>)] = [:]
    private var endedCalls: Set<UUID> = []
    private var conversationOwners: [UUID: String] = [:]
    private var recentlyEnded: [UUID] = []

    // MARK: - Seams the phone screen fills in

    /// The microphone was refused. The phone raises a sheet; a car shows an alert template (see `CarPlay/`).
    var onMicrophoneDenied: (() -> Void)?

    // MARK: - State

    /// A tap that arrived while the session was down. Dialled when it comes up.
    private var pendingDial = false

    /// The last turn written, by its own id. A `@Published` re-subscription redelivers its
    /// current value, which would otherwise re-file that turn.
    private var lastSavedTurnId: UUID?

    private var cancellables: Set<AnyCancellable> = []


    /// Subscriptions in `init`: on a CarPlay-only launch no view is made, so there is no `onLoad`.
    init() {
        // A turn is filed because it finished (`finalizeTurn`), not because the state machine moved.
        let refresh = turnOutbox
        backend.$userId.sink { [weak self] owner in
            guard owner != nil else {
                self?.conversationOwners.removeAll()
                self?.endedCalls.removeAll()
                self?.recentlyEnded.removeAll()
                self?.turnSaves.removeAll()
                self?.lastSavedTurnId = nil
                return
            }
            Task { await refresh.drain() }
        }.store(in: &cancellables)

        realtimeService.$lastCompletedTurn
            .compactMap { $0 }
            .sink { [weak self] record in
                self?.queueSave(record)
            }
            .store(in: &cancellables)

        // Paired with the previous value: an errored turn's only evidence is the move into `.error`.
        // The main-queue hop is load-bearing: `@Published` emits from `willSet`, so a synchronous
        // dial's `.connecting` would be overwritten by the outer `.ready` assignment.
        realtimeService.$sessionState
            .receive(on: DispatchQueue.main)
            .scan((SessionState.disconnected, SessionState.disconnected)) { pair, next in
                (pair.1, next)
            }
            .sink { [weak self] previous, current in
                self?.sessionStateChanged(from: previous, to: current)
            }
            .store(in: &cancellables)
    }

    // MARK: - Dialling

    /// A tap on the orb, or a car screen coming to life. Dial if we can; otherwise
    /// connect and let `.ready` dial.
    ///
    /// `.connecting` while `connect()` builds the client queues the tap; `.connecting` for a
    /// dial in flight must not, or the flag would redial after the user hangs up.
    func beginVoice() {
        switch realtimeService.sessionState {
        case .ready:
            dial()
        case .disconnected, .error:
            pendingDial = true
            Task { await self.realtimeService.connect() }
        case .connecting:
            if !realtimeService.isConversing {
                RealtimeLog.log("dial: tapped while the session was still coming up — queued")
                pendingDial = true
            }
        case .listening, .processing, .responding:
            break
        }
    }

    /// Start a conversation, then dial into it. The one conversation id is created here and
    /// carried into the call's session scope; a re-dial resumes nothing implicitly.
    ///
    /// The `isConversing` guard matters: `beginConversation` writes a new row on every call,
    /// so a second simultaneous dial would split one call across two ids.
    /// - Parameter announcingConnect: `false` for a dial nobody pressed — onboarding places
    ///   the first call itself, and a cue there invites speech at a screen the user is still
    ///   reading.
    func dial(
        announcingConnect: Bool = true,
        opening requestedOpening: SessionOpening? = nil
    ) {
        guard !realtimeService.isConversing else {
            RealtimeLog.log("dial: already in a call — ignoring")
            return
        }
        // Hands the clock to `DialTiming`; a no-op unless this dial came from an armed launch.
        LaunchTiming.dialling()
        if let openConversation = realtimeService.takePendingResumeConversationId() {
            // Only History's Resume action reaches this branch. A failed dial can leave
            // an active id behind, but that alone must not suppress a fresh opening.
            realtimeService.startConversation(
                in: realtimeService.beginConversation(id: openConversation),
                announcingConnect: announcingConnect,
                opening: .none)
            return
        }
        checkpointQueueForFreshConversation()
        realtimeService.startConversation(
            in: realtimeService.beginConversation(id: UUID()),
            announcingConnect: announcingConnect,
            opening: requestedOpening ?? .freshConversation())
    }

    /// A dial that is not going to happen. Releases the launch clock.
    func abandonDial(_ reason: String) {
        LaunchTiming.abandoned(reason)
    }

    /// A queue belongs to the conversation that built it. Cleared eagerly so the chip does not
    /// describe a conversation that no longer exists.
    private func checkpointQueueForFreshConversation() {
        triageQueue.clear()
        // The device queue is daily: persist its cursor so the next `triage_next` resumes there.
        let local = Container.shared.localTriage()
        let store = Container.shared.mailStore()
        Task { await local.pauseForConversationEnd(store: store) }
    }

    // MARK: - Permissions

    /// Ask for the microphone, then Speech Recognition, then run `next`. Every path that opens
    /// the mic goes through here; a speech denial does not stop the call.
    ///
    /// - Parameter onDenied: extra work for a refusal, on top of `onMicrophoneDenied`. A dial
    ///   and a note share this microphone but need different cleanup.
    func withMicPermission(
        onDenied: @escaping () -> Void = {},
        _ next: @escaping () -> Void
    ) {
        let thenSpeech = { self.withSpeechPermission(next) }
        let denied = { [weak self] in
            self?.onMicrophoneDenied?()
            onDenied()
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            thenSpeech()
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor in
                    if granted {
                        thenSpeech()
                    } else {
                        denied()
                    }
                }
            }
        case .denied:
            denied()
        @unknown default:
            thenSpeech()
        }
    }

    /// Microphone only, for onboarding, which explains each permission on its own screen.
    func requestMicrophoneOnly(
        onDenied: @escaping () -> Void = {},
        _ next: @escaping () -> Void
    ) {
        let denied = { [weak self] in
            self?.onMicrophoneDenied?()
            onDenied()
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            next()
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor in granted ? next() : denied() }
            }
        case .denied:
            denied()
        @unknown default:
            next()
        }
    }

    /// Ask for Speech Recognition if it has never been asked, then continue regardless
    /// of the answer. See `withMicPermission` for why this is not a gate.
    func withSpeechPermission(_ next: @escaping () -> Void) {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else {
            next()
            return
        }
        SFSpeechRecognizer.requestAuthorization { _ in
            Task { @MainActor in next() }
        }
    }

    /// Ask for the microphone if it hasn't been granted, then dial.
    func activateVoice() {
        withMicPermission(onDenied: { self.abandonDial("microphone denied") }) {
            self.beginVoice()
        }
    }

    // MARK: - The state machine's leftovers

    private func sessionStateChanged(from previous: SessionState, to current: SessionState) {
        let wasWorking = previous == .processing || previous == .responding
        // An errored turn never reaches `.ready` and publishes no finished turn, so key off the transition.
        if wasWorking, case .error(let message) = current {
            Task { await self.saveFailedCommand(message) }
        }
        if current == .disconnected {
            pendingDial = false
        }
        // The cold-start dial: the tap arrived while disconnected and `connect()` has since resolved.
        if current == .ready, pendingDial {
            pendingDial = false
            dial()
        }
    }

    // MARK: - History

    /// File a finished turn. The record arrives already built; nothing here reads live session state.
    private func save(_ record: CommandRecord, owner: String) async -> Bool {
        guard lastSavedTurnId != record.id else { return true }
        lastSavedTurnId = record.id

        return await commandStore.save(record, expectedUserId: owner)
    }

    private func queueSave(_ record: CommandRecord) {
        guard let conversation = record.conversationId else {
            guard let owner = backend.userId else { return }
            Task { _ = await commandStore.save(record, expectedUserId: owner) }
            return
        }
        guard let owner = conversationOwners[conversation] else {
            RealtimeLog.log("history: completed turn has no captured conversation owner")
            return
        }
        guard turnSaves[record.id] == nil else { return }
        let task = Task { await self.save(record, owner: owner) ? nil : record }
        turnSaves[record.id] = (conversation, record, task)
        if endedCalls.contains(conversation) { conversationEnded(conversation, owner: owner) }
    }

    func conversationStarted(_ conversation: UUID) {
        endedCalls.remove(conversation)
        recentlyEnded.removeAll { $0 == conversation }
        conversationOwners[conversation] = backend.userId
    }

    func conversationEnded(_ conversation: UUID, owner: String) {
        if endedCalls.insert(conversation).inserted { recentlyEnded.append(conversation) }
        while recentlyEnded.count > 128 {
            let expired = recentlyEnded.removeFirst()
            endedCalls.remove(expired)
            conversationOwners.removeValue(forKey: expired)
        }
        let owner = conversationOwners[conversation] ?? owner
        let refresh = turnOutbox
        let dossier = profileDossier
        Task { [weak self] in
            // Finish teardown first: it can synchronously publish the final interrupted turn.
            await Task.yield()
            guard let self else { return }
            let saves = self.turnSaves.filter { $0.value.conversation == conversation }
            var failed: [CommandRecord] = []
            for (_, value) in saves {
                if let record = await value.task.value { failed.append(record) }
            }
            for (id, _) in saves { self.turnSaves.removeValue(forKey: id) }
            guard self.backend.userId == owner else { return }
            let turns = saves.values.map(\.record)
            Task.detached(priority: .utility) { await dossier.learn(from: turns, owner: owner) }
            await refresh.enqueue(conversation: conversation, owner: owner, failedTurns: failed)
        }
    }

    /// Record a turn that failed, so History shows what was asked and why it didn't work.
    /// Never triggers the review prompt.
    private func saveFailedCommand(_ message: String) async {
        let text = realtimeService.lastCommandText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing was heard, so there is no command to file.
        guard !text.isEmpty else { return }

        let record = CommandRecord(
            commandText: text,
            responseText: message,
            serviceName: realtimeService.lastServiceName,
            serviceIcon: CommandRecord.icon(for: realtimeService.lastServiceName),
            status: .failed,
            durationSeconds: realtimeService.lastDuration,
            conversationId: realtimeService.activeConversationId
        )
        queueSave(record)
    }
}
