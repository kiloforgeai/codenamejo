#if targetEnvironment(macCatalyst)
import SwiftUI

struct DesktopFeedSidebar: View {
    @ObservedObject var viewModel: DesktopWorkspaceModel
    var select: (DesktopFeedRow) -> Void
    var refresh: () -> Void

    var body: some View {
        let rows = viewModel.filteredQueue
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Work feed").font(.system(size: 17, weight: .semibold))
                Spacer()
                if viewModel.selectingFeedItem || viewModel.refreshingFeed || viewModel.previewRefreshing {
                    ProgressView().controlSize(.mini).accessibilityLabel("Refreshing work feed")
                }
                Button(action: refresh) { Image(systemName: "arrow.clockwise").frame(width: 26, height: 26) }
                    .buttonStyle(.borderless).accessibilityLabel("Refresh feed")
                    .accessibilityIdentifier("refreshDesktopFeed").help("Check for new work while keeping your place")
                    .disabled(viewModel.refreshingFeed || viewModel.previewRefreshing || viewModel.isStartingFeed)
                Text(viewModel.feedCountLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                    .accessibilityIdentifier("desktopFeedCount")
                    .help(viewModel.inSession ? "Items prepared for this session" : "Approximate inbox messages and unread Slack conversations. The preview shows a limited selection.")
            }.padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 12)
            Picker("Filter prepared work", selection: $viewModel.filter) {
                Text("All").tag("All")
                Text("Email").tag("Email")
                Text("Slack").tag("Slack")
                Text("Calendar").tag("Calendar")
            }.pickerStyle(.menu).padding(.horizontal, 14).padding(.bottom, 12)
            if viewModel.isStartingFeed || viewModel.scopeHydrating {
                Text(viewModel.scopeHydrating ? "Connecting · keeping your place" : "Starting session · keeping your place")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).padding(.bottom, 12)
                    .accessibilityIdentifier("desktopFeedHandoff")
            } else if viewModel.inSession && viewModel.sessionFeed.status == .unavailable {
                Text("Couldn’t refresh · keeping your place. Try Refresh feed.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 12)
            } else if !viewModel.inSession {
                Text(viewModel.feedPreview?.incomplete == true
                     ? "Some sources couldn’t refresh. Showing available work; counts may be incomplete."
                     : "Inbox preview · refreshes every 2 min")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).padding(.bottom, 12)
                    .accessibilityIdentifier("desktopFeedPreviewStatus")
            }
            if !viewModel.workQueueTasks.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        Label("Research & results · \(viewModel.workQueueTasks.count)", systemImage: "tray.and.arrow.down")
                            .font(.caption.weight(.semibold)).padding(8)
                        ForEach(viewModel.workQueueTasks) { job in
                            DesktopTaskRow(job: job, selected: viewModel.selectedJob?.id == job.id) { viewModel.selectedJob = job }
                                .disabled(viewModel.selectingResult)
                            if viewModel.browserTasks[job.id]?.needsInput == true {
                                Button("View form", systemImage: "globe") { viewModel.applyTaskSelection(job) }
                                    .buttonStyle(.borderless).padding(.horizontal, 12).padding(.bottom, 8)
                            }
                        }
                    }.padding(.horizontal, 10)
                }.frame(maxHeight: min(300, CGFloat(viewModel.workQueueTasks.count * 112 + viewModel.pendingBrowserJobs.count * 36 + 36)))
                Divider().padding(.vertical, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if rows.isEmpty && viewModel.workQueueTasks.isEmpty {
                            feedEmptyState
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if let section = row.section,
                               index == 0 || rows[index - 1].section?.id != section.id {
                                VStack(alignment: .leading, spacing: 5) {
                                    if index > 0 { Divider().padding(.vertical, 8) }
                                    Label(section.title, systemImage: section.symbol)
                                        .font(.system(size: 12, weight: .semibold))
                                    if let account = section.account {
                                        Text(account).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }.padding(.horizontal, 5).padding(.top, 6).padding(.bottom, 5)
                                    .accessibilityIdentifier("feedSection_\(section.id)")
                            }
                            DesktopFeedRowButton(row: row, selected: viewModel.isCurrentRow(row)) { select(row) }
                                .disabled(viewModel.selectingFeedItem || viewModel.selectingResult || viewModel.isStartingFeed || viewModel.scopeHydrating)
                                .id(row.id)
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 8)
                }
                .onChange(of: viewModel.currentFeedRowID) { _, id in
                      if let id { proxy.scrollTo(id, anchor: .top) }
                }
            }
            if let error = viewModel.feedSelectionError {
                Text(error).font(.caption).foregroundStyle(.orange).padding(14)
            }
            if let error = viewModel.feedRefreshError {
                Text(error).font(.caption).foregroundStyle(.orange).padding(14)
                    .accessibilityIdentifier("feedRefreshError")
            }
            Divider().padding(.top, 12)
            Button { viewModel.showingHistory = true } label: {
                Label("Session history", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 14)
            }.buttonStyle(.plain)
        }.background(DesktopWorkspaceStyle.inset.opacity(0.6))
    }

    private var feedEmptyState: some View {
        let done = viewModel.feedComplete
        let unavailable = viewModel.inSession ? viewModel.sessionFeed.status == .unavailable : viewModel.feedPreview?.incomplete == true
        let filtered = !viewModel.feedRows.isEmpty
        let loading = viewModel.inSession || viewModel.feedPreview == nil
        return VStack(alignment: .leading, spacing: 14) {
            Image(systemName: done ? "checkmark.seal.fill" : unavailable ? "exclamationmark.triangle" : "tray")
                .font(.system(size: done ? 42 : 26)).foregroundStyle(done ? DesktopWorkspaceStyle.accent : Color.secondary)
            Text(done ? "You’re done." : unavailable ? "Couldn’t refresh the feed" : filtered ? "No \(viewModel.filter.lowercased()) here" : loading ? "Checking your work" : "Nothing waiting.")
                .font(.system(size: done ? 24 : 16, weight: .semibold))
            Text(done ? "Nice work. You’ve worked through the selected feed. Take a breath."
                 : unavailable ? (viewModel.inSession ? "Your place is saved. Ask Jo to try loading the next items again."
                    : "Check your connections in Settings. Jo will try again in the background.")
                 : filtered ? "Choose All to see the rest of your prepared work."
                 : loading ? (viewModel.inSession ? "Next items are loading in the background."
                    : "Your feed is loading in the background. You can start a session whenever you’re ready.")
                 : "Your connected inboxes and Slack have no work waiting. Jo will keep checking in the background.")
                .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
        }.padding(18).accessibilityIdentifier(done ? "feedComplete" : "feedEmptyState")
    }

}

