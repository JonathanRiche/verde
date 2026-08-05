---
title: Panes & tiling
description: How Verde's tiled workspace is laid out — splits, focus, resize, zoom, the sidebar, the terminal dock, and the embedded browser pane.
section: Workspace
order: 5
slug: panes
---

## Workspace anatomy

Each Verde window is one workspace tied to an imported project. Inside a
workspace you get a tiling tree of panes — chat threads, terminals, and a
browser pane — that share the main area. The sidebar on the left lists projects
and threads; the main area is the tiling surface; the terminal dock is a
terminal pane living in the same tree as chat and browser panes.

There is no floating-window layer. Everything is tiled, and the layout
persists across launches.

## Splitting panes

Splits come from two places: keyboard shortcuts for the common cases, and the
pane header buttons for everything else.

- `Ctrl+Shift+T` — split a terminal pane next to the focused workspace pane.
- `Ctrl+T` — start a new chat thread (creates a new chat pane).

For chat-vs-chat splits and terminal-vertical splits, use the pane header
buttons: `C|` and `C-` split a chat pane vertically or horizontally; `T|` and
`T-` do the same for terminals. Right-click terminal content for selection
copy, zoom, workspace splits around the focused pane, and **Close pane**.
Right-click a terminal tab to rename or close it. If `terminal.profiles` is
configured in `verde.json`, the first custom launch profile also appears in
the terminal context menu.

Use `Ctrl+Alt+T` for a new shell tab. Launch Codex, Claude, OpenCode, Cursor,
Grok, or Amp TUIs from the command palette; the built-in agent launchers are not
entries in the terminal right-click menu.

Terminal-internal tabs live inside the focused terminal pane. Workspace split
actions create new workspace panes in the tiling tree, not new tabs inside a
terminal.

## Moving focus

- `Ctrl+H / J / K / L` — focus the pane to the left / down / up / right
  (vim-style); `Ctrl+Arrow` provides the same four directions.
- Horizontal touchpad/wheel gestures pan a horizontal strip independently of
  focus. In vertical mode, hold `Ctrl` while using the vertical wheel so normal
  terminal and transcript scrolling remains available.
- `Tab` — while focused inside a chat thread pane, return focus to the prompt box.
- `Alt+1 … Alt+9, Alt+0` — jump between workspaces by sidebar order.
- `Alt+↑ / Alt+↓` — cycle to the previous / next workspace.

By default, Verde automatically switches to a scrolling strip when a workspace
reaches two tiled panes, keeping the same order shown in the sidebar. **Settings
→ Workspace → Scrolling layout** can keep that automatic behavior, pin the
scrolling layout with **Always**, or retain the split tree with **Disabled**.
**Activation threshold** changes the automatic trigger from 1–64 panes.
The command palette also exposes **Scrolling Layout: Automatic**, **Always**,
and **Disabled** for immediate policy changes without opening Settings.

**Scroll direction** chooses a horizontal strip (the default) or vertical
strip. **Panes per view** controls how many panes fit along that axis (1–6,
default 2), and **Pane spacing** controls their gap. Focus movement smoothly
reveals the next hidden pane, while manual strip scrolling can leave focus
off-screen. Horizontal and vertical positions are restored independently per
workspace; zoom temporarily fills the workspace without changing either saved
position or the selected scrolling policy.

## Resizing

- `Alt+Shift+← ↑ ↓ →` — grow the focused pane in that direction.
- Drag the divider between two workspace panes to resize the split manually.

Resizes are committed to the layout immediately and persist with the workspace.

## Rearranging panes

- `Ctrl+Shift+H / J / K / L` — move the focused pane past its neighbor in that direction.
- `Ctrl`-drag a pane — pick it up with the mouse and drop it where it should go.

Use these when the layout is right but a pane is in the wrong place. Moves are
non-destructive — every pane keeps its content and provider.

## Zooming and closing

- `Alt+Z` — zoom the focused pane to fill the workspace; press again to restore.
- Pane context menu — close the pane (or `Ctrl+W` / `Alt+X`).

## The sidebar

The left rail shows projects, threads under each project, and the active pane
in each workspace. Each pane row carries its provider glyph and a live title,
so you always know what is working without switching to it.

- `Ctrl+S` — toggle the sidebar (visible ↔ icon rail).
- `Ctrl+Shift+S` — toggle the sidebar's hidden mode (no rail at all).

