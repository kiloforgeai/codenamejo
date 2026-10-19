import Foundation

/// A sign-out asks the next onboarding to put the mail-mode question again, even to a
/// mailbox that answered it before. Cleared once a fresh answer is saved.
enum OnboardingMailModeReplay {
    private static let storageKey = "onboardingMailModeReplayAfterSignOut"

    static var isRequested: Bool { UserDefaults.standard.bool(forKey: storageKey) }
    static func request() { UserDefaults.standard.set(true, forKey: storageKey) }
    static func complete() { UserDefaults.standard.removeObject(forKey: storageKey) }
}

/// The run a call hung up on, kept whole so the next dial picks it back up where it stopped.
/// Cleared when the arc finishes or on sign-out — never by a hang-up.
enum OnboardingResume {
    private static let flowKey = "onboardingResumeFlow"
    private static let stepKey = "onboardingResumeStep"

    static var flow: EmailOnboardingFlow? {
        UserDefaults.standard.data(forKey: flowKey).flatMap { try? JSONDecoder().decode(EmailOnboardingFlow.self, from: $0) }
    }
    static var runId: String? { flow?.runId }
    static var step: Int { UserDefaults.standard.integer(forKey: stepKey) }
    static func begin(_ flow: EmailOnboardingFlow) {
        guard flow.runId != runId else { return }
        save(flow)
        UserDefaults.standard.removeObject(forKey: stepKey)
    }
    static func reached(step: Int, runId: String) {
        guard runId == self.runId else { return }
        UserDefaults.standard.set(step, forKey: stepKey)
    }
    /// The mail-mode question is on the floor: a resumed call opens on it instead of asking for
    /// the Nate reply again, which drafted it twice.
    static func asked(runId: String) {
        guard var flow, flow.runId == runId, let choice = flow.mailModeChoice, choice.status == "welcome" else { return }
        flow.mailModeChoice = .init(account: choice.account, status: "pending", mode: nil)
        save(flow)
    }
    /// The saved answer rides the run, so a resumed call skips the founder email and the question.
    static func saved(_ receipt: OnboardingMailModeReceipt, mode: String, runId: String) {
        guard var flow, flow.runId == runId, let choice = flow.mailModeChoice else { return }
        flow.mailModeChoice = .init(account: choice.account, status: "saved", mode: mode)
        flow.mailPreference = receipt.mailPreference
        save(flow)
    }
    static func finish() {
        UserDefaults.standard.removeObject(forKey: flowKey)
        UserDefaults.standard.removeObject(forKey: stepKey)
    }
    private static func save(_ flow: EmailOnboardingFlow) {
        var flow = flow
        flow.resume = nil
        UserDefaults.standard.set(try? JSONEncoder().encode(flow), forKey: flowKey)
    }
}

/// Builds onboarding on the phone: the bundled steps, the founder email and the mail-mode question.
enum LocalOnboardingRun {
    static func config(bundle: Bundle = .main) -> EmailOnboardingConfig? {
        let url = bundle.bundleURL.appendingPathComponent("prompts/onboarding/config.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(EmailOnboardingConfig.self, from: $0) }
    }

    /// A first call's run. A lone mailbox is asked its mail mode unless it has already answered.
    static func begin() async -> EmailOnboardingFlow? {
        guard let config = config() else {
            RealtimeLog.log("onboarding: no bundled config — dialling without it")
            return nil
        }
        let accounts = ProfileRuntime.allowedMailAccounts(GoogleAccountStore.mailAccounts())
        let welcomeStep = config.steps.firstIndex { $0.kind == "welcome" }.map { $0 + 1 }
        let welcome: EmailOnboardingItem? = if let account = accounts.first, let welcomeStep {
            await WelcomeEmail.insert(account: account, step: welcomeStep)
        } else { nil }
        let answered = UserDefaults.standard.string(forKey: EmailOnboardingContract.mailModeAccountKey) != nil
        let asks = welcome != nil && accounts.count == 1 && config.mailModeQuestion != nil
            && (OnboardingMailModeReplay.isRequested || !answered)
        let flow = EmailOnboardingFlow(version: 2, runId: UUID().uuidString, welcome: welcome,
            mailModeChoice: asks ? .init(account: accounts[0].lowercased(), status: "welcome", mode: nil) : nil,
            config: config)
        OnboardingResume.begin(flow)
        return flow
    }

    /// The run an earlier call hung up on, opened with the resume line.
    static func resumed() -> EmailOnboardingFlow? {
        guard var flow = OnboardingResume.flow else { return nil }
        flow.resume = true
        return flow
    }
}

/// The founder email a new user finds in their inbox. Written into the mailbox with
/// `messages.insert`, never sent, so it cannot land in Promotions or spam or arrive late.
enum WelcomeEmail {
    struct Copy: Decodable {
        let founder: String
        let fromName: String
        let subject: String
        let question: String
        let body: [String]
        var from: String { "\(fromName) <\(founder)>" }
    }

