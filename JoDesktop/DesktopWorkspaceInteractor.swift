#if targetEnvironment(macCatalyst)
import Combine
import FactoryKit
import Foundation

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
    func selectFeedItem(_ row: DesktopFeedRow)
    func performFeedAction(_ action: LiveFastAction, context: FeedActionContext)
    func submitTask(_ text: String, commandID: String?, context: FeedActionContext)
    func retryEmailReader()
    func refreshFeed()
}

@MainActor
extension DesktopWorkspaceHandler {
    func controlBrowser(_ action: String, job: DispatchJob, model: DesktopWorkspaceModel) {
        guard !model.updatingTask, let browser = model.browserTasks[job.id], browser.current() else { return }
        if action == "pause" { browser.pause(); return }
        if action == "takeover" { browser.takeOver(); return }
        model.updatingTask = true
        model.resultSelectionError = nil
        Task {
            defer { model.updatingTask = false }
            do {
                try await Container.shared.applicationTasks().resumeBrowser(job.id, version: job.taskRevision,
                    approval: action == "approve" ? browser.approval?.id : nil)
            } catch { model.resultSelectionError = error.localizedDescription }
            model.jobs = await Container.shared.dispatchJobs().history()
            if model.selectedJob?.id == job.id { model.selectedJob = model.jobs.first { $0.id == job.id } }
        }
    }
    func reviewTask(_ job: DispatchJob, model: DesktopWorkspaceModel) {
        Task {
            do { try await Container.shared.applicationTasks().reviewed(job.id, version: job.taskRevision) }
            catch { model.resultSelectionError = error.localizedDescription }
            model.jobs = await Container.shared.dispatchJobs().history()
            if model.selectedJob?.id == job.id { model.selectedJob = model.jobs.first { $0.id == job.id } }
        }
    }
    func selectTask(_ id: UUID?) { Container.shared.applicationTasks().select(id) }
    func resumeTaskArchive(_ job: DispatchJob, model: DesktopWorkspaceModel) {
        guard !model.updatingTask else { return }
        model.updatingTask = true
        model.resultSelectionError = nil
        Task {
            defer { model.updatingTask = false }
            do { try await Container.shared.applicationTasks().resumeFeedbackArchive(job.id, version: job.taskRevision) }
            catch { model.resultSelectionError = error.localizedDescription }
            model.jobs = await Container.shared.dispatchJobs().history()
            if model.selectedJob?.id == job.id { model.selectedJob = model.jobs.first { $0.id == job.id } }
        }
    }
    func chooseTaskInput(_ job: DispatchJob, choice: String, model: DesktopWorkspaceModel) {
        guard !model.updatingTask else { return }
        model.updatingTask = true
        model.resultSelectionError = nil
        Task {
            defer { model.updatingTask = false }
            do { try await Container.shared.applicationTasks().choose(job.id, version: job.taskRevision, choice: choice) }
            catch { model.resultSelectionError = error.localizedDescription }
            model.jobs = await Container.shared.dispatchJobs().history()
            if model.selectedJob?.id == job.id { model.selectedJob = model.jobs.first { $0.id == job.id } }
        }
    }
    func updateTask(_ job: DispatchJob, instruction: String?, model: DesktopWorkspaceModel) {
        guard !model.updatingTask else { return }
        model.updatingTask = true
        model.resultSelectionError = nil
        Task {
            defer { model.updatingTask = false }
            do {
                let tasks = Container.shared.applicationTasks()
                if let instruction { try await tasks.correct(job.id, version: job.taskRevision, instruction: instruction) }
                else { try await tasks.cancel(job.id, version: job.taskRevision) }
                model.taskCorrection = ""
            } catch { model.resultSelectionError = error.localizedDescription }
            model.jobs = await Container.shared.dispatchJobs().history()
            if model.selectedJob?.id == job.id { model.selectedJob = model.jobs.first { $0.id == job.id } }
        }
    }
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
    @Injected(\.desktopEmailReader) private var emailReader
    @Injected(\.applicationTasks) private var tasks
    @Injected(\.backgroundBrowsers) private var browsers
    private var feedbackSubmission: UserFeedback.Submission?
    private let hasMicrophone: @Sendable () -> Bool
    private weak var model: DesktopWorkspaceModel?
    private var checkingMicrophone = false
    private var loading = false
    private var refreshPending = false
    private var refreshGeneration = 0
    private var pendingActions = Set<MailSelection>()

