import FactoryKit
import Foundation

extension FullDuplexVoiceClient {
    func finishContextTool(
        callId: String, tool: String, output: String, ms: Double,
        outcome: String, query: String, detail: String, visible: Bool = true,
        subsystem: String = "localContext", failed: Bool = false, dial: Int? = nil,
        alreadyStarted: Bool = false
    ) {
        guard isActive else { return }
        if let dial, dial != dialGeneration { return }
        if visible {
            if !alreadyStarted { onToolUse?(tool) }
            onToolDone?(tool)
            if failed { onToolFailed?(tool) }
        }
        sendFunctionOutput(callId: callId, output: output)
        RealtimeLog.log("\(subsystem): \(tool) — \(detail) [\(outcome)] in "
            + String(format: "%.0f ms", ms))
        continueAfterFunctionResult()
    }

    /// A cancelled handler still owes an output so later turns can proceed.
    func finishSupersededTool(
        callId: String, tool: String, result: String, ms: Double,
        subsystem: String, dial: Int? = nil, alreadyStarted: Bool = false
    ) {
        finishContextTool(callId: callId, tool: tool,
            output: result + " The application stopped handling this action before advancing. "
                + "The result above stands; do not repeat the action and do not advance the queue.",
            ms: ms, outcome: "cancelled", query: "", detail: "superseded before its result was handled",
            subsystem: subsystem, failed: true, dial: dial, alreadyStarted: alreadyStarted)
    }

    /// The `output` field of an `mcp_call` item.
    static func mcpOutput(from itemJSON: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(itemJSON.utf8)),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary["output"] as? String
    }

    static func calendarMCPOutcome(
        itemJSON: String, output: String?
    ) -> (complete: Bool, successfulAccounts: [String]) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(itemJSON.utf8)),
              let dictionary = object as? [String: Any],
              let output,
              !ToolNarration.isRefusal(output)
        else { return (false, []) }
        if let error = dictionary["error"], !(error is NSNull) { return (false, []) }
        let lowered = output.lowercased()
        guard !lowered.contains("call failed")
            && !lowered.contains("could not reach")
            && !lowered.contains("unavailable")
        else { return (false, []) }
        guard let data = output.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !rows.isEmpty else { return (false, []) }
        let successful = rows.compactMap { row -> String? in
            if let error = row["error"], !(error is NSNull) { return nil }
            guard row["events"] is [Any] else { return nil }
            return row["account"] as? String
        }
        return (successful.count == rows.count, successful)
    }

    /// One string argument out of a tool's JSON, without a schema for the rest.
    static func stringArgument(_ key: String, in json: String) -> String? {
        ToolArguments(json).string(key)
    }

    static func replacingStringArgument(_ key: String, with value: String, in json: String) -> String {
        ToolArguments(json).replacingString(key, with: value)
    }

    /// One integer argument, same shape as `stringArgument` above. Accepts a JSON string too
    /// — models pass `"3"` as readily as `3` for a numeric field.
    static func intArgument(_ key: String, in json: String) -> Int? {
        ToolArguments(json).integer(key)
    }

    /// Preserve an absent flag so callers can distinguish it from an explicit false.
    static func boolArgument(_ key: String, in json: String) -> Bool? {
        ToolArguments(json).bool(key)
    }

    /// Include pending local write failures with every function output.
    func sendFunctionOutput(callId: String, output: String) {
        transport?.sendFunctionOutput(callId: callId,
            output: Container.shared.localWriteNotices().appending(to: output, conversation: conversationId()))
    }

    /// Run a tool locally and hold the conversation open until it answers.
    func runFunctionToolBlocking(
        callId: String, name: String, argumentsJSON: String
    ) {
        // `runTool` has no server path: every tool, mail and connectors alike, runs here.
        RealtimeLog.log("tools: \(name) — running on the phone")
        FullDuplexTrace.note("!! function call \(name) — running on the phone")
        onToolUse?(name)
        functionCallTask?.cancel()
        functionCallTask = Task { [weak self] in
            let result = await FullDuplexBroker.runTool(
                name: name, argumentsJSON: argumentsJSON)
            guard let self, self.isActive else { return }
            guard !Task.isCancelled else {
                // `functionCallTask` now belongs to whoever cancelled this one; only the answer is owed.
                self.finishSupersededTool(callId: callId, tool: name, result: result.text, ms: 0,
                    subsystem: "tools", alreadyStarted: true)
                return
            }
            let output = result.text
            if let effects = result.effects {
                let store = Container.shared.mailStore()
                _ = await self.localTriage.applyConfirmedEffects(effects, store: store)
            }
            self.functionCallTask = nil
            self.sendFunctionOutput(callId: callId, output: output)
            self.onToolDone?(name)
            RealtimeLog.log("tools: \(name) result posted — \(output.prefix(80))")
            self.continueAfterFunctionResult()
        }
    }
}
