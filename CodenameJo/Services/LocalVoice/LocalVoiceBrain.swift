import CryptoKit
import Foundation
import FoundationModels

/// What answers on a local call: the dispatch worker's tool loop over `/v1/responses` on the user's key,
/// or, with no key or no connection, Apple's on-device model with the calendar tools.
enum LocalVoiceBrain {
    enum Engine: String, Equatable {
        case openAI, onDevice
    }

    struct Exchange: Equatable {
        let user: String
        let assistant: String
    }

    /// The queue email a turn is about: the cursor and item the tools bind "this" to, and a
    /// note putting it in front of the model.
    struct Focus {
        let cursor: GmailManageTools.Cursor?
        let standingOn: [String: Any]?
        let note: String?
    }

    struct NoBrain: LocalizedError {
        var errorDescription: String? {
            "No connection and this phone's own model isn't available, so there is nothing to answer with."
        }
    }

    struct NoOnDeviceModel: LocalizedError {
        var errorDescription: String? {
            "Fully local mode needs Apple's on-device model. Turn on Apple Intelligence in Settings and let its models finish downloading, or turn off Fully local mode."
        }
    }

    struct EmptyReply: LocalizedError {
        var errorDescription: String? { "That didn't come back with anything to say." }
    }

    static let promptName = "local-voice"
    static let offlinePromptName = "local-voice-offline"
    /// The tuned model's shorter instructions: it learned the rules, so the prompt only names them.
    static let tunedPromptName = "local-voice-tuned"
    static let maxRounds = 8
    static let budget: TimeInterval = 45
    static let remembered = 8

    /// Which brain a local call gets. Pure, so the choice is testable.
    static func engine(hasKey: Bool, online: Bool, onDeviceAvailable: Bool) -> Engine? {
        if hasKey, online { return .openAI }
        if onDeviceAvailable { return .onDevice }
        return nil
    }

