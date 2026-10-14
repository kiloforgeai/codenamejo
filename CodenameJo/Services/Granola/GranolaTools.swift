import FactoryKit
import Foundation

/// Granola's meeting notes as local function tools, called from the phone with the Keychain grant.
/// All reads. Schemas are ours (`LiveToolSchemas`); `mine_only` stands for Granola's `involvement`.
enum GranolaTools {
    static let names: [String] = ["granola_list_meetings", "granola_get_meeting", "granola_action_items"]

    /// The meeting ids `get_meetings` takes per call.
    static let fetchBatch = 10
    /// Meetings `granola_action_items` reads before it stops, so a busy quarter is not a minute of silence.
    static let maxMeetings = 30

    /// One Granola tool call on one grant. Tests swap it for canned answers.
    typealias Call = (_ grant: RemoteMCPGrant, _ tool: String, _ arguments: [String: Any]) async throws -> RemoteMCPToolResult

    static let liveCall: Call = { grant, tool, arguments in
        try await Container.shared.remoteMCPCredentials().callTool(.granola, grantId: grant.id, name: tool, arguments: arguments)
    }

    /// Run one tool for the active profile's working grants.
    static func run(name: String, argumentsJSON: String,
                    grants: [RemoteMCPGrant] = GranolaConnector.grants().filter { !$0.needsReauth },
                    call: Call = liveCall) async -> FullDuplexBroker.ToolResult {
        let input = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let result = await run(name: name, input: input, grants: grants, call: call)
        RealtimeLog.log("granola: \(name) — \(result.isError ? "failed" : "ok"), \(result.text.utf8.count) bytes")
        return FullDuplexBroker.ToolResult(text: result.text, ok: !result.isError)
    }

