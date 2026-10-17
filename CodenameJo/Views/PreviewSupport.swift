import Foundation
import FactoryKit
import SwiftUI
import UserNotifications

// MARK: - Preview store subclasses
// Not private and not behind #if DEBUG: Prefire copies each #Preview body into generated tests,
// so everything a preview references must be visible from the test target.

@MainActor
final class PreviewCommandStore: CommandStore {
    override init() {
        super.init()
        self.commands = [
            CommandRecord(
                id: UUID(),
                commandText: "Check my inbox and summarize any unread emails from today",
                responseText: "You have 4 unread emails. The most important is from Sarah Chen about the Q3 review. Two from Linear with issue updates, and one newsletter.",
                serviceName: "Gmail",
                serviceIcon: "envelope.fill",
                status: .success,
                durationSeconds: 0.9,
                issuedAt: Date(),
                // Latency on two rows only: most stored history predates the measurement and shows no wait.
                latency: TurnLatency(
                    toResponseCreatedMs: 240, toFirstTokenMs: 620, toFirstAudioMs: 780)
            ),
            // GitHub and Notion are unwired, and History draws chips from `connectedServices`, so their rows stay commented out.
            /*
            // GitHub, not Linear: this seeded a Linear row for months, and Linear
            // has never been connectable here. A screenshot of a filter chip for
            // a service the app can't call is a screenshot of a promise it can't
            // keep — and History now draws chips from
            // `ConnectionsService.connectedServices`, so a Linear row here would
            // have no chip to sit under either.
            CommandRecord(
                id: UUID(),
                commandText: "Which pull requests are waiting on my review?",
                responseText: "Three are waiting on you: voice narration for find_person, the infra map SVGs, and the paged drawers refactor. The narration one has a failing check.",
                serviceName: "GitHub",
                serviceIcon: "chevron.left.forwardslash.chevron.right",
                status: .success,
                durationSeconds: 1.1,
                issuedAt: Date().addingTimeInterval(-600),
                latency: TurnLatency(
                    toResponseCreatedMs: 310, toFirstTokenMs: 1_450, toFirstAudioMs: 1_600)
            ),
             */
            CommandRecord(
                id: UUID(),
                commandText: "What is on my calendar for today?",
                responseText: "You have 2 events today: Engineering standup at 9 AM (in 45 minutes) and Product strategy at 3 PM with the full team.",
                serviceName: "Calendar",
                serviceIcon: "calendar",
                status: .success,
                durationSeconds: 0.8,
                issuedAt: Date().addingTimeInterval(-86400)
            ),
            /*
            CommandRecord(
                id: UUID(),
                commandText: "Summarize the Notion page on the voice architecture",
                responseText: "The voice architecture page covers the WebRTC transport design and token broker setup. Last updated 2 days ago.",
                serviceName: "Notion",
                serviceIcon: "doc.text.fill",
                status: .success,
                durationSeconds: 1.3,
                issuedAt: Date().addingTimeInterval(-86400 * 2)
            )
             */
        ]
    }

    override func refresh() async {
        // no-op: keep injected mock data
    }
}

/// A queue partway through (4 of 12), so the chip appears in the screenshot.
@MainActor
final class PreviewTriageQueueStore: TriageQueueStore {
    override init() {
        super.init()
        progress = QueueProgress(
            account: "work@example.com", position: 4,
            queued: 12, remaining: 9, done: false)
    }
}

