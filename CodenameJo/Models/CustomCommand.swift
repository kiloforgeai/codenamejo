import Foundation

/// One step of a command — a call to a tool the session already has.
///
/// `tool` is the tool's own name, `detail` is what to call it with in words
/// ("the company", "from them, last month"). The arguments are worked out when the command
/// runs, against whatever the user is talking about then, which is why `detail` is prose
/// rather than stored JSON — a command saved with literal arguments would only ever work
/// for the conversation it was dictated in.
///
/// `summarize` is the final step of nearly every command: it is where the model says what
/// the earlier steps returned.
struct CommandAction: Codable, Hashable, Sendable {
    var tool: String
    var detail: String

    /// The step as a line of text, for the tool's answer.
    var line: String {
        detail.isEmpty ? tool : "\(tool) — \(detail)"
    }
}

/// One command the user made up: a keyword, and the steps saying it runs.
///
/// "Save a command called research that means look the company up and summarise it" —
/// after which saying "research" runs those steps. Created by voice, listed and switched
/// in Settings, and run only when the user says the keyword; the assistant never reaches
/// for one on its own initiative. Stored on this phone (`CustomCommandRows`) and checked
/// here (`CustomCommandRules`).
struct CustomCommand: Codable, Identifiable, Hashable, Sendable {
    let id: String

    /// What the user says, normalised (`CustomCommandRules.normalise`). The matching identity,
    /// unique per profile — a keyword that matched two rows would leave the model with two
    /// instructions and no way to choose. One word or a short phrase, up to four words.
    var keyword: String

    /// The keyword as the user actually said it, casing intact, for drawing on screen.
    var spoken: String

    /// A short label for the Settings screen. **Never sent to the model beside the steps**:
    /// a description next to the instructions got the work done twice.
    var instruction: String

    /// The steps, in order. **This is the command.** Never sent in the session prompt — the
    /// model gets these from `commands` at the moment the keyword is said, which is what makes
    /// switching a command off take effect inside a live call.
    var actions: [CommandAction]

    /// Whether it is switched on. The Settings toggle and the voice tool both set this,
    /// through one code path in `CustomCommandStore`.
    var enabled: Bool

    var createdAt: Date?

    /// What Settings draws.
    var title: String {
        spoken.isEmpty ? keyword : spoken
    }

    /// What this command does, in words, for the screen. **Never the tool names**: the label
    /// the user gave, or else the steps' own `detail` prose.
    var plainDescription: String {
        if !instruction.isEmpty { return instruction }
        let details = actions.map(\.detail).filter { !$0.isEmpty }
        return details.joined(separator: " Then ")
    }
}
