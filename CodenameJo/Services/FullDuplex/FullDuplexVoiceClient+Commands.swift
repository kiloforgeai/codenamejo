import FactoryKit
import Foundation

extension FullDuplexVoiceClient {
    /// What all three do once they have an answer: post it, log it, queue the event for the
    /// dashboard, and let the model speak.
    ///
    /// Shared because these four steps have to happen for every one of them and in this
    /// order — the `function_call_output` before the continuation, or the model answers
    /// about a tool whose result has not landed. The *work* is per-tool above; only the
    /// plumbing is here.
    /// - Parameter visible: whether the user sees this as a step. False for a search that
    ///   found an empty store — see `answerContextSearch`. Both callbacks are skipped
    ///   together, because `onToolDone` without `onToolUse` is a step that finishes without
    ///   having started, and `TurnStep` draws that as a row with no label.
    /// - Parameter subsystem: what to call this in the log. Defaults to the context store
    ///   because that is where these four steps started; the commands tools reuse the
    ///   plumbing and would otherwise file themselves under `localContext:`, which is the
    ///   kind of small lie that costs an afternoon when someone greps for it.
    /// - Parameter failed: whether the tool refused. **Phone-answered tools need this
    ///   passed explicitly**, because the detection that catches a refused *server-side*
    ///   tool reads the MCP result event — and a tool answered here never produces one.
    ///   Without it a refused save drew a tick, which is the exact failure the warning
    ///   glyph exists to prevent, just on the other half of the tool surface.
    /// - Parameter dial: the `dialGeneration` captured before the async work that produced
    ///   this result, for a step that can outlive the call it started in (a slow local queue
    ///   page or mail search). `nil` for callers whose work cannot outlive a dial. Guards the
    ///   same hazard `publishQueueCard` guards for the Live Activity card — without it, a
    ///   step that resolves after a hangup-and-redial posts its answer and asks the model to
    ///   speak about it in the *new*, unrelated call.
    // MARK: - The user's own commands

    /// `commands` — everything about the user's own commands, routed on `action`.
    ///
    /// **One tool, two answer shapes.** `run` returns steps and no names, `list` returns names
    /// and no steps. A description sitting beside the instructions got the work done twice,
    /// because a tool result is one blob of text in which every sentence is a candidate
    /// instruction. Do not merge the two shapes back together to save a branch.
    func answerCommands(callId: String, argumentsJSON: String) {
        let toolArguments = ToolArguments(argumentsJSON)
        switch toolArguments.string("action") ?? "run" {
        case "list": answerCommandNames(callId: callId)
        case "run": answerCommandRun(callId: callId, keyword: toolArguments.string("keyword") ?? "")
        default: answerCommandManage(callId: callId, argumentsJSON: argumentsJSON)
        }
    }

    /// Read one enabled command; a missing keyword must not expand to the entire library.
    private func answerCommandRun(callId: String, keyword: String) {
        let args = GmailReadTools.json(["command": keyword])
        startDispatch(callId: callId, argumentsJSON: args)
    }

    /// `summarize` — the last step of a command, where the assistant says what it found. It
    /// fetches nothing; it exists so the step is visible like every other. The output is an
    /// instruction to speak rather than the text echoed back, which invites silence.
    func answerSummarise(callId: String, argumentsJSON: String) {
        let started = Date()
        let text = Self.stringArgument("text", in: argumentsJSON) ?? ""
        let output = text.isEmpty
            ? "Nothing was passed to summarize. Say what you found, in your own words."
            : "Say that to the user now, in those words."
        finishContextTool(
            callId: callId, tool: "summarize", output: output,
            ms: Date().timeIntervalSince(started) * 1000,
            outcome: text.isEmpty ? "local_empty" : "local_ok",
            query: "", detail: "\(text.count) char(s)", subsystem: "commands")
    }