/// One of each state the Dispatch panel can draw, so the seeded panel exercises every pill.
@MainActor
final class PreviewDispatchJobStore: DispatchJobStore {
    override func history() async -> [DispatchJob] {
        [
            DispatchJob(
                id: UUID(),
                task: "Check all three inboxes for anything about the Vercel invoice",
                state: "done",
                result: "Found it — the invoice cleared this morning. Finance forwarded the receipt to nate@example.com, and nothing else in the three inboxes mentions it.",
                startedAt: Date().addingTimeInterval(-15 * 60),
                completedAt: Date().addingTimeInterval(-14 * 60),
                deliveredAt: nil
            ),
            DispatchJob(
                id: UUID(),
                task: "Summarize the open pull requests on example-app and who each is waiting on",
                state: "running",
                result: nil,
                startedAt: Date().addingTimeInterval(-25),
                completedAt: nil,
                deliveredAt: nil
            ),
            DispatchJob(
                id: UUID(),
                task: "Pull the sales numbers for July and compare to June",
                state: "running",
                result: nil,
                startedAt: Date().addingTimeInterval(-2 * 60 * 60),
                completedAt: nil,
                deliveredAt: nil
            ),
            DispatchJob(
                id: UUID(),
                task: "Draft a reply to Priya about clause 4 of the contract",
                state: "failed",
                result: "I couldn't find Priya's latest message — the Gmail search returned nothing for the contract thread, so there was nothing safe to draft against.",
                startedAt: Date().addingTimeInterval(-60 * 60),
                completedAt: Date().addingTimeInterval(-59 * 60),
                deliveredAt: Date().addingTimeInterval(-50 * 60)
            ),
            DispatchJob(
                id: UUID(),
                task: "Find out when the Q3 review with Sarah is and what she sent ahead of it",
                state: "done",
                result: "Thursday at 2 PM. Sarah sent the deck yesterday — twelve slides, and she flagged slide 9 as the one she wants your read on.",
                startedAt: Date().addingTimeInterval(-26 * 60 * 60),
                completedAt: Date().addingTimeInterval(-26 * 60 * 60 + 40),
                deliveredAt: Date().addingTimeInterval(-25 * 60 * 60)
            ),
        ]
    }

    /// Nothing to recover and nothing to settle — fixtures never reach a
    /// conversation, and the base implementation would write the local dispatch log.
    override func recover() async -> [DispatchJob] { [] }
    override func settle(_ id: UUID) async {}
}

/// One of each state the Actions panel can draw, including rows with no link,
/// so an absent link can be reviewed as a stated fact rather than a broken row.
@MainActor
final class PreviewActionStore: ActionStore {
    override func history() async -> [ActionRecord] {
        [
            ActionRecord(
                id: UUID(),
                tool: "send_email",
                connector: "gmail",
                account: "nate@example.com",
                summary: "Sent to sarah@example.com",
                state: "done",
                detail: nil,
                itemId: "18f2c1a9b4e0d3",
                threadId: "18f2c1a9b4e0aa",
                url: "https://mail.google.com/mail/u/nate@example.com/#all/18f2c1a9b4e0aa",
                conversationId: nil,
                startedAt: Date().addingTimeInterval(-4 * 60),
                completedAt: Date().addingTimeInterval(-4 * 60 + 1)
            ),
            ActionRecord(
                id: UUID(),
                tool: "create_calendar_event",
                connector: "calendar",
                account: "nate@example.com",
                summary: "Created \"Coffee with Sarah\"",
                state: "done",
                detail: nil,
                itemId: "7a9f2c1b8e04",
                threadId: nil,
                url: "https://www.google.com/calendar/event?eid=N2E5ZjJjMWI4ZTA0",
                conversationId: nil,
                startedAt: Date().addingTimeInterval(-9 * 60),
                completedAt: Date().addingTimeInterval(-9 * 60 + 1)
            ),
            ActionRecord(
                id: UUID(),
                tool: "label_message",
                connector: "gmail",
                account: "hello@example.com",
                summary: "Labelled \"Receipts\" — \"Vercel invoice #4021\"",
                state: "failed",
                detail: "hello@example.com needs reconnecting before it can archive or label — its access predates that permission. Remove and re-add the account in Settings, then try again.",
                itemId: "18f2c1a9b4e0d3",
                threadId: nil,
                url: nil,
                conversationId: nil,
                startedAt: Date().addingTimeInterval(-32 * 60),
                completedAt: Date().addingTimeInterval(-32 * 60 + 2)
            ),
            ActionRecord(
                id: UUID(),
                tool: "archive_message",
                connector: "gmail",
                account: "nate@example.com",
                summary: "Archived in nate@example.com",
                state: "pending",
                detail: nil,
                itemId: "18f2b0c7d1e992",
                threadId: nil,
                url: nil,
                conversationId: nil,
                startedAt: Date().addingTimeInterval(-3 * 60 * 60),
                completedAt: nil
            ),
            // GitHub is unwired, so these rows stay commented out.
            /*
            // The irreversible one, and the reason GitHub writes leave rows at all. Its
            // identifier is the merge commit and its link is the pull request — two
            // different things, deliberately: the sha is what proves the merge, the PR
            // page is where a person goes to see it.
            ActionRecord(
                id: UUID(),
                tool: "merge_pull_request",
                connector: "github",
                account: "octocat",
                summary: "Merged example-org/example-server #91 as 972bb02.",
                state: "done",
                detail: nil,
                itemId: "972bb02",
                threadId: nil,
                url: "https://github.com/example-org/example-server/pull/91",
                conversationId: nil,
                startedAt: Date().addingTimeInterval(-4 * 60),
                completedAt: Date().addingTimeInterval(-4 * 60 + 2)
            ),
            // A workflow dispatch has no link and cannot have one — GitHub answers 204
            // with no run id, so there is nothing yet to point at.
            ActionRecord(
                id: UUID(),
                tool: "actions_run_trigger",
                connector: "github",
                account: "octocat",
                summary: "Started build-and-upload.yml on main in example-org/example-app.",
                state: "done",
                detail: nil,
                itemId: "build-and-upload.yml",
                threadId: nil,
                url: nil,
                conversationId: nil,
                startedAt: Date().addingTimeInterval(-33 * 60),
                completedAt: Date().addingTimeInterval(-33 * 60 + 1)
            ),
             */
            ActionRecord(
                id: UUID(),
                tool: "create_draft",
                connector: "gmail",
                account: "nate@example.com",
                summary: "Drafted a reply to priya@example.com",
                state: "done",
                detail: nil,
                itemId: nil,
                threadId: nil,
                url: nil,
                conversationId: nil,
                startedAt: Date().addingTimeInterval(-27 * 60 * 60),
                completedAt: Date().addingTimeInterval(-27 * 60 * 60 + 1)
            ),
        ]
    }
}

