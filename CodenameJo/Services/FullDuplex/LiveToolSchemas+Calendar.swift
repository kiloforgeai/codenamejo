import Foundation

extension LiveToolSchemas {
    static func respondToCalendarEvent(_ accounts: LiveSessionSetup.Accounts) -> [String: Any] {
        let calendars = accounts.calendars.joined(separator: ", ")
        return [
            "type": "function",
            "name": "respond_to_calendar_event",
            "description": "Accept, decline, or tentatively answer an invitation. Use this for 'accept that', 'decline the standup', 'say maybe to Thursday'. Pass the id of an event from search_calendar or list_calendar_events. The organizer is notified, and answering again replaces the answer.",
            "parameters": [
                "type": "object",
                "properties": [
                    "source_message_id": ["type": "string", "description": "The original invitation email ID, only when accepting from an email. It is archived after confirmed acceptance and an exact invitation UID match."],
                    "source_account": ["type": "string", "description": "Mailbox owning that source invitation email."],
                    "keep_in_inbox": ["type": "boolean", "description": "True when the user explicitly asks to keep the invitation email in the inbox."],
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
}
