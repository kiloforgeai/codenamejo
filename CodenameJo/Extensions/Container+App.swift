import FactoryKit
import Foundation

/// The app's dependency graph, and the only way a call site reaches a service. `.singleton` for
/// anything `AppDelegate` or CarPlay reaches with no view alive; `.shared` releases when unheld.
extension Container {
#if DEBUG
    @MainActor var validationTurnDriver: Factory<ValidationTurnDriver> { self { MainActor.assumeIsolated { ValidationTurnDriver() } } }
#endif
    var turnSaveOutbox: Factory<TurnSaveOutbox> { self { TurnSaveOutbox() }.singleton }
    var workspaceProfileRows: Factory<WorkspaceProfileRows> {
        self { WorkspaceProfileRows(dbPool: Container.shared.localContext().dbPool) }
    }
    var customCommandRows: Factory<CustomCommandRows> {
        self { CustomCommandRows(dbPool: Container.shared.localContext().dbPool) }
    }
    /// The user's saved voice commands. `.singleton`: Settings and the live call share one array.
    var customCommands: Factory<CustomCommandStore> {
        self { MainActor.assumeIsolated { CustomCommandStore() } }.singleton
    }
    var profileDossier: Factory<ProfileDossierLearner> {
        self { ProfileDossierLearner(rows: Container.shared.workspaceProfileRows()) }.singleton
    }
    var unsubscribeHTTP: Factory<any HTTPDataTransport> { self { UnsubscribeHTTPTransport() }.singleton }
    var providerHTTP: Factory<any HTTPDataTransport> { self { URLSessionDataTransport() }.singleton }
    /// The Google token server and Google's revoke endpoint.
    var tokenServerHTTP: Factory<any HTTPDataTransport> { self { URLSessionDataTransport() }.singleton }
    var googleGrantStorage: Factory<any GoogleGrantStorage> { self { KeychainGrantStorage() }.singleton }
    /// GitHub's device flow and REST API, called straight from this phone.
    var githubHTTP: Factory<any HTTPDataTransport> { self { URLSessionDataTransport() }.singleton }
    var githubTokenStorage: Factory<any GitHubTokenStorage> { self { KeychainGitHubTokenStorage() }.singleton }
    /// Slack's token endpoint and Web API, straight from the phone.
    var slackHTTP: Factory<any HTTPDataTransport> { self { URLSessionDataTransport() }.singleton }
    var slackGrantStorage: Factory<any SlackGrantStorage> { self { KeychainSlackGrantStorage() }.singleton }
    var slackCredentials: Factory<SlackCredentials> { self { SlackCredentials() }.singleton }
    var slackQueueCache: Factory<SlackQueueCache> { self { SlackQueueCache() }.singleton }
    /// Remote MCP sign-ins, one Keychain namespace per service (`RemoteMCPGrantStore`).
    var remoteMCPGrantStorage: Factory<any RemoteMCPGrantStorage> { self { KeychainRemoteMCPGrantStorage() }.singleton }
    var remoteMCPCredentials: Factory<RemoteMCPCredentials> { self { RemoteMCPCredentials() }.singleton }
    /// The user's own MCP servers (`CustomMCPServerStore`); their credentials are remote MCP grants.
    var customMCPServerStorage: Factory<any CustomMCPServerStorage> { self { DefaultsCustomMCPServerStorage() }.singleton }
    var googleTokenProvider: Factory<any GoogleTokenProvider> {
        self { MainActor.assumeIsolated { KeychainTokenProvider() } }.singleton
    }
    var voiceTransportQueue: Factory<AudioQueue> { self { AudioQueue() }.singleton }
    var voiceAudioConfiguration: Factory<any VoiceAudioConfiguration> {
        self { Container.shared.watchAudioRouter().audioConfiguration() }
    }
    var voiceInputDriver: Factory<any VoiceInputDriver> { self { Container.shared.watchAudioRouter().inputDriver() } }
    var watchAudioRouter: Factory<WatchAudioRouter> { self { WatchAudioRouter() }.singleton }
    var watchCompanion: Factory<WatchCompanionService> {
        self { MainActor.assumeIsolated { WatchCompanionService() } }.singleton
    }
    var voiceEvidence: Factory<any VoiceEvidence> { self { UnrecordedVoiceEvidence() }.singleton }

    var localVoiceQueue: Factory<AudioQueue> { self { AudioQueue() }.singleton }
    var localSpeech: Factory<LocalSpeech> { self { MainActor.assumeIsolated { LocalSpeech() } }.singleton }
    var localTurnDetector: Factory<SemanticTurnDetector> { self { SemanticTurnDetector() }.singleton }