    /// `list` — what the user has, for telling them. Names, never steps.
    private func answerCommandNames(callId: String) {
        let started = Date()
        let enabled = customCommands.enabledCommands
        let output: String
        if enabled.isEmpty {
            output = "This user has no commands switched on. They can make one by saying "
                + "\"save a command called X that means…\", where X is a word or a short "
                + "phrase of up to four words."
        } else {
            output = "The user's commands, to read back to them. Names only — there is "
                + "nothing here to do.\n"
                + enabled.map { command in
                    command.instruction.isEmpty
                        ? "• \(command.keyword)"
                        : "• \(command.keyword): \(command.instruction)"
                }.joined(separator: "\n")
        }
        finishContextTool(
            callId: callId, tool: "commands", output: output,
            ms: Date().timeIntervalSince(started) * 1000,
            outcome: enabled.isEmpty ? "local_empty" : "local_hit",
            query: "", detail: "\(enabled.count) name(s)", subsystem: "commands")
    }

    /// `save`, `delete`, `enable`, `disable` — through the store, the same path as the Settings
    /// toggle, so the two cannot drift.
    private func answerCommandManage(callId: String, argumentsJSON: String) {
        let toolArguments = ToolArguments(argumentsJSON)
        let action = toolArguments.string("action") ?? ""
        let keyword = toolArguments.string("keyword") ?? ""
        FullDuplexTrace.note("!! commands \(action) \"\(keyword)\"")
        let started = Date()
        Task { [weak self] in
            guard let self else { return }
            let outcome: CustomCommandStore.Outcome
            switch action {
            case "save":
                outcome = await customCommands.save(
                    keyword: keyword, label: toolArguments.string("label") ?? "",
                    actions: toolArguments.actions)
            case "correct_label":
                outcome = await customCommands.correctLabel(keyword: keyword,
                    name: toolArguments.string("label_name") ?? "",
                    account: toolArguments.string("account") ?? "")
            case "delete":
                outcome = await customCommands.delete(keyword: keyword)
            case "enable", "disable":
                outcome = await customCommands.setEnabled(keyword: keyword, to: action == "enable")
            default:
                // A schema `enum` is a strong hint, not a guarantee.
                outcome = .refused("\"\(action)\" is not something you can do to a command. Use run, list, "
                    + "save, delete, enable or disable.")
            }
            if case .saved = outcome { refreshCommandTools() }
            finishCommandWrite(callId: callId, action: action, keyword: keyword, outcome: outcome,
                               ms: Date().timeIntervalSince(started) * 1000)
        }
    }

    /// A write's result as something the model can say. A refusal and a failure both mean it
    /// did not happen, and stay distinguishable: a refusal is the user's phrasing, which they can
    /// fix in the next breath; a failure is ours. The receipt names what was stored, not what was asked.
    private func finishCommandWrite(
        callId: String, action: String, keyword: String,
        outcome: CustomCommandStore.Outcome, ms: Double
    ) {
        let output: String
        let result: String
        switch outcome {
        case .saved(let command):
            let name = command?.keyword ?? keyword
            switch action {
            case "correct_label":
                output = "Saved the label correction to \"\(name)\". Its remaining steps are unchanged. "
                    + "Confirm the correction is saved; do not ask the same label question again or claim the email has been processed."
            case "save":
                output = "Saved. \"\(name)\" is now a command. Say the keyword back "
                    + "to the user and confirm it is ready to use."
            case "delete":
                output = "Deleted \"\(name)\". Say which one went."
            case "enable":
                output = "\"\(name)\" is switched on. Say so."
            default:
                output = "\"\(name)\" is switched off. It is not deleted — say it is off."
            }
            result = "ok"
        case .refused(let why):
            output = why
            result = "refused"
        case .failed(let why):
            output = "NOT SAVED — \(why) Tell the user it did not save."
            result = "failed"
        }
        finishContextTool(
            callId: callId, tool: "commands", output: output, ms: ms,
            outcome: "local_\(result)", query: keyword,
            detail: "\(action) → \(result)", subsystem: "commands",
            failed: result != "ok")
    }

    /// The `actions` array out of the tool's JSON. Lenient: `CustomCommandRules` is the boundary.
    nonisolated static func actionsArgument(in json: String) -> [CommandAction] {
        ToolArguments(json).actions
    }
}
