---
title: Coming from Conductor
description: How Conductor habits map onto Verde, what you gain on Linux, Windows, and macOS, and what you give up, stated plainly.
section: Get started
order: 3
slug: coming-from-conductor
---

## Who this is for

Conductor runs on macOS only; Windows and Linux are on a waitlist. If you
also work on a Linux or Windows machine and want one agent workspace
everywhere, Verde runs on Linux (x86_64), macOS, and Windows (x64).

Verde is not a drop-in replacement. It is missing several things Conductor
does, and this page lists them below so you can decide before you switch.

**Last checked: November 23, 2026.** Statements about Conductor come from its
own docs and changelog on that date. If something here is wrong or out of
date, [open a GitHub issue](https://github.com/JonathanRiche/verde/issues/new).
For the wider picture, see [Verde compared with other agent workspaces](/compare).

## How the concepts map

| You're used to | In Verde | What's different |
| --- | --- | --- |
| A workspace per task | A workspace is a project folder you import from the sidebar. Chats, terminals, and a browser pane tile inside it. | Verde does not create a git worktree per task. Every chat in a workspace works in the same checkout. |
| Agent sessions | Chat threads. Codex, Claude Code, OpenCode, Cursor, Pi, FX, Grok Build, Antigravity, and Muse Code run in native chat panes, and most of them can also run as their own TUI in a terminal pane. Amp runs as a TUI only. | Chat turns run in Verde's session daemon, so they keep going when you close the app. Conductor's local sessions end when the app closes. |
| Terminals | Terminal panes, tiled next to your chats, plus a terminal dock. A `verde.toml` can declare long-running processes such as a dev server. | Terminal sessions also live in the daemon and survive closing the app. |
| Reviewing and committing changes | The **Changes** view in the right side panel (`Ctrl+Alt+S`, or `Cmd+Alt+S` on macOS) lists uncommitted changes across the workspace's repositories, with diffs, filterable by the chat that made them. From there you can commit a chat's changes, commit them on a new branch, or commit and push when the repository has a remote. After a push to a GitHub feature branch, **Create pull request** opens the PR through the GitHub CLI. | It stops at opening the pull request. There is no checks or merge view. |

## What you gain

- **The same app on Linux, Windows, and macOS.** One app, and one
  `verde.json` config format, on every machine you use.
- **Agents that outlive the window.** A headless session daemon owns every
  chat turn and terminal. Close Verde, reopen it later, and the app reattaches
  to the work that kept running. This is the default.
- **No telemetry.** Verde has no analytics or crash reporting. Conductor
  collects telemetry (PostHog) by default; since v0.97.0 you can turn it off
  in the app.
- **A native app.** Verde is written in Zig on its own GPU UI framework.
  Conductor has shipped on Electron since v0.95.0.
- **Free and MIT-licensed.** Conductor is proprietary: free locally, with paid
  plans for cloud workspaces.
- **Your choice of agent and view.** Ten built-in agents, each as a native
  chat, a terminal TUI, or both; your own ACP agents through
  `chat.custom_acp_agents` (see [Provider setup](/docs/providers)); and any
  other CLI in a terminal pane.
- **A built-in browser.** Tile your dev server next to the agent and use
  [Design Mode](/docs/design-mode) to point at an element and send it to a
  chat.
- **Scriptable and schedulable.** Drive the running app with `verde live`,
  give agents control over MCP, and schedule prompts that fire with the app
  closed. See the [CLI reference](/docs/cli).

## What you lose

- **A worktree per workspace.** Conductor isolates each task in its own git
  worktree. Verde's chats share the project checkout. The Changes view shows
  which chat touched which file, but two chats editing the same file will see
  each other's edits. To isolate a task, create the worktree yourself and
  import that folder as its own project (see below). Verde will not create or
  clean it up.
- **The checks and merge flow.** Verde commits, pushes, and opens GitHub
  pull requests. Watching CI and merging happen in a terminal pane or on your
  Git host.
- **Checkpoints.** You cannot rewind a chat and its file changes to an earlier
  turn. Commit often if you want restore points.
- **Issue intake.** Verde does not pull tasks from GitHub Issues, Linear, or
  other trackers. Paste the issue into the chat, or let the agent fetch it
  with its own tools.
- **Cloud workspaces.** Conductor's cloud workspaces keep running after you
  close the app. Verde has no hosted machines; its web client and phone apps
  pair with machines you run, such as a home server or a cloud VM.
- **A phone app from the App Store.** Conductor has an iOS app. Verde's iOS
  and Android apps are a private beta; the web client works today.

## Getting set up

1. Install Verde and sign in to at least one agent CLI. The
   [Quickstart](/docs/quickstart) has the install commands for each platform,
   and [Provider setup](/docs/providers) covers each agent.
2. Import each repository as a project with the **+** button in the sidebar.
3. Start a chat with the workspace pencil, then pick the provider and model
   before you send the first message.
4. Review the chat's work in the **Changes** view and commit or push from
   there.

If you want Conductor-style isolation for a task, make a worktree and import
it as a second project:

```bash
git worktree add ../my-app-login-fix -b login-fix
# Import ../my-app-login-fix in Verde, work there, then when you're done:
git worktree remove ../my-app-login-fix
```

## Opening a pull request

After a push to a branch other than the default one, the git toast offers
**Create PR**; the chat header's git menu and the command palette offer
**Create pull request** whenever the branch is pushed and ahead of the default
branch. Verde runs the GitHub CLI for you, so install `gh` and sign in once
with `gh auth login`. The title and description are written by the model you
set for commit messages (falling back to the commit text); edit them before you
create the PR, or create it as a draft. If the branch already has an open PR,
Verde shows that one. For other Git hosts, run their CLI in a terminal pane.
