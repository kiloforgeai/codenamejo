import Combine
import FactoryKit
import SwiftUI

// Debug builds only, like the Admin section that draws it.
#if DEBUG
@MainActor
protocol ProfileDossierAdminHandler {
    func setEnabled(_ enabled: Bool, viewModel: ProfileDossierAdminViewModel)
}

struct ProfileDossierAdminToggle<Interactor: ViewWithModelLifecycleObserver<ProfileDossierAdminViewModel> & ProfileDossierAdminHandler>: View {
    @StateObject var viewModel: ProfileDossierAdminViewModel
    @StateObject var interactor: Interactor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { viewModel.enabled }, set: { interactor.setEnabled($0, viewModel: viewModel) })) {
                SettingsRow.label("Profile dossier", icon: "person.text.rectangle",
                    detail: "Let Jo learn about you from this profile's calls, on your OpenAI key, and bring it to the next call.")
            }
            .disabled(viewModel.busy || !viewModel.loaded)
            .tint(Theme.toggleOn)
            .accessibilityIdentifier("profileDossierToolToggle")
            if viewModel.busy { ProgressView() }
            if let error = viewModel.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .listRowBackground(Theme.surface)
        .bind(observer: interactor, viewModel: viewModel)
    }
}

@MainActor
struct ProfileDossierAdminComponent {
    static func make() -> some View {
        ProfileDossierAdminToggle(viewModel: ProfileDossierAdminViewModel(), interactor: ProfileDossierAdminInteractor())
    }
}

@MainActor
final class ProfileDossierAdminViewModel: ViewModel {
    @Published var enabled = false
    @Published var busy = false
    @Published var loaded = false
    @Published var profileName = "the selected profile"
    @Published var error: String?
}

@MainActor
final class ProfileDossierAdminInteractor: ViewModelInteractor<ProfileDossierAdminViewModel>, ProfileDossierAdminHandler {
    @Injected(\.workspaceProfiles) private var profiles
    private var generation = 0
    private var loadedProfile: String?

    @CancellableBuilder
    override func onViewAppear(viewModel: ProfileDossierAdminViewModel) -> [AnyCancellable] {
        super.onViewAppear(viewModel: viewModel)
        profiles.$selected.map { $0?.id }.removeDuplicates().sink { [weak self] _ in
            self?.load(viewModel: viewModel)
        }
    }

    private func load(viewModel: ProfileDossierAdminViewModel) {
        generation += 1
        let version = generation
        loadedProfile = nil
        viewModel.loaded = false
        viewModel.enabled = false
        viewModel.error = nil
        viewModel.busy = false
        guard let profile = profiles.selected else { return }
        viewModel.profileName = profile.name
        Task { [weak self] in
            do {
                let enabled = try await self?.profiles.dossierEnabled(for: profile.id) ?? false
                guard let self, version == generation else { return }
                viewModel.enabled = enabled
                viewModel.loaded = true
                loadedProfile = profile.id
            } catch {
                guard let self, version == generation else { return }
                viewModel.error = "Could not load the dossier setting. Reopen Settings to retry."
            }
        }
    }

    func setEnabled(_ enabled: Bool, viewModel: ProfileDossierAdminViewModel) {
        guard !viewModel.busy, viewModel.loaded, let profileId = loadedProfile,
              profiles.selected?.id == profileId else { return }
        viewModel.error = nil
        viewModel.busy = true
        Task {
            defer { viewModel.busy = false }
            do {
                try await profiles.setDossierEnabled(enabled, for: profileId)
                viewModel.enabled = enabled
            } catch {
                viewModel.error = "Could not save the dossier setting. Try again."
            }
        }
    }
}
#endif
