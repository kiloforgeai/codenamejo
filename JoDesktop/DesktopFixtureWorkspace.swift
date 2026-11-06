#if targetEnvironment(macCatalyst) && JO_QA
import Combine
import FactoryKit
import Foundation
import SwiftUI

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
        ProfileRuntime.install(nil)
        let model = DesktopWorkspaceModel()
        let interactor = DesktopFixtureInteractor(context: context)
        return DesktopFixtureView(viewModel: model, interactor: interactor)
    }
}

struct DesktopFixtureView: View {
    @StateObject var viewModel: DesktopWorkspaceModel
    @StateObject var interactor: DesktopFixtureInteractor
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ISOLATED QA · synthetic mail · no audio or provider writes").font(.caption)
                Spacer()
                Button("Next + receipt") { interactor.next(delayProjection: false) }
                Button("Delay projection") { interactor.next(delayProjection: true) }
                Button("Apply projection") { interactor.applyProjection() }
                Button("Finish fixture") { interactor.finish() }
            }.padding(12)
            DesktopWorkspaceView(viewModel: viewModel, interactor: interactor)
            Text(interactor.renderLabel).font(.caption.monospaced()).padding(8)
                .accessibilityIdentifier("fixtureRenderIdentity")
        }.frame(minWidth: 1040, minHeight: 760)
    }
}

@MainActor
class DesktopFixtureInteractor: ViewModelInteractor<DesktopWorkspaceModel>, DesktopWorkspaceHandler {
    @Published var renderLabel = "Waiting for the workspace to render"
    private let context: LocalContextStore
    private let queue = LocalTriageQueue(mailAccounts: { ["qa@example.test"] }, unreadOpeningLoader: { _ in nil })
    private var mail: MailStore { MailStore(database: context.dbPool, userId: "fixture-user") }
    private var client: FullDuplexVoiceClient!
    private weak var model: DesktopWorkspaceModel?
    private var pendingProjection: LocalTriageQueue.DesktopSnapshot?
    private var renderRevision = 0
    private var busy = false

    init(context: LocalContextStore) { self.context = context; super.init() }

    @CancellableBuilder
    override func onLoad(viewModel: DesktopWorkspaceModel) -> [AnyCancellable] {
        super.onLoad(viewModel: viewModel)
        model = viewModel
        client = FullDuplexVoiceClient(localContext: context, localTriage: queue)
        client.sequentialFeed = true
        client.onFeedFocus = { [weak viewModel] in viewModel?.focus = $0 }
        Task {
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
        model?.response = "Synthetic response for \(snapshot.currentID ?? "the completed pass"). No audio was played."
    }

    func applyProjection() {
        guard let model, let snapshot = pendingProjection else { return }
        model.queueCurrent = snapshot.currentID.map { .init(account: snapshot.account ?? "", messageID: $0) }
        model.queueRevision = snapshot.revision
        model.queueScope = snapshot.scope
        model.queueStatus = snapshot.status
        model.queue = snapshot.items.map { .init(id: $0.id, source: "Email", title: $0.subject, detail: $0.from,
            reason: nil, selection: .init(account: $0.account, messageID: $0.id)) }
        pendingProjection = nil
    }
    func finish() {
        Task {
            await queue.end()
            model?.queue = []
            model?.queueCurrent = nil
            model?.queueStatus = .complete
            model?.focus = .complete(.init())
            model?.response = "You have finished this synthetic pass."
        }
    }
    func rendered(_ state: RenderedFeedState) {
        renderRevision += 1
        renderLabel = "Render \(renderRevision) · focus \(state.focus?.messageID ?? "transition") · queue \(state.queueCurrent?.messageID ?? "none") · \(state.queueOrder.count) rows"
    }
    func toggleSession() {}
    func toggleMute() {}
    func stopSpeaking() {}
    func refresh(viewModel: DesktopWorkspaceModel) {}
    func exportDiagnostics() {}
    func exportHistory() {}
    func showFeedback() { model?.showingFeedback = true }
    func saveFeedback() {
        guard let model, model.canSaveFeedback else { return }
        model.savingFeedback = true
        Task {
            defer { model.savingFeedback = false }
            do {
                let log = VoiceDiagnostics(directory: FileManager.default.temporaryDirectory.appendingPathComponent("jo-fixture-feedback"))
                _ = try await log.saveFeedback(FeedbackText.validated(model.feedbackText), source: .button,
                    userID: "fixture-user", context: .init(engine: "fixture", renderRevision: renderRevision))
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
