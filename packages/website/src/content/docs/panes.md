---
title: Panes & tiling
description: How Verde's tiled workspace is laid out — splits, focus, resize, zoom, the sidebar, the terminal dock, and the embedded browser pane.
section: Workspace
order: 3
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
`T-` do the same for terminals. Right-click inside a terminal pane to spawn
shell tabs or agent launch-profile tabs (Claude, OpenCode, Codex, Cursor), or
to add a new workspace terminal pane around the focused one.

Terminal-internal tabs live inside the focused terminal pane. Workspace split
actions create new workspace panes in the tiling tree, not new tabs inside a
terminal.

## Moving focus

- `Ctrl+H / J / K / L` — focus the pane to the left / down / up / right (vim-style).
- `Alt+← ↑ ↓ →` — same idea, arrow keys instead.
- `Tab` — while focused inside a chat thread pane, return focus to the prompt box.
- `Alt+1 … Alt+9, Alt+0` — jump between workspaces by sidebar order.

## Resizing

- `Alt+Shift+← ↑ ↓ →` — grow the focused pane in that direction.
- Drag the divider between two workspace panes to resize the split manually.

Resizes are committed to the layout immediately and persist with the workspace.

## Swapping panes

- `Ctrl+Shift+H / J / K / L` — swap the focused pane with its neighbor in that direction.

Use swap when the layout is right but the wrong pane is in the wrong place.
Swap is non-destructive — both panes keep their content and provider.

## Zooming and minimizing

- `Alt+Z` — zoom the focused pane to fill the workspace; press again to restore.
- Pane header button — minimize the pane into the restore strip; click to bring it back.
- Pane header button — close the pane (or `Ctrl+W` / `Alt+X`).

## The sidebar

The left rail shows projects, threads under each project, and the active pane
in each workspace. Each pane row carries its provider glyph and a live title,
so you always know what is working without switching to it.

- `Ctrl+S` — toggle the sidebar (visible ↔ icon rail).
- `Ctrl+Shift+S` — toggle the sidebar's hidden mode (no rail at all).

Right-click the sidebar for project import, rename, archive, and the new-thread
/ pencil button for opening a Codex TUI directly.

## The terminal dock

Verde's embedded terminals are powered by Ghostty's `libghostty-vt` terminal
engine. Each terminal pane is a full terminal with tabs, splits, OSC titles,
and per-terminal zoom.

- `Ctrl+Alt+T` — new terminal tab inside the focused terminal pane.
- `Ctrl+Shift+W` — close the active terminal tab.
- `Ctrl+Shift+R` — rename the active terminal tab.
- `Ctrl+Shift+PageUp` / `Ctrl+Shift+PageDown` — previous / next terminal tab.
- `Ctrl+Alt+↑ ↓ ← →` — move focus between terminal splits inside the focused terminal pane.
- `Ctrl+-` / `Ctrl+=` — per-terminal zoom; restored with the terminal layout.

Per-terminal zoom is independent of the workspace-level zoom (`Alt+Z`). It
persists per terminal surface, not per workspace.

## The browser pane

Press `Ctrl+B` to toggle the embedded browser pane next to the focused chat.
The backend is the host platform's native webview: WPE WebKit on Linux,
WKWebView on macOS, WebView2 on Windows. No bundled Chromium.

You can drive the browser pane from the CLI:

```bash
verde live browser open --url https://example.com
verde live browser navigate --url https://example.com/dashboard
verde live browser eval --script "document.title"
verde live browser status --json
```

See [CLI reference](/docs/cli) for the full browser command surface.

## Persisting layouts

Workspace layouts, per-terminal zoom, terminal tab state, and the browser
pane's URL all persist across launches in Verde's SQLite state. Closing the
app and reopening it restores the same tiling tree for each project.

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
workspaces, and app commands. `Ctrl+Enter` on any result opens it in a fresh
pane. Slash commands run from the composer:

- `/stack` — start / stop / restart every process and agent declared in the workspace's `verde.yml`.
- `/process` — control a single declared process by name.

Each provider also exposes its own slash commands inside the composer
alongside `/stack` and `/process`.
