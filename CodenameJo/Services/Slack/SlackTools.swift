import Foundation

/// The Slack tools, run on this phone with the user's token. Schemas are in `LiveToolSchemas`.
enum SlackTools {
    static let queueName = "slack_triage_next"
    static let readNames: Set<String> = [
        "slack_read_channel", "slack_read_thread", "slack_search_public_and_private",
        "slack_search_channels", "slack_search_users", "slack_read_user_profile",
        "slack_list_channel_members",
    ]
    static let writeNames: Set<String> = [
        "slack_send_message", "slack_add_reaction", "slack_schedule_message",
        "slack_mark_read", "slack_mark_unread",
    ]
    /// Declared on the session, in this order, when a workspace is connected.
    static let catalogOrder = [queueName] + [
        "slack_read_channel", "slack_read_thread", "slack_search_public_and_private",
        "slack_search_channels", "slack_search_users", "slack_read_user_profile",
        "slack_list_channel_members", "slack_send_message", "slack_add_reaction",
        "slack_schedule_message", "slack_mark_read", "slack_mark_unread",
    ]

    struct Result: Sendable {
        let text: String
        /// The write landed in Slack. False for every refusal and every read.
        var written = false
        /// The conversation the write resolved to, for matching it to the queue.
        var channel: String? = nil
        /// Whether the conversation's badge is now actually clear; nil when nothing marked.
        var markedRead: Bool? = nil
        var ok = false
    }

    /// The queued conversation a reply, reaction or schedule should also mark read.
    struct MarkTarget: Sendable {
        let teamId: String
        let channelId: String
        let ts: String
        /// The queue already knows what to call it, so a receipt costs no lookup.
        let label: String
    }

    static func run(name: String, argumentsJSON: String, markTarget: MarkTarget? = nil,
                    workspaces: [SlackWorkspace] = SlackWorkspace.served()) async -> Result {
        let input = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        return await run(name: name, input: input, markTarget: markTarget, workspaces: workspaces)
    }

    static func run(name: String, input: [String: Any], markTarget: MarkTarget? = nil,
                    workspaces: [SlackWorkspace]) async -> Result {
        if let refusal = refusal(name, input, workspaces) { return Result(text: refusal) }
        // On the queued conversation the resolved id and newest ts are already in hand, which
        // saves the DM lookup and the history read a person id or a bare mark would cost.
        var input = input
        if let target = markTarget {
            input["channel_id"] = target.channelId
            if name == "slack_mark_read", string(input, "message_ts").isEmpty { input["message_ts"] = target.ts }
        }
        let label = markTarget?.label
        do {
            switch name {
            case "slack_read_channel":
                return read(try await whichever(workspaces) { try await readChannel($0, input) })
            case "slack_read_thread":
                return read(try await whichever(workspaces) { try await readThread($0, input) })
            case "slack_read_user_profile":
                return read(try await whichever(workspaces) { try await readUserProfile($0, input) })
            case "slack_list_channel_members":
                return read(try await whichever(workspaces) { try await listChannelMembers($0, input) })
            case "slack_search_public_and_private":
                return read(await fanOut(workspaces) { try await searchMessages($0, input) })
            case "slack_search_channels":
                return read(await fanOut(workspaces) { try await searchChannels($0, input) })
            case "slack_search_users":
                return read(await fanOut(workspaces) { try await searchUsers($0, input) })
            case "slack_send_message", "slack_add_reaction", "slack_schedule_message":
                let write = try await whichever(workspaces) { ws -> Write in
                    switch name {
                    case "slack_send_message": return try await sendMessage(ws, input, label: label)
                    case "slack_add_reaction": return try await addReaction(ws, input, label: label)
                    default: return try await scheduleMessage(ws, input, label: label)
                    }
                }
                return await finish(write, markTarget: markTarget, workspaces: workspaces)
            case "slack_mark_read":
                let write = try await whichever(workspaces) { try await markRead($0, input, label: label) }
                return Result(text: write.text, written: write.ts != nil, channel: write.channel,
                              markedRead: write.ts != nil ? true : nil, ok: write.ts != nil)
            case "slack_mark_unread":
                let write = try await whichever(workspaces) { try await markUnread($0, input, label: label) }
                return Result(text: write.text, written: write.ts != nil, channel: write.channel,
                              markedRead: write.ts != nil ? false : nil, ok: write.ts != nil)
            default:
                return Result(text: "\(name) is not a Slack tool.")
            }
        } catch {
            RealtimeLog.log("slack tool \(name): \(error)")
            return Result(text: explain(error))
        }
    }

