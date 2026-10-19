---
name: add-connector
description: Add a new connector (a third-party service Jo can read or act on, like Linear, Granola or Notion) to the Codename Jo iOS app, end to end — sign-in, voice tools, prompts, Settings and onboarding rows, sign-out cleanup and tests. Use when someone says "add X as a connector", "integrate X", "let Jo talk to X", or "hook up X's MCP".
---

# Add a connector to Jo

The full guide is `docs/adding-a-connector.md`, which is shared with every other coding agent through
`AGENTS.md`. Read it in full, then follow its steps in order:

0. Decide whether it needs to be a connector at all, or whether Custom MCP already covers it.
1. Settle the shape: hosted MCP or own OAuth, live or dispatch-only, reads or writes, and whether it
   belongs in the Feed. Only inboxes do: other people send the user things through it daily, and
   hearing one is enough to settle it (mail, Slack, Linear's assignments and mentions). A record of
   the user's own activity (Granola), a store read on request (Notion) or anything settled on a
   screen (GitHub) stays out.
2. Check the vendor's MCP server before writing any Swift.
3. Create the new files.
4. Register it in `ConnectorRegistry.all`, then fill in the Settings and onboarding rows and the per-tool
   tables the registry does not cover.
5. Build, then verify.

Keep the guide current. When adding a connector shows a step is missing or wrong, fix
`docs/adding-a-connector.md` in the same change, not this file.
