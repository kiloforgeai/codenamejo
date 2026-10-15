#if DEBUG
import Foundation
import FoundationModels

/// `LOCAL_TOOL_EVAL=1` at launch: phrases from real local calls, run through Apple's model and
/// Gemma with tools that only record, scored on which tool each model picked. Console log only.
enum LocalToolEval {
    enum Context { case email, open }

    struct Case {
        let phrase: String
        let expect: String?
        let context: Context
    }

    static let cases: [Case] = [
        Case(phrase: "Can you label this Kilo Forge, please?", expect: "label_current_email", context: .email),
        Case(phrase: "Can you go ahead and archive this, please?", expect: "archive_current_email", context: .email),
        Case(phrase: "Reply saying I'll have it to you by Thursday, and send it.", expect: "reply_to_current_email",
             context: .email),
        Case(phrase: "What did they ask me to do?", expect: nil, context: .email),
        Case(phrase: "Yeah, go ahead.", expect: nil, context: .email),
        Case(phrase: "What is on my calendar for today?", expect: "read_calendar", context: .email),
        Case(phrase: "Okay, can you book, uh, two to 3:00 p.m. for me for massage, please?", expect: "add_calendar_event",
             context: .email),
        Case(phrase: "Can you cancel my lunch, please?", expect: "cancel_calendar_event", context: .email),
        Case(phrase: "There should be a block on my calendar from 12 to 1 for lunch. Can you cancel this for me, please?",
             expect: "cancel_calendar_event", context: .email),
        Case(phrase: "Uh, can you cancel my day and stand up at 4 p.m., please?", expect: "cancel_calendar_event",
             context: .email),
        Case(phrase: "Put this on my calendar for Thursday at 10.", expect: "add_calendar_event", context: .email),
        Case(phrase: "What do I have on Thursday?", expect: "read_calendar", context: .open),
        Case(phrase: "Add dentist tomorrow at 3.", expect: "add_calendar_event", context: .open),
        Case(phrase: "Cancel my 12 to 1 lunch today.", expect: "cancel_calendar_event", context: .open),
        Case(phrase: "Am I free tomorrow at 3?", expect: "read_calendar", context: .open),
        Case(phrase: "Is the dentist still on tomorrow?", expect: "read_calendar", context: .open),
    ]

    static let email = """
    From: Sam Rivera <sam@example.com>
    Subject: Q4 budget sheet
    Date: Wed, 14 Oct 2026 09:12:00 -0400

    Hi Raghav, could you look over the Q4 budget sheet before Thursday and send me your notes? \
    The marketing line is the one I'm least sure about. Thanks, Sam
    """

