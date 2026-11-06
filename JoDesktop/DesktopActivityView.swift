#if targetEnvironment(macCatalyst)
import SwiftUI

struct DesktopActivityView: View {
    @ObservedObject var viewModel: DesktopWorkspaceModel
    @State private var visibleLimit = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DesktopWorkspaceStyle.caption("LIVE ACTIVITY").padding(22)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if viewModel.steps.isEmpty {
                        Label(viewModel.inSession
                            ? (viewModel.sessionIntent == .feed ? "Preparing your feed" : "Ready for your request")
                            : "Nothing running yet", systemImage: "circle.dotted")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.steps) { step in
                        HStack(alignment: .top, spacing: 11) {
                            if step.isRunning { ProgressView().controlSize(.mini) }
                            else { Image(systemName: step.outcome.symbol).foregroundStyle(step.failed ? .red : .green).font(.caption) }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.label).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                                if let elapsed = step.elapsed {
                                    Text(String(format: "%.1f s", elapsed)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    Divider().padding(.vertical, 8)
                    DesktopWorkspaceStyle.caption("ACTIONS")
                    Text("\(viewModel.runningJobs.count) running · \(viewModel.returnedTasks.count) to review")
                        .font(.caption).foregroundStyle(.secondary)
                    if viewModel.activityJobs.isEmpty {
                        Text("Action receipts appear here. Research and answers stay in your work feed.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                    }
                    ForEach(Array(viewModel.activityJobs.prefix(visibleLimit))) { job in
                        Button { viewModel.selectedJob = job } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 7) {
                                    Image(systemName: job.desktopStatusSymbol)
                                        .foregroundStyle(job.activityNeedsAttention ? Color.orange : DesktopWorkspaceStyle.accent)
                                    Text(job.activityTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if let date = job.completedAt ?? job.startedAt {
                                        Text(date, style: .time).font(.system(size: 10)).foregroundStyle(.tertiary)
                                    }
                                }
                                if let action = job.mailAction {
                                    Text(action.subject + " · " + action.account).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                } else if let origin = job.origin {
                                    Text(origin.sender + " · " + origin.account).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                if job.activityNeedsAttention, let result = job.result {
                                    Text(result).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(2)
                                }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(viewModel.selectedJob?.id == job.id ? DesktopWorkspaceStyle.accent.opacity(0.12) : DesktopWorkspaceStyle.inset.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).accessibilityIdentifier("activityTask_\(job.id)")
                            .accessibilityLabel(job.activityAccessibilityLabel)
                            .accessibilityHint("Show the full request, result and recorded actions in the center pane")
                            .disabled(viewModel.selectingResult)
                    }
                    if viewModel.activityJobs.count > visibleLimit {
                        Button("Show older actions (\(viewModel.activityJobs.count - visibleLimit))") { visibleLimit += 24 }
                            .buttonStyle(.borderless).accessibilityIdentifier("showOlderActivity")
                    }
                }.padding(.horizontal, 22).padding(.bottom, 22)
            }
            Spacer(minLength: 0)
        }
    }

}

extension DispatchJob {
    var activityNeedsAttention: Bool {
        if let action = mailAction {
            return action.state == .failed || action.state == .unknown
                || (result?.contains(LocalCompose.archiveUnconfirmed) == true)
        }
        return didFail || state == "unknown" || state == "awaiting_input" || (isRunning && hasStopped())
            || receipts?.contains(where: { $0.outcome != "success" }) == true
            || (result.map { text in ["unconfirmed", "not confirmed", "not completed", "warning:"].contains { text.lowercased().contains($0) } } ?? false)
    }

    var activityTitle: String {
        if let action = mailAction { return action.title }
        let title = origin.flatMap { origin -> String? in
            let subject = origin.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            return subject.isEmpty ? nil : subject
        } ?? task
        guard isDone, !activityNeedsAttention else { return (activityNeedsAttention ? desktopAttentionLabel : desktopStatusLabel) + " · " + title }
        let tools = Set(receipts?.filter { $0.outcome == "success" }.map { ToolNarration.canonical($0.tool) } ?? [])
        let labels = tools.sorted().compactMap { tool in
            ["archive_message": "Archived", "label_message": "Labeled", "send_email": "Sent", "create_draft": "Draft saved",
             "mark_spam": "Marked as spam", "trash_message": "Moved to Trash"][tool]
        }
        let action = !tools.isEmpty && labels.count == tools.count ? labels.joined(separator: " + ") : "Completed"
        return action + " · " + title
    }

    private var desktopAttentionLabel: String { state == "awaiting_input" ? "Needs your input" : state == "unknown" ? "Outcome unknown" : "Needs attention" }

    var activityAccessibilityLabel: String {
        if let action = mailAction {
            return action.title + ", " + action.subject + ", " + action.account
                + (activityNeedsAttention ? ", " + (result ?? action.state.label) : "")
        }
        return activityTitle + (origin.map { ", " + $0.sender + ", " + $0.account } ?? "")
            + (activityNeedsAttention ? ", " + (result ?? desktopAttentionLabel) : "")
    }

    var desktopStatusLabel: String {
        if let action = mailAction { return action.state.label }
        if state == "cancel_requested" { return "Cancellation requested" }
        if state == "cancelled" { return "Cancelled" }
        if state == "awaiting_input" { return "Needs your input" }
        if state == "queued" { return "Queued" }
        if activityNeedsAttention { return desktopAttentionLabel }
        if isDone { return effectivePreference == .quiet || deliveredAt != nil ? "Completed" : "Result ready" }
        return hasStopped() ? "Outcome unknown" : "Working in background"
    }
    var desktopStatusSymbol: String {
        if state == "awaiting_input" { return "questionmark.circle" }
        if state == "cancelled" { return "xmark.circle" }
        if state == "queued" { return "clock" }
        if activityNeedsAttention { return "exclamationmark.triangle" }
        return isDone ? "checkmark.circle" : "arrow.trianglehead.2.clockwise.rotate.90"
    }
}
#endif
