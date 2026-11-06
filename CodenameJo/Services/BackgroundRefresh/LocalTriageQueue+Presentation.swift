import Foundation

extension LocalTriageQueue {
    /// How an item is presented, per voice model. Live reads the message because it invents senders
    /// and subjects from the step alone; Realtime is accurate from the snippet.
    private static let liveBodySummary =
        "Automatically include what its body is about and what the sender wants, in your own "
            + "words. Delegate retrieval of the current message body unless it is already "
            + "supplied. Never volunteer when it was sent; give the sent date only if they ask, "
            + "and then use the message's own date, never one from the body. If unavailable, say "
            + "so. Summarize only this selected chain and its latest reply; retrieve needed "
            + "members without mixing other chains. Do not advance for retrieval. "
    private static let realtimeBodySummary =
        "Say what it is about from item.subject, item.snippet and the supplied conversation "
            + "context. Presenting an item costs no tool call: never read the message, search "
            + "context for its body, or announce a lookup. Never volunteer when it was sent; "
            + "give the sent date only if they ask, and then use item.date. Summarize only this "
            + "selected chain and its latest reply from the context supplied, never mixing other "
            + "chains. Only an explicit request for what it says or for more detail calls the "
            + "full-message read tool, and only then may the summary be extended. "

    /// Tools whose receipt is the whole turn: the model says nothing before calling them and leads
    /// with the receipt, so nothing composes in front of it. Canonicalised the way `markActed` stores it.
    static let receiptAfterActing: Set<String> = [
        "send_email", "forward_email", "create_draft", "unsubscribe_sender",
    ]

    /// Held answers that ran out of steps, for a close or a stop to carry. Empty in, empty out, so
    /// both callers merge it unconditionally.
    static func farewell(_ outcomes: [Outcome]) -> [String: Any] {
        guard !outcomes.isEmpty else { return [:] }
        // Per entry, because a closing set can mix a sweep and a summary on the same last message.
        let answers = outcomes.filter { $0.shape == .answer }
        let items: [[String: Any]] = outcomes.map { o in
            var item: [String: Any] = ["task": o.task, "outcome": o.text]
            if o.ok == false { item["unresolved"] = true }
            if o.shape == .answer { item["wantsTheAnswer"] = true }
            if o.independent { item["unrelatedToMail"] = true }
            return item
        }

        // Built by statement rather than as one expression: the `?:` chain was too slow for the
        // Swift type-checker.
        var note = outcomes.count == 1 ? "A job" : "\(outcomes.count) jobs"
        note += " you handed off came back while they were going through their mail, and the "
        note += "queue ended before there was a step to say it in. After the sentence above, "
        note += "reconnect each result to its original request. For an item marked "
        note += "`wantsTheAnswer`, say \"By the way, the background research you asked me "
        note += "to do on [who it is about, by name] came back\"; for other work, "
        note += "say \"By the way, the work you asked me to do on "
        note += "[who it is about, by name] is finished\". Replace the bracketed words; never read them "
        note += "aloud. For an item marked `unrelatedToMail`, instead say \"By the way,\", name what "
        note += "they asked about and give the answer. "
        // Name each job from its own outcome, not its task: the task names a document, and by now the
        // mail is gone, so the outcome is the only thing carrying a name.
        note += "**Each name comes from that item's own outcome, or from the sender of the "
        note += "email it was about — not from its task**, which describes documents and "
        note += "roles rather than naming anyone. Use the task's wording only when neither "
        note += "gives you a name, and never a role when a name is there. "
        note += "Then say how it went — every address it wrote to and whatever it "
        note += "moved — and stop there. "
        if outcomes.count > 1 {
            note += "Several, so lead with one sentence saying how many and what they touched, "
            note += "and let them ask: do NOT recite them one by one. "
        }
        // The one place the "do NOT recite" rule bends: a single answer-shaped entry is read out;
        // several fall back to "let them ask".
        if answers.count == 1 {
            note += "**One of them is marked `wantsTheAnswer`** — that one was asked to find "
            note += "something out, so give its answer rather than saying it finished, however "
            note += "many sentences that takes. \"That summary is done\" is not an answer. "
            note += "The rest, if any, stay a clause each."
        } else if answers.count > 1 {
            note += "**\(answers.count) of them are marked `wantsTheAnswer`** — each was asked "
            note += "to find something out, so a status is not enough for any of them. Give "
            note += "the first one's answer properly, say the others came back too and name "
            note += "what each was about, and let them ask for those."
        }

        return ["dispatchOutcomes": items, "dispatchOutcomesNote": note]
    }