@MainActor
final class PreviewRealtimeService: RealtimeService {
    override init() {
        super.init()
        self.sessionState = .ready
        // Seed a finished exchange so the screenshot shows the product working, not its empty state.
        self.lastCommandText = "What needs me in my inbox this morning?"
        self.responseText = """
            Three things. Nate needs Thursday confirmed, the Vercel invoice is \
            due Friday, and Priya replied about the contract — she's asking for \
            one change to clause 4.
            """
        self.memoryTurns = 4
        self.feedFocus = .email(FeedFocus.Email(
            sender: "Priya Shah <priya@example.com>",
            subject: "Contract review — one change to clause 4",
            snippet: "I made the requested edit and left one question for you in the margin.",
            account: "josh@example.com",
            position: 1,
            total: 3
        ))
        // Two droplets, one older, so they are visibly out of phase.
        self.liveDispatches = [
            LiveDispatch(
                id: UUID(),
                task: "Check every connected inbox and say which messages need a reply today",
                slot: 0,
                startedAt: Date().addingTimeInterval(-12)
            ),
            LiveDispatch(
                id: UUID(),
                task: "Look through this week's calendar and find where the two-hour gaps are",
                slot: 1,
                startedAt: Date().addingTimeInterval(-4)
            )
        ]
        // The finished step list next to its answer, so the screenshot isn't an empty feed.
        self.turnSteps = [
            finishedStep("search_messages", milliseconds: 940),
            finishedStep("get_thread", milliseconds: 1_620),
        ]
    }

    private func finishedStep(_ tool: String, milliseconds: Int) -> TurnStep {
        var step = TurnStep(tool: tool)
        step.endedAt = step.startedAt.addingTimeInterval(Double(milliseconds) / 1000)
        step.serverMilliseconds = milliseconds
        return step
    }

