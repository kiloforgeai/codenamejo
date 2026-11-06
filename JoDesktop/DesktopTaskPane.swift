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
                Text(job.mailAction?.subject ?? job.task).font(.title2.weight(.medium))
                Label(job.desktopStatusLabel, systemImage: job.didFail ? "exclamationmark.triangle" : "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
                Text(job.result ?? (job.hasStopped()
                    ? "This job stopped reporting. Its outcome is unknown. Ask Jo to check before trying it again."
                    : "This job is still running. Its result will appear here."))
                    .font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                Divider()
                if let browser = viewModel.browserTasks[job.id] {
                    DesktopBrowserTaskPanel(browser: browser, canResume: !job.isRunning && !viewModel.updatingTask) { action in
                        interactor.controlBrowser(action, job: job, model: viewModel)
                    }
                }
                if let action = job.mailAction {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(action.confirmed ? "Gmail-confirmed message" : "Requested message").font(.headline)
                        Text("From: \(action.account)")
                        Text("To: \(action.to)")
                        if !action.cc.isEmpty { Text("Cc: \(action.cc.joined(separator: ", "))") }
                        if !action.bcc.isEmpty { Text("Bcc: \(action.bcc.joined(separator: ", "))") }
                        if let date = job.completedAt ?? job.startedAt { Text(date, format: .dateTime).font(.caption).foregroundStyle(.secondary) }
                        Divider()
                        Text(action.body).font(.system(size: 15)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(action.attachments.enumerated()), id: \.offset) { _, file in
                            VStack(alignment: .leading, spacing: 4) {
                                Label("\(file.filename) · \(AttachmentText.describeSize(file.size))", systemImage: "paperclip")
                                Text("SHA-256: \(file.sha256)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        if let id = action.providerID { Text("Gmail confirmation: \(id)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                        if let thread = action.providerThreadID ?? action.threadID { Text("Thread: \(thread)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                        if let header = action.inReplyTo { Text("In reply to: \(header)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                        if let url = action.providerURL {
                            Link(action.kind == .send ? "Open sent message in Gmail" : "Open draft in Gmail", destination: url)
                                .accessibilityIdentifier("openMailActionInGmail")
                        }
                    }.textSelection(.enabled).padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                if let origin = job.origin {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Source email").font(.caption).foregroundStyle(.secondary)
                        Text(origin.subject).font(.headline)
                        Text(origin.sender).textSelection(.enabled)
                        Text(origin.account).font(.caption).foregroundStyle(.secondary)
                        Text("Message \(origin.messageID)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        if !origin.threadID.isEmpty {
                            Text("Thread \(origin.threadID)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
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
