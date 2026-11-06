#if targetEnvironment(macCatalyst) && JO_QA
import Combine
import FactoryKit
import Foundation
import SwiftUI
import UIKit

/// Compiled only into the isolated QA app. Its providers cannot reach any real mailbox.
@MainActor
struct DesktopFixtureComponent {
    static func make() -> some View {
        let backend = BackendService(restoringSession: false)
        backend.userId = "fixture-user"
        Container.shared.backend.register { backend }
        let context = LocalContextStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("jo-fixture-\(UUID().uuidString).sqlite"))
        Container.shared.localContext.register { context }
        Container.shared.googleGrantStorage.register { FixtureGrants() }
        Container.shared.googleTokenProvider.register { MainActor.assumeIsolated { FixtureTokens() } }
        Container.shared.providerHTTP.register { FixtureNoNetwork() }
        let jobs = DispatchJobStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("jo-fixture-jobs-" + UUID().uuidString + ".json"))
        Container.shared.dispatchJobs.register { jobs }
        let browsers = BackgroundBrowserStore()
        browsers.makeBrowser = { job, current in
            let browser = BackgroundBrowser(job: job, current: current)
            browser.allowLocalFixture = true
            return browser
        }
        Container.shared.backgroundBrowsers.register { browsers }
        let browserFixture = BackgroundBrowserFixture()
        let tasks = ApplicationTasks(request: { body in
            let request = (body["input"] as? [[String: Any]])?.first?["content"] as? String ?? ""
            if request.contains("browser fixture") || request.contains("browser form fixture") {
                return try await browserFixture.respond(body)
            }
            if request.contains("pause fixture") { try await Task.sleep(for: .seconds(15)) }
            let result = request.contains("input fixture")
                ? #"{"status":"needs_input","report":"Which of the two synthetic dates should I use? No external action was taken."}"#
                : "Synthetic task completed for the selected source. No external request was sent."
            return [["type": "message", "content": [["type": "output_text", "text": result]]]]
        })
        Container.shared.applicationTasks.register { tasks }
        let realtime = RealtimeService()
        Container.shared.realtimeService.register { realtime }
        ProfileRuntime.install(nil)
        let model = DesktopWorkspaceModel()
        let interactor = DesktopFixtureInteractor(context: context)
        return DesktopFixtureView(viewModel: model, interactor: interactor)
    }
}

struct DesktopFixtureView: View {
    @StateObject var viewModel: DesktopWorkspaceModel
    @StateObject var interactor: DesktopFixtureInteractor
    private struct BrowserPresentation: Identifiable {
        let id = UUID()
        let browser: SupervisedBrowserExperiment
    }
    @State private var browserPresentation: BrowserPresentation?
    @AppStorage(AppearanceSetting.storageKey) private var appearance = AppearanceSetting.system
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Isolated preview · synthetic data · no audio or provider writes", systemImage: "testtube.2")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag(AppearanceSetting.system)
                    Text("Light").tag(AppearanceSetting.light)
                    Text("Dark").tag(AppearanceSetting.dark)
                }.pickerStyle(.menu).fixedSize()
                Button("Snapshot") { interactor.exportEvidence() }
                Menu("Fixtures") {
                    Button("Next") { interactor.next(delayProjection: false) }
                    Button("Archive fixture") { interactor.archive() }
                    Button("Delay projection") { interactor.next(delayProjection: true) }
                    Button("Delay session startup") { interactor.delaySessionStartup() }
                    Button("Refresh continuity fixture") { interactor.refreshContinuity() }
                    Button("Apply projection") { interactor.applyProjection() }
                    Button("Section feed") { interactor.sectionFeed() }
                    Button("Finish fixture") { interactor.finish() }
                    Button("Completed actions fixture") { interactor.completedActions() }
                    Button("Draft review fixture") { interactor.draftReview() }
                    Button("Sent receipts fixture") { interactor.sentReceipts() }
                    Button("Calendar receipts fixture") { interactor.calendarReceipts() }
                    Button("Selection stability fixture") { interactor.selectionStability() }
                    Button("Background browser fixture") { interactor.backgroundBrowser(form: false) }
                    Button("Background form fixture") { interactor.backgroundBrowser(form: true) }
                    Button("Expire task browsers") { Container.shared.backgroundBrowsers().purge() }
                    Button("Export evidence") { interactor.exportEvidence() }
                    Button("Save bundle…") { interactor.saveEvidenceBundle() }
                    Button("Browser fixture") {
                        let browser = SupervisedBrowserExperiment(context: .init(jobID: UUID(), profileID: nil,
                            origin: .init(account: "qa@example.test", messageID: "fixture-1", threadID: "thread-1",
                                sender: "Same Sender", subject: "Same Subject"),
                            request: "Inspect workshop availability and request a place only after my approval."))
                        browserPresentation = BrowserPresentation(browser: browser)
                    }
                }
            }.padding(.horizontal, 16).padding(.vertical, 8)
            DesktopWorkspaceView(viewModel: viewModel, interactor: interactor)
            HStack {
                Text(interactor.renderLabel).accessibilityIdentifier("fixtureRenderIdentity")
                Spacer()
                Text(interactor.evidenceStatus).textSelection(.enabled).accessibilityIdentifier("fixtureEvidenceStatus")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 6)
        }.frame(minWidth: 1040, minHeight: 760)
            .sheet(item: $browserPresentation) { presentation in
                SupervisedBrowserExperimentView(browser: presentation.browser) { context, result, state in
                    interactor.returnBrowserResult(context, result: result, state: state)
                }
            }
    }
}

