#if targetEnvironment(macCatalyst)
import Combine
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
    @Published var inSession = false { didSet { if !inSession && oldValue { committedFocus = nil; startingFeedRows = nil; startingFeedRowID = nil } } }
    @Published var sessionIntent: DesktopSessionIntent = .feed
    @Published var muted = false
    @Published var micLive = false
    @Published var focus: FeedFocus? { didSet { commitMatchingFocus() } }
    @Published var committedFocus: FeedFocus?
    @Published var emailReader: DesktopEmailReader.State = .idle
    @Published var showingActivity = false
    @Published var response = ""
    @Published var previousResponse = false
    @Published var responseItemID: String?
    @Published var responseTurnID: String?
    @Published var userWords = ""
    @Published var steps: [TurnStep] = []
    @Published var jobs: [DispatchJob] = []
    @Published var sessionFeed = DesktopSessionFeed() { didSet { commitMatchingFocus() } }
    @Published var feedPreview: DesktopFeedPreview.Snapshot?
    @Published var previewRefreshing = false
    @Published var refreshingFeed = false
    @Published var feedRefreshError: String?
    @Published var previewSelection: DesktopFeedRow?
    @Published var startingFeedRows: [DesktopFeedRow]?
    @Published var startingFeedRowID: String?
    @Published var conversationID: UUID? { didSet { if conversationID != oldValue { changeConversation() } } }
    @Published var profileID: String? { didSet { if profileID != oldValue { jobs = []; selectedJob = nil; feedPreview = nil; clearSelectionSnapshot() } } }
    var isStartingFeed: Bool { startingFeedRows != nil }

    var feedPresentation: DesktopFeedPresentation {
        let preview = inSession ? nil : previewSelection
        return .init(focus: preview?.previewFocus ?? focus,
              committedFocus: committedFocus, feed: preview == nil ? sessionFeed : .init(current: preview?.selection),
              inSession: inSession, intent: sessionIntent, holdingStartup: isStartingFeed)
    }

    var selectionIsTransitioning: Bool { feedPresentation.isTransitioning }
    var displayedFocus: FeedFocus? { feedPresentation.displayedFocus }
    var presentedSelection: MailSelection? { feedPresentation.presentedSelection }

    func readerRequest(ownerID: String?, headersOnly: Bool) -> DesktopEmailReader.Request? {
        let presentation = feedPresentation
        guard let ownerID, case .email(let email) = presentation.displayedFocus,
              let selection = presentation.displayedSelection else { return nil }
        return .init(selection: selection, threadID: email.threadId.flatMap { $0.isEmpty ? nil : $0 },
                     ownerID: ownerID, profileID: profileID, conversationID: conversationID, headersOnly: headersOnly)
    }

    private func commitMatchingFocus() {
        if isStartingFeed {
            let incoming = DesktopFeedPresentation(focus: focus, committedFocus: nil, feed: sessionFeed,
                inSession: true, intent: sessionIntent)
            guard sessionFeed.status == .unavailable || (focus != nil && !incoming.isTransitioning) else { return }
            startingFeedRows = nil
            startingFeedRowID = nil
        }
        if !selectionIsTransitioning, committedFocus != focus { committedFocus = focus }
    }

    private func changeConversation() {
        let retain = conversationID != nil && sessionIntent == .feed
        let rows = feedRows
        let selectedID = currentFeedRowID
        let visible = displayedFocus
        let reader = emailReader
        clearSelectionSnapshot()
        if retain {
            startingFeedRows = rows
            startingFeedRowID = selectedID
            committedFocus = visible
            emailReader = reader
        }
    }

    private func clearSelectionSnapshot() {
        startingFeedRows = nil
        startingFeedRowID = nil
        emailReader = .idle
        committedFocus = nil
        focus = nil
        sessionFeed = .init()
        previewSelection = nil
        passedPreviewRows = []
        feedSelectionError = nil
    }

    func applySessionFeed(_ feed: DesktopSessionFeed) {
        guard feed.revision >= sessionFeed.revision else { return }
        sessionFeed = feed
    }

    var renderedState: RenderedFeedState {
        let presentation = feedPresentation
        var state = RenderedFeedState(profileID: profileID, conversationID: conversationID, focus: presentation.displayedSelection,
            queueCurrent: inSession ? sessionFeed.current : presentation.displayedSelection, queueOrder: feedRows.map { $0.selection?.canonical ?? $0.id },
            queueRevision: sessionFeed.revision, queueScope: sessionFeed.scope,
            response: response, previousResponse: previousResponse, focusMode: focusMode)
        state.responseItemID = responseItemID
        state.feedActionError = feedActionError
        state.rawFocus = presentation.rawSelection
        state.transitioning = presentation.isTransitioning
        state.displayBranch = presentation.displayBranch
        state.responseTurnID = responseTurnID
        state.sidebarSource = isStartingFeed ? "held_preview" : inSession ? "session" : "preview"
        state.sessionPhase = isStartingFeed ? "starting" : inSession ? "active" : "idle"
        state.position = presentation.currentEmail?.displayedPosition
        state.total = presentation.currentEmail?.displayedTotal
        state.jobStates = (runningJobs + finishedJobs).prefix(12).map { $0.id.uuidString + ":" + $0.state }
        if let selectedJob {
            state.focus = nil
            state.rawFocus = nil
            state.displayBranch = "activity"
            state.activityID = selectedJob.id
            state.position = nil
            state.total = nil
        }
        return state
    }
    @Published var showMicDenied = false
    @Published var showMicUnavailable = false
    @Published var showingSettings = false
    @Published var showingCommands = false
    @Published var feedActionError: String?
    @Published var requestedActionContext: FeedActionContext?
    var feedActionContext: FeedActionContext? { FeedActionContext(renderedState) }
    @Published var taskText = ""
    @Published var taskPreference: DispatchJob.CompletionPreference = .bringBack
    @Published var taskCorrection = ""
    @Published var updatingTask = false
    @Published var taskReceipt: String?
    @Published var submittingTask = false
    @Published var passedPreviewRows = Set<String>()

    func taskOrigin(_ context: FeedActionContext) -> DispatchJob.MailOrigin? {
        guard feedActionContext == context, case .email(let email) = displayedFocus else { return nil }
        return .init(account: context.selection.account, messageID: context.selection.messageID,
            threadID: email.threadId ?? "", sender: email.sender, subject: email.subject)
    }
    @Published var showingHistory = false
    @Published var focusMode = false
    @Published var filter = "All"
    @Published var selectedJob: DispatchJob?
    @Published var selectingResult = false
    @Published var selectingFeedItem = false
    @Published var feedSelectionError: String?
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

    var feedRows: [DesktopFeedRow] {
        let parked = Set(jobs.filter(\.ownsFeedSource).compactMap(\.sourceSelection))
        if let startingFeedRows { return startingFeedRows }
        let rows = (inSession ? sessionFeed.rows : (feedPreview?.rows ?? []).filter { !passedPreviewRows.contains($0.id) })
            .filter { row in row.selection.map { !parked.contains($0) } ?? true }
        let selected = inSession ? sessionFeed.selectedRow : previewSelection
        guard let selected else { return rows }
        return [selected] + rows.filter { $0.id != selected.id }
    }
    var filteredQueue: [DesktopFeedRow] {
        filter == "All" ? feedRows : feedRows.filter { $0.source == filter || $0.source == "Overview" }
    }

    func isCurrentRow(_ row: DesktopFeedRow) -> Bool {
        guard selectedJob == nil else { return false }
        if isStartingFeed { return startingFeedRowID == row.id }
        if !inSession, let previewSelection { return previewSelection.id == row.id }
        if let selected = sessionFeed.selectedRow { return selected.id == row.id }
        return feedPresentation.isCurrentRow(row)
    }
    var currentFeedRowID: String? { feedRows.first(where: isCurrentRow)?.id }
    var feedCountLabel: String {
        if isStartingFeed { return "≈\(filteredQueue.count)" }
        return inSession ? String(filteredQueue.count) : feedPreview?.countLabel(filter: filter) ?? "—"
    }
    var returnedTasks: [DispatchJob] { jobs.filter(\.needsReview) }
    var activityJobs: [DispatchJob] { runningJobs + returnedTasks + finishedJobs.filter { !$0.needsReview } }
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

#endif