    /// What may be said when the walk lands on its last message; `closeClaim` belongs to the turn after.
    static func lastNote(scope: Scope, adopted: Bool = false) -> String {
        let forbidden: String
        let close: String
        if adopted {
            forbidden = "they are through the messages they asked for"
            close = "\"Archived — that was the last one you asked for.\" Their inbox is NOT "
                + "clear, empty, at zero or gone through — never say any of that, and do not "
                + "state a mailbox count."
        } else {
            switch scope {
            case .all:
                forbidden = "they have been through their whole inbox"
                close = "\"Archived — that was the last message in this inbox pass.\" "
                    + "Even then, do NOT say their inbox is clear, empty or at zero: "
                    + "every message they did not act on is still sitting in it."
            case .important:
                forbidden = "their important mail is done"
                close = "\"Archived — that finishes this pass through important mail from the past week.\" "
                    + "Even then, do NOT say their inbox is clear or at zero: this "
                    + "queue only ever looked at what mattered from their past week, and the "
                    + "rest of their inbox is exactly where it was."
            case .unread:
                forbidden = "their inbox is clear"
                close = "\"Archived — that was the last unread message in this pass.\" "
                    + "Do NOT say their inbox is clear, empty or at zero: read mail may remain."
            }
        }
        return "This is the LAST message in the queue, and IT IS NOT DEALT WITH YET — so the "
            + "queue is NOT finished and you must not tell them it is. Do NOT say they are "
            + "done, do NOT say \(forbidden), and do NOT sum the queue up: they are standing "
            + "on a message that is still sitting in their inbox. Nothing else about THIS turn "
            + "changes — handle this message exactly as you would any other step. What changes "
            + "is the turn AFTER. There is no next message behind this one, so never say "
            + "\"Next is …\" about it: it leaves them waiting for mail that does not exist. "
            + "And WHEN THEY TELL YOU TO ARCHIVE, LABEL OR SPAM IT, THAT turn is the receipt "
            + "and the close together, with the call inside it: \(close) Only say that if the "
            + "write actually went and actually finished the message — a refusal, or a thread "
            + "with members left behind, is not a close. None of that is a reason to call "
            + "triage_next on THIS turn; `note` already says when the queue moves."
    }

    /// Traversal proves a selected pass completed, not that Gmail contains no inbox messages.
    static func closeClaim(scope: Scope, adopted: Bool = false) -> String {
        // An adopted queue is the handful they named, so the only claim worth stating is the one that
        // would be false.
        if adopted {
            return "This queue was only the messages they asked for, and it is finished. "
                + "Their inbox is NOT clear, empty, at zero or gone through — never say any "
                + "of that, and do not state a mailbox count."
        }
        let unit: String
        switch scope {
        case .all: unit = "the selected inbox pass"
        case .important: unit = "their important mail from the past week in this pass"
        case .unread: unit = "their unread messages in this pass"
        }
        return "They have been through \(unit). Say that in one sentence and NOTHING more — do "
            + "NOT say their inbox is clear, empty or at zero, and do not imply they are "
            + "finished with their mail. Everything outside \(unit) is exactly where it was."
    }

    // MARK: - The payload

    /// A landed job's answer, merged onto the step it rides: before the next message and after any
    /// email-action receipt, all from one result.
    static func outcomeFields(_ outcome: Outcome) -> [String: Any] {
        [
            "dispatchOutcome": [
                "task": outcome.task,
                "outcome": outcome.text,
            ].merging(outcome.ok == false ? ["unresolved": true] : [:]) { a, _ in a },
            "dispatchOutcomeNote": outcome.independent ? independentNote
                : (outcome.shape == .receipt ? receiptNote : answerNote) + outcomeNaming,
        ]
    }