    init(hasMicrophone: @escaping @Sendable () -> Bool = { OnboardingAudioSession.hasInputDevice }) {
        self.hasMicrophone = hasMicrophone
        super.init()
    }

    @CancellableBuilder
    override func onLoad(viewModel: DesktopWorkspaceModel) -> [AnyCancellable] {
        super.onLoad(viewModel: viewModel)
        model = viewModel
        viewModel.onFeedTransition = { [weak self] phase, feed in self?.feedPreview.recordSession(phase, feed: feed) }
        viewModel.reconcileScope(owner: backend.userId, profile: ProfileRuntime.snapshot?.profileId, context: previewContext)
        feedPreview.update(context: previewContext, inSession: realtime.isConversing,
                           hydratingOwner: backend.userId, hydratingProfile: ProfileRuntime.snapshot?.profileId)
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
                self?.refreshGeneration += 1
                self?.refresh(viewModel: viewModel)
            }
        feedPreview.$snapshot.combineLatest(feedPreview.$refreshing)
            .sink { [weak self, weak viewModel] snapshot, refreshing in
                guard let viewModel else { return }
                viewModel.applyPreview(snapshot)
                viewModel.previewRefreshing = refreshing
                if !viewModel.inSession { self?.updateReader(viewModel) }
            }
        feedback.$voiceReceipt.sink { [weak viewModel] in viewModel?.feedbackReceipt = $0 }
        browsers.$sessions.sink { [weak viewModel] in viewModel?.browserTasks = $0 }
        tasks.$revision.dropFirst().sink { [weak self, weak viewModel] _ in
            guard let viewModel else { return }
            self?.refresh(viewModel: viewModel)
        }
        emailReader.$state.receive(on: DispatchQueue.main).sink { [weak self, weak viewModel] state in
            guard let self, let viewModel else { return }
            guard !viewModel.scopeHydrating else { return }
            let request = viewModel.readerRequest(ownerID: self.backend.userId, headersOnly: MailHeadersOnly.withholdsBodies)
            viewModel.emailReader = state.request == request ? state : .idle
        }
        backend.$userId.dropFirst().sink { [weak self, weak viewModel] owner in
            guard owner != viewModel?.ownerID else { return }
            self?.browsers.purge()
            viewModel?.reconcileScope(owner: owner, profile: nil, context: nil)
            self?.feedPreview.update(context: nil, inSession: false)
            self?.tasks.select(nil)
            viewModel?.emailReader = .idle
            self?.emailReader.show(nil)
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
        let context = previewContext
        model.reconcileScope(owner: backend.userId, profile: ProfileRuntime.snapshot?.profileId, context: context)
        guard backend.userId != nil else { updateReader(model); return }
        if model.inSession && !realtime.isConversing, let context {
            feedPreview.seed(.visible(model.feedRows), context: context)
        }
        model.conversationID = realtime.activeConversationId
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
        updateReader(model)
        refresh(viewModel: model)
    }

    private func updateReader(_ model: DesktopWorkspaceModel, retry: Bool = false) {
        guard !model.scopeHydrating else { return }
        emailReader.show(model.readerRequest(ownerID: backend.userId, headersOnly: MailHeadersOnly.withholdsBodies), retry: retry)
    }

    func retryEmailReader() {
        guard let model else { return }
        updateReader(model, retry: true)
    }