@MainActor
class DesktopFixtureInteractor: ViewModelInteractor<DesktopWorkspaceModel>, DesktopWorkspaceHandler {
    @Published var renderLabel = "Waiting for the workspace to render"
    @Published var evidenceStatus = "No evidence exported"

    func draftReview() {
        Task {
            let message = MailMIME.Outgoing(to: "Alex <alex@example.test>", cc: ["team@example.test"],
                subject: "Re: Project review", body: "Hi Alex,\n\nThursday at 10 works for me. I’ve attached the project notes for our review.\n\nCould we spend the first few minutes on the rollout schedule?\n\nThanks,\nNate",
                threadId: "thread-1", inReplyTo: "<fixture-1@example.test>",
                attachments: [.init(filename: "Project notes.txt", mimeType: "text/plain", bytes: Data("Synthetic project notes".utf8))])
            let action = MailActionReceipt(kind: .draft, account: "qa@example.test", message: message, replyMessageID: "fixture-1")
            do {
                _ = try await LocalDraftReview.stage(action: action, message: message, owner: "fixture-user", profile: nil,
                    conversation: nil, origin: .init(account: "qa@example.test", messageID: "fixture-1", threadID: "thread-1", sender: "Alex", subject: message.subject),
                    archiveAfterSave: false, attachmentAccounts: ["qa@example.test"])
                model?.applyJobs(await Container.shared.dispatchJobs().history())
            } catch { model?.resultSelectionError = GmailManageTools.detail(error) }
        }
    }

    func calendarReceipts() {
        Task {
            let store = Container.shared.dispatchJobs()
            for (index, state) in [CalendarActionReceipt.State.unknown, .failed, .confirmed].enumerated() {
                var action = CalendarActionReceipt(tool: CalendarTools.create,
                    arguments: ["summary": state == .confirmed ? "Project review" : "Project review · \(state.rawValue)", "start": "2026-11-04T10:00:00-08:00",
                        "end": "2026-11-04T10:30:00-08:00", "time_zone": "America/Los_Angeles",
                        "attendees": ["alex@example.test"]], account: "qa@example.test",
                    requestKey: "calendar-fixture-\(index)-\(UUID())", parentJobID: nil)
                let origin = DispatchJob.MailOrigin(account: "qa@example.test", messageID: "fixture-1",
                    threadID: "thread-1", sender: "Alex", subject: "Project review request")
                guard let (job, _) = try? await store.beginCalendarAction(action, ownerID: "fixture-user",
                    profileID: nil, conversationID: nil, origin: origin) else { continue }
                action.state = state; action.attempted = true
                action.providerID = "synthetic-event-\(index)"
                action.providerLink = "https://calendar.google.com/calendar/event?eid=synthetic-event-\(index)"
                action.start = action.requestedStart; action.end = action.requestedEnd
                action.invitationOutcome = state == .confirmed ? "Google confirmed the event. Notifications requested; delivery not verified." : "No provider confirmation."
                action.archiveState = state == .confirmed ? "unconfirmed — source email kept" : nil
                await store.recordCalendarAction(job.id, action: action,
                    result: state == .confirmed ? "Calendar event created. The source email was kept because archiving failed." : "Synthetic \(state.rawValue) calendar operation.")
            }
            model?.jobs = await store.history()
        }
    }
    private let context: LocalContextStore
    private let queue = LocalTriageQueue(mailAccounts: { ["qa@example.test", "second@example.test"] },
        feedSectionLoader: { section in
            let count = section.account == "qa@example.test" ? 6 : 20
            return (0..<count).map { index in
                LocalTriageQueue.Item(account: section.account ?? "", id: "\(section.kind.rawValue)-\(index)",
                    threadId: "thread-\(index)", from: "Synthetic sender \(index)", subject: "Prepared email \(index + 1)",
                    date: "", snippet: "Only synthetic mail is used for this check.",
                    internalDate: Int64(Date().timeIntervalSince1970 * 1000), acted: nil,
                    importanceBand: section.kind == .important ? "high" : "normal")
            }
        }, unreadOpeningLoader: { _ in nil })
    private var mail: MailStore { MailStore(database: context.dbPool, userId: "fixture-user") }
    private var client: FullDuplexVoiceClient!
    private weak var model: DesktopWorkspaceModel?
    private var pendingProjection: LocalTriageQueue.DesktopSnapshot?
    private var renderRevision = 0
    private var busy = false
    private let runID = UUID()
    private let log = VoiceDiagnostics(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("jo-fixture-trace-" + UUID().uuidString))
    private var trace: VoiceDiagnostics.Session!
    private var adapter: LiveSessionAdapter!
    private var lastRendered: RenderedFeedState?
    private var receipts = Set<String>()
    private var actions: [[String: Any]] = []
    private var evidenceIndex = 0

