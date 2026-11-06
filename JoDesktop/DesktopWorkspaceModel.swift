#if targetEnvironment(macCatalyst)
import Combine
import FactoryKit
import Foundation

enum DesktopSessionIntent {
    case feed
    case quickAction

    var opening: SessionOpening {
        switch self {
        case .feed: return .emailQueue
        case .quickAction: return .none
        }
    }
}

@MainActor
class DesktopWorkspaceModel: ViewModel {
    @Published var state: SessionState = .disconnected
    @Published var inSession = false
    @Published var sessionIntent: DesktopSessionIntent = .feed
    @Published var muted = false
    @Published var micLive = false
    @Published var focus: FeedFocus?
    @Published var response = ""
    @Published var previousResponse = false
    @Published var responseItemID: String?
    @Published var responseTurnID: String?
    @Published var userWords = ""
    @Published var steps: [TurnStep] = []
    @Published var jobs: [DispatchJob] = []
    @Published var sessionFeed = DesktopSessionFeed()
    @Published var feedPreview: DesktopFeedPreview.Snapshot?
    @Published var previewRefreshing = false
    @Published var conversationID: UUID?
    @Published var profileID: String?

    var selectionIsTransitioning: Bool {
        guard case .email(let email) = focus, let id = email.messageId else { return false }
        return sessionFeed.current?.matches(account: email.account, messageID: id) != true
    }

    var presentedSelection: MailSelection? {
        if !selectionIsTransitioning, case .email(let email) = focus, let id = email.messageId {
            return MailSelection(account: email.account, messageID: id)
        }
        return nil
    }

    var renderedState: RenderedFeedState {
        var state = RenderedFeedState(profileID: profileID, conversationID: conversationID, focus: presentedSelection,
            queueCurrent: sessionFeed.current, queueOrder: sessionFeed.rows.map { $0.selection?.canonical ?? $0.id },
            queueRevision: sessionFeed.revision, queueScope: sessionFeed.scope,
            response: response, previousResponse: previousResponse, focusMode: focusMode)
        state.responseItemID = responseItemID
        state.responseTurnID = responseTurnID
        if !selectionIsTransitioning, case .email(let email) = focus {
            state.position = email.displayedPosition; state.total = email.displayedTotal
        }
        state.jobStates = (runningJobs + finishedJobs).prefix(12).map { $0.id.uuidString + ":" + $0.state }
        return state
    }
    @Published var showMicDenied = false
    @Published var showMicUnavailable = false
    @Published var showingSettings = false
    @Published var showingCommands = false
    @Published var feedActionError: String?
    @Published var requestedActionContext: FeedActionContext?
    var feedActionContext: FeedActionContext? { inSession ? FeedActionContext(renderedState) : nil }
    @Published var showingHistory = false
    @Published var focusMode = false
    @Published var filter = "All"
    @Published var selectedJob: DispatchJob?
    @Published var selectingResult = false
    @Published var resultSelectionError: String?
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

