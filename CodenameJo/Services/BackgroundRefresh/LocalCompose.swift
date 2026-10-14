import Foundation
import FactoryKit

/// `create_draft` and `send_email`, run on the phone's own Google grant. Receipt wording is
/// load-bearing: the queue handlers read their opening words.
enum LocalCompose {
    static let names: Set<String> = ["create_draft", "send_email"]

    typealias Refusal = GmailReadTools.Refusal
    private typealias Manage = GmailManageTools

    /// How many people one spoken instruction can honestly copy.
    static let copyMax = 10
    static let archivedByRule = " Archived."
    static let archiveUnconfirmed = " The automatic archive was not confirmed; the mail may still be in the inbox."

    /// - Parameter defer: the caller advances on the receipt, so the Gmail call may land after it.
    static func run(name: String, argumentsJSON: String, defer deferred: Bool,
                    conversationId: String? = nil) async -> FullDuplexBroker.ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let started = Date()
        do {
            let result = try await compose(name, args, deferred: deferred, conversationId: conversationId)
            RealtimeLog.log("localCompose: \(name)\(GmailReadTools.string(args, "thread_id") == nil ? "" : " on a thread") "
                + "\(result.ok == true ? "ok" : "not ok") in \(Int(Date().timeIntervalSince(started) * 1000))ms — "
                + "\(result.text.prefix(80))")
            return result
        } catch let refusal as Refusal {
            RealtimeLog.log("localCompose: \(name) refused — \(refusal.text.prefix(120))")
            return .init(text: refusal.text, ok: false)
        } catch {
            RealtimeLog.log("localCompose: \(name) failed — \(error)")
            return .init(text: "The \(name) call failed: \(Manage.detail(error))", ok: false)
        }
    }

    // MARK: - The write

    private static func compose(_ name: String, _ given: [String: Any], deferred: Bool,
                                conversationId: String?) async throws -> FullDuplexBroker.ToolResult {
        let threadId = GmailReadTools.string(given, "thread_id")
        // The route's guard: a fresh message's `to` must at least parse. A reply's comes off the thread.
        if threadId == nil, !looksLikeAddress(given["to"]) {
            throw Refusal(text: "NOT \(name == "send_email" ? "SENT" : "SAVED") — \"\(text(given["to"]))\" is not an email "
                + "address. These tools only write outgoing mail and can never read or check anything. If you meant to "
                + "reply to a message, pass its thread_id and leave the address out. If you were answering a question "
                + "about the mailbox, use the Gmail read tools — or tell the user plainly that you could not.")
        }
        if name == "create_draft", let refusal = calendarRefusal(given["user_request"]) { throw Refusal(text: refusal) }
        let (args, accounts) = try await Manage.bind(name: name, given)
        let selectedId = GmailReadTools.string(args, "reply_message_id")
        if selectedId != nil, threadId == nil {
            throw Refusal(text: "NOT SENT — reply_message_id requires its thread_id. Nothing has gone yet.")
        }
        let (account, token, fetched) = try await target(args, accounts, threadId: threadId)
        let own = Set((GoogleAccountStore.emails() + accounts).map { $0.lowercased() })
        let selfAddressed = { (address: String) in own.contains(bareAddress(address).lowercased()) }

        var subject = (args["subject"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let asked = (args["to"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var to = asked
        var inReplyTo: String?
        // Whether `to` came off the thread rather than out of the model: the first-time block reads it.
        var derivedTo = false
        var replyingTo: Participant?

        if let threadId {
            var context: ThreadContext
            if let fetched { context = fetched } else { context = try await threadContext(token, account: account, threadId: threadId) }
            var selected = selectedId.flatMap { id in context.participants.first { $0.id == id } }
            if selectedId != nil, selected == nil {
                throw Refusal(text: "NOT SENT — that selected message is not available in this thread and mailbox. "
                    + "Nothing has gone yet.")
            }
            if let picked = selected, picked.fromMe,
               let recipient = ([picked.address] + picked.to + picked.cc).first(where: { !selfAddressed($0) }) {
                selected?.address = recipient
            }
            if let selected {
                context.replyTo = selected.address
                context.lastMessageId = selected.messageId
            }
            subject = context.subject.replacingOccurrences(of: #"^(re:\s*)+"#, with: "",
                                                           options: [.regularExpression, .caseInsensitive])
            subject = subject.isEmpty ? subject : "Re: \(subject)"
            inReplyTo = context.lastMessageId.isEmpty ? nil : context.lastMessageId
            // A person the user named beats the thread's own answer, when they are on the thread.
            let named = selected ?? (asked.isEmpty ? nil : context.participants.last {
                !$0.fromMe && (sameAddress($0.from, asked) || sameAddress($0.address, asked))
            })
            if let named, !selfAddressed(named.address) {
                to = named.address
                derivedTo = true
                inReplyTo = named.messageId.isEmpty ? inReplyTo : named.messageId
                replyingTo = named
            } else if !selfAddressed(context.replyTo) {
                to = context.replyTo
                derivedTo = true
                let last = context.lastMessageId
                replyingTo = context.participants.first {
                    !$0.fromMe && !last.isEmpty && $0.messageId == last && sameAddress($0.address, context.replyTo)
                } ?? context.participants.last { !$0.fromMe && sameAddress($0.address, context.replyTo) } ?? replyingTo
            } else if to.isEmpty {
                throw Refusal(text: "NOT SENT — that thread's only reply address is your own "
                    + "(\(bareAddress(context.replyTo))), which is almost never who a reply is for. "
                    + "Ask the user who it should go to, or call find_person, and call this again "
                    + "with an explicit to. Nothing has gone yet.")
            }
        }
        guard !subject.isEmpty else {
            throw Refusal(text: "No subject — write a short one from the body and call this again.")
        }
        guard looksLikeAddress(to) else {
            throw Refusal(text: threadId != nil
                ? "No recipient — that thread has no address to reply to\(to.isEmpty ? "" : " (\(to))"). "
                    + "Ask the user who it should go to."
                : "No recipient — call find_person for the address, or ask the user.")
        }

        var seen: Set<String> = [bareAddress(to).lowercased()]
        var cc = try copyAddresses(args["cc"], field: "cc", seen: &seen)
        // Reply-all copies the message being answered, as written, less the user and anyone already on it.
        if strictJSONBool(args["reply_all"]) != false, let replyingTo {
            let copied = replyingTo.to + replyingTo.cc
            let unresolved = copied.contains {
                let bare = bareAddress($0).lowercased()
                return !bare.isEmpty && !seen.contains(bare) && !selfAddressed($0)
            }
            let aliases = unresolved ? try await sendAsAddresses(token) : []
            for address in copied {
                let bare = bareAddress(address).lowercased()
                guard !bare.isEmpty, !seen.contains(bare), !selfAddressed(address), !aliases.contains(bare) else { continue }
                seen.insert(bare)
                cc.append(address)
            }
        }
        let bcc = try copyAddresses(args["bcc"], field: "bcc", seen: &seen)
        if cc.count + bcc.count > copyMax {
            throw Refusal(text: "That is \(cc.count + bcc.count) people to copy, which is more than this should do in one "
                + "go. Read the list back to the user and let them cut it.")
        }

        let message = MailMIME.Outgoing(to: to, cc: cc, bcc: bcc, subject: subject, body: text(args["body"]),
                                        threadId: threadId, inReplyTo: inReplyTo, footer: MailFooter.isOn)
        // A rule about replying has nothing to file when this is a fresh message to somebody.
        let files = threadId != nil && StandingRule.archiveAfterReply.isOn
        let copies = copiesFor(message)

        if name == "create_draft" || DraftsOnly.isOn(for: account) {
            var receipt = "Draft to \(to) saved in \(account)\(copies)." + (files ? archivedByRule : "")
            if name == "send_email" { receipt += " Nothing was sent because this inbox is set to drafts only." }
            return try await finishDraft(name, message, receipt: receipt, account: account, token: token, files: files,
                                         deferred: deferred, conversationId: conversationId)
        }
        if !derivedTo, strictJSONBool(args["recipient_confirmed"]) != true,
           !(try await hasCorresponded(to, account: account, token: token)) {
            throw Refusal(text: "NOT SENT — first time you've mailed \(to). Ask the user \"is that the right person?\" "
                + "and if they say yes, call this again with recipient_confirmed: true. Nothing has gone yet.")
        }
        let receipt = "Sent to \(to) from \(account)\(copies)." + (files ? archivedByRule : "")
        return await finishSend(message, receipt: receipt, account: account, token: token, files: files,
                                deferred: deferred, conversationId: conversationId)
    }

    // MARK: - After the receipt

    private static func finishDraft(_ name: String, _ message: MailMIME.Outgoing, receipt: String, account: String,
                                    token: String, files: Bool, deferred: Bool,
                                    conversationId: String?) async throws -> FullDuplexBroker.ToolResult {
        let raw = MailMIME.plain(message)
        let save = { (effects: Manage.Effects) async throws in
            try await saveDraft(token, raw: raw, threadId: message.threadId)
            // After the draft, never before: a rule files the original once the reply it is filing behind exists.
            if files { await fileByRule(token, account: account, threadId: message.threadId, effects) }
        }
        let queued = PendingMailWrite.QueuedDraft(raw: raw, to: message.to, threadId: message.threadId)
        guard !deferred else {
            Task.detached {
                let effects = Manage.Effects()
                do {
                    try await save(effects)
                    await applyEffects(effects.list)
                } catch {
                    // A throttled draft becomes a queued one, silently: the receipt already said it was saved, and it will be.
                    if Manage.isThrottle(error),
                       (try? await enqueue(queued, account: account, conversationId: conversationId)) != nil { return }
                    Container.shared.localWriteNotices().push(draftFailure(error, account: account),
                                                              conversation: conversationId)
                }
            }
            return .init(text: receipt, ok: true, deferred: true, performedTool: "create_draft")
        }
        let effects = Manage.Effects()
        do {
            try await save(effects)
        } catch {
            if Manage.isThrottle(error),
               let pending = try? await enqueue(queued, account: account, conversationId: conversationId) {
                // A queued draft does not file the message it answers. Said, not swallowed.
                let filed = files ? " The message it answers was not filed." : ""
                return .init(text: "Drafting. The draft is queued for background retry.\(filed)"
                    + " Say that it is drafting, and say the filing clause above if there is one;"
                    + " then continue. Do not wait or claim it has been saved.",
                    ok: false, pendingDraft: pending, performedTool: "create_draft")
            }
            return .init(text: draftFailure(error, account: account), ok: false, performedTool: "create_draft")
        }
        return .init(text: confirmed(receipt, effects.list), ok: true, effects: effects.list, performedTool: "create_draft")
    }

    /// A send is never retried: `messages/send` has no idempotency key, so a retry could send it twice.
    private static func finishSend(_ message: MailMIME.Outgoing, receipt: String, account: String, token: String,
                                   files: Bool, deferred: Bool, conversationId: String?) async -> FullDuplexBroker.ToolResult {
        let send = { (effects: Manage.Effects) async throws in
            await GmailQuota.shared.spend(100)
            var body: [String: Any] = ["raw": MailMIME.plain(message)]
            if let threadId = message.threadId { body["threadId"] = threadId }
            _ = try await GmailAPI.call("POST", path: "messages/send", body: body, token: token)
            await Container.shared.contactStore().recordSent(account: account, email: bareAddress(message.to))
            if files { await fileByRule(token, account: account, threadId: message.threadId, effects) }
        }
        guard !deferred else {
            Task.detached {
                let effects = Manage.Effects()
                do {
                    try await send(effects)
                    await applyEffects(effects.list)
                } catch {
                    Container.shared.localWriteNotices().push(sendFailure(error), conversation: conversationId)
                }
            }
            return .init(text: receipt, ok: true, deferred: true)
        }
        let effects = Manage.Effects()
        do {
            try await send(effects)
        } catch {
            return .init(text: sendFailure(error), ok: false)
        }
        return .init(text: confirmed(receipt, effects.list), ok: true, effects: effects.list)
    }

    /// A receipt that claims a rule filed the mail says so only when Gmail confirmed it.
    static func confirmed(_ receipt: String, _ effects: [GmailWriteEffect]) -> String {
        guard receipt.contains(archivedByRule),
              !effects.contains(where: { $0.removeLabelIds?.contains("INBOX") == true }) else { return receipt }
        return receipt.replacingOccurrences(of: archivedByRule, with: archiveUnconfirmed)
    }

    static func saveDraft(_ token: String, raw: String, threadId: String?) async throws {
        await GmailQuota.shared.spend(10)
        var message: [String: Any] = ["raw": raw]
        if let threadId { message["threadId"] = threadId }
        _ = try await GmailAPI.call("POST", path: "drafts", body: ["message": message], token: token)
    }

    /// A failure is logged and swallowed; the receipt's clause is corrected by `confirmed`.
    static func fileByRule(_ token: String, account: String, threadId: String?, _ effects: GmailManageTools.Effects) async {
        guard let threadId else { return }
        do {
            try await Manage.modifyThread(token, account: account, threadId: threadId, add: [], remove: ["INBOX", "UNREAD"], effects)
        } catch {
            RealtimeLog.log("localCompose: archive after write failed — \(Manage.detail(error))")
        }
    }

    static func applyEffects(_ effects: [GmailWriteEffect]) async {
        guard !effects.isEmpty else { return }
        let store = await MainActor.run { Container.shared.mailStore() }
        _ = await Container.shared.localTriage().applyConfirmedEffects(effects, store: store)
    }

    private static func enqueue(_ draft: PendingMailWrite.QueuedDraft, account: String,
                                conversationId: String?) async throws -> PendingDraft {
        let userId = await MainActor.run { Container.shared.backend().userId ?? "" }
        let queue = Container.shared.pendingMailWrites()
        let pending = try await queue.enqueueDraft(userId: userId, account: account, draft: draft,
                                                   conversationId: conversationId,
                                                   delay: PendingMailWritePolicy.delay(attempt: 1))
        queue.drainSoon(userId: userId)
        return pending
    }

    // MARK: - Failure sentences

    static func draftFailure(_ error: Error, account: String) -> String {
        if Manage.isThrottle(error) { return "\(Manage.throttled) No draft was saved." }
        let detail = (error as? PendingMailWrites.Unrecoverable)?.text ?? Manage.detail(error)
        return "that draft didn't save (\(detail)) — there is nothing in \(account)'s drafts, so it needs asking for again."
    }

    static func sendFailure(_ error: Error) -> String {
        if Manage.isThrottle(error) { return "\(Manage.throttled) Nothing went out." }
        return "that didn't send (\(Manage.detail(error))) — nothing went out, so it needs asking for again."
    }

    // MARK: - Which mailbox

    /// A thread's owner is probed in profile order, and its context kept for the reply.
    private static func target(_ args: [String: Any], _ accounts: [String],
                               threadId: String?) async throws -> (String, String, ThreadContext?) {
        if GmailReadTools.string(args, "account") != nil || accounts.count == 1 {
            let account = try Manage.single(accounts)
            return (account, try await GmailReadTools.token(account), nil)
        }
        guard let threadId else {
            guard let lead = accounts.first else { throw Refusal(text: "Multiple accounts connected — ask the user which one, then pass `account`.") }
            return (lead, try await GmailReadTools.token(lead), nil)
        }
        let probes = await withTaskGroup(of: (Int, String, String, ThreadContext)?.self) { group in
            for (index, account) in accounts.enumerated() {
                group.addTask {
                    guard let token = try? await GmailReadTools.token(account),
                          let context = try? await threadContext(token, account: account, threadId: threadId) else { return nil }
                    return (index, account, token, context)
                }
            }
            var found: [(Int, String, String, ThreadContext)] = []
            for await probe in group { if let probe { found.append(probe) } }
            return found
        }
        guard let owner = probes.min(by: { $0.0 < $1.0 }) else {
            throw Refusal(text: "Couldn't find thread \(threadId) in any connected account. "
                + "Ask the user which account to use and pass `account`.")
        }
        return (owner.1, owner.2, owner.3)
    }

    // MARK: - Reply context

    struct Participant: Equatable {
        var id: String?
        var fromMe: Bool
        var from: String
        /// Where a reply to this message goes, as written: `Name <addr>` is kept.
        var address: String
        var messageId: String
        var subject: String
        var to: [String]
        var cc: [String]
    }

    struct ThreadContext: Equatable {
        var subject: String
        var lastMessageId: String
        var replyTo: String
        /// Every delivered message, newest last.
        var participants: [Participant]
    }

    /// One metadata fetch, the user's unsent drafts left out unless the thread is nothing else.
    static func threadContext(_ token: String, account: String, threadId: String) async throws -> ThreadContext {
        await GmailQuota.shared.spend(10)
        let wanted = ["Subject", "Message-ID", "From", "Reply-To", "To", "Cc"]
        let thread = try await GmailAPI.call("GET", path: "threads/\(threadId)", query: ["format": "metadata"],
                                             repeated: wanted.map { ("metadataHeaders", $0) }, token: token)
        return try context(thread, account: account, threadId: threadId)
    }

    static func context(_ thread: [String: Any], account: String, threadId: String) throws -> ThreadContext {
        let all = thread["messages"] as? [[String: Any]] ?? []
        let delivered = all.filter { !labels($0).contains("DRAFT") }
        let messages = delivered.isEmpty ? all : delivered
        guard let last = messages.last else { throw Refusal(text: "thread \(threadId) has no messages") }
        let participants = messages.compactMap { message -> Participant? in
            let fromMe = labels(message).contains("SENT")
            let from = header(message, "From")
            let to = splitAddressList(header(message, "To"))
            let cc = splitAddressList(header(message, "Cc"))
            let mine = Set([account, from].map { bareAddress($0).lowercased() })
            let sentRecipient = (to + cc).first { !mine.contains(bareAddress($0).lowercased()) }
            let address = fromMe ? sentRecipient ?? to.first ?? cc.first ?? "" : replyAddress(message)
            guard !address.isEmpty else { return nil }
            return Participant(id: message["id"] as? String, fromMe: fromMe, from: from, address: address,
                               messageId: header(message, "Message-ID"), subject: header(message, "Subject"), to: to, cc: cc)
        }
        return ThreadContext(subject: header(last, "Subject"), lastMessageId: header(last, "Message-ID"),
                             replyTo: replyRecipient(messages), participants: participants)
    }

    /// The newest message the user did not send, `Reply-To` before `From`; else the last one's `To`.
    private static func replyRecipient(_ messages: [[String: Any]]) -> String {
        for message in messages.reversed() where !labels(message).contains("SENT") {
            let answer = replyAddress(message)
            if !answer.isEmpty { return answer }
        }
        return messages.last.map { header($0, "To") } ?? ""
    }

    private static func replyAddress(_ message: [String: Any]) -> String {
        let replyTo = header(message, "Reply-To")
        return replyTo.isEmpty ? header(message, "From") : replyTo
    }

    private static func labels(_ message: [String: Any]) -> [String] { message["labelIds"] as? [String] ?? [] }

    private static func header(_ message: [String: Any], _ name: String) -> String {
        let headers = (message["payload"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []
        return headers.first { ($0["name"] as? String)?.lowercased() == name.lowercased() }?["value"] as? String ?? ""
    }

    /// The mailbox's verified send-as addresses, bare and lowercased. `gmail.modify` is enough to list them.
    private static func sendAsAddresses(_ token: String) async throws -> Set<String> {
        await GmailQuota.shared.spend(1)
        let result = try await GmailAPI.call("GET", path: "settings/sendAs",
            query: ["fields": "sendAs(sendAsEmail,isPrimary,verificationStatus)"], token: token)
        let entries = result["sendAs"] as? [[String: Any]] ?? []
        return Set(entries.filter { $0["isPrimary"] as? Bool == true || $0["verificationStatus"] as? String == "accepted" }
            .compactMap { ($0["sendAsEmail"] as? String).map { bareAddress($0).lowercased() } })
    }

    // MARK: - Who has been mailed before

    /// The phone's directory for the connected mailboxes, then Gmail, on an exact address match.
    static func hasCorresponded(_ address: String, account: String, token: String) async throws -> Bool {
        let wanted = bareAddress(address).lowercased()
        if await Container.shared.contactStore().hasCorresponded(email: wanted, accounts: GoogleAccountStore.emails()) {
            return true
        }
        let quoted = "\"\(wanted.replacingOccurrences(of: "\"", with: ""))\""
        await GmailQuota.shared.spend(GmailQuota.Cost.list)
        let list = try await GmailAPI.call("GET", path: "messages",
            query: ["q": "from:\(quoted) OR to:\(quoted)", "maxResults": "12"], token: token)
        let ids = (list["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            for id in ids {
                group.addTask {
                    await GmailQuota.shared.spend(GmailQuota.Cost.get)
                    let message = try await GmailAPI.call("GET", path: "messages/\(id)", query: ["format": "metadata"],
                        repeated: [("metadataHeaders", "From"), ("metadataHeaders", "To")], token: token)
                    return (splitAddressList(header(message, "From")) + splitAddressList(header(message, "To")))
                        .contains { bareAddress($0).lowercased() == wanted }
                }
            }
            for try await hit in group where hit {
                group.cancelAll()
                return true
            }
            return false
        }
    }

    // MARK: - Addresses

    /// The address out of `Name <addr>`, case kept, or the entry itself.
    static func bareAddress(_ raw: String) -> String {
        if let open = raw.firstIndex(of: "<"), let close = raw[open...].firstIndex(of: ">"),
           raw.index(after: open) < close {
            return String(raw[raw.index(after: open)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func looksLikeAddress(_ raw: Any?) -> Bool {
        guard let raw = raw as? String else { return false }
        return bareAddress(raw).range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    private static func sameAddress(_ a: String, _ b: String) -> Bool {
        let left = bareAddress(a).lowercased()
        return !left.isEmpty && left == bareAddress(b).lowercased()
    }

    /// Commas inside a quoted display name do not split.
    static func splitAddressList(_ raw: String) -> [String] {
        var out: [String] = []
        var buffer = ""
        var quoted = false
        for character in raw {
            if character == "\"" { quoted.toggle() }
            if character == ",", !quoted {
                out.append(buffer)
                buffer = ""
                continue
            }
            buffer.append(character)
        }
        out.append(buffer)
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// One copy list as bare addresses, deduplicated against everyone already on the message.
    static func copyAddresses(_ value: Any?, field: String, seen: inout Set<String>) throws -> [String] {
        guard let value, !(value is NSNull) else { return [] }
        let entries: [Any]
        if let single = value as? String { entries = [single] } else if let list = value as? [Any] { entries = list } else {
            throw Refusal(text: "Couldn't read \(field) — pass the addresses as a list of text, or leave it out.")
        }
        if let notText = entries.first(where: { !($0 is String) }) {
            throw Refusal(text: "Couldn't read a \(field) entry (\(json(notText))) — pass every address as text.")
        }
        var out: [String] = []
        for entry in entries.compactMap({ $0 as? String }).flatMap(splitAddressList) {
            guard looksLikeAddress(entry) else {
                throw Refusal(text: "Can't copy \"\(entry)\" — that isn't an email address. Call find_person for it, or ask, "
                    + "then try again with every \(field) address spelled out. Nothing has gone yet.")
            }
            let bare = bareAddress(entry)
            guard seen.insert(bare.lowercased()).inserted else { continue }
            out.append(bare)
        }
        return out
    }

    /// Appended, never prepended: the queue reads the receipt's opening words.
    static func copiesFor(_ message: MailMIME.Outgoing) -> String {
        var clauses: [String] = []
        if !message.cc.isEmpty { clauses.append("copying \(speakList(message.cc))") }
        if !message.bcc.isEmpty { clauses.append("blind copying \(speakList(message.bcc))") }
        return clauses.isEmpty ? "" : ", " + clauses.joined(separator: ", ")
    }

    /// `a`, `a and b`, `a, b and c`.
    static func speakList(_ addresses: [String]) -> String {
        guard addresses.count > 1 else { return addresses.first ?? "" }
        return addresses.dropLast().joined(separator: ", ") + " and " + addresses[addresses.count - 1]
    }

    /// JavaScript's `String(value)` for the model's own arguments; absent is empty.
    private static func text(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let string = value as? String { return string }
        if let list = value as? [Any] { return list.map { text($0) }.joined(separator: ",") }
        return "\(value)"
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - A calendar request is not a draft

    /// A request to block or schedule time, with no request to write mail in it, cannot become a draft.
    static func calendarRefusal(_ request: Any?) -> String? {
        guard let raw = request as? String else { return nil }
        let normal = raw.lowercased().replacingOccurrences(of: "[’‘]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !normal.isEmpty, matches(calendarWrite, normal), !matches(emailWrite, normal) else { return nil }
        return "NOT DRAFTED — the user's request is to block or schedule calendar time, not to write "
            + "mail. Call create_calendar_event and use the current email only as context for the "
            + "event title or description. Omit account to use the calendar matching the current inbox; ask only if no "
            + "matching calendar is connected. Do not call web_search. Nothing was saved."
    }

    private static let calendarWrite = #"\b(?:block|blocked|hold|held|book|reserve|schedule|add|create|put|set aside|carve out|bought)\b[^.!?]{0,80}\b(?:time|slot|event|meeting|appointment|calendar)\b|\b(?:block|blocked|hold|held|book|reserve|schedule|add|create|put|set aside|carve out|bought)\b[^.!?]{0,80}\b(?:on|in|to) (?:my|the) calendar\b"#
    private static let emailWrite = #"\b(?:reply|draft|forward)\b|\b(?:write|send)\s+(?:an?\s+)?(?:email|e-mail|message|reply|note)\b|\bemail\s+(?:him|her|them|[a-z][\w.-]*)\b|\b(?:tell|say to)\s+(?:him|her|them|[a-z][\w.-]*)\b|\brespond\s+to\s+(?:this|that|the|an?)?\s*(?:email|e-mail|message|thread)\b"#

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
