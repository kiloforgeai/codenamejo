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
    @Published var showingSettings = false
    @Published var showingHistory = false
    @Published var focusMode = false
    @Published var filter = "All"
    @Published var selectedJob: DispatchJob?
    @Published var startedAt: Date?

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
    private var loading = false

    @CancellableBuilder
    override func onLoad(viewModel: DesktopWorkspaceModel) -> [AnyCancellable] {
        super.onLoad(viewModel: viewModel)
        voiceCall.onMicrophoneDenied = { [weak viewModel] in viewModel?.showMicDenied = true }
        launcher.$pendingLaunch.combineLatest(realtime.$sessionState)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pending, state in
                guard let self, pending, state == .ready else { return }
                self.launcher.consume()
                self.voiceCall.withMicPermission { [voiceCall = self.voiceCall] in voiceCall.beginVoice() }
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
        else { voiceCall.withMicPermission { [voiceCall] in voiceCall.beginVoice() } }
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
