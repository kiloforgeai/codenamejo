import Combine
import FactoryKit
import SwiftUI

struct CommandDraft: Identifiable {
    struct Step: Identifiable {
        let id = UUID()
        let original: CommandAction
        var tool: String
        var detail: String
        var labelScope: CommandAction.ResolvedLabel.Scope
        init(_ action: CommandAction) {
            original = action; tool = action.tool; detail = action.detail
            labelScope = action.resolvedLabel?.effectiveScope ?? .allInboxes
        }
        var action: CommandAction {
            var label = tool == original.tool && detail == original.detail ? original.resolvedLabel : nil
            if label?.effectiveScope != labelScope { label?.scope = labelScope }
            return .init(tool: tool, detail: detail, resolvedLabel: label)
        }
    }
    let id = UUID()
    let original: CustomCommand?
    let scope: CustomCommandStore.EditScope
    var phrase: String
    var description: String
    var steps: [Step]

    init(command: CustomCommand?, scope: CustomCommandStore.EditScope) {
        original = command
        self.scope = scope
        phrase = command?.title ?? ""
        description = command?.instruction ?? ""
        steps = (command?.actions ?? [.init(tool: "summarize", detail: "")]).map(Step.init)
    }
}

@MainActor
protocol CustomCommandsHandler {
    func setCommand(_ command: CustomCommand, enabled: Bool, viewModel: CustomCommandsViewModel)
    func requestDelete(_ command: CustomCommand, viewModel: CustomCommandsViewModel)
    func confirmDelete(viewModel: CustomCommandsViewModel)
    func edit(_ command: CustomCommand?, viewModel: CustomCommandsViewModel)
    func save(viewModel: CustomCommandsViewModel)
}