    private static let independentNote = "Something the user asked earlier, unrelated to their "
        + "email, has been answered. Use this order: FIRST, if this turn just acted on an email, "
        + "acknowledge that action in a clause; SECOND, say \"By the way,\" name what they asked "
        + "about in a few words, and give them the answer, as briefly as it allows; THIRD, read the "
        + "message below out as normal, ending on what they want to do with it. If no email action "
        + "happened this turn, begin at SECOND. Keep all of it in this one turn. The answer is not "
        + "about the message below: \"the email\" and \"this one\" still mean the message. "

    /// The note for a job that was asked to get work done.
    private static let receiptNote = "Work they handed off earlier has come back. Use this "
        + "order: FIRST, if this turn just acted on an email, acknowledge that action "
        + "(\"That email was archived\", or the matching receipt); SECOND, use the task "
        + "below to say \"By the way, the work you asked me to do on "
        + "[who it is about, by name] is finished\" — replacing the bracketed words, never reading them "
        + "aloud — and say how it went in one clause — **name who or what it was "
        + "about**, the count it moved, every address it wrote *to*, whatever it came "
        + "back asking; THIRD, read the message below out as normal. If no email "
        + "action happened this turn, begin at SECOND. Keep all of it in this one "
        + "turn. Do "
        + "NOT drop the message to make room; and once you have said it, \"the "
        + "email\" and \"this one\" mean the message, never the job. "

    /// The note for a job that owes the user substance rather than a receipt. It names "that summary is
    /// done" because reporting completion and dropping the answer is what models do; length is `current()`'s.
    private static let answerNote = "A job they handed off earlier has come back, and it was "
        + "asked to **find something out** — so the answer below is the substance of this "
        + "turn, not a status to report. Use this order: FIRST, if this turn just acted on an "
        + "email, acknowledge that action in a clause (\"That email was archived\"); SECOND, "
        + "say \"By the way, the background research you asked me to "
        + "do on [who it is about, by name] came back\" — replacing the bracketed "
        + "words, never reading them aloud — and then **give them the answer — "
        + "everything they asked for, however many sentences that takes**; THIRD, read the "
        + "message below out as normal, ending on what they want to do with it. If no email "
        + "action happened this turn, begin at SECOND. Keep all of it in this one turn. "
        + "**\"That summary is done\" is not an answer.** They asked what something says, who "
        + "someone is, or what was decided — that is read out, never reported, and if you "
        + "find yourself saying the job finished you have dropped the thing they were waiting "
        + "for. Do NOT drop the message below to make room; and once you have given the "
        + "answer, \"the email\" and \"this one\" mean the message, never the job. "

    /// An answer served on the message it was about, as a step of its own. Not `current()`: no
    /// `position`, `note`, `last` or scope line, since the cursor has not moved.
    /// - Parameter item: this queue's own copy, when the message is still in the buffer (only items
    ///   ahead of the cursor are pruned). It carries the date, snippet and `acted` badge; the referent does not.
    static func presentedFields(
        _ outcome: Outcome, item: Item?
    ) -> [String: Any] {
        let about = outcome.about
        var mail: [String: Any] = [
            "account": item?.account ?? about?.account ?? "",
            "id": item?.id ?? about?.id ?? "",
            "threadId": item?.threadId ?? about?.threadId ?? "",
            // Raw, exactly as `current()` emits it, so a message sounds the same whichever step serves it.
            "from": item?.from ?? about?.from ?? "",
            "subject": item?.subject ?? about?.subject ?? "",
        ]
        if let item {
            mail["date"] = item.date
            mail["snippet"] = MailHeadersOnly.snippet(item.snippet)
        }
        // Normally absent: an answer-shaped handoff does not badge the message it was about.
        if let acted = item?.acted { mail["alreadyDone"] = acted }
        var payload: [String: Any] = [
            "done": false,
            "presentedForOutcome": true,
            "returnedWorkSelection": outcome.jobId.uuidString,
            "item": mail,
            "dispatchOutcomeNote": presentNote + outcomeNaming,
        ]
        var job: [String: Any] = ["task": outcome.task, "outcome": outcome.text]
        if outcome.ok == false { job["unresolved"] = true }
        payload["dispatchOutcome"] = job
        return payload
    }

