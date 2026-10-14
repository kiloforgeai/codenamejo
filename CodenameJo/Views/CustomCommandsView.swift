import Combine
import FactoryKit
import SwiftUI

@MainActor
protocol CustomCommandsHandler {
    func setCommand(_ command: CustomCommand, enabled: Bool, viewModel: CustomCommandsViewModel)
    func requestDelete(_ command: CustomCommand, viewModel: CustomCommandsViewModel)
    func confirmDelete(viewModel: CustomCommandsViewModel)
}

/// The user's saved voice commands, in Settings. **There is no button that makes one** — they
/// are dictated — so the footer is what teaches that. A toggle pauses a command (a tap, since
/// it is reversible); deleting is a swipe plus an alert, because the steps were dictated and
/// nothing keeps a copy.
struct CustomCommandsView<Interactor: ViewWithModelLifecycleObserver<CustomCommandsViewModel> & CustomCommandsHandler>: View {
    @StateObject var viewModel: CustomCommandsViewModel
    @StateObject var interactor: Interactor

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            List {
                Section {
                    ForEach(viewModel.commands) { command in
                        row(command)
                    }
                } footer: {
                    Text("Ask for one out loud: \"save a command called candidate screen "
                         + "that means look them up and check what they've sent me.\" Then "
                         + "say \"candidate screen\". The words you say it with can be one "
                         + "word or a short phrase, up to four.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityIdentifier("commandsPlaceholder")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Commands")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete Command", isPresented: $viewModel.showDeleteAlert) {
            Button("Delete", role: .destructive) { interactor.confirmDelete(viewModel: viewModel) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(viewModel.pendingDelete.map { "\"\($0.title)\" and its steps will be permanently deleted." } ?? "")
        }
        .bind(observer: interactor, viewModel: viewModel)
    }

    /// The keyword, and what saying it does. **No tool names**: the steps are how the command is
    /// built, not what it does.
    private func row(_ command: CustomCommand) -> some View {
        Toggle(isOn: Binding(
            get: { command.enabled },
            // Straight to the interactor: the store owns the array, and the assistant can
            // switch one mid-call, so the view must not hold its own answer.
            set: { interactor.setCommand(command, enabled: $0, viewModel: viewModel) }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text(command.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                if !command.plainDescription.isEmpty {
                    Text(command.plainDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                }
            }
        }
        .tint(Theme.toggleOn)
        .accessibilityIdentifier("commandToggle-\(command.keyword)")
        .listRowBackground(Theme.surface)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                interactor.requestDelete(command, viewModel: viewModel)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("commandDelete-\(command.keyword)")
        }
    }
}

@MainActor
class CustomCommandsViewModel: ViewModel {
    @Published var commands: [CustomCommand] = []
    @Published var showDeleteAlert = false
    @Published var pendingDelete: CustomCommand?
}

@MainActor
final class CustomCommandsInteractor: ViewModelInteractor<CustomCommandsViewModel>, CustomCommandsHandler {
    @Injected(\.customCommands) private var store

    @CancellableBuilder
    override func onLoad(viewModel: CustomCommandsViewModel) -> [AnyCancellable] {
        super.onLoad(viewModel: viewModel)
        store.$commands.sink { viewModel.commands = $0 }
    }

    @CancellableBuilder
    override func onViewAppear(viewModel: CustomCommandsViewModel) -> [AnyCancellable] {
        super.onViewAppear(viewModel: viewModel)
        store.refresh()
    }

    func setCommand(_ command: CustomCommand, enabled: Bool, viewModel: CustomCommandsViewModel) {
        store.toggle(command, to: enabled)
    }

    func requestDelete(_ command: CustomCommand, viewModel: CustomCommandsViewModel) {
        viewModel.pendingDelete = command
        viewModel.showDeleteAlert = true
    }

    func confirmDelete(viewModel: CustomCommandsViewModel) {
        guard let command = viewModel.pendingDelete else { return }
        viewModel.pendingDelete = nil
        _ = store.delete(keyword: command.keyword)
    }
}

@MainActor
struct CustomCommandsComponent {
    static func make(viewModel: CustomCommandsViewModel? = nil) -> some View {
        CustomCommandsView(viewModel: viewModel ?? CustomCommandsViewModel(), interactor: CustomCommandsInteractor())
    }
}