    var feedRows: [DesktopFeedRow] { inSession ? sessionFeed.rows : feedPreview?.rows ?? [] }
    var filteredQueue: [DesktopFeedRow] {
        filter == "All" ? feedRows : feedRows.filter { $0.source == filter }
    }
    var feedCountLabel: String {
        inSession ? String(filteredQueue.count) : feedPreview?.countLabel(filter: filter) ?? "—"
    }
    var runningJobs: [DispatchJob] { jobs.filter { $0.isRunning && !$0.hasStopped() } }
    var finishedJobs: [DispatchJob] { jobs.filter { $0.hasStopped() } }
    var feedComplete: Bool {
        inSession && sessionFeed.status == .complete && sessionFeed.rows.isEmpty
            && runningJobs.isEmpty && focus?.isComplete == true
    }
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
    func quickAction()
    func toggleMute()
    func stopSpeaking()
    func exportDiagnostics()
    func exportHistory()
    func showFeedback()
    func saveFeedback()
    func rendered(_ state: RenderedFeedState)
    func selectReturnedResult(_ id: UUID)
    func performFeedAction(_ action: LiveFastAction, context: FeedActionContext)
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
    @Injected(\.desktopFeedPreview) private var feedPreview
    private var feedbackSubmission: UserFeedback.Submission?
    private let hasMicrophone: @Sendable () -> Bool
    private weak var model: DesktopWorkspaceModel?
    private var checkingMicrophone = false
    private var loading = false
    private var refreshPending = false

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
        feedPreview.$snapshot.combineLatest(feedPreview.$refreshing)
            .receive(on: DispatchQueue.main)
            .sink { [weak viewModel] snapshot, refreshing in
                viewModel?.feedPreview = snapshot
                viewModel?.previewRefreshing = refreshing
            }
    }

    override func onViewDisappear(viewModel: DesktopWorkspaceModel) {
        super.onViewDisappear(viewModel: viewModel)
        feedPreview.pause()
    }

    @CancellableBuilder
    override func onViewAppear(viewModel: DesktopWorkspaceModel) -> [AnyCancellable] {
        super.onViewAppear(viewModel: viewModel)
        copySession(to: viewModel)
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
        model.responseItemID = realtime.responseItemID
        model.responseTurnID = realtime.responseTurnID
        model.userWords = realtime.lastCommandText
        model.steps = realtime.turnSteps
        model.voiceNotice = realtime.voiceNotice
        model.conversationID = realtime.activeConversationId
        model.profileID = ProfileRuntime.snapshot?.profileId
        refresh(viewModel: model)
    }

    func selectReturnedResult(_ id: UUID) {
        guard let model, !model.selectingResult else { return }
        model.selectingResult = true
        model.resultSelectionError = nil
        Task { [weak self, weak model] in
            guard let self, let model else { return }
            defer { model.selectingResult = false }
            model.resultSelectionError = await realtime.selectReturnedResult(id)
            if model.resultSelectionError == nil, model.selectedJob?.id == id { model.selectedJob = nil }
            copySession(to: model)
        }
    }

    func rendered(_ state: RenderedFeedState) { realtime.recordRenderedWorkspace(state) }

    func performFeedAction(_ action: LiveFastAction, context: FeedActionContext) {
        guard let model else { return }
        model.feedActionError = realtime.performFeedAction(action, context: context)
        if model.feedActionError == nil { model.requestedActionContext = context }
    }

    func exportDiagnostics() { exportSession(includeContent: false) }
    func exportHistory() { exportSession(includeContent: true) }

    private func exportSession(includeContent: Bool) {
        let owner = backend.userId
        let profileOwner = Container.shared.workspaceProfiles().contextOwner
        Task { [weak self] in
            do {
                let records = try await TurnStore(database: Container.shared.localContext().dbPool).history(owner: profileOwner)
                let jobs = await Container.shared.dispatchJobs().history()
                let logs = try await Container.shared.voiceDiagnostics().snapshot(userID: owner)
                let data = try SessionExport.append(records: records, jobs: jobs, to: logs, includeContent: includeContent)
                guard self?.backend.userId == owner,
                      Container.shared.workspaceProfiles().contextOwner == profileOwner else { return }
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

    private func refresh(viewModel: DesktopWorkspaceModel) {
        let scope = ProfileRuntime.snapshot
        let context = backend.userId.flatMap { owner in
            scope.flatMap { scope in scope.emails.map { emails in
                DesktopFeedPreview.Context(userID: owner, profileID: scope.profileId, emails: emails,
                    slackTeams: connections.status.slackTeamIDs.sorted(), sections: scope.feedSections)
            } }
        }
        feedPreview.update(context: context, inSession: realtime.isConversing)
        guard !loading else { refreshPending = true; return }
        loading = true
        let profile = ProfileRuntime.snapshot?.profileId
        Task { [weak self, weak viewModel] in
            guard let self else { return }
            defer {
                self.loading = false
                if self.refreshPending, let viewModel {
                    self.refreshPending = false
                    self.refresh(viewModel: viewModel)
                }
            }
            let mail = await mailQueue.desktopSnapshot()
            let slack = await slackQueue.desktopPreparedItems()
            let jobs = await dispatchJobs.history()
            guard let viewModel, ProfileRuntime.snapshot?.profileId == profile else { return }
            viewModel.sessionFeed = .init(mail: mail, slack: slack)
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
    func quickAction() { startSession(intent: .quickAction) }

    private func startSession(intent: DesktopSessionIntent = .feed) {
        guard !checkingMicrophone, !realtime.isConversing else { return }
        localSpeech.stop()
        checkingMicrophone = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let available = try await audioQueue.run("desktop input availability", hasMicrophone)
                guard available else {
                    checkingMicrophone = false
                    model?.showMicUnavailable = true
                    return
                }
                voiceCall.withMicPermission(onDenied: { [weak self] in
                    self?.checkingMicrophone = false
                }) { [weak self] in
                    guard let self else { return }
                    checkingMicrophone = false
                    model?.sessionIntent = intent
                    voiceCall.beginVoice(opening: intent.opening)
                }
            } catch {
                checkingMicrophone = false
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
