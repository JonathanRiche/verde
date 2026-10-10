# Verde usage friction review (2026-09-27)

Source: ~230 user-authored messages from 2026-09-13 → 2026-09-27 across the verde,
mirage, revicare and victoria_wedding workspaces (desktop, web and mobile), read from
`~/.local/share/verde/Native/state.sqlite`. Orchestration/delegation threads were
excluded (reviewed separately). Counts below are from the same window.

## 1. Every fix ends with "relaunch Verde" — the user is the verification loop

- 74 agent replies told the user to relaunch/restart Verde or the daemon; 9 more
  explicitly said the change was never exercised in the running app.
- User repeatedly closes the loop by hand: "ok i restarted maybe run some more tests?",
  "ok i restarted damoen and gui", "ok i relaucnehd web gateway can you test again?"
- A daemon restart kills every other running agent (2026-09-26: all mobile agents
  stopped just to rebuild).
- Ideas: agent-safe daemon restart / hot swap that doesn't drop other sessions; a GUI
  "restart required — N pending changes" banner; agent-driven verification against a
  throwaway GUI instance.

## 2. Committing is manual chore work in a shared dirty tree

- "git commit and push" is a separate follow-up in most threads (Model Picker, Theme
  Parity, Titling, Workspace Move, Mobile Auto-Submit, Multi-Directory…).
- 19 replies mention hunk-by-hunk staging around other chats' uncommitted work; sibling
  agents' half-finished changes end up in each other's build/test runs.
- Snapshot at review time: 32 changed files on master, 13 already staged (380 lines)
  from other chats — the next plain `git commit` sweeps them up.
- See "Decisions so far" below.

## 3. Web ↔ desktop parity keeps drifting (and regressing)

~8 threads spent on parity: web New Chat "invalid params"; panes not closable, then
"grayed out again"; theme mismatch; settings/reduce-motion not read from the shared
config; "desktop only" notes on features; attachments limited to images (PDF blocked);
wife's live Claude session (via Tailscale web) not visible on the user's web/desktop.
- Idea: shared behaviour contract tests for both clients, or push more UI logic into
  client_core so behaviour can't diverge.

## 4. Transcript trust issues

- Jump on send in existing threads: history drops then re-hydrates page by page
  (message extent / row-gap bug in `prepareProjectionTranscriptContinuity`, 369 hits in
  logs). Worst on long threads, which is the normal usage pattern.
- Duplicate sends: the same prompt landed 3× in 36 s in "Chat Workspace Moving
  Behavior" — the first send likely didn't look submitted.
- Opaque errors: Claude threads showed a vague permission error whose real cause was the
  bridge closing input while a sub-agent was running; the GUI hid the real text.

## 5. Finding threads and resuming context

- User thought a thread was lost and had an agent dig through Claude session logs; it
  was open the whole time under an unrecognised auto-title ("Parallel First-Turn Titling").
- Ctrl+P palette mouse-wheel scrolling was broken (since fixed).
- In the long Sandbox thread: "where did we leave off?", "where we at", "going back to
  the list again where were we?" 4+ times.
- Ideas: per-thread "in flight / remaining" summary in the sidebar or palette; palette
  search over thread content, not just titles.

## 6. Mobile performance and connection stability

Terminal typing 5–10 s per keystroke (since improved to ~1.7 s per burst); connection
drops and "loading workspaces" re-running after refresh; recent chats wrong order / wrong
"just now"; send → message-appears delay; choppy streaming; slow `@` file search (asked
why it isn't using fff via the daemon); laggy model/mode toggles. Several were raised in
one long thread; confirm which are actually resolved.

## 7. Browser pane rough edges

Right-click context menu can't be dismissed by clicking the page; folder-icon click
bounces back to the browser tab when many tabs are open; new tabs default to
about:blank; cookie import lacked "select all" and the list overflowed.

## 8. Bug reporting has a manual step

19 messages point at "latest recording in Videos dir" or a screenshot.
- Idea: "Report bug" action that attaches the last recording/screenshot plus recent
  GUI/daemon logs to a new chat.

## 9. Crashes and resource use from the shared daemon

- 2026-09-23 "massive crashes… again": OpenCode diff tracker use-after-free took down the
  shared daemon and every chat with it.
- Claude sessions with linked children spike CPU/memory.
- Idea: isolate each provider in its own process so one crash only kills that provider.

## Smaller items

- Moving chats between workspaces was confusing (the working-folder pill looks like a
  workspace move); sidebar drag-to-move has since been added.
- The sidebar's right-click menu said "archive" where the user wanted "close pane".
- Connections settings page styling; workspace icons too small.
- Non-coding workspaces (wedding, revicare) had no problems.

---

## Decisions so far (#2)

- **Commits are always user-initiated.** No automatic commits or pushes; Verde users
  will want to commit by hand. Verde's job is to make the click safe and precise.
- **AGENTS.md stays untouched** for this.
- **Worktrees are parked.** Revisit later; current thinking is they don't fit the
  "build from master → restart → test" loop, and at most Verde should make
  orchestrator-created worktrees visible and cleaned up.
- Part 1 direction: per-chat change attribution (tool edit records + per-turn
  snapshots), an "uncommitted changes" indicator on each chat, and a Commit action
  that commits only that chat's hunks using a private index, asking the user whenever
  a hunk is shared or its owner is unclear.
- **Commit message model is its own setting**, next to title generation (provider +
  model dropdowns). Default is a fast, cheap model from whichever provider the user is
  logged into: Codex → `gpt-6-luna`, Claude → Sonnet. Messages are generated off-thread,
  so the chat's own model is never busy writing commits and can keep working.
- UI: header chip (`● 4 files +120 −30`, amber when shared/unclear) + sidebar dot +
  palette command. Clicking the chip always opens a review sheet over the pane (per-repo
  file/hunk checkboxes, inline diffs, generated editable message with regenerate,
  Commit / Commit & Push with the default chosen in settings). The sheet freezes what's
  shown if a turn is still running.
- Changes not made by any chat appear in the sheet as **Unassigned** (unticked).
- After commit: toast, plus a transcript row `Committed 4 files: a1b2c3d` that is
  **UI-only and never sent to the agent's context**. A rejected push keeps the local
  commit and offers Pull & push.
- Found while checking: the title generator's Claude fallback is
  `provider_models.DEFAULT_CLAUDE_MODEL` (`fable[1m]`), which is expensive for titles.