When collapsed to the icon rail, each workspace avatar carries a row of small
**status pips** — one dot per open pane, in layout order. Pips pulse green
while an agent is working, yellow while it waits for input, and settle when
it's done or errors, so you can watch several agents from a rail a few pixels
wide. Context menus (new thread, close, expand) still work from the collapsed
rail.

Right-click the sidebar for project import, rename, and **Close workspace**, and
use the new-thread / pencil button to open a Codex TUI directly. Closing a
workspace archives it without deleting its saved panes, threads, or layout.
Use the command palette's reopen action—or `verde live workspace reopen`—to
restore it.

## The terminal dock

Verde's embedded terminals are powered by Ghostty's `libghostty-vt` terminal
engine. Each terminal pane is a full terminal with tabs, splits, OSC titles,
scrollback with a scrollbar, and per-terminal zoom.

- `Ctrl+Alt+T` — new terminal tab inside the focused terminal pane.
- `Ctrl+Shift+R` — rename the active terminal tab.
- `Ctrl+Shift+PageUp` / `Ctrl+Shift+PageDown` — previous / next terminal tab.
- `Ctrl+Alt+↑ ↓ ← →` — move focus between terminal splits inside the focused terminal pane.
- `Ctrl+-` / `Ctrl+=` — per-terminal zoom; restored with the terminal layout.

Per-terminal zoom is independent of the workspace-level zoom (`Alt+Z`). It
persists per terminal surface, not per workspace.

Terminal applications can render Kitty graphics-protocol images inline. The
image follows terminal scrolling and is cleared when the application erases or
replaces it, like other terminal content.

## The browser pane

Press `Ctrl+Shift+B` to toggle the embedded browser pane next to the focused chat.
The backend is the host platform's native webview: WPE WebKit on Linux,
WKWebView on macOS, WebView2 on Windows. No bundled Chromium.

You can drive the browser pane from the CLI:

```bash
verde live browser open --url https://example.com
verde live browser navigate --url https://example.com/dashboard
verde live browser eval --script "document.title"
verde live browser screenshot --json
verde live browser status --json
```

The inspector button enters **Design Mode**, where you can select an element or
draw a region and send its context to a chat or terminal agent. See
[Design Mode](/docs/design-mode) for selection modes, routing, and screenshot
support, and [CLI reference](/docs/cli) for the full browser command surface.

## Persisting layouts

Workspace layouts, per-terminal zoom, terminal tab state, and the browser
pane's URL all persist across launches in Verde's SQLite state. Closing the
app and reopening it restores the same tiling tree for each project. Closing a
workspace from the sidebar or with `Ctrl+Shift+W` also preserves that state;
reopen the workspace from the command palette when you need it again.

You can inspect the persisted layout without launching the app:

```bash
verde state panes --project current --json
```

And the live layout while the app is running:

```bash
verde live panes --project current --json
```

## Command palette and slash commands

`Ctrl+Shift+P` opens the command palette — a single ranked list of threads, panes,
workspaces, and app commands. `Ctrl+Enter` on a thread result opens it in a
fresh pane. The palette also carries **Start New … TUI** entries for Codex, Claude,
OpenCode, Cursor, Grok, and Amp, and **Open Current Thread in TUI** entries that
promote a GUI chat thread into that provider's terminal TUI.

The sidebar's **History · N** row opens the same palette scoped to one
workspace's saved threads. Thread actions include open in a new pane, sync from
the provider, open as a TUI or chat, and archive. Workspace actions also import
existing Codex, OpenCode, and Claude Code threads. See
[Chat, models & runs](/docs/chat#history-and-provider-threads) for the complete
workflow and current provider limitations.

Typing `/` in the composer opens a slash-command picker. Running a command
shows a pending row in the transcript while it executes, then a result card
(`/usage` renders a structured card with limit bars and recent daily usage).

Workspace commands, available with every provider:

- `/stack` — start / stop / restart / status for every process and agent declared in the workspace's `verde.yml`.
- `/process` — start / stop / restart / focus a single declared process by name; `/process crashed` refreshes status and reports the number of crashed processes.
- `//text` — escape hatch: send a literal prompt that begins with a slash.

Provider-native commands surface in the same picker:

- **Claude Code** — `/usage`, `/compact [instructions]`, plus skill commands such as `/code-review`, `/debug`, `/loop`, `/batch`, and `/skills`.
- **Codex** — `/usage`, `/compact`, `/goal [status|clear|…]`, `/review [changes|base <branch>|commit <sha>|custom …]`, and `/shell confirm <command>` (requires typed confirmation).
- **OpenCode / Cursor** — no native slash commands yet; `/stack`, `/process`, and `//` still work.
