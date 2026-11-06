import Foundation

extension LiveToolSchemas {
    static func searchRecent(_ accounts: LiveSessionSetup.Accounts) -> [String: Any] {
        let unread = accounts.unread.joined(separator: ", ")
        return [
            "type": "function",
            "name": "search_recent",
            "description": "The user's recent mail, read and unread both, already to hand. Answers instantly and works with no signal. Use for explicitly recent requests such as what came in today. For a general email lookup, use gmail_search_messages to search all mail in the active profile, even if a recent lookup already found something. A recent lookup does not cover the profile's other mailboxes or older mail. Returns sender, subject, date, a snippet, whether it is unread, and the message id; pass an id to gmail_get_message, gmail_get_thread, gmail_archive_message or gmail_label_message exactly as you would with a result from gmail_search_messages. **\"Read me the last three\" is `count: 3` here, not a search** — that returns the newest three by arrival with everything you need to read them out, in one call and no round trip. It covers the selected mailbox's last day. With no account it uses the active mailbox, or the profile's own mailbox when no email queue is active. An empty answer is ordinary — it means nothing matched in that day, not that no such mail exists — so go to gmail_search_messages rather than telling the user there is none. **Never tell the user where an answer came from.** Not the phone, not a cache, not \"locally\": they asked about their mail, so talk about their mail.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "**Leave this out to list the newest unread** — that is what \"what's unread\", \"what came in\" and \"anything new\" mean, and passing a word like `unread` as the query searches the *text* of the mail for it and finds nothing. Only pass a query when the user named something to look for: a person, a company, a subject. Words in their own words — **not Gmail syntax**, `from:` and `is:` are not understood here. When they want a filter rather than a phrase, that is gmail_search_messages.",
                    ],
                    "count": [
                        "type": "integer",
                        "description": "How many of the newest messages to return, for \"read me the last three\", \"what are my last two emails\", \"catch me up on the last five\". Ordered by arrival, read and unread alike, within the selected mailbox. **Pass this instead of a query** — a number is not something to search the text for. What comes back is the spoken answer: read it out and do not open the messages to do it.",
                    ],
                    "unread": [
                        "type": "boolean",
                        "description": "Only when they said \"unread\". \"My last three emails\" means the three that arrived most recently, read or not.",
                    ],
                    "account": [
                        "type": "string",
                        "description": "Omit unless the user named an account: the tool selects the active inbox. Never ask which account. Connected: \(unread).",
                    ],
                ],
            ],
            "strict": false,
        ]
    }

    static func searchDrafts(_ accounts: LiveSessionSetup.Accounts) -> [String: Any] {
        let inboxes = accounts.inboxes.joined(separator: ", ")
        return [
            "type": "function",
            "name": "search_drafts",
            "description": "The user's saved drafts, already to hand. Answers instantly and works with no signal. **Try this first for anything about drafts** — \"read me my draft to Sarah\", \"do I have a draft going to the Kiloforge team\", \"what's the top draft in my personal account\" — before search_messages with in:drafts, which is slower and has to guess which connected account to search. Returns the recipient, subject, date, a snippet, the message id, and which account each draft is in whenever more than one account has any — say which mailbox a draft is in if the user has more than one connected rather than picking silently. Pass the message id to gmail_get_message or gmail_get_thread to read one in full before describing what's in it, to send_draft to send it exactly as they wrote it, or to delete_draft to remove it. **\"Send it\" after reading a draft out is send_draft, never send_email** — this result names the recipient but not their address, so rebuilding the mail means resolving a name that is already settled on the draft. An empty answer means this mailbox genuinely has no matching draft; only then fall back to search_messages with in:drafts. **Never tell the user where an answer came from.** Not the phone, not a cache, not \"locally\": they asked about their drafts, so talk about their drafts.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "**Leave this out to list the newest drafts.** Only pass a query when the user named something to look for: a recipient, a company, a subject. Words in their own words — **not Gmail syntax**.",
                    ],
                    "account": [
                        "type": "string",
                        "description": "Omit unless the user named an account: the tool selects the active inbox, or every connected one. Connected: \(inboxes).",
                    ],
                ],
            ],
            "strict": false,
        ]
    }

    private static var replyAttachments: [String: Any] {
        ["type": "array", "maxItems": 12,
         "description": "Attach only files the user requested, using exact references returned by gmail_get_message. The source account/message may differ from the reply destination account/thread_id/reply_message_id. This copies the selected files only, never the source correspondence. Do not forward the source email as a substitute. Never pass base64 bytes.",
         "items": ["type": "object", "properties": [
            "account": ["type": "string", "description": "Attachment source mailbox."],
            "message_id": ["type": "string", "description": "Attachment source Gmail message ID."],
            "filename": ["type": "string", "description": "Exact filename from attachment metadata."],
            "attachment_id": ["type": "string", "description": "Exact attachment_id from metadata; omit only for an inline file without that ID."]
         ], "required": ["account", "message_id", "filename"]]]
    }

    static func createDraft(_ accounts: LiveSessionSetup.Accounts) -> [String: Any] {
        let inboxes = accounts.inboxes.joined(separator: ", ")
        #if targetEnvironment(macCatalyst)
        let review = " Prepare a local preview in Jo’s center pane. The user must click Save to Gmail after reviewing it. Preparing a preview does not create a Gmail draft, send mail, archive the source or finish the feed item."
        #else
        let review = ""
        #endif
        return [
            "type": "function",
            "name": "create_draft",
            "description": "Save outgoing mail when the user explicitly asks for a draft. For ordinary write, reply or send requests, use send_email when available: it checks the current inbox mode even if an earlier turn said drafts. An email in context is not enough. For calendar time use create_calendar_event. Never sends. Pass thread_id for a reply." + review,
            "parameters": [
                "type": "object",
                "properties": [
                    "attachments": replyAttachments,
                    "to": [
                        "type": "string",
                        "description": "Omit when replying and the newest sender on the thread is answered. On a conversation with several senders, pass the address of the one the user named to answer that person instead. Always an email address, never a person's name.",
                    ],
                    "reply_all": [
                        "type": "boolean",
                        "description": "Omit or set true to copy everyone who was on the message being answered. Set false only when the user explicitly says to reply just to one person.",
                    ],
                    "cc": [
                        "type": "array",
                        "items": [
                            "type": "string",
                        ],
                        "description": "Optional. Email addresses to copy — an address, never a person's name, the same rule as `to`. Works on a reply: these are copied in addition to the thread's own recipient, and cc cannot redirect a reply elsewhere.",
                    ],
                    "bcc": [
                        "type": "array",
                        "items": [
                            "type": "string",
                        ],
                        "description": "Optional. Email addresses to copy blindly. Nobody on the message can see them, so saying them out loud afterwards is the only way the user learns they were copied at all. Same rule: an address, never a person's name.",
                    ],
                    "subject": [
                        "type": "string",
                        "description": "Omit when replying — the thread's subject is used.",
                    ],
                    "body": [
                        "type": "string",
                        "description": "Write only the message the user asked for. On replies, match their own earlier messages on the thread. Preserve their voice, warmth, vocabulary and punctuation habits; do not impose a generic professional tone. Keep simple requests simple: 'reply saying thanks' can be 'Thanks!' or 'Thanks, [recipient's name]!'. Do not pad it with repeated appreciation, 'I hope this finds you well', 'I'll stay tuned', or an unasked-for follow-up. Prefer ordinary words and direct sentences. Avoid dramatic em dashes unless the user's wording or writing habits support them. Keep every requested fact, question and commitment. Do not invent any. Preserve dictated or approved wording exactly.",
                    ],
                    "thread_id": [
                        "type": "string",
                    ],
                    "reply_message_id": [
                        "type": "string",
                        "description": "When replying to a specific message, pass its Gmail message ID alongside thread_id. Preserves that message's recipients and threading.",
                    ],
                    "user_request": [
                        "type": "string",
                        "description": "Current user request, copied exactly; calendar requests are rejected before Gmail.",
                    ],
                    "account": [
                        "type": "string",
                        "description": "For a reply or action on a search hit, copy its account. For new mail, omit unless the user named a sender: the tool selects the active inbox. Never ask which account. Connected: \(inboxes).",
                    ],
                ],
                "required": ["body", "user_request"],
            ],
            "strict": false,
        ]
    }

    static func sendEmail(_ accounts: LiveSessionSetup.Accounts) -> [String: Any] {
        let inboxes = accounts.inboxes.joined(separator: ", ")
        return [
            "type": "function",
            "name": "send_email",
            "description": "Write requested outgoing mail using the inbox’s current send/draft setting. In Drafts mode this saves a draft; in Send mode it sends immediately. Use this for ordinary write, reply or send requests even if an earlier turn said drafts. Use create_draft only for an explicit one-message draft request. Do not read mail back first and do not ask permission. The one exception is a `to` address this account has never mailed before: that comes back NOT SENT with what to ask, because a read-back after the fact is too late to catch a wrong address. Pass thread_id to send as a reply on an existing thread — a reply needs no `to`, because the thread's own recipient is used.",
            "parameters": [
                "type": "object",
                "properties": [
                    "attachments": replyAttachments,
                    "to": [
                        "type": "string",
                        "description": "Omit when replying and the newest sender on the thread is answered. On a conversation with several senders, pass the address of the one the user named to answer that person instead. Always an email address, never a person's name.",
                    ],
                    "reply_all": [
                        "type": "boolean",
                        "description": "Omit or set true to copy everyone who was on the message being answered. Set false only when the user explicitly says to reply just to one person.",
                    ],
                    "cc": [
                        "type": "array",
                        "items": [
                            "type": "string",
                        ],
                        "description": "Optional. Email addresses to copy — an address, never a person's name, the same rule as `to`. Works on a reply: these are copied in addition to the thread's own recipient, and cc cannot redirect a reply elsewhere.",
                    ],
                    "bcc": [
                        "type": "array",
                        "items": [
                            "type": "string",
                        ],
                        "description": "Optional. Email addresses to copy blindly. Nobody on the message can see them, so saying them out loud afterwards is the only way the user learns they were copied at all. Same rule: an address, never a person's name.",
                    ],
                    "subject": [
                        "type": "string",
                        "description": "Omit when replying — the thread's subject is used.",
                    ],
                    "body": [
                        "type": "string",
                        "description": "Write only the message the user asked for. On replies, match their own earlier messages on the thread. Preserve their voice, warmth, vocabulary and punctuation habits; do not impose a generic professional tone. Keep simple requests simple: 'reply saying thanks' can be 'Thanks!' or 'Thanks, [recipient's name]!'. Do not pad it with repeated appreciation, 'I hope this finds you well', 'I'll stay tuned', or an unasked-for follow-up. Prefer ordinary words and direct sentences. Avoid dramatic em dashes unless the user's wording or writing habits support them. Keep every requested fact, question and commitment. Do not invent any. Preserve dictated or approved wording exactly.",
                    ],
                    "thread_id": [
                        "type": "string",
                    ],
                    "reply_message_id": [
                        "type": "string",
                        "description": "When replying to a specific message, pass its Gmail message ID alongside thread_id. Preserves that message's recipients and threading.",
                    ],
                    "account": [
                        "type": "string",
                        "description": "For a reply or action on a search hit, copy its account. For new mail, omit unless the user named a sender: the tool selects the active inbox. Never ask which account. Connected: \(inboxes).",
                    ],
                    "recipient_confirmed": [
                        "type": "boolean",
                        "description": "Only after a NOT SENT refusal named a first-time address and the user confirmed it out loud. Omit otherwise — setting it without having asked defeats the whole point of the refusal.",
                    ],
                ],
                "required": ["body"],
            ],
            "strict": false,
        ]
    }

    static func forwardEmail(_ accounts: LiveSessionSetup.Accounts) -> [String: Any] {
        let inboxes = accounts.inboxes.joined(separator: ", ")
        return [
            "type": "function",
            "name": "forward_email",
            "description": "Forward a real message to someone: the original goes on verbatim — its formatting and attachments included — under a \"Forwarded message\" block, and the subject becomes Fwd: automatically. In drafts-only mode this saves a complete draft forward without sending. ALWAYS use this tool for forwards, including draft forwards. NEVER rebuild one with create_draft or send_email: retyping a message loses its formatting and attachments, and what arrives is your copy of it, not the mail itself. Forwarding is routine like sending. `to` is an email address, never a person's name. The one exception: a `to` this account has never mailed before comes back NOT SENT with what to ask, same as send_email. For a named person whose address is in the source, read get_message and distinguish From, replyTo and body contact evidence; use find_person if needed. Notification display names do not prove mailbox ownership, and prior correspondence does not resolve conflicting identities. Ask when evidence conflicts. Preserve an explicitly requested destination; do not automatically substitute Reply-To.",
            "parameters": [
                "type": "object",
                "properties": [
                    "message_id": [
                        "type": "string",
                        "description": "The message, from a search hit or the queue step. Omit only if you genuinely have none: in a queue the message they are standing on is used, and `search` finds it anywhere else.",
                    ],
                    "search": [
                        "type": "string",
                        "description": "A Gmail query matching this message and nothing else, e.g. 'from:stripe subject:\"Your receipt\"'. Pass it with message_id; it is what finds the message if the id does not resolve.",
                    ],
                    "to": [
                        "type": "string",
                        "description": "Where it goes — an email address, never a person's name.",
                    ],
                    "cc": [
                        "type": "array",
                        "items": [
                            "type": "string",
                        ],
                        "description": "Optional. Email addresses to copy — an address, never a person's name, the same rule as `to`.",
                    ],
                    "note": [
                        "type": "string",
                        "description": "A sentence from the user to put above the forwarded message — only what they actually asked to add, in their words. Omit it otherwise; never write one yourself.",
                    ],
                    "account": [
                        "type": "string",
                        "description": "For any read or action on a search hit, copy its account. Otherwise omit unless the user named an account; search spans the active profile, other tools follow the feed. Connected: \(inboxes).",
                    ],
                    "recipient_confirmed": [
                        "type": "boolean",
                        "description": "Only after a NOT SENT refusal named a first-time address and the user confirmed it out loud. Omit otherwise.",
                    ],
                ],
                "required": ["to"],
            ],
            "strict": false,
        ]
    }

    static func countMessages(_ accounts: LiveSessionSetup.Accounts) -> [String: Any] {
        let inboxes = accounts.inboxes.joined(separator: ", ")
        return [
            "type": "function",
            "name": "count_messages",
            "description": "Count messages matching a Gmail search query, without fetching them. Use this for 'how many unread' — ask it as 'in:inbox is:unread', which is the number the user means — rather than searching and counting, and to check your own work after clearing mail out. The answer is `count` plus `atLeast`: when `atLeast` is true the count stopped at its cap and the real figure is higher, so say \"more than\" rather than \"about\".",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Gmail search syntax, e.g. 'in:inbox is:unread', 'from:sarah newer_than:2d'. Scope it to 'in:inbox' unless the user asked about mail they have already filed — bare 'is:unread' counts every unread message in the account, most of which is archived.",
                    ],
                    "account": [
                        "type": "string",
                        "description": "For any read or action on a search hit, copy its account. Otherwise omit unless the user named an account; search spans the active profile, other tools follow the feed. Connected: \(inboxes).",
                    ],
                ],
                "required": ["query"],
            ],
            "strict": false,
        ]
    }

    static func archiveMessage(_ accounts: LiveSessionSetup.Accounts) -> [String: Any] {
        let inboxes = accounts.inboxes.joined(separator: ", ")
        return [
            "type": "function",
            "name": "archive_message",
            "description": "Archive a message — remove it from the inbox without deleting it. THIS IS WHAT \"archive\", \"archive it\", \"archive that\", \"clear it\", \"done with it\", \"file it\" and \"I'm done with that one\" MEAN — act, never ask what they meant. IN A QUEUE THIS IS A STEP. If the receipt hands you a `next` message, speak it in that same turn and do NOT call triage_next. If it gives none — the queue is on the user's phone and this receipt says only what happened — CALL triage_next IN THAT SAME TURN, passing message_id, or they wait on a queue that will not speak. PAST TENSE, FIRST WORD. If your sentence starts \"Okay, I'll\", \"Got it, I'll\", \"I'll archive that\" or \"let me\", it is wrong — a promise is a whole spoken turn that tells them nothing they don't know and leaves the next message unsaid. Never \"I'll archive that and move on\"; always \"Archived.\" Outside a queue there is nothing to read out, so say nothing before calling and let the receipt be your first words. Pass message_id from a search hit or from the queue step.",
            "parameters": [
                "type": "object",
                "properties": [
                    "message_id": [
                        "type": "string",
                        "description": "The message, from a search hit or the queue step. Omit only if you genuinely have none: in a queue the message they are standing on is used, and `search` finds it anywhere else.",
                    ],
                    "search": [
                        "type": "string",
                        "description": "A Gmail query matching this message and nothing else, e.g. 'from:stripe subject:\"Your receipt\"'. Pass it with message_id; it is what finds the message if the id does not resolve.",
                    ],
                    "account": [
                        "type": "string",
                        "description": "For a reply or action on a search hit, copy its account. For new mail, omit unless the user named a sender: the tool selects the active inbox. Never ask which account. Connected: \(inboxes).",
                    ],
                ],
            ],
            "strict": false,
        ]
    }

    static func labelMessage(_ accounts: LiveSessionSetup.Accounts) -> [String: Any] {
        let inboxes = accounts.inboxes.joined(separator: ", ")
        return [
            "type": "function",
            "name": "label_message",
            "description": "Apply a label to a message. Pass the name directly: this tool looks it up in a mailbox-scoped cache, matches case-insensitively, and creates it if absent. Do not call list_labels first. THIS IS WHAT \"label it X\", \"file it under X\", \"tag it X\" and \"put that in X\" MEAN. IN A QUEUE THIS IS A STEP, and archive_message describes how to advance it: speak the `next` the receipt gives you, or call triage_next in that same turn with message_id when it gives none. Outside a queue, say nothing before calling it and let the receipt be your first words. Pass also_archive to take it out of the inbox at the same time. Labelling never puts a message *back* in the inbox — unarchive_message does that, and it needs no label.",
            "parameters": [
                "type": "object",
                "properties": [
                    "message_id": [
                        "type": "string",
                        "description": "The message, from a search hit or the queue step. Omit only if you genuinely have none: in a queue the message they are standing on is used, and `search` finds it anywhere else.",
                    ],
                    "search": [
                        "type": "string",
                        "description": "A Gmail query matching this message and nothing else, e.g. 'from:stripe subject:\"Your receipt\"'. Pass it with message_id; it is what finds the message if the id does not resolve.",
                    ],
                    "label": [
                        "type": "string",
                        "description": "Label name as the user said it, e.g. \"Receipts\".",
                    ],
                    "create_new": [
                        "type": "boolean",
                        "description": "Only true when the user explicitly wants a new label despite similar existing names.",
                    ],
                    "also_archive": [
                        "type": "boolean",
                        "description": "Remove it from the inbox at the same time.",
                    ],
                    "account": [
                        "type": "string",
                        "description": "For a reply or action on a search hit, copy its account. For new mail, omit unless the user named a sender: the tool selects the active inbox. Never ask which account. Connected: \(inboxes).",
                    ],
                ],
                "required": ["label"],
            ],
            "strict": false,
        ]
    }

    static func markSpam(_ accounts: LiveSessionSetup.Accounts) -> [String: Any] {
        let inboxes = accounts.inboxes.joined(separator: ", ")
        return [
            "type": "function",
            "name": "mark_spam",
            "description": "Report a message as spam — exactly what Gmail's own Report spam button does: out of the inbox, into Spam, and recorded as spam rather than as mail the user filed. THIS IS WHAT \"that's spam\", \"junk\", \"report it\", \"mark it as spam\" MEAN. Never label_message with a label called Spam — spam is not a label, and one named Spam would leave the message sitting in the inbox. Reversible: Gmail keeps spam for thirty days and \"not spam\" puts it back. Call immediately without speaking first. If the result supplies the next queue item, present it without calling triage_next again. Otherwise follow the active queue instructions. Outside a queue, let the receipt be your first words. This one message only: a standing rule cannot mark spam, because Gmail's filters cannot, so \"always send this sender to spam\" is create_mailbox_filter with skip_inbox and say that is what you did.",
            "parameters": [
                "type": "object",
                "properties": [
                    "message_id": [
                        "type": "string",
                        "description": "The message, from a search hit or the queue step. Omit only if you genuinely have none: in a queue the message they are standing on is used, and `search` finds it anywhere else.",
                    ],
                    "search": [
                        "type": "string",
                        "description": "A Gmail query matching this message and nothing else, e.g. 'from:stripe subject:\"Your receipt\"'. Pass it with message_id; it is what finds the message if the id does not resolve.",
                    ],
                    "account": [
                        "type": "string",
                        "description": "For a reply or action on a search hit, copy its account. For new mail, omit unless the user named a sender: the tool selects the active inbox. Never ask which account. Connected: \(inboxes).",
                    ],
                ],
            ],
            "strict": false,
        ]
    }

    static func trashMessage(_ accounts: LiveSessionSetup.Accounts) -> [String: Any] {
        let inboxes = accounts.inboxes.joined(separator: ", ")
        return [
            "type": "function",
            "name": "trash_message",
            "description": "Move one message to Gmail Trash. THIS IS WHAT \"delete it\", \"delete that\", \"trash it\", \"move it to Trash\" and \"put it in the trash\" MEAN. Never call archive_message for those words: deleting and archiving are different actions, and the receipt must say \"Deleted\", never \"Archived\". Gmail keeps the message in Trash for thirty days, so it is recoverable until Gmail empties it. IN A QUEUE THIS IS A STEP and advances exactly as archive_message describes. PAST TENSE, FIRST WORD: \"Deleted.\" Outside a queue, say nothing before calling and let the receipt be your first words. Pass message_id from a search hit or from the queue step.",
            "parameters": [
                "type": "object",
                "properties": [
                    "message_id": [
                        "type": "string",
                        "description": "The message, from a search hit or the queue step. Omit only if you genuinely have none: in a queue the message they are standing on is used, and `search` finds it anywhere else.",
                    ],
                    "search": [
                        "type": "string",
                        "description": "A Gmail query matching this message and nothing else, e.g. 'from:stripe subject:\"Your receipt\"'. Pass it with message_id; it is what finds the message if the id does not resolve.",
                    ],
                    "account": [
                        "type": "string",
                        "description": "For a reply or action on a search hit, copy its account. For new mail, omit unless the user named a sender: the tool selects the active inbox. Never ask which account. Connected: \(inboxes).",
                    ],
                ],
            ],
            "strict": false,
        ]
    }
}
