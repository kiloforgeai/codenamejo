import Foundation

/// One write the assistant performed, written by the broker to `app_records`. `CodingKeys` must
/// match the JSON `lib/db.ts` builds; a mismatch decodes as nil, not an error.
struct ActionRecord: Codable, Identifiable, Hashable {
    let id: UUID
    /// The broker's tool name, e.g. `archive_message`, kept raw because `ToolNarration` keys on it.
    var tool: String
    /// `"gmail"`, `"calendar"`, `"slack"` or `"github"`; a raw `String` so a new connector needs no
    /// release.
    var connector: String
    /// The mailbox or calendar this happened in. Part of the proof rather than
    /// decoration: "archived" means nothing across four connected accounts.
    var account: String
    /// The past-tense sentence shown in the list, assembled by the broker from the tool's receipt
    /// and arguments. It may lack a specific, such as a subject; that is not an error.
    var summary: String
    /// A `String`, not an enum: write-backs replace the whole `value`, and an enum's `unknown`
    /// fallback would overwrite a newer broker's state. Read it through the helpers.
    var state: String
    /// Why a `failed` row failed, phrased for someone reading a list rather than for a
    /// model deciding what to do next.
    var detail: String?
    /// The item acted on, as the vendor confirmed it rather than as we asked.
    var itemId: String?
    var threadId: String?
    /// Where to go and check. Absent when nothing resolves (a draft id, a failed write); not an
    /// error.
    var url: String?
    /// The conversation this happened during, when the app sent one.
    var conversationId: String?
    var startedAt: Date?
    /// When the write settled — set on failure too, so `state` is what says which.
    var completedAt: Date?
    /// Durable retries outlive the ordinary single-request timeout.
    var retryUntil: Date? = nil

    enum CodingKeys: String, CodingKey {
        case id, tool, connector, account, summary, state, detail, url
        case itemId = "item_id"
        case threadId = "thread_id"
        case conversationId = "conversation_id"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case retryUntil = "retry_until"
    }

    /// The `CommandRecord.knownServices` name this row files under. Explicit for names
    /// `capitalized` gets wrong (`"github"` must be `"GitHub"`), `capitalized` for the rest.
    var serviceName: String {
        switch connector {
        case "github": return "GitHub"
        default: return connector.capitalized
        }
    }

    var isPending: Bool { state == "pending" }
    var didFail: Bool { state == "failed" }
    var isDone: Bool { state == "done" }

    /// How long a `pending` row (receipt spoken, Gmail POST still running detached) is given before
    /// it is presumed lost. Bounded by one Gmail POST, not an agent turn.
    static let pendingTolerance: TimeInterval = 60

    /// How long a row is kept. Matches `DispatchJob.retention` so "what did it do last
    /// week" has one answer across both lists.
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    /// True once this write settled, or stopped being plausible.
    func hasSettled(asOf now: Date = Date()) -> Bool {
        guard isPending else { return true }
        if let retryUntil { return now > retryUntil.addingTimeInterval(120) }
        guard let startedAt else { return true }
        return now.timeIntervalSince(startedAt) > Self.pendingTolerance
    }

    /// A `pending` row nobody will ever settle: unknown, not failed, so it isn't reported as not
    /// done.
    func isAbandoned(asOf now: Date = Date()) -> Bool {
        isPending && hasSettled(asOf: now)
    }

    /// The link, when there is one that resolves. Withheld for `pending` and `failed` rows, so the
    /// user isn't invited to verify a write that may not have happened.
    var proofURL: URL? {
        guard isDone, let url, let parsed = URL(string: url) else { return nil }
        return parsed
    }
}
