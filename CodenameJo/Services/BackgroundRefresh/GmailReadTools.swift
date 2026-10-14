import Foundation

/// Gmail search and the three body reads, declared by the phone and run on its own Google grant.
/// Result shapes are load-bearing: prompts and caches read them unchanged.
enum GmailReadTools {
    static let search = "gmail_search_messages"
    static let getMessage = "gmail_get_message"
    static let getThread = "gmail_get_thread"
    static let readAttachment = "gmail_read_attachment"
    static let names: Set<String> = [search, getMessage, getThread, readAttachment]

    static let replyNote =
        "This message replies to earlier mail. Before summarizing it or reading it as the full email, "
        + "call get_thread with its threadId so what came before is understood; never present it as first contact. "
        + "When reading it aloud, first say in one sentence what the earlier message was about, then read this one. "
        + "Replying to it needs no get_thread."

    static let headersOnlyNote =
        " This account is set to headers only: hits carry the sender, subject and date but no "
        + "snippet or body, and there is no tool that can read one. Do not guess what a message "
        + "says from its subject — say you can only see the subject, and offer to open it in Gmail."

    // MARK: - Declarations

    /// The function tools for the session. Bodies off leaves search alone.
    static func definitions(accounts: [String], bodies: Bool) -> [[String: Any]] {
        guard !accounts.isEmpty else { return [] }
        let account: [String: Any] = ["type": "string", "description":
            "For any read or action on a search hit, copy its account. Otherwise omit unless the user named an account; "
            + "search spans the active profile, other tools follow the feed. Connected: \(accounts.joined(separator: ", "))."]
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "function", "name": name, "description": description, "strict": false,
             "parameters": ["type": "object", "properties": properties, "required": required]]
        }
        var tools = [tool(search,
            "Search all mail in the active profile, across its connected mailboxes unless account is named. "
            + "Other profiles require switching first with the user's agreement. "
            + "Do not restrict to inbox, unread or recent mail unless requested. "
            + "Return sender, subject, date, and snippet for each hit, "
            + "plus the `id` and `threadId` to pass to get_message, get_thread, "
            + "archive_message, trash_message, label_message, delete_draft (search in:drafts first), "
            + "or a reply. Enough to summarize or triage without opening anything. Note each hit is the newest message of "
            + "its thread — use get_thread when the history matters. "
            + "**A result is one page and never the whole match.** `more: true` means "
            + "there is older mail this did not return, and `before` is where the next "
            + "page starts. If you are acting on every match — clearing, archiving or "
            + "labelling everything from a sender — CALL THIS AGAIN with that `before` "
            + "and keep going until `more` is false. A job is not finished while `more` "
            + "is true. If `more` is true and no `before` came back, this cannot reach the rest — "
            + "deal with what you have and say plainly which part is not done. If you "
            + "are reading hits out to someone, one page is enough: say there are more "
            + "rather than fetching them. "
            + "\"Anything urgent?\" and \"what needs me?\" are not searches: call triage_next "
            + "with scope \"important\", even mid-queue — it ranks their week."
            + (bodies ? "" : headersOnlyNote),
            ["query": ["type": "string", "description": "Gmail search syntax."],
             "max_results": ["type": "integer", "description":
                "1 to 25, default 10. Keep it small when the hits are read aloud. `before` is how you get past the first page."],
             "before": ["type": "integer", "description":
                "Where the next page starts. Only ever the `before` a previous result handed you, copied exactly. "
                + "Not a date and not one from a different search. Leave it out for the first page."],
             "account": account], ["query"])]
        guard bodies else { return tools }
        tools.append(tool(getMessage,
            "Sender, subject, sent date and full body of one message. With full-body access, "
            + "use it for every ordinary email introduction unless that content is already supplied, "
            + "so the introduction includes when it was sent and a body summary automatically. "
            + "Also use for follow-up questions or an explicit word-for-word reading. "
            + "It returns one message; when it is marked isReply, follow its note.",
            ["message_id": ["type": "string"], "account": account], ["message_id"]))
        tools.append(tool(getThread,
            "Every message on one conversation, oldest first, each marked with "
            + "whether the user sent it (`fromMe`). Use this before summarizing "
            + "anything with history: search_messages and get_message only "
            + "ever show the newest message, so on their own they cannot tell that "
            + "someone has asked the same thing three times and had no answer. Pass "
            + "thread_id from a search hit. Not before a reply: send_email and "
            + "create_draft take thread_id and read the thread themselves.",
            ["thread_id": ["type": "string"],
             "max_messages": ["type": "integer", "description": "Newest N messages. Default 15, max 30."],
             "account": account], ["thread_id"]))
        tools.append(tool(readAttachment,
            "Read a file attached to a message — a PDF, an image, or plain text — and "
            + "get back what it actually says. Use it whenever the user asks what "
            + "someone sent, or what a document says, instead of inferring from the "
            + "subject line. Pass message_id from a search hit when you have one. When "
            + "you don't, or when it doesn't resolve, pass `search` and this finds the "
            + "message itself. If a message carries several files, name the one you "
            + "want with `filename`; otherwise you get the list back and can ask.",
            ["message_id": ["type": "string", "description": "From a search hit. Omit if you don't have one."],
             "search": ["type": "string", "description":
                "Gmail search that finds the message, for when message_id is unknown or doesn't resolve, "
                + "e.g. 'from:sarah has:attachment'. The newest match is used."],
             "filename": ["type": "string", "description":
                "Which attachment, when the message has more than one. Matched loosely, so \"the contract\" finds \"Contract-v3.pdf\"."],
             "account": account], []))
        return tools
    }

    // MARK: - Running

    struct Refusal: Error { let text: String }

    static func run(name: String, argumentsJSON: String) async -> (output: String, failed: Bool, effects: [GmailWriteEffect]?) {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let started = Date()
        do {
            let output: String
            switch name {
            case search: output = try await runSearch(args)
            case getMessage: output = try await runGetMessage(args)
            case getThread: output = try await runGetThread(args)
            default: output = try await runReadAttachment(args)
            }
            RealtimeLog.log("gmailRead: \(name) ok in \(Int(Date().timeIntervalSince(started) * 1000))ms")
            return (output, false, nil)
        } catch let refusal as Refusal {
            RealtimeLog.log("gmailRead: \(name) refused — \(refusal.text.prefix(120))")
            return (refusal.text, true, nil)
        } catch {
            return (describe(error), true, nil)
        }
    }

    static func string(_ args: [String: Any], _ key: String) -> String? {
        (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// The active profile's mailboxes, or just the one named.
    static func targets(_ args: [String: Any],
                        connected: [String] = ProfileRuntime.allowedMailAccounts(GoogleAccountStore.mailAccounts())) throws -> [String] {
        guard !connected.isEmpty else {
            throw Refusal(text: "No Gmail account is connected on this phone. Say so plainly.")
        }
        guard let named = string(args, "account") else { return connected }
        guard let match = connected.first(where: { $0.caseInsensitiveCompare(named) == .orderedSame }) else {
            throw Refusal(text: "No connected account matches \"\(named)\". Connected: \(connected.joined(separator: ", ")).")
        }
        return [match]
    }

    static func token(_ account: String) async throws -> String {
        switch await GoogleCredential.token(for: account) {
        case .success(let token): return token.accessToken
        case .failure(.noStoredGrant), .failure(.grantRevoked), .failure(.scopesMissing):
            throw Refusal(text: "Google access for \(account) needs reconnecting in Settings. Say so plainly.")
        case .failure:
            throw Refusal(text: "Couldn't reach Google for \(account) just now. Say so and offer to try again.")
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case is GmailAPI.HeadersOnly:
            return "This account is set to headers only, so message bodies and files can't be read. Say you can only see the subject."
        case GmailAPI.Failure.throttled:
            return "Gmail is rate-limiting this account right now. Say so and offer to try again in a moment."
        case GmailAPI.Failure.unauthorized:
            return "Google refused access to this mailbox; it needs reconnecting in Settings. Say so plainly."
        case GmailAPI.Failure.http(404):
            return "That message or thread isn't in this mailbox. Search for it first."
        default:
            return "Gmail couldn't be reached (\(String(describing: error).prefix(120))). Do not guess; say so plainly."
        }
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The first account that answers, in profile order. A miss elsewhere is a 404, so any other failure is the one reported.
    private static func firstAnswering<T>(_ accounts: [String],
                                          _ body: (String) async throws -> T) async throws -> (account: String, token: String, value: T) {
        var failures: [Error] = []
        for account in accounts {
            do {
                let token = try await token(account)
                return (account, token, try await body(token))
            } catch { failures.append(error) }
        }
        let notFound = { (error: Error) in if case GmailAPI.Failure.http(404) = error { return true } else { return false } }
        throw failures.first { !notFound($0) } ?? failures.first ?? Refusal(text: "Nothing found in any connected account.")
    }

    // MARK: - search_messages

    /// A `before` this search handed out, or the sentence that stops one being invented.
    static func cursor(_ raw: Any?, now: Date = Date()) throws -> Int? {
        guard let raw, !(raw is NSNull), !((raw as? String)?.isEmpty ?? false) else { return nil }
        let seconds = (raw as? NSNumber)?.doubleValue ?? Double(raw as? String ?? "") ?? .nan
        guard seconds.isFinite, seconds >= 946_684_800, seconds <= now.timeIntervalSince1970 + 86_400 else {
            throw Refusal(text: "That isn't a page marker from this search. Call search_messages again with "
                + "`before` left out to start from the newest, or with the exact number the last result gave you.")
        }
        return Int(seconds)
    }

    static func pageSize(_ raw: Any?) -> Int {
        guard let asked = (raw as? NSNumber)?.doubleValue ?? Double(raw as? String ?? ""), asked.isFinite, asked >= 1
        else { return 10 }
        return min(Int(asked), 25)
    }

    struct AccountPage { let hits: [[String: Any]]; let floor: Int64? }

    /// The next `before`, or nil with a stall note when the page could not move past its own second.
    static func nextCursor(floors: [Int64], before: Int?) -> (before: Int?, stalled: Bool) {
        guard let highest = floors.max() else { return (nil, false) }
        let next = Int((Double(highest) / 1000).rounded(.up)) + 1
        if let before, next >= before { return (nil, true) }
        return (next, false)
    }

    private static func runSearch(_ args: [String: Any]) async throws -> String {
        guard let query = string(args, "query") else {
            throw Refusal(text: "No query — pass a Gmail search.")
        }
        let accounts = try targets(args)
        let before = try cursor(args["before"])
        let size = pageSize(args["max_results"])
        let q = before.map { "\(query) before:\($0)" } ?? query
        let pages = await withTaskGroup(of: (Int, Result<AccountPage, Error>).self) { group in
            for (index, account) in accounts.enumerated() {
                group.addTask {
                    do { return (index, .success(try await searchPage(account: account, query: q, size: size))) }
                    catch { return (index, .failure(error)) }
                }
            }
            var out = [(Int, Result<AccountPage, Error>)]()
            for await item in group { out.append(item) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var entries: [[String: Any]] = []
        var floors: [Int64] = []
        var failed = 0
        for (account, page) in zip(accounts, pages) {
            switch page {
            case .success(let page):
                entries.append(["account": account, "result": page.hits])
                if let floor = page.floor { floors.append(floor) }
            case .failure(let error):
                failed += 1
                entries.append(["account": account, "error": (error as? Refusal)?.text ?? describe(error)])
            }
        }
        if failed == accounts.count, let error = entries.first?["error"] as? String { throw Refusal(text: error) }
        let next = nextCursor(floors: floors, before: before)
        var result: [String: Any] = ["accounts": entries, "more": !floors.isEmpty || failed > 0]
        if let value = next.before { result["before"] = value }
        if next.stalled {
            result["unreachable"] = "More than one page of these arrived within the same second, so there is no "
                + "way to page past them. Deal with the ones here; if the same ones come back, "
                + "the rest is mail this could not reach and the job is not finished."
        }
        return json(result)
    }

    private static func searchPage(account: String, query: String, size: Int) async throws -> AccountPage {
        let token = try await token(account)
        await GmailQuota.shared.spend(GmailQuota.Cost.list)
        let page = try await GmailAPI.messagePage(token: token, query: query, limit: size)
        let ids = (page.messages ?? []).map(\.id)
        let details = Dictionary(await GmailAPI.metadataBatch(token: token, ids: ids).map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
        let ordered = ids.compactMap { details[$0] }
        // The batch drops failed parts silently; a short page would read as "no more mail".
        guard ordered.count == ids.count else { throw GmailAPI.Failure.throttled }
        let hits: [[String: Any]] = ordered.map { message in
            ["account": account, "id": message.id, "threadId": message.threadId,
             "from": message.header("From") ?? "", "subject": message.header("Subject") ?? "",
             "date": message.header("Date") ?? "", "snippet": MailHeadersOnly.snippet(message.snippet),
             "unread": message.labelIds?.contains("UNREAD") == true]
        }
        let filled = page.nextPageToken != nil && !ordered.isEmpty
        let floor = filled ? ordered.compactMap { $0.internalDate.flatMap { Int64($0) } }.min() : nil
        return AccountPage(hits: hits, floor: floor)
    }

    // MARK: - get_message

    private static func runGetMessage(_ args: [String: Any]) async throws -> String {
        guard let id = string(args, "message_id") else {
            throw Refusal(text: "No message id — search first, then open a message from a result.")
        }
        let found = try await firstAnswering(try targets(args)) { token in
            try await GmailAPI.fullMessage(token: token, id: id)
        }
        return json([["account": found.account, "result": envelope(found.value)]])
    }

    static func envelope(_ message: GmailAPI.FullMessage) -> [String: Any] {
        var body = MailBodyText.plainText(message.payload).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty, let snippet = message.snippet?.trimmingCharacters(in: .whitespacesAndNewlines), !snippet.isEmpty {
            body = snippet + "\n\n[Message body had no readable text; Gmail's preview follows.]"
        }
        body = String(body.prefix(20_000))
        let files = attachments(in: message.payload)
        if !files.isEmpty {
            let listed = files.map { "\($0.filename) (\(AttachmentText.describeSize($0.size)))" }.joined(separator: ", ")
            body += "\n\n[Attachments: \(listed). Use read_attachment to read one.]"
        }
        var out: [String: Any] = ["id": message.id, "threadId": message.threadId,
            "from": message.header("From") ?? "", "to": message.header("To") ?? "",
            "subject": message.header("Subject") ?? "", "date": message.header("Date") ?? "", "body": body]
        if !(message.header("In-Reply-To") ?? "").isEmpty || !(message.header("References") ?? "").isEmpty {
            out["isReply"] = true
            out["note"] = replyNote
        }
        return out
    }

    // MARK: - get_thread

    private static func runGetThread(_ args: [String: Any]) async throws -> String {
        guard let id = string(args, "thread_id") else {
            throw Refusal(text: "No thread id — search first, then open a thread from a result.")
        }
        let requested = (args["max_messages"] as? NSNumber)?.intValue
        let max = requested.map { Swift.min(Swift.max(1, $0), 30) } ?? 15
        let found = try await firstAnswering(try targets(args)) { token in
            try await GmailAPI.fullThread(token: token, id: id)
        }
        return json(threadResult(found.value, account: found.account, threadId: id, max: max))
    }

    static func threadResult(_ thread: GmailAPI.FullThread, account: String, threadId: String, max: Int) -> [String: Any] {
        let delivered = (thread.messages ?? []).filter { !($0.labelIds ?? []).contains("DRAFT") }
        let all = delivered.isEmpty ? thread.messages ?? [] : delivered
        let kept = all.suffix(Swift.max(1, max))
        return [
            "account": account, "threadId": thread.id ?? threadId,
            "subject": all.last?.header("Subject") ?? "", "messageCount": all.count,
            "omittedOlder": all.count - kept.count,
            "messages": kept.map { message -> [String: Any] in
                let body = MailBodyText.plainText(message.payload)
                let own = QuotedHistory.strip(body)
                return ["id": message.id, "from": message.header("From") ?? "", "to": message.header("To") ?? "",
                        "date": message.header("Date") ?? "",
                        "body": String((own.isEmpty ? body.trimmingCharacters(in: .whitespacesAndNewlines) : own).prefix(4_000)),
                        "unread": (message.labelIds ?? []).contains("UNREAD"),
                        "fromMe": (message.labelIds ?? []).contains("SENT")]
            },
        ]
    }

    // MARK: - read_attachment

    struct Attachment: Equatable {
        let filename: String, mimeType: String, size: Int
        let attachmentId: String?, data: String?
    }

    /// File parts: a filename plus either an attachment id or inline bytes.
    static func attachments(in part: GmailAPI.FullPart?) -> [Attachment] {
        guard let part else { return [] }
        var out: [Attachment] = []
        if let name = part.filename, !name.isEmpty, part.body?.attachmentId != nil || part.body?.data != nil {
            out.append(Attachment(filename: name, mimeType: part.mimeType ?? "", size: part.body?.size ?? 0,
                                  attachmentId: part.body?.attachmentId, data: part.body?.data))
        }
        for child in part.parts ?? [] { out += attachments(in: child) }
        return out
    }

    /// One file is unambiguous; several without a name is a question back.
    static func pick(_ files: [Attachment], wanted: String?) -> Result<Attachment, Refusal> {
        guard !files.isEmpty else {
            return .failure(Refusal(text: "That message has no attachments. Say so — don't describe the body as though it were a file."))
        }
        if let wanted {
            let needle = wanted.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let words = needle.split(separator: " ").filter { $0.count > 2 }
            if let match = files.first(where: { $0.filename.lowercased() == needle })
                ?? files.first(where: { $0.filename.lowercased().contains(needle) })
                ?? files.first(where: { file in words.contains { file.filename.lowercased().contains($0) } }) {
                return .success(match)
            }
            let names = files.prefix(3).map(\.filename).joined(separator: ", ")
            return .failure(Refusal(text: "No attachment matching \"\(wanted)\". The message has: \(names). Ask which one."))
        }
        if files.count == 1 { return .success(files[0]) }
        let names = files.prefix(3).map { "\($0.filename) (\(AttachmentText.describeSize($0.size)))" }.joined(separator: ", ")
        let more = files.count > 3 ? " and \(files.count - 3) more" : ""
        return .failure(Refusal(text: "That message has \(files.count) attachments: \(names)\(more). Name the "
            + "three that matter, ask which one they want, then call this again with filename."))
    }

    private static func runReadAttachment(_ args: [String: Any]) async throws -> String {
        guard !MailHeadersOnly.withholdsBodies else { throw GmailAPI.HeadersOnly() }
        let accounts = try targets(args)
        let messageId = string(args, "message_id")
        let search = string(args, "search")
        var located: (account: String, token: String, value: GmailAPI.FullMessage)?
        if let messageId {
            located = try? await firstAnswering(accounts) { token in
                try await GmailAPI.fullMessage(token: token, id: messageId)
            }
        }
        if located == nil, let search {
            let query = search.range(of: "has:attachment|filename:", options: [.regularExpression, .caseInsensitive]) != nil
                ? search : "(\(search)) has:attachment"
            located = try? await firstAnswering(accounts) { token in
                await GmailQuota.shared.spend(GmailQuota.Cost.list)
                guard let id = try await GmailAPI.messagePage(token: token, query: query, limit: 1).messages?.first?.id
                else { throw GmailAPI.Failure.http(404) }
                return try await GmailAPI.fullMessage(token: token, id: id)
            }
            if located == nil { throw Refusal(text: "Nothing with an attachment matched \"\(search)\". Say what you searched.") }
        }
        guard let located else {
            throw Refusal(text: messageId == nil
                ? "No message id or search given — say which message, or pass a `search` like 'from:sarah has:attachment'."
                : "That message id isn't in any connected account. Search for the message first, then call this again with `search` set to a query that finds it.")
        }
        let file = try pick(attachments(in: located.value.payload), wanted: string(args, "filename")).get()
        let bytes: Data
        if let inline = file.data.flatMap(GmailAPI.decodeBase64URL) {
            bytes = inline
        } else if let attachmentId = file.attachmentId {
            bytes = try await GmailAPI.attachment(token: located.token, messageId: located.value.id, attachmentId: attachmentId)
        } else {
            throw Refusal(text: "\(file.filename) has no downloadable content. Say so plainly.")
        }
        return await AttachmentText.read(bytes, filename: file.filename, mimeType: file.mimeType)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