    /// A reply, reaction or schedule on the queued conversation also clears its badge; a
    /// failed mark is reported separately, never folded into the write.
    private static func finish(_ write: Write, markTarget: MarkTarget?, workspaces: [SlackWorkspace]) async -> Result {
        guard write.ts != nil else { return Result(text: write.text) }
        var result = Result(text: write.text, written: true, channel: write.channel, ok: true)
        if let target = markTarget, let ws = workspaces.first(where: { $0.teamId == target.teamId }),
           target.channelId == write.channel {
            if ws.canMark {
                do {
                    _ = try await SlackWebAPI.post(ws, "conversations.mark", ["channel": target.channelId, "ts": target.ts])
                    result.markedRead = true
                } catch {
                    RealtimeLog.log("slack: mark after write failed — \(error)")
                    result.markedRead = false
                }
            } else {
                result.markedRead = false
            }
        }
        return result
    }

    private static func read(_ object: Any) -> Result {
        Result(text: json(object), ok: true)
    }

    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    // MARK: - Guards

    static func looksLikeSlackId(_ value: Any?) -> Bool {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces) else { return false }
        return SlackSweep.matches(#"^[CGDUW][A-Z0-9]{5,}$"#, text)
    }

    static func refusal(_ name: String, _ input: [String: Any], _ workspaces: [SlackWorkspace]) -> String? {
        if workspaces.isEmpty {
            return "No Slack workspace is connected. Ask the user to connect Slack in Settings."
        }
        if writeNames.contains(name), !looksLikeSlackId(input["channel_id"]) {
            let verb = name == "slack_add_reaction" ? "NOT REACTED"
                : name == "slack_schedule_message" ? "NOT SCHEDULED"
                : name == "slack_mark_read" || name == "slack_mark_unread" ? "NOT MARKED" : "NOT SENT"
            return "\(verb) — \"\(input["channel_id"] as? String ?? "")\" is not a Slack conversation id. "
                + "Find the channel with slack_search_channels, or the person with slack_search_users, "
                + "and pass the id from those results."
        }
        if name == "slack_send_message" || name == "slack_schedule_message", string(input, "message").isEmpty {
            return name == "slack_send_message" ? "NOT SENT — there was no message text."
                : "NOT SCHEDULED — there was no message text."
        }
        if name == "slack_mark_read" || name == "slack_mark_unread", !workspaces.contains(where: \.canMark) {
            return "NOT MARKED — this Slack connection does not have permission to change what is read. "
                + "Ask the user to reconnect Slack in Settings, which grants it. Everything else about Slack still works."
        }
        return nil
    }

    static func explain(_ error: Error) -> String {
        let code: String
        if let call = error as? SlackWebAPI.CallError { code = call.code }
        else if let local = error as? LocalRefusal { return local.message }
        else { return "Slack could not be reached (\(error.localizedDescription))." }
        switch code {
        case "channel_not_found":
            return "No conversation with that id. Find it with slack_search_channels, or slack_search_users "
                + "for a person, and use the id from those results."
        case "not_in_channel": return "The user is not in that channel, so it cannot be read or posted to."
        case "is_archived": return "That channel is archived — it can be read but not posted to."
        case "thread_not_found", "message_not_found":
            return "No message with that ts in that conversation. Read the channel again for a current one."
        case "invalid_timestamp":
            return "Slack would not accept that timestamp. Use a message's ts exactly as a read or a queue "
                + "step gave it, or leave it out to mark the whole conversation."
        case "access_denied": return "Slack refused this connection access to that conversation."
        case "invalid_auth", "token_revoked", "account_inactive", "token_expired", "not_connected":
            return "Slack needs reconnecting: ask the user to reconnect Slack in Settings."
        case "missing_scope":
            return "This Slack connection is missing a permission for that. Ask the user to reconnect Slack in "
                + "Settings, which re-grants them."
        case "ratelimited": return "Slack is rate-limiting us. Say so and try again in a moment."
        case "msg_too_long": return "That message is too long for Slack. Shorten it and send again."
        case "time_in_past": return "That time has already passed — Slack needs at least two minutes' notice."
        case "time_too_far": return "Slack will not schedule more than 120 days ahead."
        case "restricted_action", "no_permission":
            return "Slack does not permit that in this channel — it may be externally shared."
        default: return "Slack refused the request (\(code))."
        }
    }

