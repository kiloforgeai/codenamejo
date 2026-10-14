# Add a connector to Jo

A connector is a service Jo signs in to **from the phone** and calls **from the phone**. No server of
ours is in between (README → Connectors). Most of the work is following the same thread through about 20
files. This guide names every one of them, so nothing gets missed.

## 0. Does it need to be a connector?

Since Settings → Connections → Custom MCP, anyone can point Jo at an MCP server by its https address,
and every tool it lists reaches the live call as `mcp_<server>_<tool>`. If that is all you want, you
don't need this guide. Build a connector when the service deserves more than the server's raw tools:
our own short schemas, a skill prompt saying when to use them and how to read results aloud, a
confirm step for writes, a narrowed write surface, or a service with no MCP server at all.

## 1. Settle the shape before you write code

Ask, or work out, these four things. They decide which template you copy.

1. **How does it connect?**
   - **Hosted MCP server with OAuth and dynamic client registration.** This is the easy path and the
     usual one: Notion and Granola both work this way. You add one `RemoteMCPService` value and the
     shared client in `CodenameJo/Services/RemoteMCP/` handles discovery, registration, PKCE, refresh,
     revocation and the Keychain.
   - **Its own OAuth app** (Slack, `Services/Slack/`) or the **device flow** (GitHub,
     `Services/GitHub/`). Each needs a client ID wired through `Config/Version.xcconfig`, `Info.plist` and
     `AppHosts.swift`. Only go this way when there is no usable MCP server. You also own the token
     storage: a `<Name>TokenStorage` protocol with a Keychain implementation, registered in
     `Extensions/Container+App.swift` next to `githubTokenStorage`, and reached only through the
     container (`GitHubAccountStore` calls `Container.shared.githubTokenStorage()`; services use
     `@Injected`). PRINCIPLES rule 7: no new `static let shared`.
2. **Who calls the tools?**
   - **Live and dispatch** (Granola, Slack, GitHub, Custom MCP): the voice session calls them directly,
     and the background dispatch agent gets the same tools, so a handed-over job or a saved command can
     use them. This is the default: a tool only the live call has is one a saved command cannot run.
   - **Dispatch-only** (Notion): only the background dispatch agent sees the tools. See
     `DispatchWorker.swift` (`NotionTools` in `loop` and `execute`) and `LiveSessionSetup.workerTools`.
3. **Read-only, or writes too?** Every write needs a read-back and a yes on a later turn, which the skill
   prompt enforces. Mark writes as `performedTool` in the tool result. If the grant allows more than
   you mean to expose, keep an allowlist the way `GitHubTools.allowedTools` does: GitHub's `repo` scope
   carries push, force-push and delete, so what the connector can do is that list, and `run` refuses
   any name outside it before touching the API.
4. **Does it belong in the Feed?** The Feed is the morning walk: what arrived for the user since they
   last listened, read out one item at a time so they can clear it by ear. A service joins it only
   when it is an **inbox**: other people send the user things through it, every day, unasked, and
   hearing one is enough to settle it (reply, act, skip). The default is out.
   - **In:** mail and Slack. Today's calendar is a stage of its own. Linear would join as issues
     assigned to the user plus mentions.
   - **Out:** Granola, Notion and GitHub. Granola's action items arrive daily but came out of meetings
     the user sat in; nothing was sent to them, so they are a record to look up, not an inbox. Notion
     is a store Jo reads on request. A GitHub review request is settled in the diff, never by ear. Jo
     reaches all three when asked.
   - A Feed stage is a second project on top of the connector: a device-walked queue with a
     `<name>_triage_next` tool and its finishers (`Services/Slack/LocalSlackQueue.swift`), a
     `FeedFocus` case, and an addendum placing the stage (`prompts/addenda/slack-feed-stage.md`).

**Templates:**
- **Read-only, live MCP:** the Granola commit `3e6a588`. Logo and onboarding came later, in `45abbb0` and
  `55976b4`.
- **Dispatch-only:** the Notion commit `1a59f30`.
- **Feed stage:** the Slack commit `6a5c51f`, walked between important mail and the rest.

Run `git show --stat <sha>` and mirror that file list.

## 2. Check the vendor's MCP server (hosted-MCP path)

Don't write Swift until all three of these check out:

```sh
# 401 + WWW-Authenticate names the protected-resource document and the scopes
curl -si -X POST https://<host>/mcp -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}' | head -20
curl -s https://<host>/.well-known/oauth-protected-resource/mcp   # then without /mcp
curl -s https://<authorization-server>/.well-known/oauth-authorization-server
```

1. **Registration.** The server metadata needs a `registration_endpoint`, `code_challenge_methods_supported`
   containing `S256`, and `none` among the token-endpoint auth methods. Without them `RemoteMCPAuth` can't
   sign in. Stop and tell the user: they'd need a registered OAuth app.
2. **Scope.** Decide the scope that gets a refresh token. Some servers want `offline_access` (Granola),
   others only their own scopes. Notion sends none.
3. **Real tool names and argument shapes.** `tools/list` needs a signed-in token. The quickest way is to
   connect the same server to the MCP client you're working in (Claude Code's `/mcp`, Codex's or
   Cursor's MCP settings), sign in, and read the tool schemas it lists. If you can't, ask the person to.
   Also find a "who am I" tool so the grant can be labelled with the account's email.

## 3. New files

Replace `<Name>` / `<name>` with the connector's name.

| File | What goes in it |
|---|---|
| `CodenameJo/Services/<Name>/<Name>Connector.swift` | `extension RemoteMCPService { static let <name> = RemoteMCPService(id:, displayName:, endpoint:, scope:) }` plus `grants` / `connect` (labels the grant from the who-am-I tool) / `disconnect` (revokes) / `forget`. Copy `GranolaConnector.swift`. **`id` must never change once shipped**: it namespaces the Keychain items. |
| `CodenameJo/Services/<Name>/<Name>Tools.swift` | `names` (prefix every tool with `<name>_`), a `Call` typealias that tests can swap out, and `run(name:argumentsJSON:)` that turns **our** arguments into the vendor's tool. Relay only the keys your schema names. Give several accounts a sensible meaning: reads are tagged per account, writes need `account` (see `CalendarTools.definitions(accounts:)`). Explain each `RemoteMCPError` in words the model can say. |
| `Services/FullDuplex/LiveToolSchemas.swift` | One `static let` per tool, `{type, name, description, parameters, strict: false}`, and a `static let <name>` array of them. Write the schemas for a voice turn, short and in our own words, not the vendor's verbatim schema. |
| `prompts/skills/<name>.md` | The skill text: when to use which tool, how to say results ("name three and stop"), and a **Confirm first** list for every write. |
| `prompts/notes/<name>-reauth.md` | One paragraph containing `{{which}}`, used when a grant's refresh was refused. Copy `granola-reauth.md`. |
| `prompts/coaching.json` | One or two lessons with capability ids like `<name>_<thing>`. |
| `CodenameJo/Resources/Assets.xcassets/Connector<Name>.imageset/` | The logo. An SVG mark uses the template rendering intent (copy `ConnectorNotion`'s `Contents.json`); a full-colour PNG uses `original` (Granola). Simple Icons has most marks. |
| `CodenameJoTests/<Name>ToolsTests.swift` | Copy `GranolaToolsTests.swift`. Cover argument mapping, several accounts, refused grant → reconnect text, no grant, the account label, the scope, the session's tools/skill/reauth following the grants, the prompt, lessons gated on a connection, the broker routing a tool, sign-out forgetting grants, and the attention badge. |

## 4. Existing files: add `<name>` next to every `granola`

Running `grep -rn -i granola CodenameJo CodenameJoTests prompts README.md` lists nearly every place. This is
the full set:

- **`Views/ProfileConnectionsSection.swift`**
  - Add the case to the `ProfileConnectionProvider` enum, then fill in `title`, `icon` and `state(in:)`.
  - Add `if provider == .<name> { <name>Section }`.
  - Add a `<name>Section`, copied from the Granola section.
  - Add `ConnectorCopy.<name>`, one honest sentence on what it can and can't do.
- **`Onboarding/OnboardingConnectView.swift`:** `ConnectorLogo`, `onboardingBlurb`, the `available` and
  `accounts` maps, `connect(_:)`, and the comment at the top of the file.
- **`Services/ConnectionsService.swift`**
  - Add `@Published` `<name>Accounts` / `<name>Available` / `<name>NeedsReauth`.
  - Add the connector to `attentionProviderNames`, `hasAnyConnector`, `connectedServices`, `refresh()`
    and `clearPublishedStatus`.
  - Add a `connect<Name>(replacing:)` / `disconnect<Name>` section. `busyConnector` uses `"<name>"`.
- **`Views/ProfileView.swift`:** the three handler-protocol methods, the view-model properties, the
  Combine sinks and the interactor implementations.
- **`Models/ConnectorCapability.swift`:** `static let <name>: [ConnectorCapability]`. Every chip must be
  true; if something can't delete, say so.
- **`Models/ToolNarration.swift`:** a spoken `Phrasing` for each tool, plus a `sourceIcon` prefix rule
  (`tool.hasPrefix("<name>_")`).
- **`Models/CommandRecord.swift`:** add `knownServices` (name and SF Symbol). The order decides the order
  of History's chips.
- **`Services/RealtimeService.swift`:** `inferService` keywords. Put specific words before GitHub's
  generic "issue".
- **`Services/FullDuplex/`**
  - `FullDuplexBroker.swift`: read the grants in session setup, set `state.<name>…`, add to coaching
    eligibility and the session log line, and route the tool names in `runTool`.
  - `LiveSessionSetup.swift`: `State` fields, register the tools in `tools` (a `ConnectorTool` each, run
    by `runTool`), add them to the session, add the skill to `skills`, and the
    `<name>NeedsReauth` prompt fact.
  - `LiveSessionSetup.workerTools` and `FullDuplexBroker.workerTools`: a `<name>` parameter that adds
    the same tools to a dispatched job.
  - `DispatchWorker.swift`: read the job profile's grant in `loop` and pass it to `workerTools` and
    `instructions` (which adds the skill); route the names in `execute`, saying whether each writes;
    and list the tool names in `takesMailAccount`, so a pinned mail account is never passed to them.
  - `LivePrompt.swift`: the `Facts` field and parse, `skillOrder`, and a `reauthNote(...)` entry.
  - `LiveFastAction.swift`: add **read** tools to `feedIndependent`, never writes.
  - `CoachingRotation.swift`: an `Eligibility` flag and an `available` case for your lessons.
- **Grant cleanup**
  - `Services/BackendService.swift`: `<Name>Connector.forget()` in both sign-out paths, and revoke every
    grant in account delete.
  - `Services/WorkspaceProfileStore.swift`: revoke and remove the deleted profile's grants.
- **Tests:** add a scenario line to `CodenameJoTests/Fixtures/live-session-parity.json`, and decode the
  new state keys in `LiveSessionSetupParityTests.state(_:)`.
  - Each scenario in that fixture is a single line of compact JSON (`separators=(',',':')`).
  - Clone a neighbouring scenario with a script, then change its `state`, `tools` (the full entries from
    `LiveToolSchemas`, in the order `LiveSessionSetup` adds them) and `prompt`.
- **`README.md`:** a row in the Connectors table, plus the "talks to each service directly" list.

## 5. Build and verify

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # gitignored; fill it in (README → Build and run)
xcodegen generate                                  # the .xcodeproj is generated, not committed
xcodebuild build-for-testing -project CodenameJo.xcodeproj -scheme CodenameJo \
  -destination 'generic/platform=iOS Simulator' 2>&1 | grep -E '\.swift:[0-9]+:[0-9]+: error|\*\* '
```

Lines saying "failed with exit code 0 but produced no further output" are noise. Trust the `** … **`
line.

- **"Unable to type-check this expression in reasonable time"** usually means the `skills` array in
  `LiveSessionSetup.resolve` has grown too long. Build it up in steps instead.
- **Tests:** run `<Name>ToolsTests`, `LiveSessionSetupParityTests`, `DispatchWorkerTests` and any `*ToolsTests` near what you
  touched. The suite is slow, so if the person would rather run it themselves, ask first.
- **Check on a device:** Settings → Connections → connect (the account email shows); ask Jo something
  that uses each read tool; for a write, confirm Jo reads it back and waits for a yes; disconnect; sign
  out.

## Conventions

- Work in a git worktree on its own branch: other sessions commit in the main checkout.
- Use conventional commits (`feat(<name>): …`). The body says what was verified and what wasn't.
- Match the surrounding code's comment density and voice. The comments here explain *why*.
- Gmail's per-user rate limit is shared by the phone and the broker. Onboarding reads go through
  `GmailQuota`, and a new one needs its request count in the PR (PRINCIPLES rule 19).