    /// The returned answer owns this turn; the next user response releases the suspended queue.
    private static let presentNote = "A job they handed off earlier has come back. The message below is the email that job was about. "
        + "For this turn only, present this answer as its own feed item. Say \"By the way, the background research you asked me to do on [who it is about, by name] came back\" "
        + "— replacing the bracketed words, never reading them aloud — and give them everything they asked for, however many sentences that takes. "
        + "\"That summary is done\" is not an answer. End \"Circling back to that email from [sender].\" Do not ask its question again; it was already asked and stays open. "
        + "Use the sender below. Never say \"It's the email from …\"; do not re-read its body, announce another email, or repeat the preceding action receipt. "
        + "Wait for the user. Do not call triage_next again in this turn. That applies to this turn only; do not repeat the answer on later turns. "
        + "From here on \"the email\", \"this one\" and \"that message\" mean the message below. Pass message_id explicitly when you act on it, because the cursor is elsewhere. "
        + "Their place in the queue is untouched — nothing was skipped to make room for this, and the next triage_next carries on from where they were. "

    /// Naming the job, shared by both shapes. Keyed on where a name can be found (the outcome, then
    /// `item.from`, then the task), because a task describes a document and renders as a role.
    private static let outcomeNaming =
        "**Never say \"dispatch job\", \"that job\", \"the job is done\", or \"the "
        + "output of the background research\".** Name the original "
        + "request in plain language. For research, call it \"the background research you "
        + "asked me to do on [who it is about, by name]\"; for an action, call it \"the work you asked me "
        + "to do on [who it is about, by name]\". Replace the bracketed words; never read them aloud. Never "
        + "say \"that sender\" either. If all the task gives you is an address, say the "
        + "name it stands for — billing@mail.northwind-books.com is \"Northwind Books\". "
        + "**That subject is a name.** It is the person, company or thing the answer is "
        + "actually about, and you take it from the answer below, or from the sender of "
        + "the email the job was about — in that order. **The task is the last place to "
        + "look, not the first.** It was spoken over the message, so it says \"this one\" "
        + "and \"these\"; and it describes documents and roles rather than naming anyone, "
        + "so a task about an application paraphrases to \"that candidate\" — which names "
        + "nobody. Fall back to the task's own wording only when neither the answer nor "
        + "the sender gives you a name. **Never a role or a category when a name is "
        + "there**: \"that candidate\", \"the applicant\", \"the company\", \"that "
        + "sender\" all name nobody."

    static let liveSlackSentence = "Then the application moves straight on to Slack by itself: do not call "
        + "slack_triage_next for it and ask nothing about Slack. "

    /// The next lesson not already adopted, or `nil` once the plan is spent. The plan froze
    /// at session setup, so a rule switched on since is skipped rather than offered again.
    static func nextCoachingIndex(
        in lessons: [FullDuplexBroker.CoachingLesson],
        from position: Int,
        adopted: (String) -> Bool = { StandingRule(rawValue: $0)?.isOn == true }
    ) -> Int? {
        var index = max(position, 0)
        while index < lessons.count {
            if !adopted(lessons[index].capability) { return index }
            index += 1
        }
        return nil
    }

    static func nextCoachingCheckpoint(handled: Int, last: Int) -> Int? {
        handled / coachingEvery > last ? last + 1 : nil
    }

