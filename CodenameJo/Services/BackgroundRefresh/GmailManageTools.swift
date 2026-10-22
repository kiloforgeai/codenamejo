import Foundation
import FactoryKit

/// Labels, filters, bulk changes, unsubscribe and saved drafts, declared by the phone and run on its own Google grant.
/// Writes await Gmail rather than deferring.
enum GmailManageTools {
    static let listLabels = "gmail_list_labels"
    static let renameLabel = "gmail_rename_label"
    static let deleteLabel = "gmail_delete_label"
    static let unlabel = "gmail_unlabel_message"
    static let unarchive = "gmail_unarchive_message"
    static let modifyMatching = "gmail_modify_matching"
    static let unsubscribe = "gmail_unsubscribe_sender"
    static let sendDraft = "gmail_send_draft"
    static let deleteDraft = "gmail_delete_draft"
    static let listFilters = "gmail_list_mailbox_filters"
    static let createFilter = "gmail_create_mailbox_filter"
    static let deleteFilter = "gmail_delete_mailbox_filter"
    static let names: Set<String> = [listLabels, renameLabel, deleteLabel, unlabel, unarchive, modifyMatching,
                                     unsubscribe, sendDraft, deleteDraft, listFilters, createFilter, deleteFilter]

    /// Filters live under this scope rather than `gmail.modify`, so writing one is offered only where it was granted.
    static let filterScope = "https://www.googleapis.com/auth/gmail.settings.basic"

    typealias Refusal = GmailReadTools.Refusal

    // MARK: - Declarations