private struct DesktopTaskRow: View {
    let job: DispatchJob
    let selected: Bool
    let action: () -> Void

    private var accessibilityText: String {
        job.task + ", " + job.desktopStatusLabel + (job.origin.map { ", " + $0.subject + ", " + $0.account } ?? "")
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    if job.isRunning && !job.hasStopped() { ProgressView().controlSize(.mini) }
                    else { Image(systemName: job.desktopStatusSymbol).font(.caption) }
                    Text(job.desktopStatusLabel).font(.caption.weight(.semibold))
                }.foregroundStyle(job.activityNeedsAttention ? Color.orange : Color.secondary)
                Text(job.task).font(.system(size: 13, weight: .medium)).lineLimit(2)
                if let origin = job.origin {
                    Text(origin.subject + " · " + origin.account).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(DesktopWorkspaceStyle.accent.opacity(selected ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityIdentifier("returnedTask_\(job.id)")
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Show this task and its original source in the center pane")
    }
}

private struct DesktopFeedRowButton: View {
    let row: DesktopFeedRow
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: row.symbol).font(.system(size: 11))
                    Text(row.detail.isEmpty ? row.source : row.detail).lineLimit(1)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").accessibilityHidden(true) }
                }.font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? DesktopWorkspaceStyle.accent : .secondary)
                Text(row.title).font(.system(size: 14, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                if let reason = row.reason {
                    Text(reason).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? DesktopWorkspaceStyle.accent.opacity(0.1)
                            : hovering ? Color.primary.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? DesktopWorkspaceStyle.accent.opacity(0.28) : .clear, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityLabel("\(row.source), \(row.title), \(row.detail)")
            .accessibilityValue(selected ? "In focus" : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("feedRow_\(row.id)")
            .help(selected ? "Current work item" : "Work on this item")
    }
}
#endif
