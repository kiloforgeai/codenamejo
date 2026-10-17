import FactoryKit
import Foundation

/// What, if anything, a newly set-up Live session should say before the user speaks.
/// The opening `LiveSessionSetup` accepts is authoritative for email; onboarding alone keeps
/// its legacy fallback.
enum SessionOpening: String, Equatable, Sendable {
    case emailQueue = "email_queue"
    /// Jo greets and asks before any queue work; a yes is the model's own `triage_next`.
    case feedOffer = "feed_offer"
    case onboarding
    case none

    /// The call carries the sequential feed, whether the opening starts it or offers it.
    var leadsWithFeed: Bool { self == .emailQueue || self == .feedOffer }

    static func freshConversation() -> SessionOpening {
        freshConversation(
            onboardingPending: UserDefaults.standard.bool(
                forKey: FullDuplexConfig.pendingGreetingKey),
            agentLedEmailEnabled: AgentLedEmailSettings.isEnabled)
    }

    static func freshConversation(
        onboardingPending: Bool, agentLedEmailEnabled: Bool
    ) -> SessionOpening {
        // The first call after onboarding walks the queue unasked; every later call asks first.
        if agentLedEmailEnabled { return onboardingPending ? .emailQueue : .feedOffer }
        return onboardingPending ? .onboarding : .none
    }

    /// Email is fail-closed on the session setup's echo. Onboarding alone keeps the
    /// legacy nil-echo behavior.
    static func accepted(requested: SessionOpening, echoed: SessionOpening?,
                         resumingOnboarding: Bool = false) -> SessionOpening {
        if requested == .onboarding { return echoed ?? .onboarding }
        if requested == .emailQueue, echoed == .emailQueue { return .emailQueue }
        if requested == .feedOffer, echoed == .feedOffer { return .feedOffer }
        // A resumed onboarding run starts its queue instead of offering the ordinary feed.
        if requested == .feedOffer, resumingOnboarding, echoed == .emailQueue { return .emailQueue }
        return .none
    }

    static func afterReconnect(requested: SessionOpening, wasAudible: Bool) -> SessionOpening {
        wasAudible ? .none : requested
    }
}

enum AgentLedEmailSettings {
    static let key = "agentLedEmailSessions"

    /// Always on. A returning call asks before the feed starts, so "no" is the opt-out. A
    /// stored off from the retired "Open calls with your feed" switch is ignored: nothing in
    /// the app can turn it back on, and honouring it silently drops the opening and the feed.
    static var isEnabled: Bool { true }
}

/// Sets up the Live session the full-duplex call dials into, and the email preparation around it.
enum FullDuplexBroker {

    struct CoachingLesson: Codable, Equatable, Sendable {
        let capability: String
        let copy: String
        var speech: String? = nil
        var answerInstruction: String? = nil
    }

    /// The phone's own rotation for this dial (`CoachingRotation`); empty `lessons` offers no tip.
    struct CoachingPlan: Codable, Equatable, Sendable {
        let lessons: [CoachingLesson]
        /// Re-taught on a fresh onboarding even after the rotation retired it.
        var onboardingFeed: CoachingLesson? = nil
    }

