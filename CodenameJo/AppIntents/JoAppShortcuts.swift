import AppIntents

/// Registers Start Voice as an App Shortcut with Siri phrases. App-target-only: the system reads
/// App Shortcuts from the app bundle. `\(.applicationName)` also matches `INAlternativeAppNames`.
struct JoAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartVoiceSessionIntent(),
            phrases: [
                // Siri's launcher takes "launch"/"run" outright and takes "open" whenever
                // the name resolves, so this fires only as "Open Jo"/"Open Joe".
                "Open \(.applicationName)",
                "Start \(.applicationName)",
                "Start a command in \(.applicationName)",
                "New \(.applicationName) command",
                "Ask \(.applicationName)"
            ],
            shortTitle: "Start Voice Command",
            // App Shortcut tiles accept only system symbol names, so the custom OrbPedestal glyph
            // can't appear here.
            systemImageName: "record.circle"
        )
        // Workflow-only intents remain available in the Shortcuts editor, without standalone phrases.
        /*
        // The messaging bridge rides iOS 27's notification-triggered automations.
        if #available(iOS 27, *) {
            AppShortcut(
                intent: PendingTextIntent(),
                phrases: ["Get my pending text from \(.applicationName)"],
                shortTitle: "Get Pending Text",
                systemImageName: "message.fill"
            )
            AppShortcut(
                intent: ProcessMessagesIntent(),
                phrases: ["Process messages in \(.applicationName)"],
                shortTitle: "Process Messages",
                systemImageName: "text.bubble"
            )
            AppShortcut(
                intent: DeliverMessagesIntent(),
                phrases: ["Give messages to \(.applicationName)"],
                shortTitle: "Give Messages to Jo",
                systemImageName: "arrow.up.message"
            )
            AppShortcut(
                intent: PendingActionIntent(),
                phrases: ["What does \(.applicationName) need"],
                shortTitle: "Get Jo Request",
                systemImageName: "questionmark.bubble"
            )
            AppShortcut(
                intent: PendingSearchIntent(),
                phrases: ["Who is \(.applicationName) looking for"],
                shortTitle: "Get Jo Search Name",
                systemImageName: "person.crop.circle.badge.questionmark"
            )
            AppShortcut(
                intent: PendingContactIntent(),
                phrases: ["Which contact does \(.applicationName) need"],
                shortTitle: "Get Jo Contact",
                systemImageName: "person.crop.circle"
            )
        }
        */
    }
}
