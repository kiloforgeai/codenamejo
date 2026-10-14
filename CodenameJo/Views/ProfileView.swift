import AVFoundation
import Combine
import FactoryKit
import SwiftUI

/// What Settings can ask for: everything that talks to a service or changes server state.
protocol ProfileViewHandler {
    func requestSignOut(viewModel: ProfileViewModel)
    func confirmSignOut(viewModel: ProfileViewModel)
    func requestDeleteAccount(viewModel: ProfileViewModel)
    func confirmDeleteAccount(viewModel: ProfileViewModel)
    func voiceNotesSwitched(viewModel: ProfileViewModel)
    func connectGoogle(viewModel: ProfileViewModel)
    func reconnectGoogle(_ email: String, viewModel: ProfileViewModel)
    func removeGoogle(_ email: String, viewModel: ProfileViewModel)
    func connectSlack(viewModel: ProfileViewModel)
    func removeSlack(_ workspace: String, viewModel: ProfileViewModel)
    func connectGithub(viewModel: ProfileViewModel)
    func cancelGithubConnect(viewModel: ProfileViewModel)
    func openGithubVerification(viewModel: ProfileViewModel)
    func removeGithub(_ login: String, viewModel: ProfileViewModel)
    func connectNotionMcp(viewModel: ProfileViewModel)
    func removeNotionMcp(_ workspace: String, viewModel: ProfileViewModel)
    func connectGranola(viewModel: ProfileViewModel)
    func reconnectGranola(_ account: String, viewModel: ProfileViewModel)
    func removeGranola(_ account: String, viewModel: ProfileViewModel)
    func beginAddCustomMCP(viewModel: ProfileViewModel)
    func cancelCustomMCPForm(viewModel: ProfileViewModel)
    func submitCustomMCPForm(viewModel: ProfileViewModel)
    func reconnectCustomMCP(_ server: CustomMCPServerStatus, viewModel: ProfileViewModel)
    func refreshCustomMCPTools(_ server: CustomMCPServerStatus, viewModel: ProfileViewModel)
    func removeCustomMCP(_ server: CustomMCPServerStatus, viewModel: ProfileViewModel)
    func hasCalendar(_ email: String) -> Bool
    func hasFilters(_ email: String) -> Bool
    func confirmRemoveGoogle(viewModel: ProfileViewModel)
    func hasDeviceGrant(_ email: String) -> Bool
    func handleNotificationRow(viewModel: ProfileViewModel)
    func refreshConnections()
    func refresh(viewModel: ProfileViewModel)
}

struct ProfileView<Interactor: ViewWithModelLifecycleObserver<ProfileViewModel> & ProfileViewHandler>: View {
    @StateObject var viewModel: ProfileViewModel
    @StateObject var interactor: Interactor
    /// Pages back to the voice screen; `dismiss` covers a presentation that passed nothing.
    var onClose: (() -> Void)?
    @ScaledMetric private var iconWidth: CGFloat = 24
    @Environment(\.dismiss) private var dismiss
    /// Appearance is bound straight to its control: the app root reads the same
    /// key, so a view model copy would be a second source of truth.
    @AppStorage(AppearanceSetting.storageKey) private var appearance = AppearanceSetting.system

    /// Must match `DraftsOnly.isOn`'s default, or the switch shows a state the session does not use.
    @AppStorage(DraftsOnly.storageKey) private var draftsOnly = true

    /// Per-inbox answers that narrow `draftsOnly`. Empty means none answered, and a missing
    /// entry reads as the account-wide fallback.
    @AppStorage(DraftsOnly.byAccountStorageKey) private var draftsOnlyByAccount = Data()

    /// Must match `MailHeadersOnly.isOn`'s default, or the switch describes behaviour nobody gets.
    @AppStorage(MailHeadersOnly.storageKey) private var mailHeadersOnly = false

    /// Optional because the default is the account's `voice_notes` column, so absent
    /// (*never chosen*) differs from *chosen false*.
    @AppStorage(VoiceSettings.Key.voiceNotes) private var voiceNotesChoice: Bool?
    @AppStorage(LocalVoice.storageKey) private var localVoice = LocalVoice.paradee.rawValue
    @ObservedObject private var localSpeech = Container.shared.localSpeech()
    @AppStorage(LocalVoiceSettings.allLocalKey) private var allLocal = false
    @AppStorage(VoiceNotesDefault.ownerKey) private var voiceNotesOwner: String?