    init(context: LocalContextStore) { self.context = context; super.init() }

    @CancellableBuilder
    override func onLoad(viewModel: DesktopWorkspaceModel) -> [AnyCancellable] {
        super.onLoad(viewModel: viewModel)
        model = viewModel
        Container.shared.backgroundBrowsers().$sessions.sink { [weak viewModel] in viewModel?.browserTasks = $0 }
        Container.shared.applicationTasks().$selectedTaskID.removeDuplicates().sink { [weak viewModel] id in
            viewModel?.applyTaskSelection(id.flatMap { Container.shared.dispatchJobs().existing($0) })
        }
        Container.shared.applicationTasks().$revision.dropFirst().sink { [weak viewModel] _ in
            Task { @MainActor in
                guard let viewModel else { return }
                viewModel.jobs = await Container.shared.dispatchJobs().history()
                if let selected = viewModel.selectedJob { viewModel.selectedJob = viewModel.jobs.first { $0.id == selected.id } }
            }
        }
        viewModel.conversationID = runID
        client = FullDuplexVoiceClient(localContext: context, localTriage: queue)
        trace = log.begin(engine: "fixture", userID: "fixture-user")
        client.diagnostics = trace
        Container.shared.realtimeService().isConversing = true
        client.sequentialFeed = true
        client.onFeedFocus = { [weak viewModel] in viewModel?.focus = $0 }
        client.onAssistantTranscript = { [weak self, weak viewModel] text, _ in
            viewModel?.response = text
            viewModel?.responseItemID = self?.client.currentAssistantItem
            viewModel?.responseTurnID = self?.client.historyTurnID.uuidString
        }
        adapter = LiveSessionAdapter(wire: { _ in }, emit: { [weak self] in self?.client.handle($0) })
        adapter.diagnostics = trace
        Task {
            _ = await Container.shared.customCommands().save(keyword: "research sender", label: "Find a company and summarize it",
                actions: [.init(tool: "web_search", detail: "Look up the sender's company."),
                          .init(tool: "summarize", detail: "Give me the useful details.")])
            _ = await Container.shared.customCommands().save(keyword: "summarize fixture", label: "Summarize the synthetic source",
                actions: [.init(tool: "summarize", detail: "Summarize this synthetic source.")])
            _ = await Container.shared.customCommands().save(keyword: "follow up fixture", label: "Label and archive the selected fixture",
                actions: [.init(tool: "label_message", detail: "Apply Followup",
                    resolvedLabel: .init(id: "fixture-label", name: "Followup", account: "qa@example.test")),
                    .init(tool: "archive_message", detail: "Archive this email")])
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let rows = (1...40).map { index in
                MailStore.Message(user_id: "fixture-user", id: "fixture-\(index)", account: "qa@example.test",
                    threadId: "thread-\(index)", sender: index <= 2 ? "Same Sender" : "Person \(index)",
                    recipient: "qa@example.test", subject: index <= 2 ? "Same Subject" : "Fixture email \(index)",
                    snippet: "Thanks &amp; welcome, Jo!\n\nThis is fixture \(index). 🌱\n\nOn Monday, Someone wrote:\n> Earlier conversation.",
                    internalDate: now - Int64(index * 1000), cachedAt: Date())
            }
            await queue.configure(coachingPlan: .init(lessons: []), forceOnboardingFeedLesson: false,
                sequentialFeed: true, calendarFeedDue: false, localCalendar: false)
            await queue.adopt(rows, store: mail)
            let opened = await queue.step(.init(account: "qa@example.test"), store: mail, dealtWith: false)
            await present(opened.output, delayProjection: false)
            viewModel.inSession = true
            viewModel.micLive = true
            viewModel.state = .ready
            viewModel.startedAt = Date()
        }
    }