    /// A refusal decided here rather than by Slack, already in words.
    struct LocalRefusal: Error {
        let code: String
        let message: String
    }

    /// Ids are workspace-scoped and nothing in a call says which: try each, and move on only
    /// when Slack says the id is not in that workspace.
    private static let notHere: Set<String> = ["channel_not_found", "users_not_found", "no_dm_open", "not_in_channel"]

    static func whichever<T>(_ workspaces: [SlackWorkspace], _ body: (SlackWorkspace) async throws -> T) async throws -> T {
        var last: Error = SlackWebAPI.CallError(method: "lookup", code: "channel_not_found", status: 200, retryAfterSeconds: 0)
        for ws in workspaces {
            do {
                return try await body(ws)
            } catch let error as SlackWebAPI.CallError where notHere.contains(error.code) {
                last = error
            } catch let error as LocalRefusal where notHere.contains(error.code) {
                last = error
            }
        }
        throw last
    }

    private static func fanOut(_ workspaces: [SlackWorkspace], _ body: (SlackWorkspace) async throws -> [String: Any]) async -> [[String: Any]] {
        var out: [[String: Any]] = []
        for ws in workspaces {
            do { out.append(try await body(ws)) }
            catch { out.append(["workspace": ws.teamName, "error": explain(error)]) }
        }
        return out
    }

    // MARK: - Reads