    var onboardingAudioQueue: Factory<AudioQueue> {
        self { AudioQueue() }.singleton
    }

    var workspaceProfiles: Factory<WorkspaceProfileStore> { self { MainActor.assumeIsolated { WorkspaceProfileStore() } }.singleton }

    var contactStore: Factory<ContactStore> {
        self { ContactStore(database: Container.shared.localContext().dbPool) }
    }

    /// Bands and topics for cached mail, scored on the phone with the user's OpenAI key.
    var mailImportance: Factory<MailImportance> {
        self { MailImportance(contacts: Container.shared.contactStore(), model: MailImportance.openAI) }
    }

    @MainActor var mailStore: Factory<MailStore> {
        let store = MailStore(database: localContext().dbPool, userId: backend().userId ?? "")
        return self { store }.unique
    }

    var gmailQuota: Factory<GmailQuota> { self { GmailQuota() }.singleton }

    /// Accepted archives, spam reports and trashes not yet confirmed by Gmail. `.singleton` so one drain runs at a time.
    var pendingMailWrites: Factory<PendingMailWrites> {
        self { PendingMailWrites(dbPool: Container.shared.localContext().dbPool) }.singleton
    }

    /// Failures of writes already spoken about, held for their conversation's next function output.
    var localWriteNotices: Factory<LocalWriteNotices> { self { LocalWriteNotices() }.singleton }

    /// Who is signed in, and the install id every local row is owned by. `.singleton` because
    /// `AppDelegate` reaches it on a launch where no view exists yet.
    var backend: Factory<BackendService> {
        self { MainActor.assumeIsolated { BackendService.shared } }
            .scope(.singleton)
    }

    /// The live voice session. `assumeIsolated` because Factory's closure is nonisolated; every
    /// resolution site is already on the main actor, and one that isn't traps here.
    var realtimeService: Factory<RealtimeService> {
        self { MainActor.assumeIsolated { RealtimeService() } }
            .scope(.shared)
    }

    /// What a call needs started, on whichever surface got there first (`AccountBootstrap`).
    /// `.singleton` because the caller may be a CarPlay scene with no view alive.
    var accountBootstrap: Factory<AccountBootstrap> {
        self { MainActor.assumeIsolated { AccountBootstrap() } }
            .scope(.singleton)
    }

    /// The only way this app dials (`VoiceCallCoordinator`). `.singleton` because a CarPlay launch
    /// may have no view, and this holds the pending dial between `connect()` and `.ready`.
    var voiceCall: Factory<VoiceCallCoordinator> {
        self { MainActor.assumeIsolated { VoiceCallCoordinator() } }
            .scope(.singleton)
    }

    /// Command history (`record_type = "command"`).
    var commandStore: Factory<CommandStore> {
        self { MainActor.assumeIsolated { CommandStore() } }
            .scope(.shared)
    }

    /// The on-device dispatch log. A singleton: it holds the rows in memory over one file.
    var dispatchJobs: Factory<DispatchJobStore> {
        self { MainActor.assumeIsolated { DispatchJobStore() } }
            .singleton
    }

    /// Writes the assistant performed, with a link to each item
    /// (`record_type = "action"`, written by the broker).
    var actions: Factory<ActionStore> {
        self { MainActor.assumeIsolated { ActionStore() } }
            .scope(.shared)
    }

    /// Where the user is in their email queue, per the broker. `.shared`: a second instance would
    /// be a second position.
    var triageQueue: Factory<TriageQueueStore> {
        self { MainActor.assumeIsolated { TriageQueueStore() } }
            .scope(.shared)
    }

    /// The email triage queue, walked on the device (`LocalTriageQueue`). `.singleton`: a second
    /// instance would be a second cursor.
    var localTriage: Factory<LocalTriageQueue> {
        self { LocalTriageQueue() }
            .scope(.singleton)
    }

    /// The Slack queue's cursor. One, for the reason `localTriage` is one.
    var localSlack: Factory<LocalSlackQueue> {
        self { LocalSlackQueue() }
            .scope(.singleton)
    }

    var emailCleanup: Factory<EmailCleanupEnricher> {
        self { EmailCleanupEnricher() }.scope(.singleton)
    }

    /// The summary the next call's first email is opened with, warmed at launch.
    /// `.singleton` because the launch refresh writes it and a later dial reads it.
    var liveEmailOpening: Factory<LiveEmailOpeningSummary> {
        self { LiveEmailOpeningSummary() }.scope(.singleton)
    }