struct CustomCommandsView<Interactor: ViewWithModelLifecycleObserver<CustomCommandsViewModel> & CustomCommandsHandler>: View {
    @StateObject var viewModel: CustomCommandsViewModel
    @StateObject var interactor: Interactor

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Commands").font(.largeTitle.weight(.semibold))
                        Text("Click a feed action, or make a phrase that runs your own steps.")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }.listRowBackground(Color.clear)
                Section {
                    if viewModel.commands.isEmpty {
                        Text("No saved commands yet. Add one here, or ask Jo to save a command while you talk.")
                            .foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    ForEach(viewModel.commands) { command in row(command) }
                    Button { interactor.edit(nil, viewModel: viewModel) } label: {
                        Label("Add command", systemImage: "plus")
                    }.accessibilityIdentifier("addCommand")
                } header: { Text("Your commands") } footer: {
                    Text("Commands belong to the active profile. Say a command's phrase to run its steps. Changes apply the next time it runs.")
                }
                Section {
                    DisclosureGroup("Built-in feed actions") {
                        ForEach(LiveFastAction.buttons, id: \.rawValue) { action in
                            Label {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(action.title).font(.headline)
                                    Text(action.explanation).font(.callout).foregroundStyle(.secondary)
                                }.padding(.vertical, 6)
                            } icon: { Image(systemName: action.symbol).frame(width: 28) }
                        }
                        Text("Use these on the current email during a Live feed session. Built-in actions keep their meaning.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error = viewModel.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 880)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { viewModel.draft != nil }, set: { if !$0 { viewModel.draft = nil } })) {
            editor
        }
        .alert("Delete Command", isPresented: $viewModel.showDeleteAlert) {
            Button("Delete", role: .destructive) { interactor.confirmDelete(viewModel: viewModel) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(viewModel.pendingDelete.map { "\"\($0.title)\" and its steps will be permanently deleted." } ?? "")
        }
        .bind(observer: interactor, viewModel: viewModel)
    }

    private func row(_ command: CustomCommand) -> some View {
        HStack(spacing: 16) {
            Button { interactor.edit(command, viewModel: viewModel) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(command.title).font(.headline).foregroundStyle(Theme.textPrimary)
                    Text(command.plainDescription.isEmpty ? "\(command.actions.count) steps" : command.plainDescription)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Edit \(command.title)")
            Toggle("Enabled", isOn: Binding(get: { command.enabled }, set: {
                interactor.setCommand(command, enabled: $0, viewModel: viewModel)
            })).labelsHidden().tint(Theme.toggleOn)
                .accessibilityLabel("Enable \(command.title)")
                .accessibilityIdentifier("commandToggle-\(command.keyword)")
            Button { interactor.edit(command, viewModel: viewModel) } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).accessibilityLabel("Edit \(command.title) steps")
            Button(role: .destructive) { interactor.requestDelete(command, viewModel: viewModel) } label: {
                Image(systemName: "trash")
            }.buttonStyle(.borderless).accessibilityLabel("Delete \(command.title)")
        }.padding(.vertical, 10).listRowBackground(Theme.surface)
            .disabled(viewModel.busy)
    }

    private var editor: some View {
        NavigationStack {
            Form {
                Section {
                    Text(viewModel.draft?.original == nil ? "New command" : "Edit command").font(.title2.bold())
                    TextField("Phrase", text: viewModel.field(\.phrase, default: ""))
                        .accessibilityIdentifier("commandPhrase")
                    TextField("Description", text: viewModel.field(\.description, default: ""), axis: .vertical)
                        .accessibilityIdentifier("commandDescription")
                } footer: { Text("Choose a phrase of up to four words, such as ‘research sender’.") }
                Section {
                    ForEach(viewModel.draft?.steps ?? []) { step in
                        stepRow(viewModel.stepBinding(step))
                    }.onMove { from, to in viewModel.draft?.steps.move(fromOffsets: from, toOffset: to) }
                    Button("Add step", systemImage: "plus") {
                        viewModel.draft?.steps.append(.init(.init(tool: "summarize", detail: "")))
                    }
                } header: { Text("Steps · in order") } footer: {
                    Text("Describe each step in plain language, such as ‘look up the sender’s company’. Jo fills in details from the conversation when you run it.")
                }
            }.disabled(viewModel.busy)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { viewModel.draft = nil }.disabled(viewModel.busy)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(viewModel.busy ? "Saving…" : "Save") { interactor.save(viewModel: viewModel) }
                            .disabled(viewModel.busy).accessibilityIdentifier("saveCommand")
                    }
                }
        }
        .alert("Couldn't save command", isPresented: Binding(
            get: { viewModel.editorError != nil },
            set: { if !$0 { viewModel.editorError = nil } })) {
                Button("OK", role: .cancel) { viewModel.editorError = nil }
            } message: { Text(viewModel.editorError ?? "") }
        .interactiveDismissDisabled(viewModel.busy)
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 650, idealWidth: 700, minHeight: 600)
        #endif
    }

    private func stepRow(_ step: Binding<CommandDraft.Step>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Action", selection: step.tool) {
                    ForEach(viewModel.availableTools(including: step.wrappedValue.tool), id: \.self) { tool in
                        Text(CustomCommandsViewModel.actionTitle(tool)).tag(tool)
                    }
                }.accessibilityLabel("Step action")
                Button { viewModel.move(step.wrappedValue.id, by: -1) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless).accessibilityLabel("Move step up")
                    .disabled(viewModel.draft?.steps.first?.id == step.wrappedValue.id)
                Button { viewModel.move(step.wrappedValue.id, by: 1) } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.borderless).accessibilityLabel("Move step down")
                    .disabled(viewModel.draft?.steps.last?.id == step.wrappedValue.id)
                Button(role: .destructive) {
                    viewModel.draft?.steps.removeAll { $0.id == step.wrappedValue.id }
                } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).accessibilityLabel("Remove step")
            }
            TextField("What should this step do?", text: step.detail, axis: .vertical)
                .lineLimit(2...5).accessibilityLabel("Step instructions")
            if let label = step.wrappedValue.action.resolvedLabel {
                Picker("Inbox scope", selection: step.labelScope) {
                    Text("All connected inboxes").tag(CommandAction.ResolvedLabel.Scope.allInboxes)
                    Text("Only \(label.account)").tag(CommandAction.ResolvedLabel.Scope.savedAccount)
                }.accessibilityIdentifier("commandLabelScope")
                Text("“\(label.name)” is verified in the selected inbox before any command step runs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 8)
    }

}

@MainActor
class CustomCommandsViewModel: ViewModel {
    @Published var commands: [CustomCommand] = []
    @Published var showDeleteAlert = false
    @Published var pendingDelete: CustomCommand?
    @Published var draft: CommandDraft?
    @Published var busy = false
    @Published var error: String?
    @Published var editorError: String?

    func field<Value>(_ keyPath: WritableKeyPath<CommandDraft, Value>, default value: Value) -> Binding<Value> {
        let draftID = draft?.id
        let fallback = draft?[keyPath: keyPath] ?? value
        return Binding(get: {
            self.draft?.id == draftID ? self.draft?[keyPath: keyPath] ?? fallback : fallback
        }, set: { value in
            guard self.draft?.id == draftID else { return }
            self.draft?[keyPath: keyPath] = value
        })
    }

