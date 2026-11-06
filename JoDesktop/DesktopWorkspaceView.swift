#if targetEnvironment(macCatalyst)
import FactoryKit
import SwiftUI
import UIKit

struct DesktopWorkspaceView<Interactor: ViewWithModelLifecycleObserver<DesktopWorkspaceModel> & DesktopWorkspaceHandler>: View {
    @StateObject var viewModel: DesktopWorkspaceModel
    @StateObject var interactor: Interactor
    @ObservedObject private var localSpeech = Container.shared.localSpeech()
    @ObservedObject private var commands = Container.shared.customCommands()
    @AppStorage(WorkSessionMode.storageKey) private var narrationMode = WorkSessionMode.away

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                if !viewModel.focusMode {
                    DesktopFeedSidebar(viewModel: viewModel, select: interactor.selectFeedItem, refresh: interactor.refreshFeed).frame(width: 280)
                    Divider()
                }
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        Group {
                            if let job = viewModel.selectedJob {
                                DesktopTaskPane(viewModel: viewModel, interactor: interactor, job: job)
                            } else {
                                DesktopReaderPane(viewModel: viewModel, retryEmailReader: interactor.retryEmailReader)
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("workspaceReaderPane")
                        if viewModel.selectedJob == nil, case .email = viewModel.displayedFocus {
                            Divider()
                            feedActions.padding(.horizontal, 28).padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Divider()
                        DesktopConversationView(userWords: viewModel.userWords, response: viewModel.response,
                                                previousResponse: viewModel.previousResponse, state: viewModel.state,
                                                inSession: viewModel.inSession, stopSpeaking: interactor.stopSpeaking)
                            .frame(height: viewModel.inSession ? min(210, max(140, geometry.size.height * 0.24)) : 44)
                    }
                }
                if !viewModel.focusMode && viewModel.showingActivity {
                    Divider()
                    DesktopActivityView(viewModel: viewModel).frame(width: 284)
                }
            }
            Divider()
            voiceBar
        }
        .background(DesktopWorkspaceStyle.canvas)
        .background(DesktopRenderProbe(state: viewModel.renderedState, applied: interactor.rendered)
            .allowsHitTesting(false).accessibilityHidden(true))
        .tint(DesktopWorkspaceStyle.accent)
        .bind(observer: interactor, viewModel: viewModel)
        .fileExporter(isPresented: $viewModel.exportingDiagnostics,
                      document: viewModel.diagnosticsDocument, contentType: .plainText,
                      defaultFilename: "Jo-session-logs.jsonl") { result in
            if case .failure(let error) = result { viewModel.diagnosticsError = error.localizedDescription }
        }
        .alert("Couldn't export session logs", isPresented: Binding(
            get: { viewModel.diagnosticsError != nil },
            set: { if !$0 { viewModel.diagnosticsError = nil } })) {
            Button("OK") { viewModel.diagnosticsError = nil }
        } message: { Text(viewModel.diagnosticsError ?? "") }
        .sheet(isPresented: $viewModel.showingFeedback) { feedbackSheet }
        .sheet(isPresented: $viewModel.showingCommands) {
            NavigationStack {
                CustomCommandsComponent.make()
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { viewModel.showingCommands = false }
                    } }
            }.frame(width: 680, height: 600)
        }
        .onChange(of: viewModel.feedActionContext) { _, _ in viewModel.feedActionError = nil }
        .onChange(of: narrationMode) { _, mode in interactor.setNarrationMode(mode) }
        .sheet(isPresented: $viewModel.showingHistory) {
            NavigationStack { HistoryViewComponent.make(onClose: { viewModel.showingHistory = false }) }
                .frame(minWidth: 680, minHeight: 600)
        }
        .onChange(of: viewModel.selectedJob?.id) { _, id in
            viewModel.resultSelectionError = nil
            viewModel.taskCorrection = ""
            interactor.selectTask(id)
        }
        .alert("No microphone available", isPresented: $viewModel.showMicUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Connect a microphone or headset, then start a session. You can keep using the workspace meanwhile.")
        }
        .alert("Allow microphone access", isPresented: $viewModel.showMicDenied) {
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow Jo Desktop to use your microphone in System Settings, then start a session.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("JoWordmark").resizable().scaledToFit()
                .foregroundStyle(DesktopWorkspaceStyle.brand)
                .frame(width: 36, height: 32).padding(.trailing, 10)
                .accessibilityLabel("Jo").accessibilityIdentifier("desktopBrand")
            DesktopToolbarButton(title: viewModel.focusMode ? "Show feed" : "Hide feed", symbol: "sidebar.left",
                                 active: !viewModel.focusMode) { viewModel.focusMode.toggle() }
            Text("Workspace").font(.system(size: 14, weight: .medium))
            if viewModel.pendingBrowserJobs.count == 1, let job = viewModel.pendingBrowserJobs.first {
                Button("View form", systemImage: "globe") { viewModel.applyTaskSelection(job) }
                    .buttonStyle(.bordered).accessibilityIdentifier("viewPendingBrowser")
            } else if !viewModel.pendingBrowserJobs.isEmpty {
                Menu("Forms to review", systemImage: "globe") {
                    ForEach(viewModel.pendingBrowserJobs) { job in
                        Button(job.task) { viewModel.applyTaskSelection(job) }
                    }
                }.accessibilityIdentifier("viewPendingBrowsers")
            }
            Spacer()
            if let receipt = viewModel.feedbackReceipt {
                Label(receipt, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("feedbackSaved")
            }
            if let started = viewModel.startedAt {
                Text(started, style: .timer).monospacedDigit().foregroundStyle(.secondary).font(.caption)
                Text("In session").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Divider().frame(height: 18).padding(.horizontal, 5)
            Button { viewModel.showingCommands = true } label: { Label("Commands", systemImage: "command") }
                .buttonStyle(.borderless).foregroundStyle(.primary)
                .accessibilityIdentifier("desktopCommands").help("View actions and edit saved commands")
            if !viewModel.focusMode {
                DesktopToolbarButton(title: "Background activity", symbol: "sidebar.right", active: viewModel.showingActivity) {
                    viewModel.showingActivity.toggle()
                }.accessibilityIdentifier("toggleDesktopActivity")
            }
            DesktopToolbarButton(title: "Leave feedback", symbol: "bubble.left.and.text.bubble.right", action: interactor.showFeedback)
                .accessibilityIdentifier("desktopFeedback")
            DesktopToolbarButton(title: "Settings and connections", symbol: "gearshape", active: viewModel.showingSettings) {
                viewModel.showingSettings = true
            }
                .popover(isPresented: $viewModel.showingSettings, arrowEdge: .trailing) {
                    NavigationStack { ProfileViewComponent.make(onClose: { viewModel.showingSettings = false }) }
                        .frame(width: 680, height: 610)
                        .presentationCompactAdaptation(.popover)
                }
            Menu {
                Button("Export session logs", systemImage: "doc.text.magnifyingglass", action: interactor.exportDiagnostics)
                Button("Export logs with conversation text", systemImage: "text.bubble", action: interactor.exportHistory)
                Divider()
                Button("Test speaker", systemImage: "speaker.wave.2") { localSpeech.preview(.current) }
                    .disabled(viewModel.inSession || localSpeech.isPreviewing)
                    .accessibilityIdentifier("desktopTestSpeaker")
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 32).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
                .accessibilityLabel("Workspace options").help("Export logs or test the speaker")
        }.padding(.horizontal, 20).frame(height: 54)
    }

    private var feedbackSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Feedback").font(.title2.weight(.semibold))
            Text("What should Jo do better?").foregroundStyle(.secondary)
            TextEditor(text: $viewModel.feedbackText)
                .font(.body).frame(minHeight: 150)
                .padding(8).background(DesktopWorkspaceStyle.inset, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Your feedback").accessibilityIdentifier("feedbackMessage")
                .disabled(viewModel.savingFeedback)
            HStack {
                Text("Saved on this Mac. Included when you export session logs.")
                Spacer()
                Text("\(viewModel.feedbackText.count)/\(FeedbackText.maximumCharacters)")
                    .foregroundStyle(viewModel.feedbackText.count > FeedbackText.maximumCharacters ? Color.red : .secondary)
            }.font(.caption).foregroundStyle(.secondary)
            if let error = viewModel.feedbackError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .accessibilityIdentifier("feedbackError")
            }
            HStack {
                Button("Cancel") { viewModel.showingFeedback = false }
                    .keyboardShortcut(.cancelAction).disabled(viewModel.savingFeedback)
                Spacer()
                Button(viewModel.savingFeedback ? "Saving…" : "Save feedback", action: interactor.saveFeedback)
                    .buttonStyle(.borderedProminent).disabled(!viewModel.canSaveFeedback)
                    .keyboardShortcut(.return, modifiers: .command).accessibilityIdentifier("saveFeedback")
            }
        }
        .padding(28).frame(minWidth: 560, minHeight: 390)
        .interactiveDismissDisabled(viewModel.savingFeedback)
    }

    @ViewBuilder
    private var feedActions: some View {
        let context = viewModel.feedActionContext
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    frequentFeedActions(context)
                    additionalFeedActions(context)
                }
                VStack(alignment: .leading, spacing: 10) {
                    frequentFeedActions(context)
                    additionalFeedActions(context)
                }
            }
            .disabled(context == nil)
            HStack {
                TextField("Ask Jo to work on this email…", text: $viewModel.taskText)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("desktopTaskRequest")
                    .onSubmit { submitTask(context) }
                Button("Run in background") { submitTask(context) }
                    .disabled(context == nil || viewModel.taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.submittingTask)
                    .accessibilityIdentifier("desktopRunTask")
            }
            if let error = viewModel.feedActionError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            } else if context != nil, viewModel.requestedActionContext == context {
                Text("Action requested · follow its result in Live Activity").font(.caption).foregroundStyle(.secondary)
            }
            if let origin = context.flatMap(viewModel.taskOrigin) {
                Text(origin.account).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let receipt = viewModel.taskReceipt { Text(receipt).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func frequentFeedActions(_ context: FeedActionContext?) -> some View {
        HStack(spacing: 12) {
            ForEach([LiveFastAction.archive, .next, .spam], id: \.rawValue) { action in
                Button(role: action == .spam ? .destructive : nil) {
                    if let context { interactor.performFeedAction(action, context: context) }
                } label: {
                    Label(action == .spam ? "Mark as spam" : action.title, systemImage: action.symbol)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.bordered).help(action.explanation).fixedSize()
                .padding(.leading, action == .spam ? 8 : 0)
                .accessibilityIdentifier("feedAction-\(action.rawValue)")
            }
        }
    }

    private func additionalFeedActions(_ context: FeedActionContext?) -> some View {
        HStack(spacing: 16) {
            Menu("More", systemImage: "ellipsis") {
                Button(role: .destructive) {
                    if let context { interactor.performFeedAction(.trash, context: context) }
                } label: { Label(LiveFastAction.trash.title, systemImage: LiveFastAction.trash.symbol) }
            }.menuStyle(.borderlessButton).fixedSize()
            Menu("Run command", systemImage: "command") {
                ForEach(commands.commands.filter(\.enabled)) { command in
                    Button(command.title) {
                        if let context { interactor.submitTask(command.title, commandID: command.id, context: context) }
                    }
                }
            }.menuStyle(.borderlessButton).fixedSize()
        }
    }

    private func submitTask(_ context: FeedActionContext?) {
        guard let context else { return }
        interactor.submitTask(viewModel.taskText, commandID: nil, context: context)
    }

    private var voiceBar: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().fill(DesktopWorkspaceStyle.accent.opacity(0.09)).frame(width: 34, height: 34)
                Image(systemName: viewModel.inSession && !viewModel.muted && viewModel.micLive ? "waveform" : "mic.slash")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(DesktopWorkspaceStyle.accent)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Circle().fill(viewModel.inSession && viewModel.micLive && !viewModel.muted ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(viewModel.status).font(.system(size: 14, weight: .medium))
                }
                Text(viewModel.inSession ? "Say “next”, ask a question, or talk Jo through the task." : (localSpeech.previewMessage ?? "Your microphone turns on when you start a session."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let notice = viewModel.voiceNotice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if viewModel.inSession {
                Picker("Narration", selection: $narrationMode) {
                    ForEach(WorkSessionMode.allCases) { mode in Text(mode.label).tag(mode) }
                }.pickerStyle(.segmented).frame(width: 215)
                    .accessibilityIdentifier("workSessionMode")
                    .help("At computer: answer requests without reading each email automatically. Away: narrate the feed.")
                Button(action: interactor.toggleMute) {
                    Label(viewModel.muted ? "Unmute" : "Mute", systemImage: viewModel.muted ? "mic.slash" : "mic")
                }.buttonStyle(.bordered)
                Button("End session", action: interactor.toggleSession).buttonStyle(.bordered)
            } else {
                Button(action: interactor.quickAction) { Label("Quick action", systemImage: "bolt") }
                    .buttonStyle(.bordered).accessibilityIdentifier("desktopQuickAction")
                    .help("Ask Jo for one thing without starting the feed")
                Button(action: interactor.toggleSession) {
                    Label(viewModel.selectedJob == nil ? "Start session" : "Discuss activity", systemImage: "play.fill")
                }
                    .buttonStyle(.borderedProminent)
                    .help("Begin working through your feed.")
                    .accessibilityIdentifier("desktopStartFeedBar")
            }
        }.padding(.horizontal, 22).frame(height: 68).background(DesktopWorkspaceStyle.inset.opacity(0.3))
    }


}

@MainActor
struct DesktopWorkspaceComponent {
    static func make() -> some View {
        DesktopWorkspaceView(viewModel: DesktopWorkspaceModel(), interactor: DesktopWorkspaceInteractor())
    }
}
#endif