    static func threadStanding(_ item: Item, scope: Scope) -> [String: Any]? {
        if item.isTopicGroup {
            return ["queued": item.ids.count, "note": "These emails from the same sender concern one specific matter across separate Gmail threads. Give ONE concise summary of the latest state and outstanding requests, using all selected messages and their conversation context. Open with who and what; do not enumerate repetitive updates. Ask what to do with it; never invent a proactive suggestion. Later updates supersede earlier requests. Do not suggest separate actions for each email or use only the representative. Next leaves the entire group. For archive it, call archive_message with message_id set to item.archiveGroupId and the account; this archives all presented threads; an explicitly selected email targets only its thread. Replies and other writes require a specific member; ask which one if ambiguous. Never use the representative as an implicit reply target."]
        }
        let messages = item.conversation
        let hasDraft = item.hasDraft ?? false
        let pending = item.unresolvedContinuation == true
        // A single selected message inside a longer Gmail thread still owes a summary of the
        // conversation and its latest reply, so it needs a note.
        let inLongerThread = (item.threadMessageCount ?? 1) > messages.count
        guard messages.count > 1 || hasDraft || pending || inLongerThread else { return nil }
        let unread = messages.filter(\.unread)
        let read = messages.count - unread.count
        let senders = Self.spokenSenders(unread)
        let draft = hasDraft
            ? " They already have an unsent draft on this conversation — say so before "
                + "asking what to do with it."
            : ""
        guard messages.count > 1 else {
            let continuation = pending
                ? (unread.isEmpty
                    ? "This message was already read but requeued for a decision. Do not present it as new mail."
                    : "This message was requeued for a decision.")
                : ""
            let conversation = inLongerThread
                ? "**Open with the mail, never with the fact that it is a conversation.** Say who "
                    + "it is from and what it is about or wants first, in one or two sentences, "
                    + "summarising the earlier messages and this latest reply together from the "
                    + "thread context in this result. Only after that may you note it is part of "
                    + "a conversation, and only if it helps. Never open with 'this is a thread', "
                    + "never say how many messages it holds, and never name the thread instead of "
                    + "summarising it. Read the thread only if that context is missing. "
                : ""
            return ["queued": 1, "unread": unread.count, "senders": Self.spokenSenders(messages),
                    "note": (conversation + continuation + draft).trimmingCharacters(in: .whitespaces)]
        }
        if unread.isEmpty {
            return [
                "queued": messages.count, "unread": 0,
                "senders": Self.spokenSenders(messages),
                "note": "One conversation with \(messages.count) messages they have already read. "
                    + "Summarise the selected messages once: what the conversation is about "
                    + "and what the most recent message asks for. Do not present read messages as new."
                    + draft,
            ]
        }
        return [
            "queued": messages.count,
            "unread": unread.count,
            "senders": senders,
            "note": "One conversation with \(unread.count) new "
                + "\(unread.count == 1 ? "message" : "messages"), from \(Self.spokenList(senders))"
                + (read > 0
                    ? ", plus \(read) \(read == 1 ? "message" : "messages") they have already read"
                        + (scope == .all ? ", included in this inbox review" : ", carried only as context")
                    : "")
                + ". **Open with the mail, never with the fact that it is a conversation.** Say "
                + "who it is from and what it is about or wants first. Summarise it ONCE: what "
                + "it is about, what each new message says in a "
                + "clause, and what the most recent one asks for. Do not read them out one at "
                + "a time and do not repeat the subject for each. Never open with 'this is a "
                + "thread' or lead with how many messages it holds. Never present a message "
                + "marked read as new."
                + (scope == .all ? " Summarise the selected read messages too." : " Read messages are context only.")
                + draft,
        ]
    }

    static func spokenSenders(_ messages: [Item.Message]) -> [String] {
        var seen = Set<String>()
        return messages.map { spokenSender($0.from) }.filter { seen.insert($0.lowercased()).inserted }
    }

    /// "Marcus, Vivek and Jonathan" — a list as it is said rather than as it is punctuated.
    static func spokenList(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        if names.count == 2 { return "\(names[0]) and \(names[1])" }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    /// Who a message is from, as a name to say.
    static func spokenSender(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "<") else { return trimmed }
        let name = trimmed[trimmed.startIndex..<open]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        return name.isEmpty ? trimmed : speakableName(name)
    }

    private static let nameSuffixes: Set<String> = ["inc", "llc", "ltd", "co", "corp", "jr", "sr", "ii", "iii",
        "iv", "phd", "md", "esq", "gmbh", "plc", "llp", "lp", "pc", "ag", "sa"]

    /// A directory-style "Last, First" display name as it is said: "First Last".
    static func speakableName(_ display: String) -> String {
        let parts = display.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return display }
        let last = parts[0].split(whereSeparator: \.isWhitespace).map(String.init)
        let first = parts[1].split(whereSeparator: \.isWhitespace).map(String.init)
        let isName = { (word: String) in
            word.first?.isLetter == true && word.allSatisfy { $0.isLetter || "'.-".contains($0) }
                && !nameSuffixes.contains(word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        }
        guard last.count <= 2, first.count <= 2, (last + first).allSatisfy(isName) else { return display }
        return (first + last).joined(separator: " ")
    }

