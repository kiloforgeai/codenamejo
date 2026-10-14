import Foundation

/// What a connector can do, one entry per OAuth scope. Keep `scope` byte-identical to the
/// broker's `GOOGLE_SCOPES` (`lib/google.ts`); it is the join key for granted scopes.
struct ConnectorCapability: Identifiable, Hashable {
    /// The full OAuth scope URI, exactly as sent to the provider.
    let scope: String
    /// Short label — a capability, not a scope name. Sentence case, 1–3 words.
    let label: String
    /// SF Symbol shown alongside the label.
    let icon: String
    /// One line on what this permits, for the accessibility label. Written in
    /// terms of what the assistant does, not what the API endpoint is called.
    let detail: String

    var id: String { scope }
}

/// Declared on the array rather than the element so call sites can use leading-dot
/// syntax: `CapabilityChips(capabilities: .google(inboxes:))`.
extension Array where Element == ConnectorCapability {
    /// The one Google connection — mail and calendar, granted together. Computed from the inboxes
    /// because the sending clause follows `DraftsOnly`, which can change between reads.
    static func google(inboxes: [String]) -> [ConnectorCapability] {[
        ConnectorCapability(
            scope: "https://www.googleapis.com/auth/gmail.modify",
            label: "Mail",
            icon: "tray.full",
            detail: "Read, summarize, draft, archive, label and delete your mail, report spam, "
                + "and read the documents attached to it. Anything you deal with in a queue is "
                + "marked read — including the ones you skip, so they don't come back "
                + "next time. "
                + {
                    switch DraftsOnly.summary(for: inboxes) {
                    case .allDraft:
                        return "Nothing is sent for you — replies and forwards are written "
                            + "into your Drafts and wait there until you send them. That's "
                            + "Sending in Settings, on by default for every inbox; switch an "
                            + "inbox off and its mail goes as soon as you ask. It says every "
                            + "address a draft is addressed to, including anyone copied. "
                            + "Forwarding drafts the message itself — formatting and "
                            + "attachments included, not a retyped copy. "
                    case .allSend:
                        return "Sending goes as soon as you ask — you aren't asked to "
                            + "confirm, and it says every address it sent to, including "
                            + "anyone copied. Forwarding sends the message itself on — "
                            + "formatting and attachments included, not a retyped copy — and "
                            + "says where it went. "
                    case .mixed:
                        return "Whether mail is sent or saved as a draft depends on the "
                            + "inbox — that's Sending in Settings, one row each. From an "
                            + "inbox that sends, mail goes as soon as you ask, with no "
                            + "confirmation; from one that doesn't, replies and forwards "
                            + "wait in that mailbox's Drafts until you send them. Either "
                            + "way it says every address the message is addressed to, "
                            + "including anyone copied, and forwarding carries the message "
                            + "itself — formatting and attachments included, not a retyped "
                            + "copy. "
                    }
                }()
                + "It can delete one message or a whole set at once, moving it to Trash — the "
                + "same as Gmail's own Delete — and Gmail empties Trash after thirty days, "
                + "so nothing's gone the moment you ask; open Trash and put a message back "
                + "until then. Reporting spam is the same "
                + "as Gmail's own button: the message moves to Spam, which Gmail empties "
                + "after thirty days, and \"not spam\" brings it back until then. It can "
                + "also unsubscribe you from a sender and file everything they have "
                + "already sent, in one go — that tells them you're done, so it reaches "
                + "them and not just your mailbox, and it can take them a couple of days "
                + "to stop. It says which sender, and says so when there was no "
                + "unsubscribe to use, which is usual for mail a person wrote to you by "
                + "hand. Keeping the rest out of your inbox meanwhile is Mail rules "
                + "below, so without that this stops the sender but not the next email."
        ),
        // Standing rules get their own chip because they are their own scope
        // (`gmail.settings.basic`), which older connections may not have granted.
        ConnectorCapability(
            scope: "https://www.googleapis.com/auth/gmail.settings.basic",
            label: "Mail rules",
            icon: "line.3.horizontal.decrease.circle",
            detail: "Set up standing rules for mail that arrives later — label it, keep "
                + "it out of your inbox, mark it read or important. It reads the whole "
                + "rule back as it saves it, because a rule then works on mail you never "
                + "see. Rules never touch mail already in your mailbox, and it can't make "
                + "one that forwards or deletes anything."
        ),
        ConnectorCapability(
            scope: "https://www.googleapis.com/auth/calendar.readonly",
            label: "Read calendar",
            icon: "calendar",
            detail: "See your events, meetings and free time."
        ),
        ConnectorCapability(
            scope: "https://www.googleapis.com/auth/calendar.events",
            label: "Add, change & cancel",
            icon: "calendar.badge.plus",
            detail: "Put new events on your calendar, move or edit one, add and remove "
                + "guests, cancel one, and accept, decline or tentatively answer an "
                + "invitation. All of it happens as you ask — only inviting someone to a "
                + "brand-new event needs your spoken yes. Guests are emailed about a "
                + "change, and a cancellation can't be undone. Changes land on one "
                + "occurrence, not a whole repeating series."
        ),
    ]}

