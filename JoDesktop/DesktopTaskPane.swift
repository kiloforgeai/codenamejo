#if targetEnvironment(macCatalyst)
import SwiftUI

struct DesktopTaskPane<Handler: DesktopWorkspaceHandler>: View {
    @ObservedObject var viewModel: DesktopWorkspaceModel
    let interactor: Handler
    let job: DispatchJob

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label("Activity in focus", systemImage: "tray.and.arrow.down")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Back to feed", systemImage: "arrow.uturn.backward") { viewModel.selectedJob = nil }
                        .buttonStyle(.borderless).accessibilityIdentifier("backToFeed")
                        .disabled(viewModel.selectingResult)
                }
                Text(job.task).font(.title2.weight(.medium))
                Label(job.desktopStatusLabel, systemImage: job.didFail ? "exclamationmark.triangle" : "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
                Text(job.result ?? (job.hasStopped()
                    ? "This job stopped reporting. Its outcome is unknown. Ask Jo to check before trying it again."
                    : "This job is still running. Its result will appear here."))
                    .font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                Divider()
                if let origin = job.origin {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Source email").font(.caption).foregroundStyle(.secondary)
                        Text(origin.subject).font(.headline)
                        Text(origin.sender).textSelection(.enabled)
                        Text(origin.account).font(.caption).foregroundStyle(.secondary)
                        if job.hasStopped() {
                            Button("Work on this email") { interactor.selectReturnedResult(job.id) }
                                .buttonStyle(.borderedProminent)
                                .disabled(viewModel.selectingResult)
                                .accessibilityIdentifier("workOnReturnedEmail")
                            Text(viewModel.inSession
                                ? "Your place in the feed is kept while you work on this result."
                                : "Open the source email without starting voice.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                } else if job.hasStopped() {
                    Text("This result has no saved source email. Select the intended email before acting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Task \(job.id.uuidString.prefix(8)) · Revision \(job.taskRevision)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Text("Typed and spoken task follow-ups use this source while this activity is in focus.")
                    .font(.caption).foregroundStyle(.secondary)
                if job.context != nil {
                    if job.state == "awaiting_input", job.context?.deferredFeedbackArchive == true {
                        Button("Archive saved email") { interactor.resumeTaskArchive(job, model: viewModel) }
                            .buttonStyle(.borderedProminent).disabled(viewModel.updatingTask)
                        Text("Uses this task’s saved source, even if another email is now selected.").font(.caption).foregroundStyle(.secondary)
                    }
                    if job.state == "awaiting_input", let choices = job.inputChoices, !choices.isEmpty {
                        Text("Which page should Jo read?").font(.headline)
                        ForEach(choices) { choice in
                            Button(choice.label) { interactor.chooseTaskInput(job, choice: choice.id, model: viewModel) }
                                .buttonStyle(.bordered).disabled(viewModel.updatingTask)
                        }
                        Text("Reads the selected page only. Does not submit an RSVP.").font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("On success", selection: Binding(get: { job.effectivePreference }, set: {
                        interactor.setTaskPreference(job, preference: $0, model: viewModel)
                    })) {
                        ForEach(DispatchJob.CompletionPreference.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                    TextField("Correct this task’s instructions…", text: $viewModel.taskCorrection, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(3...6)
                    HStack {
                        Button("Update task") { interactor.updateTask(job, instruction: viewModel.taskCorrection, model: viewModel) }
                            .disabled(viewModel.updatingTask || viewModel.taskCorrection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if job.isRunning || job.state == "awaiting_input" {
                            Button(job.state == "cancel_requested" ? "Cancellation requested" : "Cancel task", role: .destructive) {
                                interactor.updateTask(job, instruction: nil, model: viewModel)
                            }.disabled(viewModel.updatingTask || job.state == "cancel_requested")
                        }
                    }
                }
                if job.needsReview {
                    Button("Mark reviewed") { interactor.reviewTask(job, model: viewModel) }
                    Text("Reviewing this result does not approve or run any further action.").font(.caption).foregroundStyle(.secondary)
                }
                if let receipts = job.receipts, !receipts.isEmpty {
                    Text("Recorded actions").font(.headline)
                    ForEach(Array(receipts.enumerated()), id: \.offset) { _, receipt in
                        Text("\(receipt.tool) · \(receipt.outcome)").font(.caption)
                    }
                }
                if let error = viewModel.resultSelectionError { Text(error).foregroundStyle(.red) }
            }.padding(28).frame(maxWidth: 880, alignment: .leading).frame(maxWidth: .infinity)
        }
        .id(job.id)
        .accessibilityIdentifier("workspaceTaskPane")
    }
}
#endif