    override func connect() async {
        // no-op in previews
    }

    override func disconnect() {
        // no-op in previews
    }

    override func startConversation(
        in conversationId: UUID,
        announcingConnect: Bool,
        opening: SessionOpening
    ) {
        // no-op in previews — a screenshot must not dial a real call
    }
}

/// Hosts `CommandView` with a connector attached; with none, the screen refuses the mic.
/// Registers a fresh seeded instance so a preview can't leave seeding on the app's service.
@MainActor
struct PreviewCommandViewHost: View {
    init() {
        let connections = ConnectionsService()
        connections.gmailAccounts = ["josh@example.com"]
        connections.hasLoadedStatus = true
        Container.shared.connections.register { connections }
        Container.shared.commandStore.register { PreviewCommandStore() }
        Container.shared.realtimeService.register { PreviewRealtimeService() }
        Container.shared.triageQueue.register { PreviewTriageQueueStore() }
    }

    var body: some View { CommandViewComponent.make() }
}

/// Hosts the last onboarding screen with a mailbox to name and a service that can't dial,
/// since the live canvas runs `onViewAppear` and would otherwise place a call.
@MainActor
struct PreviewOnboardingPreparingHost: View {
    init() {
        let connections = ConnectionsService()
        connections.gmailAccounts = ["josh@example.com"]
        connections.hasLoadedStatus = true
        Container.shared.connections.register { connections }
        Container.shared.realtimeService.register { PreviewRealtimeService() }
    }

    var body: some View { OnboardingPreparingViewComponent.make(onNext: {}, unread: 10_500, newsletters: 9, spam: 412) }
}

/// Hosts `HistoryView` with the connectors its seeded turns use; chips need both a connection and history.
/// Keep in step with `PreviewCommandStore`: a turn under an unset connector draws a row with no chip.
@MainActor
struct PreviewHistoryViewHost: View {
    init() {
        let connections = ConnectionsService()
        connections.gmailAccounts = ["josh@example.com"]
        connections.calendarAccounts = ["josh@example.com"]
        connections.filterAccounts = ["josh@example.com"]
        connections.githubAccounts = ["octocat"]
        connections.notionMcpAccounts = ["Notion"]
        connections.hasLoadedStatus = true
        Container.shared.connections.register { connections }
        Container.shared.commandStore.register { PreviewCommandStore() }
        Container.shared.realtimeService.register { PreviewRealtimeService() }
    }

    var body: some View { HistoryViewComponent.make() }
}

/// The Rules pane. It needs no seeding: it draws three fixed rows off `UserDefaults`.
@MainActor
struct PreviewAutomationsViewHost: View {
    var body: some View { AutomationsViewComponent.make() }
}

/// Hosts `ProfileView` with all connectors attached, since the connections never load in a preview.
/// One Google account lacks calendar and rules so the reconnect prompt appears.
struct PreviewProfileViewHost: View {
    init() {
        let connections = ConnectionsService()
        connections.gmailAvailable = true
        connections.gmailAccounts = ["josh@example.com", "nate@example.com"]
        connections.calendarAccounts = ["josh@example.com"]
        connections.filterAccounts = ["josh@example.com"]
        connections.githubAvailable = true
        connections.githubAccounts = ["octocat"]
        connections.notionMcpAvailable = true
        connections.notionMcpAccounts = ["Notion"]
        // Left empty: the screenshot should show healthy connections.
        // connections.notionMcpNeedsReauth = []
        connections.hasLoadedStatus = true
        Container.shared.connections.register { connections }
        Container.shared.pushNotifications.register { PreviewPushNotifications() }
    }

    var body: some View { ProfileViewComponent.make() }
}

/// Notification permission, granted, so the Settings screenshot doesn't depend on simulator state.
/// `refresh()` is a no-op so it can't overwrite this. No `@MainActor`: `PushNotifications` carries it.
final class PreviewPushNotifications: PushNotifications {
    override init() {
        super.init()
        status = .authorized
    }

    override func refresh() async {}
    override func request() async -> UNAuthorizationStatus { .authorized }
}
