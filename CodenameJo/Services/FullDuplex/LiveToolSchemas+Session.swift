import Foundation

extension LiveToolSchemas {
    static let logFeedback: [String: Any] = [
        "type": "function", "name": UserFeedbackTool.name,
        "description": "Save the user's feedback about Jo locally for later inspection. Use when the user asks to log feedback, report a bug, or record a complaint or suggestion about this app. Preserve their wording; never invent feedback or copy email, Slack, or tool content into it. If the feedback itself is missing, ask what to record. Only acknowledge saving after success. This does not upload, create a GitHub issue, change settings, or advance the feed.",
        "parameters": ["type": "object", "properties": [
            "message": ["type": "string", "description": "The user's feedback in their own words.",
                        "minLength": 1, "maxLength": FeedbackText.maximumCharacters]
        ], "required": ["message"], "additionalProperties": false]
    ]

    static let dispatch: [String: Any] = [
        "type": "function",
        "name": "dispatch",
        "description": "Hand one self-contained job to a second agent that has the same mail, calendar and connector tools you do — reads and writes both — and can spend several minutes on it. This tool answers you immediately with the single word 'started' and nothing else: it never returns the job's result, so there is no answer to wait for and nothing to report yet. The real answer arrives later as a note in this conversation, and you speak it then. The second agent works with nobody listening to it — it can do anything routine, it can never hear the user agree to anything, and it cannot ask you a question, so it does the routine work and comes back saying what it needs for anything that takes a spoken yes. Use it for a job that is many steps: reading a long history, working through a dozen messages, research across several searches. A single call you could make right now is not one. The task is all it gets — no transcript, no history, no way to ask what you meant — so write it as a complete instruction. It has find_person and every search you have, so it can resolve a name itself and you should not spend a turn doing that first — pass an address, id or channel when you already have one, and spell out anything only this conversation could tell it. If a mail queue is running, handing a job over does not end it, and this tool's own result says where the queue now stands — follow it exactly. In a mail queue only scope current_email counts as dealing with the current email. Use independent for unrelated questions such as weather, even while an email is open; it leaves the queue unchanged and its answer is an aside, never an email research return. For explicitly requested background work, keep the foreground email in place and follow the actual tool result. For other current_email handoffs, the result carries the NEXT message, so say the job is going in a clause and read that message out, ending on what they want to do with it. If the result instead hands back the message they are still standing on, go straight back to it in the same turn by name, without asking its question again. Either way, do not ask whether they want to keep going, and do not call triage_next — the result has already told you where they are.",
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
                "completion_preference": ["type": "string", "enum": ["quiet", "bring_back"],
                    "description": "quiet for finish quietly or no need to tell me when it succeeds; bring_back for bring me the result when ready. This controls reporting only, never approval. Errors and needs-input still surface."],
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
        "description": "The user's own commands: a keyword they say, and the tool calls it runs. Answered on the device, instantly. `run` with that exact `keyword` when they say a saved command — it executes the stored steps in order as one job. Do not repeat its steps yourself. `list` when they ask what commands they have — it returns names to read back, and no steps, because they asked what they have rather than how it works. `correct_label` to persist an explicitly agreed correction to a command's label (keyword, label_name, account); never claim a correction saved before this succeeds. `save` to create one or change what a keyword does, `delete` to remove one, `enable` and `disable` to switch one without losing it.",
        "parameters": [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["run", "list", "save", "correct_label", "delete", "enable", "disable"],
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
                "label_name": ["type": "string", "description": "Exact existing Gmail label for correct_label."],
                "account": ["type": "string", "description": "Mailbox owning the corrected Gmail label."],
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

}
