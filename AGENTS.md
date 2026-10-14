# Agent notes for Codename Jo

These notes are for coding agents (Codex, Cursor, Copilot, Gemini, Claude Code and others) working in this
repo. Start with `README.md` for what the app is and how it's built.

## Adding a connector

To add a service Jo can read or act on (Linear, Granola, Notion and the like), follow
`docs/adding-a-connector.md` from start to finish. It covers:

- whether it needs to be a connector, or Custom MCP already covers it;
- choosing the type of connector;
- checking the vendor's MCP server before writing any Swift;
- the new files to create;
- every existing file that needs a matching change;
- how to build and verify it.

Most bugs come from skipping one of those files, so follow it in order.

## Working in this repo

- The Xcode project is generated from `project.yml`: run `xcodegen generate`. `Config/Local.xcconfig` is
  gitignored and has to be copied in (see `Config/Local.xcconfig.example`).
- Use a git worktree on its own branch. Other sessions commit in the main checkout.
- Use conventional commits (`feat(<area>): …`). Say in the body what was verified and what wasn't.
- `xcodebuild build-for-testing` checks that the app and test targets compile without running anything.
