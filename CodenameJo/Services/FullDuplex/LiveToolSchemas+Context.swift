import Foundation

extension LiveToolSchemas {
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
}
