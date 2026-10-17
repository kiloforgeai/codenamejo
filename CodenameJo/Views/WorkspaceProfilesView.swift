import Combine
import FactoryKit
import SwiftUI

@MainActor
protocol WorkspaceProfilesHandler {
    func reload(viewModel: WorkspaceProfilesViewModel)
    func choose(_ profile: WorkspaceProfile, viewModel: WorkspaceProfilesViewModel)
    func saveName(viewModel: WorkspaceProfilesViewModel)
    func delete(_ profile: WorkspaceProfile, viewModel: WorkspaceProfilesViewModel)
}

struct WorkspaceProfilesView<Interactor: ViewWithModelLifecycleObserver<WorkspaceProfilesViewModel> & WorkspaceProfilesHandler>: View {
    @StateObject var viewModel: WorkspaceProfilesViewModel
    @StateObject var interactor: Interactor

    /// Draws nothing in place: the picker is a toolbar item that accumulates up to the home screen bar,
    /// and the sheet stays in ordinary content, where a sheet can present from.
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .toolbar { pickerItem }
            .sheet(isPresented: $viewModel.showSheet) { management }
            .onChange(of: viewModel.showSheet) { _, isPresented in
                if isPresented { interactor.reload(viewModel: viewModel) }
            }
            .bind(observer: interactor, viewModel: viewModel)
    }

    // MARK: - The picker

    @ToolbarContentBuilder
    private var pickerItem: some ToolbarContent {
        if viewModel.available {
            ToolbarItem(placement: .principal) { picker }
        }
    }

    /// The same glass capsule the other home-screen chips wear, in the gap between
    /// Automations and the History pair.
    private var picker: some View {
        Button {
            viewModel.showSheet = true
        } label: {
            HStack(spacing: 7) {
                Group {
                    if viewModel.busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .frame(width: 16)
                Text(pickerName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.55)
            }
            .foregroundStyle(Theme.textPrimary)
            .tint(Theme.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .contentShape(Capsule())
            .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.busy)
        .animation(.snappy, value: viewModel.active?.id)
        .accessibilityIdentifier("profilePicker")
        .accessibilityLabel("Profile: \(viewModel.active?.name ?? "Personal")")
        .accessibilityHint("Switch or manage profiles")
    }

    /// Truncated here rather than by the label: a bar that cannot fit an item drops
    /// it whole rather than shrinking it, and a name may be 80 characters.
    private var pickerName: String {
        let name = viewModel.active?.name ?? "Personal"
        return name.count > 18 ? String(name.prefix(17)) + "…" : name
    }

    // MARK: - Management sheet

    private var management: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    title
                    List {
                        ProfileConnectionsSummaryComponent.make()
                        profilesSection
                        if let error = viewModel.error { errorSection(error) }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    // The list's own top inset would stack under the title's.
                    .contentMargins(.top, 0, for: .scrollContent)
                }
            }
            .disabled(viewModel.busy)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { viewModel.showSheet = false }
                        .accessibilityIdentifier("profilesDoneButton")
                }
            }
            .alert(viewModel.editing == nil ? "New profile" : "Rename profile", isPresented: $viewModel.showName) {
                TextField("Name", text: $viewModel.name)
                Button("Cancel", role: .cancel) {}
                Button("Save") { interactor.saveName(viewModel: viewModel) }
            }
            .alert("Delete Profile", isPresented: $viewModel.showDelete, presenting: viewModel.pendingDelete) { profile in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { interactor.delete(profile, viewModel: viewModel) }
            } message: { profile in
                let count = viewModel.deleteConnectionCount
                Text("“\(profile.name)” will be deleted and its \(count) connected email account\(count == 1 ? "" : "s") disconnected from the app. Notes and history stay on your account.")
            }
        }
    }

    /// House rule: the screen names itself in the content area, not in the bar. Above
    /// the list rather than inside it — a first section carries a margin of its own.
    private var title: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Profiles")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Keep your inboxes and conversations separate.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var profilesSection: some View {
        Section {
            ForEach(viewModel.profiles) { profile in
                Button { interactor.choose(profile, viewModel: viewModel) } label: {
                    profileRow(profile)
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.surface)
                .accessibilityIdentifier("selectProfile-\(profile.id)")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if viewModel.canDelete && !profile.isDefault {
                        Button(role: .destructive) { requestDelete(profile) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .accessibilityIdentifier("deleteProfile-\(profile.id)")
                    }
                    Button { startRename(profile) } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(Theme.textSecondary)
                }
                .contextMenu {
                    Button("Rename", systemImage: "pencil") { startRename(profile) }
                    if viewModel.canDelete && !profile.isDefault {
                        Button("Delete", systemImage: "trash", role: .destructive) { requestDelete(profile) }
                    }
                }
            }
            Button { startCreate() } label: { actionRow("New profile", icon: "plus.circle.fill") }
                .buttonStyle(.plain)
                .listRowBackground(Theme.surface)
                .accessibilityIdentifier("createProfile")
        }
    }

    private func profileRow(_ profile: WorkspaceProfile) -> some View {
        let isActive = profile.id == viewModel.active?.id
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(isActive ? Theme.textPrimary : Theme.surfaceSecondary)
                Text(initial(of: profile.name))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isActive ? Theme.background : Theme.textSecondary)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if isActive {
                    Text(activeDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            if viewModel.switchingTo == profile.id {
                ProgressView().controlSize(.small)
            } else if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    /// Only the active profile's inboxes are fetched, so only it can count them.
    private var activeDetail: String {
        switch viewModel.connections.count {
        case 0: return "Active · no inbox connected"
        case 1: return "Active · 1 inbox"
        case let count: return "Active · \(count) inboxes"
        }
    }


    private func errorSection(_ error: String) -> some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.error)
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.vertical, 3)
            .listRowBackground(Theme.surface)
            Button("Try again") {
                if let active = viewModel.active { interactor.choose(active, viewModel: viewModel) }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .listRowBackground(Theme.surface)
        }
    }

    private func actionRow(_ title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 24)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func initial(of name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "•"
    }

    private func startRename(_ profile: WorkspaceProfile) {
        viewModel.editing = profile
        viewModel.name = profile.name
        viewModel.showName = true
    }

    private func startCreate() {
        viewModel.editing = nil
        viewModel.name = ""
        viewModel.showName = true
    }

    private func requestDelete(_ profile: WorkspaceProfile) {
        viewModel.pendingDelete = profile
        viewModel.showDelete = true
    }
}

