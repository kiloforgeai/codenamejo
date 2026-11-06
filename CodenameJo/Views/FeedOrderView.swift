import Combine
import FactoryKit
import SwiftUI

@MainActor
class FeedOrderViewModel: ViewModel {
    @Published var inboxes: [WorkspaceProfileConnection] = []
    @Published var profileName = ""
    @Published var saving = false
    @Published var error: String?
}

protocol FeedOrderHandler {
    func move(_ email: String, before destination: String?, viewModel: FeedOrderViewModel)
}

@MainActor
class FeedOrderInteractor: ViewModelInteractor<FeedOrderViewModel>, FeedOrderHandler {
    @Injected(\.workspaceProfiles) private var profiles

    @CancellableBuilder
    override func onLoad(viewModel: FeedOrderViewModel) -> [AnyCancellable] {
        super.onLoad(viewModel: viewModel)
        profiles.$connections.sink { [weak viewModel] in viewModel?.inboxes = $0 }
        profiles.$selected.sink { [weak viewModel] in viewModel?.profileName = $0?.name ?? "Your workspace" }
    }

    func move(_ email: String, before destination: String?, viewModel: FeedOrderViewModel) {
        guard !viewModel.saving, email != destination, let profile = profiles.selected,
              let source = viewModel.inboxes.firstIndex(where: { $0.email == email }) else { return }
        var ordered = viewModel.inboxes
        let item = ordered.remove(at: source)
        let target = destination.flatMap { address in ordered.firstIndex { $0.email == address } } ?? ordered.count
        ordered.insert(item, at: target)
        viewModel.saving = true
        viewModel.error = nil
        Task { [weak self, weak viewModel] in
            guard let self, let viewModel else { return }
            defer { viewModel.saving = false }
            do { try await profiles.reorderMailboxes(ordered.map(\.email), profileId: profile.id) }
            catch { viewModel.error = error.localizedDescription }
        }
    }
}

struct FeedOrderView<Interactor: ViewWithModelLifecycleObserver<FeedOrderViewModel> & FeedOrderHandler>: View {
    @StateObject var viewModel: FeedOrderViewModel
    @StateObject var interactor: Interactor
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var dragging: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Feed order").font(.largeTitle.bold())
                    Text(viewModel.profileName).font(.headline).foregroundStyle(.secondary)
                    Text("Drag an inbox above another to choose what comes next. Jo keeps your current email in place.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if viewModel.inboxes.isEmpty {
                    ContentUnavailableView("Connect an inbox first", systemImage: "envelope",
                        description: Text("Your connected inboxes will appear here."))
                }
                VStack(spacing: 10) {
                    ForEach(Array(viewModel.inboxes.enumerated()), id: \.element.id) { index, inbox in
                        HStack(spacing: 16) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                                .frame(width: 24, height: 32).contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("feedOrderRows"))
                                    .onChanged { _ in if !viewModel.saving { dragging = inbox.email } }
                                    .onEnded { value in
                                        defer { dragging = nil }
                                        guard !viewModel.saving else { return }
                                        let destination = viewModel.inboxes.first { candidate in
                                            candidate.email != inbox.email && (rowFrames[candidate.email]?.midY ?? .infinity) > value.location.y
                                        }?.email
                                        interactor.move(inbox.email, before: destination, viewModel: viewModel)
                                    })
                                .accessibilityHidden(true)
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                            Text(inbox.email).font(.body.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button {
                                interactor.move(inbox.email, before: viewModel.inboxes[index - 1].email, viewModel: viewModel)
                            } label: { Image(systemName: "arrow.up") }
                                .disabled(index == 0 || viewModel.saving)
                                .accessibilityLabel("Move \(inbox.email) earlier")
                            Button {
                                let afterNext = index + 2 < viewModel.inboxes.count ? viewModel.inboxes[index + 2].email : nil
                                interactor.move(inbox.email, before: afterNext, viewModel: viewModel)
                            } label: { Image(systemName: "arrow.down") }
                                .disabled(index == viewModel.inboxes.count - 1 || viewModel.saving)
                                .accessibilityLabel("Move \(inbox.email) later")
                        }
                        .padding(18).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(dragging == inbox.email ? Color.accentColor : .clear, lineWidth: 2))
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: FeedOrderRowFrames.self,
                                value: [inbox.email: geometry.frame(in: .named("feedOrderRows"))])
                        })
                        .accessibilityIdentifier("feedOrderRow_\(index)")
                    }
                }
                .coordinateSpace(name: "feedOrderRows")
                .onPreferenceChange(FeedOrderRowFrames.self) { rowFrames = $0 }
                if viewModel.saving { ProgressView("Saving order…") }
                if let error = viewModel.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                Text("Order is saved for this profile. Newly connected inboxes are added at the end.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(32).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Theme.background).navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .bind(observer: interactor, viewModel: viewModel)
    }
}

struct FeedOrderComponent {
    @MainActor
    static func make() -> some View {
        FeedOrderView(viewModel: FeedOrderViewModel(), interactor: FeedOrderInteractor())
    }
}

private struct FeedOrderRowFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
