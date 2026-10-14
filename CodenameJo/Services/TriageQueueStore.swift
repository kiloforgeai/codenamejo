import Foundation

/// Where the user is in their email queue, for the chip beside the orb. The walk is `LocalTriageQueue`;
/// this holds the position. Not `final`: `PreviewTriageQueueStore` pins a fixture.
@MainActor
class TriageQueueStore: ObservableObject {
    /// The live queue, or nil when none is running.
    @Published var progress: QueueProgress?

    /// Could this tool have moved the cursor? A superset: there may be no live queue, or the
    /// id check may have refused to advance.
    static func advancesQueue(_ tool: String) -> Bool {
        movers.contains(ToolNarration.canonical(tool))
    }

    /// Bulk tools take a query, not a message id, so no queue advances on them. `unarchive_message` must stay
    /// out (not a queue finisher). `create_calendar_event` has no message id; the broker gates it on a live queue.
    private static let movers: Set<String> = [
        "triage_next", "archive_message", "trash_message", "label_message",
        "mark_spam", "send_email", "create_draft", "forward_email",
        // A broker finishing tool that resolves the draft's own thread, so the cursor moves.
        "send_draft",
        "unsubscribe_sender",
        "create_calendar_event",
    ]

    /// One reading of where the queue is. `remaining` counts the current item: a fresh queue of
    /// twelve reads "1 of 12" with twelve remaining.
    struct QueueProgress: Equatable {
        let account: String?
        let position: Int
        let queued: Int
        let remaining: Int
        let done: Bool
    }

    /// Take the position from the queue this phone is walking. Nil closes it.
    func applyLocal(_ local: LocalTriageQueue.Progress?) {
        guard let local else {
            progress = nil
            return
        }
        progress = QueueProgress(
            account: local.account,
            position: local.displayPosition ?? local.position,
            queued: local.displayQueued ?? local.queued,
            remaining: local.displayRemaining ?? local.remaining,
            done: local.done
        )
    }

    /// Forget the position, for a new conversation (which starts a new queue).
    func clear() {
        progress = nil
    }
}
