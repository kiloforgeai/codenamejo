import Foundation

/// The settings a user chose, stored on the account (`record_type = "profile"`) so they survive the
/// device. `nil` means never set; device-only switches are deliberately not here.
struct UserProfile: Codable, Equatable {
    // MARK: How it behaves

    /// Whether sent mail ends with the "Sent via Codename Jo 🪩" line. See `MailFooter`.
    var mailFooterEnabled: Bool?

    /// Whether the assistant may see message bodies at all. Absent means it may. See
    /// `MailHeadersOnly`. The broker reads this field directly, so it is the source, not a mirror.
    var mailHeadersOnly: Bool?

    /// The three automatic filing rules, account-wide; absent means off. See `StandingRule`.
    var archiveAfterReply: Bool?
    var archiveAfterForward: Bool?
    var archiveAfterLabel: Bool?

    /// Whether the assistant may send mail at all, or only draft it. See `DraftsOnly`.
    var draftsOnly: Bool?
    var onboardingMailModeAccount: String?

    /// Whether the mail queue groups its messages into conversations. See `ThreadQueue`.
    var threadQueue: Bool?

    /// What each named inbox does, where `draftsOnly` answers for the rest. `nil` and `[:]` both
    /// mean no inbox has an answer of its own.
    var draftsOnlyByAccount: [String: Bool]?

    /// Where a queue starts when the user hasn't said in the call — a `TriageScope` raw value,
    /// `nil` for the whole automatic walk. Read by the phone's `LocalTriageQueue`.
    var triageScope: String?

    /// A profile override; absent uses the account's employee default.
    var suggestedActions: Bool?

    /// Whether a fresh native-cache call should open by walking email. Missing means enabled,
    /// matching the shipped default and allowing older profile rows to opt in without rewrite.
    var agentLedEmailSessions: Bool?

    /// Whether Jo's dedicated broker may send the daily email-queue reminder.
    /// Missing means disabled; only an explicit `true` opts the account in.
    var dailyMailNotifications: Bool?

    /// Local wall-clock minute for the daily reminder (`0...1439`) and its IANA time zone, paired
    /// so 9 AM stays 9 AM across daylight-saving changes.
    var dailyMailNotificationMinuteOfDay: Int?
    var dailyMailNotificationTimeZone: String?

    /// Whether this person has been through onboarding. It travels, but only the flow may apply it
    /// — see `applyToLocalSettings(completingOnboarding:)`.
    var hasCompletedOnboarding: Bool?

    // MARK: How it looks

    /// An `AppearanceSetting` raw value, stored as a string so an unknown value from a newer build
    /// falls back to system rather than failing decode.
    var appearance: String?

    // MARK: - Reading and writing local settings

    /// The profile as the settings on this device currently stand. Reads presence, not value:
    /// `bool(forKey:)` answers `false` for a missing key.
    static func capturingLocalSettings() -> UserProfile {
        let defaults = UserDefaults.standard
        func flag(_ key: String) -> Bool? {
            defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
        }
        func text(_ key: String) -> String? {
            let stored = defaults.string(forKey: key)
            return (stored?.isEmpty ?? true) ? nil : stored
        }
        func integer(_ key: String) -> Int? {
            defaults.object(forKey: key) == nil ? nil : defaults.integer(forKey: key)
        }

        var profile = UserProfile()
        profile.mailFooterEnabled = flag(MailFooter.storageKey)
        profile.mailHeadersOnly = flag(MailHeadersOnly.storageKey)
        profile.archiveAfterReply = flag(StandingRule.archiveAfterReply.storageKey)
        profile.archiveAfterForward = flag(StandingRule.archiveAfterForward.storageKey)
        profile.archiveAfterLabel = flag(StandingRule.archiveAfterLabel.storageKey)
        profile.draftsOnly = flag(DraftsOnly.storageKey)
        profile.onboardingMailModeAccount = text(EmailOnboardingContract.mailModeAccountKey)
        profile.threadQueue = flag(ThreadQueue.storageKey)
        // Presence, not emptiness: an absent key means this build never wrote one.
        profile.draftsOnlyByAccount =
            defaults.data(forKey: DraftsOnly.byAccountStorageKey) == nil
                ? nil
                : DraftsOnly.current
        profile.triageScope = text(TriageScope.storageKey)
        profile.suggestedActions = flag(SuggestedActions.storageKey)
        profile.agentLedEmailSessions = flag(AgentLedEmailSettings.key)
        profile.dailyMailNotifications = flag(DailyMailNotifications.storageKey)
        profile.dailyMailNotificationMinuteOfDay = integer(
            DailyMailNotifications.minuteOfDayStorageKey)
        profile.dailyMailNotificationTimeZone = text(
            DailyMailNotifications.timeZoneStorageKey)
        profile.hasCompletedOnboarding = flag(OnboardingState.storageKey)
        profile.appearance = text(AppearanceSetting.storageKey)
        return profile
    }

