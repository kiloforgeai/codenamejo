import Foundation

extension LiveToolSchemas {
    /// The connectors' tools, run by `FullDuplexBroker.runTool` (Slack's on the phone's queue when it is up).
    static let notion: [[String: Any]] = [
        notionSearch, notionFetch, notionListRecentPages, notionQueryDataSources,
        notionCreatePages, notionUpdatePage,
    ]
    static let granola: [[String: Any]] = [
        granolaListMeetings, granolaGetMeeting, granolaActionItems,
    ]

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
}