    /// Wednesday, October 14, 2026, 3:12 PM in the phone's zone, so "Thursday" is day 1.
    static var now: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 15, minute: 12)) ?? Date()
    }

    @MainActor
    static func run() async {
        RealtimeLog.log("eval: \(cases.count) phrases")
        if #available(iOS 27.0, *) {
            let system = SystemLanguageModel.default
            RealtimeLog.log("eval: on-device model is \(system.variant.displayName), context \(system.contextSize) tokens")
        }
        var systemScore = await score("system") { tools, instructions in
            LanguageModelSession(tools: tools, instructions: instructions)
        }
        // The cloud model traps, not throws, without Apple's managed
        // com.apple.developer.private-cloud-compute entitlement, so it runs only when asked for.
        var cloudScore = -1
        if #available(iOS 27.0, *), ProcessInfo.processInfo.environment["LOCAL_TOOL_EVAL"] == "cloud" {
            let cloud = PrivateCloudComputeLanguageModel()
            RealtimeLog.log("eval: cloud model \(String(describing: cloud.availability)), quota \(String(describing: cloud.quotaUsage.status))")
            if case .available = cloud.availability {
                cloudScore = await score("cloud") { tools, instructions in
                    LanguageModelSession(model: cloud, tools: tools, instructions: Instructions(instructions))
                }
                RealtimeLog.log("eval: cloud quota after \(String(describing: cloud.quotaUsage.status))")
            }
        }
        var tunedScore = -1
        if #available(iOS 27.0, *), ProcessInfo.processInfo.environment["LOCAL_TOOL_EVAL"] == "tuned" {
            do {
                try await LocalModel.Tuned.preload()
                tunedScore = await score("tuned", tuned: true) { tools, instructions in
                    LanguageModelSession(model: LocalModel.Tuned.model, tools: tools, instructions: Instructions(instructions))
                }
            } catch {
                RealtimeLog.log("eval: tuned gemma could not load — \(error)")
            }
        }
        var gemmaScore = -1
        if #available(iOS 27.0, *), ProcessInfo.processInfo.environment["LOCAL_TOOL_EVAL"] == "gemma" {
            do {
                try await LocalModel.Gemma.preload()
                gemmaScore = await score("gemma") { tools, instructions in
                    LanguageModelSession(model: LocalModel.Gemma.model, tools: tools, instructions: Instructions(instructions))
                }
            } catch {
                RealtimeLog.log("eval: gemma could not load — \(error)")
            }
        }
        if systemScore < 0 { systemScore = 0 }
        RealtimeLog.log("eval: done — system \(systemScore)/\(cases.count), cloud \(cloudScore)/\(cases.count), "
            + "gemma \(gemmaScore)/\(cases.count), tuned \(tunedScore)/\(cases.count)")
    }

    @MainActor
    private static func score(_ label: String, tuned: Bool = false,
                              session: ([any Tool], String) -> LanguageModelSession) async -> Int {
        var right = 0
        for item in cases {
            let recorder = Recorder()
            let tools: [any Tool] = [
                RecordArchive(recorder: recorder), RecordReply(recorder: recorder), RecordLabel(recorder: recorder),
                RecordRead(recorder: recorder), RecordAdd(recorder: recorder), RecordCancel(recorder: recorder),
            ]
            let instructions: String
            let prompt: String
            let options: GenerationOptions
            switch item.context {
            case .email:
                instructions = tuned ? LocalInbox.tunedInstructions : LocalInbox.conversationInstructions
                prompt = "Current email data:\n<email>\n\(email)\n</email>\nNow: \(LocalVoiceCalendar.spokenNow(now)).\n"
                    + "User request: \(item.phrase)"
                options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 180)
            case .open:
                instructions = (try? LivePrompt.Text.bundled(
                    tuned ? LocalVoiceBrain.tunedPromptName : LocalVoiceBrain.offlinePromptName)) ?? ""
                prompt = LocalVoiceBrain.offlinePrompt(item.phrase, history: [], now: now)
                options = GenerationOptions(temperature: 0.5, maximumResponseTokens: 220)
            }
            let started = Date()
            var reply = ""
            var failure: String?
            do {
                reply = try await session(tools, instructions).respond(to: prompt, options: options).content
            } catch {
                failure = String(describing: error).prefix(160).description
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let calls = await recorder.calls
            let picked = calls.first.map { $0.split(separator: "{").first.map(String.init) ?? $0 }
            let ok = picked == item.expect
            if ok { right += 1 }
            let said = failure.map { "failed: \($0)" } ?? "\"\(reply.prefix(100))\""
            RealtimeLog.log("eval[\(label)] \(ok ? "✓" : "✗") \"\(item.phrase)\" → "
                + (calls.isEmpty ? "(no tool)" : calls.joined(separator: " + ")) + " \(said) in \(ms) ms")
        }
        RealtimeLog.log("eval[\(label)]: \(right)/\(cases.count)")
        return right
    }
}

private actor Recorder {
    private(set) var calls: [String] = []
    func record(_ call: String) { calls.append(call) }
}

private struct RecordArchive: Tool {
    let name = "archive_current_email"
    let description = "Archives the email the user is looking at. Use when the user asks to archive it."
    @Generable struct Arguments {
        @Guide(description: "True when the user asked to archive the current email.")
        var confirmed: Bool
    }
    let recorder: Recorder
    func call(arguments: Arguments) async throws -> String {
        await recorder.record("archive_current_email{confirmed:\(arguments.confirmed)}")
        return "Archived. The next email will be presented. Say nothing more."
    }
}

