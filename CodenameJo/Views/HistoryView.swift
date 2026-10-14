import Combine
import FactoryKit
import SwiftUI

/// What the History screen can ask for, so the view compiles against actions rather than
/// one concrete interactor.
protocol HistoryViewHandler {
    func select(service: String, viewModel: HistoryViewModel)
    func setGrouping(_ grouping: HistoryViewModel.Grouping, viewModel: HistoryViewModel)
    /// One toggle for anything expandable: a turn's answer or a dispatch job's result.
    func toggleExpanded(_ id: UUID, viewModel: HistoryViewModel)
    /// The list has scrolled to the row a notification tap asked for. Clears the
    /// router's copy, which outlives the view model's so it can survive a cold start.
    func consumeScrollTarget()
    func toggleTurns(of conversation: Conversation, viewModel: HistoryViewModel)
    func requestDelete(_ command: CommandRecord, viewModel: HistoryViewModel)
    func confirmDelete(viewModel: HistoryViewModel)
    func requestDeleteConversation(_ conversation: Conversation, viewModel: HistoryViewModel)
    func confirmDeleteConversation(viewModel: HistoryViewModel)
    func resume(_ conversation: Conversation, viewModel: HistoryViewModel)
    func copy(_ text: String)
}

struct HistoryView<Interactor: ViewWithModelLifecycleObserver<HistoryViewModel> & HistoryViewHandler>: View {
    @StateObject var viewModel: HistoryViewModel
    @StateObject var interactor: Interactor

    /// Notes waiting to be read back and sent. Observed directly, unlike the other lists:
    /// these rows are edited, sent and deleted on this screen, so the queue is the source of truth.
    @ObservedObject private var workspaceProfiles = Container.shared.workspaceProfiles()
    private var profileMemos: [QueuedMemo] {
        memoQueue.items.filter { $0.profileId == workspaceProfiles.selected?.id || ($0.profileId == nil && workspaceProfiles.selected?.isDefault != false) }
    }
    @ObservedObject private var memoQueue = Container.shared.memoQueue()
    @Environment(\.dismiss) private var dismiss
    /// Closes the screen when it is a pager pane: `dismiss()` does nothing without a presentation.
    var onClose: (() -> Void)?

    var body: some View {
        Group {
            if onClose == nil {
                NavigationStack { screen }
            } else {
                screen
            }
        }
        .bind(observer: interactor, viewModel: viewModel)
    }