    func sectionFeed() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            let profiles = Container.shared.workspaceProfiles()
            await profiles.adopt(["qa@example.test", "second@example.test"])
            Container.shared.localTriage.register { self.queue }
            await queue.configure(coachingPlan: nil, forceOnboardingFeedLesson: false,
                sequentialFeed: true, calendarFeedDue: false, localCalendar: false,
                feedSections: profiles.feedSections)
            let step = await queue.openingStep(store: mail)
            await queue.awaitFeedSectionPreparation()
            model?.profileID = ProfileRuntime.snapshot?.profileId
            await present(step.output, delayProjection: false)
        }
    }

    func next(delayProjection: Bool) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            let step = await queue.step(.init(), store: mail, dealtWith: false)
            await present(step.output, delayProjection: delayProjection)
        }
    }

    private func present(_ output: String, delayProjection: Bool) async {
        let progress = await queue.progress
        client.applyStep(output, progress: progress, standing: progress.map { ($0.position, $0.queued) },
            served: await queue.takeServedOutcomes(), dial: client.dialGeneration)
        let snapshot = await queue.desktopSnapshot()
        pendingProjection = snapshot
        if !delayProjection { applyProjection() }
        do {
            let text = "Synthetic response for \(snapshot.currentID ?? "the completed pass"). No audio was played."
            let start = Double(renderRevision * 10_000)
            adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.input_transcript.delta",
                "delta": "What email is selected?", "start_ms": start, "end_ms": start + 100]))
            adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.output_transcript.delta",
                "delta": text, "start_ms": start + 200, "end_ms": start + 300]))
        } catch { evidenceStatus = "Caption fixture failed: \(error.localizedDescription)" }
    }

    func applyProjection() {
        guard let model, let snapshot = pendingProjection else { return }
        model.sessionFeed = .init(mail: snapshot)
        updateFixtureEmailReader()
        pendingProjection = nil
    }

    func delaySessionStartup() {
        guard let model, !busy else { return }
        model.conversationID = UUID()
        model.inSession = true
        Task {
            if let step = client.standingStep { await present(step, delayProjection: true) }
        }
    }

    func refreshContinuity() {
        guard let model, !busy, !model.sessionFeed.rows.isEmpty else { return }
        busy = true
        let original = model.sessionFeed
        let focus = model.displayedFocus
        Task {
            defer { busy = false }
            @MainActor func capture(_ phase: String) async {
                trace.record(.feedRefresh, ["phase": phase, "queue_revision": String(model.sessionFeed.revision),
                    "visible_count": String(model.feedRows.count), "queue_order": model.feedRows.map { trace.target($0.id) }.joined(separator: ",")])
                try? await Task.sleep(for: .milliseconds(350))
                exportEvidence()
                try? await Task.sleep(for: .seconds(1))
            }
            await capture("baseline")
            toggleSession()
            await capture("ended")
            model.conversationID = UUID(); model.inSession = true
            model.applySessionFeed(.init(status: .loading, revision: 1))
            await capture("delayed_start")
            model.applySessionFeed(.init(status: .unavailable, revision: 2))
            await capture("unavailable")
            model.focus = focus
            var refreshed = original
            refreshed.revision = max(original.revision, 3)
            model.applySessionFeed(refreshed)
            await capture("reconnected")
            model.refreshingFeed = true
            await capture("manual_refresh")
            refreshed.rows.append(.email(account: "qa@example.test", messageID: "inserted", subject: "New arrival", sender: "Fixture Sender"))
            refreshed.revision += 1
            model.applySessionFeed(refreshed); model.refreshingFeed = false
            await capture("inserted")
            if refreshed.rows.count > 2 { refreshed.rows.remove(at: 2) }
            refreshed.revision += 1
            model.applySessionFeed(refreshed)
            await capture("removed")
            model.applySessionFeed(original)
            await capture("old_response_rejected")
            updateFixtureEmailReader()
        }
    }

    private func updateFixtureEmailReader() {
        guard let model else { return }
        if case .email(let email) = model.displayedFocus, let id = email.messageId {
            let request = DesktopEmailReader.Request(selection: .init(account: email.account, messageID: id),
                threadID: email.threadId, ownerID: "fixture-user", profileID: model.profileID,
                conversationID: model.conversationID, headersOnly: false)
            let text = "FIRST MARKER · Complete synthetic email \(id). Café 🙂\n\n"
                + "Email link: https://example.com/?jo-link-test=email\n\n"
                + (1...30).map { "Paragraph \($0). This complete email remains readable while the conversation scrolls independently below it." }
                    .joined(separator: "\n\n")
                + "\n\nOn Monday, the earlier sender wrote:\n> The original quoted reply stays visible.\n\nFINAL MARKER"
            do {
                model.emailReader = .ready(request, .init(selectedID: id, messages: [
                    .init(id: "earlier-\(id)", from: "Earlier sender", to: email.account, cc: "", subject: email.subject,
                          date: "Monday", body: try DesktopEmailReader.linkedBody("The complete earlier message in this synthetic thread.\n\nThread link: https://example.com/?jo-link-test=thread"),
                          attachments: [], error: nil),
                    .init(id: id, from: email.sender, to: email.account, cc: "", subject: email.subject,
                          date: "Tuesday", body: try DesktopEmailReader.linkedBody(text), attachments: ["Example.pdf"], error: nil)
                ]))
            } catch { model.emailReader = .failed(request, error.localizedDescription) }
        } else { model.emailReader = .idle }
    }
    func finish() {
        Task {
            await queue.end()
            model?.sessionFeed = .init(status: .complete)
            model?.focus = .complete(.init())
            model?.response = "You have finished this synthetic pass."
        }
    }
    func rendered(_ state: RenderedFeedState) {
        renderRevision += 1
        lastRendered = state
        var fixtureState = state
        fixtureState.conversationID = nil // This isolated renderer has no live transport conversation.
        Container.shared.realtimeService().recordRenderedWorkspace(fixtureState)
        trace?.record(.workspaceRendered, state.diagnosticFields(session: trace, revision: renderRevision))
        renderLabel = "Render \(renderRevision) · focus \(state.focus?.messageID ?? "transition") · queue \(state.queueCurrent?.messageID ?? "none") · \(state.queueOrder.count) rows"
    }
    func performFeedAction(_ action: LiveFastAction, context: FeedActionContext) {
        guard let model, !busy else { return }
        guard lastRendered.flatMap(FeedActionContext.init) == context else {
            model.feedActionError = "The selected email changed. Wait for the current email to appear."
            return
        }
        model.requestedActionContext = context
        if !model.inSession {
            guard let origin = model.taskOrigin(context) else { return }
            Task {
                if action != .next {
                    let result = await Container.shared.applicationTasks().perform(name: action.rawValue,
                        arguments: GmailReadTools.json(["account": origin.account, "message_id": origin.messageID]),
                        profile: context.profileID, origin: origin)
                    guard result.ok == true else { model.feedActionError = result.text; return }
                }
                let rows = model.feedRows.filter { $0.selection != context.selection }
                if let current = model.previewSelection { model.passedPreviewRows.insert(current.id) }
                model.previewSelection = rows.first
                updateFixtureEmailReader()
                model.jobs = await Container.shared.dispatchJobs().history()
                model.showingActivity = true
                model.requestedActionContext = nil
            }
            return
        }
        switch action {
        case .archive: archive()
        case .next: next(delayProjection: false)
        default: model.feedActionError = "This isolated fixture only simulates Archive and Next."
        }
    }

    func backgroundBrowser(form: Bool) {
        guard let model else { return }
        Task {
            do {
                let tasks = Container.shared.applicationTasks()
                let origin = DispatchJob.MailOrigin(account: "qa@example.test", messageID: "fixture-1",
                    threadID: "thread-1", sender: "Synthetic sender", subject: "Workshop")
                let job = try tasks.job(request: form ? "browser form fixture: request a place after approval"
                    : "browser fixture: bring back the workshop times", commandID: nil, origin: origin, profile: nil)
                await tasks.submit(job)
                model.jobs = await Container.shared.dispatchJobs().history()
                model.showingActivity = true
                model.selectedJob = model.jobs.first { $0.id == job.id }
                tasks.select(job.id)
            } catch { model.resultSelectionError = error.localizedDescription }
        }
    }

    func submitTask(_ text: String, commandID: String?, context: FeedActionContext) {
        guard let model, let origin = model.taskOrigin(context) else { return }
        Task {
            do {
                let tasks = Container.shared.applicationTasks()
                if text == "feedback archive fixture" {
                    let id = UUID()
                    try await tasks.deferFeedbackArchive(id: id, owner: Container.shared.backend().userId,
                        profile: context.profileID, origin: origin, conversation: nil)
                    model.taskText = ""
                    model.taskReceipt = "Archive saved for after feedback"
                    model.showingActivity = true
                    model.jobs = await Container.shared.dispatchJobs().history()
                    return
                }
                let job = try tasks.job(request: text, commandID: commandID, origin: origin, profile: context.profileID)
                let id = await tasks.submit(job)
                if let accepted = Container.shared.dispatchJobs().existing(id),
                   let step = await queue.parkTaskSource(accepted, store: mail) {
                    await present(step, delayProjection: false)
                }
                model.taskText = ""
                model.taskReceipt = "Task accepted · \(id.uuidString.prefix(8))"
                model.showingActivity = true
                model.jobs = await Container.shared.dispatchJobs().history()
                _ = await tasks.result(id)
                if text.contains("choice fixture") {
                    let links = EmailLinkTool.links(html: #"<a href="https://events.example.test/morning">Morning workshop</a><a href="https://events.example.test/evening">Evening workshop</a>"#, text: "")
                    if case .failure(let ambiguity) = EmailLinkTool.select(links, hint: "workshop") {
                        let choices = EmailLinkTool.choices(in: ambiguity.text)
                        _ = await Container.shared.dispatchJobs().requireChoice(id, revision: 1, choices: choices)
                        await Container.shared.dispatchJobs().finish(id, state: "awaiting_input", result: "Which workshop page should I read? Reading does not submit an RSVP.", revision: 1)
                    }
                }
                model.jobs = await Container.shared.dispatchJobs().history()
            } catch { model.feedActionError = error.localizedDescription }
        }
    }
    func archive() {
        guard !busy else { return }
        let authorization = UUID().uuidString
        let target = LiveEmailPresentation.Key.step(client.standingStep ?? "")
        var record: [String: Any] = ["authorization": authorization, "render_revision": renderRevision,
            "target": target?.messageId ?? "none", "operation": "fixture_archive", "writes_before": receipts.count]
        if let refusal = client.renderedSelectionRefusal() {
            record["outcome"] = "refused"; record["writes_after"] = receipts.count
            actions.append(record); evidenceStatus = refusal
            return
        }
        guard let target, target.account == "qa@example.test", target.messageId.hasPrefix("fixture-"),
              let number = Int(target.messageId.dropFirst(8)), (1...40).contains(number) else {
            evidenceStatus = "Refused: target is outside the fixture manifest"
            return
        }
        busy = true
        Task {
            defer { busy = false }
            receipts.insert(target.messageId)
            let effect = GmailWriteEffect(account: target.account, scope: "message", threadId: "thread-\(number)",
                messageIds: [target.messageId], messageIdsComplete: true, operation: "archive", removeLabelIds: ["INBOX"])
            _ = await queue.applyConfirmedEffects([effect], store: mail)
            record["outcome"] = "fixture_confirmed"; record["writes_after"] = receipts.count
            actions.append(record)
            trace.record(.toolFinished, ["call_id": authorization, "tool": "archive_message",
                "target_hash": trace.target(MailSelection(account: target.account, messageID: target.messageId).canonical),
                "outcome": "fixture_confirmed", "render_revision": String(renderRevision)])
            let step = await queue.step(.init(), store: mail, dealtWith: true)
            await present(step.output, delayProjection: false)
            evidenceStatus = "Fixture receipts: \(receipts.count). No provider writes."
        }
    }

    func exportEvidence() {
        guard evidenceIndex < 100 else { evidenceStatus = "This run reached its 100-capture limit"; return }
        guard let state = lastRendered, let trace,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: { $0.isKeyWindow }) else {
            evidenceStatus = "No rendered workspace to export"; return
        }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.pngData { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        evidenceIndex += 1
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JoQA/\(runID.uuidString)/\(evidenceIndex)", isDirectory: true)
        let fields = state.diagnosticFields(session: trace, revision: renderRevision)
        let manifest: [String: Any] = ["run_id": runID.uuidString, "schema_version": 1,
            "source_revision": Bundle.main.infoDictionary?["JoSourceRevision"] as? String ?? "unknown",
            "render_revision": renderRevision, "rendered": fields,
            "fixture_focus": state.focus?.messageID ?? "none", "fixture_queue": state.queueCurrent?.messageID ?? "none",
            "fixture_receipts": receipts.sorted(), "actions": actions, "audio": "not_tested",
            "provider": "fixture_only", "response": state.response, "timestamp": Date().timeIntervalSince1970]
        Task {
            do {
                let metadata = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                let diagnostics = try await log.snapshot(userID: "fixture-user")
                try await Task.detached(priority: .utility) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try image.write(to: folder.appendingPathComponent("window.png"))
                    try metadata.write(to: folder.appendingPathComponent("manifest.json"))
                    try diagnostics.write(to: folder.appendingPathComponent("diagnostics.jsonl"))
                }.value
                evidenceStatus = "Evidence saved: \(folder.path)"
            } catch { evidenceStatus = "Evidence export failed: \(error.localizedDescription)" }
        }
    }
    func saveEvidenceBundle() {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JoQA", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path),
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: { $0.isKeyWindow }),
              let presenter = window.rootViewController else {
            evidenceStatus = "Capture evidence before saving a bundle"; return
        }
        presenter.present(UIDocumentPickerViewController(forExporting: [folder], asCopy: true), animated: true)
    }
    func refreshFeed() {
        guard let model, !model.refreshingFeed else { return }
        model.feedRefreshError = nil
        model.refreshingFeed = true
        Task {
            model.feedRefreshError = await queue.refreshDesktopFeed(store: mail)
            model.applySessionFeed(.init(mail: await queue.desktopSnapshot()))
            model.refreshingFeed = false
        }
    }

    func selectReturnedResult(_ id: UUID) {
        guard let job = model?.jobs.first(where: { $0.id == id }), let origin = job.origin else { return }
        Task {
            let outcome = LocalTriageQueue.Outcome(jobId: id, task: job.task, text: job.result ?? "",
                ok: job.isDone, expects: .answer, about: origin.about)
            if let step = await queue.selectReturnedResult(outcome, profileID: nil) {
                await present(step, delayProjection: false)
                model?.selectedJob = nil
            }
        }
    }
    func returnBrowserResult(_ context: SupervisedBrowserExperiment.Context, result: String, state: String) {
        Task {
            let jobs = Container.shared.dispatchJobs()
            await jobs.begin(id: context.jobID, task: context.request, profileId: context.profileID, origin: context.origin)
            await jobs.finish(context.jobID, state: state, result: result)
            model?.jobs = await jobs.history()
        }
    }

    func sentReceipts() {
        Task {
            do {
                let jobs = Container.shared.dispatchJobs()
                for index in 0..<17 {
                    var message = MailMIME.Outgoing(to: "Dana <dana@example.test>", cc: ["team@example.test"],
                        subject: "Fixture reply \(index + 1)", body: "Thanks, Dana.\n\nThe synthetic review is ready.\nNate",
                        threadId: "fixture-thread-\(index)", inReplyTo: "<fixture-\(index)@example.test>")
                    if index == 16 {
                        message.subject = "Fwd: Synthetic invoice"
                        message.body = "Please review this invoice.\n\n---------- Forwarded message ----------\nFrom: Vendor <notifications@billing.example>\nSubject: Synthetic invoice\n\nTotal: $100. No real transaction."
                    }
                    var action = MailActionReceipt(kind: index == 15 ? .draft : index == 16 ? .forward : .send, account: "qa@example.test",
                        message: message, replyMessageID: "fixture-source-\(index)")
                    if index == 16 {
                        action.forwardNote = "Please review this invoice."
                        action.archiveState = "unconfirmed"
                        action.omittedAttachments = [.init(filename: "large-scan.pdf", mimeType: "application/pdf",
                            size: 24_000_000, reason: "Exceeds attachment limit")]
                    }
                    let origin = DispatchJob.MailOrigin(account: action.account, messageID: action.replyMessageID!,
                        threadID: message.threadId!, sender: "Dana", subject: message.subject)
                    let (job, _) = try await jobs.beginMailAction(action, ownerID: "fixture-user", profileID: nil,
                        conversationID: nil, origin: origin)
                    _ = try await MailActionAudit.write(job, receipt: "Synthetic provider confirmed this message. No external request was made.") {
                        let sent: [String: Any] = ["id": "fixture-sent-\(index)", "threadId": message.threadId!]
                        return action.kind.isDraft ? ["id": "fixture-draft-\(index)", "message": sent] : sent
                    }
                }
                model?.jobs = await jobs.history()
            } catch { model?.resultSelectionError = "Receipt fixture failed: \(error.localizedDescription)" }
        }
    }

    func selectionStability() {
        Task {
            for index in 1...30 {
                try? await Task.sleep(for: .milliseconds(300))
                model?.response = "Synthetic transcript update \(index). No audio or provider writes."
                updateFixtureEmailReader()
                if index == 15 { completedActions() }
            }
        }
    }

    func completedActions() {
        Task {
            let jobs = Container.shared.dispatchJobs()
            for (index, state) in ["done", "done", "done", "partial", "unknown"].enumerated() {
                let id = UUID(), subject = index == 2 ? "Project update — a deliberately long subject with café ☕ and extensive release details" : "Project update"
                let origin = DispatchJob.MailOrigin(account: index == 1 ? "personal@example.test" : "qa@example.test",
                    messageID: "activity-\(index)", threadID: "thread-\(index)", sender: "Dana", subject: subject)
                await jobs.begin(id: id, task: "Archive only the original email from Dana about \(subject). Keep its account and thread unchanged. Do not archive any other email.", profileId: nil, origin: origin)
                if state != "unknown" { await jobs.receipt(id, callId: "fixture", tool: index == 1 ? "send_email" : "archive_message", failed: state == "partial") }
                await jobs.finish(id, state: state, result: state == "done"
                    ? "Confirmed synthetic action on \(subject). Complete original receipt retained here for inspection. No provider request was made."
                    : "The archive was not confirmed. Check the original email before retrying.", reportBack: false)
            }
            model?.jobs = await jobs.history()
        }
    }
    func selectFeedItem(_ row: DesktopFeedRow) {
        guard !busy else { return }
        model?.selectedJob = nil
        Container.shared.applicationTasks().select(nil)
        model?.feedSelectionError = nil
        if model?.inSession == false {
            model?.previewSelection = row
            updateFixtureEmailReader()
            return
        }
        busy = true
        Task {
            defer { busy = false }
            let output: String?
            if let selection = row.selection {
                output = await queue.selectPreparedEmail(selection, profileID: model?.profileID)
            } else {
                output = await queue.selectPreparedSupplement(row, profileID: model?.profileID)?.selectionStep
            }
            if let output { await present(output, delayProjection: false) }
            else { model?.feedSelectionError = "This item is no longer in the prepared feed." }
        }
    }

    func toggleSession() {
        guard let model else { return }
        if model.inSession {
            model.feedPreview = .init(mail: .init(rows: model.sessionFeed.rows, count: model.sessionFeed.rows.count), slack: .init())
            model.inSession = false
            model.conversationID = nil
            model.focus = nil
            model.response = ""
            model.userWords = ""
            model.micLive = false
            model.startedAt = nil
        } else {
            model.conversationID = runID
            model.inSession = true
            model.micLive = true
            model.startedAt = Date()
            Task { if let step = client.standingStep { await present(step, delayProjection: false) } }
        }
    }
    func quickAction() {}
    func toggleMute() { model?.muted.toggle() }
    func stopSpeaking() {}
    func retryEmailReader() {}
    func exportDiagnostics() {}
    func exportHistory() {}
    func showFeedback() { model?.showingFeedback = true }
    func saveFeedback() {
        guard let model, model.canSaveFeedback else { return }
        model.savingFeedback = true
        Task {
            defer { model.savingFeedback = false }
            do {
                _ = try await log.saveFeedback(FeedbackText.validated(model.feedbackText), source: .button,
                    userID: "fixture-user", context: .init(sessionID: trace.id, engine: "fixture", renderRevision: renderRevision))
                model.showingFeedback = false
                model.feedbackText = ""
                model.feedbackReceipt = "Fixture feedback saved locally"
            } catch { model.feedbackError = error.localizedDescription }
        }
    }
}

