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

    /// Forwards return only after the durable receipt records the provider outcome.
    static func run(argumentsJSON: String, defer deferred: Bool, conversationId: String? = nil,
                    userRequest: String? = nil, parentJobID: UUID? = nil, callID: String? = nil) async
        -> FullDuplexBroker.ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let started = Date()
        do {
            let result = try await forward(args, conversationId: conversationId, userRequest: userRequest,
                                           parentJobID: parentJobID, callID: callID)
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

    private static func forward(_ given: [String: Any], conversationId: String?, userRequest: String?,
                                parentJobID: UUID?, callID: String?) async throws -> FullDuplexBroker.ToolResult {
        let owner = await MainActor.run { Container.shared.backend().userId }
        let profile = ProfileRuntime.snapshot
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
        let resolution = try ForwardRecipient.resolve(to, source: source, userRequest: userRequest)
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
        let forward = MailMIME.Forward(to: to, cc: cc, note: note, source: source, attachments: attachments,
                                      footer: MailFooter.isOn)
        let raw = MailMIME.forward(forward)
        let threadId = source.threadId.isEmpty ? nil : source.threadId
        let draft = DraftsOnly.isOn(for: account)
        if !draft, strictJSONBool(args["recipient_confirmed"]) != true,
           !(try await LocalCompose.hasCorresponded(to, account: account, token: token)) {
            throw Refusal(text: "NOT SENT — first time you've mailed \(to). Ask the user \"is that the right person?\" "
                + "and if they say yes, call this again with recipient_confirmed: true. Nothing has gone yet.")
        }
        let receipt = (draft
            ? "Draft forward to \(to) saved in \(account)\(copies)\(droppedClause) — nothing was sent, because Drafts only is on for this inbox."
            : "Forwarded to \(to) from \(account)\(copies)\(droppedClause).")
            + (files ? LocalCompose.archivedByRule : "")
        guard let owner, !owner.isEmpty else {
            throw Refusal(text: "Nothing was sent or saved. Sign in so the forward can be recorded under your account.")
        }
        let content = MailMIME.forwardContent(forward)
        let outgoing = MailMIME.Outgoing(to: to, cc: cc, subject: content.subject, body: content.text,
            threadId: threadId, inReplyTo: source.rfcMessageId, attachments: attachments.map {
                .init(filename: $0.ref.filename, mimeType: $0.ref.mimeType, bytes: $0.bytes)
            })
        let key = callID.map { (parentJobID?.uuidString ?? conversationId ?? "foreground") + ":" + $0 }
        var action = MailActionReceipt(kind: draft ? .draftForward : .forward, account: account, message: outgoing,
            replyMessageID: messageId, parentJobID: parentJobID, requestKey: key)
        action.forwardResolution = resolution
        action.forwardNote = note
        action.forwardHTML = content.html.isEmpty ? nil : content.html
        action.omittedAttachments = dropped.map {
            .init(filename: $0.filename, mimeType: $0.mimeType, size: $0.size, reason: "Exceeds attachment limit")
        }
        action.archiveState = files ? "pending" : nil
        let store = await MainActor.run { Container.shared.dispatchJobs() }
        let origin = DispatchJob.MailOrigin(account: account, messageID: messageId, threadID: source.threadId,
                                             sender: source.from, subject: source.subject)
        #if targetEnvironment(macCatalyst)
        if draft {
            return try await LocalDraftReview.stage(action: action, message: outgoing, originalRaw: raw,
                owner: owner, profile: profile?.profileId, conversation: conversationId, origin: origin,
                archiveAfterSave: files, attachmentAccounts: attachments.isEmpty ? [] : [account])
        }
        #endif
        let (job, created) = try await store.beginMailAction(action, ownerID: owner, profileID: profile?.profileId,
                                                           conversationID: conversationId, origin: origin)
        guard created else { return MailActionAudit.replay(job) }
        let effects = Manage.Effects()
        do {
            let warning = try await MailActionAudit.write(job, receipt: receipt.replacingOccurrences(of: LocalCompose.archivedByRule, with: ""),
                validate: {
                    try Task.checkCancellation()
                    guard ProfileRuntime.snapshot?.membershipRevision == profile?.membershipRevision,
                          ProfileRuntime.allowedMailAccounts(GoogleAccountStore.mailAccounts()).contains(where: {
                              $0.caseInsensitiveCompare(account) == .orderedSame
                          }) else { throw Refusal(text: "Nothing was sent or saved. The source inbox changed.") }
                }) {
                    if draft { return try await LocalCompose.saveDraft(token, raw: raw, threadId: threadId) }
                    await GmailQuota.shared.spend(100)
                    var body: [String: Any] = ["raw": raw]
                    if let threadId { body["threadId"] = threadId }
                    return try await GmailAPI.call("POST", path: "messages/send", body: body, token: token)
                }
            if !draft { await Container.shared.contactStore().recordSent(account: account, email: LocalCompose.bareAddress(to)) }
            if files {
                await LocalCompose.fileByRule(token, account: account, threadId: threadId, effects)
                let archived = effects.list.contains { $0.removeLabelIds?.contains("INBOX") == true }
                _ = await store.recordMailArchive(job.id, state: archived ? "confirmed" : "unconfirmed")
            }
            let result = LocalCompose.confirmed(receipt, effects.list) + warning
            await MailActionAudit.update(job, result: result)
            return .init(text: result, ok: true, effects: effects.list)
        } catch {
            return .init(text: await MailActionAudit.result(job, fallback: Manage.detail(error)),
                         ok: false, outcomeUnknown: error is MailActionAudit.Failure)
        }
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
        return MailMIME.ForwardSource(from: header("From"), replyTo: header("Reply-To"), date: header("Date"), subject: header("Subject"),
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
