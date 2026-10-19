import Foundation

enum JoTips {
    static let storageKey = "joTipsEnabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: storageKey) as? Bool ?? true
    }
}

/// The quick-tip rotation and `coach_capability`, on the phone. Lessons ship in the bundled
/// `prompts/coaching.json`; which ones this phone has offered or had dismissed stays in `UserDefaults`.
enum CoachingRotation {
    static let toolName = "coach_capability"
    static let feedCapability = "feed"
    static let offeredKey = "coachingOffered"
    static let dismissedKey = "coachingDismissed"

    struct Lesson: Decodable, Equatable {
        let capability: String
        let copy: String
    }

    private struct Catalog: Decodable { let lessons: [Lesson] }

    static let catalog: [Lesson] = {
        let url = Bundle.main.bundleURL.appendingPathComponent("prompts/coaching.json")
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(Catalog.self, from: data) else { return [] }
        return file.lessons
    }()

    static func copy(for capability: String) -> String? {
        catalog.first { $0.capability == capability }?.copy
    }

    /// What this phone can tell about which lessons apply to the account.
    struct Eligibility: Equatable {
        /// This build has a Slack app and no workspace is connected yet.
        var slackConnectable = false
        var multipleInboxes = false
        var hasFeedItems = false
        var hasCommands = false
        /// This build can sign in to GitHub, and whether a login is connected.
        var githubAvailable = false
        var githubConnected = false
        var hasGranola = false
        var notionConnected = false
    }

    static func adopted(_ capability: String, _ eligibility: Eligibility) -> Bool {
        if let rule = StandingRule(rawValue: capability) { return rule.isOn }
        switch capability {
        case "feed_items": return eligibility.hasFeedItems
        case "commands": return eligibility.hasCommands
        default: return false
        }
    }

    static func available(_ capability: String, _ eligibility: Eligibility) -> Bool {
        switch capability {
        case "multi_account_routing": return eligibility.multipleInboxes
        case "github_connect": return eligibility.githubAvailable && !eligibility.githubConnected
        case "github_reviews": return eligibility.githubConnected
        case "granola_meetings", "granola_action_items": return eligibility.hasGranola
        case "slack_connect": return eligibility.slackConnectable
        case "notion_notes": return eligibility.notionConnected
        case "notion_connect": return !eligibility.notionConnected
        default: return true
        }
    }

    /// Every lesson not yet offered, dismissed or adopted, in catalog order. The Feed lesson rides
    /// apart so a fresh onboarding can teach it again unless it was dismissed.
    static func plan(_ eligibility: Eligibility, catalog: [Lesson] = catalog,
                     defaults: UserDefaults = .standard) -> FullDuplexBroker.CoachingPlan {
        guard JoTips.isEnabled(defaults: defaults) else { return .init(lessons: []) }
        let offered = Set((defaults.dictionary(forKey: offeredKey) ?? [:]).keys)
        let dismissed = Set(defaults.stringArray(forKey: dismissedKey) ?? [])
        let lessons = catalog.filter {
            !offered.contains($0.capability) && !dismissed.contains($0.capability)
                && !adopted($0.capability, eligibility) && available($0.capability, eligibility)
        }
        let feed = catalog.first { $0.capability == feedCapability && !dismissed.contains($0.capability) }
        return .init(lessons: lessons.map(lesson), onboardingFeed: feed.map(lesson))
    }

    static func recordOffer(_ capability: String, defaults: UserDefaults = .standard) {
        var offered = defaults.dictionary(forKey: offeredKey) ?? [:]
        offered[capability] = Date().timeIntervalSince1970
        defaults.set(offered, forKey: offeredKey)
    }

    /// The lesson a queue step offers for local playback, read so the offer can be retired.
    static func offer(inQueueOutput output: String) -> (id: String, capability: String)? {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
              let coaching = root["coaching"] as? [String: Any],
              coaching["delivery"] as? String == "local_playback",
              let id = coaching["id"] as? String,
              let capability = (coaching["lesson"] as? [String: Any])?["capability"] as? String
        else { return nil }
        return (id, capability)
    }

    // MARK: - What the model is handed