    /// This email's spoken summary and suggestion, prepared on the phone with the user's key.
    static func prepareEmail(_ key: LiveEmailPresentation.Key, scope: ProfileRuntime.Scope?) async -> LiveEmailPresentation? {
        guard let scope, scope.containsMailbox(key.account) else {
            RealtimeLog.log("livePreparation: deferred — email profile connections unavailable or mismatched")
            return nil
        }
        guard !MailHeadersOnly.withholdsBodies, scope.mailHeadersOnly != true else { return nil }
        guard !LocalVoiceSettings.allLocal else { return nil }
        let preparationId = UUID().uuidString
        let preparationStarted = Date()
        let preparationUptime = ProcessInfo.processInfo.systemUptime
        func elapsedMs() -> Int { Int((ProcessInfo.processInfo.systemUptime - preparationUptime) * 1000) }
        RealtimeLog.log("preparation.request: id=\(preparationId) profile=\(scope.profileId) email=\(key.messageId) startedAt=\(preparationStarted.timeIntervalSince1970)")
        do {
            var prepared = try await LocalEmailPresentation.prepare(key, scope: scope)
            func encode(_ value: some Encodable) -> String {
                String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self)
            }
            Container.shared.voiceEvidence().record("preparation.response", [
                "requestId": preparationId, "elapsedMs": elapsedMs(),
                "key": encode(key), "body": encode(prepared), "profileId": scope.profileId])
            RealtimeLog.log("preparation.response: id=\(preparationId) elapsedMs=\(elapsedMs())")
            prepared.preparationRequestId = preparationId
            prepared.preparationReceivedAt = Date()
            guard prepared.key == key else {
                RealtimeLog.log("livePreparation: rejected mismatched email identity")
                return nil
            }
            RealtimeLog.log("livePreparation: email=\(key.messageId) category=\(prepared.category ?? "<none>") suggestion=\(prepared.suggestedQuestion ?? "<none>") summaryBytes=\(prepared.summary.utf8.count)")
            return prepared
        } catch {
            Container.shared.voiceEvidence().record("preparation.failure", [
                "requestId": preparationId, "profileId": scope.profileId, "messageId": key.messageId,
                "elapsedMs": elapsedMs(), "cancelled": Task.isCancelled,
                "errorType": String(describing: type(of: error))])
            RealtimeLog.log("preparation.failure: id=\(preparationId) elapsedMs=\(elapsedMs()) cancelled=\(Task.isCancelled) error=\(error)")
            return nil
        }
    }

    /// Whether the category's playbook changed. A lost report only means this email's category does not learn from it.
    static func reportPlaybook(account: String, category: String,
                               turns: [(role: String, text: String)], tools: [String]) async -> Bool {
        let changed = await LocalEmailPresentation.reportPlaybook(account: account, category: category, turns: turns, tools: tools)
        RealtimeLog.log("playbook: \(category) turns=\(turns.count) changed=\(changed)")
        return changed
    }

    struct LiveConfiguration {
        var emailPreparation: Bool? = nil
        var fastActions: [String]? = nil
        /// The `session` object the phone posts to `/v1/live/sessions`, and the brain's Responses config,
        /// both built by `LivePrompt` from the session's tools and prompt facts.
        var session = Data()
        var brain = Data()
        /// OpenAI's SDP answer, filled in once the phone has created the session.
        var answerSDP = ""
    }

    struct Session {
        let live: LiveConfiguration
        /// Permission-first coaching is on, so `web_search` needs the user's own request.
        var interactiveCoaching = false
        /// The opening this session may speak; nil keeps the legacy onboarding fallback.
        let openingMode: SessionOpening?
        /// The phone's own onboarding run for this call, if one is under way.
        let onboardingFlow: EmailOnboardingFlow?
        /// The post-mail sequential feed is on.
        let sequentialFeed: Bool
        let localCoachingDelivery: Bool
        /// Whether this session should automatically cover today's remaining calendar.
        let calendarFeedDue: Bool
        /// Local cadence keys captured when the session was set up.
        let calendarFeedOwners: [String]
        /// `dispatch` requires its `scope` argument.
        var dispatchScope: Bool = false
        /// Whether any write on this session reports its outcome later. None does.
        let asyncWrites: Bool
        /// Whether `search_calendar` was declared. Calendar reads use the calendar tools.
        let localCalendar: Bool
        /// `triage_next` is a client function on this session.
        let localTriage: Bool
        /// The phone's own quick-tip rotation for this dial.
        let coachingPlan: CoachingPlan?
        /// The user's first name for the opening greeting; nil keeps the nameless copy.
        let greetingName: String?
        /// Today's morning feed answers, spoken in the opening once a local day.
        let feedBriefing: [String]
        let feedBriefingOwners: [String]
        /// `slack_triage_next` and its finishers are declared, so this phone owns the Slack cursor.
        var localSlackTriage = false
        /// The Feed reaches Slack: important Slack after important mail, the rest after the calendar.
        var profileSlackFeed = false
        var importantSlackStage = false
    }

    /// Sets the Live session up on this phone: its tools, prompt facts and capability answers come
    /// from local state (`LiveSessionSetup`), so nothing here reaches our server.
    static func mint(
        opening: SessionOpening = .none, onboardingFlow: EmailOnboardingFlow? = nil
    ) async throws -> Session {
        // Only configured phones on iOS 27 have the updated messaging shortcut setup.
        let shortcutText = await MainActor.run { Container.shared.shortcutActions().isAvailable }
        // The mailboxes the cache covers, omitted whole when any falls outside the active profile:
        // a cache that does not match the served mailboxes withholds the device mail tools.
        let unread = await Container.shared.mailStore().inboxUnread()
        var cachedMailboxes: [String] = []
        if let unread, ProfileRuntime.allowedMailAccounts(unread.accounts).count == unread.accounts.count {
            cachedMailboxes = unread.accounts
        }
        let calendarStore = CalendarStore(database: Container.shared.localContext().dbPool)
        let calendarSyncedAccounts = ProfileRuntime.allowedMailAccounts(await calendarStore.syncedAccounts())
        let cadenceUserId = await MainActor.run { Container.shared.backend().userId }
        let cadenceOwners = CalendarFeedCadence.owners(
            accounts: calendarSyncedAccounts.isEmpty ? (unread?.accounts ?? []) : calendarSyncedAccounts,
            userId: cadenceUserId)
        // Offered only with positive evidence that a timed event is still ahead today. A skip doesn't
        // mark the cadence complete, so the next dial asks again.
        let calendarCadenceDue = opening.leadsWithFeed
            && CalendarFeedCadence.isDue(owners: cadenceOwners)
        var hasReviewableEvents = false
        if calendarCadenceDue {
            // Every account that should hold a cache: a calendar grant with no sync state makes
            // `provablyEmpty` refuse, so one clear mailbox can't hide another's busy day.
            let calendarGranted = GoogleAccountStore.all()
                .filter { GoogleCredential.calendarScopes.allSatisfy($0.scopes.contains) }
                .map(\.email)
            let restOfToday = CalendarFeedCadence.restOfLocalDay()
            hasReviewableEvents = await CalendarSearch.hasReviewableFeedEvents(
                timeMinMs: restOfToday.startMs, timeMaxMs: restOfToday.endMs,
                accounts: calendarGranted, store: calendarStore)
            if !hasReviewableEvents {
                RealtimeLog.log(
                    "feed: calendar stage skipped — no reviewable event confirmed in cache")
            }
        }
        let feedBriefingOwners = cadenceUserId.map { ["feed-items:\($0)"] } ?? []
        // Granola's grants for this profile; a refused refresh is flagged on use, never here.
        let granolaGrants = GranolaConnector.grants()
        let granola = granolaGrants.contains { !$0.needsReauth }
        // Re-read first, off the main actor's writer wait, so the eligibility below sees the list.
        await Container.shared.customCommands().refresh()
        let coachingEligibility = await MainActor.run {
            let commands = Container.shared.customCommands()
            return CoachingRotation.Eligibility(
                slackConnectable: SlackConfig.isConfigured && SlackGrantStore.all().isEmpty,
                multipleInboxes: GoogleAccountStore.mailAccounts().count > 1,
                hasFeedItems: !FeedItems.all().isEmpty,
                hasCommands: !commands.commands.isEmpty,
                githubAvailable: !AppHosts.githubClientID.isEmpty,
                githubConnected: !GitHubAccountStore.usable().isEmpty,
                hasGranola: granola,
                notionConnected: NotionTools.isConnected(profileId: ProfileRuntime.snapshot?.profileId))
        }
        let coachingPlan = CoachingRotation.plan(coachingEligibility)

        var request = LiveSessionSetup.Request()
        request.opening = opening
        request.onboardingRun = onboardingFlow.map {
            ($0.mailModeChoice != nil, $0.resume == true, $0.config?.opening ?? "")
        }
        request.dispatch = true
        request.shortcutText = shortcutText
        request.shortcutRead = shortcutText
        request.coachingLessons = coachingPlan.lessons.count + (coachingPlan.onboardingFeed == nil ? 0 : 1)
        request.cachedMailboxes = cachedMailboxes
        if opening.leadsWithFeed {
            request.sequentialFeed = true
            request.calendarFeedDue = calendarCadenceDue && hasReviewableEvents
            request.feedItems = CalendarFeedCadence.isDue(owners: feedBriefingOwners)
        }

        let mailboxes = ProfileRuntime.allowedMailAccounts(GoogleAccountStore.mailAccounts())
        let calendarAccounts = await CalendarTools.accounts()
        let grants = await reachability(mailboxes + calendarAccounts.filter { !mailboxes.contains($0) })
        let failed = Set(grants.needsReauth + grants.unreachable)
        let slack = await slackReachability()
        var state = LiveSessionSetup.State(
            inboxes: mailboxes.filter { !failed.contains($0) },
            calendars: calendarAccounts.filter { !failed.contains($0) },
            needsReauth: grants.needsReauth, unreachable: grants.unreachable,
            draftsOnly: { DraftsOnly.isOn(for: $0) },
            triageScope: UserDefaults.standard.string(forKey: TriageScope.storageKey),
            notionNeedsReauth: NotionTools.needsReauth(profileId: ProfileRuntime.snapshot?.profileId),
            githubAccounts: GitHubAccountStore.usable().map(\.login),
            githubNeedsReauth: GitHubAccountStore.needsReauth(),
            granola: granola, granolaNeedsReauth: granolaGrants.filter(\.needsReauth).map(\.label),
            notion: NotionTools.isConnected(profileId: ProfileRuntime.snapshot?.profileId),
            ownerNames: [mailboxes.first.flatMap { GoogleAccountStore.grant(for: $0)?.displayName },
                         GoogleAccountStore.primary()?.displayName])
        state.slackWorkspaces = slack.workspaces
        state.slackNeedsReauth = slack.needsReauth
        // The profile's own MCP servers, offered from the tool lists they gave last time; the
        // lists are refreshed behind this dial so the next one sees what the server has now.
        let customServers = CustomMCPConnector.servers()
        state.customMCPTools = CustomMCPTools.definitions(servers: customServers)
        state.customMCPServers = customServers.filter(CustomMCPConnector.isUsable).map(\.name)
        state.customMCPNeedsReauth = customServers.filter { !CustomMCPConnector.isUsable($0) }.map(\.name)
        CustomMCPConnector.refreshToolsInBackground(customServers)
        let setup = LiveSessionSetup.resolve(request, state, catalog: LiveSessionSetup.Catalog.bundled)

        // Mail search, body reads, mail management and calendar list/create/update are the phone's own tools,
        // run on its Google grant.
        let mailAccounts = GoogleAccountStore.mailAccounts()
        let mailTools = setup.tools + GmailReadTools.definitions(accounts: mailAccounts,
            bodies: !MailHeadersOnly.withholdsBodies && ProfileRuntime.snapshot?.mailHeadersOnly != true)
            + GmailManageTools.definitions(accounts: mailAccounts, filterAccounts: mailAccounts.filter {
                GoogleAccountStore.grant(for: $0)?.scopes.contains(GmailManageTools.filterScope) == true })
            + CalendarTools.definitions(accounts: calendarAccounts)
        // The user's saved commands, re-read above; their steps are fetched live by `commands`.
        let commandKeywords = await MainActor.run { Container.shared.customCommands().commands.map(\.keyword) }
        let tools = LiveSessionSetup.addingCommands(to: mailTools, keywords: commandKeywords,
                                                    dispatch: request.dispatch, catalog: LiveSessionSetup.Catalog.bundled)
        var live = LiveConfiguration(emailPreparation: true, fastActions: setup.fastActions)
        var facts = LivePrompt.Facts(setup.prompt)
        facts.commands = true
        facts.commandKeywords = commandKeywords
        // The dossier is on this phone, so the active profile's overview is added here.
        if let owner = cadenceUserId, let profileId = ProfileRuntime.snapshot?.profileId {
            facts.profileContext = await Container.shared.profileDossier().context(owner: owner, profileId: profileId)?.overview
        }
        let prompt = try LivePrompt.configs(facts: facts,
            tools: tools, fastActions: !setup.fastActions.isEmpty, timeZone: TimeZone.current.identifier)
        live.session = try JSONSerialization.data(withJSONObject: prompt.session)
        live.brain = try JSONSerialization.data(withJSONObject: prompt.brain)

        var session = Session(
            live: live,
            openingMode: setup.openingMode,
            onboardingFlow: onboardingFlow,
            sequentialFeed: setup.sequentialFeed,
            localCoachingDelivery: setup.localCoachingDelivery,
            calendarFeedDue: setup.calendarFeedDue,
            calendarFeedOwners: cadenceOwners,
            dispatchScope: true,
            asyncWrites: false,
            localCalendar: false,
            localTriage: true,
            coachingPlan: coachingPlan,
            greetingName: setup.greetingName,
            feedBriefing: setup.feedBriefing ? FeedItems.todaysAnswers() : [],
            feedBriefingOwners: feedBriefingOwners)
        session.interactiveCoaching = setup.interactiveCoaching
        session.localSlackTriage = setup.localSlackTriage
        session.profileSlackFeed = setup.slackFeedStage
        session.importantSlackStage = setup.importantSlackStage
        RealtimeLog.log("session: set up Live session for \(LivePrompt.speakerModel)"
            + " · opening requested \(opening.rawValue), accepted \(setup.openingMode.rawValue)"
            + (session.onboardingFlow == nil ? "" : " · onboarding")
            + (session.sequentialFeed ? " · sequential feed" : " · legacy checkpoints")
            + (session.calendarFeedDue ? " · calendar feed due" : " · calendar suppressed")
            + " · dispatch"
            + (setup.greetingName == nil ? " · no greeting name" : " · greeting by name")
            // Both branches: "not declared" is the finding when the model answers mail the slow way.
            + (setup.localMail ? " · search_recent declared" : " · NO search_recent (cache covers "
                + (cachedMailboxes.isEmpty ? "nothing" : cachedMailboxes.joined(separator: "+")) + ", serving "
                + (state.inboxes.isEmpty ? "none" : state.inboxes.joined(separator: "+")) + ")")
            + " · \(coachingPlan.lessons.count) coaching lesson(s) preloaded"
            + (shortcutText ? " · send_text via Shortcuts" : " · NO send_text shortcut")
            + (granola ? " · granola" : "")
            + (grants.needsReauth.isEmpty ? "" : " · google needs reauth: \(grants.needsReauth.joined(separator: ", "))")
            + (grants.unreachable.isEmpty ? "" : " · google unreachable: \(grants.unreachable.joined(separator: ", "))")
            + (slack.workspaces.isEmpty ? "" : " · slack on device (\(slack.workspaces.count) workspace(s))")
            + (slack.needsReauth.isEmpty ? "" : " · slack needs reauth: \(slack.needsReauth.joined(separator: ", "))")
            + (state.notion ? " · notion via dispatch" : "")
            + (state.notionNeedsReauth.isEmpty ? "" : " · notion needs reauth")
            + (state.githubAccounts.isEmpty ? "" : " · github: \(state.githubAccounts.joined(separator: ", "))")
            + (state.githubNeedsReauth.isEmpty ? "" : " · github needs reauth: \(state.githubNeedsReauth.joined(separator: ", "))")
            + (state.customMCPServers.isEmpty ? "" : " · mcp: \(state.customMCPServers.joined(separator: ", ")) (\(state.customMCPTools.count) tools)")
            + (state.customMCPNeedsReauth.isEmpty ? "" : " · mcp needs reauth: \(state.customMCPNeedsReauth.joined(separator: ", "))"))
        return session
    }

    /// The active profile's Slack workspaces, each token renewed if due: a refused renewal or a
    /// refresh token past its 30 days needs the user; a transient failure still serves the tools.
    private static func slackReachability() async -> (workspaces: [String], needsReauth: [String]) {
        let grants = SlackGrantStore.inProfile()
        var workspaces: [String] = [], needsReauth: [String] = []
        for grant in grants {
            switch await Container.shared.slackCredentials().token(teamId: grant.teamId) {
            case .success: workspaces.append(grant.teamName)
            case .failure(.needsReauth): needsReauth.append(grant.teamName)
            case .failure(.transient(let why)):
                RealtimeLog.log("slack: \(grant.teamName) token unavailable at dial — \(why)")
                workspaces.append(grant.teamName)
            case .failure(.notConnected): break
            }
        }
        return (workspaces, needsReauth)
    }

    /// Each grant's state, as Google answers a refresh (or the cached token): a revoked grant needs
    /// the user, any other failure leaves that account out of this call.
    private static func reachability(_ accounts: [String]) async -> (needsReauth: [String], unreachable: [String]) {
        let results = await withTaskGroup(of: (String, GoogleCredential.Failure?).self) { group in
            for account in accounts {
                group.addTask {
                    switch await GoogleCredential.token(for: account, requiredScopes: []) {
                    case .success: return (account, nil)
                    case .failure(let failure): return (account, failure)
                    }
                }
            }
            var out: [String: GoogleCredential.Failure?] = [:]
            for await (account, failure) in group { out[account] = failure }
            return out
        }
        var needsReauth: [String] = [], unreachable: [String] = []
        for account in accounts {
            switch results[account] ?? nil {
            case .grantRevoked?: needsReauth.append(account)
            case .transient?: unreachable.append(account)
            case .noStoredGrant?, .scopesMissing?, nil: break
            }
        }
        return (needsReauth, unreachable)
    }

    /// What a tool run on this phone answered: the text the model reads, and whether the
    /// executor says the tool actually did the thing.
    /// `ok` nil is not "assume fine": a backgrounded write treats nil as worth saying, because a swallowed
    /// failure is worse than a needless correction.
    struct ToolResult {
        let text: String
        /// Nil when the executor didn't classify this tool; nil means "speak it".
        let ok: Bool?
        var effects: [GmailWriteEffect]? = nil
        var pendingArchive: PendingArchive? = nil
        var pendingDraft: PendingDraft? = nil
        var deferred: Bool = false
        var performedTool: String? = nil
    }

    /// Run one client-executed write on this phone and return the text for the `function_call_output` item.
    ///
    /// Failures come back as text, never a throw, so the model can say what went wrong.
    /// Every name runs on this phone's grant.
    static func runTool(
        name: String, argumentsJSON: String,
        conversationId: String? = nil, deferArchive: Bool = false, deferDraft: Bool = false, deferSpam: Bool = false, deferTrash: Bool = false, deferSend: Bool = false, deferCalendar: Bool = false, deferLabel: Bool = false,
        profileId: String? = ProfileRuntime.snapshot?.profileId
    ) async -> ToolResult {
        // Notion's MCP, called from this phone with the profile's own grant.
        if NotionTools.names.contains(name) {
            return await NotionTools.run(name: name, argumentsJSON: argumentsJSON, profileId: profileId)
        }
        if LocalMailWrites.names.contains(name) {
            let deferred = (name == "archive_message" && deferArchive) || (name == "mark_spam" && deferSpam)
                || (name == "trash_message" && deferTrash) || (name == "label_message" && deferLabel)
            return await LocalMailWrites.run(name: name, argumentsJSON: argumentsJSON, defer: deferred,
                                             conversationId: conversationId)
        }
        // A send or forward defers only inside a call, where a failure has a conversation to be told in.
        let inCall = deferSend && !(conversationId ?? "").isEmpty
        if LocalCompose.names.contains(name) {
            return await LocalCompose.run(name: name, argumentsJSON: argumentsJSON,
                                          defer: name == "create_draft" ? deferDraft : inCall, conversationId: conversationId)
        }
        if name == LocalForward.name {
            return await LocalForward.run(argumentsJSON: argumentsJSON, defer: inCall, conversationId: conversationId)
        }
        if LocalCalendarWrites.names.contains(name) {
            return await LocalCalendarWrites.run(name: name, argumentsJSON: argumentsJSON, defer: deferCalendar,
                                                 conversationId: conversationId)
        }
        // Every github_ name goes here so one outside ALLOWED_TOOLS is refused there, not reported as unknown.
        if GitHubTools.isGitHubTool(name) {
            return await GitHubTools.run(name: name, argumentsJSON: argumentsJSON)
        }
        if GranolaTools.names.contains(name) {
            return await GranolaTools.run(name: name, argumentsJSON: argumentsJSON)
        }
        // The user's own MCP servers, called from this phone with the profile's grant.
        if CustomMCPTools.isCustomTool(name) {
            return await CustomMCPTools.run(name: name, argumentsJSON: argumentsJSON,
                                            servers: CustomMCPConnector.servers(profileId: profileId))
        }
        RealtimeLog.log("tools: \(name) has no executor on this phone")
        return ToolResult(text: "There is no tool called \(name). Use only the tools you were given.", ok: false)
    }

    /// What a dispatched job came back with. Only a confirmed action success may suppress a report.
    struct DispatchOutcome {
        let text: String
        let ok: Bool?
        var reportBack = true
        /// The job reached the local dispatch log, so a memo queue's work is done whatever it said.
        var recorded = true
    }

    /// The mail and calendar writes a dispatched job may call, and the connectors the job's
    /// profile has, as Responses function tools.
    static func workerTools(mail: [String], calendar: [String], notion: Bool = false, granola: Bool = false,
                            slack: Bool = false, githubAccounts: [String] = [],
                            customMCPTools: [[String: Any]] = []) -> [[String: Any]] {
        LiveSessionSetup.workerTools(inboxes: mail, calendars: calendar,
                                     draftsOnly: { DraftsOnly.isOn(for: $0) }, notion: notion, granola: granola,
                                     slack: slack, githubAccounts: githubAccounts, customMCPTools: customMCPTools,
                                     catalog: .bundled)
    }
}
