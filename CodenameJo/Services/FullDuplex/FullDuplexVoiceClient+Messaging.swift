import FactoryKit
import Foundation

extension FullDuplexVoiceClient {
    /// Return the handoff immediately; the existing report queue speaks the final outcome.
    private func beginShortcut(callId: String, tool: String) -> Bool {
        guard shortcutActions.isAvailable else {
            postDispatchOutput(callId: callId, startedWork: false,
                output: "Messaging is unavailable. It requires iOS 27 and the updated Jo Messages setup in Admin Settings.")
            return false
        }
        guard shortcutTask == nil, !shortcutActions.isPending else {
            postDispatchOutput(callId: callId, startedWork: false,
                output: "A messaging action is already pending. Do not start or retry it; its result will arrive separately.")
            return false
        }
        onToolUse?(tool)
        postDispatchOutput(callId: callId,
            output: "The messaging request is pending, not completed. Do not claim success or call it again. "
                + "The final result will arrive separately.")
        return true
    }

    func answerSendText(callId: String, argumentsJSON: String) {
        let toolArguments = ToolArguments(argumentsJSON)
        let recipient = toolArguments.string("recipient") ?? ""
        let body = toolArguments.string("body") ?? ""
        let dial = dialGeneration
        guard let userID = Container.shared.backend().userId else {
            postDispatchOutput(callId: callId, startedWork: false, output: "Sign in to Jo before sending a text.")
            return
        }
        guard beginShortcut(callId: callId, tool: "send_text") else { return }
        shortcutTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.isActive, self.dialGeneration == dial else { return }
            guard Container.shared.backend().userId == userID else {
                self.shortcutTask = nil
                return
            }
            do {
                let handle = try await self.phoneContacts.handle(for: recipient)
                guard !Task.isCancelled, self.isActive, self.dialGeneration == dial else { return }
                self.shortcutTask = nil
                guard Container.shared.backend().userId == userID else { return }
                guard self.shortcutActions.isAvailable else {
                    RealtimeLog.log("shortcuts: send cancelled because messaging was disabled during contact lookup")
                    self.finishShortcut(callId: callId, argumentsJSON: argumentsJSON, tool: "send_text", result: .cancelled, dial: dial)
                    return
                }
                self.shortcutActions.sendText(to: handle, body: body) { [weak self] result in
                    self?.finishShortcut(callId: callId, argumentsJSON: argumentsJSON, tool: "send_text", result: result, dial: dial)
                }
            } catch {
                guard !Task.isCancelled, self.isActive, self.dialGeneration == dial else { return }
                self.shortcutTask = nil
                guard Container.shared.backend().userId == userID else { return }
                self.finishShortcut(callId: callId, argumentsJSON: argumentsJSON, tool: "send_text", result: .failed(error.localizedDescription), dial: dial)
            }
        }
    }

    func answerFindContact(callId: String, argumentsJSON: String) {
        let name = (Self.stringArgument("name", in: argumentsJSON) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let started = Date()
        let dial = dialGeneration
        localContextTasks[callId] = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.phoneContacts.search(name)
            guard !Task.isCancelled, self.isActive, self.dialGeneration == dial else { return }
            self.localContextTasks[callId] = nil
            let output = self.phoneContacts.modelOutput(for: outcome, query: name)
            let failed: Bool
            switch outcome {
            case .matches: failed = false
            case .denied, .needsPermission, .limited, .failed: failed = true
            }
            self.finishContextTool(
                callId: callId, tool: "find_contact", output: output,
                ms: Date().timeIntervalSince(started) * 1000,
                outcome: failed ? "contacts_unavailable" : "contacts_searched",
                query: name, detail: failed ? "unavailable" : "searched",
                subsystem: "contacts", failed: failed, dial: dial)
        }
    }

    func answerReadTexts(callId: String, argumentsJSON: String) {
        let about = Self.stringArgument("about", in: argumentsJSON) ?? ""
        let dial = dialGeneration
        if let refusal = ShortcutReadPolicy.refusal(for: argumentsJSON) {
            finishContextTool(callId: callId, tool: "read_texts", output: refusal, ms: 0,
                outcome: "unsupported_read_scope", query: about, detail: "unsupported read scope; no shortcut launched",
                subsystem: "shortcuts", failed: true, dial: dial)
            return
        }
        guard beginShortcut(callId: callId, tool: "read_texts") else { return }
        shortcutActions.readTexts(about: about) { [weak self] result in
            self?.finishShortcut(callId: callId, argumentsJSON: argumentsJSON, tool: "read_texts", result: result, dial: dial)
        }
    }

    private func finishShortcut(
        callId: String, argumentsJSON: String, tool: String,
        result: ShortcutActionRunner.Result, dial: Int
    ) {
        guard isActive, dialGeneration == dial,
              let userID = Container.shared.backend().userId else { return }
        onToolDone?(tool)
        if result.failed { onToolFailed?(tool) }
        let resultText = tool == "read_texts" ? result.readModelOutput : result.modelOutput
        let output = "Original tool: \(tool)\nCall ID: \(callId)\nArguments: \(argumentsJSON)\nResult: \(resultText)"
        pendingReports.append(DispatchReport(
            kind: .shortcut(tool: tool, userID: userID), jobId: nil, task: "\(tool) request \(callId)", text: output,
            ok: !result.failed, landedAt: .now, delivery: .nextQuietBeat, origin: nil, scope: .independent))
        drainDispatchReports()
    }
}
