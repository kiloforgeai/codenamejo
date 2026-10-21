import Foundation

/// The Live session's function schemas, written once, here. `LiveSessionSetup.tools` pairs each with
/// what a call to it runs, and `LiveSessionSetup.Catalog` serves them to the session and the worker.
/// Account-scoped wording takes the session's `Accounts`; everything else is a constant.
///
/// Write a description for a voice turn, short and in our own words, not a vendor's verbatim schema.
enum LiveToolSchemas {
    /// The connectors' tools, run by `FullDuplexBroker.runTool` (Slack's on the phone's queue when it is up).
    static let notion: [[String: Any]] = [
        notionSearch, notionFetch, notionListRecentPages, notionQueryDataSources,
        notionCreatePages, notionUpdatePage,
    ]
    static let slack: [[String: Any]] = [
        slackTriageNext, slackReadChannel, slackReadThread, slackSearchPublicAndPrivate,
        slackSearchChannels, slackSearchUsers, slackReadUserProfile, slackListChannelMembers,
        slackSendMessage, slackAddReaction, slackScheduleMessage, slackMarkRead,
        slackMarkUnread,
    ]
    static let granola: [[String: Any]] = [
        granolaListMeetings, granolaGetMeeting, granolaActionItems,
    ]
    static let github: [[String: Any]] = [
        githubGetMe, githubSearchRepositories, githubListPullRequests, githubPullRequestRead,
        githubSearchPullRequests, githubListIssues, githubIssueRead, githubSearchIssues,
        githubListCommits, githubGetCommit, githubGetFileContents, githubSearchCode,
        githubActionsList, githubActionsGet, githubGetJobLogs, githubListNotifications,
        githubGetNotificationDetails, githubListLabel, githubMergePullRequest, githubIssueWrite,
        githubAddIssueComment, githubUpdatePullRequest, githubActionsRunTrigger,
    ]

    static let dispatch: [String: Any] = [
        "type": "function",
        "name": "dispatch",
        "description": "Hand one self-contained job to a second agent that has the same mail, calendar and connector tools you do — reads and writes both — and can spend several minutes on it. This tool answers you immediately with the single word 'started' and nothing else: it never returns the job's result, so there is no answer to wait for and nothing to report yet. The real answer arrives later as a note in this conversation, and you speak it then. The second agent works with nobody listening to it — it can do anything routine, it can never hear the user agree to anything, and it cannot ask you a question, so it does the routine work and comes back saying what it needs for anything that takes a spoken yes. Use it for a job that is many steps: reading a long history, working through a dozen messages, research across several searches. A single call you could make right now is not one. The task is all it gets — no transcript, no history, no way to ask what you meant — so write it as a complete instruction. It has find_person and every search you have, so it can resolve a name itself and you should not spend a turn doing that first — pass an address, id or channel when you already have one, and spell out anything only this conversation could tell it. If a mail queue is running, handing a job over does not end it, and this tool's own result says where the queue now stands — follow it exactly. In a mail queue only scope current_email counts as dealing with the current email. Use independent for unrelated questions such as weather, even while an email is open; it leaves the queue unchanged and its answer is an aside, never an email research return. For current_email, the result carries the NEXT message, so say the job is going in a clause and read that message out, ending on what they want to do with it. If the result instead hands back the message they are still standing on, go straight back to it in the same turn by name, without asking its question again. Either way, do not ask whether they want to keep going, and do not call triage_next — the result has already told you where they are.",
        "parameters": [
            "type": "object",
            "properties": [
                "task": [
                    "type": "string",
                    "description": "The complete instruction, standing on its own. \"Find the contract Dana sent last month and say when it renews\" — never \"catch me up on that\" or \"check the rest\". **\"These\", \"this one\", \"the rest of these\" mean the thing in front of the user, and you are the only one who can see it — so resolve them into the task and never widen them.** In a mail queue that is the message you just read out: \"archive all of these\" on a Tech Brew newsletter is \"Archive every email from news@technologybrew.com\", naming the sender. It is NOT \"archive all unread mail\", NOT \"clear the inbox\", and NOT anything about the mailbox as a whole. Widening a demonstrative is the one mistake here that cannot be taken back: the second agent has no way to know what the user was looking at, believes the task it is handed, and acts on all of it. If you genuinely cannot tell what they meant, ask them — that costs one turn, and guessing costs their inbox. And never describe the target by its place in the queue — no \"the sender currently in front of the queue\": the queue moves on the moment you hand the job over, so that phrase points at the wrong mail by the time the job runs. The name or address is the whole reference.",
                ],
                "account": [
                    "type": "string",
                    "description": "Which connected account the job acts from, when it writes and more than one is connected. The second agent cannot ask which, so a job that sends mail or puts something on a calendar without this comes back unfinished. Leave it out for a reply or anything worked out from a thread, and for a job that only reads.",
                ],
                "facts": [
                    "type": "array",
                    "items": [
                        "type": "string",
                    ],
                    "description": "Anything the second agent could not work out on its own, one per entry: \"Sarah Chen = sarah.chen@halden.example\", \"#eng = C012ABC\", \"the standup = the 9am Monday event\". It uses these exactly as written and does not look them up again. Only pass what you already have — leave a name out and it resolves that name itself, which is usually right and is always faster than you stopping to do it.",
                ],
                "scope": [
                    "type": "string",
                    "enum": ["independent", "current_email"],
                    "description": "Relationship to the email being reviewed, separate from expects. current_email only when the user asks for work on or information about that email, its sender, links or attachments. independent for unrelated requests, including weather or work on a different email. An open email alone does not imply a relationship. If uncertain, use independent; do not advance or attach the current email.",
                ],
                "announce": [
                    "type": "string",
                    "description": "The one sentence the user hears as this starts, in your voice: what you are starting, then what comes back — \"I'm looking into your Notion culture page; I'll come back with a summary.\" For a receipt job, stop after what you are starting. Name the subject; never \"one sec\" or \"checking\".",
                ],
                "requested_background": [
                    "type": "boolean",
                    "description": "True when the user explicitly said to do this in the background or dispatch it. Set true even for a single mail or calendar lookup.",
                ],
                "expects": [
                    "type": "string",
                    "enum": ["answer", "receipt"],
                    "description": "What they are owed back. **\"answer\"** when they asked to be told something — summarize this, read this file, what does it say, who is this person, what was decided. The reply is the thing they were waiting for and gets read out in full. **\"receipt\"** when they asked for work done — a sweep, a send, labels — silent on success, reported only on failure or unfinished work. A lookup done only to do the work — slots to offer in a reply — is still \"receipt\". Unsure is \"answer\": an extra sentence they can talk over costs nothing, and a summary compressed to \"that finished\" is lost without them knowing it was there.",
                ],
                "queue_cleanup": [
                    "type": "object",
                    "additionalProperties": false,
                    "description": "For an authorized archive-all or unsubscribe-and-archive request about a known email sender, always supply this pinned scope so the local queue removes matching emails immediately. Omit for research, individual actions, or complex searches. Copy the same exact query into task.",
                    "properties": [
                        "message_id": [
                            "type": "string",
                            "description": "The known email identifying the sender, copied from the queue. Never invent an ID.",
                        ],
                        "query": [
                            "type": "string",
                            "description": "Exact authorized Gmail scope: in:inbox from:ADDRESS, optionally category:promotions or category:purchases if the user approved that category. Use the full sender address, including Apple relay addresses. No negation, OR, dates, or extra predicates.",
                        ],
                    ],
                    "required": ["message_id", "query"],
                ],
            ],
            "required": ["task", "expects", "announce", "scope"],
        ],
        "strict": false,
    ]

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

    static func respondToCalendarEvent(_ accounts: LiveSessionSetup.Accounts) -> [String: Any] {
        let calendars = accounts.calendars.joined(separator: ", ")
        return [
            "type": "function",
            "name": "respond_to_calendar_event",
            "description": "Accept, decline, or tentatively answer an invitation. Use this for 'accept that', 'decline the standup', 'say maybe to Thursday'. Pass the id of an event from search_calendar or list_calendar_events. The organizer is notified, and answering again replaces the answer.",
            "parameters": [
                "type": "object",
                "properties": [
                    "event_id": [
                        "type": "string",
                        "description": "From a search_calendar or list_calendar_events result.",
                    ],
                    "response": [
                        "type": "string",
                        "enum": ["accepted", "declined", "tentative"],
                        "description": "\"accepted\" for yes, \"declined\" for no, \"tentative\" for maybe.",
                    ],
                    "account": [
                        "type": "string",
                        "description": "Omit unless the user named an account: the tool selects the active inbox calendar. Never ask which calendar. Connected: \(calendars).",
                    ],
                ],
                "required": ["event_id", "response"],
            ],
            "strict": false,
        ]
    }

    static func cancelCalendarEvent(_ accounts: LiveSessionSetup.Accounts) -> [String: Any] {
        let calendars = accounts.calendars.joined(separator: ", ")
        return [
            "type": "function",
            "name": "cancel_calendar_event",
            "description": "Cancel an event and take it off the calendar. Use this for 'cancel my 3pm', 'delete Thursday's review'. Pass the id of an event from search_calendar or list_calendar_events. Every guest is emailed a cancellation the moment this is called and there is no way to undo it.",
            "parameters": [
                "type": "object",
                "properties": [
                    "event_id": [
                        "type": "string",
                        "description": "From a search_calendar or list_calendar_events result.",
                    ],
                    "account": [
                        "type": "string",
                        "description": "Omit unless the user named an account: the tool selects the active inbox calendar. Never ask which calendar. Connected: \(calendars).",
                    ],
                ],
                "required": ["event_id"],
            ],
            "strict": false,
        ]
    }