    private var screen: some View {
        Group {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    Text("History")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                    Picker("View", selection: Binding(
                        get: { viewModel.grouping },
                        set: { interactor.setGrouping($0, viewModel: viewModel) }
                    )) {
                        ForEach(HistoryViewModel.Grouping.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .accessibilityIdentifier("historyGrouping")

                    serviceFilter
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 12)

                    if viewModel.grouping == .actions {
                        // `isActionsEmpty` covers only action and dispatch rows, and can be true offline, so it
                        // must not hide the notes waiting to send.
                        if viewModel.isActionsEmpty && profileMemos.isEmpty {
                            actionEmptyState
                        } else {
                            activityList
                        }
                    } else if viewModel.isEmpty {
                        emptyState
                    } else {
                        conversationList
                    }
                }
                .frame(maxWidth: 700)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            // History sits left of the voice screen; the chevron points toward home.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onClose?()
                    } label: {
                        Label("Back", systemImage: "chevron.right")
                            .labelStyle(.iconOnly)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("historyBackButton")
                }
            }
            .alert("Delete Command", isPresented: $viewModel.showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    interactor.confirmDelete(viewModel: viewModel)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This command will be permanently deleted.")
            }
            .alert("Delete Conversation", isPresented: $viewModel.showDeleteConversationAlert) {
                Button("Delete", role: .destructive) {
                    interactor.confirmDeleteConversation(viewModel: viewModel)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This conversation and all its turns will be permanently deleted.")
            }
        }
        // `dismiss` is an environment value the interactor cannot reach, so the view model
        // carries the request back.
        .onChange(of: viewModel.shouldDismiss) { _, shouldDismiss in
            if shouldDismiss {
                viewModel.shouldDismiss = false
                if let onClose {
                    onClose()
                } else {
                    dismiss()
                }
            }
        }
    }

    // MARK: - Service filter strip

    /// Wraps instead of scrolling sideways: a horizontal ScrollView here would steal the
    /// pager's drag.
    private var serviceFilter: some View {
        ChipFlowLayout(spacing: 8) {
            ForEach(viewModel.services, id: \.self) { service in
                serviceChip(service)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func serviceChip(_ service: String) -> some View {
        let isSelected = (viewModel.selectedService == service)
            || (service == "All" && viewModel.selectedService == nil)
        return Button {
            interactor.select(service: service, viewModel: viewModel)
        } label: {
            HStack(spacing: 5) {
                if service != "All" {
                    Image(systemName: CommandRecord.icon(for: service))
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Theme.background : Theme.serviceColor(for: service))
                }
                Text(service)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.background : Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Theme.accent : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isSelected ? Color.clear : Theme.border, lineWidth: 0.5)
            )
        }
        .accessibilityIdentifier("serviceFilter_\(service)")
    }

    /// Rough guess at whether three lines clip the text; it only decides whether to show the hint.
    private func isTruncated(_ text: String) -> Bool {
        text.count > 120 || text.contains("\n")
    }

    // MARK: - Turn rows (nested under a conversation)

    private func commandDetailRow(_ command: CommandRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.serviceColor(for: command.serviceName).opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: command.serviceIcon)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.serviceColor(for: command.serviceName))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(command.commandText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(viewModel.expanded.contains(command.id) ? nil : 2)
                    HStack(spacing: 6) {
                        Text(command.serviceName)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.serviceColor(for: command.serviceName))
                        if command.durationSeconds > 0 {
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                            HStack(spacing: 3) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 9))
                                Text(String(format: "%.1fs", command.durationSeconds))
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(Theme.accent.opacity(0.8))
                        }
                        // Time to first audio, beside the round trip. Nil on rows written before it was measured.
                        if let waited = command.latency?.toFirstAudioMs {
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                            HStack(spacing: 3) {
                                Image(systemName: "hourglass")
                                    .font(.system(size: 9))
                                Text(String(format: "%.1fs", Double(waited) / 1000))
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text(command.issuedAt.formatted(.dateTime.hour().minute()))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }

            if !command.responseText.isEmpty && command.responseText != "Processing..." {
                let isOpen = viewModel.expanded.contains(command.id)
                let failed = command.status == .failed
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 5) {
                        // Without this a failure reads as an answer — the
                        // response field holds the error text either way.
                        if failed {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.warning)
                                .padding(.top, 2)
                        }
                        Text(command.responseText)
                            .font(.system(size: 12))
                            .foregroundStyle(failed ? Theme.warning : Theme.textSecondary)
                            // nil, not a large number: a cap still truncates a
                            // long answer, which is the thing tapping undoes.
                            .lineLimit(isOpen ? nil : 3)
                            .textSelection(.enabled)
                    }

                    if isOpen {
                        Button {
                            interactor.copy(command.responseText)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        // Without this the row's tap gesture swallows the tap
                        // and the row collapses instead of copying.
                        .onTapGesture {
                            interactor.copy(command.responseText)
                        }
                    } else if isTruncated(command.responseText) {
                        // Only advertise expansion when something is hidden.
                        Text("Tap to read more")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.18), value: viewModel.expanded.contains(command.id))
        .accessibilityIdentifier("historyRow_\(command.id)")
        .accessibilityHint(viewModel.expanded.contains(command.id) ? "Collapse response" : "Expand response")
    }

    // MARK: - Conversations

    /// The threads the assistant can pick back up, each with its turns behind a disclosure
    /// chevron. Resuming loads that conversation's turns as context.
    private var conversationList: some View {
        List {
            ForEach(viewModel.conversations) { conversation in
                conversationRow(conversation)
                    .listRowBackground(Theme.surface)
                    .listRowSeparatorTint(Theme.border)
                    .contextMenu { exportActions(conversation) }

                if viewModel.expandedConversations.contains(conversation.id) {
                    // Oldest first, as `Conversation.records` is stored.
                    ForEach(conversation.records) { command in
                        commandDetailRow(command)
                            .padding(.leading, 12)
                            .contentShape(Rectangle())
                            .onTapGesture { interactor.toggleExpanded(command.id, viewModel: viewModel) }
                            .listRowBackground(Theme.surfaceSecondary)
                            .listRowSeparatorTint(Theme.border)
                            // A long-press menu, not `.swipeActions`: the root pager's ScrollView claims the
                            // horizontal drag, and tap is taken by expand/collapse.
                            .contextMenu {
                                Button(role: .destructive) {
                                    interactor.requestDelete(command, viewModel: viewModel)
                                } label: {
                                    Label("Delete turn", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    /// Share and Copy for a conversation, on the context menu so the row's tap stays Resume.
    /// `ShareLink` shares the text directly, so it reaches Slack and Mail without a save step.
    @ViewBuilder
    private func exportActions(_ conversation: Conversation) -> some View {
        ShareLink(item: conversation.transcript, subject: Text(conversation.title)) {
            Label("Export transcript", systemImage: "square.and.arrow.up")
        }
        Button {
            interactor.copy(conversation.transcript)
        } label: {
            Label("Copy transcript", systemImage: "doc.on.doc")
        }
        Divider()
        Button(role: .destructive) {
            interactor.requestDeleteConversation(conversation, viewModel: viewModel)
        } label: {
            Label("Delete conversation", systemImage: "trash")
        }
    }

    /// How long a conversation ran, in the coarsest unit that still reads as a length.
    private func durationText(_ conversation: Conversation) -> String {
        let minutes = Int(conversation.duration / 60)
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
        }
        // A resumed conversation can span days; an hour count past 24 reads as
        // a mistake rather than a length.
        let days = hours / 24
        return days == 1 ? "1 day" : "\(days) days"
    }

    /// Resumable only with a real conversation id and rows in this phone's context store,
    /// which is the only memory a resumed call has. Another phone's call is readable, not resumable.
    private func canResume(_ conversation: Conversation) -> Bool {
        guard let id = conversation.resumableId else { return false }
        return viewModel.conversationsWithContext.contains(id)
    }

    /// Current for the live conversation, Resume where this phone holds context, otherwise nil.
    private func resumeLabel(_ conversation: Conversation, isActive: Bool) -> String? {
        if isActive { return "Current" }
        return canResume(conversation) ? "Resume" : nil
    }

    /// Two tap targets, not one Button: the chevron opens the turns in place and the row resumes.
    private func conversationRow(_ conversation: Conversation) -> some View {
        let isActive = conversation.id == viewModel.activeConversationId
        let isOpen = viewModel.expandedConversations.contains(conversation.id)
        return HStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(durationText(conversation))
                        Text("·")
                        Text(conversation.lastActivity.formatted(.relative(presentation: .numeric)))
                        if isActive {
                            Text("· active")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)
                // No label where there is nothing to resume; see `canResume`.
                if let label = resumeLabel(conversation, isActive: isActive) {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isActive ? Theme.textTertiary : Theme.accent)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard canResume(conversation) else { return }
                interactor.resume(conversation, viewModel: viewModel)
            }

            Button {
                interactor.toggleTurns(of: conversation, viewModel: viewModel)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(isOpen ? 0 : -90))
                    .animation(.easeInOut(duration: 0.18), value: isOpen)
                    .frame(width: 28, height: 28)
                    .background(Theme.surfaceSecondary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isOpen ? "Hide turns" : "Show turns")
            .accessibilityIdentifier("conversationTurnsToggle_\(conversation.id)")
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("conversationRow_\(conversation.id)")
    }

    // MARK: - Actions (writes and dispatched lookups, one list)

    /// Everything the assistant did, newest first: writes (each with a link) interleaved with
    /// dispatched lookups. Read-only; dispatch delivery and recovery stay in `DispatchJobStore.recover`.
    private var activityList: some View {
        // `ScrollViewReader` only so a notification tap can land on its own row.
        ScrollViewReader { proxy in
            activityRows
                // `onAppear` matters most: a cold-start push sets the target before this list exists,
                // and `onChange` only fires while the view is alive.
                .onAppear { scroll(proxy, to: viewModel.scrollTarget) }
                .onChange(of: viewModel.scrollTarget) { _, target in
                    scroll(proxy, to: target)
                }
                // The rows arrive asynchronously, so appearing is not the same moment as having them.
                .onChange(of: viewModel.activityEntries.count) { _, _ in
                    scroll(proxy, to: viewModel.scrollTarget)
                }
        }
    }

    /// Move to the row and stop asking. Cleared through the router too, whose copy survives
    /// a cold start and would otherwise re-scroll on every open.
    private func scroll(_ proxy: ScrollViewProxy, to target: UUID?) {
        guard let target else { return }
        guard viewModel.activityEntries.contains(where: { $0.id == target }) else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(target, anchor: .center)
        }
        viewModel.scrollTarget = nil
        interactor.consumeScrollTarget()
        // Long enough to see after the scroll settles, short enough not to read as a selection.
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.4)) { viewModel.highlighted = nil }
        }
    }

    private var activityRows: some View {
        List {
            // A pinned section, not interleaved: a note has not happened yet, and sorting it by capture
            // time would bury it. It leaves at the instant `DispatchWorker` claims it.
            if !profileMemos.isEmpty {
                Section {
                    ForEach(profileMemos) { memo in
                        MemoRow(memo: memo, queue: memoQueue)
                            .listRowBackground(Theme.surface)
                            .listRowSeparatorTint(Theme.border)
                    }
                } header: {
                    Text("Waiting to send")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            ForEach(viewModel.activityEntries) { entry in
                Group {
                    switch entry {
                    case .action(let record): actionRow(record)
                    case .dispatch(let job): dispatchRow(job)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { interactor.toggleExpanded(entry.id, viewModel: viewModel) }
                // `listRowBackground` so the tint fills the full row. `Theme.accent` resolves per
                // appearance, so one opacity works in light and dark.
                .listRowBackground(
                    (viewModel.highlighted == entry.id ? Theme.accent.opacity(0.24) : Theme.surface)
                        .animation(.easeInOut(duration: 0.25), value: viewModel.highlighted)
                )
                .listRowSeparatorTint(Theme.border)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func actionRow(_ record: ActionRecord) -> some View {
        let isOpen = viewModel.expanded.contains(record.id)
        let state = actionState(record)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: ToolNarration.sourceIcon(for: record.tool) ?? "checkmark.seal")
                    .font(.system(size: 11))
                    .foregroundStyle(state.color)

                Text(state.label)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(state.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(state.color.opacity(0.12))
                    .clipShape(Capsule())

                Spacer()

                if let stamp = record.completedAt ?? record.startedAt {
                    Text(stamp.formatted(.relative(presentation: .numeric)))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            // The broker's own phrasing: the receipt the assistant spoke.
            Text(record.summary)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(isOpen ? nil : 2)

            Text(record.account)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)

            // Always visible rather than behind the disclosure, so failures are scannable.
            if let detail = record.detail, !detail.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(detail)
                        .font(.system(size: 12))
                        .lineLimit(isOpen ? nil : 2)
                        .textSelection(.enabled)
                }
                .foregroundStyle(state.color)
                .padding(.horizontal, 4)
            }

            if isOpen { actionDetail(record) }
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.18), value: isOpen)
        .accessibilityIdentifier("actionRow_\(record.id)")
    }

    /// The proof, once a row is open: what ran, against what, and where to go and see it.
    private func actionDetail(_ record: ActionRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Theme.border)

            actionField("Tool", record.tool)
            if let itemId = record.itemId, !itemId.isEmpty {
                actionField(idLabel(for: record), itemId)
            }

            if let url = record.proofURL {
                // Gmail's `#all/<id>` is a fragment only desktop Gmail routes, so Gmail rows copy the link;
                // path/query links open. Not a `Link`: the row's tap gesture would swallow or double it.
                let opensHere = record.connector != "gmail"
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(openLabel(for: record.connector))
                        Image(systemName: opensHere ? "arrow.up.right.square" : "doc.on.doc")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)

                    if !opensHere {
                        Text("Opens on a computer — Gmail for iPhone can't open a link to one message.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if opensHere {
                        UIApplication.shared.open(url)
                    } else {
                        interactor.copy(url.absoluteString)
                    }
                }
                .accessibilityAddTraits(opensHere ? .isLink : .isButton)
                .accessibilityIdentifier("actionProofLink_\(record.id)")
            } else {
                // Say which of the two reasons it is. "No link" alone reads as a bug.
                Text(record.isDone
                     ? "No link — this one has nothing openable to point at."
                     : "No link — this didn't happen, so there is nothing to show.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 4)
    }

    /// What to call the identifier. GitHub's depends on the tool (sha, number, id), so this
    /// takes the record; Slack's is a message timestamp, not a conversation id.
    private func idLabel(for record: ActionRecord) -> String {
        switch record.connector {
        case "calendar": return "Event"
        case "github":
            switch ToolNarration.canonical(record.tool) {
            case "merge_pull_request": return "Commit"
            case "issue_write": return "Issue"
            case "add_issue_comment": return "Comment"
            case "update_pull_request": return "Pull request"
            // A dispatch carries its workflow file, a re-run or cancel the run's id; "Run" fits both.
            case "actions_run_trigger": return "Run"
            default: return "Item"
            }
        default: return "Message"
        }
    }

    private func openLabel(for connector: String) -> String {
        switch connector {
        case "calendar": return "Open in Google Calendar"
        case "github": return "Open in GitHub"
        // Gmail cannot be opened from a phone at all — see the note above `opensHere`.
        default: return "Copy link to this message"
        }
    }

    private func actionField(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
        }
    }

    /// What to call a write's state. `pending` past its tolerance is "abandoned", not failed:
    /// the broker was evicted mid-write and nobody knows the outcome.
    private func actionState(_ record: ActionRecord) -> (label: String, color: Color) {
        if record.isDone { return ("Done", Theme.success) }
        if record.didFail { return ("Failed", Theme.error) }
        if record.isPending {
            return record.isAbandoned()
                ? ("Unconfirmed", Theme.warning)
                : ("Working", Theme.conversing)
        }
        // A state this build doesn't know — a newer broker wrote it. Show it raw
        // rather than guessing, same as `dispatchState`.
        return (record.state.capitalized, Theme.textTertiary)
    }

    /// Names the connectors it covers, so a write missing from the list does not read as
    /// "nothing happened".
    private var actionEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textTertiary)
            Text("No actions yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("Ask the assistant to send, archive, label or schedule something — each one lands here with a link to the item. Dispatched lookups land here too, with their status and their answer.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            // Named rather than "every connector": the recorded set is smaller than Settings implies.
            Text("Covering Gmail, Calendar and Notion.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    // MARK: - Dispatch rows

    private func dispatchRow(_ job: DispatchJob) -> some View {
        let isOpen = viewModel.expanded.contains(job.id)
        let state = dispatchState(job)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(state.label)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(state.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(state.color.opacity(0.12))
                    .clipShape(Capsule())

                // An answer nobody heard. It is spoken on the next connect; until then only this shows it.
                if job.deliveredAt == nil, job.recoveredAnswer() != nil {
                    HStack(spacing: 3) {
                        Image(systemName: "bell.badge")
                            .font(.system(size: 9))
                        Text("Unheard")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                }

                Spacer()

                if let stamp = job.completedAt ?? job.startedAt {
                    Text(stamp.formatted(.relative(presentation: .numeric)))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Text(job.task)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(isOpen ? nil : 2)

            if let result = job.result, !result.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(result)
                        .font(.system(size: 12))
                        .foregroundStyle(job.didFail ? Theme.warning : Theme.textSecondary)
                        .lineLimit(isOpen ? nil : 3)
                        .textSelection(.enabled)

                    if isOpen {
                        Button {
                            interactor.copy(result)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        // Without this the row's tap gesture swallows the tap and collapses the row.
                        .onTapGesture {
                            interactor.copy(result)
                        }
                    } else if isTruncated(result) {
                        Text("Tap to read more")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.18), value: isOpen)
        .accessibilityIdentifier("dispatchRow_\(job.id)")
    }

    /// What to call a job's state. Nothing resumes a dispatch, so a stale `running` row
    /// past its tolerance reads as never finished.
    private func dispatchState(_ job: DispatchJob) -> (label: String, color: Color) {
        if job.isDone { return ("Done", Theme.success) }
        if job.didFail { return ("Failed", Theme.error) }
        if job.isRunning {
            return job.hasStopped()
                ? ("Never finished", Theme.warning)
                : ("Running", Theme.conversing)
        }
        // A state this build doesn't know — a newer build wrote it. Show it
        // raw rather than guessing.
        return (job.state.capitalized, Theme.textTertiary)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textTertiary)
            Text("No command history yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("Your voice commands will appear here after you issue them from the Command tab.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }
}

// MARK: - Chip layout

/// Left-to-right, wrapping when a chip won't fit, so the strip never scrolls.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Component

/// The screen's constructor, and the only place that knows which interactor it runs with.
@MainActor
struct HistoryViewComponent {
    @ViewBuilder
    static func make(
        viewModel: HistoryViewModel? = nil,
        interactor: HistoryViewInteractor? = nil,
        onClose: (() -> Void)? = nil
    ) -> some View {
        HistoryView(viewModel: viewModel ?? HistoryViewModel(), interactor: interactor ?? HistoryViewInteractor(), onClose: onClose)
    }
}

// MARK: - View model

/// Everything the History screen draws, computed by the interactor once per change.
@MainActor
final class HistoryViewModel: ViewModel {
    /// Conversations are the threads you can pick back up; Actions interleaves the writes the
    /// assistant made with the lookups it dispatched, as distinct rows.
    enum Grouping: String, CaseIterable {
        case conversations = "Conversations"
        case actions = "Actions"
    }

    /// One row of the merged Actions list: a write or a dispatched lookup.
    enum ActivityEntry: Identifiable {
        case action(ActionRecord)
        case dispatch(DispatchJob)

        var id: UUID {
            switch self {
            case .action(let record): return record.id
            case .dispatch(let job): return job.id
            }
        }

        /// When it happened, for interleaving. Settled time when there is one,
        /// otherwise started time — a row still in flight sorts by when it began.
        var sortDate: Date {
            switch self {
            case .action(let record): return record.completedAt ?? record.startedAt ?? .distantPast
            case .dispatch(let job): return job.completedAt ?? job.startedAt ?? .distantPast
            }
        }
    }

    @Published var grouping: Grouping = .conversations
    /// `nil` means "All" — the chip strip's first entry.
    @Published var selectedService: String?
    @Published var services: [String] = ["All"]
    @Published var conversations: [Conversation] = []
    /// The action and dispatch rows the current chip lets through, newest first. Loaded per
    /// appearance: neither `ActionStore` nor `DispatchJobStore` publishes changes.
    @Published var activityEntries: [ActivityEntry] = []
    /// A row the list should scroll to, set by a notification tap and cleared once the
    /// list has moved. Nil the rest of the time, which is every ordinary appearance.
    @Published var scrollTarget: UUID?
    /// The row to tint while the user finds it. Cleared on a timer: a marker, not a selection.
    @Published var highlighted: UUID?
    /// True when there are no action or dispatch rows at all, as opposed to none
    /// matching the selected chip — same distinction `isEmpty` draws for commands.
    @Published var isActionsEmpty = true
    /// Conversations whose turns are unfolded beneath them.
    @Published var expandedConversations: Set<UUID> = []
    /// True when there is no history at all, as opposed to none matching the current filter.
    @Published var isEmpty = true
    /// Rows the user has tapped open. Collapsed by default so the list stays scannable.
    @Published var expanded: Set<UUID> = []
    @Published var commandToDelete: CommandRecord?
    @Published var showDeleteAlert = false
    @Published var conversationToDelete: Conversation?
    @Published var showDeleteConversationAlert = false
    @Published var activeConversationId: UUID?
    /// Conversations this phone still holds context for, the ones Resume is offered on.
    /// Empty until the store answers, so Resume may appear a frame late.
    @Published var conversationsWithContext: Set<UUID> = []
    /// Set by the interactor when resuming; the view turns it into a `dismiss()`.
    @Published var shouldDismiss = false
}

// MARK: - Interactor

@MainActor
final class HistoryViewInteractor: ViewModelInteractor<HistoryViewModel> {
    @Injected(\.commandStore) private var commandStore
    @Injected(\.realtimeService) private var realtimeService
    @Injected(\.connections) private var connections
    @Injected(\.dispatchJobs) private var dispatchStore
    @Injected(\.actions) private var actionStore
    @Injected(\.historyRouter) private var historyRouter
    @Injected(\.localContext) private var localContext
    @Injected(\.voiceLauncher) private var voiceLauncher

    @CancellableBuilder
    override func onLoad(viewModel: HistoryViewModel) -> [AnyCancellable] {
        super.onLoad(viewModel: viewModel)

        // One subscription over commands, service, connector state and grouping: every visible
        // list depends on all four. `receive(on:)` reads services after `objectWillChange` lands.
        commandStore.$commands
            .combineLatest(
                viewModel.$selectedService,
                viewModel.$grouping,
                connections.objectWillChange.map { _ in () }.prepend(())
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] commands, service, _, _ in
                self?.apply(commands: commands, service: service, viewModel: viewModel)
            }

        realtimeService.$activeConversationId
            .receive(on: DispatchQueue.main)
            .sink { id in
                viewModel.activeConversationId = id
            }

        // Observe tab requests while the pager owns this interactor; ContentView
        // consumes the pane request independently.
        historyRouter.$pendingTab
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tab in
                // Through `setGrouping`: switching to .actions reloads rows a notification just updated.
                self?.setGrouping(tab, viewModel: viewModel)
                self?.historyRouter.consumeTab()
            }

        // A notification row is scrolled to and highlighted, not expanded. Not consumed here:
        // on a cold start the rows may not have loaded, so `activityList` clears it after scrolling.
        historyRouter.$pendingEntryId
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                viewModel.scrollTarget = id
                viewModel.highlighted = id
                // The tapped row finished moments ago; re-read so it says "Done", not a stale state.
                self?.reloadDispatch(viewModel: viewModel)
                self?.reloadActions(viewModel: viewModel)
            }
    }

    @CancellableBuilder
    override func onViewAppear(viewModel: HistoryViewModel) -> [AnyCancellable] {
        super.onViewAppear(viewModel: viewModel)
        // Re-read on every appearance: turns were just spoken, and `DispatchJobStore` publishes nothing.
        Task { await self.commandStore.refresh() }
        reloadDispatch(viewModel: viewModel)
        reloadActions(viewModel: viewModel)
        reloadResumable(viewModel: viewModel)
    }

    /// Which conversations still have context on this phone, for the Resume gate. Read on
    /// every appearance, since the call just ended may have written its first rows.
    private func reloadResumable(viewModel: HistoryViewModel) {
        Task { [localContext] in
            let ids = await localContext.conversationsWithContext()
            viewModel.conversationsWithContext = ids
        }
    }

    /// Every dispatch row, unfiltered, so a chip change re-filters without a network read.
    private var allDispatchJobs: [DispatchJob] = []

    /// Fetch the dispatch rows for the panel. Fire-and-forget: a failed read
    /// draws the empty state, and the next appearance or tab switch retries.
    private func reloadDispatch(viewModel: HistoryViewModel) {
        Task {
            self.allDispatchJobs = await self.dispatchStore.history()
            self.apply(commands: self.commandStore.commands,
                       service: viewModel.selectedService,
                       viewModel: viewModel)
        }
    }

    /// Every action row, unfiltered — the same arrangement as `allDispatchJobs`, so a
    /// chip change re-filters without another network read.
    private var allActionRecords: [ActionRecord] = []

    /// Fetch the action rows. Same fire-and-forget posture as `reloadDispatch`.
    private func reloadActions(viewModel: HistoryViewModel) {
        Task {
            self.allActionRecords = await self.actionStore.history()
            self.apply(commands: self.commandStore.commands,
                       service: viewModel.selectedService,
                       viewModel: viewModel)
        }
    }

    /// Recompute every visible list from one source of truth.
    private func apply(commands: [CommandRecord], service: String?, viewModel: HistoryViewModel) {
        viewModel.isEmpty = commands.isEmpty
        viewModel.isActionsEmpty = allActionRecords.isEmpty && allDispatchJobs.isEmpty

        // A chip is offered when the account can reach the service and the tab has rows under it;
        // `knownServices` only orders them. Rows are not filtered by reachability, only chips.
        let names: Set<String>
        switch viewModel.grouping {
        case .actions:
            names = Set(allActionRecords.map { $0.serviceName })
                .union(allDispatchJobs.map { RealtimeService.inferService(from: $0.task) })
        case .conversations:
            names = Set(commands.map { $0.serviceName })
        }
        let reachable = Set(connections.connectedServices)
        viewModel.services = ["All"] + CommandRecord.knownServices
            .map { $0.name }
            .filter { names.contains($0) && reachable.contains($0) }

        // A selected chip that is no longer drawn would leave an empty list under "All".
        if let selected = service, !viewModel.services.contains(selected) {
            viewModel.selectedService = nil
            return
        }

        let filtered: [CommandRecord]
        if let service, service != "All" {
            filtered = commands.filter { $0.serviceName == service }
        } else {
            filtered = commands
        }

        viewModel.conversations = Conversation.group(filtered)

        let actions: [ActionRecord]
        let jobs: [DispatchJob]
        if let service, service != "All" {
            actions = allActionRecords.filter { $0.serviceName == service }
            jobs = allDispatchJobs.filter {
                RealtimeService.inferService(from: $0.task) == service
            }
        } else {
            actions = allActionRecords
            jobs = allDispatchJobs
        }
        viewModel.activityEntries =
            (actions.map(HistoryViewModel.ActivityEntry.action)
                + jobs.map(HistoryViewModel.ActivityEntry.dispatch))
            .sorted { $0.sortDate > $1.sortDate }
    }
}

extension HistoryViewInteractor: HistoryViewHandler {
    func select(service: String, viewModel: HistoryViewModel) {
        viewModel.selectedService = (service == "All") ? nil : service
    }

    func setGrouping(_ grouping: HistoryViewModel.Grouping, viewModel: HistoryViewModel) {
        viewModel.grouping = grouping
        // Landing on the panel is the moment its rows are looked at, so it is
        // the moment they should be fresh — both kinds, since the list holds both.
        switch grouping {
        case .actions:
            reloadDispatch(viewModel: viewModel)
            reloadActions(viewModel: viewModel)
        case .conversations: break
        }
    }

    func toggleExpanded(_ id: UUID, viewModel: HistoryViewModel) {
        if viewModel.expanded.contains(id) {
            viewModel.expanded.remove(id)
        } else {
            viewModel.expanded.insert(id)
        }
    }

    func consumeScrollTarget() {
        historyRouter.consumeEntry()
    }

    func toggleTurns(of conversation: Conversation, viewModel: HistoryViewModel) {
        if viewModel.expandedConversations.contains(conversation.id) {
            viewModel.expandedConversations.remove(conversation.id)
        } else {
            viewModel.expandedConversations.insert(conversation.id)
        }
    }

    func requestDelete(_ command: CommandRecord, viewModel: HistoryViewModel) {
        // The ask, not the answer: `command_deleted` says one went through.
        viewModel.commandToDelete = command
        viewModel.showDeleteAlert = true
    }

    func confirmDelete(viewModel: HistoryViewModel) {
        guard let command = viewModel.commandToDelete else { return }
        viewModel.commandToDelete = nil
        Task { await self.commandStore.delete(command) }
    }

    func requestDeleteConversation(_ conversation: Conversation, viewModel: HistoryViewModel) {
        viewModel.conversationToDelete = conversation
        viewModel.showDeleteConversationAlert = true
    }

    func confirmDeleteConversation(viewModel: HistoryViewModel) {
        guard let conversation = viewModel.conversationToDelete else { return }
        viewModel.conversationToDelete = nil
        // Sequential: `CommandStore.delete` republishes its array per record, and racing
        // deletes would interleave those writes.
        Task {
            for record in conversation.records {
                await self.commandStore.delete(record)
            }
        }
    }

    /// Pick a conversation up and dial into it via `requestLaunch()`, which runs the voice
    /// screen's gates. Only requested when `resume(_:)` adopted the id, or it would start a new call.
    func resume(_ conversation: Conversation, viewModel: HistoryViewModel) {
        guard realtimeService.resume(conversation) else { return }
        voiceLauncher.requestLaunch(source: "resume")
        viewModel.shouldDismiss = true
    }

    func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}

// MARK: - Waiting to send

/// One unsent note. The transcript is editable because it becomes an agent's instruction
/// with no live call to correct it; a separate view because the edit buffer needs `@State`.
private struct MemoRow: View {

    let memo: QueuedMemo
    let queue: MemoQueue

    /// Gates Send: a send with no route fails silently and burns one of five attempts.
    @ObservedObject private var connectivity = Container.shared.connectivity()

    @State private var draft: String = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(status.label)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(status.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(status.color.opacity(0.12))
                    .clipShape(Capsule())

                Spacer()

                Text(memo.capturedAt.formatted(.relative(presentation: .numeric)))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }

            if memo.transcript.isEmpty && memo.state != .needsReview {
                // Says which of the two reasons it is; only one needs the user to act.
                Text(memo.state == .awaitingModel
                     ? "Waiting for the offline speech model to download."
                     : "Transcribing…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                TextField("What you said", text: $draft, axis: .vertical)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1...6)
                    .focused($editing)
                    .textFieldStyle(.plain)
                    // Committed on focus loss, not per keystroke: the queue writes its manifest on every mutation.
                    .onChange(of: editing) { _, isEditing in
                        if !isEditing { commit() }
                    }
                    .onSubmit(commit)
            }

            if let error = memo.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
            } else if !connectivity.isOnline && memo.isSendable {
                // Says why the button is dim, so the row reads as waiting rather than broken.
                Text("Waiting for a connection.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }

            HStack(spacing: 16) {
                Button {
                    commit()
                    Task { await queue.send(memo.id) }
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Theme.accent : Theme.textTertiary)
                .disabled(!canSend)

                Button {
                    queue.remove(memo.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)

                Spacer()

                if memo.state == .sending {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("memoRow_\(memo.id)")
        // `onAppear` rather than an initialiser default: `ForEach` reuses row views, so
        // a `@State` seeded at init would keep the previous memo's text.
        .onAppear { draft = memo.transcript }
        .onChange(of: memo.transcript) { _, text in
            guard !editing else { return }
            draft = text
        }
    }

    private var canSend: Bool {
        memo.isSendable && memo.state != .sending && connectivity.isOnline
    }

    private func commit() {
        guard draft != memo.transcript else { return }
        queue.updateTranscript(draft, for: memo.id)
    }

    private var status: (label: String, color: Color) {
        switch memo.state {
        case .awaitingModel: ("NO MODEL YET", Theme.textTertiary)
        case .transcribing: ("TRANSCRIBING", Theme.textTertiary)
        case .needsReview: ("COULDN'T HEAR IT", Theme.warning)
        // Not "ready to send": nothing waits for a tap.
        case .ready: connectivity.isOnline
            ? ("SENDING", Theme.accent)
            : ("WAITING FOR SIGNAL", Theme.textTertiary)
        case .sending: ("SENDING", Theme.accent)
        case .failed: ("DIDN'T SEND", Theme.warning)
        }
    }
}

#if DEBUG
import Prefire

#Preview("HistoryView") {
    // Registering the mocks is the injection; `PreviewHistoryViewHost` seeds them.
    PreviewHistoryViewHost()
        .snapshot(delay: 0.5)
}
#endif