    static func lesson(_ lesson: Lesson) -> FullDuplexBroker.CoachingLesson {
        let rule = StandingRule(rawValue: lesson.capability)
        let speech = "Quick tip: \(lesson.copy) " + (rule == nil
            ? "Was that helpful?"
            : "It is switched off at the moment. Want me to turn that on?")
        let answer = answerInstruction(lesson.capability) + (rule.map {
            "Only a yes to this lesson's question means call set_rule with rule \"\($0.rawValue)\" and enabled true. "
                + "A no means call coach_capability with action dismiss and capability \"\($0.rawValue)\". "
                + "A skip, interruption or request to continue emails authorizes neither action."
        } ?? "Yes or no is feedback only. Do not dismiss the lesson unless explicitly asked to stop suggesting it.")
        return .init(capability: lesson.capability, copy: lesson.copy, speech: speech, answerInstruction: answer)
    }

    static func answerInstruction(_ capability: String) -> String {
        let rule = StandingRule(rawValue: capability) != nil
        let fields = "capability \"\(capability)\", answer yes/no/other and user_words quoting their actual reply, "
            + "without paraphrasing. Include checkpoint_id from the coaching object when available. Do not "
            + "invent words for silence or interruption. "
        return (rule
            ? "Record every spoken answer. For the yes that turns the rule on, call coach_capability with action "
                + "feedback in the same turn as set_rule, not instead of it. For a no, put the answer fields on "
                + "the dismiss call. For any other reply, use action feedback. Supply "
            : "After a spoken answer to the terminal question, call coach_capability with action feedback and ")
            + fields + "Feedback only records the reply; it does not enable a rule or dismiss a tip. "
            + "Record a later spoken reaction to the same tip as another feedback call. "
            + (rule ? "" : "If they explicitly ask to stop suggesting this tip, use action dismiss instead, with the same fields. ")
    }

    // MARK: - coach_capability

    static let maxUserWords = 4000

    /// `dismiss` retires a lesson for good; `feedback` only acknowledges the user's answer.
    static func run(argumentsJSON: String, defaults: UserDefaults = .standard) -> (output: String, failed: Bool) {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let action = args["action"] as? String
        let trimmed = (args["capability"] as? String)?.trimmingCharacters(in: .whitespaces)
        let named = trimmed.flatMap { $0.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) == nil ? nil : $0 }
        guard action == "dismiss" || action == "feedback", args["capability"] == nil || named != nil else {
            return ("Coaching was not changed because the action or capability was invalid.", true)
        }
        if let error = answerError(args) { return (error, true) }
        guard let named else {
            return (action == "feedback" ? "Name the capability the user answered about."
                : "Name the capability the user asked not to hear about again.", true)
        }
        guard copy(for: named) != nil else {
            return ("There is no lesson called \(named)." + (action == "dismiss" ? " Say nothing about tips." : ""), true)
        }
        if action == "feedback" {
            return ("Tip feedback recorded. Follow the lesson's answer instructions and pending continuation; "
                + "feedback does not change a rule or dismiss a tip.", false)
        }
        var dismissed = defaults.stringArray(forKey: dismissedKey) ?? []
        if !dismissed.contains(named) { dismissed.append(named) }
        defaults.set(dismissed, forKey: dismissedKey)
        RealtimeLog.log("coaching: dismissed \(named)")
        return ("Dismissed \(named) coaching permanently. Confirm that once. If a Feed stage is pending, this "
            + "receipt is never the end of the turn: resume it now using the pending checkpoint's instructions. "
            + "If no Feed stage is pending, say nothing else.", false)
    }

    static func answerError(_ args: [String: Any]) -> String? {
        if args["action"] as? String == "feedback" || args["answer"] != nil || args["user_words"] != nil {
            guard let answer = args["answer"] as? String, ["yes", "no", "other"].contains(answer) else {
                return "Supply answer yes, no or other."
            }
            guard let words = args["user_words"] as? String,
                  !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, words.count <= maxUserWords else {
                return "Supply the user's words, up to \(maxUserWords) characters, without paraphrasing."
            }
        }
        if let id = args["checkpoint_id"] {
            guard let id = id as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.count <= 300 else {
                return "Supply the exact checkpoint_id."
            }
        }
        return nil
    }
}
