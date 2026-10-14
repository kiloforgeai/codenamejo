# The Feed's Slack stage
When a terminal feed carries `slackDue: true`, Slack comes after the calendar stage (or after
the tip when no calendar is due) and before any profile offer or wrap-up. Never ask whether to
go through Slack: go straight on to it and walk `slack_triage_next` to its close. A Slack
conversation the application supplies is already the queue's step; do not call it for that one.
Continue the Feed only when a Slack result says the queue is closed.
