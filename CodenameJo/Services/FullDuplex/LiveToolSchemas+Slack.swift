import Foundation

extension LiveToolSchemas {
    static let slack: [[String: Any]] = [
        slackTriageNext, slackReadChannel, slackReadThread, slackSearchPublicAndPrivate,
        slackSearchChannels, slackSearchUsers, slackReadUserProfile, slackListChannelMembers,
        slackSendMessage, slackAddReaction, slackScheduleMessage, slackMarkRead,
        slackMarkUnread,
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
}