    static var onDeviceAvailable: Bool {
        if LocalModel.usesOther { return true }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// The reply as text deltas, in order. The on-device model streams as it writes; the
    /// OpenAI loop answers once its tool rounds are done, in one piece.
    static func reply(to transcript: String, history: [Exchange], engine: Engine,
                      profileId: String? = ProfileRuntime.snapshot?.profileId,
                      focus: Focus? = nil, conversationId: String? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // A tool speaks its own line and ends the turn; the model's repeat of it is cancelled.
            let voice = Voice(say: { continuation.yield($0) }, done: { continuation.finish() })
            let task = Task {
                do {
                    switch engine {
                    case .openAI:
                        continuation.yield(try await respondOpenAI(transcript, history: history, profileId: profileId,
                                                                   focus: focus))
                    case .onDevice:
                        try await respondOnDevice(transcript, history: history, conversationId: conversationId,
                                                  voice: voice) { continuation.yield($0) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - OpenAI

    static func instructions(mail: Bool, calendar: Bool, notion: Bool, text: LivePrompt.Text = .bundled) throws -> String {
        var facts = LivePrompt.Facts()
        facts.skills = (mail ? ["email"] : []) + (calendar ? ["calendar"] : []) + (notion ? ["notion"] : [])
        return try LivePrompt.baseInstructions(facts, text: text) + "\n\n" + text(promptName)
    }

    /// The last few exchanges as input messages, oldest first, then the new transcript.
    static func input(_ transcript: String, history: [Exchange]) -> [[String: Any]] {
        var items: [[String: Any]] = []
        for exchange in history.suffix(remembered) {
            items.append(["role": "user", "content": exchange.user])
            items.append(["role": "assistant", "content": exchange.assistant])
        }
        items.append(["role": "user", "content": transcript])
        return items
    }

    /// The spoken text of a Responses output: every message's output_text, joined.
    static func spokenText(_ output: [[String: Any]]) -> String {
        output.filter { $0["type"] as? String == "message" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }
            .joined(separator: " ")
    }

    @MainActor
    private static func respondOpenAI(_ transcript: String, history: [Exchange], profileId: String?,
                                      focus: Focus?) async throws -> String {
        let started = Date()
        let mail = GoogleAccountStore.mailAccounts()
        let calendar = CalendarTools.accounts()
        // Notion alone of the connectors, as before the registry: the local brain is the dispatch loop, not a call.
        let notion = NotionConnector().status(profileId: profileId)
        let relay = FullDuplexBroker.workerTools(mail: ProfileRuntime.allowedMailAccounts(mail), calendar: calendar,
                                                 connectors: [NotionConnector.id: notion])
        let relayNames = Set(relay.compactMap { $0["name"] as? String })
        let tools = DispatchWorker.tools(mail: mail, calendar: calendar, relay: relay)
        let instructions = try instructions(mail: !mail.isEmpty, calendar: !calendar.isEmpty, notion: notion.isConnected)
        let names = Set(tools.compactMap { $0["name"] as? String })
        let cacheKey = SHA256.hash(data: Data((instructions + names.sorted().joined()).utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
        var input = input(transcript, history: history)
        if let note = focus?.note { input.insert(["role": "developer", "content": note], at: input.count - 1) }

        for round in 0..<maxRounds {
            try Task.checkCancellation()
            guard Date().timeIntervalSince(started) < budget else {
                RealtimeLog.log("local-voice: brain stopped at the deadline, \(round) round(s) in")
                return "That took too long, so I stopped. Ask me again and I'll try once more."
            }
            let body: [String: Any] = [
                "model": LivePrompt.brainModel, "instructions": instructions, "input": input, "tools": tools,
                "reasoning": ["effort": "low"], "text": ["verbosity": "low"], "max_output_tokens": 1200,
                "service_tier": "priority", "store": false, "include": ["reasoning.encrypted_content"],
                "prompt_cache_key": cacheKey,
            ]
            let result = try await LiveOpenAI.responses(body, timeout: 60)
            guard let output = result["output"] as? [[String: Any]] else {
                throw LiveBrainRequestError(status: 502, serverCode: "local_voice_request_failed")
            }
            input += output
            let calls = output.filter { $0["type"] as? String == "function_call" }
            if calls.isEmpty {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                RealtimeLog.log("local-voice: brain answered in \(ms) ms after \(round) tool round(s)")
                return spokenText(output)
            }
            for call in calls {
                try Task.checkCancellation()
                let name = call["name"] as? String ?? ""
                let callId = call["call_id"] as? String ?? ""
                let arguments = call["arguments"] as? String ?? "{}"
                let result = await DispatchWorker.execute(name, arguments, relayNames: relayNames, cursor: focus?.cursor,
                                                          standingOn: focus?.standingOn, profileId: profileId)
                RealtimeLog.log("local-voice: tool \(name)\(result.failed ? " failed" : "")")
                input.append(["type": "function_call_output", "call_id": callId, "output": result.output])
            }
        }
        RealtimeLog.log("local-voice: brain hit the \(maxRounds)-round tool cap")
        return "I ran out of steps on that one. Ask me again, or ask for a smaller piece of it."
    }

    // MARK: - On device

    /// The turn as the on-device model reads it, dated so "tomorrow" and "Thursday" can become a day offset.
    static func offlinePrompt(_ transcript: String, history: [Exchange], now: Date = Date()) -> String {
        let context = history.suffix(4).map { "User: \($0.user.prefix(600))\nJo: \($0.assistant.prefix(600))" }
            .joined(separator: "\n\n")
        let dated = "Now: \(LocalVoiceCalendar.spokenNow(now)).\n"
        return context.isEmpty ? dated + transcript
            : dated + "Recent conversation, for context only:\n\(context)\n\nCurrent user message:\n\(transcript)"
    }

    /// The words a tool may act on: this turn's, plus the previous turn's when Jo answered it
    /// with a question, so "On Friday at 2" after "which day?" still carries the "cancel".
    static func authorizing(_ transcript: String, history: [Exchange]) -> String {
        guard let last = history.last, last.assistant.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        else { return transcript }
        return last.user + " " + transcript
    }

    /// The on-device instructions for the model in use.
    static func onDeviceInstructions(text: LivePrompt.Text = .bundled) throws -> String {
        try text(LocalModel.usesTuned ? tunedPromptName : offlinePromptName)
    }

    /// Readies the next turn's session while the user is still talking.
    static func prewarm() {
        guard onDeviceAvailable, let instructions = try? onDeviceInstructions() else { return }
        LocalModel.session(tools: LocalVoiceCalendar.tools(transcript: ""), instructions: instructions).prewarm()
    }

    private static func respondOnDevice(_ transcript: String, history: [Exchange],
                                        text: LivePrompt.Text = .bundled, conversationId: String?, voice: Voice,
                                        delta: (String) -> Void) async throws {
        guard onDeviceAvailable else { throw NoBrain() }
        try await LocalModel.preload()
        let started = Date()
        let tools = LocalVoiceCalendar.tools(transcript: authorizing(transcript, history: history), now: started,
                                             conversationId: conversationId, voice: voice)
        let session = LocalModel.session(tools: tools, instructions: try onDeviceInstructions(text: text))
        var previous = ""
        for try await snapshot in session.streamResponse(to: offlinePrompt(transcript, history: history, now: started),
                                                         options: GenerationOptions(temperature: 0.5,
                                                                                    maximumResponseTokens: 220)) {
            try Task.checkCancellation()
            let content = snapshot.content
            guard content.hasPrefix(previous) else { continue }
            if previous.isEmpty {
                RealtimeLog.log("local-voice: on-device model first words in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            }
            delta(String(content.dropFirst(previous.count)))
            previous = content
        }
        RealtimeLog.log("local-voice: on-device model answered in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }
}