    func selectReturnedResult(_ id: UUID) {
        guard let model, !model.selectingResult else { return }
        if !model.inSession {
            guard let job = dispatchJobs.selectableResult(id, allowedAccounts: GoogleAccountStore.mailAccounts()), let origin = job.origin else {
                model.resultSelectionError = "This source is not accessible in the current profile."
                return
            }
            model.previewSelection = .email(account: origin.account, messageID: origin.messageID, subject: origin.subject, sender: origin.sender)
            model.selectedJob = nil
            updateReader(model)
            return
        }
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

    func selectFeedItem(_ row: DesktopFeedRow) {
        guard let model, !model.isStartingFeed, !model.scopeHydrating, !model.selectingFeedItem, !model.selectingResult,
              model.feedRows.contains(where: { $0.id == row.id }) else { return }
        model.selectedJob = nil
        tasks.select(nil)
        guard !model.isCurrentRow(row) else { return }
        if !model.inSession {
            model.previewSelection = row
            model.feedSelectionError = nil
            updateReader(model)
            return
        }
        model.selectingFeedItem = true
        refreshGeneration += 1
        model.feedSelectionError = nil
        Task { [weak self, weak model] in
            guard let self, let model else { return }
            defer { model.selectingFeedItem = false }
            model.feedSelectionError = await realtime.selectFeedItem(row)
            copySession(to: model)
        }
    }

    func performFeedAction(_ action: LiveFastAction, context: FeedActionContext) {
        guard let model, let origin = model.taskOrigin(context) else { return }
        if let reason = tasks.refusal(owner: backend.userId, profile: context.profileID, origin: origin) {
            model.feedActionError = reason
            return
        }
        guard pendingActions.insert(context.selection).inserted else { return }
        if model.inSession { realtime.beginDesktopInteraction() }
        model.feedActionError = nil
        model.requestedActionContext = context
        let owner = backend.userId
        Task { [self, weak model] in
            defer { pendingActions.remove(context.selection) }
            guard let model else { return }
            if action != .next {
                let result = await tasks.perform(name: action.rawValue,
                    arguments: GmailReadTools.json(["account": origin.account, "message_id": origin.messageID]),
                    profile: context.profileID, origin: origin, conversationID: context.conversationID, inputSource: "button")
                guard owner == backend.userId, context.profileID == ProfileRuntime.snapshot?.profileId else { return }
                if let effects = result.effects {
                    _ = await mailQueue.applyConfirmedEffects(effects, store: Container.shared.mailStore())
                }
                guard result.ok == true, result.pendingArchive == nil, result.pendingDraft == nil, !result.deferred else {
                    model.feedActionError = result.text
                    refresh(viewModel: model)
                    return
                }
                feedPreview.remove(context.selection)
            }
            refreshGeneration += 1
            guard model.profileID == context.profileID, model.conversationID == context.conversationID,
                  model.renderedState.rawFocus == context.selection,
                  model.renderedState.focus == context.selection else { refresh(viewModel: model); return }
            if model.inSession {
                model.feedActionError = await realtime.advanceDesktopFeed(context)
                copySession(to: model)
            } else {
                let remaining = model.feedRows.filter { $0.selection != context.selection }
                if let row = model.previewSelection { model.passedPreviewRows.insert(row.id) }
                model.previewSelection = remaining.first
                model.focus = nil
                updateReader(model)
            }
            model.requestedActionContext = nil
            refresh(viewModel: model)
        }
    }

    func submitTask(_ text: String, commandID: String?, context: FeedActionContext) {
        guard let model, !model.submittingTask, let origin = model.taskOrigin(context),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let job = try tasks.job(request: text, commandID: commandID, origin: origin, profile: context.profileID)
            model.submittingTask = true
            model.showingActivity = true
            model.feedActionError = nil
            Task { [weak self, weak model] in
                guard let self else { return }
                let id = await tasks.submit(job)
                guard let model else { return }
                model.submittingTask = false
                guard dispatchJobs.existing(id)?.context != nil else {
                    model.feedActionError = (await tasks.result(id)).text
                    return
                }
                if model.inSession { await realtime.parkAcceptedTask(id); copySession(to: model) }
                else {
                    model.jobs = await dispatchJobs.history()
                    feedPreview.remove(context.selection)
                    model.previewSelection = nil
                    model.previewSelection = model.feedRows.first
                }
                model.taskText = ""
                model.taskReceipt = dispatchJobs.existing(id)?.effectivePreference == .quiet
                    ? "Task accepted · source saved in Activities · successful work will finish quietly"
                    : "Task accepted · source saved in Activities · the result will return to the feed"
                refresh(viewModel: model)
            }
        } catch { model.feedActionError = error.localizedDescription }
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
        if model.feedbackText.isEmpty { model.feedbackText = feedback.takeVoiceDraft() ?? "" }
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

    func refreshFeed() {
        guard let model, !model.refreshingFeed, !model.previewRefreshing, !model.isStartingFeed else { return }
        model.feedRefreshError = nil
        if !model.inSession { refresh(viewModel: model, force: true); return }
        let owner = backend.userId, profile = model.profileID, conversation = model.conversationID
        refreshGeneration += 1
        model.refreshingFeed = true
        Task { [weak self, weak model] in
            guard let self, let model else { return }
            defer { model.refreshingFeed = false }
            let error = await mailQueue.refreshDesktopFeed(store: Container.shared.mailStore())
            guard owner == backend.userId, profile == model.profileID, conversation == model.conversationID else { return }
            model.feedRefreshError = error
            refresh(viewModel: model)
        }
    }

    private var previewContext: DesktopFeedPreview.Context? {
        let scope = ProfileRuntime.snapshot
        return backend.userId.flatMap { owner in
            scope.flatMap { scope in scope.emails.map { emails in
                DesktopFeedPreview.Context(userID: owner, profileID: scope.profileId, emails: emails,
                    slackTeams: connections.status.slackTeamIDs.sorted(), sections: scope.feedSections)
            } }
        }
    }

    private func refresh(viewModel: DesktopWorkspaceModel, force: Bool = false) {
        let context = previewContext
        viewModel.reconcileScope(owner: backend.userId, profile: ProfileRuntime.snapshot?.profileId, context: context)
        feedPreview.update(context: context, inSession: realtime.isConversing, force: force,
                           hydratingOwner: backend.userId, hydratingProfile: ProfileRuntime.snapshot?.profileId)
        guard context != nil else { return }
        guard !loading else { refreshPending = true; return }
        loading = true
        let profile = ProfileRuntime.snapshot?.profileId
        let conversation = realtime.activeConversationId
        let owner = backend.userId
        let generation = refreshGeneration
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
            guard let viewModel, ProfileRuntime.snapshot?.profileId == profile,
                  realtime.activeConversationId == conversation, backend.userId == owner,
                  generation == refreshGeneration else { return }
            viewModel.applySessionFeed(.init(mail: mail, slack: slack))
            if let error = mail.selectionError { viewModel.feedSelectionError = error }
            updateReader(viewModel)
            viewModel.jobs = jobs
            if let selected = viewModel.selectedJob {
                viewModel.selectedJob = jobs.first { $0.id == selected.id }
            }
        }
    }

    func toggleSession() {
        if realtime.isConversing { realtime.endConversation() }
        else { startSession(intent: model?.selectedJob == nil ? .feed : .quickAction) }
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
                    let row = intent == .feed ? model?.previewSelection : nil
                    let profile = ProfileRuntime.snapshot?.profileId
                    Task { [weak self] in
                        guard let self else { return }
                        await mailQueue.preferDesktopOpening(row, profileID: profile)
                        guard ProfileRuntime.snapshot?.profileId == profile else { return }
                        voiceCall.beginVoice(opening: intent.opening)
                    }
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
