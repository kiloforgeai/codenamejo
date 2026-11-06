#if targetEnvironment(macCatalyst)
import FactoryKit
import SwiftUI
import UIKit

private enum Desk {
    static let accent = Color(red: 0.75, green: 0.43, blue: 0.28)
    static let canvas = Color(uiColor: .systemBackground)
    static let inset = Color(uiColor: .secondarySystemBackground)
    static let line = Color.primary.opacity(0.09)
}

struct DesktopWorkspaceView<Interactor: ViewWithModelLifecycleObserver<DesktopWorkspaceModel> & DesktopWorkspaceHandler>: View {
    @StateObject var viewModel: DesktopWorkspaceModel
    @StateObject var interactor: Interactor
    @ObservedObject private var localSpeech = Container.shared.localSpeech()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                if !viewModel.focusMode {
                    sidebar.frame(width: 260)
                    Divider()
                }
                workspace.frame(maxWidth: .infinity, maxHeight: .infinity)
                if !viewModel.focusMode {
                    Divider()
                    activity.frame(width: 284)
                }
            }
            Divider()
            voiceBar
        }
        .background(Desk.canvas)
        .background(DesktopRenderProbe(state: viewModel.renderedState, applied: interactor.rendered)
            .allowsHitTesting(false).accessibilityHidden(true))
        .tint(Desk.accent)
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
            }.frame(minWidth: 700, idealWidth: 760, minHeight: 660)
        }
        .onChange(of: viewModel.feedActionContext) { _, _ in viewModel.feedActionError = nil }
        .sheet(isPresented: $viewModel.showingSettings) {
            NavigationStack { ProfileViewComponent.make(onClose: { viewModel.showingSettings = false }) }
                .frame(minWidth: 760, idealWidth: 840, minHeight: 700, idealHeight: 820)
        }
        .sheet(isPresented: $viewModel.showingHistory) {
            NavigationStack { HistoryViewComponent.make(onClose: { viewModel.showingHistory = false }) }
                .frame(minWidth: 680, minHeight: 600)
        }
        .onChange(of: viewModel.selectedJob?.id) { _, _ in viewModel.resultSelectionError = nil }
        .sheet(item: $viewModel.selectedJob) { job in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(job.task).font(.title2.weight(.medium))
                        Label(jobStatus(job), systemImage: job.didFail ? "exclamationmark.triangle" : "bolt.horizontal.circle")
                            .foregroundStyle(.secondary)
                        if let origin = job.origin {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Source email").font(.caption).foregroundStyle(.secondary)
                                Text(origin.subject).font(.headline)
                                Text(origin.sender).textSelection(.enabled)
                                Text(origin.account).font(.caption).foregroundStyle(.secondary)
                                if job.hasStopped() {
                                    Button("Work on this email") { interactor.selectReturnedResult(job.id) }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(!viewModel.inSession || viewModel.selectingResult)
                                        .accessibilityIdentifier("workOnReturnedEmail")
                                    Text(viewModel.inSession
                                        ? "Your place in the feed is kept while you work on this result."
                                        : "Start a session, then select this email to continue its work.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        } else if job.hasStopped() {
                            Text("This result has no saved source email. Select the intended email before acting.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = viewModel.resultSelectionError { Text(error).foregroundStyle(.red) }
                        Text(job.result ?? (job.hasStopped()
                            ? "This job stopped reporting. Its outcome is unknown. Ask Jo to check before trying it again."
                            : "This job is still running. Its result will appear here."))
                            .font(.body).textSelection(.enabled)
                    }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { viewModel.selectedJob = nil } } }
            }.frame(minWidth: 600, minHeight: 440)
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
        HStack(spacing: 13) {
            Text("jo").font(.system(size: 32, weight: .semibold, design: .serif)).foregroundStyle(Desk.accent)
            Rectangle().fill(Desk.line).frame(width: 1, height: 22).padding(.horizontal, 6)
            Text("Your workspace").font(.system(size: 14, weight: .medium))
            Spacer()
            if let receipt = viewModel.feedbackReceipt {
                Label(receipt, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("feedbackSaved")
            }
            if let started = viewModel.startedAt {
                Text(started, style: .timer).monospacedDigit().foregroundStyle(.secondary).font(.caption)
                Text("IN SESSION").font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary)
            }
            Button { viewModel.focusMode.toggle() } label: {
                Label(viewModel.focusMode ? "Show workspace" : "Focus mode",
                      systemImage: viewModel.focusMode ? "sidebar.squares.left" : "rectangle.center.inset.filled")
            }.buttonStyle(.borderless).padding(.leading, 16)
            Button { viewModel.showingSettings = true } label: { Image(systemName: "gearshape").padding(8) }
                .buttonStyle(.plain).accessibilityLabel("Settings and connections")
            Button { viewModel.showingCommands = true } label: { Label("Commands", systemImage: "command") }
                .buttonStyle(.borderless).accessibilityIdentifier("desktopCommands")
            Button(action: interactor.showFeedback) { Label("Feedback", systemImage: "bubble.left.and.text.bubble.right") }
                .buttonStyle(.borderless).accessibilityIdentifier("desktopFeedback")
                .help("Leave feedback about Jo")
            Button(action: interactor.exportDiagnostics) { Image(systemName: "doc.text.magnifyingglass").padding(8) }
                .buttonStyle(.plain).accessibilityLabel("Export session logs")
                .contextMenu {
                    Button("Export logs only", action: interactor.exportDiagnostics)
                    Button("Export with conversation text — review before sharing", action: interactor.exportHistory)
                }
        }.padding(.horizontal, 24).frame(height: 64)
    }

    private var feedbackSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Feedback").font(.title2.weight(.semibold))
            Text("What should Jo do better?").foregroundStyle(.secondary)
            TextEditor(text: $viewModel.feedbackText)
                .font(.body).frame(minHeight: 150)
                .padding(8).background(Desk.inset, in: RoundedRectangle(cornerRadius: 8))
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
        .padding(24).frame(width: 560, height: 360)
        .interactiveDismissDisabled(viewModel.savingFeedback)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("WORK FEED").font(.system(size: 11, weight: .semibold)).tracking(1.8)
                Spacer()
                if !viewModel.inSession && viewModel.previewRefreshing {
                    ProgressView().controlSize(.mini).accessibilityLabel("Refreshing work feed")
                }
                Text(viewModel.feedCountLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityIdentifier("desktopFeedCount")
                    .help(viewModel.inSession ? "Items prepared for this session" : "Approximate inbox messages and unread Slack conversations. The preview shows a limited selection.")
            }.padding(.horizontal, 22).padding(.top, 25).padding(.bottom, 18)
            Picker("Filter prepared work", selection: $viewModel.filter) {
                Text("All").tag("All")
                Text("Email").tag("Email")
                Text("Slack").tag("Slack")
                Text("Calendar").tag("Calendar")
            }.pickerStyle(.menu).padding(.horizontal, 18).padding(.bottom, 18)
            if !viewModel.inSession {
                Text(viewModel.feedPreview?.incomplete == true
                     ? "Some sources couldn’t refresh. Showing available work; counts may be incomplete."
                     : "Inbox preview · refreshes every 2 min")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 22).padding(.bottom, 14)
                    .accessibilityIdentifier("desktopFeedPreviewStatus")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if viewModel.filteredQueue.isEmpty {
                        feedEmptyState
                    }
                    ForEach(Array(viewModel.filteredQueue.enumerated()), id: \.element.id) { index, row in
                        if let section = row.section,
                           index == 0 || viewModel.filteredQueue[index - 1].section?.id != section.id {
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
                        VStack(alignment: .leading, spacing: 8) {
                            Label(row.source, systemImage: row.symbol)
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Desk.accent)
                            if let selected = viewModel.presentedSelection, row.selection == selected {
                                Text("CURRENT").font(.caption2.weight(.semibold)).foregroundStyle(Desk.accent)
                            }
                            Text(row.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
                            Text(row.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            if let reason = row.reason {
                                Text(reason).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Desk.canvas, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Desk.line, lineWidth: 1))
                            .accessibilityIdentifier("feedRow_\(row.id)")
                    }
                }.padding(.horizontal, 14)
            }
            Divider().padding(.top, 12)
            Button { viewModel.showingHistory = true } label: {
                Label("Session history", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(22)
            }.buttonStyle(.plain)
        }.background(Desk.inset.opacity(0.6))
    }

    private var feedEmptyState: some View {
        let done = viewModel.feedComplete
        let unavailable = viewModel.inSession ? viewModel.sessionFeed.status == .unavailable : viewModel.feedPreview?.incomplete == true
        let filtered = !viewModel.feedRows.isEmpty
        let loading = viewModel.inSession || viewModel.feedPreview == nil
        return VStack(alignment: .leading, spacing: 14) {
            Image(systemName: done ? "checkmark.seal.fill" : unavailable ? "exclamationmark.triangle" : "tray")
                .font(.system(size: done ? 42 : 26)).foregroundStyle(done ? Desk.accent : Color.secondary)
            Text(done ? "You’re done." : unavailable ? "Couldn’t refresh the feed" : filtered ? "No \(viewModel.filter.lowercased()) here" : loading ? "Checking your work" : "Nothing waiting.")
                .font(.system(size: done ? 26 : 16, weight: .medium, design: done ? .serif : .default))
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

    private var workspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Label(viewModel.inSession ? "IN FOCUS" : "LET’S GET TO IT", systemImage: "viewfinder")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.7).foregroundStyle(Desk.accent)
                    Spacer()
                    if !viewModel.selectionIsTransitioning, case .email(let email) = viewModel.focus,
                       let position = email.displayedPosition {
                        Text("\(position)\(email.displayedTotal.map { " / \($0)" } ?? "")")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                if viewModel.selectionIsTransitioning {
                    ProgressView("Updating the selected email…")
                        .padding(.vertical, 32).accessibilityIdentifier("feedSelectionTransition")
                } else if let focus = viewModel.focus {
                    if case .email(let email) = focus, email.isBackgroundResult {
                        Label("Background result · your place in the feed is saved", systemImage: "arrow.uturn.backward")
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("feedBackgroundResult")
                    }
                    focusContent(focus)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(viewModel.inSession ? "One thing at a time." : "Less clicking.\nMore getting it done.")
                            .font(.system(size: 42, weight: .regular, design: .serif)).tracking(-1.1)
                        Text(viewModel.inSession
                            ? (viewModel.sessionIntent == .feed
                                ? "Jo is getting your next feed item ready. Its details will appear here."
                                : "Tell Jo what you need done. Your request and its context will appear here.")
                            : "Start a session to go straight into your feed. Jo brings you the next task, and you talk it through together.")
                            .font(.system(size: 16)).foregroundStyle(.secondary).lineSpacing(6).frame(maxWidth: 460, alignment: .leading)
                    }.padding(.vertical, 20)
                    if !viewModel.inSession {
                        HStack(spacing: 12) {
                            Button(action: interactor.toggleSession) {
                                Label("Start a work session", systemImage: "waveform")
                                    .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 16).padding(.vertical, 9)
                            }.buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("desktopStartFeed")
                            Button(action: interactor.quickAction) {
                                Label("Quick action", systemImage: "bolt")
                                    .font(.system(size: 14, weight: .medium)).padding(.vertical, 9)
                            }.buttonStyle(.bordered)
                                .help("Ask Jo for one thing without starting the feed.")
                                .accessibilityIdentifier("desktopQuickAction")
                        }
                        HStack(spacing: 22) {
                            Label("Email", systemImage: "envelope")
                            Label("Slack", systemImage: "number")
                            Label("Background work", systemImage: "bolt.horizontal.circle")
                        }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 12)
                    }
                }
                if viewModel.inSession, case .email = viewModel.focus { feedActions }
                if !viewModel.userWords.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        caption("YOU")
                        Text(viewModel.userWords).font(.system(size: 14)).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(.top, 8)
                }
                if !viewModel.response.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            caption(viewModel.previousResponse ? "JO · PREVIOUS RESPONSE" : "JO")
                            Spacer()
                            if viewModel.state == .responding {
                                Button("Stop speaking", action: interactor.stopSpeaking).font(.caption).buttonStyle(.borderless)
                            }
                        }
                        Text(viewModel.response).font(.system(size: 17)).lineSpacing(7).textSelection(.enabled)
                            .foregroundStyle(viewModel.previousResponse ? .secondary : .primary)
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Desk.inset.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
                }
                if case .error(let message) = viewModel.state {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).font(.callout).textSelection(.enabled)
                }
                Spacer(minLength: 25)
            }.padding(36).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var feedActions: some View {
        let context = viewModel.feedActionContext
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ForEach([LiveFastAction.archive, .next], id: \.rawValue) { action in
                    Button {
                        if let context { interactor.performFeedAction(action, context: context) }
                    } label: { Label(action.title, systemImage: action.symbol).padding(.vertical, 5) }
                        .buttonStyle(.bordered).help(action.explanation)
                        .accessibilityIdentifier("feedAction-\(action.rawValue)")
                }
                Menu("More", systemImage: "ellipsis") {
                    ForEach([LiveFastAction.trash, .spam], id: \.rawValue) { action in
                        Button(role: .destructive) {
                            if let context { interactor.performFeedAction(action, context: context) }
                        } label: { Label(action.title, systemImage: action.symbol) }
                    }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            .disabled(context == nil || viewModel.state == .processing)
            if let error = viewModel.feedActionError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            } else if context != nil, viewModel.requestedActionContext == context {
                Text("Action requested · follow its result in Live Activity").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func focusContent(_ focus: FeedFocus) -> some View {
        switch focus {
        case .email(let email):
            let preview = EmailPreview(snippet: email.snippet)
            VStack(alignment: .leading, spacing: 18) {
                Label("EMAIL · \(email.account)", systemImage: "envelope")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(email.subject.isEmpty ? "No subject" : email.subject)
                    .font(.system(size: 32, weight: .regular, design: .serif)).textSelection(.enabled)
                HStack {
                    Text(email.sender).font(.system(size: 14, weight: .medium))
                    Spacer()
                    if let received = email.received { Text(received, style: .date).font(.caption).foregroundStyle(.secondary) }
                }
                Divider()
                HStack {
                    Text("EMAIL PREVIEW").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if let url = EmailPreview.gmailURL(account: email.account, messageID: email.messageId) {
                        Link(destination: url) { Label("Open in Gmail", systemImage: "arrow.up.right") }
                            .font(.callout).accessibilityIdentifier("openFocusedEmail")
                    }
                }
                Text(preview.text.isEmpty ? "No preview available." : preview.text)
                    .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(6).textSelection(.enabled)
                    .accessibilityIdentifier("focusedEmailPreview")
                if !preview.quoted.isEmpty {
                    DisclosureGroup("Quoted conversation") {
                        Text(preview.quoted).font(.body).foregroundStyle(.secondary)
                            .lineSpacing(5).textSelection(.enabled).padding(.top, 8)
                    }
                }
                Text("This preview may be shortened or include earlier replies. Open the email for the complete message.")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
            .accessibilityIdentifier("focusedEmail")
        case .slack(let slack):
            VStack(alignment: .leading, spacing: 18) {
                Label(slack.workspace, systemImage: "number").font(.caption).foregroundStyle(.secondary)
                Text(slack.name).font(.system(size: 32, weight: .regular, design: .serif))
                ForEach(Array(slack.messages.enumerated()), id: \.offset) { _, message in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message.from).font(.system(size: 13, weight: .semibold))
                        Text(message.text).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                    }.padding(.vertical, 4)
                }
            }
        case .calendar(let calendar):
            Text("The rest of your day.").font(.system(size: 34, design: .serif))
            switch calendar {
            case .agenda(let events, let partial):
                ForEach(events, id: \.id) { event in
                    HStack(alignment: .top, spacing: 20) {
                        Group {
                            if let start = event.start, !event.allDay { Text(start, style: .time) }
                            else { Text("All day") }
                        }.font(.system(size: 12, design: .monospaced)).frame(width: 75, alignment: .leading)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.title).font(.system(size: 16, weight: .medium))
                            if let location = event.location, !location.isEmpty { Text(location).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(.vertical, 8)
                }
                if partial { Text("Some calendars could not be loaded.").font(.caption).foregroundStyle(.orange) }
            case .loading: ProgressView("Reading your calendar…")
            case .empty(let partial): Text(partial ? "No events in the calendars available. Some calendars could not be loaded." : "Your calendar is clear for the rest of today.").foregroundStyle(.secondary)
            case .unavailable: Label("Your calendar could not be loaded.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        case .tip(let tip):
            Text("A note from Jo.").font(.system(size: 34, design: .serif))
            Text(tip.copy).font(.title3).lineSpacing(6)
        case .about(let facts):
            Text("Getting to know your work.").font(.system(size: 34, design: .serif))
            ForEach(facts, id: \.self) { Text($0).font(.body) }
        case .emailStatus(let status):
            Text(status == .unavailable ? "Email needs attention." : "Through this part of your inbox.")
                .font(.system(size: 34, design: .serif))
            Text(status == .unavailable ? "Jo could not load the mail for this part of the feed." : "Keep talking. Jo will guide you to what’s next.").foregroundStyle(.secondary)
        case .slackStatus(let status):
            Text(status == .stopped ? "Slack is paused." : "Through your Slack conversations.")
                .font(.system(size: 34, design: .serif))
        case .complete:
            Text("A little more headspace.").font(.system(size: 38, design: .serif))
            Text("This pass through your feed is finished. Jo is here for whatever you want to tackle next.")
                .foregroundStyle(.secondary).lineSpacing(6)
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 0) {
            caption("LIVE ACTIVITY").padding(22)
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
                    caption("BACKGROUND WORK")
                    if viewModel.jobs.isEmpty {
                        Text("Hand Jo a longer task and keep going. Its progress and result will appear here.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                    }
                    ForEach(Array((viewModel.runningJobs + viewModel.finishedJobs).prefix(12))) { job in
                        Button { viewModel.selectedJob = job } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(jobStatus(job), systemImage: jobSymbol(job))
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(job.didFail ? Color.orange : Desk.accent)
                                Text(job.task).font(.system(size: 13, weight: .medium)).lineLimit(3)
                                if let result = job.result { Text(result).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3) }
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Desk.inset.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 22).padding(.bottom, 22)
            }
            Spacer(minLength: 0)
        }
    }

    private var voiceBar: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().fill(Desk.accent.opacity(0.12)).frame(width: 46, height: 46)
                Image(systemName: viewModel.inSession && !viewModel.muted && viewModel.micLive ? "waveform" : "mic.slash")
                    .font(.system(size: 20, weight: .medium)).foregroundStyle(Desk.accent)
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
                Button(action: interactor.toggleMute) {
                    Label(viewModel.muted ? "Unmute" : "Mute", systemImage: viewModel.muted ? "mic.slash" : "mic")
                }.buttonStyle(.bordered)
                Button("End session", action: interactor.toggleSession).buttonStyle(.bordered)
            } else {
                Button {
                    localSpeech.preview(.current)
                } label: {
                    Label(localSpeech.isPreviewing ? "Playing…" : "Test speaker", systemImage: "speaker.wave.2")
                }
                .buttonStyle(.bordered)
                .disabled(localSpeech.isPreviewing)
                .accessibilityIdentifier("desktopTestSpeaker")
                Button(action: interactor.toggleSession) { Label("Start session", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .help("Begin working through your feed.")
                    .accessibilityIdentifier("desktopStartFeedBar")
            }
        }.padding(.horizontal, 26).frame(height: 88).background(Desk.inset.opacity(0.3))
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
    }
    private func jobStatus(_ job: DispatchJob) -> String {
        if job.didFail { return "Needs attention" }
        if job.isDone { return "Result ready" }
        return job.hasStopped() ? "Outcome unknown" : "Working in background"
    }
    private func jobSymbol(_ job: DispatchJob) -> String {
        if job.didFail || (job.isRunning && job.hasStopped()) { return "exclamationmark.triangle" }
        return job.isDone ? "checkmark.circle" : "arrow.trianglehead.2.clockwise.rotate.90"
    }
}

@MainActor
struct DesktopWorkspaceComponent {
    static func make() -> some View {
        DesktopWorkspaceView(viewModel: DesktopWorkspaceModel(), interactor: DesktopWorkspaceInteractor())
    }
}
#endif
