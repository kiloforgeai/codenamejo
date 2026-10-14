import Combine
import FactoryKit
import SwiftUI

@MainActor
protocol MessagesSettingsHandler {
    func requestContacts(viewModel: MessagesSettingsViewModel)
    func setMessagingReady(_ ready: Bool, viewModel: MessagesSettingsViewModel)
    func openSetupURL(_ url: URL?, viewModel: MessagesSettingsViewModel)
}

struct MessagesSettingsScreen<Interactor: ViewWithModelLifecycleObserver<MessagesSettingsViewModel> & MessagesSettingsHandler>: View {
    @StateObject var viewModel: MessagesSettingsViewModel
    @StateObject var interactor: Interactor

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            List {
                Section {
                    Text("Ask Jo to read unread texts from the past 24 hours or send a text to a contact.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .listRowBackground(Theme.surface)
                } header: {
                    SettingsRow.header("Messages")
                }

                Section {
                    contactsPermissionRow
                } header: {
                    SettingsRow.header("1. Contacts")
                }

                Section {
                    ForEach(ShortcutActionRunner.Channel.all) { channel in
                        setupRow(
                            channel.shortcutName,
                            detail: "Reads unread texts and sends SMS or iMessage texts.",
                            button: channel.installURL == nil ? "Open Shortcuts" : "Install Jo Messages",
                            accessibilityID: "installJoMessages"
                        ) {
                            interactor.openSetupURL(channel.installURL ?? ShortcutActionRunner.shortcutsURL, viewModel: viewModel)
                        }
                        setupRow(
                            "Jo Messages Trigger",
                            detail: "Starts Jo Messages when Jo requests it. After installing, turn on Automation in the trigger's settings.",
                            button: channel.automationInstallURL == nil ? "Open Automations" : "Install Jo Messages Trigger",
                            accessibilityID: "installJoMessagesTrigger"
                        ) {
                            interactor.openSetupURL(channel.automationInstallURL ?? ShortcutActionRunner.automationsURL, viewModel: viewModel)
                        }
                    }
                } header: {
                    SettingsRow.header("2. Install both shortcuts")
                }

                Section {
                    Toggle("Messages setup is ready", isOn: Binding(
                        get: { viewModel.messagingReady },
                        set: { interactor.setMessagingReady($0, viewModel: viewModel) }))
                        .font(.body)
                        .tint(Theme.toggleOn)
                        .accessibilityIdentifier("messagingSetupReady")
                        .listRowBackground(Theme.surface)
                } header: {
                    SettingsRow.header("3. Enable Messages")
                } footer: {
                    SettingsRow.footer("Turn this on after both shortcuts are installed and the trigger's Automation is enabled. Start a new call after setup. The first time Shortcuts asks to share messages with Jo or to send a message, tap Always Allow so later requests run hands-free.")
                }

                if let error = viewModel.setupError {
                    Section {
                        Text(error)
                            .font(.body)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("messagesSetupError")
                            .listRowBackground(Theme.surface)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .bind(observer: interactor, viewModel: viewModel)
    }

    private var contactsPermissionRow: some View {
        let permission = viewModel.contactsPermission
        let detail: String = switch permission {
        case .allowed: "Allowed. Jo can find a contact's phone number when you say a name."
        case .limited: "Name lookup needs full Contacts access. Allow it in Settings, or use an exact phone number."
        case .notAsked: "Let Jo find a contact's phone number when you ask to send a text."
        case .denied: "Contacts access is off. Enable it for Codename Jo in Settings."
        }
        let status: String = switch permission {
        case .allowed: "Allowed"
        case .limited: "Limited access"
        case .notAsked: "Not requested"
        case .denied: "Not allowed"
        }
        return setupRow(
            "Contact access",
            detail: detail,
            button: permission == .notAsked ? "Allow Contacts" : "Manage Contacts",
            accessibilityID: "messagesContactsPermission",
            status: status
        ) {
            interactor.requestContacts(viewModel: viewModel)
        }
    }

    private func setupRow(
        _ title: String, detail: String, button: String?,
        accessibilityID: String, status: String? = nil, action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                if let status {
                    Text("Status: \(status)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .accessibilityIdentifier("messagesContactsStatus")
                }
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let button {
                Button(action: action) {
                    Text(button)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .accessibilityIdentifier(accessibilityID)
            }
        }
        .padding(.vertical, 8)
        .listRowBackground(Theme.surface)
    }
}

@MainActor
struct MessagesSettingsComponent {
    static func make() -> some View {
        MessagesSettingsScreen(viewModel: MessagesSettingsViewModel(), interactor: MessagesSettingsInteractor())
    }
}

@MainActor
class MessagesSettingsViewModel: ViewModel {
    @Published var contactsPermission: PhoneContacts.Permission = .notAsked
    @Published var messagingReady = false
    @Published var setupError: String?
}

@MainActor
class MessagesSettingsInteractor: ViewModelInteractor<MessagesSettingsViewModel> {
    @Injected(\.phoneContacts) private var contacts
    @Injected(\.shortcutActions) private var shortcuts

    @CancellableBuilder
    override func onViewAppear(viewModel: MessagesSettingsViewModel) -> [AnyCancellable] {
        super.onViewAppear(viewModel: viewModel)
        viewModel.contactsPermission = contacts.permission
        viewModel.messagingReady = shortcuts.isConfigured
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self, weak viewModel] _ in
                guard let self, let viewModel else { return }
                viewModel.contactsPermission = self.contacts.permission
                viewModel.messagingReady = self.shortcuts.isConfigured
            }
    }
}

extension MessagesSettingsInteractor: MessagesSettingsHandler {
    func requestContacts(viewModel: MessagesSettingsViewModel) {
        Task {
            viewModel.setupError = nil
            do { try await contacts.requestOrOpenSettings() }
            catch { viewModel.setupError = error.localizedDescription }
            viewModel.contactsPermission = contacts.permission
        }
    }

    func setMessagingReady(_ ready: Bool, viewModel: MessagesSettingsViewModel) {
        shortcuts.isConfigured = ready
        viewModel.messagingReady = shortcuts.isConfigured
        if !ready { shortcuts.cancel() }
    }

    func openSetupURL(_ url: URL?, viewModel: MessagesSettingsViewModel) {
        Task {
            guard let url, await UIApplication.shared.open(url) else {
                viewModel.setupError = "Jo could not open the setup link. Try again from Settings."
                return
            }
            viewModel.setupError = nil
        }
    }
}

#if DEBUG
import Prefire

#Preview("Messages settings") {
    NavigationStack {
        MessagesSettingsComponent.make()
    }
    .prefireIgnored()
}
#endif
