import Foundation

/// The Live speaker and brain prompts, assembled on the phone from the bundled `prompts/` text
/// and the per-user facts `LiveSessionSetup` decides.
enum LivePrompt {
    static let speakerModel = "gpt-live-1"
    static let brainModel = "gpt-5.6-luna"
    static let voice = "marin"

    struct MissingText: LocalizedError {
        let name: String
        var errorDescription: String? { "The app is missing its prompt file \(name).md." }
    }

    /// Reads `prompts/<name>.md`, dropping the file's final newline.
    struct Text {
        let root: URL
        static var bundled: Text {
            Text(root: Bundle.main.bundleURL.appendingPathComponent("prompts", isDirectory: true))
        }

        func callAsFunction(_ name: String, _ values: [String: String] = [:]) throws -> String {
            guard var text = try? String(contentsOf: root.appendingPathComponent(name + ".md"), encoding: .utf8)
            else { throw MissingText(name: name) }
            if text.hasSuffix("\n") { text.removeLast() }
            for (key, value) in values { text = text.replacingOccurrences(of: "{{\(key)}}", with: value) }
            return text
        }
    }

    /// What the session setup knows about this user and session, as data. Absent keys are off.
    struct Facts {
        var skills: [String] = []
        var memory = false
        var profiles = false, profileManagement = false
        var calendarAccounts: [String] = []
        var localClock = false
        var fiveStepResume = false
        var fiveStepOpening: String?
        var sequentialOpening = false
        var feedOffer = false
        var coaching: String?
        var localCoachingDelivery = false, localTriage = false, noDeviceMail = false
        var localSlackTriage = false, slackFeedStage = false, importantSlackStage = false
        var triageScope: String?
        var calendar = false
        var dispatch = false, emailLinkDispatch = false, endSession = false
        var mailModeSwitching = false
        var drafting: [String] = [], sending: [String] = []
        var googleNeedsReauth: [String] = [], googleUnreachable: [String] = []
        var notionNeedsReauth: [String] = []
        var granolaNeedsReauth: [String] = []
        var slackNeedsReauth: [String] = []
        var githubNeedsReauth: [String] = []
        /// The user's own MCP servers serving this call, and the ones needing reconnecting.
        var customMCP: [String] = []
        var customMCPNeedsReauth: [String] = []
        /// The user's saved commands: the section explaining them, and every keyword, switched off or not.
        var commands = false
        var commandKeywords: [String] = []
        var profileContext: String?

        init() {}