    /// `filterAccounts` are the mailboxes whose grant can write a filter; creating and deleting one is offered only then.
    static func definitions(accounts: [String], filterAccounts: [String]) -> [[String: Any]] {
        guard !accounts.isEmpty else { return [] }
        let connected = accounts.joined(separator: ", ")
        let account: [String: Any] = ["type": "string", "description":
            "For any read or action on a search hit, copy its account. Otherwise omit unless the user named an account; "
            + "search spans the active profile, other tools follow the feed. Connected: \(connected)."]
        let writeAccount: [String: Any] = ["type": "string", "description":
            "For a reply or action on a search hit, copy its account. For new mail, omit unless the user named a sender: "
            + "the tool selects the active inbox. Never ask which account. Connected: \(connected)."]
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "function", "name": name, "description": description, "strict": false,
             "parameters": ["type": "object", "properties": properties, "required": required]]
        }
        func string(_ description: String, enum values: [String]? = nil) -> [String: Any] {
            var out: [String: Any] = ["type": "string", "description": description]
            if let values { out["enum"] = values }
            return out
        }
        func boolean(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }
        var tools = [
            tool(listLabels, listLabelsNote,
                 ["account": account],
                 []),
            tool(renameLabel, renameLabelNote,
                 ["label": string("The label to rename, as it exists now, e.g. \"Recipts\". Must already exist. Never a Gmail "
                     + "system name — the inbox, spam, sent and Gmail's own categories are not labels that can be "
                     + "renamed."),
                  "name": string("What it should be called instead, e.g. \"Receipts\". Must not be a label that already exists: "
                     + "Gmail refuses the collision and there is no merge."),
                  "account": account],
                 ["label", "name"]),
            tool(deleteLabel, deleteLabelNote,
                 ["label": string("The label to delete, as the user said it, e.g. \"Promotional\". Must already exist. Never a "
                     + "Gmail system name — the inbox, spam, sent and Gmail's own categories cannot be deleted and "
                     + "asking is refused."),
                  "account": account],
                 ["label"]),
            tool(unlabel, unlabelNote,
                 ["message_id": string("The message, from a search hit or the queue step. Omit only if you genuinely have none: in a "
                     + "queue the message they are standing on is used, and `search` finds it anywhere else."),
                  "search": string("A Gmail query matching this message and nothing else, e.g. 'from:stripe subject:\"Your "
                     + "receipt\"'. Pass it with message_id; it is what finds the message if the id does not resolve."),
                  "label": string("The label to take off, as the user said it, e.g. \"GitHub\". Must already exist on this account. "
                     + "Never a Gmail system name — the inbox is not a label to remove here, and archive_message is the "
                     + "tool for taking a message out of it."),
                  "account": writeAccount],
                 ["label"]),
            tool(unarchive, unarchiveNote,
                 ["message_id": string("Exact ID of the earlier email being restored, copied from its archive action or search_context "
                     + "record. For undoing the previous email, never use the current feed item's ID. There is no cursor "
                     + "fallback."),
                  "search": string("Optional sender/subject description of the same earlier email. This never substitutes a "
                     + "different message if its ID is missing or invalid."),
                  "account": writeAccount],
                 []),
            tool(modifyMatching, modifyMatchingNote,
                 ["action": string("Which bulk action. `label` and `unlabel` also need `label`; `unlabel` is the only one whose "
                     + "`query` may be left out other than in a queue.", enum: ["archive", "label", "unlabel", "spam", "delete"]),
                  "query": string("Gmail search syntax for the set to act on, e.g. 'from:hi@easyplant.com', 'label:Promotions', "
                     + "'subject:invoice', 'older_than:1y'. **Leave it out in a queue** to mean the sender you are on. "
                     + "It must name what to match: 'in:inbox' or 'is:unread' alone is refused, because that is the "
                     + "whole mailbox, and excluding things does not narrow it — 'is:unread -from:me' is the same "
                     + "instruction wearing a disguise and is refused too. A query matching most of the mailbox is "
                     + "refused whatever its shape, and nothing happens when it is: report that back rather than trying "
                     + "a different way to say it. Do not add 'in:inbox' yourself — `archive` is scoped to it either "
                     + "way, and `label`, `spam` and `delete` reach archived mail on purpose. **For `unlabel` this is "
                     + "optional** and narrows *within* the label: it is ANDed with it, so 'from:github.com' means only "
                     + "the labelled mail from GitHub and '-from:github.com' means all the labelled mail that is not. A "
                     + "bare exclusion is fine there, because the label is already the set. Do not add the label term "
                     + "yourself; it is applied either way."),
                  "label": string("The label, as the user said it, e.g. \"Receipts\". **Required for `label` and `unlabel`.** For "
                     + "`label` it is created if it does not exist; for `unlabel` it must already exist and nothing is "
                     + "created. Never \"Spam\" or \"Trash\" as a filing label — spam is `action: spam`, delete is "
                     + "`action: delete`, and neither is a label this creates or removes — and never a Gmail system "
                     + "name: the inbox and unread are not labels this removes, and archive_message and "
                     + "unarchive_message are the tools for those."),
                  "also_archive": boolean("Take them out of the inbox at the same time. **For `label` only.** \"File all of this away\", "
                     + "\"label it and clear it out\" mean this — one call rather than `label` followed by `archive`."),
                  "account": account],
                 ["action"]),
            tool(unsubscribe, unsubscribeNote,
                 ["message_id": string("The message, from a search hit or the queue step. Omit only if you genuinely have none: in a "
                     + "queue the message they are standing on is used, and `search` finds it anywhere else."),
                  "sender": string("Whose mail to stop, when there is no message in front of you — a sending domain or address, e.g. "
                     + "'redditmail.com'. The newest message from them is what gets read for the unsubscribe link. Pass "
                     + "a broader domain ('pinterest.com') when the user means every stream a company sends, and leave "
                     + "it out when message_id or the queue supplies one."),
                  "search": string("A Gmail query matching this message and nothing else, e.g. 'from:stripe subject:\"Your "
                     + "receipt\"'. Pass it with message_id; it is what finds the message if the id does not resolve."),
                  "account": writeAccount,
                  "clear_existing": boolean("Whether to archive the existing matching inbox backlog after unsubscribing. Defaults to true for "
                     + "compatibility. Pass false when the user approved only the unsubscribe; existing messages then "
                     + "remain in the inbox."),
                  "clear_existing_query": string("Optional exact Gmail query for the backlog archive when clear_existing is true. Use this for a "
                     + "disclosed category-and-sender cleanup; otherwise the tool clears the sending host's inbox "
                     + "backlog.")],
                 []),
            tool(sendDraft, sendDraftNote,
                 ["message_id": string("The message id from a draft search result."),
                  "account": writeAccount],
                 ["message_id"]),
            tool(deleteDraft, deleteDraftNote,
                 ["message_id": string("The message id from a draft search result."),
                  "account": writeAccount],
                 ["message_id"]),
            tool(listFilters, listFiltersNote,
                 ["account": account],
                 [])
        ]
        guard !filterAccounts.isEmpty else { return tools }
        tools += [
            tool(createFilter, createFilterNote,
                 ["message_id": string("The message this rule came from, when there is one — from a queue step or a search hit. It gets "
                     + "the rule applied to it as well, and in a queue that is what moves the user on. Omit when the "
                     + "user is setting up a rule out of the blue."),
                  "search": string("A Gmail query matching this message and nothing else, e.g. 'from:stripe subject:\"Your "
                     + "receipt\"'. Pass it with message_id; it is what finds the message if the id does not resolve."),
                  "from": string("Sender to match — an address or a domain, e.g. \"stripe.com\" or \"receipts@stripe.com\". Prefer "
                     + "the domain when the user names a company, since a company sends from several addresses."),
                  "to": string("Recipient to match."),
                  "subject": string("Words in the subject."),
                  "query": string("Anything Gmail search can express, for matches the fields above can't, e.g. 'has:attachment "
                     + "larger:5M' or 'list:*'."),
                  "negated_query": string("Gmail search that must NOT match, e.g. 'from:me'."),
                  "label": string("Label to apply, as the user said it. Created if it doesn't exist."),
                  "skip_inbox": boolean("Keep it out of the inbox — what the user means by \"skip the inbox\", \"archive it\" or \"I "
                     + "don't need to see it\". The mail is still there and still searchable."),
                  "mark_read": boolean("Mark it read on arrival."),
                  "mark_important": boolean("Flag it as important, so it stands out."),
                  "account": writeAccount],
                 []),
            tool(deleteFilter, deleteFilterNote,
                 ["filter_id": string("The rule to delete, as list_mailbox_filters reported it. Required, and it is checked against the "
                     + "mailbox before anything is removed."),
                  "account": writeAccount],
                 ["filter_id"])
        ]
        return tools
    }

    private static let listLabelsNote = """
        List existing user labels per connected account when the user asks to browse them or clarify a label \
        name. Do not call this before label_message: that tool looks up the supplied name itself using a \
        mailbox-scoped cache. System labels are not included. For bulk labelling with modify_matching, use \
        this to check an uncertain name before creating a new label.
        """

    private static let renameLabelNote = """
        Rename a label. THIS IS WHAT "rename Receipts to Invoices", "call that label something else", "I \
        spelled that label wrong" MEAN. **Every message keeps the label** — Gmail addresses a label by id \
        and messages carry the id, so the name changes and nothing else does: nothing moves, nothing is \
        re-labelled, nothing leaves the inbox. Reversible — rename it back. asking and say you did. The \
        label must already exist; a name the mailbox does not have comes back refused with the names it does \
        have, so call list_labels first if you are guessing at the spelling. **This cannot merge two \
        labels.** Renaming to a name that is already taken is refused, because Gmail has no merge — putting \
        the mail under one label and getting rid of the other is modify_matching label, then action unlabel, \
        then delete_label, and that sequence is worth saying out loud before you start it.
        """

    private static let deleteLabelNote = """
        Delete a label for good. THIS IS WHAT "get rid of that label", "delete the Promotional label", "I \
        don't want that label any more" MEAN. **No mail is deleted** — every message stays exactly where it \
        is, in the inbox or the archive, read or unread — but the label comes off all of them and there is \
        no undo: recreating the name gives you an empty label, and which messages carried it is not \
        recoverable. So say what it costs in the same breath as doing it: the receipt gives you the label \
        and how many messages it was on, and that number is the thing to read out. The label must already \
        exist; a name the mailbox does not have is refused with the names it does have, and nothing is \
        deleted. **If more than one label matches what the user said, ask which** — "GitHub" and "GitHub \
        PRs" are one word apart and only one of them was meant. To clear a label off messages while keeping \
        the label itself, that is modify_matching unlabel, not this.
        """

    private static let unlabelNote = """
        Take a label off one message — the inverse of label_message. THIS IS WHAT "remove that label", "take \
        GitHub off this", "that shouldn't be labelled Receipts", "unlabel it" and "wrong label" MEAN. \
        Nothing moves and nothing is deleted. The label must already exist — this never creates one, and a \
        name the mailbox does not have comes back refused with the names it does have. It does NOT archive, \
        mark read, or move the message: only that one label comes off, and everything else about the message \
        stays where it was. THIS IS NOT A QUEUE STEP — it moves no cursor, so never say "Next is …" after \
        it; say nothing before calling it and let the receipt be your first words. For the same label across \
        many messages use modify_matching unlabel, which is one call rather than this in a loop.
        """

    private static let unarchiveNote = """
        Put an archived message back in the inbox — the inverse of archive_message. THIS IS WHAT "unarchive \
        that", "put that back", "undo that", "I didn't mean to archive that", "bring it back" and "restore \
        it" MEAN. NO LABEL IS NEEDED AND YOU NEVER ASK FOR ONE — label_message is not how a message comes \
        back, and asking the user what to call a label is the complaint this tool was written to answer. \
        Routine and reversible. It comes back unread, so it will be in their next queue; say so only if they \
        ask. **PASS THE ID YOU ARCHIVED WITH.** This is the one message tool where a missing id cannot be \
        filled in from the queue: the cursor has already moved past the message that was archived, so the \
        message they are standing on is a *different* message, and acting on it would put the wrong mail \
        back while the one they asked about stays gone. If you no longer have the id, recover the earlier \
        message and its action from search_context. Match the named sender or subject, and ask which email \
        if ambiguous. A skip is not an archive. An already-in-inbox result is not a successful restoration; \
        never substitute another target silently. THIS IS NOT A QUEUE STEP — it moves no cursor, so do not \
        speak first and never say "Next is …": say nothing before calling it and let the receipt be your \
        first words.
        """

    private static let modifyMatchingNote = """
        Act on EVERY message matching a Gmail query, in one call — the whole set, not a page of it. It \
        answers when the work is actually done, and the number it gives you is a count of what moved. Use \
        archive_message, trash_message, label_message, unlabel_message or mark_spam for one message you are \
        holding; use this for all of them.\n`archive` — "archive everything from EasyPlant", "clear out the \
        Promotions label", "get rid of anything older than a year". It only ever touches the inbox: mail \
        already archived is left alone.\n`label` — "file everything from Stripe under Receipts", "label all \
        the Vercel mail Infrastructure", "tag anything with an invoice". Needs `label` and creates it if it \
        does not exist. **It covers the whole mailbox, not just the inbox** — mail already archived gets the \
        label too. Messages that already have it are skipped, so running the same call twice is safe. Pass \
        also_archive to file and clear the inbox in the same call.\n`unlabel` — "remove the GitHub label \
        from anything that isn't actually from GitHub", "take Receipts off the Stripe marketing mail", \
        "unlabel the candidate emails". Needs `label`, and **the label is what bounds the work, so `query` \
        is optional here and only here**: leave it out to take the label off everything carrying it, or pass \
        one to narrow within the label. It never creates a label, and a name the mailbox does not have comes \
        back refused with the names it does have — so call list_labels first if you are guessing at the \
        spelling. THIS IS NOT delete_mailbox_filter — a rule that keeps re-applying the label is a separate \
        fix, and if they want both, do both and say so.\n`spam` — "all of this is junk", "report everything \
        from them", "send the whole lot to spam". Exactly what Gmail's own Report spam button does, applied \
        to the whole set: out of the inbox, into Spam, recorded as spam rather than as mail the user filed. \
        It covers the whole mailbox too, so never tell them this only works on what is still in their inbox. \
        **Prefer `archive` unless they actually said spam or junk.** Clearing a newsletter is archiving; \
        this teaches Gmail what the sender is, which is a judgement about them rather than about the mail, \
        and Gmail deletes reported mail after thirty days. It refuses far sooner than `archive` for that \
        reason — a query matching more than a thousand comes back refused with nothing reported, and the \
        answer to that is `archive`, not a reworded query. mark_spam says the rest.\n`delete` — "delete \
        everything from EasyPlant", "get rid of these for good", "empty out the Promotions backlog". Moves \
        the set to Trash — exactly what Gmail's own Delete does — and Gmail empties Trash after thirty days, \
        so nothing is gone the instant this runs. This is about messages, not `delete_label` (which deletes \
        a label, no mail touched) or `delete_mailbox_filter` (a rule, no mail touched). It covers the whole \
        mailbox, same as `label` and `spam`: mail already archived is reached too. Messages already in Trash \
        are skipped, so running the same call twice is safe. **Prefer `archive` unless they actually said \
        delete, trash or "for good."** Archiving keeps mail forever and searchable, and most "clean this up" \
        asks mean that; reach for `delete` only when the word or the intent is unmistakable.\nIN A QUEUE, \
        "all of these", "the rest of these" and "everything like this" MEAN THE SENDER OF THE MESSAGE IN \
        FRONT OF YOU — call this with no query at all and that sender is used. Never turn it into a query \
        about the whole inbox: the user is looking at one message and talking about it, and "all unread" is \
        not what they said. That fill-in is for `archive`, `label`, `spam` and `delete`; `unlabel` never \
        reads the cursor, because a blank query there already means every message under the label.
        """

    private static let unsubscribeNote = """
        Actually unsubscribe from a sender's mail, AND stop the rest arriving, AND by default clear what is \
        already there — one call. Set clear_existing false when the user approved only unsubscribing and did \
        not separately approve a backlog archive. When the approved cleanup is narrower than all mail from \
        that sender, pass clear_existing_query to pin the archive to that exact Gmail query. "Unsubscribe me \
        from these", "stop these emails", "get me off this list", "I don't want these any more" are this \
        tool. Never do this by hand with create_mailbox_filter and modify_matching: those cannot \
        unsubscribe, so the sender keeps sending and the user only stops seeing it. A rule happens in every \
        case; the clear-out happens unless clear_existing is false. Never follow this with \
        create_mailbox_filter, or with modify_matching when the backlog was already cleared, for the same \
        sender. **The answer says which of four things happened and you must repeat the distinction, not \
        flatten it to "unsubscribed":** it unsubscribed outright; it sent a request it cannot confirm; it \
        emailed an unsubscribe address; or the sender offers no unsubscribe at all, which means a person \
        wrote to them rather than a mailing list — say that plainly, the rule still ran. It keys on the \
        sending host, so 'explore.pinterest.com' stops one Pinterest stream and not the other three — pass \
        sender 'pinterest.com' when they mean the whole company.
        """

    private static let sendDraftNote = """
        Send a draft they already have, exactly as they wrote it. THIS IS WHAT "send that draft", "send it" \
        and "send that" MEAN whenever a draft is what you just read out or found — pass the message id from \
        search_drafts (or search_messages with in:drafts). NEVER REBUILD ONE OUT OF send_email: that sends \
        your transcription of their words instead of their words and leaves the original unsent in Drafts. \
        The recipient is already on the draft — do NOT call find_person and do NOT ask who it is for. The \
        receipt names the address; say it afterwards, as with any send.
        """

    private static let deleteDraftNote = """
        Permanently delete a saved draft. THIS IS WHAT "delete that draft", "discard the draft" and "clean \
        up that draft" MEAN. Search for the draft first with in:drafts and pass its message id. This cannot \
        be undone, so only use it when the user explicitly asks to delete or discard a draft.
        """

    private static let listFiltersNote = """
        Every standing rule on the mailbox, read back in plain words. Use it for "what rules do I have", \
        "what filters are set up", "is anything forwarding my mail", and BEFORE delete_mailbox_filter, which \
        needs an id from here. Also the way to answer "why didn't I see that email?" — a rule that skips the \
        inbox or files mail away is invisible otherwise, so check the rules against the sender before saying \
        the message never arrived. Rules made in Gmail itself show up here too, and some of them do things \
        you cannot write: forwarding mail elsewhere, or sending it straight to the bin. SAY THOSE OUT LOUD \
        FIRST if any exist — forwarding is the one thing on this list the user may not know is happening. \
        Summarise the rest; do not read out ids, and do not list fifteen rules one by one unless asked.
        """

    private static let createFilterNote = """
        Change what GMAIL ITSELF does to mail as it arrives — "always label anything from Stripe as Receipts \
        and skip the inbox", "mark newsletters read". Right when the thing being changed is THE MAILBOX: \
        what gets labelled, what skips the inbox, what is marked read or important. It is not right merely \
        because the user said "a rule", "from now on" or "always" — those words fit set_rule just as well, \
        and only the object of the sentence tells the two apart. "Label Stripe mail as Receipts" is this, \
        because it is about mail arriving; "archive it after I reply" is set_rule, because it is about what \
        happens after the user acts. label_message and archive_message act on one message that already \
        exists and do nothing about the next one. Reversible — a rule can be deleted, and it only touches \
        mail that arrives after it. So do not ask first. SAY THE WHOLE RULE AND CALL THIS IN THE SAME TURN, \
        past tense, exactly as archive_message describes: **what it matches and everything it does** — \
        "Done, mail from stripe.com now gets labelled Receipts and skips your inbox." You know every word \
        before it runs, so do not wait for this to answer and never say "I'll set that up". That sentence is \
        the only chance the user has to catch a rule that is wrong, because a filter is invisible afterwards \
        and acts on mail they never see. It cannot forward mail onward automatically or delete it; if the \
        user asks for either, say so plainly rather than writing a different rule (forwarding one message \
        they are holding is different — that is forward_email). Give at least one thing to match on and at \
        least one thing to do. IN A QUEUE, PASS message_id — the message the rule came from is then filed \
        the same way in this one call and the queue moves on. Without it the rule is still written, but the \
        message in front of the user is untouched and the queue stays where it is.
        """

    private static let deleteFilterNote = """
        Delete one standing rule, by the filter_id list_mailbox_filters gave. Use it for "get rid of that \
        rule", "stop doing that", "turn off the Stripe filter". CALL list_mailbox_filters FIRST and take the \
        id from its answer — never invent one; an id that isn't on the mailbox deletes nothing and you will \
        be told so. SAY WHICH RULE IS GOING IN THE SAME TURN, past tense, the way create_mailbox_filter \
        describes: what it matched and what it did. "Done, the rule that labelled Stripe mail Receipts is \
        gone." They cannot see a rule, so that sentence is the only way they learn which one you picked. \
        **GMAIL CANNOT EDIT A GMAIL RULE OR GMAIL FILTER.** To change one, delete it and call \
        create_mailbox_filter to write the replacement — say that is what you are doing, because the new \
        rule is a different rule and anything the old one could do that create_mailbox_filter cannot \
        (forwarding mail, sending it to the bin) will not come back. Deleting only stops future mail being \
        touched; mail the rule already filed stays exactly where it is.
        """

    // MARK: - The queue's message

    /// The message the feed is standing on, from its current step.
    struct Cursor: Equatable {
        let messageId: String
        let account: String
        let senders: [String]
    }

    static func cursor(step: String?) -> Cursor? {
        guard let step, let json = try? JSONSerialization.jsonObject(with: Data(step.utf8)) as? [String: Any],
              json["done"] as? Bool == false, let item = json["item"] as? [String: Any], item["alreadyDone"] == nil,
              let id = item["id"] as? String, !id.isEmpty, let account = item["account"] as? String, !account.isEmpty
        else { return nil }
        let froms = ((item["messages"] as? [[String: Any]]) ?? []).compactMap { $0["from"] as? String }
            + [item["from"] as? String].compactMap { $0 }
        var senders: [String] = []
        for sender in froms.map(bareAddress) where !sender.isEmpty && !senders.contains(sender) { senders.append(sender) }
        return Cursor(messageId: id, account: account, senders: senders)
    }

    /// "This" and "these" in a queue: a missing id becomes the message in front of the user, and a blank
    /// sweep its sender. Never for an unarchive or an unlabel sweep, whose referent is not the cursor.
    static func resolvedArguments(name: String, argumentsJSON: String, cursor: Cursor?) -> String {
        guard let cursor,
              var args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any]
        else { return argumentsJSON }
        let given = GmailReadTools.string(args, "message_id")
        switch name {
        case unlabel, unsubscribe, createFilter:
            if let given {
                guard given == cursor.messageId, GmailReadTools.string(args, "account") == nil else { return argumentsJSON }
                args["account"] = cursor.account
            } else {
                // A rule is set from the message only when one is named; a named sender is its own target.
                guard name != createFilter, name != unsubscribe || GmailReadTools.string(args, "sender") == nil
                else { return argumentsJSON }
                args["message_id"] = cursor.messageId
                args["account"] = cursor.account
            }
        case modifyMatching:
            let action = (args["action"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased()
            guard action != "unlabel", GmailReadTools.string(args, "query") == nil,
                  cursor.senders.count == 1, let sender = cursor.senders.first else { return argumentsJSON }
            args["query"] = "from:\(sender)"
            if GmailReadTools.string(args, "account") == nil { args["account"] = cursor.account }
        default:
            return argumentsJSON
        }
        guard let data = try? JSONSerialization.data(withJSONObject: args) else { return argumentsJSON }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Running

    /// What each write confirmed.
    final class Effects {
        var list: [GmailWriteEffect] = []
    }

    static func run(name: String, argumentsJSON: String)
        async -> (output: String, failed: Bool, effects: [GmailWriteEffect]?) {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let started = Date()
        let effects = Effects()
        let confirmed = { effects.list.isEmpty ? nil : effects.list }
        do {
            let (scoped, accounts) = try await bind(name: name, args)
            let output: String
            switch name {
            case listLabels: output = try await runListLabels(accounts)
            case renameLabel: output = try await runRenameLabel(scoped, accounts)
            case deleteLabel: output = try await runDeleteLabel(scoped, accounts)
            case unlabel: output = try await runUnlabel(scoped, accounts, effects)
            case unarchive: output = try await runUnarchive(scoped, accounts, effects)
            case modifyMatching: output = try await runSweep(scoped, accounts, effects).text
            case unsubscribe: output = try await runUnsubscribe(scoped, accounts, effects)
            case sendDraft: output = try await runSendDraft(scoped, accounts, effects)
            case deleteDraft: output = try await runDeleteDraft(scoped, accounts)
            case listFilters: output = try await runListFilters(accounts)
            case createFilter: output = try await runCreateFilter(scoped, accounts, effects)
            default: output = try await runDeleteFilter(scoped, accounts)
            }
            RealtimeLog.log("gmailManage: \(name) ok in \(Int(Date().timeIntervalSince(started) * 1000))ms")
            return (output, false, confirmed())
        } catch let refusal as Refusal {
            RealtimeLog.log("gmailManage: \(name) refused — \(refusal.text.prefix(120))")
            return (refusal.text, true, confirmed())
        } catch {
            return (GmailReadTools.describe(error), true, confirmed())
        }
    }

    private static let reads: Set<String> = [listLabels, listFilters]

    /// Writes stay on the feed's mailbox; a read goes where it was pointed, else the feed's.
    static func bind(name: String, _ args: [String: Any]) async throws -> ([String: Any], [String]) {
        let connected = ProfileRuntime.allowedMailAccounts(GoogleAccountStore.mailAccounts())
        guard !connected.isEmpty else { throw Refusal(text: "No Gmail account is connected on this phone. Say so plainly.") }
        let requested = GmailReadTools.string(args, "account")
        let mailbox = reads.contains(name) && requested != nil ? nil : await Container.shared.localTriage().currentMailbox
        let targetsItem = ["message_id", "thread_id", "draft_id"].contains { GmailReadTools.string(args, $0) != nil }
        if !reads.contains(name), targetsItem, let mailbox, let requested,
           mailbox.caseInsensitiveCompare(requested) != .orderedSame {
            throw Refusal(text: "Nothing was changed. That search result belongs to a different mailbox from the current feed. "
                + "Open that mailbox's feed before acting on it; do not retry without the result's account or use a different message.")
        }
        var out = args
        guard let selected = mailbox ?? requested else {
            out.removeValue(forKey: "account")
            return (out, connected)
        }
        guard let owned = connected.first(where: { $0.caseInsensitiveCompare(selected) == .orderedSame }) else {
            throw Refusal(text: "NOT SENT — that inbox is not connected. Ask which connected email account to use.")
        }
        out["account"] = owned
        return (out, [owned])
    }

    /// The one mailbox a write belongs to.
    static func single(_ accounts: [String]) throws -> String {
        guard accounts.count == 1 else {
            throw Refusal(text: "Multiple accounts connected — ask the user which one, then pass `account`.")
        }
        return accounts[0]
    }

    private static func canFilter(_ account: String) -> Bool {
        GoogleAccountStore.grant(for: account)?.scopes.contains(filterScope) == true
    }

    static let throttled = "Gmail is rate-limiting this account right now."

    static func isThrottle(_ error: Error) -> Bool {
        if case GmailAPI.Failure.throttled = error { return true }
        return false
    }

    static func isUnauthorized(_ error: Error) -> Bool {
        if case GmailAPI.Failure.unauthorized = error { return true }
        return false
    }

    static func status(_ error: Error) -> Int? {
        if case GmailAPI.Failure.http(let code) = error { return code }
        return nil
    }

    static func detail(_ error: Error) -> String {
        if let refusal = error as? Refusal { return refusal.text }
        if let code = status(error) { return "gmail \(code)" }
        return String(String(describing: error).prefix(160))
    }

    static func bareAddress(_ from: String) -> String {
        var address = from
        if let open = from.lastIndex(of: "<"), let close = from.lastIndex(of: ">"), open < close {
            address = String(from[from.index(after: open)..<close])
        }
        return address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Gmail calls

    static func modify(_ token: String, account: String, id: String, add: [String], remove: [String],
                               _ effects: Effects) async throws -> (id: String, threadId: String) {
        await GmailQuota.shared.spend(GmailQuota.Cost.get)
        let response = try await GmailAPI.call("POST", path: "messages/\(id)/modify",
            body: ["addLabelIds": add, "removeLabelIds": remove], token: token)
        let confirmed = response["id"] as? String ?? id
        let threadId = response["threadId"] as? String ?? ""
        effects.list.append(GmailWriteEffect(account: account, scope: "message", threadId: threadId.isEmpty ? nil : threadId,
            messageIds: [confirmed], messageIdsComplete: true, operation: "modify", addLabelIds: add, removeLabelIds: remove))
        return (confirmed, threadId)
    }

    static func modifyThread(_ token: String, account: String, threadId: String, add: [String], remove: [String],
                                     _ effects: Effects) async throws {
        await GmailQuota.shared.spend(10)
        let response = try await GmailAPI.call("POST", path: "threads/\(threadId)/modify",
            body: ["addLabelIds": add, "removeLabelIds": remove], token: token)
        let members = (response["messages"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        effects.list.append(GmailWriteEffect(account: account, scope: "thread", threadId: response["id"] as? String ?? threadId,
            messageIds: members ?? [], messageIdsComplete: members != nil, operation: "modify",
            addLabelIds: add, removeLabelIds: remove))
    }

    /// Gmail shows a thread in the inbox while any message in it still carries `INBOX`.
    static func modifyThreadWide(_ token: String, account: String, id: String, add: [String], remove: [String],
                                         _ effects: Effects) async throws {
        let confirmed = try await modify(token, account: account, id: id, add: add, remove: remove, effects)
        guard !confirmed.threadId.isEmpty else { return }
        try await modifyThread(token, account: account, threadId: confirmed.threadId, add: add, remove: remove, effects)
    }

    private static func batchModify(_ token: String, account: String, ids: [String], add: [String], remove: [String],
                                    _ effects: Effects) async throws {
        guard !ids.isEmpty else { return }
        await GmailQuota.shared.spend(50)
        var body: [String: Any] = ["ids": ids]
        if !add.isEmpty { body["addLabelIds"] = add }
        if !remove.isEmpty { body["removeLabelIds"] = remove }
        _ = try await GmailAPI.call("POST", path: "messages/batchModify", body: body, token: token)
        effects.list.append(GmailWriteEffect(account: account, scope: "message", threadId: nil, messageIds: ids,
            messageIdsComplete: true, operation: "batchModify",
            addLabelIds: add.isEmpty ? nil : add, removeLabelIds: remove.isEmpty ? nil : remove))
    }

    /// A dead id is retried against the `search` the model passed, nearest in time first.
    static func findAgain(_ token: String, args: [String: Any], deadId: String) async -> String? {
        guard let search = GmailReadTools.string(args, "search") else { return nil }
        await GmailQuota.shared.spend(GmailQuota.Cost.list)
        guard let hits = try? await GmailAPI.messagePage(token: token, query: search, limit: 5).messages, !hits.isEmpty
        else { return nil }
        guard let wanted = idClock(deadId) else { return hits[0].id }
        let distance = { (id: String) in idClock(id).map { abs($0 - wanted) } ?? .max }
        return hits.min { distance($0.id) < distance($1.id) }?.id
    }

    private static func idClock(_ id: String) -> Int? {
        guard id.count <= 16, let value = UInt64(id, radix: 16) else { return nil }
        return Int(value >> 20)
    }

    // MARK: - Labels

    struct Label: Equatable {
        let id: String
        let name: String
        let user: Bool
    }

    static func labels(_ token: String) async throws -> [Label] {
        await GmailQuota.shared.spend(GmailQuota.Cost.profile)
        let response = try await GmailAPI.call("GET", path: "labels", token: token)
        return ((response["labels"] as? [[String: Any]]) ?? []).compactMap { raw in
            guard let id = raw["id"] as? String, let name = raw["name"] as? String else { return nil }
            return Label(id: id, name: name, user: raw["type"] as? String == "user")
        }
    }

    static func findLabel(_ token: String, _ name: String) async throws -> Label? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return try await labels(token).first { $0.name.lowercased() == wanted }
    }

    /// The label, created on a miss; a 409 is a race, so it is looked up again.
    static func resolveLabel(_ token: String, _ name: String) async throws -> String {
        if let found = try await findLabel(token, name) { return found.id }
        do {
            let created = try await GmailAPI.call("POST", path: "labels", body: [
                "name": name.trimmingCharacters(in: .whitespaces),
                "labelListVisibility": "labelShow", "messageListVisibility": "show",
            ], token: token)
            if let id = created["id"] as? String { return id }
            throw GmailAPI.Failure.decoding("labels — no id")
        } catch GmailAPI.Failure.http(409) {
            if let raced = try await findLabel(token, name) { return raced.id }
            throw GmailAPI.Failure.http(409)
        }
    }

    static func systemLabelRefusal(_ name: String) -> String? {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "SPAM":
            return "Spam is not a label. For this one message, call mark_spam — that is what "
                + "Gmail's own Report spam button does. For every future message, a rule cannot "
                + "mark spam, so write it with skip_inbox and say their mail skips the inbox "
                + "from now on rather than promising spam."
        case "TRASH":
            return "Trash is not a filing label — it can't be applied or removed as one. To delete "
                + "one message, call trash_message. For a whole set of mail, call modify_matching "
                + "with action: delete instead of trying to label it Trash. A filter cannot delete "
                + "future mail either, so write it with "
                + "skip_inbox and say their mail skips the inbox from now on rather than promising "
                + "deletion."
        case "INBOX":
            return "The inbox is not a label to apply. To put an archived message back, call "
                + "unarchive_message — it takes no label. To take one out, archive_message, or "
                + "label_message's also_archive to file and archive at once."
        case "UNREAD":
            return "Read and unread are not labels here. Nothing on this surface sets either."
        case "SENT", "DRAFT", "CHAT":
            return "Gmail refuses that name — it is one of its own and cannot be applied. Ask the "
                + "user what to call the label."
        default:
            return nil
        }
    }

    /// The names that do exist are the answer, so the model can correct itself.
    private static func noSuchLabel(_ accounts: [String], _ label: String) async -> String {
        var names = Set<String>()
        for account in accounts {
            guard let token = try? await GmailReadTools.token(account),
                  let listed = try? await labels(token) else { continue }
            names.formUnion(listed.filter(\.user).map(\.name))
        }
        let sorted = names.sorted { $0.localizedCompare($1) == .orderedAscending }
        return "There is no label called \"\(label)\" in \(accounts.joined(separator: " or ")), so nothing was changed. "
            + (sorted.isEmpty
                ? "That account has no labels of its own at all."
                : "The labels that exist are: \(sorted.joined(separator: ", ")). Use one of those if one of them "
                    + "is what the user meant, or ask them which.")
    }

    private static func runListLabels(_ accounts: [String]) async throws -> String {
        var out: [[String: Any]] = []
        for account in accounts {
            do {
                let token = try await GmailReadTools.token(account)
                let names = try await labels(token).filter(\.user).map(\.name)
                    .sorted { $0.localizedCompare($1) == .orderedAscending }
                out.append(["account": account, "result": names])
            } catch {
                out.append(["account": account, "error": detail(error)])
            }
        }
        return GmailReadTools.json(out)
    }

    /// The user's own label by name, never one of Gmail's.
    private static func labelToActOn(_ token: String, account: String, _ label: String,
                                     verb: String) async throws -> (label: Label, all: [Label]) {
        let all = try await labels(token)
        let wanted = label.lowercased()
        guard let found = all.first(where: { $0.name.lowercased() == wanted }) else {
            throw Refusal(text: await noSuchLabel([account], label))
        }
        guard found.user else {
            throw Refusal(text: "\"\(found.name)\" is one of Gmail's own labels, not one of the user's, so it cannot be "
                + "\(verb) — the inbox, spam, sent, drafts and the Promotions/Social/Updates "
                + "categories are Gmail's furniture and it owns their names. Say that in one sentence "
                + "and leave it there. If they meant a label of their own with a similar name, "
                + "list_labels is what shows which ones exist.")
        }
        return (found, all)
    }

    static func renameRefusal(_ labels: [Label], current: Label, wanted: String) -> String? {
        let name = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "A rename needs a new name — ask the user what to call it." }
        if current.name == name { return "That label is already called \"\(name)\", so there is nothing to do." }
        guard let clash = labels.first(where: { $0.id != current.id && $0.name.lowercased() == name.lowercased() })
        else { return nil }
        if !clash.user {
            return "\"\(name)\" is a name Gmail keeps for itself, so no label can be called that. Pick another name."
        }
        return "There is already a label called \"\(clash.name)\", and Gmail cannot merge two labels "
            + "into one. To get everything under \"\(clash.name)\" and be rid of \"\(current.name)\": "
            + "modify_matching label with the query 'label:\"\(current.name)\"' and the label "
            + "\"\(clash.name)\", then action unlabel on \"\(current.name)\", then delete_label on "
            + "\"\(current.name)\". Say that is what it takes — it is three steps, not a rename — "
            + "and do it if they want it."
    }

    private static func runRenameLabel(_ args: [String: Any], _ accounts: [String]) async throws -> String {
        let target = try single(accounts)
        guard let label = GmailReadTools.string(args, "label"), let wanted = GmailReadTools.string(args, "name") else {
            throw Refusal(text: "A rename needs both names — the label as it is now and what it should be "
                + "called. Ask for whichever is missing.")
        }
        let token = try await GmailReadTools.token(target)
        let found = try await labelToActOn(token, account: target, label, verb: "renamed")
        let current = found.label
        if let refusal = renameRefusal(found.all, current: current, wanted: wanted) { throw Refusal(text: refusal) }
        do {
            _ = try await GmailAPI.call("PATCH", path: "labels/\(current.id)", body: ["name": wanted], token: token)
        } catch {
            throw Refusal(text: isThrottle(error)
                ? "\(throttled) The label is still called \"\(current.name)\"."
                : status(error) == 409
                    ? "\"\(wanted)\" turned out to be taken in \(target), so the label is "
                        + "still called \"\(current.name)\". Gmail cannot merge two labels; that is "
                        + "modify_matching label, then action unlabel, then delete_label."
                    : "that rename didn't go through (\(detail(error))) — the label is still called "
                        + "\"\(current.name)\", so it needs asking for again.")
        }
        return "Renamed \"\(current.name)\" to \"\(wanted)\" in \(target). Every message that had it still has it, under the new name."
    }

    private static func runDeleteLabel(_ args: [String: Any], _ accounts: [String]) async throws -> String {
        let target = try single(accounts)
        guard let label = GmailReadTools.string(args, "label") else {
            throw Refusal(text: "No label given, so nothing was deleted. Ask which label they mean.")
        }
        let token = try await GmailReadTools.token(target)
        let doomed = try await labelToActOn(token, account: target, label, verb: "deleted").label
        await GmailQuota.shared.spend(GmailQuota.Cost.profile)
        let size = (try? await GmailAPI.call("GET", path: "labels/\(doomed.id)", token: token))?["messagesTotal"] as? Int
        let carried = size.map { $0 == 1 ? "1 message" : "\($0) messages" } ?? "the messages that had it"
        do {
            _ = try await GmailAPI.call("DELETE", path: "labels/\(doomed.id)", token: token)
        } catch {
            throw Refusal(text: isThrottle(error)
                ? "\(throttled) The label \"\(doomed.name)\" is still there."
                : "that label didn't delete (\(detail(error))) — \"\(doomed.name)\" is still in "
                    + "\(target) and still on its mail, so it needs asking for again.")
        }
        return "Deleted the label \"\(doomed.name)\" from \(target) — it was on \(carried). Those messages are all still there, "
            + "exactly where they were; they just aren't labelled any more, and that can't be undone."
    }

    // MARK: - unlabel_message, unarchive_message

    /// The failure sentence once Gmail has refused the write.
    static func unchangedRefusal(_ error: Error, account: String, unchanged: String) -> Refusal {
        let capital = unchanged.prefix(1).uppercased() + unchanged.dropFirst()
        if isThrottle(error) { return Refusal(text: "\(throttled) \(capital).") }
        if isUnauthorized(error) {
            return Refusal(text: "\(account) needs reconnecting before it can archive, trash or label — "
                + "its access predates that permission. Remove and re-add the account in "
                + "Settings, then try again.")
        }
        if status(error) == 404 {
            return Refusal(text: "that one didn't go through — the message id doesn't match anything "
                + "in \(account), so \(unchanged). Search for it by sender and subject and act on the id the search returns.")
        }
        return Refusal(text: "that didn't go through (\(detail(error))) — \(unchanged).")
    }

    private static func runUnlabel(_ args: [String: Any], _ accounts: [String], _ effects: Effects) async throws -> String {
        guard let wanted = GmailReadTools.string(args, "label") else {
            throw Refusal(text: "No label given — ask the user which label to take off.")
        }
        if let reserved = systemLabelRefusal(wanted) { throw Refusal(text: reserved) }
        guard let messageId = GmailReadTools.string(args, "message_id") else {
            throw Refusal(text: "No message id — search first, then act on a result.")
        }
        let target = try single(accounts)
        let token = try await GmailReadTools.token(target)
        guard let label = try await findLabel(token, wanted) else { throw Refusal(text: await noSuchLabel([target], wanted)) }
        let unchanged = "the label is still on it"
        do {
            _ = try await modify(token, account: target, id: messageId, add: [], remove: [label.id], effects)
        } catch let error where status(error) == 404 {
            guard let found = await findAgain(token, args: args, deadId: messageId),
                  (try? await modify(token, account: target, id: found, add: [], remove: [label.id], effects)) != nil
            else { throw unchangedRefusal(error, account: target, unchanged: unchanged) }
            RealtimeLog.log("gmailManage: unlabel recovered — \(messageId) was dead, acted on \(found) instead")
        } catch {
            throw unchangedRefusal(error, account: target, unchanged: unchanged)
        }
        return "Removed \"\(wanted)\" in \(target)."
    }

    private static func runUnarchive(_ args: [String: Any], _ accounts: [String], _ effects: Effects) async throws -> String {
        guard let messageId = GmailReadTools.string(args, "message_id") else {
            throw Refusal(text: "No message id — search first, then act on a result.")
        }
        let target = try single(accounts)
        let token = try await GmailReadTools.token(target)
        let unchanged = "it is still archived"
        let state: (threadId: String, inInbox: Bool)
        do {
            state = try await undoState(token, messageId: messageId)
        } catch let refusal as Refusal {
            throw refusal
        } catch {
            throw unchangedRefusal(error, account: target, unchanged: unchanged)
        }
        // An archive still queued on this phone would land again after this put it back.
        let userId = await MainActor.run { Container.shared.backend().userId ?? "" }
        let pending = await Container.shared.pendingMailWrites().pending(userId: userId)
        if pending.contains(where: { !$0.isMessageScoped && $0.matches(account: target, ids: [messageId], threadId: state.threadId) }) {
            throw Refusal(text: "The archive is currently finishing. Wait a moment before undoing it.")
        }
        if state.inInbox {
            throw Refusal(text: "That email is already in your inbox. Nothing was restored or marked unread. "
                + "Do not claim an undo succeeded. Find the earlier email's identity in search_context; "
                + "if the intended sender or subject is unclear, ask which email they meant. Never substitute the current queue item.")
        }
        do {
            try await modifyThreadWide(token, account: target, id: messageId, add: ["INBOX", "UNREAD"], remove: [], effects)
        } catch {
            throw unchangedRefusal(error, account: target, unchanged: unchanged)
        }
        return "Back in your inbox in \(target)."
    }

    /// Every member is read, because archive and undo both act on the whole thread.
    private static func undoState(_ token: String, messageId: String) async throws -> (threadId: String, inInbox: Bool) {
        await GmailQuota.shared.spend(GmailQuota.Cost.get)
        let message = try await GmailAPI.call("GET", path: "messages/\(messageId)",
            query: ["format": "minimal", "fields": "id,threadId"], token: token)
        guard let threadId = message["threadId"] as? String, !threadId.isEmpty else {
            throw Refusal(text: "Gmail did not identify the thread for undo")
        }
        await GmailQuota.shared.spend(10)
        let thread = try await GmailAPI.call("GET", path: "threads/\(threadId)",
            query: ["format": "minimal", "fields": "messages(id,labelIds)"], token: token)
        guard let members = thread["messages"] as? [[String: Any]], members.contains(where: { $0["id"] as? String == messageId })
        else { throw Refusal(text: "Could not verify the email's inbox state. Nothing was restored.") }
        let labels = members.map { $0["labelIds"] as? [String] ?? [] }
        if labels.contains(where: { $0.contains("TRASH") || $0.contains("SPAM") }) {
            throw Refusal(text: "That conversation is in Trash or Spam, not archived. Nothing was restored.")
        }
        return (threadId, labels.contains { $0.contains("INBOX") })
    }

    // MARK: - modify_matching

    enum SweepKind: String, CaseIterable {
        case archive, label, unlabel, spam, delete
    }

    static let sweepPage = 500
    static let sweepCap = 2_000

    static func refuseAbove(_ kind: SweepKind) -> Int { kind == .spam ? 1_000 : 5_000 }

    /// The scope each action's own mutation invalidates, so a rerun finds only what is left.
    static func sweepScope(_ kind: SweepKind, label: String) -> String {
        switch kind {
        case .archive: return "in:inbox"
        case .spam: return "-in:spam"
        case .delete: return "-in:trash"
        case .label: return "-label:\"\(label)\""
        case .unlabel: return "label:\"\(label)\""
        }
    }

    static func sweepMutation(_ kind: SweepKind, labelId: String, alsoArchive: Bool) -> (add: [String], remove: [String]) {
        switch kind {
        case .archive: return ([], ["INBOX", "UNREAD"])
        case .spam: return (["SPAM"], ["INBOX", "UNREAD"])
        case .delete: return (["TRASH"], ["INBOX", "UNREAD"])
        case .label: return ([labelId], alsoArchive ? ["INBOX", "UNREAD"] : [])
        case .unlabel: return ([], [labelId])
        }
    }

    static func sweepRefusal(_ query: String, kind: SweepKind) -> String? {
        let positive = query.split(whereSeparator: \.isWhitespace).map(String.init).filter { term in
            !term.hasPrefix("-") && term.range(of: #"^(in:\S+|is:(un)?read)$"#, options: [.regularExpression, .caseInsensitive]) == nil
        }
        guard positive.isEmpty else { return nil }
        let what: String
        switch kind {
        case .spam: what = "That would report the entire mailbox as spam"
        case .label: what = "That would label the entire mailbox"
        case .unlabel: what = "That would strip the label off everything carrying it"
        case .delete: what = "That would delete the entire mailbox"
        case .archive: what = "That would archive the whole inbox"
        }
        return "\(what) — there is nothing in the query to match on. "
            + "Give it a sender, a subject, a label or an age, e.g. 'from:hi@easyplant.com'. "
            + "Excluding things does not narrow it: a query is what it matches, not what it skips."
    }

    static func sweepTooBig(count: Int, atLeast: Bool, kind: SweepKind) -> String {
        let how = atLeast ? "more than \(refuseAbove(kind))" : "\(count)"
        let narrow = "otherwise narrow it to a sender, a label or a subject."
        switch kind {
        case .spam:
            return "That query matches \(how) messages, which is far too many to report as spam on "
                + "one instruction — nothing was reported. Reporting spam teaches Gmail what this "
                + "sender is and bins the mail after thirty days, so it is not the tool for a "
                + "backlog this size: action archive clears whatever is still in the inbox and is "
                + "reversible. Say that to the user, or \(narrow)"
        case .label:
            return "That query matches \(how) messages, which is too much of the mailbox to label on "
                + "one instruction — nothing was labelled. If that really is the intent, say so to "
                + "the user and let them decide; \(narrow)"
        case .unlabel:
            return "That matches \(how) messages carrying the label, which is too many to unlabel on "
                + "one instruction — nothing was changed. If the user really means all of them, say "
                + "so and let them decide; otherwise narrow it within the label, to a sender, a "
                + "subject or an age."
        case .delete:
            return "That query matches \(how) messages, which is too much of the mailbox to delete on "
                + "one instruction — nothing was deleted. If that really is the intent, say so to the "
                + "user and let them decide; \(narrow)"
        case .archive:
            return "That query matches \(how) messages in the inbox, which is too much of it to archive "
                + "on one instruction — nothing was archived. If that really is the intent, say so to "
                + "the user and let them decide; \(narrow)"
        }
    }

    private static let noQuery: [SweepKind: String] = [
        .archive: "No query — say what to archive, e.g. 'from:hi@easyplant.com'. In a queue you "
            + "can leave it out and the sender of the message in front of you is used.",
        .label: "No query — say what to label, e.g. 'from:stripe.com'. In a queue you can leave "
            + "it out and the sender of the message in front of you is used.",
        .spam: "No query — say what to report as spam, e.g. 'from:noreply@spammer.example'. In "
            + "a queue you can leave it out and the sender of the message in front of you is used.",
        .delete: "No query — say what to delete, e.g. 'from:hi@easyplant.com'. In a queue you can "
            + "leave it out and the sender of the message in front of you is used.",
    ]

    static func sweepReceipt(_ kind: SweepKind, count: Int, query: String, label: String, alsoArchive: Bool) -> String {
        let many = "\(count) message\(count == 1 ? "" : "s") matching \(query)"
        switch kind {
        case .archive: return "Archived \(many)"
        case .unlabel: return "Removed the label \"\(label)\" from \(many)"
        case .spam: return "Reported \(many) as spam"
        case .delete: return "Deleted \(many)"
        case .label: return alsoArchive ? "Labelled and archived \(many) as \"\(label)\"" : "Labelled \(many) as \"\(label)\""
        }
    }

    static func sweepNothingToDo(_ kind: SweepKind, query: String, label: String) -> String {
        switch kind {
        case .archive: return "Nothing in the inbox matches \(query) — there was nothing to archive."
        case .spam: return "Nothing matches \(query) that isn't already in Spam — there was nothing to report."
        case .delete: return "Nothing matches \(query) that isn't already in Trash — there was nothing to delete."
        case .unlabel:
            return "Nothing carrying \"\(label)\" matches \(query) — the label is not on any of that "
                + "mail, so nothing was changed."
        case .label:
            return "Nothing matches \(query) that isn't already labelled \"\(label)\" — nothing was changed."
        }
    }

    static func countUpTo(_ token: String, query: String, cap: Int) async throws -> (count: Int, atLeast: Bool) {
        var count = 0
        var pageToken: String?
        while count < cap {
            await GmailQuota.shared.spend(GmailQuota.Cost.list)
            let page = try await GmailAPI.messagePage(token: token, query: query, limit: 500, pageToken: pageToken)
            let ids = page.messages ?? []
            count += ids.count
            pageToken = page.nextPageToken
            if pageToken == nil || ids.isEmpty { return (count, false) }
        }
        return (count, true)
    }

    private static func sweepMatching(_ token: String, account: String, query: String,
                                      mutation: (add: [String], remove: [String]),
                                      _ effects: Effects) async throws -> (modified: Int, hitCap: Bool) {
        var seen = Set<String>()
        while seen.count < sweepCap {
            await GmailQuota.shared.spend(GmailQuota.Cost.list)
            let page = try await GmailAPI.messagePage(token: token, query: query, limit: min(sweepPage, sweepCap - seen.count))
            var fresh: [String] = []
            for ref in page.messages ?? [] where !seen.contains(ref.id) && !fresh.contains(ref.id) { fresh.append(ref.id) }
            if fresh.isEmpty { return (seen.count, false) }
            try await batchModify(token, account: account, ids: fresh, add: mutation.add, remove: mutation.remove, effects)
            seen.formUnion(fresh)
        }
        return (seen.count, true)
    }

    /// Every match in one call, counted before anything moves and refused past the ceiling.
    static func runSweep(_ args: [String: Any], _ accounts: [String],
                         _ effects: Effects) async throws -> (text: String, changed: Int) {
        let given = (args["action"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let kind = SweepKind(rawValue: given.lowercased()) else {
            throw Refusal(text: given.isEmpty
                ? "No action given — say which bulk action this is: archive, label, unlabel, spam or delete."
                : "\"\(given)\" is not a bulk action. Use archive, label, unlabel, spam or delete.")
        }
        let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if kind != .unlabel {
            guard !query.isEmpty else { throw Refusal(text: noQuery[kind] ?? "") }
            if let refusal = sweepRefusal(query, kind: kind) { throw Refusal(text: refusal) }
        }
        let label = (args["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if kind == .label {
            guard !label.isEmpty else { throw Refusal(text: "No label given — ask the user what to call it.") }
            if let reserved = systemLabelRefusal(label) { throw Refusal(text: reserved) }
        }
        if kind == .unlabel {
            guard !label.isEmpty else { throw Refusal(text: "No label given — ask the user which label to take off.") }
            if let reserved = systemLabelRefusal(label) { throw Refusal(text: reserved) }
        }
        let alsoArchive = args["also_archive"] as? Bool == true
        let shown = query.isEmpty ? "label:\"\(label)\"" : query
        let scoped = "\(sweepScope(kind, label: label)) \(query)".trimmingCharacters(in: .whitespaces)

        var plan: [(account: String, token: String, mutation: (add: [String], remove: [String]))] = []
        var unprepared: [(account: String, error: Error)] = []
        for account in accounts {
            do {
                let token = try await GmailReadTools.token(account)
                if kind == .unlabel {
                    guard let found = try await findLabel(token, label) else { continue }
                    plan.append((account, token, sweepMutation(kind, labelId: found.id, alsoArchive: false)))
                } else {
                    let labelId = kind == .label ? try await resolveLabel(token, label) : ""
                    plan.append((account, token, sweepMutation(kind, labelId: labelId, alsoArchive: alsoArchive)))
                }
            } catch {
                unprepared.append((account, error))
            }
        }
        if kind == .unlabel, plan.isEmpty, unprepared.isEmpty { throw Refusal(text: await noSuchLabel(accounts, label)) }
        guard !plan.isEmpty else {
            throw Refusal(text: unprepared.map { failure in
                isUnauthorized(failure.error) || status(failure.error) == 403
                    ? "\(failure.account) needs reconnecting before it can label mail — ask the user to reconnect Google in Settings"
                    : "\(failure.account) could not be reached (\(detail(failure.error)))"
            }.joined(separator: "; ") + ". Nothing was changed.")
        }

        var total = 0
        var anyAtLeast = false
        for step in plan {
            let size = try await countUpTo(step.token, query: scoped, cap: refuseAbove(kind) + 1)
            total += size.count
            anyAtLeast = anyAtLeast || size.atLeast
        }
        if anyAtLeast || total > refuseAbove(kind) {
            RealtimeLog.log("gmailManage: \(kind.rawValue) sweep refused \(shown) — matches \(total)\(anyAtLeast ? "+" : "")")
            throw Refusal(text: sweepTooBig(count: total, atLeast: anyAtLeast, kind: kind))
        }

        var changed = 0
        var changedIn: [String] = []
        var cappedIn: [String] = []
        var failed = unprepared.map { ($0.account, detail($0.error)) }
        for step in plan {
            do {
                let done = try await sweepMatching(step.token, account: step.account, query: scoped,
                                                   mutation: step.mutation, effects)
                changed += done.modified
                if done.modified > 0 { changedIn.append(step.account) }
                if done.hitCap { cappedIn.append(step.account) }
            } catch {
                failed.append((step.account, detail(error)))
            }
        }
        let summary = sweepReceipt(kind, count: changed, query: shown, label: label, alsoArchive: alsoArchive)
        guard changed > 0 || !failed.isEmpty else { return (sweepNothingToDo(kind, query: shown, label: label), 0) }
        let place = changedIn.count == 1 ? " in \(changedIn[0])"
            : changedIn.count > 1 ? " across \(changedIn.joined(separator: " and "))" : ""
        let capNote = cappedIn.isEmpty ? ""
            : " That is this tool's own limit, not Gmail's, and more still matches — so this did not cover all of it."
        let failNote = failed.isEmpty ? ""
            : " \(failed.map { "\($0.0) could not be reached (\($0.1))" }.joined(separator: "; ")), so nothing was changed there."
        return ("\(summary)\(place).\(capNote)\(failNote)", changed)
    }

    // MARK: - unsubscribe_sender

    struct UnsubscribeHeaders: Equatable {
        var oneClick: String?
        var link: String?
        var mailto: Mailto?
        var dkimPass: Bool

        struct Mailto: Equatable {
            let to: String
            let subject: String
            let body: String
        }
    }

    static func parseUnsubscribe(_ listUnsubscribe: String, post: String, authentication: String) -> UnsubscribeHeaders {
        var uris: [String] = []
        var rest = Substring(listUnsubscribe)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            uris.append(rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces))
            rest = rest[rest.index(after: close)...]
        }
        let https = uris.first { $0.lowercased().hasPrefix("https://") }
        let mailto = uris.first { $0.lowercased().hasPrefix("mailto:") }
        let oneClick = https != nil
            && post.range(of: #"List-Unsubscribe\s*=\s*One-Click"#, options: [.regularExpression, .caseInsensitive]) != nil
            ? https : nil
        return UnsubscribeHeaders(
            oneClick: oneClick, link: oneClick == nil ? https : nil, mailto: mailto.map(parseMailto),
            dkimPass: authentication.range(of: #"\bdkim=pass\b"#, options: [.regularExpression, .caseInsensitive]) != nil)
    }

    private static func parseMailto(_ uri: String) -> UnsubscribeHeaders.Mailto {
        let withoutScheme = String(uri.dropFirst("mailto:".count))
        let parts = withoutScheme.split(separator: "?", maxSplits: 1).map(String.init)
        let to = (parts.first ?? "").removingPercentEncoding ?? parts.first ?? ""
        var subject = "", body = ""
        if parts.count > 1 {
            for item in URLComponents(string: "x:?" + parts[1])?.queryItems ?? [] {
                if item.name.lowercased() == "subject" { subject = item.value?.trimmingCharacters(in: .whitespaces) ?? "" }
                if item.name.lowercased() == "body" { body = item.value?.trimmingCharacters(in: .whitespaces) ?? "" }
            }
        }
        return .init(to: to.trimmingCharacters(in: .whitespaces),
                     subject: subject.isEmpty ? "unsubscribe" : subject, body: body.isEmpty ? "unsubscribe" : body)
    }

    /// The host, not the registrable domain, so one stream is stopped rather than a whole company.
    static func senderHost(_ address: String) -> String {
        let bare = bareAddress(address)
        guard let at = bare.lastIndex(of: "@") else { return bare }
        return String(bare[bare.index(after: at)...]).trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// A header URL is written by whoever sent the mail: HTTPS to a named public host, never an address literal.
    static func safeUnsubscribeURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty, host.contains("."),
              !host.contains(":"), host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil,
              ![".local", ".localhost", ".internal", ".home.arpa"].contains(where: { host.hasSuffix($0) })
        else { return nil }
        return url
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// RFC 8058's fixed body. A redirect counts as taken; it is never followed.
    private static func postUnsubscribe(_ raw: String) async -> Bool {
        guard let url = safeUnsubscribeURL(raw) else {
            RealtimeLog.log("gmailManage: unsubscribe POST refused — not a public https URL")
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        request.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: request, delegate: NoRedirects())
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            RealtimeLog.log("gmailManage: unsubscribe POST \(url.host ?? "") → \(code)")
            return (200..<400).contains(code)
        } catch {
            RealtimeLog.log("gmailManage: unsubscribe POST failed — \(error.localizedDescription.prefix(160))")
            return false
        }
    }

    private static func encodeHeader(_ value: String) -> String {
        value.allSatisfy(\.isASCII) ? value : "=?UTF-8?B?\(Data(value.utf8).base64EncodedString())?="
    }

    private static func sendMail(_ token: String, to: String, subject: String, body: String) async throws {
        let raw = ["To: \(to)", "Subject: \(encodeHeader(subject))", "Content-Type: text/plain; charset=UTF-8", "", body]
            .joined(separator: "\r\n")
        let encoded = Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        await GmailQuota.shared.spend(100)
        _ = try await GmailAPI.call("POST", path: "messages/send", body: ["raw": encoded], token: token)
    }

    private static func readUnsubscribe(_ token: String, messageId: String) async throws
        -> (headers: UnsubscribeHeaders, from: String) {
        await GmailQuota.shared.spend(GmailQuota.Cost.get)
        let wanted = ["From", "List-Unsubscribe", "List-Unsubscribe-Post", "Authentication-Results"]
        let message = try await GmailAPI.call("GET", path: "messages/\(messageId)", query: ["format": "metadata"],
            repeated: wanted.map { ("metadataHeaders", $0) }, token: token)
        let headers = ((message["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
        func header(_ name: String) -> String {
            (headers.first { ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }?["value"] as? String) ?? ""
        }
        return (parseUnsubscribe(header("List-Unsubscribe"), post: header("List-Unsubscribe-Post"),
                                 authentication: header("Authentication-Results")), header("From"))
    }

    private static func runUnsubscribe(_ args: [String: Any], _ accounts: [String], _ effects: Effects) async throws -> String {
        let target = try single(accounts)
        let token = try await GmailReadTools.token(target)
        let said = GmailReadTools.string(args, "sender") ?? ""
        let clearExisting = args["clear_existing"] as? Bool != false
        let clearExistingQuery = GmailReadTools.string(args, "clear_existing_query") ?? ""

        var messageId = GmailReadTools.string(args, "message_id") ?? ""
        if messageId.isEmpty {
            guard !said.isEmpty else {
                throw Refusal(text: "No message and no sender — say whose mail to stop, e.g. sender "
                    + "'redditmail.com', or pass the message_id it was said over.")
            }
            await GmailQuota.shared.spend(GmailQuota.Cost.list)
            let query = said.contains(":") ? said : "from:\(senderHost(said).isEmpty ? said : senderHost(said))"
            messageId = (try? await GmailAPI.messagePage(token: token, query: query, limit: 1).messages?.first?.id) ?? ""
            guard !messageId.isEmpty else {
                throw Refusal(text: "No mail from \(said) in \(target), so there is nothing to unsubscribe from.")
            }
        }
        let read: (headers: UnsubscribeHeaders, from: String)
        if let first = try? await readUnsubscribe(token, messageId: messageId) {
            read = first
        } else {
            guard let again = await findAgain(token, args: args, deadId: messageId) else {
                throw Refusal(text: "That message isn't in \(target) any more and no search was given to find "
                    + "it again. Search for one from that sender and call this with the hit.")
            }
            messageId = again
            read = try await readUnsubscribe(token, messageId: messageId)
        }
        let headers = read.headers

        let unsubHost = senderHost(read.from)
        let host = !said.isEmpty && !said.contains(":") ? senderHost(said) : unsubHost
        guard !host.isEmpty else { throw Refusal(text: "Could not tell who that message is from, so nothing was changed.") }
        let query = clearExistingQuery.isEmpty ? "from:\(host)" : clearExistingQuery
        let filters = canFilter(target)

        let offered = headers.oneClick != nil || headers.link != nil || headers.mailto != nil
        let stopped: String
        enum Route { case oneClick, link, mailto, unsigned, none }
        let route: Route = offered && !headers.dkimPass ? .unsigned
            : headers.oneClick != nil ? .oneClick : headers.link != nil ? .link : headers.mailto != nil ? .mailto : .none
        switch route {
        case .unsigned: stopped = "The unsubscribe on \(unsubHost)'s mail isn't signed by them, so I didn't use it."
        case .oneClick: stopped = "Unsubscribed from \(unsubHost)."
        case .link: stopped = "Sent an unsubscribe request to \(unsubHost) — I can't confirm they honoured it."
        case .mailto: stopped = "Emailed \(unsubHost)'s unsubscribe address."
        case .none: stopped = "No unsubscribe on \(unsubHost) — it isn't a mailing list."
        }
        let ruled = !filters
            ? " I can't add a rule to keep the rest out — \(target) needs reconnecting in Settings for that"
                + (clearExisting ? " — but I'm clearing out what's already there." : ".")
            : host == unsubHost
                ? " Their mail now skips your inbox\(clearExisting ? ", and I'm clearing out what's already there" : "")."
                : " Mail from \(host) now skips your inbox — that covers every address they send "
                    + "from, where the unsubscribe only covered \(unsubHost)"
                    + (clearExisting ? " — and I'm clearing out what's already there." : ".")
        let briefly = route == .oneClick && filters && host == unsubHost

        var problems: [String] = []
        var unsubscribeFailed = false
        switch route {
        case .oneClick:
            if !(await postUnsubscribe(headers.oneClick ?? "")) {
                if let mailto = headers.mailto {
                    do { try await sendMail(token, to: mailto.to, subject: mailto.subject, body: mailto.body) }
                    catch { unsubscribeFailed = true }
                } else {
                    unsubscribeFailed = true
                }
            }
        case .link:
            _ = await postUnsubscribe(headers.link ?? "")
        case .mailto:
            if let mailto = headers.mailto {
                do { try await sendMail(token, to: mailto.to, subject: mailto.subject, body: mailto.body) }
                catch { problems.append("the unsubscribe message to \(unsubHost) did not send") }
            }
        case .unsigned, .none:
            break
        }

        var ruleSaved = filters
        var backlogCleared = clearExisting
        if filters {
            do {
                _ = try await GmailAPI.call("POST", path: "settings/filters",
                    body: ["criteria": ["from": host], "action": ["removeLabelIds": ["INBOX"]]], token: token)
            } catch let error where status(error) == 409 {
                RealtimeLog.log("gmailManage: unsubscribe rule for \(host) was already there")
            } catch {
                ruleSaved = false
                problems.append("the rule to keep \(host) out of your inbox was not saved")
            }
        }
        if clearExisting {
            do {
                let swept = try await runSweep(["action": "archive", "query": query], [target], effects)
                if swept.changed == 0, !swept.text.hasPrefix("Nothing in the inbox matches") {
                    backlogCleared = false
                    problems.append("the backlog from \(host) was not cleared — \(swept.text)")
                }
            } catch {
                backlogCleared = false
                problems.append("the backlog from \(host) was not cleared — \(detail(error))")
            }
        } else if (try? await modify(token, account: target, id: messageId, add: [], remove: ["UNREAD"], effects)) == nil {
            problems.append("the message from \(unsubHost) could not be marked read")
        }
        if unsubscribeFailed {
            let kept = [ruleSaved ? "their mail skips your inbox now" : "", backlogCleared ? "I've cleaned the backlog" : ""]
                .filter { !$0.isEmpty }
            problems.insert("Couldn't unsubscribe you from \(unsubHost)"
                + (kept.isEmpty ? "" : ", but \(kept.joined(separator: " and "))"), at: 0)
        }
        guard problems.isEmpty else { throw Refusal(text: problems.joined(separator: "; ")) }
        return briefly ? stopped : stopped + ruled
    }

    // MARK: - Drafts

    private static func findDraftId(_ token: String, messageId: String) async throws -> String? {
        var pageToken: String?
        repeat {
            await GmailQuota.shared.spend(GmailQuota.Cost.list)
            let page = try await GmailAPI.draftPage(token: token, limit: 500, pageToken: pageToken)
            if let draft = page.drafts?.first(where: { $0.message?.id == messageId }) { return draft.id }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return nil
    }

    private static func runDeleteDraft(_ args: [String: Any], _ accounts: [String]) async throws -> String {
        guard let messageId = GmailReadTools.string(args, "message_id") else {
            throw Refusal(text: "No draft message id given — search drafts first.")
        }
        let target = try single(accounts)
        let token = try await GmailReadTools.token(target)
        do {
            guard let draftId = try await findDraftId(token, messageId: messageId) else {
                throw Refusal(text: "that draft was already gone from \(target) by the time it went to "
                    + "delete it — nothing was there to remove.")
            }
            _ = try await GmailAPI.call("DELETE", path: "drafts/\(draftId)", token: token)
        } catch let refusal as Refusal {
            throw refusal
        } catch {
            throw Refusal(text: isThrottle(error) ? "\(throttled) The draft is still there."
                : isUnauthorized(error)
                    ? "\(target) needs reconnecting before it can delete drafts — its "
                        + "access predates that permission. Remove and re-add the account in Settings, then try again."
                    : status(error) == 404 ? "that draft is already gone from \(target)."
                    : "the draft could not be deleted from \(target) (\(detail(error))) — it is still there.")
        }
        return "Deleted the draft from \(target)."
    }

    private static func runSendDraft(_ args: [String: Any], _ accounts: [String], _ effects: Effects) async throws -> String {
        guard let messageId = GmailReadTools.string(args, "message_id") else {
            throw Refusal(text: "No draft message id given — search drafts first.")
        }
        let target = try single(accounts)
        let token = try await GmailReadTools.token(target)
        guard let draftId = try await findDraftId(token, messageId: messageId) else {
            throw Refusal(text: "NOT SENT — there is no draft on that message in \(target). Search drafts "
                + "again and pass the id from the result. Nothing has gone yet.")
        }
        if DraftsOnly.isOn(for: target) {
            throw Refusal(text: "NOT SENT — Drafts only is on for \(target), so nothing goes out from it. "
                + "The draft is untouched. They can turn off Drafts only under Safeguards in Settings.")
        }
        let draft = try await GmailAPI.draftDetail(token: token, id: draftId)
        let to = draft.message?.header("To")?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !to.isEmpty else {
            throw Refusal(text: "NOT SENT — that draft has no recipient on it, so there is nowhere for it to go. "
                + "Ask who it should go to. Nothing has gone yet.")
        }
        let threadId = draft.message?.threadId ?? ""
        let filesSend = !threadId.isEmpty && StandingRule.archiveAfterReply.isOn
        do {
            _ = try await GmailAPI.call("POST", path: "drafts/send", body: ["id": draftId], token: token)
        } catch {
            throw Refusal(text: isThrottle(error) ? "\(throttled) Nothing went out and the draft is still there."
                : "that draft didn't send (\(detail(error))) — nothing went out, so it is still in \(target)'s drafts.")
        }
        guard filesSend else { return "Sent to \(to) from \(target)." }
        do {
            try await modifyThread(token, account: target, threadId: threadId, add: [], remove: ["INBOX", "UNREAD"], effects)
            return "Sent to \(to) from \(target). Archived."
        } catch {
            RealtimeLog.log("gmailManage: archive after send_draft failed — \(detail(error))")
            return "Sent to \(to) from \(target). The automatic archive was not confirmed; the mail may still be in the inbox."
        }
    }

    // MARK: - Filters

    private static let addedLabelWords: [String: String] = [
        "TRASH": "sent to the bin", "SPAM": "marked as spam", "IMPORTANT": "marked important", "STARRED": "starred",
        "UNREAD": "left unread", "INBOX": "kept in the inbox", "CATEGORY_PERSONAL": "filed under Personal",
        "CATEGORY_SOCIAL": "filed under Social", "CATEGORY_PROMOTIONS": "filed under Promotions",
        "CATEGORY_UPDATES": "filed under Updates", "CATEGORY_FORUMS": "filed under Forums",
    ]
    private static let removedLabelWords: [String: String] = [
        "INBOX": "kept out of the inbox", "UNREAD": "marked read", "IMPORTANT": "marked not important",
        "STARRED": "unstarred", "SPAM": "kept out of spam",
    ]

    static func joinWords(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.joined() }
        return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }

    static func describeSize(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return "\(Int((Double(bytes) / 1_000).rounded())) KB" }
        return "\(bytes) bytes"
    }

    static func describeFilter(_ filter: [String: Any], labelName: (String) -> String) -> (matches: String, does: String) {
        let c = filter["criteria"] as? [String: Any] ?? [:]
        let a = filter["action"] as? [String: Any] ?? [:]
        func text(_ key: String) -> String? { (c[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var matches: [String] = []
        if let from = text("from") { matches.append("from \(from)") }
        if let to = text("to") { matches.append("to \(to)") }
        if let subject = text("subject") { matches.append("with \"\(subject)\" in the subject") }
        if let query = text("query") { matches.append("matching \(query)") }
        if let negated = text("negatedQuery") { matches.append("not matching \(negated)") }
        if c["hasAttachment"] as? Bool == true { matches.append("with an attachment") }
        if let size = c["size"] as? Int, size > 0 {
            matches.append("\(c["sizeComparison"] as? String == "smaller" ? "smaller" : "larger") than \(describeSize(size))")
        }
        var does: [String] = []
        if let forward = a["forward"] as? String, !forward.isEmpty { does.append("forwarded to \(forward)") }
        does += (a["addLabelIds"] as? [String] ?? []).map { addedLabelWords[$0] ?? "labelled \"\(labelName($0))\"" }
        does += (a["removeLabelIds"] as? [String] ?? []).map { removedLabelWords[$0] ?? "un-labelled \"\(labelName($0))\"" }
        return (matches.isEmpty ? "(every message)" : matches.joined(separator: " and "),
                does.isEmpty ? "(nothing)" : joinWords(does))
    }

    static func isRebuildable(_ filter: [String: Any]) -> Bool {
        let a = filter["action"] as? [String: Any] ?? [:]
        if let forward = a["forward"] as? String, !forward.isEmpty { return false }
        return !(a["addLabelIds"] as? [String] ?? []).contains { $0 == "TRASH" || $0 == "SPAM" }
    }

    private static func filters(_ token: String) async throws -> [[String: Any]] {
        await GmailQuota.shared.spend(GmailQuota.Cost.profile)
        return try await GmailAPI.call("GET", path: "settings/filters", token: token)["filter"] as? [[String: Any]] ?? []
    }

    private static func labelNamer(_ token: String, _ filters: [[String: Any]]) async -> (String) -> String {
        let ids = filters.flatMap { filter -> [String] in
            let a = filter["action"] as? [String: Any] ?? [:]
            return (a["addLabelIds"] as? [String] ?? []) + (a["removeLabelIds"] as? [String] ?? [])
        }
        guard ids.contains(where: { addedLabelWords[$0] == nil && removedLabelWords[$0] == nil }),
              let all = try? await labels(token) else { return { $0 } }
        let byId = Dictionary(all.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return { byId[$0] ?? $0 }
    }

    private static func runListFilters(_ accounts: [String]) async throws -> String {
        var out: [[String: Any]] = []
        for account in accounts {
            do {
                let token = try await GmailReadTools.token(account)
                let stored = try await filters(token)
                let name = await labelNamer(token, stored)
                out.append(["account": account, "result": stored.map { filter -> [String: Any] in
                    let described = describeFilter(filter, labelName: name)
                    var row: [String: Any] = ["id": filter["id"] as? String ?? "",
                                              "rule": "mail \(described.matches) is \(described.does)"]
                    if !isRebuildable(filter) { row["cannot_be_rewritten"] = true }
                    return row
                }])
            } catch {
                out.append(["account": account, "error": detail(error)])
            }
        }
        return GmailReadTools.json(out)
    }

    private static func runCreateFilter(_ args: [String: Any], _ accounts: [String], _ effects: Effects) async throws -> String {
        let target = try single(accounts)
        guard canFilter(target) else {
            throw Refusal(text: "\(target) needs reconnecting before it can save a rule — writing "
                + "one needs a permission its access predates. Remove and re-add the account "
                + "in Settings, then try again. Labelling and archiving still work as normal.")
        }
        let criteriaKeys = [("from", "from"), ("to", "to"), ("subject", "subject"), ("query", "query"), ("negated_query", "negatedQuery")]
        var criteria: [String: String] = [:]
        for (arg, key) in criteriaKeys { if let value = GmailReadTools.string(args, arg) { criteria[key] = value } }
        guard !criteria.isEmpty else {
            throw Refusal(text: "NOT CREATED — no rule was saved. If they asked for a rule, ask what it should "
                + "apply to — a sender, a subject, or a search — and pass at least one of those. "
                + "If they did not ask for a rule, drop it and go back to what they actually asked for.")
        }
        let label = GmailReadTools.string(args, "label")
        if let label, let reserved = systemLabelRefusal(label) { throw Refusal(text: reserved) }
        let skipInbox = args["skip_inbox"] as? Bool == true
        let markRead = args["mark_read"] as? Bool == true
        let markImportant = args["mark_important"] as? Bool == true
        guard label != nil || skipInbox || markRead || markImportant else {
            throw Refusal(text: "NOT CREATED — no rule was saved. If they asked for a rule, ask what should "
                + "happen to matching mail — a label, skipping the inbox, marking it read or "
                + "important. If they did not ask for a rule, drop it and go back to what they "
                + "actually asked for.")
        }
        let matches = [criteria["from"].map { "from \($0)" }, criteria["to"].map { "to \($0)" },
                       criteria["subject"].map { "with \"\($0)\" in the subject" }, criteria["query"].map { "matching \($0)" },
                       criteria["negatedQuery"].map { "not matching \($0)" }].compactMap { $0 }
        let does = [label.map { "labelled \"\($0)\"" }, skipInbox ? "kept out of the inbox" : nil,
                    markRead ? "marked read" : nil, markImportant ? "marked important" : nil].compactMap { $0 }
        let sentence = "New mail \(matches.joined(separator: " and ")) is now \(joinWords(does)) in \(target)."
        let messageId = GmailReadTools.string(args, "message_id")
        let coverage = messageId != nil
            ? " I've applied it to this \(skipInbox ? "conversation" : "message") too; nothing else already in your inbox is touched."
            : " It applies to mail arriving from now on, not to anything already there."

        let token = try await GmailReadTools.token(target)
        var ruleSaved = false
        do {
            var labelIds: [String] = []
            if let label { labelIds = [try await resolveLabel(token, label)] }
            let add = labelIds + (markImportant ? ["IMPORTANT"] : [])
            let remove = (skipInbox ? ["INBOX"] : []) + (markRead ? ["UNREAD"] : [])
            _ = try await GmailAPI.call("POST", path: "settings/filters",
                body: ["criteria": criteria, "action": ["addLabelIds": add, "removeLabelIds": remove]], token: token)
            ruleSaved = true
            if let messageId {
                let act = { (id: String) async throws in
                    if skipInbox { try await modifyThreadWide(token, account: target, id: id, add: add, remove: remove, effects) }
                    else { _ = try await modify(token, account: target, id: id, add: add, remove: remove, effects) }
                }
                do {
                    try await act(messageId)
                } catch let error where status(error) == 404 {
                    guard let found = await findAgain(token, args: args, deadId: messageId) else { throw error }
                    try await act(found)
                    RealtimeLog.log("gmailManage: create_mailbox_filter recovered — \(messageId) was dead, filed \(found) instead")
                }
            }
        } catch {
            throw Refusal(text: isThrottle(error)
                ? "\(throttled) " + (ruleSaved
                    ? "The rule is saved, but that one message didn't get filed — it is still in the inbox."
                    : "The rule didn't save, so nothing has changed about your mail.")
                : isUnauthorized(error)
                    ? "\(target) needs reconnecting before it can save a rule — its access "
                        + "predates that permission. Remove and re-add the account in Settings, then ask for the rule again."
                    : ruleSaved
                        ? "the rule is saved, but that one message didn't get filed (\(detail(error))) — "
                            + "it is still sitting in the inbox, so archive or label it directly. "
                            + "Everything arriving from now on is covered."
                        : "that rule didn't save (\(detail(error))) — nothing has changed about your mail, "
                            + "so it needs asking for again.")
        }
        return sentence + coverage
    }

    private static func runDeleteFilter(_ args: [String: Any], _ accounts: [String]) async throws -> String {
        let target = try single(accounts)
        guard canFilter(target) else {
            throw Refusal(text: "\(target) needs reconnecting before a rule can be deleted — removing "
                + "one needs a permission its access predates, though reading them back does "
                + "not. Remove and re-add the account in Settings, then try again.")
        }
        guard let id = GmailReadTools.string(args, "filter_id") else {
            throw Refusal(text: "No filter id. Call list_mailbox_filters first and delete the rule by the id it "
                + "reports — a rule cannot be deleted by describing it.")
        }
        let token = try await GmailReadTools.token(target)
        let stored = try await filters(token)
        guard let doomed = stored.first(where: { $0["id"] as? String == id }) else {
            throw Refusal(text: "No rule with that id in \(target)\(stored.isEmpty ? " — that mailbox has no rules at all" : ""). "
                + "Call list_mailbox_filters and use an id from its answer; nothing has been deleted.")
        }
        let described = describeFilter(doomed, labelName: await labelNamer(token, [doomed]))
        do {
            _ = try await GmailAPI.call("DELETE", path: "settings/filters/\(id)", token: token)
        } catch {
            throw Refusal(text: isThrottle(error)
                ? "\(throttled) The rule is still there, so mail is still being filed by it."
                : isUnauthorized(error)
                    ? "\(target) needs reconnecting before a rule can be deleted — its "
                        + "access predates that permission. Remove and re-add the account in Settings, then ask again."
                    : "that rule didn't delete (\(detail(error))) — it is still in place and still "
                        + "filing mail, so it needs asking for again.")
        }
        return "The rule that had mail \(described.matches) \(described.does) is gone from \(target)."
            + " Mail it already filed stays where it is; only new mail is unaffected."
            + (isRebuildable(doomed) ? "" : " I can't write that rule again — forwarding and binning aren't things I'm able to set up.")
    }
}
