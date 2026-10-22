import Foundation
import FactoryKit

/// `forward_email`, run on the phone's own Google grant: the original message whole, with its attachments, from
/// the mailbox that holds it.
enum LocalForward {
    static let name = "forward_email"

    typealias Refusal = GmailReadTools.Refusal
    private typealias Manage = GmailManageTools

    /// Decoded bytes, ~24 MB once base64'd, under Gmail's 25 MB ceiling.
    static let attachmentCap = 18_000_000

    /// - Parameter defer: the caller advances on the receipt, so the Gmail call may land after it.
    static func run(argumentsJSON: String, defer deferred: Bool, conversationId: String? = nil) async
        -> FullDuplexBroker.ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let started = Date()
        do {
            let result = try await forward(args, deferred: deferred, conversationId: conversationId)
            RealtimeLog.log("localForward: \(result.ok == true ? "ok" : "not ok") in "
                + "\(Int(Date().timeIntervalSince(started) * 1000))ms — \(result.text.prefix(80))")
            return result
        } catch let refusal as Refusal {
            RealtimeLog.log("localForward: refused — \(refusal.text.prefix(120))")
            return .init(text: refusal.text, ok: false)
        } catch {
            RealtimeLog.log("localForward: failed — \(error)")
            return .init(text: "The \(name) call failed: \(Manage.detail(error))", ok: false)
        }
    }

    private static func forward(_ given: [String: Any], deferred: Bool,
                                conversationId: String?) async throws -> FullDuplexBroker.ToolResult {
        let (args, targets) = try await Manage.bind(name: name, given)
        // Before the original is looked up: a forward with nowhere to go refuses in one hop.
        let to = (args["to"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard LocalCompose.looksLikeAddress(to) else {
            throw Refusal(text: to.isEmpty
                ? "No recipient — call find_person for the address, or ask the user."
                : "Can't forward to \"\(to)\" — that isn't an email address. Call find_person for it, or ask the user. "
                    + "Nothing has gone yet.")
        }
        var seen: Set<String> = [LocalCompose.bareAddress(to).lowercased()]
        let cc = try LocalCompose.copyAddresses(args["cc"], field: "cc", seen: &seen)
        if cc.count > LocalCompose.copyMax {
            throw Refusal(text: "That is \(cc.count) people to copy, which is more than this should do in one go. "
                + "Read the list back to the user and let them cut it.")
        }

        let located = try await locate(targets, args)
        let (account, token, messageId, source) = (located.account, located.token, located.messageId, located.source)
        // In the source's own order, greedily: a scan too big to ride along must not take the invoice behind it too.
        var kept: [MailMIME.Attachment] = []
        var dropped: [MailMIME.Attachment] = []
        var total = 0
        for ref in source.attachments {
            if total + ref.size <= attachmentCap {
                kept.append(ref)
                total += ref.size
            } else {
                dropped.append(ref)
            }
        }
        let note = GmailReadTools.string(args, "note")

        // Fetched before the receipt: what fits is part of what the receipt says.
        var attachments: [(ref: MailMIME.Attachment, bytes: Data)] = []
        do {
            for ref in kept { attachments.append((ref, try await bytes(of: ref, messageId: messageId, token: token))) }
        } catch {
            return .init(text: Manage.isThrottle(error) ? "\(Manage.throttled) Nothing went out."
                : "That didn't forward (\(Manage.detail(error))). Nothing went out.", ok: false)
        }
        // Not limited to threads: handing an email on is what clears it.
        let files = StandingRule.archiveAfterForward.isOn
        let copies = cc.isEmpty ? "" : ", copying \(LocalCompose.speakList(cc))"
        let droppedClause = dropped.isEmpty ? ""
            : ", without \(LocalCompose.speakList(dropped.map { "\($0.filename) (\(Manage.describeSize($0.size)))" })) "
                + "— too big to send on"
        let raw = MailMIME.forward(.init(to: to, cc: cc, note: note, source: source, attachments: attachments,
                                         footer: MailFooter.isOn))
        let threadId = source.threadId.isEmpty ? nil : source.threadId

        if DraftsOnly.isOn(for: account) {
            let receipt = "Draft forward to \(to) saved in \(account)\(copies)\(droppedClause) — nothing was sent, because "
                + "Drafts only is on for this inbox." + (files ? LocalCompose.archivedByRule : "")
            return await finish(receipt: receipt, deferred: deferred, conversationId: conversationId, failure: { error in
                Manage.isThrottle(error) ? "\(Manage.throttled) No draft was saved."
                    : "that draft forward didn't save (\(Manage.detail(error))) — there is nothing in \(account)'s drafts, "
                        + "so it needs asking for again."
            }) { effects in
                try await LocalCompose.saveDraft(token, raw: raw, threadId: threadId)
                if files { await LocalCompose.fileByRule(token, account: account, threadId: threadId, effects) }
            }
        }
        // A forward's `to` is always the model's choice, never the thread's, so it is always checked.
        if strictJSONBool(args["recipient_confirmed"]) != true,
           !(try await LocalCompose.hasCorresponded(to, account: account, token: token)) {
            throw Refusal(text: "NOT SENT — first time you've mailed \(to). Ask the user \"is that the right person?\" "
                + "and if they say yes, call this again with recipient_confirmed: true. Nothing has gone yet.")
        }
        let receipt = "Forwarded to \(to) from \(account)\(copies)\(droppedClause)."
            + (files ? LocalCompose.archivedByRule : "")
        // Never retried: `messages/send` has no idempotency key, so a retry could forward it twice.
        return await finish(receipt: receipt, deferred: deferred, conversationId: conversationId, failure: { error in
            Manage.isThrottle(error) ? "\(Manage.throttled) Nothing went out."
                : "that didn't forward (\(Manage.detail(error))) — nothing went out, so it needs asking for again."
        }) { effects in
            await GmailQuota.shared.spend(100)
            var body: [String: Any] = ["raw": raw]
            if let threadId { body["threadId"] = threadId }
            _ = try await GmailAPI.call("POST", path: "messages/send", body: body, token: token)
            await Container.shared.contactStore().recordSent(account: account, email: LocalCompose.bareAddress(to))
            if files { await LocalCompose.fileByRule(token, account: account, threadId: threadId, effects) }
        }
    }

    /// The write after the receipt: deferred when the caller can carry the receipt, inline otherwise.
    private static func finish(receipt: String, deferred: Bool, conversationId: String?,
                               failure: @escaping @Sendable (Error) -> String,
                               _ write: @escaping @Sendable (Manage.Effects) async throws -> Void) async
        -> FullDuplexBroker.ToolResult {
        guard !deferred else {
            Task.detached {
                let effects = Manage.Effects()
                do {
                    try await write(effects)
                    await LocalCompose.applyEffects(effects.list)
                } catch {
                    Container.shared.localWriteNotices().push(failure(error), conversation: conversationId)
                }
            }
            return .init(text: receipt, ok: true, deferred: true)
        }
        let effects = Manage.Effects()
        do {
            try await write(effects)
        } catch {
            return .init(text: failure(error), ok: false)
        }
        return .init(text: LocalCompose.confirmed(receipt, effects.list), ok: true, effects: effects.list)
    }

    // MARK: - Finding the original

    /// The id across every target mailbox first, then the newest hit of `search`.
    private static func locate(_ targets: [String], _ args: [String: Any]) async throws
        -> (account: String, token: String, messageId: String, source: MailMIME.ForwardSource) {
        let messageId = GmailReadTools.string(args, "message_id") ?? ""
        let search = GmailReadTools.string(args, "search") ?? ""
        if !messageId.isEmpty {
            for account in targets {
                guard let token = try? await GmailReadTools.token(account),
                      let source = try? await source(messageId, token: token) else { continue }
                RealtimeLog.log("localForward: message_id resolved in \(account)")
                return (account, token, messageId, source)
            }
            RealtimeLog.log("localForward: message_id resolved in no inbox — \(search.isEmpty ? "no search given" : "searching")")
        }
        guard !search.isEmpty else {
            throw Refusal(text: messageId.isEmpty
                ? "No message id or search given — say which message, or pass a `search` like "
                    + "'from:stripe subject:\"Your receipt\"'."
                : "That message id isn't in any connected account. Search for the message first, then call this again "
                    + "with `search` set to a query that finds it.")
        }
        for account in targets {
            let token = try await GmailReadTools.token(account)
            await GmailQuota.shared.spend(GmailQuota.Cost.list)
            let list = (try? await GmailAPI.call("GET", path: "messages", query: ["q": search, "maxResults": "5"],
                                                 token: token)) ?? [:]
            guard let first = (list["messages"] as? [[String: Any]])?.first?["id"] as? String else { continue }
            RealtimeLog.log("localForward: resolved by search in \(account)")
            return (account, token, first, try await source(first, token: token))
        }
        throw Refusal(text: "Nothing matched \"\(search)\". Say what you searched.")
    }

    /// The message whole, read through `GmailAPI.call` so a headers-only mailbox can still forward:
    /// these bytes go into the outgoing message and never to a model.
    static func source(_ messageId: String, token: String) async throws -> MailMIME.ForwardSource {
        await GmailQuota.shared.spend(GmailQuota.Cost.get)
        let json = try await GmailAPI.call("GET", path: "messages/\(messageId)", query: ["format": "full"], token: token)
        return try source(json)
    }

    static func source(_ json: [String: Any]) throws -> MailMIME.ForwardSource {
        let message = try JSONDecoder().decode(GmailAPI.FullMessage.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        let payload = message.payload
        let header = { (name: String) in message.header(name) ?? "" }
        return MailMIME.ForwardSource(from: header("From"), date: header("Date"), subject: header("Subject"),
            to: header("To"), cc: header("Cc"), rfcMessageId: header("Message-ID"), threadId: message.threadId,
            text: payload.map(flattened)?.text ?? "", html: payload.map(html) ?? "",
            attachments: payload.map(attachments) ?? [])
    }

    /// A plain part anywhere at a level beats an HTML one, and HTML is read as text.
    private static func flattened(_ part: GmailAPI.FullPart) -> (text: String, kind: String?) {
        let decode = { (data: String?) in data.flatMap(MailBodyText.decodeBase64URL) ?? "" }
        if part.mimeType == "text/plain", let data = part.body?.data { return (decode(data), "plain") }
        if let children = part.parts {
            let nested = children.map(flattened)
            if let plain = nested.first(where: { $0.kind == "plain" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return plain
            }
            if let html = nested.first(where: { $0.kind == "html" && !$0.text.isEmpty }) { return html }
            if let empty = nested.first(where: { $0.kind == "html" }) { return empty }
        }
        if part.mimeType == "text/html", let data = part.body?.data {
            return (MailBodyText.stripHTML(decode(data)).trimmingCharacters(in: .whitespacesAndNewlines), "html")
        }
        return ("", nil)
    }

    /// The first non-blank `text/html` part, untouched.
    private static func html(_ part: GmailAPI.FullPart) -> String {
        if part.mimeType == "text/html", let data = part.body?.data { return MailBodyText.decodeBase64URL(data) ?? "" }
        for child in part.parts ?? [] {
            let found = html(child)
            if !found.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return found }
        }
        return ""
    }

    /// Every named part with bytes behind it, in tree order.
    private static func attachments(_ part: GmailAPI.FullPart) -> [MailMIME.Attachment] {
        var found: [MailMIME.Attachment] = []
        if let filename = part.filename, !filename.isEmpty, let body = part.body,
           !(body.attachmentId ?? "").isEmpty || body.data != nil {
            let contentId = part.headers?.first { $0.name.caseInsensitiveCompare("Content-ID") == .orderedSame }?.value
            found.append(.init(filename: filename, mimeType: part.mimeType ?? "application/octet-stream", size: body.size ?? 0,
                               attachmentId: body.attachmentId ?? "", data: body.data,
                               contentId: contentId?.isEmpty == false ? contentId : nil))
        }
        for child in part.parts ?? [] { found += attachments(child) }
        return found
    }

    /// The bytes inline when Gmail sent them, else the attachment endpoint.
    private static func bytes(of ref: MailMIME.Attachment, messageId: String, token: String) async throws -> Data {
        if let data = ref.data { return GmailAPI.decodeBase64URL(data) ?? Data() }
        await GmailQuota.shared.spend(GmailQuota.Cost.get)
        let body = try await GmailAPI.call("GET", path: "messages/\(messageId)/attachments/\(ref.attachmentId)",
                                           token: token)
        return (body["data"] as? String).flatMap(GmailAPI.decodeBase64URL) ?? Data()
    }
}
