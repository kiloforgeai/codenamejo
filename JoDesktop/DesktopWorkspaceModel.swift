#if targetEnvironment(macCatalyst)
import Combine
import FactoryKit
import Foundation

struct DesktopFeedRow: Identifiable, Equatable {
    let id: String
    let source: String
    let title: String
    let detail: String
    let reason: String?
    var symbol: String { source == "Slack" ? "number" : "envelope" }
}

@MainActor
class DesktopWorkspaceModel: ViewModel {
    @Published var state: SessionState = .disconnected
    @Published var inSession = false
    @Published var muted = false
    @Published var micLive = false
    @Published var focus: FeedFocus?
    @Published var response = ""
    @Published var previousResponse = false
    @Published var userWords = ""
    @Published var steps: [TurnStep] = []
    @Published var jobs: [DispatchJob] = []
    @Published var queue: [DesktopFeedRow] = []
    @Published var showMicDenied = false
    @Published var showMicUnavailable = false
    @Published var showingSettings = false
    @Published var showingHistory = false
    @Published var focusMode = false
    @Published var filter = "All"
    @Published var selectedJob: DispatchJob?
    @Published var startedAt: Date?
    @Published var voiceNotice: String?
    @Published var diagnosticsDocument = VoiceDiagnosticsDocument()
    @Published var exportingDiagnostics = false
    @Published var diagnosticsError: String?
    @Published var showingFeedback = false
    @Published var feedbackText = ""
    @Published var savingFeedback = false
    @Published var feedbackError: String?
    @Published var feedbackReceipt: String?

    var canSaveFeedback: Bool { !savingFeedback && (try? FeedbackText.validated(feedbackText)) != nil }

    var filteredQueue: [DesktopFeedRow] {
        filter == "All" ? queue : queue.filter { $0.source == filter }
    }
    var runningJobs: [DispatchJob] { jobs.filter { $0.isRunning && !$0.hasStopped() } }
    var finishedJobs: [DispatchJob] { jobs.filter { $0.hasStopped() } }
    var status: String {
        if case .error = state { return "Connection needs attention" }
        if !inSession { return "Ready when you are" }
        if muted { return "Microphone muted" }
        if !micLive { return "Connecting" }
        switch state {
        case .responding: return "Jo is speaking"
        case .processing: return "Jo is working"
        default: return "Jo is listening"
        }
    }
}

protocol DesktopWorkspaceHandler {
    func toggleSession()
    func toggleMute()
    func stopSpeaking()
    func refresh(viewModel: DesktopWorkspaceModel)
    func exportDiagnostics()
    func showFeedback()
    func saveFeedback()
}

@MainActor
class DesktopWorkspaceInteractor: ViewModelInteractor<DesktopWorkspaceModel>, DesktopWorkspaceHandler {
    @Injected(\.realtimeService) private var realtime
    @Injected(\.voiceCall) private var voiceCall
    @Injected(\.localTriage) private var mailQueue
    @Injected(\.localSlack) private var slackQueue
    @Injected(\.dispatchJobs) private var dispatchJobs
    @Injected(\.connections) private var connections
    @Injected(\.voiceLauncher) private var launcher
    @Injected(\.historyRouter) private var historyRouter
    @Injected(\.commandStore) private var history
    @Injected(\.onboardingAudioQueue) private var audioQueue
    @Injected(\.localSpeech) private var localSpeech
    @Injected(\.userFeedback) private var feedback
    @Injected(\.backend) private var backend
    private var feedbackSubmission: UserFeedback.Submission?
    private let hasMicrophone: @Sendable () -> Bool
    private weak var model: DesktopWorkspaceModel?
    private var checkingMicrophone = false
    private var loading = false

    init(hasMicrophone: @escaping @Sendable () -> Bool = { OnboardingAudioSession.hasInputDevice }) {
        self.hasMicrophone = hasMicrophone
        super.init()
    }

