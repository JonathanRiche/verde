---
title: Quickstart
description: Install Verde, authenticate a provider CLI, and run your first chat thread in a tiled workspace.
section: Get started
order: 1
slug: quickstart
---

## Install

Install the latest Verde release from the website.

On Linux or macOS:

```bash
curl -fsSL https://verdeai.dev/install.sh | sh
```

On Windows x64, open PowerShell and run:

```powershell
irm https://verdeai.dev/install.ps1 | iex
```

The installers download the matching release artifact from GitHub and verify it
before installation. Linux installs into `~/.local`, macOS installs into
`/Applications`, and Windows installs the complete app and runtime package into
`%LOCALAPPDATA%\Programs\Verde`, creates a Start Menu shortcut, and launches the
app. The Windows install does not require administrator access. For other paths
— Arch Linux via the AUR, an npm launcher, a custom prefix, or a source build —
see the [install section on the homepage](/#install).

On Linux, the embedded browser pane uses the system WPE WebKit runtime. The
installer will warn if the required libraries are missing and print the package
command for your distribution. You can let it install them by setting
`VERDE_INSTALL_BROWSER_DEPS=1` before running it.

## Authenticate a provider

Verde does not host a model. It drives the coding-agent CLIs already installed on
your machine, so install and authenticate at least one provider before launching
the app:

| Provider    | Setup                                                                              |
| ----------- | ---------------------------------------------------------------------------------- |
| Codex       | Install the [Codex CLI](https://github.com/openai/codex), then run `codex login`.  |
| Claude Code | Install [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and Node.js, ensure `node` is on `PATH`, then log in. |
| OpenCode    | Install [OpenCode](https://github.com/anomalyco/opencode); ensure `opencode` is on `PATH`. |
| Cursor      | Install the [Cursor CLI](https://cursor.com/docs/cli/installation), ensure `agent` is on `PATH`, run `agent login`. `CURSOR_API_KEY` is also supported for headless environments. |
| Amp         | Install [Amp](https://ampcode.com); ensure `amp` is on `PATH`. Amp runs as a terminal TUI rather than a chat pane — launch it from the command palette. |

See [Provider setup](/docs/providers) for the full per-provider notes.

## Launch

```bash
verde
```

The first launch opens an empty workspace. If no GUI provider is ready, the
**Connect an AI provider** screen shows which CLIs are missing, need sign-in, or
are ready. Finish setup and choose **Check again**, or choose **Not now** to
continue without a chat provider.

The sidebar on the left lists your projects and threads; the main area is where
chat, terminal, and browser panes live as a tiling tree.

## Import a project

Right-click the sidebar or click the **+** button to import a project. Verde
watches the project directory you import; threads, processes, and agents all
operate against that workspace root.

A project can optionally declare a stack in `verde.yml` (or `verde.yaml`) at its
root — long-running processes and agent CLIs to drive from the terminal dock.
See [Configuration & state](/docs/config) for the schema.

## Start a chat thread

1. With a project imported, press `Ctrl+T` (or `Cmd+T` on macOS) to create a new chat thread.
2. Open the searchable model picker. Before the first message you can choose both the provider and model; after that, the provider stays bound to the thread.
3. Open the **Run** pill to choose available reasoning and speed options, plus **Supervised** or **Full access** command permissions.
4. Type a prompt and press `Enter` to send. The transcript grows as the agent streams; consecutive tool calls collapse into a status summary you can expand.
5. Press `Tab` while focused in a chat thread to return focus to the prompt box.

See [Chat, models & runs](/docs/chat) for provider readiness, model shortcuts,
follow-ups, approvals, and transcript preferences.

## Tile a browser pane

Press `Ctrl+B` to toggle the embedded browser pane next to the focused chat. On
Linux it uses WPE WebKit, on macOS WKWebView, on Windows WebView2 — never a
bundled Chromium. Use it to keep docs, a preview server, or a staging URL in
view while the agent works.

You can drive the browser pane from the CLI too:

```bash
verde live browser open --url http://localhost:3000
verde live browser navigate --url http://localhost:3000/dashboard
verde live browser eval --script "document.title"
```

Click the browser inspector to enter **Design Mode**. Select an element, box,
or freeform region; describe the change; then route the resulting context to a
chat or terminal agent. See [Design Mode](/docs/design-mode) for platform
screenshot support and delivery behavior.

## Split a terminal

Press `Ctrl+Shift+T` to split a terminal pane next to the focused workspace pane.
Right-click inside a terminal to spawn shell tabs or agent launch-profile tabs
(Claude, OpenCode, Codex, Cursor, Amp). Per-terminal zoom (`Ctrl+-` / `Ctrl+=`)
and the full layout persist across launches.

## Move around

- `Ctrl+H / J / K / L` — move focus across panes, vim-style
- `Ctrl+Shift+H / J / K / L` — swap the focused pane with its neighbor (rearrange the tiling)
- `Alt+Shift+← ↑ ↓ →` — resize the focused pane
- `Alt+Z` — zoom the focused pane to fill the workspace; press again to restore
- `Alt+1 … Alt+9, Alt+0` — jump between workspaces by sidebar order
- `Alt+↑ / Alt+↓` — cycle to the previous / next workspace

The full set of defaults and how to remap them is in [Keybinds](/docs/keybinds).

## Open the command palette

`Ctrl+Shift+P` opens a Raycast-style launcher that ranks chat threads, open panes,
workspaces, and app commands in a single searchable list. Press `Ctrl+Enter` on
any result to open it in a fresh pane.

Closing a workspace with `Ctrl+Shift+W` removes it from the active sidebar but
keeps its layout and threads. Use the command palette's reopen action to bring
it back.

Slash commands like `/stack` and `/process` run from the composer alongside each
provider's own commands. See [Panes & tiling](/docs/panes) for the full pane
surface.

## Where to go next

- [Provider setup](/docs/providers) — provider-specific notes and troubleshooting.
- [Chat, models & runs](/docs/chat) — model selection, run permissions, approvals, and transcript controls.
- [Design Mode](/docs/design-mode) — send browser selections to chat and terminal agents.
- [Panes & tiling](/docs/panes) — splits, focus, resize, zoom, the terminal dock, and the browser pane.
- [Keybinds](/docs/keybinds) — every default and how to remap.
- [CLI reference](/docs/cli) — drive Verde from your shell with `verde live` and `verde state`.
- [Configuration & state](/docs/config) — `verde.json`, `verde.yml`, themes, Omarchy integration.
- [Troubleshooting](/docs/troubleshooting) — provider auth, browser runtime, source-build issues.
