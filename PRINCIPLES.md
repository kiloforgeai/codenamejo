# PRINCIPLES.md

The rules every change in this repository is held to. They are short on purpose: an agent writing
code reads them before starting, and an agent reviewing a PR grades the diff against them, one by
one. Nothing here is enforced by tooling; a review that skips a rule is how the pattern comes back.
When a rule and the code disagree, the rule wins and the code is drift.

## Scope

1. **Do what was asked, all of it, and nothing else.** No unrequested refactors, findings, or
   follow-ups in the diff or the reply. If part of the ask is blocked, finish the rest and say what
   was left out.
2. **One PR per piece of work.** Never stack or split. A second concern found mid-task is folded
   into the open branch or raised, not opened as its own PR.
3. **Stay on the checked-out branch.** Never switch a repo off the branch it was parked on. Backend
   work gets a fresh worktree cut from `origin/main`.
4. **Build and drive the app only when explicitly asked.** `/validate-change`, local Codex
   reviews, and independent critic subagents are opt-in only. They are not required for code,
   tests, scripts, executable configuration, or non-code changes. Complete work on a feature
   branch, then commit, push, and open or update its PR.
5. **Verify a platform claim before it becomes a diagnosis or a PR.** Check Apple's docs, a vendor's
   discovery document, or the code. A belief that stood for a week in three files was undone by one
   `curl`.

## Code

6. **One voice path, one MCP server.** The conversational call has one transport, one Realtime
   model and one tool route; no second one without a reason the existing one cannot serve.
   "Offline" is the only honest reason and it is a new design. That design is `LocalVoiceCall`:
   on-device recognition, the text brain and the phone's own voice, engaged on its own when the
   Live session cannot be reached or drops, or on every dial, with nothing sent to OpenAI, when
   the user chooses Fully local mode. Dispatch's separate text brain is
   sanctioned because it is not a call.
7. **The container is the only door to a service.** Register in `Extensions/Container+App.swift`,
   inject with `@Injected`, resolve with `Container.shared.x()` in views. No new `static let
   shared` outside `Shared/`. Never `@EnvironmentObject`, `.environmentObject`, or `.environment`
   on our own types — in code or in docs.
8. **Every screen is view, view model, interactor, component.** Lifecycle work goes in
   `onViewAppear`/`onLoad` via `bind(observer:viewModel:)`, not `.task`/`.onAppear`. Stores are
   `@MainActor ObservableObject`, not `final`, no `private(set)` on `@Published`.
9. **Bar chrome stays at system defaults.** No `.toolbarColorScheme`, `UINavigationBarAppearance`,
   `UITabBarAppearance`, `.toolbarBackground`, and no `.preferredColorScheme` with a literal — the
   one exception is the user's `AppearanceSetting` applied once at the window root. Titles are
   `.inline` and empty; a screen names itself with a `Text` in the content area.
10. **Nothing that blocks goes on the main thread.** Audio session, engine and tap calls run on
    `AudioQueue`. A run-loop hop is not a fix.
11. **Correctness never depends on a silent push.** A push is a hint that a refresh may be worth
    running, budgeted by battery. Design as if it never arrives.
12. **Per-account facts are backend columns with a default**, read by the app — never an app-side
    rule, trigger or job. Per-user facts the model needs are an MCP tool, not prompt text frozen at
    mint.
13. **Slow work comes off the turn.** Dispatch it; do not narrate the wait better. The assistant
    reports results, never turn mechanics. On GPT Live, while delegated work runs, a short
    presence line ("still working on that") is allowed; it never names a tool, step or service.
14. **A conversation is a call.** A dial gets one id and keeps it; a call resumed from History
    deliberately reuses the earlier id so `search_context` finds it. Never split an id on a pause
    or merge two ids.
15. **Unwiring means deleting.** A feature taken out is deleted, not commented out or hidden
    behind a flag; the commit that removes it says what went, so it can be restored from git.
16. **Local stores are user-scoped.** Every on-device row carries `user_id`; the sign-out purge is
    not the boundary.
17. **Prompt variants get their own flag**, constant, text and profile key; never composed from an
    existing prompt.
18. **Surface failures; never swallow them.** No empty `catch`, no `if error != nil { }`. A dead
    component and a quiet user must not render the same.
19. **Onboarding makes very few Gmail calls, and only from the phone.** Gmail's per-user rate limit
    is shared by the phone and the broker; on 2026-09-10 the broker's onboarding picks alone cost
    ~130 requests, ran twice, and 429'd the phone's own sync. Selection for onboarding steps 2–4
    lives in `LocalOnboardingMail` behind `GmailQuota`: list only what is kept, batch the gets,
    never fetch the same message from both sides. A new onboarding read needs the request count in
    the PR.

## Writing

20. **Comments are one or two lines and only where the code cannot say it.** No histories, no
    arguments with a previous approach, no dates and attributions. The why goes in the commit and
    PR body.
21. **No status write-ups or changelog files in the repo.** The diff, commit and PR are the
    record.
22. **A PR body is under 1,500 characters**: what changed (≤5 bullets), what was verified, what was
    not. Same shape for the commit body. Never open a draft.
23. **Codex review comments get fixed, answered and resolved** without being asked.
24. **Do not touch workflow YAML or `scripts/`** without an explicit instruction from the repo owner.
25. **When device testing is requested, use the device, not the simulator.** The simulator does
    not reproduce the rendering and audio bugs this app has. The pure-logic XCTests may run
    wherever `xcodebuild` puts them.

## For the reviewer

Grade the diff against each numbered rule and cite the number. A violation is a blocking finding
even when the code works. A rule that is wrong gets changed here, in its own PR, not worked around.