    /// Pending "open History on this tab" requests. `.shared` because the asker
    /// and the two things that act on it live in different panes of the pager.
    var historyRouter: Factory<HistoryRouter> {
        self { MainActor.assumeIsolated { HistoryRouter() } }
            .scope(.shared)
    }

    /// The signed-in user's settings, on their account. `.singleton` because it watches
    /// `UserDefaults` for the whole process; two would upload every change twice.
    var userProfile: Factory<UserProfileStore> {
        self { MainActor.assumeIsolated { UserProfileStore() } }
            .scope(.singleton)
    }

    /// Every tool result this phone has seen, in SQLite with FTS5. Not `@MainActor`; `.singleton`
    /// so background mail refreshes share one `DatabasePool` with `MailStore`.
    var localContext: Factory<LocalContextStore> {
        self { LocalContextStore() }
            .scope(.singleton)
    }

    /// Which connectors the signed-in user has. `.singleton` because it holds the OAuth callback
    /// continuation across a trip to Safari and back.
    var connections: Factory<ConnectionsService> {
        self { MainActor.assumeIsolated { ConnectionsService() } }
            .scope(.singleton)
    }

    /// The Lock Screen / Dynamic Island card and the one owner of the `Activity` handle.
    /// `.singleton` because launch sweeps and the End intent run before any view exists.
    var liveActivity: Factory<LiveVoiceActivity> {
        self { MainActor.assumeIsolated { LiveVoiceActivity() } }
            .scope(.singleton)
    }

    /// Phone contact resolution shared by the call, settings, and App Intents.
    var phoneContacts: Factory<PhoneContacts> {
        self { PhoneContacts() }.scope(.singleton)
    }

    /// Pending messaging work must survive the trip through Shortcuts.
    var shortcutActions: Factory<ShortcutActionRunner> {
        self { MainActor.assumeIsolated { ShortcutActionRunner() } }
            .scope(.singleton)
    }

    /// "Start a call" or "leave a note" from outside the app. Lives in `Shared/`, which the widget
    /// extension compiles without packages, so the type keeps its own `static let shared`.
    var voiceLauncher: Factory<VoiceSessionLauncher> {
        self { MainActor.assumeIsolated { VoiceSessionLauncher.shared } }
            .scope(.singleton)
    }

    /// The seam a Live Activity button reaches the live call through. Same
    /// arrangement and same reason as `voiceLauncher`.
    var voiceRemoteControl: Factory<VoiceRemoteControl> {
        self { MainActor.assumeIsolated { VoiceRemoteControl.shared } }
            .scope(.singleton)
    }

    /// Whether this phone may show a notification, and the one thing that asks. `.shared` because
    /// the system prompt can only be shown once per install.
    var pushNotifications: Factory<PushNotifications> {
        self { MainActor.assumeIsolated { PushNotifications() } }
            .scope(.shared)
    }

    /// On-device speech for memos (`MemoTranscriber`). `.shared` so Settings and the memo queue
    /// read one answer about locale, model readiness and `AssetInventory` reservations.
    var memoTranscriber: Factory<MemoTranscriber> {
        self { MainActor.assumeIsolated { MemoTranscriber() } }
            .scope(.shared)
    }

    /// Notes waiting to be read back and sent (`MemoQueue`). `.singleton` because `isPaused` and
    /// `inFlight` aren't on disk, and forgetting an in-flight send risks a duplicate email.
    var memoQueue: Factory<MemoQueue> {
        self { MainActor.assumeIsolated { MemoQueue() } }
            .scope(.singleton)
    }

    /// Whether the phone has a usable network path. `.singleton` because it owns an `NWPathMonitor`
    /// started once at launch.
    var connectivity: Factory<Connectivity> {
        self { MainActor.assumeIsolated { Connectivity() } }
            .scope(.singleton)
    }

    /// The microphone the offline path uses (`MemoRecorder`). `.shared` because two of
    /// these would be two claims on one microphone.
    var memoRecorder: Factory<MemoRecorder> {
        self { MainActor.assumeIsolated { MemoRecorder() } }
            .scope(.shared)
    }
}


extension Container: AutoRegistering {
    public func autoRegister() {
#if DEBUG
        voiceEvidence.register { ValidationEvidence() }
        if CaptureInjector.isEnabled {
            voiceInputDriver.register { InjectedVoiceInputDriver(injector: CaptureInjector()) }
#if targetEnvironment(simulator)
            if UUID(uuidString: ProcessInfo.processInfo.environment["VALIDATION_RUN_ID"] ?? "") != nil {
                voiceAudioConfiguration.register { SimulatorVoiceAudioConfiguration() }
            }
#endif
        }
#endif
    }

}
