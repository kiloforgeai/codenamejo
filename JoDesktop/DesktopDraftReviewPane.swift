#if targetEnvironment(macCatalyst)
import FactoryKit
import SwiftUI

struct DesktopDraftReviewPane: View {
    let job: DispatchJob
    let review: MailDraftReview
    @ObservedObject var model: DesktopWorkspaceModel
    @State private var subject: String
    @State private var bodyText: String
    @State private var handled = false

    init(job: DispatchJob, review: MailDraftReview, model: DesktopWorkspaceModel) {
        self.job = job; self.review = review; self.model = model
        _subject = State(initialValue: review.message.subject)
        _bodyText = State(initialValue: review.message.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Draft preview", systemImage: "square.and.pencil").font(.headline)
                Text("Only in Jo").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Back to feed", systemImage: "arrow.uturn.backward") { perform(.keep) }
                    .buttonStyle(.borderless).accessibilityIdentifier("backToFeed")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let action = job.mailAction {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("From: \(action.account)")
                            Text("To: \(action.to)")
                            if !action.cc.isEmpty { Text("Cc: " + action.cc.joined(separator: ", ")) }
                            if !action.bcc.isEmpty { Text("Bcc: " + action.bcc.joined(separator: ", ")) }
                        }.font(.callout).textSelection(.enabled)
                    }
                    Divider()
                    TextField("Subject", text: $subject).font(.title3).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Draft subject").accessibilityIdentifier("draftPreviewSubject")
                    TextEditor(text: $bodyText).font(.system(size: 15)).lineSpacing(5)
                        .frame(minHeight: 280).scrollContentBackground(.hidden)
                        .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Draft message").accessibilityIdentifier("draftPreviewBody")
                    ForEach(Array((review.message.attachments ?? []).enumerated()), id: \.offset) { _, file in
                        Label("\(file.filename) · \(AttachmentText.describeSize(file.bytes.count))", systemImage: "paperclip")
                            .font(.callout)
                    }
                    ForEach(Array((job.mailAction?.omittedAttachments ?? []).enumerated()), id: \.offset) { _, file in
                        Text("Not included: \(file.filename) · \(file.reason)").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Review here first. Save to Gmail creates a draft; it does not send it.")
                    .font(.callout).foregroundStyle(.secondary)
                if review.archiveAfterSave {
                    Text("Your filing rule will archive the source thread after Gmail confirms the draft.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.resultSelectionError { Text(error).font(.callout).foregroundStyle(.red) }
                HStack(spacing: 12) {
                    Button("Save to Gmail") { perform(.save) }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("saveReviewedDraft")
                    Button("Keep in Jo") { perform(.keep) }.buttonStyle(.bordered)
                        .accessibilityIdentifier("keepReviewedDraft")
                    Spacer()
                    Button("Discard", role: .destructive) { perform(.discard) }.buttonStyle(.borderless)
                        .accessibilityIdentifier("discardReviewedDraft")
                    if model.updatingTask { ProgressView().controlSize(.small) }
                }
            }
        }.padding(28).frame(maxWidth: 880, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity)
            .disabled(model.updatingTask)
            .onDisappear {
                guard !handled, !model.updatingTask,
                      subject != review.message.subject || bodyText != review.message.body else { return }
                Task {
                    do {
                        _ = try await Container.shared.dispatchJobs().editDraftReview(job.id,
                            revision: review.revision, subject: subject, body: bodyText)
                    } catch { model.resultSelectionError = GmailManageTools.detail(error) }
                }
            }
    }

    private enum Action { case save, keep, discard }
    private func perform(_ action: Action) {
        guard !model.updatingTask else { return }
        model.updatingTask = true; model.resultSelectionError = nil
        Task { @MainActor in
            defer { model.updatingTask = false }
            do {
                let store = Container.shared.dispatchJobs()
                switch action {
                case .save:
                    _ = try await LocalDraftReview.save(job.id, revision: review.revision, subject: subject, body: bodyText)
                case .keep:
                    _ = try await store.editDraftReview(job.id, revision: review.revision, subject: subject, body: bodyText)
                case .discard:
                    try await store.discardDraftReview(job.id, revision: review.revision)
                }
                handled = true
                model.applyJobs(await store.history())
                if action == .keep { model.selectedJob = nil }
            } catch {
                model.resultSelectionError = GmailManageTools.detail(error)
                model.applyJobs(await Container.shared.dispatchJobs().history())
            }
        }
    }
}
#endif