    private static func string(_ input: [String: Any], _ key: String) -> String {
        (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func clamp(_ value: Any?, _ low: Int, _ high: Int, _ fallback: Int) -> Int {
        let number = (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init)
        return number.map { min(high, max(low, $0)) } ?? fallback
    }

    /// The DM already open with a person; never opens one just to read it.
    private static func channelFor(_ ws: SlackWorkspace, _ given: String) async throws -> String {
        guard given.hasPrefix("U") || given.hasPrefix("W") else { return given }
        let json = try await SlackWebAPI.call(ws, "users.conversations", ["types": "im", "exclude_archived": "true", "limit": "200"])
        if let dm = (json["channels"] as? [[String: Any]] ?? []).first(where: { $0["user"] as? String == given })?["id"] as? String {
            return dm
        }
        throw LocalRefusal(code: "no_dm_open", message: "There is no direct message conversation open with that person yet, "
            + "so there is nothing to read. Sending them a message will start one.")
    }

    private static func with(_ facts: SlackNameBook.Facts) -> [String: Any]? {
        guard let userId = facts.userId else { return nil }
        var out: [String: Any] = ["user_id": userId, "name": facts.label]
        if let handle = facts.person?.handle { out["handle"] = handle }
        if let email = facts.person?.email { out["email"] = email }
        return out
    }

    static func readChannel(_ ws: SlackWorkspace, _ input: [String: Any]) async throws -> [String: Any] {
        let channel = try await channelFor(ws, string(input, "channel_id"))
        var params = ["channel": channel, "limit": String(clamp(input["limit"], 1, 100, 30))]
        for key in ["oldest", "latest", "cursor"] where !string(input, key).isEmpty { params[key] = string(input, key) }
        let json = try await SlackWebAPI.call(ws, "conversations.history", params)
        let book = SlackNameBook()
        let messages = await SlackSweep.render(ws, (json["messages"] as? [[String: Any]] ?? []).map(SlackSweep.RawMessage.init),
                                               book: book, concise: string(input, "response_format") == "concise")
        let facts = await SlackSweep.channelFacts(ws, channel, book: book)
        var out: [String: Any] = ["workspace": ws.teamName, "channel": facts.label, "channel_id": channel,
                                  "kind": facts.kind, "order": "newest first", "messages": messages.map(\.json)]
        if let with = with(facts) { out["with"] = with }
        if json["has_more"] as? Bool == true { out["more"] = true }
        let cursor = SlackWebAPI.nextCursor(json)
        if !cursor.isEmpty { out["cursor"] = cursor }
        return out
    }

    static func readThread(_ ws: SlackWorkspace, _ input: [String: Any]) async throws -> [String: Any] {
        let channel = try await channelFor(ws, string(input, "channel_id"))
        let json = try await SlackWebAPI.call(ws, "conversations.replies", [
            "channel": channel, "ts": string(input, "message_ts"), "limit": String(clamp(input["limit"], 1, 200, 60)),
        ])
        let book = SlackNameBook()
        let messages = await SlackSweep.render(ws, (json["messages"] as? [[String: Any]] ?? []).map(SlackSweep.RawMessage.init),
                                               book: book, concise: string(input, "response_format") == "concise")
        let facts = await SlackSweep.channelFacts(ws, channel, book: book)
        var out: [String: Any] = ["workspace": ws.teamName, "channel": facts.label, "channel_id": channel,
                                  "kind": facts.kind, "order": "oldest first", "messages": messages.map(\.json)]
        if let with = with(facts) { out["with"] = with }
        if json["has_more"] as? Bool == true { out["more"] = true }
        return out
    }

    static func searchMessages(_ ws: SlackWorkspace, _ input: [String: Any]) async throws -> [String: Any] {
        let query = string(input, "query")
        guard !query.isEmpty else { throw LocalRefusal(code: "bad_request", message: "A search needs a query.") }
        let json = try await SlackWebAPI.call(ws, "search.messages", [
            "query": query, "count": String(clamp(input["limit"], 1, 20, 12)),
            "sort": string(input, "sort") == "timestamp" ? "timestamp" : "score",
            "sort_dir": string(input, "sort_dir") == "asc" ? "asc" : "desc",
        ])
        let block = json["messages"] as? [String: Any] ?? [:]
        let matches = block["matches"] as? [[String: Any]] ?? []
        let book = SlackNameBook()
        await SlackSweep.resolveMentions(ws, matches.compactMap { $0["text"] as? String }, book: book)
        var rendered: [[String: Any]] = []
        for match in matches {
            let channel = match["channel"] as? [String: Any] ?? [:]
            let name = channel["name"] as? String
            var row: [String: Any] = [
                "channel": channel["is_mpim"] as? Bool == true ? "a group DM"
                    : (name != nil && channel["is_im"] as? Bool != true) ? SlackSweep.spokenChannel(name!) : (channel["id"] as? String ?? ""),
                "channel_id": channel["id"] as? String ?? "",
                "from": SlackSweep.nonEmpty(match["username"]) ?? SlackSweep.nonEmpty(match["user"]) ?? "unknown",
                "ts": match["ts"] as? String ?? "",
                "text": await SlackSweep.speakable(match["text"] as? String ?? "", book: book),
            ]
            if let user = match["user"] as? String { row["from_id"] = user }
            rendered.append(row)
        }
        return ["workspace": ws.teamName, "total": (block["total"] as? NSNumber)?.intValue ?? matches.count, "matches": rendered]
    }

    static func searchChannels(_ ws: SlackWorkspace, _ input: [String: Any]) async throws -> [String: Any] {
        let terms = string(input, "query").lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        var all: [[String: Any]] = []
        var cursor = ""
        for _ in 0..<2 {
            var params = ["types": "public_channel,private_channel",
                          "exclude_archived": input["include_archived"] as? Bool == true ? "false" : "true", "limit": "200"]
            if !cursor.isEmpty { params["cursor"] = cursor }
            let json = try await SlackWebAPI.call(ws, "conversations.list", params)
            all += json["channels"] as? [[String: Any]] ?? []
            cursor = SlackWebAPI.nextCursor(json)
            if cursor.isEmpty { break }
        }
        func value(_ c: [String: Any], _ key: String) -> String? { (c[key] as? [String: Any])?["value"] as? String }
        let scored = all.map { c -> (c: [String: Any], score: Int) in
            let name = (c["name"] as? String ?? "").lowercased()
            let hay = [c["name"] as? String, value(c, "topic"), value(c, "purpose")].compactMap { $0 }.joined(separator: " ").lowercased()
            let score = terms.reduce(0) { total, term in
                total + (name == term ? 100 : name.contains(term) ? 10 : hay.contains(term) ? 1 : 0)
            }
            return (c, score)
        }.filter { $0.score > 0 }.sorted { $0.score > $1.score }.prefix(clamp(input["limit"], 1, 20, 10))
        return ["workspace": ws.teamName, "searched": all.count, "channels": scored.map { entry -> [String: Any] in
            var row: [String: Any] = [
                "channel_id": entry.c["id"] as? String ?? "",
                "name": SlackSweep.spokenChannel(entry.c["name"] as? String ?? ""),
                "private": entry.c["is_private"] as? Bool == true, "member": entry.c["is_member"] as? Bool == true,
            ]
            if let members = entry.c["num_members"] as? NSNumber { row["members"] = members.intValue }
            if let purpose = value(entry.c, "purpose"), !purpose.isEmpty { row["purpose"] = purpose }
            return row
        }]
    }

    static func searchUsers(_ ws: SlackWorkspace, _ input: [String: Any]) async throws -> [String: Any] {
        let query = string(input, "query")
        guard !query.isEmpty else { throw LocalRefusal(code: "bad_request", message: "A user search needs a query.") }
        if SlackSweep.matches(#"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, query) {
            do {
                let user = try await SlackWebAPI.call(ws, "users.lookupByEmail", ["email": query])["user"] as? [String: Any]
                return ["workspace": ws.teamName, "users": user.map { [profile($0)] } ?? []]
            } catch let error as SlackWebAPI.CallError where error.code == "users_not_found" {
                return ["workspace": ws.teamName, "users": [[String: Any]]()]
            }
        }
        let terms = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        let wanted = terms.filter { !$0.hasPrefix("-") }
        let unwanted = terms.filter { $0.hasPrefix("-") }.map { String($0.dropFirst()) }
        var all: [[String: Any]] = []
        var cursor = ""
        for _ in 0..<3 {
            var params = ["limit": "200"]
            if !cursor.isEmpty { params["cursor"] = cursor }
            let json = try await SlackWebAPI.call(ws, "users.list", params)
            all += json["members"] as? [[String: Any]] ?? []
            cursor = SlackWebAPI.nextCursor(json)
            if cursor.isEmpty { break }
        }
        let users = all.filter { u in
            guard u["deleted"] as? Bool != true, u["is_bot"] as? Bool != true, u["id"] as? String != "USLACKBOT" else { return false }
            let p = u["profile"] as? [String: Any] ?? [:]
            let hay = [u["name"], u["real_name"], p["display_name"], p["real_name"], p["title"], p["email"]]
                .compactMap { $0 as? String }.joined(separator: " ").lowercased()
            return wanted.allSatisfy(hay.contains) && !unwanted.contains(where: hay.contains)
        }.prefix(clamp(input["limit"], 1, 20, 10)).map(profile)
        return ["workspace": ws.teamName, "searched": all.count, "users": Array(users)]
    }

    static func profile(_ u: [String: Any]) -> [String: Any] {
        let p = u["profile"] as? [String: Any] ?? [:]
        var out: [String: Any] = [
            "user_id": u["id"] as? String ?? "",
            "name": SlackSweep.nonEmpty(p["display_name"]) ?? SlackSweep.nonEmpty(p["real_name"])
                ?? SlackSweep.nonEmpty(u["name"]) ?? (u["id"] as? String ?? ""),
        ]
        if let handle = SlackSweep.nonEmpty(u["name"]) { out["handle"] = "@" + handle }
        if let title = SlackSweep.nonEmpty(p["title"]) { out["title"] = title }
        if let email = SlackSweep.nonEmpty(p["email"]) { out["email"] = email }
        if let tz = SlackSweep.nonEmpty(u["tz_label"]) { out["timezone"] = tz }
        let status = [p["status_emoji"], p["status_text"]].compactMap { SlackSweep.nonEmpty($0) }.joined(separator: " ")
        if !status.isEmpty { out["status"] = status }
        if u["is_admin"] as? Bool == true { out["admin"] = true }
        return out
    }

    static func readUserProfile(_ ws: SlackWorkspace, _ input: [String: Any]) async throws -> [String: Any] {
        let id = string(input, "user_id").isEmpty ? ws.userId : string(input, "user_id")
        guard let user = try await SlackWebAPI.call(ws, "users.info", ["user": id])["user"] as? [String: Any] else {
            throw SlackWebAPI.CallError(method: "users.info", code: "users_not_found", status: 200, retryAfterSeconds: 0)
        }
        return ["workspace": ws.teamName, "user": profile(user)]
    }

    static func listChannelMembers(_ ws: SlackWorkspace, _ input: [String: Any]) async throws -> [String: Any] {
        let channel = string(input, "channel_id")
        if channel.hasPrefix("U") || channel.hasPrefix("W") || channel.hasPrefix("D") {
            throw LocalRefusal(code: "not_a_channel", message: "A direct message has no member list — the members are the two people in it.")
        }
        var params = ["channel": channel, "limit": String(clamp(input["limit"], 1, 30, 30))]
        if !string(input, "cursor").isEmpty { params["cursor"] = string(input, "cursor") }
        let json = try await SlackWebAPI.call(ws, "conversations.members", params)
        let ids = json["members"] as? [String] ?? []
        if string(input, "response_format") == "ids_only" {
            return ["workspace": ws.teamName, "member_ids": ids, "count": ids.count]
        }
        let book = SlackNameBook()
        _ = await SlackSweep.eachWithConcurrency(ids) { _ = await SlackSweep.userFacts(ws, $0, book: book) }
        var members: [[String: Any]] = []
        for id in ids { members.append(["user_id": id, "name": await book.userName(id) ?? id]) }
        var out: [String: Any] = ["workspace": ws.teamName, "members": members, "count": ids.count,
                                  "channel": await SlackSweep.channelFacts(ws, channel, book: book).label]
        let cursor = SlackWebAPI.nextCursor(json)
        if !cursor.isEmpty { out["cursor"] = cursor }
        return out
    }

    // MARK: - Writes

    struct Write: Sendable {
        let text: String
        var ts: String? = nil
        var channel: String? = nil
    }

    static func sendMessage(_ ws: SlackWorkspace, _ input: [String: Any], label known: String? = nil) async throws -> Write {
        let channel = string(input, "channel_id")
        let message = string(input, "message")
        guard !message.isEmpty else { return Write(text: "NOT SENT — there was no message text.") }
        let thread = string(input, "thread_ts")
        let broadcast = input["reply_broadcast"] as? Bool == true
        var body: [String: Any] = ["channel": channel, "text": message]
        if !thread.isEmpty { body["thread_ts"] = thread }
        if !thread.isEmpty && broadcast { body["reply_broadcast"] = true }
        let json = try await SlackWebAPI.post(ws, "chat.postMessage", body)
        let posted = json["channel"] as? String ?? channel
        let label = await knownOrLooked(known, ws, posted)
        let where_ = thread.isEmpty ? "to \(label)"
            : broadcast ? "in the thread in \(label), and also to the whole channel" : "in the thread in \(label)"
        return Write(text: "Sent \(where_) on \(ws.teamName).", ts: json["ts"] as? String ?? "", channel: posted)
    }

    static func addReaction(_ ws: SlackWorkspace, _ input: [String: Any], label known: String? = nil) async throws -> Write {
        let channel = string(input, "channel_id")
        let ts = string(input, "message_ts")
        let emoji = string(input, "emoji").replacingOccurrences(of: ":", with: "")
        let name = emoji.isEmpty ? "thumbsup" : emoji
        do {
            _ = try await SlackWebAPI.post(ws, "reactions.add", ["channel": channel, "timestamp": ts, "name": name])
        } catch let error as SlackWebAPI.CallError where error.code == "already_reacted" {
            RealtimeLog.log("slack: reaction already present — treated as done")
        }
        let label = await knownOrLooked(known, ws, channel)
        return Write(text: "Reacted :\(name): on the message in \(label).", ts: ts, channel: channel)
    }

    static func scheduleMessage(_ ws: SlackWorkspace, _ input: [String: Any], label known: String? = nil) async throws -> Write {
        let channel = string(input, "channel_id")
        let message = string(input, "message")
        guard !message.isEmpty else { return Write(text: "NOT SCHEDULED — there was no message text.") }
        let at = clamp(input["post_at"], 0, Int.max, 0)
        guard at > 0 else { return Write(text: "NOT SCHEDULED — post_at must be a Unix timestamp in seconds.") }
        let thread = string(input, "thread_ts")
        var body: [String: Any] = ["channel": channel, "text": message, "post_at": at]
        if !thread.isEmpty { body["thread_ts"] = thread }
        if !thread.isEmpty && input["reply_broadcast"] as? Bool == true { body["reply_broadcast"] = true }
        let json = try await SlackWebAPI.post(ws, "chat.scheduleMessage", body)
        let posted = json["channel"] as? String ?? channel
        let label = await knownOrLooked(known, ws, posted)
        let when = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(at)))
        return Write(text: "Scheduled for \(label) on \(ws.teamName) at \(when) (epoch \(at)). It sits in Drafts and sent "
                        + "in Slack until it goes.",
                     ts: json["scheduled_message_id"] as? String ?? "", channel: posted)
    }