private final class FixtureGrants: GoogleGrantStorage, @unchecked Sendable {
    func all() -> [GoogleAccountStore.Grant] {
        ["qa@example.test", "second@example.test"].map { .init(email: $0, refreshToken: "fixture", scopes: ["https://www.googleapis.com/auth/gmail.modify"], grantedAt: Date(), isPrimary: $0.hasPrefix("qa")) }
    }
    func save(_ grant: GoogleAccountStore.Grant) -> Bool { false }
    func remove(_ email: String) {}
    func removeAll() {}
}
private struct FixtureNoNetwork: HTTPDataTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if let url = request.url, url.host == "gmail.googleapis.com", url.path.hasSuffix("/drafts"), request.httpMethod == "POST" {
            let body: [String: Any] = ["id": "fixture-draft-" + UUID().uuidString,
                "message": ["id": "fixture-message", "threadId": "thread-1"]]
            return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        guard let url = request.url, url.host == "gmail.googleapis.com", url.path.contains("fixture-") || url.path.contains("thread-") else {
            throw URLError(.notConnectedToInternet)
        }
        let parts = url.path.split(separator: "/")
        let id = String(parts.last == "modify" ? parts.dropLast().last ?? "" : parts.last ?? "")
        let number = id.split(separator: "-").last ?? "1"
        let message: [String: Any] = ["id": "fixture-\(number)", "threadId": "thread-\(number)", "labelIds": ["INBOX"]]
        let body: [String: Any] = url.path.contains("/threads/") ? ["id": "thread-\(number)", "messages": [message]] : message
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor
private final class FixtureTokens: GoogleTokenProvider {
    func token(for email: String?, requiredScopes: [String]) async -> Result<GoogleCredential.Token, GoogleCredential.Failure> {
        .success(.init(accessToken: "fixture", email: email ?? "qa@example.test", scopes: requiredScopes))
    }
}
#endif