    /// GitHub — tool-surface labels, not scopes: the `repo` scope carries push and delete, so these
    /// promise what `GitHubTools.allowedTools` lets through. A change to that list changes these chips.
    static let github: [ConnectorCapability] = [
        ConnectorCapability(
            scope: "github.pulls",
            label: "Pull requests",
            icon: "arrow.triangle.pull",
            detail: "Read your pull requests, the ones waiting on your review, and their "
                + "diffs, reviews and comments."
        ),
        ConnectorCapability(
            scope: "github.issues",
            label: "Issues",
            icon: "exclamationmark.bubble",
            detail: "Read issues and search them across your repositories."
        ),
        ConnectorCapability(
            scope: "github.code",
            label: "Read code",
            icon: "doc.text.magnifyingglass",
            detail: "Read files, read commits and search code in the repositories you can "
                + "already see."
        ),
        ConnectorCapability(
            scope: "github.checks",
            label: "CI status",
            icon: "checkmark.seal",
            detail: "See which workflow runs passed or failed, and read the failing job's log."
        ),
        ConnectorCapability(
            scope: "github.notifications",
            label: "Notifications",
            icon: "bell",
            detail: "See the review requests and mentions waiting on you."
        ),
        ConnectorCapability(
            scope: "github.merge",
            label: "Merge",
            icon: "arrow.triangle.merge",
            detail: "Merge a pull request. It is read back to you first and needs your spoken yes, "
                + "because it changes the branch everyone builds on."
        ),
        ConnectorCapability(
            scope: "github.issuewrite",
            label: "File issues",
            icon: "square.and.pencil",
            detail: "File an issue, and edit, label or close one. Read back to you first and it "
                + "needs your spoken yes. Nothing is destroyed — an issue can be reopened and "
                + "its history is kept."
        ),
        ConnectorCapability(
            scope: "github.comment",
            label: "Comment",
            icon: "bubble.left",
            detail: "Comment on an issue or pull request. Read back to you first and it needs "
                + "your spoken yes, because watchers are emailed the moment it lands and "
                + "deleting the comment doesn't unsend that."
        ),
        ConnectorCapability(
            scope: "github.workflows",
            label: "Run CI",
            icon: "play.circle",
            detail: "Start a workflow, re-run one, cancel a run, or delete a finished run's logs. "
                + "The workflow, the repository and the branch are read back to you first and it "
                + "needs your spoken yes, because a run can deploy or publish something — and "
                + "deleted logs are the one thing here that can't be recovered."
        ),
        ConnectorCapability(
            scope: "github.pullrequestwrite",
            label: "Edit pull requests",
            icon: "pencil.line",
            detail: "Put a pull request back into draft or mark it ready for review, and retitle, "
                + "describe, close, reopen or request reviews on one. These happen as you ask — "
                + "all of them are reversible. Changing which branch it would merge into is not "
                + "one of them: that is read back to you first, like merging."
        ),
        ConnectorCapability(
            scope: "github.nothingelse",
            label: "Nothing else",
            icon: "lock",
            detail: "It cannot push code, approve a review, open a pull request, create or delete "
                + "a repository, or alter your repository settings."
        ),
    ]

    /// Notion: tool-surface labels rather than scopes, matching the seven verbs in `NotionTools`.
    /// "Never deletes or rewrites a page" holds because Notion's MCP has no delete tool.
    static let notion: [ConnectorCapability] = [
        ConnectorCapability(
            scope: "notion.read",
            label: "Search and read",
            icon: "magnifyingglass.circle",
            detail: "Search and read anything in Notion you have access to — pages, "
                + "databases and their rows, without picking them first."
        ),
        ConnectorCapability(
            scope: "notion.write",
            label: "Capture and update",
            icon: "square.and.pencil",
            detail: "Write a note, add to a page, and mark things done by setting a "
                + "property. It happens as you ask, and it never deletes or rewrites a page."
        ),
        ConnectorCapability(
            scope: "notion.session",
            label: "Reconnect now and then",
            icon: "arrow.clockwise",
            detail: "Notion expires this connection periodically. Codename Jo renews it from "
                + "this phone; if that ever fails, this row will say so."
        ),
    ]

    static let granola: [ConnectorCapability] = [
        ConnectorCapability(
            scope: "granola.meetings",
            label: "Ask about a meeting",
            icon: "text.magnifyingglass",
            detail: "\"What did we decide with Rob on Tuesday?\" It finds the meeting and answers "
                + "from its notes, rather than reading a whole meeting back at you."
        ),
        ConnectorCapability(
            scope: "granola.actions",
            label: "What you committed to",
            icon: "checklist",
            detail: "\"What am I on the hook for this week?\" It reads the action items out "
                + "of every meeting in a stretch and says who owns each one, so the ones "
                + "that are yours come first."
        ),
        ConnectorCapability(
            scope: "granola.readonly",
            label: "Reads only",
            icon: "eye",
            detail: "It can read your notes and nothing else. It can't write a note, edit "
                + "one, or delete anything in Granola."
        ),
    ]
}