    /// The most messages the opening list of an important walk names.
    static let rankedMax = 5
    static let nothingImportantScript =
        "There's nothing important in your inbox right now. Want to do some cleanup?"

    /// The chain's latest member, whose author `spokenIdentity` names.
    static func latestAuthor(_ item: Item) -> (from: String, recipient: String?) {
        let contextual = item.displayGroupID == "read-thread"
            ? item.summaryMessages ?? [] : item.exchangeContext ?? []
        let latest = (item.conversation + contextual)
            .max(by: { $0.internalDate < $1.internalDate })
        return (latest?.from ?? item.from, latest?.recipient ?? item.recipient)
    }

    static func spokenIdentity(_ item: Item, owned: [String] = []) -> String {
        /// A name to say, or the bare address when the header carries no display name —
        /// a placeholder there erases the only identity such a message has.
        func speakable(_ raw: String, fallback: String) -> String {
            let name = spokenSender(raw)
            guard name.contains("@") else { return name }
            return MailAddress.list(raw).first?.email ?? fallback
        }
        let (from, recipient) = Self.latestAuthor(item)
        if Self.fromMe(from, accounts: [item.account] + owned),
           let recipient, !recipient.isEmpty {
            let parsed = MailAddress.list(recipient)
            let named = parsed.map(\.name).filter { !$0.isEmpty && !$0.contains("@") }
            let names: String
            if parsed.count > 1, named.isEmpty {
                names = "the recipients"
            } else if named.count < parsed.count, !named.isEmpty {
                names = Self.spokenList(named + ["other recipients"])
            } else {
                names = named.isEmpty
                    ? speakable(recipient, fallback: "the recipient") : Self.spokenList(named)
            }
            return "Your message to \(names)"
        }
        return speakable(from, fallback: "the sender")
    }

    static func presentationMatches(_ captured: Item, current: Item) -> Bool {
        captured.account.lowercased() == current.account.lowercased()
            && captured.threadId == current.threadId && captured.ids == current.ids
            && captured.acted == current.acted && captured.markedRead == current.markedRead
            && captured.displayGroupID == current.displayGroupID
    }

