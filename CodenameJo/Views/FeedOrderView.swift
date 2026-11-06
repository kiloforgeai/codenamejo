import Combine
import FactoryKit
import SwiftUI

@MainActor
class FeedOrderViewModel: ViewModel {
    @Published var sections: [FeedSection] = []
    @Published var profileName = ""
    @Published var saving = false
    @Published var error: String?
}

protocol FeedOrderHandler {
    func setEnabled(_ id: String, enabled: Bool, viewModel: FeedOrderViewModel)
    func move(_ id: String, before destination: String?, viewModel: FeedOrderViewModel)
}

@MainActor
class FeedOrderInteractor: ViewModelInteractor<FeedOrderViewModel>, FeedOrderHandler {
    @Injected(\.workspaceProfiles) private var profiles

    @CancellableBuilder
    override func onLoad(viewModel: FeedOrderViewModel) -> [AnyCancellable] {
        super.onLoad(viewModel: viewModel)
        profiles.$feedSections.sink { [weak viewModel] in viewModel?.sections = $0 }
        profiles.$selected.sink { [weak viewModel] in viewModel?.profileName = $0?.name ?? "Your workspace" }
    }

    func move(_ id: String, before destination: String?, viewModel: FeedOrderViewModel) {
        guard !viewModel.saving, id != destination,
              let source = viewModel.sections.firstIndex(where: { $0.id == id }) else { return }
        var ordered = viewModel.sections
        let item = ordered.remove(at: source)
        let target = destination.flatMap { id in ordered.firstIndex { $0.id == id } } ?? ordered.count
        ordered.insert(item, at: target)
        save(ordered, viewModel: viewModel)
    }

    func setEnabled(_ id: String, enabled: Bool, viewModel: FeedOrderViewModel) {
        guard !viewModel.saving, let index = viewModel.sections.firstIndex(where: { $0.id == id }) else { return }
        var sections = viewModel.sections
        sections[index].enabled = enabled
        save(sections, viewModel: viewModel)
    }

    private func save(_ sections: [FeedSection], viewModel: FeedOrderViewModel) {
        guard let profile = profiles.selected else { return }
        viewModel.saving = true
        viewModel.error = nil
        Task { [weak self, weak viewModel] in
            guard let self, let viewModel else { return }
            defer { viewModel.saving = false }
            do { try await profiles.saveFeedSections(sections, profileId: profile.id) }
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
                    Text("Feed sections").font(.largeTitle.bold())
                    Text(viewModel.profileName).font(.headline).foregroundStyle(.secondary)
                    Text("Choose what belongs in your feed, then drag sections into the order you want. Your current email stays in place.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 10) {
                    ForEach(Array(viewModel.sections.enumerated()), id: \.element.id) { index, section in
                        HStack(spacing: 16) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                                .frame(width: 24, height: 32).contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("feedOrderRows"))
                                    .onChanged { _ in if !viewModel.saving { dragging = section.id } }
                                    .onEnded { value in
                                        defer { dragging = nil }
                                        guard !viewModel.saving else { return }
                                        let destination = viewModel.sections.first { candidate in
                                            candidate.id != section.id && (rowFrames[candidate.id]?.midY ?? .infinity) > value.location.y
                                        }?.id
                                        interactor.move(section.id, before: destination, viewModel: viewModel)
                                    })
                                .accessibilityHidden(true)
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                            Image(systemName: section.symbol).frame(width: 24).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(section.title).font(.body.weight(.semibold))
                                Text(section.subtitle).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Toggle("Include \(section.title), \(section.subtitle)", isOn: Binding(
                                get: { section.enabled },
                                set: { interactor.setEnabled(section.id, enabled: $0, viewModel: viewModel) }))
                                .labelsHidden().disabled(viewModel.saving)
                                .accessibilityIdentifier("feedSectionToggle_\(section.id)")
                            Button {
                                interactor.move(section.id, before: viewModel.sections[index - 1].id, viewModel: viewModel)
                            } label: { Image(systemName: "arrow.up") }
                                .disabled(index == 0 || viewModel.saving)
                                .accessibilityLabel("Move \(section.title), \(section.subtitle) earlier")
                            Button {
                                let afterNext = index + 2 < viewModel.sections.count ? viewModel.sections[index + 2].id : nil
                                interactor.move(section.id, before: afterNext, viewModel: viewModel)
                            } label: { Image(systemName: "arrow.down") }
                                .disabled(index == viewModel.sections.count - 1 || viewModel.saving)
                                .accessibilityLabel("Move \(section.title), \(section.subtitle) later")
                        }
                        .padding(18).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(dragging == section.id ? Color.accentColor : .clear, lineWidth: 2))
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: FeedOrderRowFrames.self,
                                value: [section.id: geometry.frame(in: .named("feedOrderRows"))])
                        })
                        .accessibilityIdentifier("feedOrderRow_\(index)")
                    }
                }
                .coordinateSpace(name: "feedOrderRows")
                .onPreferenceChange(FeedOrderRowFrames.self) { rowFrames = $0 }
                if viewModel.saving { ProgressView("Saving feed…") }
                if let error = viewModel.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                Text("Saved for this profile. Important emails are Jo’s high-priority mail from the past week; Other emails includes everything else, including unranked mail. Changes apply to upcoming sections. New inbox sections are added at the end.")
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
