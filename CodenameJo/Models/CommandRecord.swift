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
    }

    /// One tool the assistant ran during the turn: the persisted twin of `TurnStep`, which can't
    /// synthesize `Codable` because its `id` is a `let` with a default.
    struct ToolStep: Codable, Hashable {
        let tool: String
        /// The broker's own measurement, where there was one. A reported 0 means unknown, so it is
        /// stored as nil.
        var milliseconds: Int?
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
    }
    var brainSteps: [BrainStep]?

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
    static let knownServices: [(name: String, icon: String)] = [("Gmail", "envelope.fill")]
        + ConnectorRegistry.all.compactMap { connector in connector.historyIcon.map { (connector.displayName, $0) } }
        + [
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