    /// The `item` a step hands the model: the message, its conversation, and its topic members.
    static func itemPayload(
        _ item: Item, owned: [String], decision: EmailCleanupDecision?
    ) -> [String: Any] {
        var itemPayload: [String: Any] = [
            "account": item.account,
            "id": item.id,
            "threadId": item.threadId,
            "from": item.from,
            "subject": item.subject,
            "date": item.date,
            "snippet": MailHeadersOnly.snippet(item.snippet),
            "fromMe": Self.fromMe(item.from, accounts: owned),
        ]
        // The step names who a sent message went to, so it never has to read one to say it.
        if let recipient = item.recipient, !recipient.isEmpty { itemPayload["to"] = recipient }
        itemPayload["exchangeId"] = item.displayGroupID
        for (key, context) in [("summaryMessages", item.summaryMessages), ("exchangeContext", item.exchangeContext)] {
            if let context, let data = try? JSONEncoder().encode(context),
               let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                itemPayload[key] = zip(entries, context).map { entry, message in
                    entry.merging(["fromMe": Self.fromMe(message.from, accounts: owned)]) { $1 }
                }
            }
        }
        if let acted = item.acted { itemPayload["alreadyDone"] = acted }
        let conversation = item.conversation
        if conversation.count > 1 {
            itemPayload["messages"] = conversation.map { message in
                var payload: [String: Any] = [
                    "id": message.id,
                    "threadId": message.threadId ?? item.threadId,
                    "from": Self.spokenSender(message.from),
                    "subject": message.subject,
                    "date": message.date,
                    "snippet": MailHeadersOnly.snippet(message.snippet),
                    "unread": message.unread,
                    "fromMe": Self.fromMe(message.from, accounts: owned),
                ]
                if let recipient = message.recipient, !recipient.isEmpty {
                    payload["to"] = recipient
                }
                return payload
            }
        }
        if item.isTopicGroup {
            itemPayload["groupKind"] = "topic"
            itemPayload["archiveGroupId"] = Self.topicSelectionID(item)
            itemPayload["conversations"] = item.unwrappedTopics.map { part -> [String: Any] in
                let context = part.summaryMessages ?? part.exchangeContext ?? []
                return ["threadId": part.threadId, "exchangeId": part.displayGroupID ?? "",
                    "messages": (part.conversation + context).map { member -> [String: Any] in
                        ["id": member.id, "threadId": member.threadId ?? part.threadId,
                         "from": Self.spokenSender(member.from), "subject": member.subject,
                         "snippet": MailHeadersOnly.snippet(member.snippet), "unread": member.unread,
                         "fromMe": Self.fromMe(member.from, accounts: owned)]
                    }]
            }
        }
        if item.hasDraft == true { itemPayload["hasDraft"] = true }
        // Why this one is in front of them, only ever on the top band. A reason the model can say in
        // passing, rather than a band label it would announce.
        if let why = item.importanceWhy, !why.isEmpty { itemPayload["why"] = why }
        if let decision {
            itemPayload["senderInboxCount"] = decision.senderInboxCount
        }
        // Unconditional: a cleanup offer changes what to say about the item, not who it is from.
        itemPayload["identity"] = Self.spokenIdentity(item, owned: owned)
        return itemPayload
    }

    /// How to put a Gmail-category cleanup offer for this item, in place of the ordinary summary.
    static func cleanupOfferNote(_ decision: EmailCleanupDecision) -> String {
        var note = ""
        note += "This cleanup comes from Gmail's own \(decision.category.rawValue) category, "
        note += "not a local model, and it does not change queue order. Do not give the "
        note += "ordinary summary or generic action question. "
        if decision.action == .unsubscribe {
            note += "Say this shape, substituting the sender display name and exact count: "
            note += "\"You have "
            note += decision.atLeast ? "at least [count]" : "[count]"
            note += " promotional emails from [sender] in your inbox. I can unsubscribe you "
            note += "from this sender and archive those messages. Should I go ahead and "
            note += "do that? \(EmailCleanupPolicy.alternativeOfferSentence)\" "
        } else if decision.category == .promotions {
            note += "The available cleanup action is archive. Do not mention unsubscribe "
            note += "availability, route safety, or verification. Say this shape: \"You have "
            note += decision.atLeast ? "at least [count]" : "[count]"
            note += " promotional emails from [sender] in your inbox. I can archive this "
            note += "batch. Shall I do that? \(EmailCleanupPolicy.alternativeOfferSentence)\" "
        } else {
            note += "Say this shape: \"This looks like a purchase or receipt. You have "
            note += decision.atLeast ? "at least [count]" : "[count]"
            note += " purchase emails from [sender] in your inbox. I can archive this batch. "
            note += "Shall I do that? \(EmailCleanupPolicy.alternativeOfferSentence)\" "
        }
        note += "Use cleanup.senderInboxCount for [count]. For [sender], use "
        note += "cleanup.senderDisplayName exactly. The first sender reference must be that "
        note += "actual name and must never be 'this sender'; only the later reference may "
        note += "say 'this sender'. Offer that one proactive recommendation, mention the "
        note += "alternative from the sentence above, and wait. Do not list every action. "
        note += (decision.action == .unsubscribe
            ? "Neither action has run. " : "Nothing has run. ")
        note += "Only an explicit yes to this immediately preceding "
        note += "offer for this item and account authorizes cleanup. On approval call dispatch "
        note += "exactly once with cleanup.dispatch.task, cleanup.dispatch.account, "
        note += "cleanup.dispatch.expects and cleanup.dispatch.facts. Never call "
        note += "unsubscribe_sender or modify_matching inline, and do not wait for the "
        note += "background result; follow dispatch's queue advance. A topic change, "
        note += "interruption, bare acknowledgement, silence or ambiguous answer does not "
        note += "authorize cleanup. If they ask who the sender is, how many there are, or "
        note += "what the offer means, answer from this item and cleanup, repeat the same "
        note += "cleanup question, and wait; do not call triage_next. That repeated offer is "
        note += "the new immediate approval context. A no or skip calls triage_next "
        note += "without a write. On an answered no — not a skip, a topic change or an "
        note += "interruption — set offer_declined true on that triage_next, so this "
        note += "sender is not offered the same cleanup again in this call. "
        note += EmailCleanupPolicy.alternativeActionGuidance
        return note
    }

    /// How to summarize an ordinary item and what to ask after it.
    static func summaryNote(liveFeatures: Bool) -> String {
        var note = ""
        note += "Give the normal one- or two-sentence summary. Open it with item.identity "
        note += "exactly, carry straight on into what the message says, and never speak the "
        note += "subject line as a label or a heading. "
        if !MailHeadersOnly.withholdsBodies {
            note += liveFeatures ? Self.liveBodySummary : Self.realtimeBodySummary
        } else {
            note += "Use item.snippet and supplied conversation context for what it says. "
        }
        note += "Introduce every item that way, including after an archive "
        note += "or a next. When the message is one the user sent, name who it went to "
        note += "from the item's 'to' field — 'your reply to Dana Whitfield', never just 'a reply "
        note += "you wrote' — using the display name in that field and never its address. "
        note += "For a thread summary, name the correspondent and who wrote the latest reply, "
        note += "and never borrow another member's recipients. fromMe true marks a message the user wrote: "
        note += "call it yours ('your invite', 'you proposed') and never say its sender's name. Credit what "
        note += "it says — an invitation, a proposed time or place — to the user, never to a participant its "
        note += "subject names. Credit every other message to its own sender, and quoted "
        note += "text in a snippet to whoever its attribution line names, never to the quoting sender. When the user asks to reply, say "
        note += "the recipient address the reply tool resolved, every recipient for reply-all. "
        note += "Never recite field labels such as From, Subject or Snippet, "
        note += "never spell the sender's address, and never invent the body. "
        if MailHeadersOnly.withholdsBodies {
            note += "No body is available; never fetch or infer one. "
        } else {
            note += "Only an explicit word-for-word read request gets the original wording. "
        }
        note += "Ask 'What would you like to do with it?' once per item, then wait. "
        note += "Answer follow-up questions without repeating the introduction or offering an action. "
        note += "Never invent a proactive suggestion. "
        note += "Wait for the answer. When they "
        note += "have said what to do — "
        note += "archive, label, reply, or nothing — do it and call triage_next again in "
        note += "the SAME turn to move on. Never ask whether they want to carry on."
        // Without this, an acknowledgement can make the model repeat the current message.
        note += " Once you have summarized this message, do not summarize it again — if they "
        note += "answer with nothing that decides anything (\"okay\", \"sure\", \"got it\"), "
        note += "call triage_next only if the preceding question was the generic action question "
        note += "or 'How do you want to deal with it?'. "
        note += "Next or skip advances without acting. Silence or noise authorizes nothing."
        return note
    }

    /// Every step carries this: noise never archives, and an explicit archive needs no confirmation.
    static let archiveRuleNote = " Archive is NEVER the default queue action. A cough, throat-clear, breath, "
        + "background noise, silence, unintelligible audio or a laugh does not authorize "
        + "archive_message or a cleanup dispatch. If the user asks to archive, archive the "
        + "email immediately without asking for confirmation, then continue the queue. "
        + "Next or skip means triage_next without archiving. A request to read or explain "
        + "the email means answer that request, not archive or advance. An acknowledgement "
        + "such as 'that was me, got it' is not an archive instruction. Only the explicit "
        + "approval of this item's immediately preceding cleanup offer authorizes its "
        + "proposed cleanup; never infer approval from noise or an earlier email's instruction."

    static func cleanupCoversConversation(_ item: Item, decision: EmailCleanupDecision) -> Bool {
        guard item.acted == nil, let sender = EmailCleanupPolicy.sender(item.from) else { return false }
        let matching = Set(decision.matchingMessageIDs)
        return item.conversation.allSatisfy {
            matching.contains($0.id) && EmailCleanupPolicy.sender($0.from) == sender
        }
    }

    static func cleanupInput(_ item: Item) -> EmailCleanupInput {
        EmailCleanupInput(
            account: item.account,
            id: item.id,
            from: item.from)
    }

    static func json(_ payload: [String: Any]) -> String {
        let sanitized = EmailQueueSpeechContract.sanitize(payload)
        guard let data = try? JSONSerialization.data(withJSONObject: sanitized),
              let text = String(data: data, encoding: .utf8)
        else { return "{\"note\":\"The queue could not be read. Say so and stop.\"}" }
        return text
    }
}
