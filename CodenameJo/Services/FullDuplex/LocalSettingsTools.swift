import Foundation

/// A JSON `true`/`false`, and nothing else: `JSONSerialization` hands `1` back as an `NSNumber`
/// that `as? Bool` would accept.
func strictJSONBool(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
}

/// `set_rule`: the three filing rules, switched by voice into the same defaults the Rules tab writes.
enum StandingRuleTool {
    static let name = "set_rule"

    static func run(argumentsJSON: String, defaults: UserDefaults = .standard) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let requested = (args["rule"] as? String).flatMap(StandingRule.init(rawValue:))
        if args["rule"] != nil, requested == nil {
            return "NOT CHANGED — there is no such rule. The three are "
                + StandingRule.allCases.map(\.rawValue).joined(separator: ", ")
                + ". If they asked for something about the mailbox itself, that is create_mailbox_filter."
        }
        let isOn = { (rule: StandingRule) in defaults.bool(forKey: rule.storageKey) }
        let copy = { (rule: StandingRule) in CoachingRotation.copy(for: rule.rawValue) ?? rule.detail }
        if let rule = requested, let enabled = strictJSONBool(args["enabled"]) {
            defaults.set(enabled, forKey: rule.storageKey)
            RealtimeLog.log("rules: \(rule.rawValue) \(enabled ? "on" : "off") by voice")
            return "Rule \"\(rule.title)\" is now \(enabled ? "on" : "off"). " + (enabled
                ? "From now on: \(copy(rule))"
                : "It stops applying from your next email; nothing already filed comes back.")
        }
        if let rule = requested {
            return "\"\(rule.title)\" is \(isOn(rule) ? "on" : "off"). \(copy(rule))"
        }
        return "Automatic filing rules (set_rule switches one):\n"
            + StandingRule.allCases.map { "- \($0.title): \(isOn($0) ? "on" : "off")" }.joined(separator: "\n")
    }
}