        init(_ json: [String: Any]) {
            func flag(_ key: String) -> Bool { json[key] as? Bool ?? false }
            func list(_ key: String) -> [String] { json[key] as? [String] ?? [] }
            skills = list("skills")
            memory = flag("memory")
            profiles = flag("profiles"); profileManagement = flag("profileManagement")
            calendarAccounts = list("calendarAccounts"); localClock = flag("localClock")
            if let five = json["fiveStepOnboarding"] as? [String: Any] {
                fiveStepResume = five["resume"] as? Bool ?? false
                fiveStepOpening = five["opening"] as? String ?? ""
            }
            sequentialOpening = flag("sequentialOpening")
            feedOffer = flag("feedOffer")
            coaching = json["coaching"] as? String
            localCoachingDelivery = flag("localCoachingDelivery"); localTriage = flag("localTriage")
            noDeviceMail = flag("noDeviceMail")
            localSlackTriage = flag("localSlackTriage"); slackFeedStage = flag("slackFeedStage")
            importantSlackStage = flag("importantSlackStage")
            triageScope = json["triageScope"] as? String
            calendar = flag("calendar")
            dispatch = flag("dispatch"); emailLinkDispatch = flag("emailLinkDispatch"); endSession = flag("endSession")
            mailModeSwitching = flag("mailModeSwitching")
            drafting = list("drafting"); sending = list("sending")
            googleNeedsReauth = list("googleNeedsReauth"); googleUnreachable = list("googleUnreachable")
            notionNeedsReauth = list("notionNeedsReauth")
            granolaNeedsReauth = list("granolaNeedsReauth")
            slackNeedsReauth = list("slackNeedsReauth")
            githubNeedsReauth = list("githubNeedsReauth")
            customMCP = list("customMCP"); customMCPNeedsReauth = list("customMCPNeedsReauth")
            commands = flag("commands"); commandKeywords = list("commandKeywords")
            profileContext = (json["profileContext"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// The `/v1/live/sessions` session object and the brain's Responses config.
    static func configs(facts: Facts, tools: [Any], fastActions: Bool, timeZone: String,
                        now: Date = Date(), text: Text = .bundled) throws -> (session: [String: Any], brain: [String: Any]) {
        let toolNames = Set(tools.compactMap { ($0 as? [String: Any])?["name"] as? String })
        let speaker = try speakerInstructions(fastActions: fastActions, toolNames: toolNames, text: text)
        let brain = try brainInstructions(facts, timeZone: timeZone, now: now, text: text)
        let tail = try "\n" + text("brain") + (fastActions ? "\n" + text("fast-actions") : "")
        func session(_ profile: String) -> [String: Any] {
            ["model": speakerModel, "instructions": speaker + profile,
             "audio": ["output": ["voice": voice]], "delegation": ["type": "client"]]
        }
        func responses(_ profile: String) -> [String: Any] {
            ["model": brainModel, "reasoning": ["effort": "low"], "parallel_tool_calls": false,
             "service_tier": "priority", "instructions": brain + profile + tail, "tools": tools]
        }
        var profile = ""
        if let block = facts.profileContext {
            let candidate = "\n" + block
            if fits(session(candidate)) && fits(responses(candidate)) { profile = candidate }
        }
        return (session(profile), responses(profile))
    }

    /// The profile overview rides only when both requests stay inside a 32k context with room to answer.
    private static func fits(_ request: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return false }
        return data.count / 4 + 8192 + 256 <= 32768
    }

    static func speakerInstructions(fastActions: Bool, toolNames: Set<String>, text: Text = .bundled) throws -> String {
        var out = try text("speaker")
        if fastActions { out += try "\n" + text("fast-actions") }
        let abilities = (toolNames.contains("read_texts") ? ["check unread SMS/iMessage texts"] : [])
            + (toolNames.contains("send_text") ? ["send SMS/iMessage texts"] : [])
        if !abilities.isEmpty {
            out += try "\n" + text("speaker-messaging", ["abilities": abilities.joined(separator: " and ")])
        }
        return out
    }

    private static let skillOrder = ["email", "calendar", "slack", "notion", "granola", "github"]

    static func baseInstructions(_ facts: Facts, text: Text) throws -> String {
        let skills = try skillOrder.filter(facts.skills.contains).map { name in
            try text("skills/" + name).split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !["<!-- guardrail -->", "<!-- /guardrail -->"].contains($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: "\n").trimmingTrailingWhitespace
        }
        var sections = [try text("base/role")]
        if facts.memory { sections.append(try text("base/memory")) }
        sections.append(try text("base/confirm-first"))
        sections += skills
        sections.append(try text("base/web"))
        if facts.commands { sections.append(try text("base/commands")) }
        sections.append(try text("base/reminder"))
        return sections.joined(separator: "\n\n")
    }

    static func brainInstructions(_ f: Facts, timeZone: String, now: Date = Date(), text: Text = .bundled) throws -> String {
        func addendum(_ name: String) throws -> String { try "\n" + text("addenda/" + name) }
        var s = ""
        if f.profiles || f.profileManagement {
            s += try "\n" + text("notes/profiles") + "\n" + text("notes/profiles-switch") + "\n"
        }
        if f.profileManagement { s += try text("notes/profiles-manage") + "\n" }
        s += try baseInstructions(f, text: text)
        s += try addendum("spoken")
        if let note = try calendarNote(f, timeZone: timeZone, now: now, text: text) { s += "\n\n" + note }
        if let line = f.fiveStepOpening {
            let opening = try f.fiveStepResume
                ? text("onboarding/five-step-resume", ["line": line])
                : text("onboarding/five-step-first", ["line": line])
            s += try "\n" + text("onboarding/five-step", ["opening": opening]) + "\n"
        }
        if f.sequentialOpening { s += try addendum("sequential-email-queue-opening") }
        if f.feedOffer { s += try addendum("sequential-email-feed-offer") }
        if let coaching = f.coaching {
            s += try addendum(coaching == "lessons" ? "interactive-coaching" : "no-interactive-coaching")
        }
        if f.localCoachingDelivery { s += try addendum("local-coaching-delivery") }
        if f.localTriage { s += try addendum("local-triage") }
        if f.localSlackTriage { s += try addendum("local-slack-triage") }
        if f.slackFeedStage { s += try addendum("slack-feed-stage") }
        if f.importantSlackStage { s += try addendum("important-slack-stage") }
        if f.noDeviceMail { s += try addendum("no-device-mail") }
        if let scope = f.triageScope {
            s += try addendum("triage-default").replacingOccurrences(of: "{PILE}", with: pileLabel(scope))
                .replacingOccurrences(of: "{SCOPE}", with: scope)
        }
        if f.calendar { s += try addendum("calendar-read") }
        if f.dispatch { s += try addendum("dispatch") }
        if f.dispatch && f.emailLinkDispatch { s += try addendum("email-link-dispatch") }
        if f.endSession { s += try addendum("end-session") }
        if f.mailModeSwitching {
            s += try addendum("mail-mode") + "\n"
        } else {
            s += try "\n" + text("notes/mail-preferences", [
                "drafting": f.drafting.isEmpty ? "none" : f.drafting.joined(separator: ", "),
                "sending": f.sending.isEmpty ? "none" : f.sending.joined(separator: ", "),
            ]) + "\n"
        }
        if f.calendar { s += try addendum("calendar-write") }
        if !f.customMCP.isEmpty {
            s += try "\n\n" + text("notes/custom-mcp", ["servers": f.customMCP.joined(separator: ", ")])
        }
        if !f.commandKeywords.isEmpty {
            s += try "\n\n" + text("notes/commands") + "\n" + f.commandKeywords.map { "- " + $0 }.joined(separator: "\n")
        }
        for note in try [googleNote(f, text: text),
                         reauthNote("notion-reauth", "Notion", f.notionNeedsReauth, text: text),
                         reauthNote("granola-reauth", "Granola", f.granolaNeedsReauth, text: text),
                         reauthNote("slack-reauth", "Slack", f.slackNeedsReauth, text: text),
                         reauthNote("github-reauth", "GitHub", f.githubNeedsReauth, text: text),
                         customMCPReauthNote(f, text: text)] where !note.isEmpty {
            s += "\n\n" + note
        }
        return s
    }

    static func pileLabel(_ scope: String) -> String {
        switch scope {
        case "all": "your whole inbox, read mail included"
        case "important": "your most important mail from this week"
        default: "your unread mail"
        }
    }

    static func calendarNote(_ f: Facts, timeZone: String, now: Date, text: Text) throws -> String? {
        guard !f.calendarAccounts.isEmpty else { return nil }
        let zone = TimeZone(identifier: timeZone) == nil ? "UTC" : timeZone
        let seconds = TimeZone(identifier: zone)?.secondsFromGMT(for: now) ?? 0
        let offset = String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
        let today = try f.localClock
            ? text("notes/calendar-today-tool")
            : text("notes/calendar-today-clock", ["zone": zone])
        return try text("notes/calendar", ["accounts": f.calendarAccounts.joined(separator: ", "),
            "zone": zone, "offset": offset, "today": today])
    }

    static func googleNote(_ f: Facts, text: Text) throws -> String {
        var parts: [String] = []
        if !f.googleNeedsReauth.isEmpty {
            parts.append(try text("notes/google-reauth", ["accounts": f.googleNeedsReauth.joined(separator: " and "),
                "which": f.googleNeedsReauth.count == 1 ? "that account" : "those accounts"]))
        }
        if !f.googleUnreachable.isEmpty {
            parts.append(try text("notes/google-unreachable", ["accounts": f.googleUnreachable.joined(separator: " and "),
                "which": f.googleUnreachable.count == 1 ? "that account is" : "those accounts are"]))
        }
        return parts.joined(separator: " ")
    }

    /// Named by server rather than by account: a custom server has no account label of its own.
    static func customMCPReauthNote(_ f: Facts, text: Text) throws -> String {
        guard !f.customMCPNeedsReauth.isEmpty else { return "" }
        let names = f.customMCPNeedsReauth.joined(separator: " and ")
        let which = f.customMCPNeedsReauth.count == 1 ? "their \(names) server" : "their \(names) servers"
        return try text("notes/custom-mcp-reauth", ["which": which])
    }

    static func reauthNote(_ name: String, _ service: String, _ accounts: [String], text: Text) throws -> String {
        guard let first = accounts.first else { return "" }
        let which = accounts.count == 1 ? "their \(service) connection (\(first))" : "their \(service) connections"
        return try text("notes/" + name, ["which": which])
    }
}

private extension String {
    var trimmingTrailingWhitespace: String {
        var out = self
        while let last = out.last, last.isWhitespace { out.removeLast() }
        return out
    }
}
