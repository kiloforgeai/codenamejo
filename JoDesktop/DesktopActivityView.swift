#if targetEnvironment(macCatalyst)
import SwiftUI

struct DesktopActivityView: View {
    @ObservedObject var viewModel: DesktopWorkspaceModel

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
                    DesktopWorkspaceStyle.caption("BACKGROUND WORK")
                    Text("\(viewModel.runningJobs.count) running · \(viewModel.returnedTasks.count) to review")
                        .font(.caption).foregroundStyle(.secondary)
                    if viewModel.jobs.isEmpty {
                        Text("Hand Jo a longer task and keep going. Its progress and result will appear here.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                    }
                    ForEach(Array(viewModel.activityJobs.prefix(12))) { job in
                        Button { viewModel.selectedJob = job } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(job.desktopStatusLabel, systemImage: job.desktopStatusSymbol)
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(job.didFail ? Color.orange : DesktopWorkspaceStyle.accent)
                                if let origin = job.origin {
                                    Text(origin.account + " · " + origin.subject).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Text(job.effectivePreference.label).font(.caption).foregroundStyle(.secondary)
                                Text(job.task).font(.system(size: 13, weight: .medium)).lineLimit(3)
                                if let result = job.result { Text(result).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3) }
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(viewModel.selectedJob?.id == job.id ? DesktopWorkspaceStyle.accent.opacity(0.12) : DesktopWorkspaceStyle.inset.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).accessibilityIdentifier("activityTask_\(job.id)")
                            .disabled(viewModel.selectingResult)
                    }
                }.padding(.horizontal, 22).padding(.bottom, 22)
            }
            Spacer(minLength: 0)
        }
    }

}

extension DispatchJob {
    var desktopStatusLabel: String {
        if state == "cancel_requested" { return "Cancellation requested" }
        if state == "cancelled" { return "Cancelled" }
        if state == "awaiting_input" { return "Needs your input" }
        if state == "queued" { return "Queued" }
        if didFail { return "Needs attention" }
        if isDone { return effectivePreference == .quiet || deliveredAt != nil ? "Completed" : "Result ready" }
        return hasStopped() ? "Outcome unknown" : "Working in background"
    }
    var desktopStatusSymbol: String {
        if state == "awaiting_input" { return "questionmark.circle" }
        if state == "cancelled" { return "xmark.circle" }
        if state == "queued" { return "clock" }
        if didFail || state == "unknown" || (isRunning && hasStopped()) { return "exclamationmark.triangle" }
        return isDone ? "checkmark.circle" : "arrow.trianglehead.2.clockwise.rotate.90"
    }
}
#endif