    private var voiceNotes: Binding<Bool> {
        Binding(
            get: { VoiceNotesDefault.effective(voiceNotesChoice, owner: voiceNotesOwner) },
            set: {
                voiceNotesChoice = $0
                interactor.voiceNotesSwitched(viewModel: viewModel)
            }
        )
    }

    private var appVersion: String { AppInfo.appVersion }

    var body: some View {
        Group {
            if onClose == nil {
                NavigationStack { screen }
            } else {
                screen
            }
        }
        .bind(observer: interactor, viewModel: viewModel)
    }

    private var screen: some View {
        Group {
            ZStack {
                Theme.background.ignoresSafeArea()

                List {
                    Text("Settings")
                        .font(.title2.bold())
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))

                    accountHeaderSection
                    voiceSection
                    Section {
                        NavigationLink("OpenAI key") { OpenAIKeyView() }
                            .accessibilityIdentifier("settings_openai_key")
                    } footer: {
                        Text("Calls are billed to your own OpenAI account.")
                    }
                    Section {
                        NavigationLink("Commands") { CustomCommandsComponent.make() }
                            .accessibilityIdentifier("settings_commands")
                    } footer: {
                        Text("Words you've saved by voice, and the steps each one runs.")
                    }
                    notificationsSection
                    // Only drawn once there is a mailbox to list.
                    if !viewModel.gmailAccounts.isEmpty { sendingSection }
                    // The notification automation trigger this relies on is iOS 27's.
                    if #available(iOS 27, *) { messagesSection }
                    privacySection
                    appearanceSection
                    legalSection
                    aboutSection
                    signOutSection
                    dangerZoneSection
                    #if DEBUG
                    // Last: the staff block sits below Delete Account.
                    AdminSectionComponent.make()
                    #endif
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 700)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Settings is the pane right of the voice screen, so the chevron points
                // back the way the swipe goes; `dismiss` covers a sheet presentation.
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if let onClose { onClose() } else { dismiss() }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("settingsCloseButton")
                }
            }
            .alert("Sign Out", isPresented: $viewModel.showSignOutAlert) {
                Button("Sign Out", role: .destructive) {
                    interactor.confirmSignOut(viewModel: viewModel)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("You will need to sign back in to use Codename Jo.")
            }
            .alert("Delete Account", isPresented: $viewModel.showDeleteAlert) {
                Button("Delete Account", role: .destructive) {
                    interactor.confirmDeleteAccount(viewModel: viewModel)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will permanently delete all your data. This action cannot be undone.")
            }
            .alert("Couldn't Delete Account", isPresented: $viewModel.deleteFailed) {
                Button("Try Again") { interactor.confirmDeleteAccount(viewModel: viewModel) }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Some of your data could not be deleted. You are still signed in — "
                    + "please try again.")
            }
        }
    }

    // MARK: - Account header

    /// Who is signed in, first on the screen. Hidden until the session lookup answers.
    @ViewBuilder
    private var accountHeaderSection: some View {
        if let email = viewModel.accountEmail {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(Theme.accent)
                        .font(.largeTitle)
                    VStack(alignment: .leading, spacing: 2) {
                        if let name = viewModel.accountName, !name.isEmpty {
                            Text(name)
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            Text(email)
                                .font(.footnote)
                                .foregroundStyle(Theme.textTertiary)
                        } else {
                            Text(email)
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
                .padding(.vertical, 2)
                .listRowBackground(Theme.surface)
                .accessibilityIdentifier("accountHeader")
            } header: {
                SettingsRow.header("Account")
                    .textCase(nil)
            }
        }
    }

    // MARK: - Voice

    /// The voice decisions that belong to the user: whether the Note action is available.
    private var voiceSection: some View {
        Section {
            // `VoiceSettings.voiceNotes` says what off stops and why turning it back on takes a relaunch.
            Toggle(isOn: voiceNotes) {
                SettingsRow.label(
                    "Voice notes",
                    icon: "mic.badge.plus",
                    detail: "Shows the Note button on the main screen and enables Leave "
                        + "a Note from the Action Button, Lock Screen, Control Center, "
                        + "Siri, and Shortcuts. Notes can be recorded without signal and "
                        + "send themselves later. Off, anything already recorded waits "
                        + "until you switch this back on. This phone only."
                )
            }
            .tint(Theme.toggleOn)
            .accessibilityIdentifier("voiceNotesToggle")
            .listRowBackground(Theme.surface)

            Toggle(isOn: $allLocal) {
                SettingsRow.label(
                    "Fully local mode",
                    icon: "iphone.and.arrow.forward",
                    detail: "Everything stays on this phone: speech recognition, Apple's on-device "
                        + "model and the phone's own voice. Nothing goes to OpenAI. Jo can still "
                        + "go through your inbox with you — archive, delete, mark spam, file under "
                        + "a label, draft a reply — and read or add to your calendar, talking to "
                        + "Google directly. Off, the phone's "
                        + "voice still steps in on its own whenever the live call can't connect "
                        + "or drops, keeping your mail and calendar while there's a connection."
                )
            }
            .tint(Theme.toggleOn)
            .accessibilityIdentifier("allLocalToggle")
            .listRowBackground(Theme.surface)

            VStack(alignment: .leading, spacing: 6) {
                Picker("Local voice", selection: $localVoice) {
                    ForEach(LocalVoice.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
                Text(localVoiceDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                Button("Hear a sample") {
                    localSpeech.preview(LocalVoice(rawValue: localVoice) ?? .paradee)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
            }
            .accessibilityIdentifier("localVoicePicker")
            .listRowBackground(Theme.surface)
        } header: {
            SettingsRow.header("Voice")
        }
    }

    /// Says whether Kokoro's voice is on this phone yet, because until it has downloaded the
    /// system voice speaks in its place.
    private var localVoiceDetail: String {
        let choice = LocalVoice(rawValue: localVoice) ?? .paradee
        guard choice == .paradee else {
            let tier = LocalVoiceSettings.pick(from: LocalVoiceSettings.installed())?.tier ?? "Compact"
            return "The best English voice on this phone (\(tier))."
        }
        switch localSpeech.paradeeState {
        case .ready: return "On this phone, and works with no connection."
        case .idle, .loading: return "Downloading (about 10 MB). The system voice speaks until it's ready."
        case .failed: return "Couldn't download, so the system voice speaks instead. Tap Hear a sample to retry."
        }
    }

    // MARK: - Notifications

    /// Not a Toggle: only iOS can change the permission once asked, so the row shows the state
    /// and offers the one action available (ask, open Settings, or none).
    private var notificationsSection: some View {
        Section {
            Button {
                interactor.handleNotificationRow(viewModel: viewModel)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: viewModel.notificationsEnabled ? "bell.badge.fill" : "bell.slash")
                        .font(.body)
                        .foregroundStyle(viewModel.notificationsEnabled ? Theme.accent : Theme.textSecondary)
                        .frame(width: iconWidth)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.notificationsTitle)
                            .font(.body)
                            .foregroundStyle(Theme.textPrimary)
                        Text(viewModel.notificationsDetail)
                            .font(.footnote)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    if viewModel.notificationsBusy {
                        ProgressView().controlSize(.small)
                    } else if !viewModel.notificationsEnabled {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            // Inert once granted: there is nothing left to ask for.
            .disabled(viewModel.notificationsEnabled || viewModel.notificationsBusy)
            .listRowBackground(Theme.surface)
            .accessibilityIdentifier("notificationsRow")

        } header: {
            SettingsRow.header("Notifications")
                .textCase(nil)
        } footer: {
            Text("Handed-off work can carry its answer back here.")
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Sending

    /// Whether each connected inbox sends mail or only writes drafts. See `DraftsOnly`.
    /// No account-wide switch: new inboxes are answered for when they connect (`ConnectionsService.claimNewInboxes`).
    private var sendingSection: some View {
        Section {
            ForEach(viewModel.gmailAccounts, id: \.self) { email in
                let isDrafting = DraftsOnly.isOn(
                    for: email, in: draftsOnlyByAccount, fallback: draftsOnly)
                Toggle(isOn: sendsBinding(for: email)) {
                    SettingsRow.label(
                        email,
                        icon: isDrafting ? "tray.and.arrow.down" : "paperplane",
                        detail: isDrafting
                            ? "Mail waits in your Drafts until you send it"
                            : "Mail goes out as soon as you ask"
                    )
                }
                .tint(Theme.toggleOn)
                .accessibilityIdentifier("sendsToggle_\(email)")
                .listRowBackground(Theme.surface)
            }
        } header: {
            SettingsRow.header("Sending")
        } footer: {
            SettingsRow.footer(
                "Each inbox decides for itself. On, mail goes the moment you ask. Off, the "
                    + "default: nothing is sent from it — replies and forwards are written into "
                    + "that mailbox's Gmail Drafts and you send them yourself. A newly "
                    + "connected inbox always starts off. Reading, searching, archiving and "
                    + "labelling are unaffected either way."
            )
        }
    }

    /// On means the inbox sends, the inverse of the stored `draftsOnly` answer. Goes through the
    /// `@AppStorage` value so SwiftUI registers the dependency and the row redraws.
    private func sendsBinding(for email: String) -> Binding<Bool> {
        Binding(
            get: {
                !DraftsOnly.isOn(for: email, in: draftsOnlyByAccount, fallback: draftsOnly)
            },
            set: {
                draftsOnlyByAccount =
                    DraftsOnly.setting(!$0, for: email, in: draftsOnlyByAccount)
            }
        )
    }

    /// Reading and sending texts through the two Jo Messages shortcuts.
    private var messagesSection: some View {
        Section {
            NavigationLink {
                MessagesSettingsComponent.make()
            } label: {
                SettingsRow.label(
                    "Messages",
                    icon: "message",
                    detail: "Read unread texts, send a text, and set up the two shortcuts."
                )
            }
            .accessibilityIdentifier("settingsMessagesRow")
            .listRowBackground(Theme.surface)
        } header: {
            SettingsRow.header("Messages")
        }
    }

    /// Headers only: this phone never asks Google for a message body.
    private var privacySection: some View {
        Section {
            Toggle(isOn: $mailHeadersOnly) {
                SettingsRow.label(
                    "Headers only",
                    icon: mailHeadersOnly ? "lock.doc" : "doc.text",
                    detail: mailHeadersOnly
                        ? "Jo sees senders, subjects and dates — never the body"
                        : "Jo can read the body of a message when you ask"
                )
            }
            .tint(Theme.toggleOn)
            .accessibilityIdentifier("mailHeadersOnlyToggle")
            .listRowBackground(Theme.surface)
        } header: {
            SettingsRow.header("Privacy")
        } footer: {
            SettingsRow.footer(
                "On, the body of an email is never fetched from Gmail at all — not by us "
                    + "and not by this phone — so nothing from it can reach an AI model. Jo "
                    + "can still triage, file, archive, label, forward and send: she works "
                    + "from who wrote to you and what the subject says. She cannot summarise "
                    + "a message, answer what it said, or read an attachment, and she will "
                    + "say so rather than guess."
            )
        }
    }

    // MARK: - Appearance

    /// System / Light / Dark. Every `Theme` color has both variants, so pinning is safe;
    /// the override is applied once, at the window root in `CodenameJoApp`.
    private var appearanceSection: some View {
        Section {
            Picker(selection: $appearance) {
                ForEach(AppearanceSetting.allCases) { setting in
                    Text(setting.label).tag(setting)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: iconWidth)
                    Text("Theme")
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.textSecondary)
            .listRowBackground(Theme.surface)
            .accessibilityIdentifier("appearancePicker")
        } header: {
            SettingsRow.header("Appearance")
                .textCase(nil)
        } footer: {
            Text("System follows your phone's light or dark setting.")
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Legal

    private var legalSection: some View {
        Section {
            if let privacyURL = URL(string: "https://codenamejo.com/privacy") {
                Link(destination: privacyURL) {
                    HStack {
                        Image(systemName: "hand.raised.fill")
                            .foregroundStyle(Theme.textSecondary)
                            .font(.body)
                        Text("Privacy Policy")
                            .font(.body)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.footnote)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .listRowBackground(Theme.surface)
                .accessibilityIdentifier("privacyPolicyLink")
            }
            if let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") {
                Link(destination: termsURL) {
                    HStack {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(Theme.textSecondary)
                            .font(.body)
                        Text("Terms of Use")
                            .font(.body)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.footnote)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .listRowBackground(Theme.surface)
                .accessibilityIdentifier("termsOfUseLink")
            }
            NavigationLink {
                AcknowledgementsView()
            } label: {
                HStack {
                    Image(systemName: "heart.text.square")
                        .foregroundStyle(Theme.textSecondary)
                        .font(.body)
                    Text("Acknowledgements")
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .listRowBackground(Theme.surface)
            .accessibilityIdentifier("acknowledgementsLink")
        } header: {
            SettingsRow.header("Legal")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            if let reviewURL = AppInfo.writeReviewURL {
                Link(destination: reviewURL) {
                    HStack {
                        Image(systemName: "star")
                            .foregroundStyle(Theme.textSecondary)
                            .font(.body)
                        Text("Rate Codename Jo")
                            .font(.body)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.footnote)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .listRowBackground(Theme.surface)
                .accessibilityIdentifier("rateAppLink")
            }
            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(Theme.textSecondary)
                    .font(.body)
                Text("Version")
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(appVersion)
                    .font(.body)
                    .foregroundStyle(Theme.textTertiary)
            }
            .listRowBackground(Theme.surface)
            .accessibilityIdentifier("versionRow")
        } header: {
            SettingsRow.header("About")
        }
    }

    // MARK: - Sign out

    /// Paired with Delete Account at the bottom; the header section is identity.
    private var signOutSection: some View {
        Section {
            Button {
                interactor.requestSignOut(viewModel: viewModel)
            } label: {
                HStack {
                    Image(systemName: "arrow.right.square")
                        .foregroundStyle(Theme.warning)
                        .font(.body)
                    Text("Sign Out")
                        .font(.body)
                        .foregroundStyle(Theme.warning)
                    Spacer()
                }
            }
            .listRowBackground(Theme.surface)
            .accessibilityIdentifier("signOutButton")
        }
    }

    // MARK: - Danger zone

    /// Delete Account sits alone, apart from Sign Out, so the irreversible action takes a deliberate scroll.
    private var dangerZoneSection: some View {
        Section {
            Button {
                interactor.requestDeleteAccount(viewModel: viewModel)
            } label: {
                HStack {
                    Image(systemName: "trash.fill")
                        .foregroundStyle(Theme.error)
                        .font(.body)
                    Text("Delete Account")
                        .font(.body)
                        .foregroundStyle(Theme.error)
                    Spacer()
                }
            }
            .listRowBackground(Theme.surface)
            .accessibilityIdentifier("deleteAccountButton")
        } header: {
            Text("Danger Zone")
                .font(.headline)
                .foregroundStyle(Theme.error)
                .textCase(nil)
        } footer: {
            Text("Permanently deletes your account and everything stored with it. This cannot be undone.")
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

// MARK: - Component

@MainActor
struct ProfileViewComponent {
    @ViewBuilder
    static func make(
        viewModel: ProfileViewModel? = nil,
        interactor: ProfileViewInteractor? = nil,
        onClose: (() -> Void)? = nil
    ) -> some View {
        ProfileView(viewModel: viewModel ?? ProfileViewModel(), interactor: interactor ?? ProfileViewInteractor(), onClose: onClose)
    }
}

// MARK: - View model

@MainActor
final class ProfileViewModel: ViewModel {
    /// Who is signed in, shown at the top of the screen. Nil until the session
    /// lookup answers — the header section hides rather than showing a blank.
    @Published var accountEmail: String?
    @Published var accountName: String?
    @Published var gmailAvailable = false
    @Published var gmailAccounts: [String] = []
    /// Connected Google accounts whose grant was revoked. Not a missing scope —
    /// see `ConnectionsService.gmailNeedsReauth`.
    @Published var gmailNeedsReauth: [String] = []
    @Published var githubAvailable = false
    @Published var githubAccounts: [String] = []
    /// Logins GitHub stopped honouring. See `ConnectionsService.githubNeedsReauth`.
    @Published var githubNeedsReauth: [String] = []
    /// The device-flow code on screen while a GitHub sign-in waits for it.
    @Published var githubPendingCode: GitHubDeviceFlow.Code?
    @Published var slackAvailable = false
    @Published var slackAccounts: [String] = []
    @Published var slackNeedsReauth: [String] = []
    @Published var notionMcpAvailable = false
    @Published var notionMcpAccounts: [String] = []
    /// Workspaces whose MCP credential was rejected and needs the user. Not the
    /// same as "expired" — see `ConnectionsService.notionMcpNeedsReauth`.
    @Published var notionMcpNeedsReauth: [String] = []
    @Published var granolaAvailable = false
    @Published var granolaAccounts: [String] = []
    /// Accounts whose Granola refresh was refused; see `ConnectionsService.granolaNeedsReauth`.
    @Published var granolaNeedsReauth: [String] = []
    @Published var customMCPAvailable = false
    @Published var customMCPServers: [CustomMCPServerStatus] = []
    /// The add-or-reconnect sheet and its draft. `customMCPReconnecting` is the server whose
    /// token is being replaced; nil means the draft is a new server.
    @Published var showCustomMCPForm = false
    @Published var customMCPReconnecting: CustomMCPServerStatus?
    @Published var customMCPDraftName = ""
    @Published var customMCPDraftURL = ""
    @Published var customMCPDraftAuth: CustomMCPServer.Auth = .oauth
    @Published var customMCPDraftToken = ""
    /// Which connector is mid-request, mirrored from `ConnectionsService`; nil when idle.
    /// The Connections section keys its spinner on this.
    @Published var busyConnector: String?
    /// Whether anything is in flight. Computed rather than mirrored so it cannot
    /// disagree with `busyConnector`; a change to that republishes this too.
    var isConnectionBusy: Bool { busyConnector != nil }
    @Published var connectionError: String?
    /// Which connector `connectionError` belongs to, so it can be shown in that
    /// provider's footer rather than in one shared across all four.
    @Published var connectionErrorConnector: String?
    /// Whether the connections have loaded. Until they have, every `*Available` flag is false,
    /// so the section shows it is still checking.
    @Published var hasLoadedConnections = false
    @Published var connectionStatusLoadFailed = false
    /// The Google account the user has tapped Remove on, nil when no confirmation is up.
    /// The address doubles as the flag — a separate bool could disagree with it.
    @Published var pendingGoogleRemoval: String?
    @Published var showSignOutAlert = false
    @Published var showDeleteAlert = false
    /// Set when `deleteAccount()` fails. The user stays signed in so the delete can be retried.
    @Published var deleteFailed = false
    /// Whether an alert sent right now would appear on this phone.
    @Published var notificationsEnabled = false
    /// Whether the system alert can still be shown. False after a grant or a denial,
    /// so it is not the inverse of `notificationsEnabled`.
    @Published var notificationsCanAsk = true
    @Published var notificationsBusy = false

    /// Which of the three sentences applies is a fact about the permission, so it lives here.
    var notificationsTitle: String {
        if notificationsEnabled { return "Notifications are on" }
        return notificationsCanAsk ? "Turn on notifications" : "Notifications are off"
    }

    var notificationsDetail: String {
        if notificationsEnabled { return "Answers to handed-off work reach this phone" }
        return notificationsCanAsk
            ? "Hear back about work that finishes after a call"
            : "Turn them back on in iOS Settings"
    }
}

// MARK: - Interactor

@MainActor
final class ProfileViewInteractor: ViewModelInteractor<ProfileViewModel> {
    @Injected(\.backend) private var backend
    @Injected(\.connections) private var connections
    @Injected(\.pushNotifications) private var push

    @CancellableBuilder
    override func onLoad(viewModel: ProfileViewModel) -> [AnyCancellable] {
        super.onLoad(viewModel: viewModel)

        // Mirrored so the Connections section is drawn from fields, not from the service.
        connections.$gmailAvailable
            .receive(on: DispatchQueue.main)
            .sink { viewModel.gmailAvailable = $0 }

        connections.$gmailAccounts
            .receive(on: DispatchQueue.main)
            .sink { viewModel.gmailAccounts = $0 }

        connections.$gmailNeedsReauth
            .receive(on: DispatchQueue.main)
            .sink { viewModel.gmailNeedsReauth = $0 }

        connections.$githubAvailable
            .receive(on: DispatchQueue.main)
            .sink { viewModel.githubAvailable = $0 }

        connections.$githubAccounts
            .receive(on: DispatchQueue.main)
            .sink { viewModel.githubAccounts = $0 }

        connections.$githubNeedsReauth
            .receive(on: DispatchQueue.main)
            .sink { viewModel.githubNeedsReauth = $0 }

        connections.$githubPendingCode
            .receive(on: DispatchQueue.main)
            .sink { viewModel.githubPendingCode = $0 }

        connections.$slackAvailable
            .receive(on: DispatchQueue.main)
            .sink { viewModel.slackAvailable = $0 }

        connections.$slackAccounts
            .receive(on: DispatchQueue.main)
            .sink { viewModel.slackAccounts = $0 }

        connections.$slackNeedsReauth
            .receive(on: DispatchQueue.main)
            .sink { viewModel.slackNeedsReauth = $0 }

        connections.$notionMcpAvailable
            .receive(on: DispatchQueue.main)
            .sink { viewModel.notionMcpAvailable = $0 }

        connections.$notionMcpAccounts
            .receive(on: DispatchQueue.main)
            .sink { viewModel.notionMcpAccounts = $0 }

        connections.$notionMcpNeedsReauth
            .receive(on: DispatchQueue.main)
            .sink { viewModel.notionMcpNeedsReauth = $0 }
        connections.$granolaAvailable
            .receive(on: DispatchQueue.main)
            .sink { viewModel.granolaAvailable = $0 }
        connections.$granolaAccounts
            .receive(on: DispatchQueue.main)
            .sink { viewModel.granolaAccounts = $0 }
        connections.$granolaNeedsReauth
            .receive(on: DispatchQueue.main)
            .sink { viewModel.granolaNeedsReauth = $0 }
        connections.$customMCPAvailable
            .receive(on: DispatchQueue.main)
            .sink { viewModel.customMCPAvailable = $0 }
        connections.$customMCPServers
            .receive(on: DispatchQueue.main)
            .sink { viewModel.customMCPServers = $0 }
        connections.$busyConnector
            .receive(on: DispatchQueue.main)
            .sink { viewModel.busyConnector = $0 }

        connections.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { viewModel.connectionError = $0 }

        // Two publishers because the service publishes two fields, both in the same run-loop turn.
        connections.$errorConnector
            .receive(on: DispatchQueue.main)
            .sink { viewModel.connectionErrorConnector = $0 }

        connections.$hasLoadedStatus
            .receive(on: DispatchQueue.main)
            .sink { viewModel.hasLoadedConnections = $0 }

        connections.$statusLoadFailed
            .receive(on: DispatchQueue.main)
            .sink { viewModel.connectionStatusLoadFailed = $0 }

        // Mirrored like the connector flags above, and for the same reason: the row is
        // drawn from view-model fields, not from a service the view holds.
        push.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                viewModel.notificationsEnabled = self.push.isEnabled
                viewModel.notificationsCanAsk = self.push.canAsk
            }

        push.$isRequesting
            .receive(on: DispatchQueue.main)
            .sink { viewModel.notificationsBusy = $0 }
    }

    @CancellableBuilder
    override func onViewAppear(viewModel: ProfileViewModel) -> [AnyCancellable] {
        super.onViewAppear(viewModel: viewModel)
        refresh(viewModel: viewModel)
    }
}

extension ProfileViewInteractor: ProfileViewHandler {
    func refresh(viewModel: ProfileViewModel) {
        Task {
            await self.connections.refresh()
        }

        // On every appearance: notifications can be switched off in iOS Settings while backgrounded.
        Task {
            await self.push.refresh()
        }

        let user = backend.sessionUser()
        viewModel.accountName = user.name
        viewModel.accountEmail = user.email
    }

    func refreshConnections() {
        Task { await connections.refresh() }
    }

    func requestSignOut(viewModel: ProfileViewModel) {
        viewModel.showSignOutAlert = true
    }

    /// Never asked shows the system alert; already answered opens iOS Settings.
    func handleNotificationRow(viewModel: ProfileViewModel) {
        guard !push.isEnabled else { return }
        if push.canAsk {
            Task {
                let status = await self.push.request()
            }
        } else {
            push.openSystemSettings()
        }
    }

    func confirmSignOut(viewModel: ProfileViewModel) {
        backend.signOut()
    }

    func requestDeleteAccount(viewModel: ProfileViewModel) {
        viewModel.showDeleteAlert = true
    }

    /// Nothing here may run before the delete answers, so a failed delete is not mistaken for success.
    func confirmDeleteAccount(viewModel: ProfileViewModel) {
        Task {
            do {
                try await self.backend.deleteAccount()
            } catch {
                viewModel.deleteFailed = true
                return
            }
            UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
        }
    }

    func voiceNotesSwitched(viewModel: ProfileViewModel) {
        VoiceNotesDefault.stamp(backend.userId)
    }

    func connectGoogle(viewModel: ProfileViewModel) {
        connections.connectGmail()
    }

    func reconnectGoogle(_ email: String, viewModel: ProfileViewModel) {
        connections.connectGmail(reconnecting: email)
    }

    /// Asks first. `disconnectGmail` revokes the grant with Google, drops the Keychain grant
    /// and the mailbox's cached mail in one go, which is more than "Remove" implies.
    func removeGoogle(_ email: String, viewModel: ProfileViewModel) {
        viewModel.pendingGoogleRemoval = email
    }

    func confirmRemoveGoogle(viewModel: ProfileViewModel) {
        guard let email = viewModel.pendingGoogleRemoval else { return }
        viewModel.pendingGoogleRemoval = nil
        Task { await self.connections.disconnectGmail(email) }
    }

    /// Serves Connect and a row's Reconnect alike: the device flow has no login hint, and
    /// signing in as the same login replaces its token.
    func connectGithub(viewModel: ProfileViewModel) {
        connections.connectGithub()
    }

    func cancelGithubConnect(viewModel: ProfileViewModel) {
        connections.cancelGithubConnect()
    }

    /// Copies the code, so it can be pasted on GitHub's page, then opens that page.
    func openGithubVerification(viewModel: ProfileViewModel) {
        guard let code = viewModel.githubPendingCode else { return }
        UIPasteboard.general.string = code.userCode
        UIApplication.shared.open(code.verificationURL)
    }

    func removeGithub(_ login: String, viewModel: ProfileViewModel) {
        Task { await self.connections.disconnectGithub(login) }
    }

    /// Connect, add another workspace, or reconnect one whose token lapsed: one consent each.
    func connectSlack(viewModel: ProfileViewModel) {
        connections.connectSlack()
    }

    func removeSlack(_ workspace: String, viewModel: ProfileViewModel) {
        Task { await self.connections.disconnectSlack(workspace) }
    }

    /// Serves Connect and a connected row's Reconnect alike: reconnecting replaces the credential,
    /// which is how a rejected one gets fixed.
    func connectNotionMcp(viewModel: ProfileViewModel) {
        connections.connectNotionMcp()
    }

    func removeNotionMcp(_ workspace: String, viewModel: ProfileViewModel) {
        Task { await self.connections.disconnectNotionMcp(workspace) }
    }

    func connectGranola(viewModel: ProfileViewModel) {
        connections.connectGranola()
    }

    func reconnectGranola(_ account: String, viewModel: ProfileViewModel) {
        connections.connectGranola(replacing: account)
    }

    func removeGranola(_ account: String, viewModel: ProfileViewModel) {
        Task { await self.connections.disconnectGranola(account) }
    }

    func beginAddCustomMCP(viewModel: ProfileViewModel) {
        viewModel.customMCPReconnecting = nil
        viewModel.customMCPDraftName = ""
        viewModel.customMCPDraftURL = ""
        viewModel.customMCPDraftAuth = .oauth
        viewModel.customMCPDraftToken = ""
        viewModel.showCustomMCPForm = true
    }

    func cancelCustomMCPForm(viewModel: ProfileViewModel) {
        viewModel.showCustomMCPForm = false
        viewModel.customMCPDraftToken = ""
    }

    /// Add the drafted server, or replace the token of the one being reconnected. The sheet
    /// closes on success and stays up with the error otherwise.
    func submitCustomMCPForm(viewModel: ProfileViewModel) {
        let token = viewModel.customMCPDraftToken
        let reconnecting = viewModel.customMCPReconnecting
        let name = viewModel.customMCPDraftName, url = viewModel.customMCPDraftURL
        let auth = viewModel.customMCPDraftAuth
        Task {
            let saved = if let reconnecting {
                await self.connections.reconnectCustomMCP(reconnecting.id, token: token)
            } else {
                await self.connections.addCustomMCP(name: name, endpoint: url, auth: auth, token: token)
            }
            if saved {
                viewModel.showCustomMCPForm = false
                viewModel.customMCPDraftToken = ""
            }
        }
    }

    /// A bearer server needs a new token, so its reconnect goes through the sheet; the other two
    /// kinds reconnect in place.
    func reconnectCustomMCP(_ server: CustomMCPServerStatus, viewModel: ProfileViewModel) {
        guard server.auth == .bearer else {
            Task { _ = await self.connections.reconnectCustomMCP(server.id, token: "") }
            return
        }
        viewModel.customMCPReconnecting = server
        viewModel.customMCPDraftName = server.name
        viewModel.customMCPDraftURL = server.host
        viewModel.customMCPDraftAuth = .bearer
        viewModel.customMCPDraftToken = ""
        viewModel.showCustomMCPForm = true
    }

    func refreshCustomMCPTools(_ server: CustomMCPServerStatus, viewModel: ProfileViewModel) {
        Task { await self.connections.refreshCustomMCPTools(server.id) }
    }

    func removeCustomMCP(_ server: CustomMCPServerStatus, viewModel: ProfileViewModel) {
        Task { await self.connections.removeCustomMCP(server.id) }
    }


    /// Whether this account's grant covers Calendar. A read-through rather than
    /// mirrored state: it's a question about one row, asked while drawing it.
    func hasCalendar(_ email: String) -> Bool {
        connections.hasCalendar(email)
    }

    /// Whether this account's grant covers writing standing mail rules. Same
    /// read-through, and the same question asked one scope over.
    func hasFilters(_ email: String) -> Bool {
        connections.hasFilters(email)
    }

    /// Whether this phone holds the grant, not just the broker. Decides whether the
    /// background mail refresh can see this inbox at all.
    func hasDeviceGrant(_ email: String) -> Bool {
        connections.hasDeviceGrant(email)
    }
}

#if DEBUG
import Prefire

#Preview("ProfileView") {
    PreviewProfileViewHost()
        .snapshot(delay: 0.5)
}
#endif