    /// Write this profile over the local settings; a `nil` field removes the key.
    /// - Parameter completingOnboarding: false while the onboarding flow is on screen.
    func applyToLocalSettings(completingOnboarding: Bool = true) {
        let defaults = UserDefaults.standard
        func write(_ value: Bool?, _ key: String) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        func write(_ value: String?, _ key: String) {
            if let value, !value.isEmpty { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        func write(_ value: Int?, _ key: String) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        write(mailFooterEnabled, MailFooter.storageKey)
        // Absent does not clear this one: its default is full mail, so a lagging profile would undo
        // a privacy choice. Only sign-out (`clearLocalSettings`) clears it.
        if let mailHeadersOnly { write(mailHeadersOnly, MailHeadersOnly.storageKey) }
        write(archiveAfterReply, StandingRule.archiveAfterReply.storageKey)
        write(archiveAfterForward, StandingRule.archiveAfterForward.storageKey)
        write(archiveAfterLabel, StandingRule.archiveAfterLabel.storageKey)
        write(draftsOnly, DraftsOnly.storageKey)
        write(onboardingMailModeAccount, EmailOnboardingContract.mailModeAccountKey)
        write(threadQueue, ThreadQueue.storageKey)
        // Through `DraftsOnly` because the stored shape is encoded JSON; `nil` still removes the
        // key.
        DraftsOnly.replace(with: draftsOnlyByAccount)
        write(triageScope, TriageScope.storageKey)
        write(suggestedActions, SuggestedActions.storageKey)
        write(agentLedEmailSessions, AgentLedEmailSettings.key)
        write(dailyMailNotifications, DailyMailNotifications.storageKey)
        write(dailyMailNotificationMinuteOfDay, DailyMailNotifications.minuteOfDayStorageKey)
        write(dailyMailNotificationTimeZone, DailyMailNotifications.timeZoneStorageKey)
        if completingOnboarding { write(hasCompletedOnboarding, OnboardingState.storageKey) }
        write(appearance, AppearanceSetting.storageKey)
    }

    /// Wipe every setting this profile owns off the device, on sign-out. Exactly the keys
    /// `applyToLocalSettings` writes; device state like the trace switch isn't this function's.
    static func clearLocalSettings() {
        let defaults = UserDefaults.standard
        for key in [
            MailFooter.storageKey,
            MailHeadersOnly.storageKey,
            StandingRule.archiveAfterReply.storageKey,
            StandingRule.archiveAfterForward.storageKey,
            StandingRule.archiveAfterLabel.storageKey,
            DraftsOnly.storageKey,
            DraftsOnly.byAccountStorageKey,
            ThreadQueue.storageKey,
            TriageScope.storageKey,
            AgentLedEmailSettings.key,
            SuggestedActions.storageKey,
            DailyMailNotifications.storageKey,
            DailyMailNotifications.minuteOfDayStorageKey,
            DailyMailNotifications.timeZoneStorageKey,
            AppearanceSetting.storageKey,
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    /// True when nothing has been chosen; an empty profile isn't worth applying over local
    /// settings.
    var isEmpty: Bool { self == UserProfile() }
}


extension UserProfile {
    /// Ported from the old server's `PROFILE_SETTING_FIELDS`. The three filing
    /// rules are deliberately absent: they answer for the account, not for one workspace.
    static let workspaceFields = ["mailFooterEnabled", "draftsOnly", "draftsOnlyByAccount", "triageScope", "suggestedActions"]

    func replacingWorkspaceSettings(with other: UserProfile) throws -> UserProfile {
        var values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] ?? [:]
        let scoped = try JSONSerialization.jsonObject(with: JSONEncoder().encode(other)) as? [String: Any] ?? [:]
        for key in Self.workspaceFields { values[key] = scoped[key] ?? NSNull() }
        return try JSONDecoder().decode(UserProfile.self, from: JSONSerialization.data(withJSONObject: values))
    }
}
