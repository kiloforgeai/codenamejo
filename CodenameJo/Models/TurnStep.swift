import Foundation

/// One thing the assistant did during a turn, as the live screen shows it. Not persisted;
/// `CommandRecord.ToolStep` and `ActionRecord` are the durable records.
struct TurnStep: Identifiable, Equatable {
    let id = UUID()
    /// The tool's name, kept so a completion frame can find its step.
    let tool: String
    let startedAt: Date
    var endedAt: Date?

    /// Whether the tool answered with a refusal or an error, so a refused write never reads as
    /// done.
    var failed = false
    /// The broker's own measurement, preferred over `endedAt - startedAt`, which is wrong for every
    /// parallel step but the last.
    var serverMilliseconds: Int?

    init(tool: String, startedAt: Date = Date()) {
        self.tool = tool
        self.startedAt = startedAt
    }

    var isRunning: Bool { endedAt == nil }

    /// The glyph for this step's outcome, and the colour to draw it in.
    var outcome: (symbol: String, isFailure: Bool) {
        if isRunning { return ("circle.dotted", false) }
        return failed ? ("exclamationmark.triangle.fill", true) : ("checkmark", false)
    }

    var label: String {
        isRunning ? ToolNarration.progressLabel(for: tool) : ToolNarration.doneLabel(for: tool)
    }

    /// The service this step is talking to, when it can be told from the name.
    var sourceIcon: String? { ToolNarration.sourceIcon(for: tool) }

    /// How long it took, or nil when there is nothing honest to show. A `0` means the broker
    /// didn't know, so it shows nothing rather than "0.0s".
    var elapsed: TimeInterval? {
        if let ms = serverMilliseconds { return ms > 0 ? Double(ms) / 1000 : nil }
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}