    private static func knownOrLooked(_ known: String?, _ ws: SlackWorkspace, _ channel: String) async -> String {
        if let known { return known }
        return await SlackSweep.channelFacts(ws, channel, book: SlackNameBook()).label
    }

    private static func newestTs(_ ws: SlackWorkspace, _ channel: String) async throws -> String {
        let json = try await SlackWebAPI.call(ws, "conversations.history", ["channel": channel, "limit": "1"])
        return (json["messages"] as? [[String: Any]])?.first?["ts"] as? String ?? ""
    }

    static func markRead(_ ws: SlackWorkspace, _ input: [String: Any], label known: String? = nil) async throws -> Write {
        let channel = try await channelFor(ws, string(input, "channel_id"))
        let given = string(input, "message_ts")
        let ts = given.isEmpty ? try await newestTs(ws, channel) : given
        guard !ts.isEmpty else { return Write(text: "NOT MARKED — there is nothing in that conversation to mark.") }
        _ = try await SlackWebAPI.post(ws, "conversations.mark", ["channel": channel, "ts": ts])
        let label = await knownOrLooked(known, ws, channel)
        return Write(text: given.isEmpty ? "Marked \(label) read on \(ws.teamName)."
                        : "Marked \(label) read up to that message on \(ws.teamName). Anything after it is still unread.",
                     ts: ts, channel: channel)
    }

    /// Sets the cursor on the message before the one that should show unread; Slack names it.
    static func markUnread(_ ws: SlackWorkspace, _ input: [String: Any], label known: String? = nil) async throws -> Write {
        let channel = try await channelFor(ws, string(input, "channel_id"))
        let given = string(input, "message_ts")
        let from = given.isEmpty ? try await newestTs(ws, channel) : given
        guard !from.isEmpty else { return Write(text: "NOT MARKED — there is nothing in that conversation to mark.") }
        let before = try await SlackWebAPI.call(ws, "conversations.history", [
            "channel": channel, "latest": from, "inclusive": "false", "limit": "1",
        ])
        guard let ts = (before["messages"] as? [[String: Any]])?.first?["ts"] as? String, !ts.isEmpty else {
            return Write(text: "NOT MARKED — that is the first message in the conversation, so there is no earlier point "
                            + "for Slack to put the marker. It is already as unread as it can be.")
        }
        _ = try await SlackWebAPI.post(ws, "conversations.mark", ["channel": channel, "ts": ts])
        let label = await knownOrLooked(known, ws, channel)
        return Write(text: "\(label) is showing unread again on \(ws.teamName), from that message on.", ts: from, channel: channel)
    }
}