    @CancellableBuilder
    override func onLoad(viewModel: DesktopWorkspaceModel) -> [AnyCancellable] {
        super.onLoad(viewModel: viewModel)
        model = viewModel
        voiceCall.onMicrophoneDenied = { [weak viewModel] in viewModel?.showMicDenied = true }
        launcher.$pendingLaunch.combineLatest(realtime.$sessionState)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pending, state in
                guard let self, pending, state == .ready else { return }
                self.launcher.consume()
                self.startSession()
            }
        historyRouter.$pendingPane
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak viewModel] pending in
                guard pending else { return }
                viewModel?.showingHistory = true
                self?.historyRouter.consumePane()
            }
        realtime.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak viewModel] in
                guard let self, let viewModel else { return }
                self.copySession(to: viewModel)
            }
        realtime.$queueCursorMovedAt
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak viewModel] _ in
                guard let viewModel else { return }
                self?.refresh(viewModel: viewModel)
            }
    }

    @CancellableBuilder
    override func onViewAppear(viewModel: DesktopWorkspaceModel) -> [AnyCancellable] {
        super.onViewAppear(viewModel: viewModel)
        copySession(to: viewModel)
        refresh(viewModel: viewModel)
        Task { await realtime.connect() }
        Task { await connections.refresh(); await history.refresh() }
        Timer.publish(every: 3, on: .main, in: .common).autoconnect()
            .sink { [weak self, weak viewModel] _ in
                guard let viewModel else { return }
                self?.refresh(viewModel: viewModel)
            }
    }

    private func copySession(to model: DesktopWorkspaceModel) {
        if realtime.isConversing && !model.inSession { model.startedAt = Date() }
        if !realtime.isConversing { model.startedAt = nil }
        model.inSession = realtime.isConversing
        model.state = realtime.sessionState
        model.muted = realtime.isMuted
        model.micLive = realtime.micIsLive && !realtime.micHeldForOpening
        model.focus = realtime.feedFocus
        model.response = realtime.responseText
        model.previousResponse = realtime.answerIsStale
        model.userWords = realtime.lastCommandText
        model.steps = realtime.turnSteps
        model.voiceNotice = realtime.voiceNotice
    }

    func exportDiagnostics() {
        let owner = backend.userId
        Task { [weak self] in
            do {
                let data = try await Container.shared.voiceDiagnostics().snapshot(userID: owner)
                guard self?.backend.userId == owner else { return }
                self?.model?.diagnosticsDocument = VoiceDiagnosticsDocument(data: data)
                self?.model?.exportingDiagnostics = true
            } catch { self?.model?.diagnosticsError = error.localizedDescription }
        }
    }

    func showFeedback() {
        guard let model, !model.savingFeedback else { return }
        feedbackSubmission = feedback.capture()
        model.feedbackError = nil
        model.feedbackReceipt = nil
        model.showingFeedback = true
    }

    func saveFeedback() {
        guard let model, model.canSaveFeedback, let submission = feedbackSubmission else { return }
        let message = model.feedbackText
        model.savingFeedback = true
        model.feedbackError = nil
        Task { [weak self, weak model] in
            guard let self, let model else { return }
            defer { model.savingFeedback = false }
            do {
                _ = try await feedback.save(message, source: .button, submission: submission)
                model.feedbackText = ""
                model.showingFeedback = false
                model.feedbackReceipt = "Feedback saved"
            } catch { model.feedbackError = error.localizedDescription }
        }
    }

    func refresh(viewModel: DesktopWorkspaceModel) {
        guard !loading else { return }
        loading = true
        let profile = ProfileRuntime.snapshot?.profileId
        Task { [weak self, weak viewModel] in
            guard let self else { return }
            defer { self.loading = false }
            let mail = await mailQueue.desktopPreparedItems()
            let slack = await slackQueue.desktopPreparedItems()
            let jobs = await dispatchJobs.history()
            guard let viewModel, ProfileRuntime.snapshot?.profileId == profile else { return }
            viewModel.queue = mail.map {
                DesktopFeedRow(id: "mail:\($0.account):\($0.id)", source: "Email",
                    title: $0.subject.isEmpty ? "No subject" : $0.subject,
                    detail: $0.from, reason: $0.importanceWhy)
            } + slack.map {
                DesktopFeedRow(id: "slack:\($0.teamId):\($0.channelId)", source: "Slack",
                    title: $0.label, detail: $0.teamName, reason: $0.why.isEmpty ? nil : $0.why)
            }
            viewModel.jobs = jobs
            if let selected = viewModel.selectedJob {
                viewModel.selectedJob = jobs.first { $0.id == selected.id }
            }
        }
    }

    func toggleSession() {
        if realtime.isConversing { realtime.endConversation() }
        else { startSession() }
    }
    private func startSession() {
        guard !checkingMicrophone else { return }
        localSpeech.stop()
        checkingMicrophone = true
        Task { [weak self] in
            guard let self else { return }
            defer { checkingMicrophone = false }
            do {
                let available = try await audioQueue.run("desktop input availability", hasMicrophone)
                guard available else {
                    model?.showMicUnavailable = true
                    return
                }
                voiceCall.withMicPermission { [voiceCall] in voiceCall.beginVoice() }
            } catch {
                RealtimeLog.log("desktop: input availability failed: \(error.localizedDescription)")
                model?.showMicUnavailable = true
            }
        }
    }

    func toggleMute() {
        guard realtime.isConversing else { return }
        realtime.setConversationMuted(!realtime.isMuted)
    }
    func stopSpeaking() {
        guard realtime.isConversing else { return }
        realtime.interrupt()
    }
}
#endif