    static let findPerson: [String: Any] = [
        "type": "function",
        "name": "find_person",
        "description": "Turn a name into an email address, from who the user actually corresponds with. Call this before composing mail to someone the user named rather than spelled out. Returns every candidate, most corresponded-with first, each with how many messages they share and the date they last did. Take the clear leader; if the top two are close, ask the user which, by address. An empty answer is not proof they are unknown — read what it says and follow it.",
        "parameters": [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": "The person as the user said them, e.g. \"Sarah\" or \"Sarah Chen\".",
                ],
            ],
            "required": ["name"],
        ],
        "strict": false,
    ]

    static func createDraft(_ accounts: LiveSessionSetup.Accounts) -> [String: Any] {
        let inboxes = accounts.inboxes.joined(separator: ", ")
        return [
            "type": "function",
            "name": "create_draft",
            "description": "Save outgoing mail when the user explicitly asks for a draft. For ordinary write, reply or send requests, use send_email when available: it checks the current inbox mode even if an earlier turn said drafts. An email in context is not enough. For calendar time use create_calendar_event. Never sends. Pass thread_id for a reply.",
            "parameters": [
                "type": "object",
                "properties": [
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
            "description": "Forward a real message to someone: the original goes on verbatim — its formatting and attachments included — under a \"Forwarded message\" block, and the subject becomes Fwd: automatically. In drafts-only mode this saves a complete draft forward without sending. ALWAYS use this tool for forwards, including draft forwards. NEVER rebuild one with create_draft or send_email: retyping a message loses its formatting and attachments, and what arrives is your copy of it, not the mail itself. Forwarding is routine like sending. `to` is an email address, never a person's name. The one exception: a `to` this account has never mailed before comes back NOT SENT with what to ask, same as send_email.",
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

    static let triageNext: [String: Any] = [
        "type": "function",
        "name": "triage_next",
        "description": "Walk the user through one mailbox at a time, one message at a time, newest first, until they reach the end of it or stop you. Answers instantly, from the mail already on their phone. Starting with no scope uses their saved pile, with Important continuing straight into the rest of unread. An unconfigured queue does that same Important-then-unread walk; it never returns a scope question. **After you act on a message, follow that tool's result.** If it explicitly says the queue already moved and carries its next message, checkpoint or close, do not call this. Otherwise call this again in the SAME turn to move on, so the user never has to ask for the next one. It returns the current message but no mailbox count; only answer how many are unread when the user explicitly asks. This is what \"next\", \"skip\", \"move on\" and \"nothing, carry on\" all mean, and it is how you start when the user asks what is in their inbox. Use direction \"back\" when they want the one before. Use restart when they want to check for mail that has arrived since. **Use stop the moment they end it** — \"stop\", \"that's enough\", \"I'm done\" — because saying you have stopped is not what stops it. With no account, it starts the primary mailbox or continues the active one. If the user asks to switch inboxes, call this with the exact account; their current place is checkpointed and resumes when they switch back. If the result offers another mailbox, an immediate yes means call this once with that offered account, while a no means stop true. Never carry that yes past an intervening question, topic change, interruption, skip, or completed action. **Never tell the user where an answer came from.** Not the phone, not a cache, not \"locally\": they asked about their mail, so talk about their mail.",
        "parameters": [
            "type": "object",
            "properties": [
                "direction": [
                    "type": "string",
                    "enum": ["forward", "back"],
                    "description": "Default forward. \"back\" returns the previous message.",
                ],
                "restart": [
                    "type": "boolean",
                    "description": "Rebuild from live mail, discarding the current position. For \"check again\", \"anything since?\", \"start over\".",
                ],
                "stop": [
                    "type": "boolean",
                    "description": "End the queue and close it for good. Moves nothing and marks nothing — it takes the queue away and tells you how much they had left so you can say it on the way out.",
                ],
                "account": [
                    "type": "string",
                    "description": "Exact connected mailbox to activate. Omit to continue the active mailbox. Use when the user names an inbox or immediately accepts the mailbox offered by the preceding triage_next result.",
                ],
                "scope": [
                    "type": "string",
                    "enum": ["unread", "all", "important"],
                    "description": "Which mail to walk: \"important\" for their past week, most important first — \"what needs me\", \"anything urgent\", \"just the important ones\" — \"unread\" for all of their unread, \"all\" for everything in the inbox, read and unread. Send this when the user explicitly names a different pile; asking what is urgent mid-queue names \"important\". Otherwise leave it out: the queue uses their saved pile or its automatic inbox walk. Important continues into the rest of unread. Leave it out on every later call and the queue stays in the scope it started in; sending a different one rebuilds it and loses their place.",
                ],
            ],
        ],
        "strict": false,
    ]

    static let currentTime: [String: Any] = [
        "type": "function",
        "name": "current_time",
        "description": "What time it is for this user right now, with their timezone and the Unix timestamp. Call it before working out a `post_at`, resolving \"in an hour\", or saying the time out loud. For a calendar date such as \"tomorrow\" or \"next week\", the latest Clock line in the conversation context is enough; without one, call this first. Never guess the time. One call is good for the rest of the turn.",
        "parameters": [
            "type": "object",
            "properties": [String: Any](),
            "required": [String](),
        ],
        "strict": false,
    ]

    static let setRule: [String: Any] = [
        "type": "function",
        "name": "set_rule",
        "description": "Switch one of the user's three automatic filing rules on or off, or read them back. THIS IS WHAT \"archive it after I reply\", \"stop archiving when I forward\", \"turn that rule on\" and \"what rules do I have\" MEAN. The three are fixed and there are no others: archive_after_reply (Archive after replying), archive_after_forward (Archive after forwarding), archive_after_label (Archive after filing). There is nothing to create and nothing to delete, so a request for a rule that is not one of these is a request for something else — usually create_mailbox_filter, which is about the mailbox (what gets labelled, what skips the inbox) rather than about what happens after the user acts. Say the rule and its new state back in the same turn: they cannot see a switch they just flipped by voice.",
        "parameters": [
            "type": "object",
            "properties": [
                "rule": [
                    "type": "string",
                    "enum": ["archive_after_reply", "archive_after_forward", "archive_after_label"],
                    "description": "Which rule. Omit to read all three back, which is what \"what rules do I have\" asks for.",
                ],
                "enabled": [
                    "type": "boolean",
                    "description": "True to switch it on, false to switch it off. **Pass it whenever they said on or off** — omitting it only reports the current state, which is not what \"turn that on\" asked for.",
                ],
            ],
        ],
        "strict": false,
    ]

    static let commands: [String: Any] = [
        "type": "function",
        "name": "commands",
        "description": "The user's own commands: a keyword they say, and the tool calls it runs. Answered on the device, instantly. `run` when they say a keyword — it returns that command's steps, which you then carry out in order. `list` when they ask what commands they have — it returns names to read back, and no steps, because they asked what they have rather than how it works. `save` to create one or change what a keyword does, `delete` to remove one, `enable` and `disable` to switch one without losing it.",
        "parameters": [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["run", "list", "save", "delete", "enable", "disable"],
                    "description": "What to do. `list` takes nothing else.",
                ],
                "keyword": [
                    "type": "string",
                    "description": "**What the user says to run it** — one word or a short phrase, up to 4 words: \"research\", \"standup\", \"candidate screen\". Their words, not a description of the command: if they describe it in a sentence, pick the word or two that name it and check that with them. Required for everything but `list`.",
                ],
                "label": [
                    "type": "string",
                    "description": "A short name for the app screen — three or four words, like \"Research a company\" or \"Morning standup\". **A name, not an instruction**: it is what you read back on `list`, and writing it as \"send an email to…\" makes a sentence you will later mistake for work. For `save`.",
                ],
                "actions": [
                    "type": "array",
                    "description": "The steps, in the order they should run. **This is the whole command.** Turn what the user described into calls to the tools you already have: \"look them up and check what they've sent me\" is a web_search then a gmail_search_messages, then a summarize step saying what to tell them. **One step per tool call, and each step describes only its own call.** Never restate the command inside a step, and never have one step mention what another does — a step reading \"send the email and then say it was sent\" is two orders and does the work twice. **Only the steps they asked for**, never one added because it might help and never a conditional one: every step runs every time, on mail you have not read yet. For `save`.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "tool": [
                                "type": "string",
                                "enum": ["{{commandTools}}"],
                                "description": "**Which tool to call** — this half of the step is the instruction, and it is a tool name and nothing else. Use summarize for the final step, where you say what you found.",
                            ],
                            "detail": [
                                "type": "string",
                                "description": "**The action inside that one call** — what to pass it, in words: \"the company\", \"from them, last month\", \"three sentences\". Not JSON: the arguments are worked out when the command runs, against whatever the user is talking about then. It argues its own tool and says nothing about the command as a whole or about any other step. \"Send an email to sarah@acme.com saying hi\" belongs on a send_email step as \"to sarah@acme.com, body: hi\" — the verb is already the tool.",
                            ],
                        ],
                        "required": ["tool"],
                    ],
                ],
            ],
            "required": ["action"],
        ],
        "strict": false,
    ]

    static let summarize: [String: Any] = [
        "type": "function",
        "name": "summarize",
        "description": "Say what you found, at the end of a command. Pass the spoken answer as `text` — the sentence or two you are about to say — and then say it. This is the last step of most commands: the steps before it fetch things, and this is where you tell the user what they add up to. Answered on the device, instantly. Use it only inside a command; in ordinary conversation just answer.",
        "parameters": [
            "type": "object",
            "properties": [
                "text": [
                    "type": "string",
                    "description": "What you are about to say, in the same words you will speak. Not a description of what you found — the finding itself.",
                ],
            ],
            "required": ["text"],
        ],
        "strict": false,
    ]

    static let dispatchCommand: [String: Any] = [
        "type": "function",
        "name": "dispatch_command",
        "description": "Run one of the user's saved commands as a background job. Use this only when the user explicitly asks to dispatch a command. Pass the exact keyword from the enum; do not open it, paraphrase it, copy its steps into `task`, or run any step in this conversation. The phone resolves the stored ordered steps and decides whether their result is an answer or a receipt. If the requested keyword is not in the enum, say that command could not be dispatched and do not guess another command.",
        "parameters": [
            "type": "object",
            "properties": [
                "command": [
                    "type": "string",
                    "enum": ["{{commandKeywords}}"],
                    "description": "The exact saved-command keyword to dispatch.",
                ],
                "account": [
                    "type": "string",
                    "description": "Which connected account the command acts from when it writes and more than one is connected. Leave it out for read-only work or when the command resolves the account from its source context.",
                ],
                "task": [
                    "type": "string",
                    "description": "What the user asked for, in their words, including whatever they named for the command to work on — \"research Apple\", not just \"research\". The stored steps refer to it, and the worker hears nothing else from this conversation.",
                ],
                "facts": [
                    "type": "array",
                    "items": [
                        "type": "string",
                    ],
                    "description": "Facts from this conversation the command needs and cannot recover on its own. ALWAYS include the message_id and account of any email the user is looking at or just heard — the command's steps say \"the email you are looking at\" and the worker cannot see it. Pass only known facts; never invent missing context.",
                ],
            ],
            "required": ["command"],
        ],
        "strict": false,
    ]

    static let feedItems: [String: Any] = [
        "type": "function",
        "name": "feed_items",
        "description": "Add, list or remove something the user wants to hear every morning at the start of their Feed. THIS IS WHAT \"add Nvidia and Cisco stock to my feed\", \"give me the weather every morning\", \"what's in my feed\" and \"stop telling me the weather\" MEAN. It is looked up each morning and spoken when they first call, so it suits anything that changes daily: prices, forecasts, scores, news. Adding does not look it up now; confirm in a few words and move on. **One subject per item**: \"Nvidia and Cisco\" is two items in one call. Each `query` must stand on its own tomorrow morning — \"today's weather forecast in San Francisco\", \"latest closing price of NVIDIA stock\" — never \"the weather\". **You do not know where the user is**, so if a place matters and they did not name one, ask which city and add nothing until they say.",
        "parameters": [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["add", "list", "remove"],
                ],
                "items": [
                    "type": "array",
                    "description": "add only: one entry per subject.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "label": [
                                "type": "string",
                                "description": "A short name you will say back, like \"Nvidia\" or \"San Francisco weather\".",
                            ],
                            "query": [
                                "type": "string",
                                "description": "The self-contained search to run each morning.",
                            ],
                        ],
                        "required": ["label", "query"],
                    ],
                ],
                "label": [
                    "type": "string",
                    "description": "remove only: any word from the item, like \"weather\". It matches by word, so never list first to find the exact name.",
                ],
            ],
            "required": ["action"],
        ],
        "strict": false,
    ]

    static let coachCapability: [String: Any] = [
        "type": "function",
        "name": "coach_capability",
        "description": "Record the user's answer to a quick tip the queue already delivered. Never use it to find, research, or generate a lesson, and never call it before a tip has been spoken. Call `dismiss` with a capability only when the user says they do not want that lesson suggested again. Never demonstrate or run a capability from this tool. Record answers to a delivered tip with action feedback, capability, answer yes/no/other and user_words quoting the user without paraphrasing. Include checkpoint_id when available. For a dismissal include these fields on action dismiss instead. Feedback never enables a rule or dismisses a lesson; never record silence as an answer.",
        "parameters": [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["dismiss", "feedback"],
                ],
                "capability": [
                    "type": "string",
                    "description": "The exact capability id from the queue coaching object's lesson. Never invent one.",
                ],
                "answer": [
                    "type": "string",
                    "enum": ["yes", "no", "other"],
                    "description": "Required for feedback. Include for dismiss when answering a tip.",
                ],
                "user_words": [
                    "type": "string",
                    "maxLength": 4000,
                    "description": "The user's actual spoken reply, not a summary. Required for feedback; include for dismiss.",
                ],
                "checkpoint_id": [
                    "type": "string",
                    "description": "The exact coaching id from the queue result, when available.",
                ],
            ],
            "required": ["action"],
            "additionalProperties": false,
        ],
        "strict": false,
    ]

    static let listProfiles: [String: Any] = [
        "type": "function",
        "name": "list_profiles",
        "description": "List the user’s named profiles, plus the active profile’s inboxes and whether each one has Drafts only on. Never reads another profile’s mail or history.",
        "parameters": [
            "type": "object",
            "properties": [String: Any](),
            "required": [String](),
        ],
        "strict": false,
    ]

    static let switchProfile: [String: Any] = [
        "type": "function",
        "name": "switch_profile",
        "description": "Switch to a named profile when the user asks. Re-scopes mail, calendar and tools to that profile and continues this conversation with its email feed. Resolve the name first; unknown names leave the current profile active.",
        "parameters": [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                ],
            ],
            "required": ["name"],
        ],
        "strict": false,
    ]

    static let createProfile: [String: Any] = [
        "type": "function",
        "name": "create_profile",
        "description": "Create a new, empty profile with the name the user said. It gets no mailbox and does not become active — this call keeps its own profile and feed. Its feed is empty until a mailbox is connected to it, which only happens in the app — so offer to switch them into it rather than describing steps.",
        "parameters": [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                ],
            ],
            "required": ["name"],
        ],
        "strict": false,
    ]

    static let renameProfile: [String: Any] = [
        "type": "function",
        "name": "rename_profile",
        "description": "Rename a profile. `name` is the new name; `profile` names the one to rename and defaults to the active profile. Nothing else changes — same mailboxes, same feed. An unknown `profile` renames nothing.",
        "parameters": [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                ],
                "profile": [
                    "type": "string",
                ],
            ],
            "required": ["name"],
        ],
        "strict": false,
    ]

    static let searchContext: [String: Any] = [
        "type": "function",
        "name": "search_context",
        "description": "Search what you have already looked up for this user — mail and calendar results — and what the two of you said to each other. This is your memory: you cannot see back far in the conversation, and this is how you reach what you read. Answered on the device, in single-digit milliseconds, so it costs the user nothing they can hear and there is never a reason not to try it first. It searches this call unless you widen it — see `scope`. **Anything about an earlier conversation today is this tool**, including a question about mail you discussed then: \"what did we go through this morning\", \"what was that email you read me\", \"what did we talk about earlier\". A mail, calendar or queue tool cannot answer those — they see the mailbox as it is now and have never seen the conversation. Do not start a queue to answer a question about a queue you already walked. A call before today is out of reach: say so rather than searching. It only knows what has actually been read, so an empty answer is ordinary and means nothing went wrong — go and fetch it, and do not tell the user anything failed. What comes back is an excerpt of what was read at the time, with its age: if the age matters for what they asked, or the excerpt stops short of the part you need, read the real thing again.",
        "parameters": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "What to look for, in the user's own words — \"the invoice from Stripe\", \"Sarah's deck\", \"the deploy that failed\". Words, not operators: this searches the text of what was read, so a name, a subject or a phrase works and a query syntax does not.",
                ],
                "scope": [
                    "type": "string",
                    "enum": ["call", "today"],
                    "description": "How far back to look. \"call\" is this call; \"today\" is the whole day and is as far as memory goes — use it for \"this morning\" or \"earlier today\". Nothing reaches yesterday: if they ask about a call before today, say memory covers today only rather than searching and reporting an empty result as if none happened. Widening reaches what was said, including what was said about an email, and notes you saved. It does not reach the mail or calendar data itself from an earlier call, which goes stale, so fetch anything that has to be current.",
                ],
            ],
            "required": ["query", "scope"],
        ],
        "strict": false,
    ]

    static let listCalls: [String: Any] = [
        "type": "function",
        "name": "list_calls",
        "description": "List today's calls with this user — when each started and ended and how many exchanges it held. Answered on the device instantly. Call it for \"how many calls have we had today\", \"what have we talked about today\", or before reading one back, and say the numbers plainly. To read one of them, call search_context with just that call's start time as the query.",
        "parameters": [
            "type": "object",
            "properties": [String: Any](),
            "required": [String](),
        ],
        "strict": false,
    ]

    static let saveContext: [String: Any] = [
        "type": "function",
        "name": "save_context",
        "description": "Cache a lookup you just did, so asking for the same thing again is instant. Call this right after any search or list: pass what was asked for as `request` and the actual data you got back as `result` — the list itself, the senders and subjects, the names, the numbers. Not a summary of it. Reads through our own tools are already cached for you automatically, so this is for what no tool produced.",
        "parameters": [
            "type": "object",
            "properties": [
                "request": [
                    "type": "string",
                    "description": "What was looked up, in plain words — 'unread mail from today', 'open PRs on the broker repo', 'Sarah's email address'. This is what a later question is matched against, so phrase it the way it would be asked.",
                ],
                "result": [
                    "type": "string",
                    "description": "The data itself, as you would read it out. A list stays a list — keep the senders, subjects, titles, dates and ids. This is what comes back on a hit, so anything you leave out is something you will have to look up again.",
                ],
                "summary": [
                    "type": "string",
                    "description": "Optional one-line gloss, for when a hit only needs a sentence.",
                ],
                "kind": [
                    "type": "string",
                    "enum": ["message", "event", "code", "person", "note"],
                    "description": "What sort of data this is. A label only — nothing you save expires, so judge a hit by the age it comes back with.",
                ],
            ],
            "required": ["request", "result"],
        ],
        "strict": false,
    ]

    static let forgetContext: [String: Any] = [
        "type": "function",
        "name": "forget_context",
        "description": "Delete a remembered fact by key, when the user corrects it or it stops being true.",
        "parameters": [
            "type": "object",
            "properties": [
                "key": [
                    "type": "string",
                    "description": "The key, such as 'm_7'.",
                ],
            ],
            "required": ["key"],
        ],
        "strict": false,
    ]

    static let endSession: [String: Any] = [
        "type": "function",
        "name": "end_session",
        "description": "Hang up. Call this when the user says they are finished with the call — \"end session\", \"hang up\", \"I'm done\", \"that's all for now\", \"goodbye\", or any other way of saying it. **The call does not end until you call this.** Saying that you are ending it does nothing on its own, and a user told the session is closed while the microphone is still live has been misled — so never say the call is over unless this returned. Do not call it because a task finished, because there is a pause, or because the user said thanks. Only when they have said they want the call to end. Accepting or declining a calendar invitation is a task decision, never a request to end the call. An affirmative answer to Jo's exact Feed question \"Would you like me to wrap up?\" is an explicit request to end the call, so call this immediately; a negative answer keeps the call open. If \"I'm done\" might have meant the thing you were just working on rather than the call, ask which — a wrong hang-up cannot be undone and they have to dial again. After it returns, say one short goodbye and stop; the phone hangs up when you finish speaking.",
        "parameters": [
            "type": "object",
            "properties": [
                "said": [
                    "type": "string",
                    "description": "What the user said that you took as asking to end the call, in their own words. Recorded so a hang-up nobody wanted can be traced to what triggered it.",
                ],
            ],
            "required": ["said"],
        ],
        "strict": false,
    ]

    static let stopListening: [String: Any] = [
        "type": "function",
        "name": "stop_listening",
        "description": "Mute the user's microphone. Call this when they ask you to stop listening — \"stop listening\", \"mute\", \"stop listening to me\", \"go quiet\", or any other way of saying it. It does **not** end the call; never call end_session for this. After it returns, say nothing — no acknowledgement, no goodbye. Stay silent until they unmute and speak again.",
        "parameters": [
            "type": "object",
            "properties": [String: Any](),
        ],
        "strict": false,
    ]

    static let sendText: [String: Any] = [
        "type": "function",
        "name": "send_text",
        "description": "Send an SMS or iMessage text message from the user's own phone, through their Messages app. Only for an explicit request to compose or send a text, SMS or iMessage. For plain 'message Sarah', ask which service unless already established; never infer Messages rather than email. Never use this for a read request such as 'what did Sarah text me'. Contact-specific text reads are unavailable; read_texts only supports everyone's unread texts. For a named recipient, use find_contact if available and clarify multiple contacts or numbers. Without Contacts access, or if no number is found, ask for a phone number. Use a dictated number directly; never invent one. If the body is missing, ask for it. Read back the exact body and recipient number, then wait for an explicit yes on a later turn before calling. If either changes, read back and confirm again. Pass that number and the exact confirmed words. A pending receipt is not completion: wait for the final result without retrying. Report handoff to Messages, never delivery. Say it was not sent only when the result confirms that. If sending is unconfirmed, say you could not confirm whether Messages sent it and ask the user to check Messages before retrying; never resend automatically.",
        "parameters": [
            "type": "object",
            "properties": [
                "recipient": [
                    "type": "string",
                    "description": "Who to text: the phone number `find_contact` returned, or a number the user dictated. Never guess or invent a number.",
                ],
                "body": [
                    "type": "string",
                    "description": "The text of the message, in the user's words, exactly as read back and confirmed.",
                ],
                "confirmed": [
                    "type": "boolean",
                    "description": "True only after the user heard the exact message and recipient read back and said yes on a later turn. Never set this from the initial send request.",
                ],
            ],
            "required": ["recipient", "body", "confirmed"],
        ],
        "strict": false,
    ]

    static let readTexts: [String: Any] = [
        "type": "function",
        "name": "read_texts",
        "description": "Read everyone's unread SMS and iMessage texts from the past 24 hours. Only use this for requests for all new or unread texts. Contact-specific reads, latest-message reads, already-read texts and older texts are unavailable. If the user asks what a named person texted them, or asks for latest or older texts, explain that limitation; do not call this tool or silently broaden their request to everyone's unread texts. Do not call find_contact for a read request. Mail tools cannot read texts. Omit about and unread; the phone uses its all-unread shortcut branch. Read the returned sender and body briefly. Call without a spoken preamble, then wait in silence for the result. A pending receipt is not completion: call once and never retry while waiting. Never say there are no unread texts until the final result confirms that. On failure, say the read failed, not that there were no messages.",
        "parameters": [
            "type": "object",
            "properties": [
                "about": [
                    "type": "string",
                    "enum": [""],
                    "description": "Legacy compatibility field; omit or leave empty. Contact-specific reads are unavailable.",
                ],
                "unread": [
                    "type": "boolean",
                    "enum": [
                        true,
                    ],
                    "description": "Legacy compatibility field; omit or set true. Only unread texts from the past 24 hours are supported.",
                ],
            ],
            "required": [String](),
            "additionalProperties": false,
        ],
        "strict": false,
    ]

    static let findContact: [String: Any] = [
        "type": "function",
        "name": "find_contact",
        "description": "Look up a person in the user's phone contacts and get their phone number(s). **Call this before `send_text` whenever the recipient is a name rather than a number.** If exactly one contact and one number come back, use that number as the recipient without asking. If several contacts or several numbers come back, ask the user which one they mean — say the names, and the organisation or number label when that is what tells them apart — and only then send to the number they chose. If the contact exists but has no phone number, say you found them but have no number to text and ask for one. If nothing comes back, ask for the number; never guess one. This is for texting and calling; for email addresses use `find_person`.",
        "parameters": [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": "The name as the user said it, e.g. \"Raghav\" or \"Raghav Kiloforge\".",
                ],
            ],
            "required": ["name"],
        ],
        "strict": false,
    ]

    static let webSearch: [String: Any] = [
        "type": "function",
        "name": "web_search",
        "description": "Search the web and get an answer back. One call does the searching and the reading; you get a short answer with its sources named. Never use this to find, research, or generate a Jo coaching lesson. Never use it to discover or substitute for a connected tool: it cannot read or change the user's Gmail or Calendar. In an interactive-coaching session, set user_requested true only when the user's own words asked for a web lookup.",
        "parameters": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "What to find out, in plain words. Write it so it stands alone — the search has no idea what was said earlier in the conversation.",
                ],
                "user_requested": [
                    "type": "boolean",
                    "description": "True only when the user's own words requested this web lookup. Never set this for a coaching lesson, tool instruction, assistant-chosen research, or as a fallback for a Gmail or Calendar action.",
                ],
            ],
            "required": ["query", "user_requested"],
        ],
        "strict": false,
    ]

    static func findPersonWorker(_ accounts: LiveSessionSetup.Accounts) -> [String: Any] {
        let inboxes = accounts.inboxes.joined(separator: ", ")
        return [
            "type": "function",
            "name": "find_person",
            "description": "Turn a name into an email address, from who the user actually corresponds with. Call this before composing mail to someone the user named rather than spelled out. Returns every candidate found, most corresponded-with first, each with how many messages they share and the date they last did. Take the clear leader; if the top two are close, ask the user which, by address. An empty list means the user has never exchanged mail with them from any connected account.",
            "parameters": [
                "type": "object",
                "properties": [
                    "name": [
                        "type": "string",
                        "description": "The person as the user said them, e.g. \"Sarah\" or \"Sarah Chen\".",
                    ],
                    "account": [
                        "type": "string",
                        "description": "For any read or action on a search hit, copy its account. Otherwise omit unless the user named an account; search spans the active profile, other tools follow the feed. Connected: \(inboxes).",
                    ],
                ],
                "required": ["name"],
            ],
            "strict": false,
        ]
    }

    static let notionSearch: [String: Any] = [
        "type": "function",
        "name": "notion-search",
        "description": "Search the user's whole Notion workspace — pages and databases — by meaning. Use it whenever they name a page, topic or note; it returns titles, ids and URLs. Nothing found means it is not there. Read a result with notion-fetch before answering about its contents.",
        "parameters": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "What they are looking for, in plain words.",
                ],
                "page_size": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 25,
                    "description": "How many results. Defaults to 10.",
                ],
            ],
            "required": ["query"],
        ],
        "strict": false,
    ]

    static let notionFetch: [String: Any] = [
        "type": "function",
        "name": "notion-fetch",
        "description": "Read one Notion page or database by id or URL, from notion-search or notion-list-recent-pages. A page comes back as Markdown; a database comes back with its columns and its data sources (collection://…), not its rows — read those with notion-query-data-sources. This is where the answer lives — titles alone are not it.",
        "parameters": [
            "type": "object",
            "properties": [
                "id": [
                    "type": "string",
                    "description": "The page or database id, its Notion URL, or a collection:// data source URL.",
                ],
            ],
            "required": ["id"],
        ],
        "strict": false,
    ]

    static let notionListRecentPages: [String: Any] = [
        "type": "function",
        "name": "notion-list-recent-pages",
        "description": "The pages the user opened most recently, newest first. The cheapest way to resolve \"that page\", \"what I was just looking at\" or \"my notes from earlier\" without a search.",
        "parameters": [
            "type": "object",
            "properties": [
                "limit": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 50,
                    "description": "How many. Defaults to 10.",
                ],
            ],
            "required": [String](),
        ],
        "strict": false,
    ]

    static let notionQueryDataSources: [String: Any] = [
        "type": "function",
        "name": "notion-query-data-sources",
        "description": "Read a database's rows: the latest entries, everything with a given Status, a count. notion-fetch the database first — it lists each data source as collection://… with its columns. Then give data_source_url and a read-only SQLite query that uses that URL, quoted, as the table name (SELECT * FROM \"collection://…\" ORDER BY … LIMIT 10; wrap timestamps in datetime()). Or give view_url, a database view's URL, to get that view's rows with its own filters and sorts — a view never hits the SQL usage limit some plans have.",
        "parameters": [
            "type": "object",
            "properties": [
                "data_source_url": [
                    "type": "string",
                    "description": "The collection://… URL from notion-fetch.",
                ],
                "query": [
                    "type": "string",
                    "description": "Read-only SQLite against data_source_url.",
                ],
                "view_url": [
                    "type": "string",
                    "description": "A database view's URL, instead of a query.",
                ],
                "page_size": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100,
                    "description": "Rows per page, for view_url. Defaults to 100.",
                ],
            ],
            "required": [String](),
        ],
        "strict": false,
    ]

    static let notionCreatePages: [String: Any] = [
        "type": "function",
        "name": "notion-create-pages",
        "description": "Create one Notion page. Routine — do it, then say the title back. Give parent_page_id to file it under a page, parent_database_id to add a row to a database, or neither for a top-level private page. Before creating, search: add to a page that already exists rather than making a second with the same name.",
        "parameters": [
            "type": "object",
            "properties": [
                "title": [
                    "type": "string",
                    "description": "The page title.",
                ],
                "content": [
                    "type": "string",
                    "description": "The body, as Markdown. Optional.",
                ],
                "parent_page_id": [
                    "type": "string",
                    "description": "Id or URL of the page to file it under.",
                ],
                "parent_database_id": [
                    "type": "string",
                    "description": "Id or URL of the database to add it to, or its collection:// data source URL.",
                ],
                "properties": [
                    "type": "object",
                    "description": "Database properties, by name, for a database row — a Status, a Due date, an Owner id. If the database's title column is not called title, put the title under that column's name here instead.",
                ],
            ],
            "required": ["title"],
        ],
        "strict": false,
    ]

    static let notionUpdatePage: [String: Any] = [
        "type": "function",
        "name": "notion-update-page",
        "description": "Change an existing page. command update_properties sets properties by name — the mark-as-done tool: a Status, a checkbox (\"__YES__\" or \"__NO__\"), a date, an assignee. command insert_content appends Markdown to the page (position start to prepend). Routine; say what changed in one clause. Cannot delete a page or rewrite what is on it.",
        "parameters": [
            "type": "object",
            "properties": [
                "page_id": [
                    "type": "string",
                    "description": "The page id or URL.",
                ],
                "command": [
                    "type": "string",
                    "enum": ["update_properties", "insert_content"],
                ],
                "properties": [
                    "type": "object",
                    "description": "For update_properties: property name → new value.",
                ],
                "content": [
                    "type": "string",
                    "description": "For insert_content: the Markdown to add.",
                ],
                "position": [
                    "type": "string",
                    "enum": ["start", "end"],
                    "description": "For insert_content. Defaults to end.",
                ],
            ],
            "required": ["page_id", "command"],
        ],
        "strict": false,
    ]

    static let slackTriageNext: [String: Any] = [
        "type": "function",
        "name": "slack_triage_next",
        "description": "Walk the user through their unread Slack one conversation at a time. Call it with no arguments the first time and it builds the queue — every channel, DM and group DM with something unread in it, across every connected workspace, ranked so the one most likely to need them comes first — and hands back the first one with the messages already in it, so no separate read is needed. Call it again when the user asks for the next one, or skips. Do NOT call it after you reply, react, schedule a message or mark the conversation you are on: that tool's own answer already carries the next one, and calling this as well walks the user past a conversation they never heard. Asking for the next one marks nothing read. The Slack queue is how all of this is spoken.",
        "parameters": [
            "type": "object",
            "properties": [
                "direction": [
                    "type": "string",
                    "enum": ["forward", "back"],
                    "description": "Default forward. \"back\" returns the previous conversation.",
                ],
                "restart": [
                    "type": "boolean",
                    "description": "Rebuild from live Slack, discarding the current position. For \"check again\", \"anything since?\", \"start over\".",
                ],
                "stop": [
                    "type": "boolean",
                    "description": "End the queue and close it for good. For \"stop\", \"that's enough\", \"I'm done\", \"later\". Moves nothing and marks nothing; tells you how many conversations are still waiting.",
                ],
            ],
            "required": [String](),
        ],
        "strict": false,
    ]

    static let slackReadChannel: [String: Any] = [
        "type": "function",
        "name": "slack_read_channel",
        "description": "Recent messages in one channel, DM or group DM, newest first. Each message comes back with the sender's display name, its text, and its `ts` — which is what slack_read_thread, slack_add_reaction and a threaded reply all take. Returns 30 messages by default; ask for up to 100. `more` and `cursor` mean there was more than one page.",
        "parameters": [
            "type": "object",
            "properties": [
                "channel_id": [
                    "type": "string",
                    "description": "The conversation's Slack id — C… for a channel, D… for a DM, or a person's U… id to reach them directly. Never guess one.",
                ],
                "limit": [
                    "type": "integer",
                    "description": "How many messages, 1 to 100. Default 30.",
                ],
                "oldest": [
                    "type": "string",
                    "description": "Only messages after this ts.",
                ],
                "latest": [
                    "type": "string",
                    "description": "Only messages before this ts.",
                ],
                "cursor": [
                    "type": "string",
                    "description": "The `cursor` from a previous page.",
                ],
                "response_format": [
                    "type": "string",
                    "enum": ["detailed", "concise"],
                    "description": "'detailed' (default) includes reactions and attached file names; 'concise' is who said what and when.",
                ],
            ],
            "required": ["channel_id"],
        ],
        "strict": false,
    ]

    static let slackReadThread: [String: Any] = [
        "type": "function",
        "name": "slack_read_thread",
        "description": "One thread — the parent message and its replies, oldest first, because a thread is one story. Takes the parent message's ts, which comes from slack_read_channel or a search result.",
        "parameters": [
            "type": "object",
            "properties": [
                "channel_id": [
                    "type": "string",
                    "description": "The conversation's Slack id — C… for a channel, D… for a DM, or a person's U… id to reach them directly. Never guess one.",
                ],
                "message_ts": [
                    "type": "string",
                    "description": "The parent message's ts, like \"1234567890.123456\".",
                ],
                "limit": [
                    "type": "integer",
                    "description": "How many messages, 1 to 200. Default 60.",
                ],
                "response_format": [
                    "type": "string",
                    "enum": ["detailed", "concise"],
                    "description": "'detailed' (default) or 'concise'.",
                ],
            ],
            "required": ["channel_id", "message_ts"],
        ],
        "strict": false,
    ]

    static let slackSearchPublicAndPrivate: [String: Any] = [
        "type": "function",
        "name": "slack_search_public_and_private",
        "description": "Search messages across every channel, private channel, DM and group DM the user can see. Use this when they ask about a topic, a decision or what someone said — not to find out what is new, which is slack_triage_next. Slack's search modifiers work: in:#channel, from:@name, before:2026-08-01, has:link, \"exact phrase\".",
        "parameters": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "Keywords, optionally with Slack search modifiers.",
                ],
                "limit": [
                    "type": "integer",
                    "description": "How many matches, 1 to 20. Default 12.",
                ],
                "sort": [
                    "type": "string",
                    "enum": ["score", "timestamp"],
                    "description": "'score' (default, most relevant) or 'timestamp' (most recent).",
                ],
                "sort_dir": [
                    "type": "string",
                    "enum": ["asc", "desc"],
                ],
            ],
            "required": ["query"],
        ],
        "strict": false,
    ]

    static let slackSearchChannels: [String: Any] = [
        "type": "function",
        "name": "slack_search_channels",
        "description": "Find a channel by name or subject, and get the channel_id every other tool needs. Matches on name, topic and purpose; exact name matches rank first.",
        "parameters": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "Part of a channel name or subject.",
                ],
                "limit": [
                    "type": "integer",
                    "description": "How many, 1 to 20. Default 10.",
                ],
                "include_archived": [
                    "type": "boolean",
                    "description": "Include archived channels. Default false.",
                ],
            ],
            "required": ["query"],
        ],
        "strict": false,
    ]

    static let slackSearchUsers: [String: Any] = [
        "type": "function",
        "name": "slack_search_users",
        "description": "Find a person by name, email or job title, and get their user_id — which is also what you pass as channel_id to DM them. An email address is looked up exactly. Prefix a term with - to exclude it.",
        "parameters": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "A name, an email address, or a title like \"engineering\".",
                ],
                "limit": [
                    "type": "integer",
                    "description": "How many, 1 to 20. Default 10.",
                ],
            ],
            "required": ["query"],
        ],
        "strict": false,
    ]

    static let slackReadUserProfile: [String: Any] = [
        "type": "function",
        "name": "slack_read_user_profile",
        "description": "One person's details — name, title, email, timezone, status. Defaults to the signed-in user when no id is given, which is how to answer questions about the user's own Slack profile.",
        "parameters": [
            "type": "object",
            "properties": [
                "user_id": [
                    "type": "string",
                    "description": "Their U… id. Omit for the signed-in user.",
                ],
            ],
            "required": [String](),
        ],
        "strict": false,
    ]

    static let slackListChannelMembers: [String: Any] = [
        "type": "function",
        "name": "slack_list_channel_members",
        "description": "Who is in a channel or group DM, up to 30 a page. Does not work on a DM, where the members are the two people in it. Pass response_format ids_only when the names are not needed — it is much faster.",
        "parameters": [
            "type": "object",
            "properties": [
                "channel_id": [
                    "type": "string",
                    "description": "The conversation's Slack id — C… for a channel, D… for a DM, or a person's U… id to reach them directly. Never guess one.",
                ],
                "limit": [
                    "type": "integer",
                    "description": "How many, 1 to 30. Default 30.",
                ],
                "cursor": [
                    "type": "string",
                    "description": "The `cursor` from a previous page.",
                ],
                "response_format": [
                    "type": "string",
                    "enum": ["detailed", "concise", "ids_only"],
                    "description": "Names by default; 'ids_only' skips resolving them.",
                ],
            ],
            "required": ["channel_id"],
        ],
        "strict": false,
    ]

    static let slackSendMessage: [String: Any] = [
        "type": "function",
        "name": "slack_send_message",
        "description": "Post a message to a channel, or DM a person by passing their user_id as channel_id. To reply inside a thread, pass that message's ts as thread_ts — without it the reply goes to the whole channel. The result says which of the two happened. This tool only sends — it cannot read, search or check anything.",
        "parameters": [
            "type": "object",
            "properties": [
                "channel_id": [
                    "type": "string",
                    "description": "The conversation's Slack id — C… for a channel, D… for a DM, or a person's U… id to reach them directly. Never guess one.",
                ],
                "message": [
                    "type": "string",
                    "description": "What to say. Markdown is fine.",
                ],
                "thread_ts": [
                    "type": "string",
                    "description": "The ts of the message being replied to, to keep it in the thread.",
                ],
                "reply_broadcast": [
                    "type": "boolean",
                    "description": "With thread_ts, also post the reply to the whole channel. Rarely wanted.",
                ],
            ],
            "required": ["channel_id", "message"],
        ],
        "strict": false,
    ]

    static let slackAddReaction: [String: Any] = [
        "type": "function",
        "name": "slack_add_reaction",
        "description": "React to a message with an emoji. Takes the message's ts and the emoji name without colons — \"thumbsup\", \"eyes\", \"white_check_mark\". Reacting twice is not an error.",
        "parameters": [
            "type": "object",
            "properties": [
                "channel_id": [
                    "type": "string",
                    "description": "The conversation's Slack id — C… for a channel, D… for a DM, or a person's U… id to reach them directly. Never guess one.",
                ],
                "message_ts": [
                    "type": "string",
                    "description": "The ts of the message.",
                ],
                "emoji": [
                    "type": "string",
                    "description": "Emoji name without colons. Defaults to thumbsup.",
                ],
            ],
            "required": ["channel_id", "message_ts"],
        ],
        "strict": false,
    ]

    static let slackScheduleMessage: [String: Any] = [
        "type": "function",
        "name": "slack_schedule_message",
        "description": "Post a message later. post_at is a Unix timestamp in seconds. Slack refuses under two minutes out or beyond 120 days. It cannot be changed or cancelled once scheduled, though the user can delete it from Drafts and sent in Slack. This tool only schedules — it cannot read or check anything, and it does not post now.",
        "parameters": [
            "type": "object",
            "properties": [
                "channel_id": [
                    "type": "string",
                    "description": "The conversation's Slack id — C… for a channel, D… for a DM, or a person's U… id to reach them directly. Never guess one.",
                ],
                "message": [
                    "type": "string",
                    "description": "What to say.",
                ],
                "post_at": [
                    "type": "integer",
                    "description": "Unix timestamp in seconds when it should go.",
                ],
                "thread_ts": [
                    "type": "string",
                    "description": "The ts of a message to reply to, to schedule it into that thread.",
                ],
                "reply_broadcast": [
                    "type": "boolean",
                    "description": "With thread_ts, also post to the whole channel when it fires.",
                ],
            ],
            "required": ["channel_id", "message", "post_at"],
        ],
        "strict": false,
    ]

    static let slackMarkRead: [String: Any] = [
        "type": "function",
        "name": "slack_mark_read",
        "description": "Mark a conversation read in Slack, so its unread badge goes away. Call it with just the channel_id to clear the whole conversation, which is what the user almost always means; pass message_ts to mark read only up to that message and leave everything after it unread. Do NOT call this after replying, reacting or scheduling in a queued conversation — those already mark it read.",
        "parameters": [
            "type": "object",
            "properties": [
                "channel_id": [
                    "type": "string",
                    "description": "The conversation's Slack id — C… for a channel, D… for a DM, or a person's U… id to reach them directly. Never guess one.",
                ],
                "message_ts": [
                    "type": "string",
                    "description": "Mark read up to and including this message only. Omit to mark the whole conversation read.",
                ],
            ],
            "required": ["channel_id"],
        ],
        "strict": false,
    ]

    static let slackMarkUnread: [String: Any] = [
        "type": "function",
        "name": "slack_mark_unread",
        "description": "Put a conversation back to showing unread in Slack, so it stays in the user's sidebar — including undoing a slack_mark_read. With just the channel_id the newest message shows unread again; pass message_ts to make that message and everything after it unread. It cannot restore an exact earlier position, because Slack does not say where the marker was.",
        "parameters": [
            "type": "object",
            "properties": [
                "channel_id": [
                    "type": "string",
                    "description": "The conversation's Slack id — C… for a channel, D… for a DM, or a person's U… id to reach them directly. Never guess one.",
                ],
                "message_ts": [
                    "type": "string",
                    "description": "Make this message and everything after it unread. Omit for the newest message alone.",
                ],
            ],
            "required": ["channel_id"],
        ],
        "strict": false,
    ]

    static let granolaListMeetings: [String: Any] = [
        "type": "function",
        "name": "granola_list_meetings",
        "description": "List the user's Granola meetings in a time range, with titles and ids. Use it when they ask what meetings they had, or to find the ids to read with granola_get_meeting. Anything about what was actually said or decided needs the notes, so follow this with granola_get_meeting rather than answering from titles.",
        "parameters": [
            "type": "object",
            "properties": [
                "time_range": [
                    "type": "string",
                    "enum": ["this_week", "last_week", "last_30_days", "custom"],
                    "description": "Defaults to last_30_days.",
                ],
                "custom_start": [
                    "type": "string",
                    "description": "ISO date. Required when time_range is custom.",
                ],
                "custom_end": [
                    "type": "string",
                    "description": "ISO date. Required when time_range is custom.",
                ],
                "mine_only": [
                    "type": "boolean",
                    "description": "True for 'my meetings' — ones the user captured or was a listed participant in. Omit to list everything they can see.",
                ],
            ],
            "required": [String](),
        ],
        "strict": false,
    ]

    static let granolaGetMeeting: [String: Any] = [
        "type": "function",
        "name": "granola_get_meeting",
        "description": "Read the notes and AI summary for meetings you already have ids for, from granola_list_meetings. Up to ten at once, so fetch the candidates together rather than one per turn. This is where decisions, follow-ups and action items live — the summary ends with a Next Steps list naming who owns what.",
        "parameters": [
            "type": "object",
            "properties": [
                "meeting_ids": [
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 10,
                    "items": [
                        "type": "string",
                        "minLength": 1,
                    ],
                    "description": "Meeting ids, at most ten. Fetch additional candidates in separate batches.",
                ],
            ],
            "required": ["meeting_ids"],
        ],
        "strict": false,
    ]

    static let granolaActionItems: [String: Any] = [
        "type": "function",
        "name": "granola_action_items",
        "description": "What was committed to across the user's meetings — every action item in a time range, each with who owns it and which meeting it came from. Use it for \"what am I on the hook for\", \"what did I commit to this week\", \"what's outstanding\". Owners are returned as written, so filter by name when they ask only about theirs. For one meeting you already have the id of, granola_get_meeting is cheaper.",
        "parameters": [
            "type": "object",
            "properties": [
                "time_range": [
                    "type": "string",
                    "enum": ["this_week", "last_week", "last_30_days", "custom"],
                    "description": "Defaults to last_30_days.",
                ],
                "custom_start": [
                    "type": "string",
                    "description": "ISO date. Required when time_range is custom.",
                ],
                "custom_end": [
                    "type": "string",
                    "description": "ISO date. Required when time_range is custom.",
                ],
                "mine_only": [
                    "type": "boolean",
                    "description": "True to look only at meetings the user captured or was a participant in. This filters the meetings, not the owners of the items inside them.",
                ],
            ],
            "required": [String](),
        ],
        "strict": false,
    ]

    static let githubGetMe: [String: Any] = [
        "type": "function",
        "name": "github_get_me",
        "description": "The signed-in GitHub user — their login and name. Call this to resolve \"my\" in a question about pull requests, issues or reviews, rather than asking the user what their username is.",
        "parameters": [
            "type": "object",
            "properties": [String: Any](),
        ],
        "strict": false,
    ]

    static let githubSearchRepositories: [String: Any] = [
        "type": "function",
        "name": "github_search_repositories",
        "description": "Find a repository by name or description. This is what turns a repo the user said out loud — \"the voice app\", \"the broker\" — into the owner/repo pair every other GitHub tool needs. Call it first whenever you do not already have that pair; guessing an owner is the most common way a GitHub question fails.",
        "parameters": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "GitHub search syntax. A bare name works; narrow with qualifiers like `user:kiloforgeai` or `org:kiloforgeai` when the user named a place.",
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
            "required": ["query"],
        ],
        "strict": false,
    ]

    static let githubListPullRequests: [String: Any] = [
        "type": "function",
        "name": "github_list_pull_requests",
        "description": "Open pull requests in one repository, newest activity first by default. Each comes back with its number, title, author, draft state, branches and the date it last moved. Use github_search_pull_requests instead when the question spans repos or asks about \"mine\".",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "state": [
                    "type": "string",
                    "enum": ["open", "closed", "all"],
                    "description": "Default open.",
                ],
                "base": [
                    "type": "string",
                    "description": "Only PRs targeting this branch.",
                ],
                "head": [
                    "type": "string",
                    "description": "Only PRs from this branch.",
                ],
                "sort": [
                    "type": "string",
                    "enum": ["created", "updated", "popularity", "long-running"],
                    "description": "Default created.",
                ],
                "direction": [
                    "type": "string",
                    "enum": ["asc", "desc"],
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
            "required": ["owner", "repo"],
        ],
        "strict": false,
    ]

    static let githubPullRequestRead: [String: Any] = [
        "type": "function",
        "name": "github_pull_request_read",
        "description": "Everything about one pull request, by method: `get` for its title, body, author and mergeability; `get_status` for whether its checks pass — use this before saying anything about CI; `get_files` for what changed; `get_diff` for the change itself (capped, so use get_files when you only need the file list); `get_reviews` for who approved or requested changes; `get_comments` for the discussion; `get_review_comments` for line-level notes on the code.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "pull_number": [
                    "type": "integer",
                    "description": "The pull request number, as in #142. Get it from a list or a search.",
                ],
                "method": [
                    "type": "string",
                    "enum": [
                        "get",
                        "get_diff",
                        "get_status",
                        "get_files",
                        "get_reviews",
                        "get_review_comments",
                        "get_comments",
                    ],
                    "description": "Default get.",
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
            "required": ["owner", "repo", "pull_number"],
        ],
        "strict": false,
    ]

    static let githubSearchPullRequests: [String: Any] = [
        "type": "function",
        "name": "github_search_pull_requests",
        "description": "Find pull requests across repositories with GitHub search syntax — this is how \"my open PRs\" and \"what needs my review\" are answered. Useful qualifiers: `author:@me`, `review-requested:@me`, `is:open`, `draft:false`, `repo:owner/name`, `org:name`. `is:pr` is added for you.",
        "parameters": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "GitHub search syntax.",
                ],
                "sort": [
                    "type": "string",
                    "enum": ["created", "updated", "comments"],
                    "description": "Default is best match.",
                ],
                "order": [
                    "type": "string",
                    "enum": ["asc", "desc"],
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
            "required": ["query"],
        ],
        "strict": false,
    ]

    static let githubListIssues: [String: Any] = [
        "type": "function",
        "name": "github_list_issues",
        "description": "Open issues in one repository. Pull requests are filtered out, so a count here is issues only. Narrow by label, assignee or creator when the user did.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "state": [
                    "type": "string",
                    "enum": ["open", "closed", "all"],
                    "description": "Default open.",
                ],
                "labels": [
                    "type": "string",
                    "description": "Comma-separated label names.",
                ],
                "assignee": [
                    "type": "string",
                    "description": "A login, `none`, or `*` for any assignee.",
                ],
                "creator": [
                    "type": "string",
                    "description": "A login.",
                ],
                "since": [
                    "type": "string",
                    "description": "ISO-8601; only issues updated after it.",
                ],
                "sort": [
                    "type": "string",
                    "enum": ["created", "updated", "comments"],
                ],
                "direction": [
                    "type": "string",
                    "enum": ["asc", "desc"],
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
            "required": ["owner", "repo"],
        ],
        "strict": false,
    ]

    static let githubIssueRead: [String: Any] = [
        "type": "function",
        "name": "github_issue_read",
        "description": "One issue, by method: `get` for its body and state, `get_comments` for the discussion, `get_labels` for its labels, `get_sub_issues` for issues tracked underneath it.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "issue_number": [
                    "type": "integer",
                    "description": "The issue number, as in #37. Get it from a list, a search, or a notification.",
                ],
                "method": [
                    "type": "string",
                    "enum": ["get", "get_comments", "get_labels", "get_sub_issues"],
                    "description": "Default get.",
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
            ],
            "required": ["owner", "repo", "issue_number"],
        ],
        "strict": false,
    ]

    static let githubSearchIssues: [String: Any] = [
        "type": "function",
        "name": "github_search_issues",
        "description": "Find issues across repositories with GitHub search syntax. Qualifiers that matter: `assignee:@me`, `author:@me`, `mentions:@me`, `is:open`, `label:bug`, `repo:owner/name`. `is:issue` is added for you, so pull requests will not come back.",
        "parameters": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "GitHub search syntax.",
                ],
                "sort": [
                    "type": "string",
                    "enum": ["created", "updated", "comments"],
                ],
                "order": [
                    "type": "string",
                    "enum": ["asc", "desc"],
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
            "required": ["query"],
        ],
        "strict": false,
    ]

    static let githubListCommits: [String: Any] = [
        "type": "function",
        "name": "github_list_commits",
        "description": "Recent commits on a branch — who changed what, and when. Each comes back with a short sha, its subject line and the author. Narrow to one file with `path` when the user asked what happened to something specific.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "sha": [
                    "type": "string",
                    "description": "Branch, tag or sha to start from.",
                ],
                "path": [
                    "type": "string",
                    "description": "Only commits touching this file or directory.",
                ],
                "author": [
                    "type": "string",
                    "description": "A login or email.",
                ],
                "since": [
                    "type": "string",
                    "description": "ISO-8601.",
                ],
                "until": [
                    "type": "string",
                    "description": "ISO-8601.",
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
            "required": ["owner", "repo"],
        ],
        "strict": false,
    ]

    static let githubGetCommit: [String: Any] = [
        "type": "function",
        "name": "github_get_commit",
        "description": "One commit in full — its whole message, the files it touched and how much of each. The diff itself is not included; there is nothing spoken to do with one.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "sha": [
                    "type": "string",
                    "description": "A sha, branch or tag.",
                ],
            ],
            "required": ["owner", "repo", "sha"],
        ],
        "strict": false,
    ]

    static let githubGetFileContents: [String: Any] = [
        "type": "function",
        "name": "github_get_file_contents",
        "description": "Read a file from a repository, or list a directory — pass a file path for the first, a directory path or nothing for the second. Text only: a binary file is refused rather than read out as noise.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "path": [
                    "type": "string",
                    "description": "Path in the repo. A directory, or empty, lists instead of reads.",
                ],
                "ref": [
                    "type": "string",
                    "description": "Branch, tag or sha. Default branch otherwise.",
                ],
            ],
            "required": ["owner", "repo"],
        ],
        "strict": false,
    ]

    static let githubSearchCode: [String: Any] = [
        "type": "function",
        "name": "github_search_code",
        "description": "Find where something is defined or mentioned in code, across repositories. Returns the file paths that match, which you then read with github_get_file_contents — the matching lines are not included, because a spoken answer is \"it's in three files\" and then the one that matters.",
        "parameters": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "GitHub code search syntax. Narrow it: `repo:owner/name`, `path:lib/`, `language:swift`. An unqualified search across all of GitHub is rarely what the user meant.",
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
            "required": ["query"],
        ],
        "strict": false,
    ]

    static let githubActionsList: [String: Any] = [
        "type": "function",
        "name": "github_actions_list",
        "description": "CI, by method: `workflow_runs` (default) for recent runs and whether they passed — this is what \"did the build pass\" is answered from; `workflows` for the workflows a repo has, which is where a workflow_id for running one comes from; `workflow_jobs` for the jobs inside one run, which is how you find the job that failed.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "method": [
                    "type": "string",
                    "enum": ["workflow_runs", "workflows", "workflow_jobs"],
                    "description": "Default workflow_runs.",
                ],
                "workflow_id": [
                    "type": "string",
                    "description": "For workflow_runs: narrow to one workflow, by file name (build.yml) or id.",
                ],
                "run_id": [
                    "type": "integer",
                    "description": "A workflow run's id, from github_actions_list method workflow_runs.",
                ],
                "branch": [
                    "type": "string",
                    "description": "Only runs on this branch.",
                ],
                "event": [
                    "type": "string",
                    "description": "push, pull_request, workflow_dispatch…",
                ],
                "status": [
                    "type": "string",
                    "description": "queued, in_progress, completed, success, failure, cancelled…",
                ],
                "actor": [
                    "type": "string",
                    "description": "Only runs started by this login.",
                ],
                "filter": [
                    "type": "string",
                    "enum": ["latest", "all"],
                    "description": "For workflow_jobs: `latest` attempt only, or all attempts.",
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
            "required": ["owner", "repo"],
        ],
        "strict": false,
    ]

    static let githubActionsGet: [String: Any] = [
        "type": "function",
        "name": "github_actions_get",
        "description": "One CI run or job, by method: `workflow_run` for a run's status and conclusion, `job` for one job including which of its steps failed, `workflow_run_usage` for how long a run took.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "method": [
                    "type": "string",
                    "enum": ["workflow_run", "job", "workflow_run_usage"],
                    "description": "Default workflow_run.",
                ],
                "run_id": [
                    "type": "integer",
                    "description": "A workflow run's id, from github_actions_list method workflow_runs.",
                ],
                "job_id": [
                    "type": "integer",
                    "description": "A job's id, from github_actions_list workflow_jobs.",
                ],
            ],
            "required": ["owner", "repo"],
        ],
        "strict": false,
    ]

    static let githubGetJobLogs: [String: Any] = [
        "type": "function",
        "name": "github_get_job_logs",
        "description": "Why a build failed. Pass `failed_only` with a `run_id` when the user asked why CI broke and you do not know which job — it finds the failing jobs and tails each one, which is the fast path. Pass a `job_id` for one specific job. Only the end of each log comes back: a build log's beginning is the same setup steps every time and the answer is always at the end.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "failed_only": [
                    "type": "boolean",
                    "description": "With run_id: tail the logs of every job that failed, up to three.",
                ],
                "run_id": [
                    "type": "integer",
                    "description": "A workflow run's id, from github_actions_list method workflow_runs.",
                ],
                "job_id": [
                    "type": "integer",
                    "description": "One job's id.",
                ],
                "tail_lines": [
                    "type": "integer",
                    "description": "How many lines from the end, 10 to 500. Default 120.",
                ],
            ],
            "required": ["owner", "repo"],
        ],
        "strict": false,
    ]

    static let githubListNotifications: [String: Any] = [
        "type": "function",
        "name": "github_list_notifications",
        "description": "The user's GitHub notifications — review requests, mentions, replies — each with the reason it arrived and the number of the pull request or issue it is about. This is what \"what needs my attention on GitHub\" is answered from, and it needs no repo.",
        "parameters": [
            "type": "object",
            "properties": [
                "all": [
                    "type": "boolean",
                    "description": "Include already-read ones. Default unread only.",
                ],
                "participating": [
                    "type": "boolean",
                    "description": "Only threads the user is directly involved in.",
                ],
                "since": [
                    "type": "string",
                    "description": "ISO-8601.",
                ],
                "before": [
                    "type": "string",
                    "description": "ISO-8601.",
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
        ],
        "strict": false,
    ]

    static let githubGetNotificationDetails: [String: Any] = [
        "type": "function",
        "name": "github_get_notification_details",
        "description": "One notification thread, when a list entry was not enough to say what it is about.",
        "parameters": [
            "type": "object",
            "properties": [
                "notification_id": [
                    "type": "string",
                    "description": "The `id` from github_list_notifications.",
                ],
            ],
            "required": ["notification_id"],
        ],
        "strict": false,
    ]

    static let githubListLabel: [String: Any] = [
        "type": "function",
        "name": "github_list_label",
        "description": "The labels a repository actually has, with their descriptions. Read these before labelling anything, and let the user pick from real names — a label that does not exist is silently dropped when an issue is filed.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
            ],
            "required": ["owner", "repo"],
        ],
        "strict": false,
    ]

    static let githubMergePullRequest: [String: Any] = [
        "type": "function",
        "name": "github_merge_pull_request",
        "description": "Merge a pull request. This moves a branch other people are working on and sets off whatever is downstream of it — a deploy, a release — within seconds. Confirm across two turns first: name the pull request, its repo, its author and whether its checks pass, then merge in the next turn only on a clear yes. This tool only changes something on GitHub — it can never read, list, search or check anything. If you are answering a question, use the read tools instead.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "pull_number": [
                    "type": "integer",
                    "description": "The pull request number, as in #142. Get it from a list or a search.",
                ],
                "merge_method": [
                    "type": "string",
                    "enum": ["merge", "squash", "rebase"],
                    "description": "Default is the repository's own default.",
                ],
                "commit_title": [
                    "type": "string",
                ],
                "commit_message": [
                    "type": "string",
                ],
            ],
            "required": ["owner", "repo", "pull_number"],
        ],
        "strict": false,
    ]

    static let githubIssueWrite: [String: Any] = [
        "type": "function",
        "name": "github_issue_write",
        "description": "File a new issue (`method: create`, needs a title) or change an existing one (`method: update`, needs an issue_number) — its title, body, labels, assignees, or open/closed state. Read the title and the repo back to the user before filing: a garbled title in the wrong repo is what this confirms against. Label only with names from github_list_label. This tool only changes something on GitHub — it can never read, list, search or check anything. If you are answering a question, use the read tools instead.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "method": [
                    "type": "string",
                    "enum": ["create", "update"],
                    "description": "Default create.",
                ],
                "issue_number": [
                    "type": "integer",
                    "description": "The issue number, as in #37. Get it from a list, a search, or a notification.",
                ],
                "title": [
                    "type": "string",
                ],
                "body": [
                    "type": "string",
                ],
                "labels": [
                    "type": "array",
                    "items": [
                        "type": "string",
                    ],
                    "description": "Label names that exist in the repo — check with github_list_label.",
                ],
                "assignees": [
                    "type": "array",
                    "items": [
                        "type": "string",
                    ],
                    "description": "Logins.",
                ],
                "state": [
                    "type": "string",
                    "enum": ["open", "closed"],
                    "description": "For update.",
                ],
                "state_reason": [
                    "type": "string",
                    "enum": ["completed", "not_planned", "reopened"],
                    "description": "Why it closed.",
                ],
            ],
            "required": ["owner", "repo"],
        ],
        "strict": false,
    ]

    static let githubAddIssueComment: [String: Any] = [
        "type": "function",
        "name": "github_add_issue_comment",
        "description": "Comment on an issue or a pull request — pass its number either way. Everyone watching is emailed the moment it lands, and deleting the comment afterwards does not unsend that, so read the comment back before posting it. This tool only changes something on GitHub — it can never read, list, search or check anything. If you are answering a question, use the read tools instead.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "issue_number": [
                    "type": "integer",
                    "description": "The issue or pull request number — pull requests take this too.",
                ],
                "body": [
                    "type": "string",
                    "description": "The comment.",
                ],
            ],
            "required": ["owner", "repo", "issue_number", "body"],
        ],
        "strict": false,
    ]

    static let githubUpdatePullRequest: [String: Any] = [
        "type": "function",
        "name": "github_update_pull_request",
        "description": "Change a pull request's own fields: `draft` true to put it back into draft or false to mark it ready for review, plus title, body, state (open/closed), reviewers and base branch. Routine — do it and say you did — with two exceptions. Marking a draft ready notifies its reviewers and putting it back does not unsend that, so say who was notified. And changing `base` decides where a later merge lands, so that one field is confirmed across two turns like a merge. This tool only changes something on GitHub — it can never read, list, search or check anything. If you are answering a question, use the read tools instead.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "pull_number": [
                    "type": "integer",
                    "description": "The pull request number, as in #142. Get it from a list or a search.",
                ],
                "draft": [
                    "type": "boolean",
                    "description": "true puts it into draft, false marks it ready for review.",
                ],
                "title": [
                    "type": "string",
                ],
                "body": [
                    "type": "string",
                ],
                "state": [
                    "type": "string",
                    "enum": ["open", "closed"],
                ],
                "base": [
                    "type": "string",
                    "description": "The branch it would merge into. Confirm this one across two turns — it decides where a later merge lands.",
                ],
                "reviewers": [
                    "type": "array",
                    "items": [
                        "type": "string",
                    ],
                    "description": "Logins to ask.",
                ],
                "maintainer_can_modify": [
                    "type": "boolean",
                ],
            ],
            "required": ["owner", "repo", "pull_number"],
        ],
        "strict": false,
    ]

    static let githubActionsRunTrigger: [String: Any] = [
        "type": "function",
        "name": "github_actions_run_trigger",
        "description": "Start or stop CI: `run_workflow` dispatches a workflow against a branch (needs workflow_id and ref), `rerun_workflow_run` and `rerun_failed_jobs` run one again, `cancel_workflow_run` stops one in progress, `delete_workflow_run_logs` deletes a finished run's logs and cannot be undone. Confirm across two turns first, and read back the workflow, the repo AND the branch — a workflow run from the wrong branch can ship the wrong build. This tool only changes something on GitHub — it can never read, list, search or check anything. If you are answering a question, use the read tools instead.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "method": [
                    "type": "string",
                    "enum": [
                        "run_workflow",
                        "rerun_workflow_run",
                        "rerun_failed_jobs",
                        "cancel_workflow_run",
                        "delete_workflow_run_logs",
                    ],
                ],
                "workflow_id": [
                    "type": "string",
                    "description": "For run_workflow: the workflow's file name (build.yml) or numeric id, from github_actions_list method workflows.",
                ],
                "ref": [
                    "type": "string",
                    "description": "For run_workflow: the branch or tag to run against. Read this back to the user — the wrong branch is the wrong build.",
                ],
                "inputs": [
                    "type": "object",
                    "description": "For run_workflow: the workflow's own dispatch inputs, if it takes any.",
                ],
                "run_id": [
                    "type": "integer",
                    "description": "A workflow run's id, from github_actions_list method workflow_runs.",
                ],
            ],
            "required": ["owner", "repo", "method"],
        ],
        "strict": false,
    ]
}