    static func run(name: String, input: [String: Any], grants: [RemoteMCPGrant],
                    call: Call) async -> (text: String, isError: Bool) {
        guard let first = grants.first else {
            return ("No Granola account is connected. Ask the user to connect Granola in Settings.", true)
        }
        do {
            switch name {
            case "granola_list_meetings":
                let args = listArguments(input)
                guard grants.count > 1 else { return try await relay(first, "list_meetings", args, call) }
                // Tagged by account: a flat merge is a list the model cannot attribute.
                var tagged: [[String: String]] = []
                for grant in grants {
                    do {
                        let result = try await relay(grant, "list_meetings", args, call)
                        tagged.append(["account": grant.label, result.isError ? "error" : "result": result.text])
                    } catch {
                        tagged.append(["account": grant.label, "error": explain(error)])
                    }
                }
                return (json(tagged), false)
            case "granola_get_meeting":
                guard let ids = input["meeting_ids"] as? [Any], (1...fetchBatch).contains(ids.count),
                      ids.allSatisfy({ ($0 as? String).map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } == true })
                else {
                    return ("Provide 1 to 10 non-empty meeting ids. Fetch additional candidates in separate batches of at most 10.", true)
                }
                // Ids are account-scoped and nothing says which account; every tool here is a read,
                // so try each and keep the first answer that is not an error.
                var last: (text: String, isError: Bool)?
                for grant in grants {
                    let result = try await relay(grant, "get_meetings", ["meeting_ids": ids], call)
                    if !result.isError { return result }
                    last = result
                }
                return last ?? ("Granola returned nothing for that.", true)
            case "granola_action_items":
                // One account: the list and the fetches have to agree on whose meetings they read.
                return try await actionItems(input, grant: first, call: call)
            default:
                return ("\(name) is not a Granola tool.", true)
            }
        } catch {
            return (explain(error), true)
        }
    }

    private static func relay(_ grant: RemoteMCPGrant, _ tool: String, _ args: [String: Any],
                              _ call: Call) async throws -> (text: String, isError: Bool) {
        let result = try await call(grant, tool, args)
        if result.text.isEmpty { return ("Granola returned nothing for that.", true) }
        return (result.text, result.isError)
    }

    /// Ours into Granola's: `mine_only` becomes the OR of both `involvement` conditions, which is
    /// what Granola's docs say to send for "my meetings".
    static func listArguments(_ input: [String: Any]) -> [String: Any] {
        var args = input
        let mine = args.removeValue(forKey: "mine_only") as? Bool == true
        if mine { args["involvement"] = ["captured_by_me": true, "listed_as_participant": true] }
        return args
    }

    /// Transport and auth failures in words the model can act on. A tool that failed inside
    /// Granola comes back as its own text instead, which is more specific than anything here.
    static func explain(_ error: Error) -> String {
        switch error as? RemoteMCPError {
        case .unauthorized?:
            return "Granola rejected the connection. Ask the user to reconnect Granola in Settings — it takes one tap."
        case .badResponse?:
            return "Granola returned something unreadable. Say so and try again in a moment."
        case .http(let status, _)? where status == 429:
            return "Granola is rate-limiting us. Say so and try again in a moment."
        case .http(let status, _)? where status >= 500:
            return "Granola is having trouble right now. Say so and try again in a moment."
        case .http(let status, _)?:
            return "Granola refused the request (HTTP \(status))."
        case .rpc(_, let message)?:
            return "Granola refused the request (\(message))."
        case .sessionExpired?, .transport?, nil:
            return "Couldn't reach Granola. Say so and try again in a moment."
        }
    }

    // MARK: - Action items

    /// One action item from a meeting's Next Steps, with its owner when the note names one.
    struct ActionItem: Equatable {
        let item: String
        var owner: String?
        let meeting: String
        let date: String
    }

    /// List the range, fetch in batches, and read each summary's Next Steps out. Granola has no
    /// action-items endpoint; this saves the model holding every full summary to answer one question.
    static func actionItems(_ input: [String: Any], grant: RemoteMCPGrant,
                            call: Call) async throws -> (text: String, isError: Bool) {
        let listed = try await relay(grant, "list_meetings", listArguments(input), call)
        if listed.isError { return listed }
        let meetings = matches(#"<meeting\s+id="([^"]+)"[^>]*>"#, in: listed.text).map { $0[0] }
        guard !meetings.isEmpty else {
            return (json(["count": 0, "items": [Any](), "note": "No meetings in that range."]), false)
        }
        let ids = Array(meetings.prefix(maxMeetings))
        var items: [ActionItem] = []
        var without: [String] = []
        for start in stride(from: 0, to: ids.count, by: fetchBatch) {
            let batch = try await relay(grant, "get_meetings",
                                        ["meeting_ids": Array(ids[start..<min(start + fetchBatch, ids.count)])], call)
            if batch.isError { return batch }
            for block in matches(#"<meeting\s+id="[^"]*"\s+title="([^"]*)"\s+date="([^"]*)"[^>]*>([\s\S]*?)</meeting>"#,
                                 in: batch.text) {
                let meeting = decode(block[0])
                let summary = matches(#"<summary>([\s\S]*?)</summary>"#, in: block[2]).first?[0] ?? ""
                let steps = nextSteps(summary)
                if steps.isEmpty { without.append(meeting); continue }
                for step in steps {
                    let split = splitOwner(step)
                    items.append(ActionItem(item: split.item, owner: split.owner, meeting: meeting, date: decode(block[1])))
                }
            }
        }
        var out: [String: Any] = ["count": items.count,
                                  "items": items.map { item -> [String: Any] in
                                      var row: [String: Any] = ["item": item.item, "meeting": item.meeting, "date": item.date]
                                      if let owner = item.owner { row["owner"] = owner }
                                      return row
                                  }]
        // Named rather than counted, so "the Cico sync listed none" is something Jo can say.
        if !without.isEmpty { out["meetingsWithNoActionItems"] = without }
        if meetings.count > ids.count { out["note"] = "Read the \(ids.count) most recent of \(meetings.count) meetings." }
        return (json(out), false)
    }

    /// Contains, not equals: the summariser often folds the actions into a compound heading such
    /// as `# Docs and Next Steps`.
    private static let heading = try! NSRegularExpression(
        pattern: #"^#{1,6}\s.*\b(next steps|action items|follow[\s-]?ups?|to-?dos?)\b\s*$"#, options: [.caseInsensitive])

    /// The bullets under the summary's Next Steps heading. Indented detail lines are skipped.
    static func nextSteps(_ summary: String) -> [String] {
        let lines = summary.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return heading.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
        }) else { return [] }
        var out: [String] = []
        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil { break }
            if let bullet = matches(#"^\s*[-*]\s+(.*\S)\s*$"#, in: line).first { out.append(bullet[0]) }
        }
        return out
    }

    /// `**item** (Owner)` and `**item (Owner)**` both occur in real notes.
    static func splitOwner(_ raw: String) -> (item: String, owner: String?) {
        let text = decode(raw).trimmingCharacters(in: .whitespaces)
        let bolded = matches(#"^\*\*(.+?)\*\*\s*(?:\((.+?)\))?\s*$"#, in: text).first
        let inner = (bolded?[0] ?? text.replacingOccurrences(of: "**", with: "")).trimmingCharacters(in: .whitespaces)
        if let owner = bolded?[1].trimmingCharacters(in: .whitespaces), !owner.isEmpty { return (inner, owner) }
        if let trailing = matches(#"^(.*\S)\s*\(([^()]+)\)\s*$"#, in: inner).first {
            return (trailing[0].trimmingCharacters(in: .whitespaces), trailing[1].trimmingCharacters(in: .whitespaces))
        }
        return (inner, nil)
    }

    static func decode(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Each match's capture groups, an unmatched optional group as "".
    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
