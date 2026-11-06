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
    @Published var inSession = false { didSet { if !inSession && oldValue { retainSessionForIdle() } } }
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
    @Published var browserTasks: [UUID: BackgroundBrowser] = [:]
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
    private(set) var ownerID: String?
    @Published var scopeHydrating = false
    var onFeedTransition: ((String, DesktopSessionFeed) -> Void)?
    var isStartingFeed: Bool { startingFeedRows != nil }

    var feedPresentation: DesktopFeedPresentation {
        let preview = inSession ? nil : previewSelection
        return .init(focus: preview?.previewFocus ?? focus,
              committedFocus: committedFocus, feed: preview == nil ? sessionFeed : .init(current: preview?.selection),
              inSession: inSession, intent: sessionIntent, holdingStartup: isStartingFeed || scopeHydrating)
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
            guard (sessionFeed.status == .unavailable && startingFeedRows?.isEmpty == true)
                || (focus != nil && !incoming.isTransitioning) else { return }
            startingFeedRows = nil
            startingFeedRowID = nil
        }
        let current = !inSession ? previewSelection?.previewFocus ?? focus : focus
        if !selectionIsTransitioning, committedFocus != current { committedFocus = current }
    }

    private func changeConversation() {
        if conversationID == nil { retainSessionForIdle(); return }
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
            onFeedTransition?("session_start_retained", .init(rows: rows, current: DesktopFeedPresentation.selection(for: visible)))
        }
    }

    private func retainSessionForIdle() {
        guard sessionIntent == .feed else { return }
        guard inSession || !sessionFeed.rows.isEmpty || startingFeedRows != nil else { return }
        let rows = startingFeedRows ?? sessionFeed.rows
        let visible = displayedFocus ?? committedFocus ?? focus
        let visibleSelection = DesktopFeedPresentation.selection(for: visible)
        let visibleRow = rows.first { row in
            if let visibleSelection { return row.selection == visibleSelection }
            return visible != nil && row.previewFocus == visible
        }
        let selected = startingFeedRowID ?? visibleRow?.id ?? sessionFeed.selectedRow?.id
            ?? rows.first(where: { $0.selection == sessionFeed.current && sessionFeed.current != nil })?.id
        feedPreview = .visible(rows)
        previewSelection = rows.first { $0.id == selected }
        if visibleRow?.id == selected, visible != nil { previewSelection?.previewFocus = visible }
        committedFocus = previewSelection?.previewFocus
        startingFeedRows = nil
        startingFeedRowID = nil
        onFeedTransition?("session_end_retained", .init(rows: rows, current: previewSelection?.selection))
    }

    func reconcileScope(owner: String?, profile: String?, context: DesktopFeedPreview.Context?) {
        if owner != ownerID {
            ownerID = owner
            jobs = []; selectedJob = nil; feedPreview = nil
            clearSelectionSnapshot()
            profileID = nil
        }
        if let profile { profileID = profile }
        else if owner == nil { profileID = nil }
        if context == nil, owner != nil, !scopeHydrating { committedFocus = displayedFocus }
        scopeHydrating = owner != nil && context == nil
        guard let context else { return }
        let visibleRow = feedRows.first { $0.id == currentFeedRowID }
        feedPreview = feedPreview?.restricted(to: context)
        startingFeedRows = startingFeedRows?.filter(context.allows)
        var feed = sessionFeed
        feed.rows = feed.rows.filter(context.allows)
        if let selected = feed.selectedRow, !context.allows(selected) { feed.selectedRow = nil }
        if let selection = feed.current, !context.emails.contains(where: { $0.caseInsensitiveCompare(selection.account) == .orderedSame }) {
            feed.current = nil
        }
        if let previewSelection, !context.allows(previewSelection) { self.previewSelection = nil }
        let removedVisible = visibleRow.map { !context.allows($0) } ?? false
        let removedEmail: Bool
        if case .email(let email) = displayedFocus {
            removedEmail = !context.emails.contains { $0.caseInsensitiveCompare(email.account) == .orderedSame }
        } else { removedEmail = false }
        if removedVisible || removedEmail {
            focus = nil; committedFocus = nil; emailReader = .idle
            startingFeedRowID = nil
        }
        if feed != sessionFeed { sessionFeed = feed }
    }

    private func clearSelectionSnapshot() {
        onFeedTransition?("intentional_scope_or_conversation_clear", .init())
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
        var next = feed
        if feed.rows.isEmpty && [.idle, .loading, .unavailable].contains(feed.status) {
            next.rows = sessionFeed.rows
            next.current = nil
            next.selectedRow = nil
        }
        guard next != sessionFeed else { return }
        sessionFeed = next
        onFeedTransition?(next.rows == feed.rows ? "session_applied" : "session_retained", next)
    }

    func applyPreview(_ snapshot: DesktopFeedPreview.Snapshot?) {
        let previous = feedPreview
        feedPreview = snapshot
        guard !inSession, !isStartingFeed, let snapshot, let selected = previewSelection else { return }
        if var updated = snapshot.rows.first(where: { $0.id == selected.id }) {
            updated.previewFocus = selected.previewFocus
            previewSelection = updated
            return
        }
        guard previous?.rows.contains(where: { $0.id == selected.id }) == true else { return }
        let part = selected.source == "Email" ? snapshot.mail : selected.source == "Slack" ? snapshot.slack : snapshot.calendar
        guard !part.incomplete, part.count != nil else { return }
        previewSelection = snapshot.rows.first
        focus = nil
        committedFocus = previewSelection?.previewFocus
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
        if selectionIsTransitioning, let visible = feedPresentation.displayedSelection { return row.selection == visible }
        return feedPresentation.isCurrentRow(row)
    }
    var currentFeedRowID: String? { feedRows.first(where: isCurrentRow)?.id }
    var feedCountLabel: String {
        let tasks = workQueueTasks.count
        if isStartingFeed { return filteredQueue.isEmpty && tasks == 0 ? "—" : "≈\(filteredQueue.count + tasks)" }
        if inSession { return String(filteredQueue.count + tasks) }
        let label = feedPreview?.countLabel(filter: filter) ?? "—"
        guard tasks > 0 else { return label }
        guard let count = Int(label.replacingOccurrences(of: "≈", with: "")) else { return "≥\(tasks)" }
        return "≈\(count + tasks)"
    }
    var returnedTasks: [DispatchJob] { jobs.filter(\.needsReview) }
    var workQueueTasks: [DispatchJob] {
        jobs.filter(\.belongsInWorkQueue).sorted {
            if $0.startedAt == $1.startedAt { return $0.id.uuidString < $1.id.uuidString }
            return ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast)
        }
    }
    var activityJobs: [DispatchJob] {
        let auditedParents = Set(jobs.compactMap { $0.mailAction?.parentJobID })
        return (runningJobs + returnedTasks + finishedJobs.filter { !$0.needsReview }).filter { job in
            guard !job.belongsInWorkQueue else { return false }
            guard job.isDone, auditedParents.contains(job.id), let receipts = job.receipts, !receipts.isEmpty else { return true }
            return !receipts.allSatisfy { ["send_email", "create_draft"].contains($0.tool) && $0.outcome == "success" }
        }
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

#endif