private struct RecordReply: Tool {
    let name = "reply_to_current_email"
    let description = "Writes a reply to the email the user is looking at: saves it as a Gmail draft, or sends it when the user said to send it."
    @Generable struct Arguments {
        @Guide(description: "The reply text, written as the user, in plain text. No subject line.")
        var body: String
        @Guide(description: "True only when the user said to send the reply. False saves it as a draft.")
        var send: Bool
    }
    let recorder: Recorder
    func call(arguments: Arguments) async throws -> String {
        await recorder.record("reply_to_current_email{send:\(arguments.send), body:\"\(arguments.body.prefix(40))\"}")
        return arguments.send ? "Sent." : "Saved as a draft."
    }
}

private struct RecordLabel: Tool {
    let name = "label_current_email"
    let description = "Files the email the user is looking at under a Gmail label. Use when the user asks to label, file or tag it."
    @Generable struct Arguments {
        @Guide(description: "The label name exactly as the user said it.")
        var label: String
    }
    let recorder: Recorder
    func call(arguments: Arguments) async throws -> String {
        await recorder.record("label_current_email{label:\"\(arguments.label)\"}")
        return "Filed under \(arguments.label)."
    }
}

private struct RecordRead: Tool {
    let name = LocalVoiceCalendar.read
    let description = "What is on the user's calendar on a day, or over the next few days."
    @Generable struct Arguments {
        @Guide(description: "Days from today: 0 is today, 1 is tomorrow.", .range(0...13))
        var dayOffset: Int
        @Guide(description: "How many days to include from that day: 1 for that day only, 7 for a week.", .range(1...7))
        var days: Int
    }
    let recorder: Recorder
    func call(arguments: Arguments) async throws -> String {
        await recorder.record("read_calendar{dayOffset:\(arguments.dayOffset), days:\(arguments.days)}")
        return "Tomorrow you have 2 things: Standup at 9:30 AM, and Dentist at 3 PM."
    }
}

private struct RecordAdd: Tool {
    let name = LocalVoiceCalendar.add
    let description = "Adds an event to the user's calendar. Use only when the user asked to add, schedule or "
        + "block something and gave a day and a time."
    @Generable struct Arguments {
        @Guide(description: "The event title, in the user's words.")
        var title: String
        @Guide(description: "Days from today: 0 is today, 1 is tomorrow.", .range(0...30))
        var dayOffset: Int
        @Guide(description: "Start hour, 0 to 23.", .range(0...23))
        var hour: Int
        @Guide(description: "Start minute.", .range(0...59))
        var minute: Int
        @Guide(description: "Length in minutes; 60 when the user gave none.", .range(5...480))
        var durationMinutes: Int
    }
    let recorder: Recorder
    func call(arguments: Arguments) async throws -> String {
        await recorder.record("add_calendar_event{title:\"\(arguments.title)\", dayOffset:\(arguments.dayOffset), "
            + "hour:\(arguments.hour), minute:\(arguments.minute), minutes:\(arguments.durationMinutes)}")
        return "Added \(arguments.title)."
    }
}

private struct RecordCancel: Tool {
    let name = LocalVoiceCalendar.cancel
    let description = "Cancels an event on the user's calendar. Use only when the user asked to cancel, delete or "
        + "remove one and named it."
    @Generable struct Arguments {
        @Guide(description: "Days from today: 0 is today, 1 is tomorrow.", .range(0...30))
        var dayOffset: Int
        @Guide(description: "The event's name as the user said it, without the time or words like the or my.")
        var title: String
        @Guide(description: "Start hour, 0 to 23, when the user said a time; -1 when they did not.", .range(-1...23))
        var hour: Int
    }
    let recorder: Recorder
    func call(arguments: Arguments) async throws -> String {
        await recorder.record("cancel_calendar_event{dayOffset:\(arguments.dayOffset), title:\"\(arguments.title)\", "
            + "hour:\(arguments.hour)}")
        return "Cancelled \(arguments.title)."
    }
}
#endif
