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
        Container.shared.providerHTTP.register { FixtureNoNetwork() }
        let jobs = DispatchJobStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("jo-fixture-jobs-" + UUID().uuidString + ".json"))
        Container.shared.dispatchJobs.register { jobs }
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
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ISOLATED QA · synthetic mail · no audio or provider writes").font(.caption)
                Spacer()
                Button("Next") { interactor.next(delayProjection: false) }
                Button("Archive fixture") { interactor.archive() }
                Button("Delay projection") { interactor.next(delayProjection: true) }
                Button("Apply projection") { interactor.applyProjection() }
                Button("Section feed") { interactor.sectionFeed() }
                Button("Finish fixture") { interactor.finish() }
                Button("Export evidence") { interactor.exportEvidence() }
                Button("Save bundle…") { interactor.saveEvidenceBundle() }
                Button("Browser fixture") {
                    let browser = SupervisedBrowserExperiment(context: .init(jobID: UUID(), profileID: nil,
                        origin: .init(account: "qa@example.test", messageID: "fixture-1", threadID: "thread-1",
                            sender: "Same Sender", subject: "Same Subject"),
                        request: "Inspect workshop availability and request a place only after my approval."))
                    browserPresentation = BrowserPresentation(browser: browser)
                }
            }.padding(12)
            DesktopWorkspaceView(viewModel: viewModel, interactor: interactor)
            Text(interactor.renderLabel).font(.caption.monospaced()).padding(8)
                .accessibilityIdentifier("fixtureRenderIdentity")
            Text(interactor.evidenceStatus).font(.caption).textSelection(.enabled)
                .accessibilityIdentifier("fixtureEvidenceStatus")
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
            served: [UUID()], dial: client.dialGeneration)
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
        pendingProjection = nil
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
        switch action {
        case .archive: archive()
        case .next: next(delayProjection: false)
        default: model.feedActionError = "This isolated fixture only simulates Archive and Next."
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
    func toggleSession() {}
    func quickAction() {}
    func toggleMute() {}
    func stopSpeaking() {}
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
    func all() -> [GoogleAccountStore.Grant] { [] }
    func save(_ grant: GoogleAccountStore.Grant) -> Bool { false }
    func remove(_ email: String) {}
    func removeAll() {}
}
private struct FixtureNoNetwork: HTTPDataTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw URLError(.notConnectedToInternet) }
}
#endif
