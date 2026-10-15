# Codename Jo

A hands-free voice assistant for your inbox and the tools around it. You talk, and Jo walks
you through your mail. It:

- reads you the week, ranked by what matters
- summarises, drafts and sends replies
- archives, labels and unsubscribes
- puts things on your calendar
- hands longer jobs to a background worker, so the conversation keeps moving

**Fully client-executed.** Every tool, ranking, summary and decision runs on your phone, on
your own OpenAI key. The only server is a thin, stateless Google connection shim that adds
our verified client's secret to Google's token calls. It records the email address of each
Google account that signs in, and never sees your mail.

This repository is the iOS app (SwiftUI), with a watchOS companion and a Live Activity.

## What runs where

| Piece | Where it runs |
|---|---|
| Voice session (`gpt-live-1`) and the reasoning model behind it (`gpt-5.6-luna`) | OpenAI, called straight from the phone with your API key |
| Gmail and Calendar reads and writes | The phone, calling Google's APIs directly |
| Ranking your mail by importance, email summaries, per-category playbooks | The phone, which asks OpenAI on your key |
| The mail queue, profiles, history, settings | The phone's local database |
| Your Google, Notion, Granola, Slack, GitHub and custom MCP credentials | The phone's Keychain |
| Google sign-in and token refresh | Our hosted token shim, which adds the web client's secret to Google's token request and returns the result. It records each signed-in account's email and first sign-in date, and never stores or logs tokens |

What leaves your phone, and to whom:

- **To OpenAI, on your key:** your voice, and the mail, calendar and connector content Jo
  needs to answer you. That means senders, subjects and previews, plus full message bodies
  when Jo reads them.
- **To Google, Notion, Granola, Slack, GitHub and any MCP server you add:** the API calls Jo
  makes for you, with your own tokens.
- **To the token shim:** a Google sign-in code or refresh token, once at sign-in and about
  once an hour per account after that. At sign-in it records the account's email address and
  the date. Nothing about your mail.
- **To Hugging Face:** a one-time download of the local voice model and its pronunciation
  lexicon, the first time the local voice is used. Nothing about you goes with it.

Apart from that sign-up email, there is no analytics, telemetry, push, call recording or
feedback upload.

## Connectors

| Connector | How you connect | What Jo can do |
|---|---|---|
| **Gmail and Google Calendar** | Google sign-in during onboarding. Add more inboxes in Settings | The core: read, rank, summarise, draft, send, forward, archive, trash, label, filter, unsubscribe; read and change your calendar |
| **Notion** | Settings → Connections | Search, read pages and databases, add notes, create pages, update properties. It can't delete pages: Notion's MCP server has no tool for it |
| **Granola** | Settings → Connections | List meetings, read notes, pull action items |
| **Slack** | Settings → Connections | Walk your unread Slack in a call (important Slack after important mail), read channels and threads, send, schedule, react, mark read |
| **GitHub** | Settings → Connections, by entering a short code on github.com (device flow) | Pull requests, checks, issues, commits, notifications and workflow runs. Merging, editing issues and starting workflows only happen after you confirm, unless one of your own saved commands does them |
| **Custom MCP** | Settings → Connections → Custom MCP, by entering any MCP server's https address. Sign in with OAuth, paste a token, or connect with no credential | Every tool the server lists, as `mcp_<server>_<tool>`. Jo lists them when you add the server and again behind each call |

The phone talks to each service directly:
- **Notion and Granola** through their own hosted MCP servers.
- **Custom MCP servers** through the endpoint you entered, over streamable HTTP.
- **Slack** through its Web API.
- **GitHub** through its REST API.

None of them goes through any server of ours.

## Requirements

- An iPhone on iOS 26.4 or later.
- A Mac with Xcode 26.4 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`).
- An OpenAI API key whose project can use `gpt-live-1`, `gpt-5.6-luna` and `gpt-6-luna`.
- An Apple ID. A free one works, with Apple's limits: the app has to be reinstalled from
  Xcode every 7 days.

## Build and run

```sh
git clone https://github.com/kiloforgeai/codenamejo.git
cd codenamejo
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then fill it in, see below
xcodegen generate
open CodenameJo.xcodeproj
```

Pick your iPhone as the run destination and press Run. On first launch, Jo asks for your
OpenAI key, then walks you through Google sign-in and the microphone permission, and dials
your first call.

`Config/Local.xcconfig` (git-ignored) holds the settings that are specific to you:

| Setting | Required | What it is |
|---|---|---|
| `DEVELOPMENT_TEAM` | Yes | Your Apple team ID (Xcode → Settings → Accounts) |
| `APP_BUNDLE_ID` | Yes | A bundle ID you own, such as `com.yourname.jo` |
| `JO_SLACK_CLIENT_ID` | No | Your own Slack app, instead of ours. It needs PKCE turned on and the redirect `com.kiloforge.codenamejo://oauth/callback` |
| `JO_GITHUB_CLIENT_ID` | No | Your own GitHub OAuth App, instead of ours. It needs "Enable Device Flow" turned on |

With only the first two set, everything works. Google sign-in uses our hosted shim and our
verified, CASA-assessed Google client, so you don't need a Google Cloud project of your own.

## Your OpenAI key

Jo runs on **your** OpenAI account, and you pay OpenAI directly for what it uses. Create a
key at <https://platform.openai.com/api-keys>. The key stays in the phone's Keychain and is
sent only to OpenAI. Nothing calls a model until a key is saved. Deleting the app forgets
the key, so a reinstall asks for it again.

## Limitations

- **Background work needs the app alive.** A dispatched job or a send keeps going after
  you hang up, and the next call tells you how it went. Started on screen, a job gets
  minutes off screen; started from the Lock Screen, about 30 seconds. Force-quitting stops
  it, and nothing is fetched or prepared overnight.
- **History keeps the last 30 days.**
- **Slack checks at most 50 conversations per sweep,** to stay inside Slack's rate limits.
- **Profiles and settings live on one phone.** They don't sync between devices.

## Tests

```sh
xcodebuild -scheme CodenameJo -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Contributing

Read [PRINCIPLES.md](PRINCIPLES.md) first. Every change in this repository is held to it.

## Adding a connector

To add a service Jo can read or act on (Linear, Notion and the like), follow
[docs/adding-a-connector.md](docs/adding-a-connector.md) from start to finish. It names every
file to create and every existing one to touch, in order. Coding agents get the same guide
through `AGENTS.md`, and Claude Code has an `add-connector` skill, so "add Linear as a
connector" is enough to start.

## License

MIT. See [LICENSE](LICENSE).