    static let copy: Copy? = {
        let url = Bundle.main.bundleURL.appendingPathComponent("prompts/onboarding/welcome-email.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Copy.self, from: $0) }
    }()

    /// Each onboarding adds a fresh copy to the one welcome thread: `[threadId, Message-ID]`.
    private static let threadKey = "onboardingWelcomeThread"

    /// Nil when the insert fails: the walk goes on without the founder step.
    static func insert(account: String, step: Int) async -> EmailOnboardingItem? {
        guard let copy, case .success(let token) = await GoogleCredential.token(for: account) else { return nil }
        let prior = UserDefaults.standard.stringArray(forKey: threadKey).flatMap { $0.count == 2 ? $0 : nil }
        let date = Date().addingTimeInterval(-60)
        let domain = copy.founder.split(separator: "@").last.map(String.init) ?? "localhost"
        let messageId = "<welcome.\(UUID().uuidString.lowercased())@\(domain)>"
        do {
            var inserted: [String: Any]
            do {
                inserted = try await post(raw(copy, to: account, date: date, messageId: messageId, replyTo: prior?[1]),
                                          threadId: prior?[0], token: token.accessToken)
            } catch GmailAPI.Failure.http(404) where prior != nil {
                inserted = try await post(raw(copy, to: account, date: date, messageId: messageId, replyTo: nil),
                                          threadId: nil, token: token.accessToken)
            }
            guard let id = inserted["id"] as? String, !id.isEmpty else { return nil }
            let threadId = inserted["threadId"] as? String ?? id
            // Insert accepts `labelIds` and applies none of them, so they are asked for again.
            _ = try await GmailAPI.call("POST", path: "messages/\(id)/modify",
                body: ["addLabelIds": ["INBOX", "UNREAD"]], token: token.accessToken)
            UserDefaults.standard.set([threadId, messageId], forKey: threadKey)
            RealtimeLog.log("onboarding: welcome inserted\(prior?[0] == threadId ? " onto the thread" : "")")
            let ms = Int64(date.timeIntervalSince1970 * 1000)
            return .init(account: account, id: id, threadId: threadId, from: copy.from, subject: copy.subject,
                         date: ISO8601DateFormatter().string(from: date), snippet: copy.question,
                         internalDate: ms, onboardingStep: step, cleanup: nil)
        } catch {
            RealtimeLog.log("onboarding: welcome not inserted — \(error)")
            return nil
        }
    }

    private static func post(_ raw: String, threadId: String?, token: String) async throws -> [String: Any] {
        var body: [String: Any] = ["raw": raw, "labelIds": ["INBOX", "UNREAD"]]
        if let threadId { body["threadId"] = threadId }
        return try await GmailAPI.call("POST", path: "messages", query: ["internalDateSource": "dateHeader"],
                                       body: body, token: token)
    }

    static func raw(_ copy: Copy, to account: String, date: Date, messageId: String, replyTo: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        var headers = ["From: \(copy.from)", "To: \(account)", "Subject: \(copy.subject)",
                       "Date: \(formatter.string(from: date))", "Message-ID: \(messageId)"]
        if let replyTo { headers += ["In-Reply-To: \(replyTo)", "References: \(replyTo)"] }
        headers.append("Content-Type: text/plain; charset=UTF-8")
        let body = copy.body.map { $0.replacingOccurrences(of: "{{question}}", with: copy.question.lowercased()) }
        return Data((headers + [""] + body).joined(separator: "\r\n").utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct EmailOnboardingFlow: Codable, Sendable {
    let version: Int
    let runId: String
    let welcome: EmailOnboardingItem?
    var mailPreference: OnboardingMailPreference? = nil
    var mailModeChoice: MailModeChoice? = nil
    /// v2 only: the bundled steps, snapshotted for this run.
    var config: EmailOnboardingConfig? = nil
    /// An unfinished run from an earlier call: open with `resumeLine`, not the introduction.
    var resume: Bool? = nil

    /// What the phone can seed before any mail is picked: the founder email and the beats.
    var seededItems: [EmailOnboardingItem] {
        guard let config else { return welcome.map { [$0] } ?? [] }
        return config.steps.enumerated().compactMap { index, step in
            switch step.kind {
            case "welcome": return welcome
            case "beat": return .beat(id: step.id, step: index + 1, account: welcome?.account ?? "")
            default: return nil
            }
        }
    }

    struct MailModeChoice: Codable, Sendable {
        let account: String
        let status: String
        let mode: String?
    }
}

/// Flat and all-optional so an unknown kind decodes and is skipped rather than failing the mint.
struct EmailOnboardingConfig: Codable, Sendable {
    let opening: String?
    let steps: [Step]

    struct Step: Codable, Sendable {
        let id: String
        let kind: String
        let line: String?
        let question: String?
        let query: String?
        let count: Int?
        let note: String?
        let say: String?
        let then: String?
        let tip: String?
    }

    func step(_ number: Int) -> Step? { steps.indices.contains(number - 1) ? steps[number - 1] : nil }
    var mailModeQuestion: String? { steps.first { $0.kind == "mail_mode" }?.question }
    var finish: Step? { steps.last { $0.kind == "finish" } }
}

struct EmailOnboardingItem: Codable, Sendable {
    let account: String
    let id: String
    let threadId: String
    let from: String
    let subject: String
    let date: String
    let snippet: String
    let internalDate: Int64
    let onboardingStep: Int
    let cleanup: Cleanup?
    /// The drafted "about you" step; see `EmailOnboardingContract.aboutItem`.
    var about: About? = nil

    struct About: Codable, Sendable {
        let items: [String]
        let spoken: [String]
        let help: [String]
    }

    struct Cleanup: Codable, Sendable {
        let senderInboxCount: Int
        let atLeast: Bool
        let senderDisplayName: String
        let query: String
        let account: String
        let messageId: String
        let note: String
        let dispatch: Dispatch
        struct Dispatch: Codable, Sendable {
            let task: String
            let account: String
            let expects: String
            let facts: [String]
        }
    }

    var queueItem: LocalTriageQueue.Item {
        .init(account: account, id: id, threadId: threadId, from: from, subject: subject,
              date: date, snippet: snippet, internalDate: internalDate)
    }

    static func beat(id: String, step: Int, account: String) -> Self {
        .init(account: account, id: EmailOnboardingContract.beatPrefix + id,
              threadId: EmailOnboardingContract.beatPrefix + id, from: "Jo", subject: "", date: "",
              snippet: "", internalDate: 0, onboardingStep: step, cleanup: nil)
    }

    /// A beat's placeholder id, so it is never marked read or shown as mail.
    static func about(id: String, step: Int, account: String, about: About) -> Self {
        var item = beat(id: id, step: step, account: account)
        item.about = about
        return item
    }

    /// v1 steps are fixed numbers; v2 looks the kind up in the run's config.
    func kind(in config: EmailOnboardingConfig?) -> String {
        if let config { return config.step(onboardingStep)?.kind ?? "" }
        return onboardingStep == 1 ? "welcome" : cleanup != nil ? "cleanup" : "important"
    }

    func note(config: EmailOnboardingConfig?) -> String {
        let step = config?.step(onboardingStep)
        switch kind(in: config) {
        case "welcome":
            return EmailOnboardingContract.welcomeInstruction(line: step?.line ?? EmailOnboardingContract.welcomeLine)
        case "about":
            return about.map { EmailOnboardingContract.aboutInstruction($0, question: nil) } ?? "This step is unavailable. Call triage_next."
        case "beat":
            let then = step?.then.map { "\($0) Call triage_next when that is done." } ?? "Then call triage_next in the same turn."
            return "Say exactly \"\(step?.say ?? "")\" \(then) This step has no email: do not present one or call a mail tool for it."
        default:
            if let cleanup { return cleanup.note }
            return (step?.note ?? EmailOnboardingContract.importantLead)
                + " Use the existing mail tools for their answer, or triage_next for an explicit skip. Reads and clarification do not advance onboarding."
        }
    }
}

struct EmailOnboardingSelection: Decodable, Sendable {
    let items: [EmailOnboardingItem]
    let failures: [String]
}

struct OnboardingMailPreference: Codable, Sendable {
    let account: String
    let draftsOnly: Bool?
}

struct OnboardingMailModeReceipt: Codable, Sendable {
    let note: String
    let mailPreference: OnboardingMailPreference
}

enum EmailOnboardingContract {
    /// Past the last step, as opposed to a `stop` — which leaves the arc to resume next call.
    static func finishesOnboarding(_ output: String) -> Bool {
        exitsOnboarding(output)
            && (try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])?["stopped"] as? Bool != true
    }

    static func exitsOnboarding(_ output: String) -> Bool {
        guard let payload = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              payload["onboarding"] == nil else { return false }
        return payload["stopped"] as? Bool == true || payload["done"] as? Bool == true || payload["item"] != nil
    }

    static let beatPrefix = "onboarding-beat:"
    static let importantLead = "Summarize this recent important email in one sentence and ask what they would like to do with it."
    static let mailModeQuestion = "Going forward, should I send your emails, or keep them in Drafts?"
    static let mailModeNote = mailModeInstruction(question: mailModeQuestion)
    static func mailModeInstruction(question: String) -> String {
        "Ask \"\(question)\" Wait for an explicit choice of send or drafts. A bare yes/no is ambiguous: clarify. Call triage_next with onboarding_mail_mode \"send\" or \"drafts\" only after that choice; use \"skip\" only if they explicitly skip this preference. Do not draft or send another Nate reply. Reads, questions, silence, and ordinary next calls do not save a preference or advance. Never claim it is saved before the tool succeeds."
    }

    /// Saved on the phone: `onboardingPreferenceSaved` applies it to the profile, and the run keeps it for a resume.
    static func saveMailMode(flow: EmailOnboardingFlow, mode: String) throws -> OnboardingMailModeReceipt {
        guard let account = flow.mailModeChoice?.account, ["send", "drafts", "skip"].contains(mode) else {
            throw URLError(.cannotParseResponse)
        }
        let draftsOnly = mode == "skip" ? nil : mode != "send"
        let note = draftsOnly.map {
            "Got it — I’ll \($0 ? "keep your emails in Drafts" : "send your emails") for this account. You can change that anytime in Settings."
        } ?? "Skipped — your setting is unchanged, and you can change it anytime in Settings."
        let receipt = OnboardingMailModeReceipt(note: note, mailPreference: .init(account: account, draftsOnly: draftsOnly))
        OnboardingResume.saved(receipt, mode: mode, runId: flow.runId)
        OnboardingMailModeReplay.complete()
        return receipt
    }

    static let mailModeAccountKey = "onboardingMailModeAccount"

    /// Observations, then what Jo can do about them. `question` is the finish step's, asked here
    /// when this is the last stage, so Live doesn't compress all three steps into one reply.
    static func aboutInstruction(_ about: EmailOnboardingItem.About, question: String?) -> String {
        let help = about.help.isEmpty ? "" : " Then say \"Here's how I can help with that.\" and give each of these in your own voice, "
            + "one sentence each, keeping the sender names and any quoted phrase: " + about.help.joined(separator: " | ") + "."
        let then = question.map { " Then ask exactly \"\($0)\" and wait. If they say yes, call triage_next once; if they say no, do not offer to wrap up or end the call." }
            ?? " Then call triage_next in the same turn."
        return "Say \"Here's what I picked up about you from your email.\" Then say these briefly, in your own voice: "
            + about.spoken.joined(separator: "; ") + "." + help + then
            + " This step has no email: do not present one or call a mail tool for it."
    }

    /// The same step as the Live speaker's own copy, so it needs no backend turn to word it.
    static func aboutScript(_ about: EmailOnboardingItem.About, question: String) -> String {
        (["Here's what I picked up about you from your email: " + about.spoken.joined(separator: "; ") + "."]
            + (about.help.isEmpty ? [] : ["Here's how I can help with that."] + about.help) + [question])
            .joined(separator: " ")
    }

    /// Summarises senders on the phone and drafts from that on the user's key. Nil drops the
    /// step: the walk goes on to the next one, as it does when onboarding mail cannot be found.
    static func aboutItem(flow: EmailOnboardingFlow, store: MailStore) async -> EmailOnboardingItem? {
        guard let steps = flow.config?.steps, let index = steps.firstIndex(where: { $0.kind == "about" }) else { return nil }
        let started = Date()
        let scope = ProfileRuntime.snapshot
        let senders = await LocalOnboardingMail.aboutSenders(store: store, scope: scope)
        guard senders.count >= 5 else {
            RealtimeLog.log("onboarding: about skipped — \(senders.count) senders")
            return nil
        }
        guard let prompt = try? aboutPrompt(senders),
              let text = try? await LiveOpenAI.read([["type": "input_text", "text": prompt]], json: true, timeout: 20),
              let about = parseAbout(text) else {
            RealtimeLog.log("onboarding: about draft unavailable")
            return nil
        }
        guard ProfileRuntime.snapshot?.profileId == scope?.profileId else {
            RealtimeLog.log("onboarding: about discarded — profile changed")
            return nil
        }
        RealtimeLog.log("onboarding: about drafted from \(senders.count) senders in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return .about(id: steps[index].id, step: index + 1, account: flow.welcome?.account ?? "", about: about)
    }

    /// What the about step may promise: its own list, not the tip rotation.
    static let aboutCapabilities: [(String, String)] = [
        ("unsubscribe", CoachingRotation.copy(for: "unsubscribe") ?? ""),
        ("bulk_sender_cleanup", CoachingRotation.copy(for: "bulk_sender_cleanup") ?? ""),
        ("filter", "I can keep a sender out of your inbox from now on with a Gmail filter. "
            + "While reviewing one of their emails, say 'Filter this sender out of my inbox.'"),
        ("calendar_actions", CoachingRotation.copy(for: "calendar_actions") ?? ""),
        ("dispatch", CoachingRotation.copy(for: "dispatch") ?? ""),
    ]

    static func aboutPrompt(_ senders: [LocalOnboardingMail.AboutSender],
                            text: LivePrompt.Text = .bundled) throws -> String {
        try text("onboarding/about", [
            "capabilities": aboutCapabilities.map { "- \($0.0): \($0.1)" }.joined(separator: "\n"),
            "senders": senders.prefix(80).map { "- \($0.from.prefix(120)) ×\($0.count)" }.joined(separator: "\n"),
        ])
    }

    /// Every bound the model's answer must meet; one it breaks is no draft.
    static func parseAbout(_ text: String) -> EmailOnboardingItem.About? {
        guard let raw = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        func lines(_ value: Any?, _ max: Int, chars: Int = 200) -> [String] {
            ((value as? [Any]) ?? []).compactMap { $0 as? String }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= chars }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.prefix(max).map { $0 }
        }
        let items = lines(raw["items"], 10), spoken = lines(raw["spoken"], 5)
        guard !items.isEmpty, !spoken.isEmpty else { return nil }
        let tips = Set(aboutCapabilities.map(\.0))
        var seen = Set<String>(), help: [String] = []
        for entry in (raw["help"] as? [[String: Any]]) ?? [] {
            guard let tip = entry["tip"] as? String, tips.contains(tip), !seen.contains(tip),
                  let line = lines([entry["line"] as Any], 1, chars: 300).first else { continue }
            seen.insert(tip)
            help.append(line)
            if help.count == 2 { break }
        }
        return .init(items: items, spoken: spoken, help: help)
    }

    /// Scripted, and says "an email" rather than pointing at "this": nothing is on a screen.
    /// Ported from the old server's `ONBOARDING_WELCOME_LINE` and `ONBOARDING_RESUME_OPENING`.
    static let resumeLine = "Welcome back! Let's pick up where we left off."
    static let welcomeLine = "Nate, the founder of Codename Jo, sent you an email asking where you found us. Say a friend told me about you, and I'll draft your reply."
    /// Drafts on the answer, and makes that the turn's only call.
    /// "to this exact thread" is what `isOnboardingWelcomeReply` matches on — don't reword it.
    static func welcomeInstruction(line: String) -> String {
        "Say exactly \"\(line)\" Say that line even though you would not normally invite them to speak: telling them the words is what teaches them how this works. Do not ask what they want to do with it, do not ask how they want to answer him, and do not end this turn on a question. An answer can pause mid-thought: while what they have said so far trails off, keep listening without prompting them. Once they have finished, turn everything they said into a short reply, save it with create_draft to this exact thread, and say where the draft was saved in one clause. The draft's result carries the next onboarding stage; if it does not, call triage_next in the same turn. Never send this reply. Do not read it back first and do not ask permission. You already have everything you need: the thread id is in this payload and the question is in the snippet. Do not read, search for or look up this email, and do not look for another one from Nate — reply on the thread id you were given. Archive or skip if requested. Reads and reply edits do not advance onboarding."
    }
    /// The Nate reply, steered onto his thread as a draft. The stage advances only when the draft
    /// lands on the welcome thread, and the reply must never be sent; both were left to the model,
    /// and a draft addressed to Nate as new mail left the stage standing. A write aimed at Nate's
    /// thread or address is that reply for as long as onboarding runs; one with no address and no
    /// thread is that reply while the welcome stage is up. Nil leaves any other write alone, so a
    /// side request to someone else stays a side request.
    static func welcomeReplyArguments(_ arguments: String, welcome: EmailOnboardingItem,
                                      onWelcomeStage: Bool) -> String? {
        guard let data = arguments.data(using: .utf8),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func field(_ key: String) -> String? {
            let value = (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        let thread = field("thread_id")
        let to = field("to")
        let founder = LocalCompose.bareAddress(welcome.from).lowercased()
        let onNatesThread = thread.map { $0 == welcome.threadId || $0 == welcome.id } ?? false
        let toNate = to.map { LocalCompose.looksLikeAddress(founder) && LocalCompose.bareAddress($0).lowercased() == founder } ?? false
        guard onNatesThread || toNate || (onWelcomeStage && thread == nil && to == nil) else { return nil }
        json["thread_id"] = welcome.threadId
        json["account"] = welcome.account
        json.removeValue(forKey: "to")
        json.removeValue(forKey: "subject")
        if let selected = field("reply_message_id"), selected != welcome.id {
            json.removeValue(forKey: "reply_message_id")
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: json),
              let result = String(data: encoded, encoding: .utf8) else { return nil }
        return result
    }

    /// The composer's instructions for the Nate reply: `prompts/onboarding/reply.md` with his question in it.
    static func replyPrompt(question: String, text: LivePrompt.Text = .bundled) throws -> String {
        try text("onboarding/reply", ["question": question])
    }

    /// The Nate reply, written on the phone from what they said. A one-shot call on a prompt a
    /// few hundred tokens long, where the brain turn it replaces read forty thousand and took ten
    /// seconds. Nil when the words are not an answer to Nate, when there is no key, or when the
    /// call fails: the brain keeps the turn, as before.
    static func composeWelcomeReply(words: String, question: String? = WelcomeEmail.copy?.question,
                                    text: LivePrompt.Text = .bundled) async -> String? {
        guard let question, let prompt = try? replyPrompt(question: question, text: text) else {
            RealtimeLog.log("onboarding: reply composer has no prompt or question")
            return nil
        }
        do {
            // One user message holding the prompt and their words, the shape the about step's
            // call already takes; the prompt carries the "JSON" that json_object mode requires.
            let answer = try await LiveOpenAI.read([["type": "input_text", "text": prompt + "\n\nTheir words:\n" + words]],
                                                   json: true, timeout: 8)
            guard let reply = parseReply(answer) else {
                RealtimeLog.log("onboarding: reply composer declined — \(answer.prefix(160))")
                return nil
            }
            return reply
        } catch {
            RealtimeLog.log("onboarding: reply composer failed — \(error)")
            return nil
        }
    }

    /// The reply out of the composer's JSON, only when it says the words were an answer.
    static func parseReply(_ text: String) -> String? {
        guard let raw = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              raw["answers"] as? Bool == true,
              let reply = (raw["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reply.isEmpty, reply.count <= 600 else { return nil }
        return reply
    }

    /// The mail-mode answer as the phone reads it: "send" or "drafts" when exactly one of them is
    /// named and nothing negates it, "skip" on its own, nil for anything else. Nil hands the
    /// turn to the brain, whose note already says a bare yes or no needs clarifying.
    static func mailModeAnswer(_ transcript: String) -> String? {
        let spoken = transcript.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let words = Set(spoken)
        // A question about the choice is not the choice.
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?"),
              !["what", "which", "how", "why", "does", "do", "is", "can", "could", "should", "would", "will", "are"]
                .contains(spoken.first ?? ""),
              words.isDisjoint(with: ["not", "don", "dont", "never", "no", "nope", "rather", "instead"]) else { return nil }
        let send = !words.isDisjoint(with: ["send", "sending", "sent"])
        let drafts = !words.isDisjoint(with: ["draft", "drafts", "drafting"])
        if send != drafts { return send ? "send" : "drafts" }
        if !send, words.contains("skip") { return "skip" }
        return nil
    }

    static let tip = "You're in your Feed. I bring forward emails that need your attention and help you handle them by voice. Whenever you need something, just ask."
    static let question = "Congrats on finishing onboarding! Want to keep going through your inbox?"
    static let finish = finishInstruction(tip: tip, question: question)
    static func finishInstruction(tip: String, question: String) -> String {
        "Say exactly \"\(tip)\" Then ask exactly \"\(question)\" and wait. Do not run calendar or coaching tools. If they say yes, call triage_next once; if they say no, do not offer to wrap up or end the call. Do not infer that their inbox is clear."
    }
}