@MainActor
class WorkspaceProfilesViewModel: ViewModel {
    @Published var available = false
    @Published var canDelete = false
    @Published var profiles: [WorkspaceProfile] = []
    @Published var active: WorkspaceProfile?
    @Published var connections: [WorkspaceProfileConnection] = []
    @Published var busy = false
    /// Which row the spinner belongs to while a switch is in flight.
    @Published var switchingTo: String?
    @Published var error: String?
    @Published var showSheet = false
    @Published var showName = false
    @Published var name = ""
    @Published var editing: WorkspaceProfile?
    @Published var showDelete = false
    @Published var pendingDelete: WorkspaceProfile?
    /// How many inboxes the pending deletion removes, for the alert. Fetched by the interactor
    /// for a non-active profile; 0 while in flight.
    @Published var deleteConnectionCount = 0
}

@MainActor
final class WorkspaceProfilesInteractor: ViewModelInteractor<WorkspaceProfilesViewModel>, WorkspaceProfilesHandler {
    @Injected(\.workspaceProfiles) private var profiles
    @Injected(\.backend) private var backend

    @CancellableBuilder
    override func onLoad(viewModel: WorkspaceProfilesViewModel) -> [AnyCancellable] {
        super.onLoad(viewModel: viewModel)
        profiles.$profiles.sink { viewModel.profiles = $0 }
        profiles.$selected.sink { viewModel.active = $0 }
        profiles.$connections.sink { viewModel.connections = $0 }
        profiles.$capabilities.sink { viewModel.available = $0.management; viewModel.canDelete = $0.deletion }
        profiles.$isSwitching.sink { viewModel.busy = $0 }
        profiles.$error.sink { viewModel.error = $0; if $0 != nil { viewModel.showSheet = true } }
        profiles.$needsConnection.sink { if $0 { viewModel.showSheet = true } }
        backend.$isSignedIn.sink { [weak self] signedIn in if signedIn { self?.reload(viewModel: viewModel) } }
        viewModel.$pendingDelete.sink { [weak self] pending in self?.countConnections(of: pending, viewModel: viewModel) }
    }

    func reload(viewModel: WorkspaceProfilesViewModel) {
        Task {
            do { try await profiles.load() }
            catch WorkspaceProfileError.unavailable { viewModel.available = false }
            catch { viewModel.error = error.localizedDescription }
        }
    }
    func choose(_ profile: WorkspaceProfile, viewModel: WorkspaceProfilesViewModel) {
        Task {
            viewModel.switchingTo = profile.id
            await profiles.choose(profile)
            viewModel.switchingTo = nil
            if profiles.error == nil && !profiles.needsConnection { viewModel.showSheet = false }
        }
    }
    func saveName(viewModel: WorkspaceProfilesViewModel) {
        Task {
            do {
                if let editing = viewModel.editing { try await profiles.rename(editing, name: viewModel.name) }
                else { try await profiles.create(viewModel.name) }
            } catch { viewModel.error = error.localizedDescription }
        }
    }
    func delete(_ profile: WorkspaceProfile, viewModel: WorkspaceProfilesViewModel) {
        Task { await profiles.delete(profile) }
    }
    private func countConnections(of profile: WorkspaceProfile?, viewModel: WorkspaceProfilesViewModel) {
        guard let profile else { return }
        if profile.id == profiles.selected?.id { viewModel.deleteConnectionCount = profiles.connections.count; return }
        Task {
            do { viewModel.deleteConnectionCount = try await profiles.connections(of: profile.id).count }
            catch { viewModel.deleteConnectionCount = 0; viewModel.error = error.localizedDescription }
        }
    }
}

@MainActor
struct WorkspaceProfilesComponent {
    static func make(viewModel: WorkspaceProfilesViewModel? = nil) -> some View {
        WorkspaceProfilesView(viewModel: viewModel ?? WorkspaceProfilesViewModel(), interactor: WorkspaceProfilesInteractor())
    }
}
