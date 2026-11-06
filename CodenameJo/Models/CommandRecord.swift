import Foundation

/// A single voice command issued by the user and its outcome.
/// Stored in `app_records` with record_type = "command".
struct CommandRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var commandText: String
    var responseText: String
    var serviceName: String       // e.g. "Gmail", "Linear", "Calendar"
    var serviceIcon: String       // SF Symbol name for the service
    var status: CommandStatus
    var durationSeconds: Double   // voice-to-response round trip
    var issuedAt: Date
    /// Which conversation this turn belonged to. Optional for records written before conversations
    /// existed; `Conversation.group` splits those on a pause.
    var profile_id: String?
    var conversationId: UUID?
    /// The tools the assistant ran to answer. Optional, so older records still decode.
    var toolSteps: [ToolStep]?
    /// How long this turn kept the user waiting in silence before it spoke (`durationSeconds`
    /// includes the question and answer). Nil for an unmeasured turn, not zero.
    var latency: TurnLatency?

    enum CommandStatus: String, Codable, Hashable {
        case success
        case failed
        case pending
        case cancelled
        case partial
        case conversational
        case unknown
    }

    static func outcome(steps: [TurnStep], interrupted: Bool) -> CommandStatus {
        if interrupted { return .cancelled }
        if steps.isEmpty { return .conversational }
        if steps.contains(where: \.isRunning) { return .unknown }
        let failed = steps.filter(\.failed).count
        if failed == steps.count { return .failed }
        if failed > 0 { return .partial }
        return .success
    }

    /// One tool the assistant ran during the turn: the persisted twin of `TurnStep`, which can't
    /// synthesize `Codable` because its `id` is a `let` with a default.
    struct ToolStep: Codable, Hashable {
        let tool: String
        /// The broker's own measurement, where there was one. A reported 0 means unknown, so it is
        /// stored as nil.
        var milliseconds: Int?
        var outcome: String? = nil
        var callID: String? = nil
        var reason: String? = nil
        var targetHash: String? = nil
    }

    /// One delegated backend response on Live: when it finished, counted from the hand-off, and what it called.
    /// `userSpokeMs` is how long the user kept talking after the hand-off, which is waiting on them, not the model.
    struct BrainStep: Codable, Hashable {
        var ms: Int
        var tools: [String]?
        var inputTokens: Int?
        var cachedTokens: Int?
        var outputTokens: Int?
        /// The user's last word to the hand-off; first step of a delegation only.
        var handoffMs: Int?
        var userSpokeMs: Int?
        var responseID: String? = nil
        var delegationID: String? = nil
        var turnID: String? = nil
        var inputTurn: Int? = nil
        var requestStartedAt: Date? = nil
        var requestFinishedAt: Date? = nil
    }
    var brainSteps: [BrainStep]?
    var feedbackID: UUID? = nil

    func preservingTerminalAttempts(from previous: CommandRecord?) -> CommandRecord {
        guard let previous else { return self }
        var record = self
        var steps = record.toolSteps ?? []
        for prior in previous.toolSteps ?? [] {
            if prior.outcome == "accepted", let id = prior.callID {
                if let index = steps.firstIndex(where: { $0.callID == id }) {
                    if !["success", "refused", "failed", "cancelled", "partial", "unknown"].contains(steps[index].outcome ?? "") { steps[index] = prior }
                } else { steps.append(prior) }
                continue
            }
            guard let id = prior.callID,
                  ["success", "refused", "failed", "cancelled", "partial", "unknown"].contains(prior.outcome ?? "") else { continue }
            if let index = steps.firstIndex(where: { $0.callID == id }) { steps[index] = prior }
            else { steps.append(prior) }
        }
        record.toolSteps = steps.isEmpty ? nil : steps
        record.feedbackID = record.feedbackID ?? previous.feedbackID
        if steps.contains(where: { $0.outcome == "refused" }) {
            record.status = steps.contains(where: { $0.outcome == "success" }) ? .partial : .failed
        } else if record.status == .conversational, let terminal = steps.last(where: {
            $0.callID != nil && ["success", "failed", "cancelled", "partial", "unknown"].contains($0.outcome ?? "")
        }), let status = CommandStatus(rawValue: terminal.outcome ?? "") {
            record.status = status
        } else if steps.contains(where: { $0.outcome == "accepted" }), record.status == .conversational {
            record.status = .pending
        } else if record.feedbackID != nil, record.status == .pending || record.status == .conversational {
            record.status = .success
        }
        return record
    }

    /// Appended to a reply the user cut off, so a transcript can't read it as complete.
    /// Deliberately not shared with `ClaudeVoiceClient`'s marker, which tells the model instead.
    static let interruptedMarker = " […the user interrupted here]"

    init(
        id: UUID = UUID(),
        commandText: String,
        responseText: String = "",
        serviceName: String = "General",
        serviceIcon: String = "waveform",
        status: CommandStatus = .pending,
        durationSeconds: Double = 0,
        issuedAt: Date = Date(),
        conversationId: UUID? = nil,
        toolSteps: [ToolStep]? = nil,
        latency: TurnLatency? = nil,
        brainSteps: [BrainStep]? = nil
    ) {
        self.id = id
        self.commandText = commandText
        self.responseText = responseText
        self.serviceName = serviceName
        self.serviceIcon = serviceIcon
        self.status = status
        self.durationSeconds = durationSeconds
        self.issuedAt = issuedAt
        self.conversationId = conversationId
        self.profile_id = ProfileRuntime.snapshot.flatMap { $0.isDefault ? nil : $0.profileId }
        self.toolSteps = toolSteps
        self.latency = latency
        self.brainSteps = brainSteps
    }
}

extension CommandRecord {
    /// Display table of services and SF Symbols, not a capability list: legacy names stay so old
    /// rows still draw. History's chips intersect it with `connectedServices`.
    static let knownServices: [(name: String, icon: String)] = [
        ("Gmail", "envelope.fill"),
        ("Slack", "bubble.left.and.bubble.right.fill"),
        ("GitHub", "chevron.left.forwardslash.chevron.right"),
        ("Notion", "doc.text.fill"),
        ("Granola", "text.bubble.fill"),
        ("Calendar", "calendar"),
        // Kept only so existing rows still draw; `inferService` no longer produces it.
        ("Kiloforge", "bolt.fill"),
        ("Linear", "checkmark.square.fill"),
        ("Asana", "checklist"),
        ("Drive", "folder.fill"),
        ("Mercury", "dollarsign.circle.fill"),
        ("Typefully", "pencil.and.outline"),
        ("General", "waveform")
    ]

    static func icon(for service: String) -> String {
        knownServices.first { $0.name == service }?.icon ?? "waveform"
    }
}

extension CommandRecord {
    /// The display category for a turn or background job; it does not route tools.
    static func inferService(from text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("email") || lower.contains("gmail") || lower.contains("inbox")
            || lower.contains("mail") { return "Gmail" }
        if lower.contains("granola") { return "Granola" }
        if lower.contains("slack") { return "Slack" }
        if lower.contains("github") || lower.contains("pull request") || lower.contains("pr ")
            || lower.contains("issue") || lower.contains("repo") || lower.contains("merge")
            || lower.contains("workflow") { return "GitHub" }
        if lower.contains("notion") || lower.contains("page") || lower.contains("doc")
            || lower.contains("note") || lower.contains("database") { return "Notion" }
        if lower.contains("calendar") || lower.contains("meeting") || lower.contains("schedule")
            || lower.contains("invite") || lower.contains("invitation")
            || lower.contains("event") { return "Calendar" }
        return "General"
    }
}