    // Text fields finish editing after removal/dismissal; never retain an array-index binding.
    func stepBinding(_ step: CommandDraft.Step) -> Binding<CommandDraft.Step> {
        let draftID = draft?.id
        return Binding(get: {
            guard self.draft?.id == draftID else { return step }
            return self.draft?.steps.first { $0.id == step.id } ?? step
        }, set: { value in
            guard self.draft?.id == draftID,
                  let index = self.draft?.steps.firstIndex(where: { $0.id == step.id }) else { return }
            self.draft?.steps[index] = value
        })
    }

    func move(_ id: UUID, by offset: Int) {
        guard let index = draft?.steps.firstIndex(where: { $0.id == id }),
              let count = draft?.steps.count, (0..<count).contains(index + offset) else { return }
        draft?.steps.swapAt(index, index + offset)
    }

    func availableTools(including selected: String) -> [String] {
        Array(Set(CustomCommandRules.allowedNames(in: commands.flatMap { $0.actions.map(\.tool) }) + [selected]))
            .sorted { Self.actionTitle($0) < Self.actionTitle($1) }
    }
    static func actionTitle(_ tool: String) -> String {
        tool.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }
}

@MainActor
class CustomCommandsInteractor: ViewModelInteractor<CustomCommandsViewModel>, CustomCommandsHandler {
    @Injected(\.customCommands) private var store
    private var scope: CustomCommandStore.EditScope?

    @CancellableBuilder
    override func onLoad(viewModel: CustomCommandsViewModel) -> [AnyCancellable] {
        super.onLoad(viewModel: viewModel)
        scope = store.editScope
        store.$commands.sink { viewModel.commands = $0 }
    }

    @CancellableBuilder
    override func onViewAppear(viewModel: CustomCommandsViewModel) -> [AnyCancellable] {
        super.onViewAppear(viewModel: viewModel)
        Container.shared.realtimeService().recordCommandPanel(open: true)
        Task { await store.refresh() }
    }

    override func onViewDisappear(viewModel: CustomCommandsViewModel) {
        super.onViewDisappear(viewModel: viewModel)
        Container.shared.realtimeService().recordCommandPanel(open: false)
    }

    private func currentScope(viewModel: CustomCommandsViewModel) -> CustomCommandStore.EditScope? {
        guard let scope, store.editScope == scope else {
            viewModel.error = "The active profile changed or is signed out. Reopen Commands to continue."
            return nil
        }
        return scope
    }

    func edit(_ command: CustomCommand?, viewModel: CustomCommandsViewModel) {
        guard !viewModel.busy, let scope = currentScope(viewModel: viewModel) else { return }
        viewModel.editorError = nil
        viewModel.draft = .init(command: command, scope: scope)
    }

    func save(viewModel: CustomCommandsViewModel) {
        guard !viewModel.busy, let draft = viewModel.draft else { return }
        viewModel.busy = true
        viewModel.editorError = nil
        Task {
            defer { viewModel.busy = false }
            let result = await store.edit(expected: draft.original, scope: draft.scope, keyword: draft.phrase,
                label: draft.description, actions: draft.steps.map(\.action))
            switch result {
            case .saved: viewModel.draft = nil
            case .refused(let message), .failed(let message): viewModel.editorError = message
            }
        }
    }

    func setCommand(_ command: CustomCommand, enabled: Bool, viewModel: CustomCommandsViewModel) {
        guard !viewModel.busy, currentScope(viewModel: viewModel) != nil else { return }
        viewModel.busy = true
        Task {
            guard currentScope(viewModel: viewModel) != nil else { viewModel.busy = false; return }
            let result = await store.setEnabled(keyword: command.keyword, to: enabled)
            handle(result, viewModel: viewModel)
        }
    }

    func requestDelete(_ command: CustomCommand, viewModel: CustomCommandsViewModel) {
        viewModel.pendingDelete = command
        viewModel.showDeleteAlert = true
    }

    func confirmDelete(viewModel: CustomCommandsViewModel) {
        guard !viewModel.busy, let command = viewModel.pendingDelete,
              currentScope(viewModel: viewModel) != nil else { return }
        viewModel.pendingDelete = nil
        viewModel.busy = true
        Task {
            guard currentScope(viewModel: viewModel) != nil else { viewModel.busy = false; return }
            handle(await store.delete(keyword: command.keyword), viewModel: viewModel)
        }
    }

    private func handle(_ outcome: CustomCommandStore.Outcome, viewModel: CustomCommandsViewModel) {
        viewModel.busy = false
        switch outcome {
        case .saved: viewModel.error = nil
        case .refused(let message), .failed(let message): viewModel.error = message
        }
    }
}

@MainActor
struct CustomCommandsComponent {
    static func make(viewModel: CustomCommandsViewModel? = nil) -> some View {
        CustomCommandsView(viewModel: viewModel ?? CustomCommandsViewModel(), interactor: CustomCommandsInteractor())
    }
}
