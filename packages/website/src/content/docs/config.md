---
title: Configuration & state
description: verde.json settings, update and transcript preferences, verde.toml stacks, themes, state files, and runtime logs.
section: Reference
order: 8
slug: config
---

## verde.json

User config is loaded from `$XDG_CONFIG_HOME/verde/verde.json` or
`~/.config/verde/verde.json` on Linux/macOS, and
`%APPDATA%\Verde\verde.json` on Windows. `VERDE_CONFIG` can point to a custom
file. It is read on startup and on app refresh.

Point JSON language servers at the hosted schema so editors autocomplete and
validate keys:

```json
{
  "$schema": "https://verdeai.dev/config.schema.json"
}
```

The schema is published at [`https://verdeai.dev/config.schema.json`](https://verdeai.dev/config.schema.json).
Verde ignores `$schema` when loading config, and Settings saves leave the
pointer in place. VS Code, Zed, Helix, and Neovim's JSON LSP pick it up from
that field. You can also map the file globally:

```json
{
  "json.schemas": [
    {
      "fileMatch": ["**/verde/verde.json"],
      "url": "https://verdeai.dev/config.schema.json"
    }
  ]
}
```

A complete example:

```json
{
  "$schema": "https://verdeai.dev/config.schema.json",
  "theme": {
    "theme": "verde-dark",
    "colors": {
      "background": "#101820",
      "panel": "#151b24",
      "accent": "#50c878",
      "text": "#f0f0f5",
      "selection": "#58a6ff"
    }
  },
  "ui": {
    "font_size": 20,
    "workspace_pane_gap": 12,
    "workspace_panes_per_view": 1,
    "workspace_split_default_pane": "chat",
    "workspace_scroll_direction": "horizontal",
    "workspace_scroll_mode": "automatic",
    "workspace_scroll_threshold": 3,
    "unzoom_on_pane_navigation": false,
    "workspace_tabs": "automatic"
  },
  "open": {
    "default": "folder",
    "links": "verde_browser"
  },
  "browser": {
    "scroll_speed": 2.5
  },
  "terminal": {
    "font_size": 18,
    "profiles": [
      { "label": "Local Agent", "command": ["my-agent", "--interactive"] }
    ]
  },
  "transcript": {
    "tool_call_groups": "collapsed"
  },
  "chat": {
    "automatic_titles": true,
    "title_provider": "codex",
    "title_model": "gpt-6-luna",
    "default_provider": "codex",
    "default_model": "gpt-5.6-sol",
    "default_reasoning": "low",
    "favorite_models": [
      { "provider": "codex", "model": "gpt-5.6-sol" }
    ],
    "new_pane_behavior": "new_pane"
  },
  "updates": {
    "check_automatically": true
  },
  "notifications": {
    "enabled": true
  },
  "keybinds": {
    "new_thread": "CommandOrControl+T",
    "browser": "Ctrl+Shift+B",
    "workspace": {
      "focus_up": "Ctrl+K",
      "focus_down": "Ctrl+J",
      "focus_left": "Ctrl+H",
      "focus_right": "Ctrl+L",
      "pane_previous": "Ctrl+Shift+Tab",
      "pane_next": "Ctrl+Tab",
      "close": "Alt+X",
      "active_select": ["Ctrl+Shift+1", "Ctrl+Shift+2", "Ctrl+Shift+3", "Ctrl+Shift+4", "Ctrl+Shift+5", "Ctrl+Shift+6", "Ctrl+Shift+7", "Ctrl+Shift+8", "Ctrl+Shift+9", "Ctrl+Shift+0"],
      "pane_select": ["Ctrl+1", "Ctrl+2", "Ctrl+3", "Ctrl+4", "Ctrl+5", "Ctrl+6", "Ctrl+7", "Ctrl+8", "Ctrl+9", "Ctrl+0"],
      "previous": "Alt+Up",
      "next": "Alt+Down"
    }
  }
}
```

Keybinds are loaded on startup and on app refresh. Use a string for one
shortcut or a string array for multiple shortcuts. Use `null`, an empty string,
or an empty array to disable a binding. The `workspace.pane_select` and
`workspace.active_select` arrays are positional and follow the corresponding
sidebar lists in displayed order. `new_thread`, `settings`, `workspace.close`, and
`workspace.close_current` are unbound by default; prefix `x` / `Shift+X` still
close a pane or workspace when prefix mode is on. Prefix `x` on an empty
workspace closes that workspace too. The example above opts `close` back to
`Alt+X`. See [Keybinds](/docs/keybinds) for the full keybinds reference.

Most of these options also appear in Settings:

- **Appearance** — theme and UI font size.
- **Transcript** — tool-call groups: `collapsed`, `expanded`, or
  `remember_last`.
- **Chat** — generate concise chat titles automatically after the opening
  exchange and choose the provider and model used for titles.
- **Terminal** — font size, launch profiles, and whether terminal link clicks
  open in Verde's browser pane or the system browser.
- **Browser** — set embedded-page wheel speed from `1.0×` to `5.0×`; the
  default is `2.5×`.
- **Workspace** — choose `automatic`, `always`, or `disabled` scrolling layout,
  set the automatic activation threshold (1–64 panes), choose horizontal or
  vertical scrolling, control how many panes fit in one view and their gap,
  set the default open action for project files and folders, choose whether new
  chats create panes or replace an existing chat pane, and choose whether the
  unshifted prefix split keys create GUI chats or terminals. Mode and threshold
  can inherit these global values or be overridden for the currently selected
  workspace. Drag-resized column widths are also saved per workspace and take
  precedence over panes-per-view sizing until reset. `ui.workspace_pane_gap`
  also sets the outer margin for multi-pane scrolling views and the outer and
  internal spacing for tiled groups. A tiled scrolling group occupies the full
  viewport until only one pane remains; standalone and zoomed panes remain
  edge-to-edge. Pane navigation keeps the destination zoomed by default; set
  `ui.unzoom_on_pane_navigation` to `true` to restore on navigation instead.
- **Agent integrations** — status-pip hooks for supported provider CLIs.
- **Experimental features** — enable the Companion sidecar and Mission Control
  (off by default). **Appearance → Default companion** chooses Sprout, Moss, or
  Vireo when the companion is on.
- **Updates** — check now, install an available release, and automatic checks.
- **Notifications** — enable or disable desktop notifications when an agent
  finishes, waits for input, or errors.

Settings that write `verde.json` apply when you choose **Save**. Provider hook
installation/removal runs immediately because it updates the provider's own
configuration.

`browser.scroll_speed` accepts values from `1.0` through `5.0`. Older configs
using `browser.fast_scrolling` remain compatible: `true` maps to the `2.5×`
default and `false` maps to `1.0×`.

### Open actions

`open.default` controls the workspace header's primary open action. Supported
string values are `folder`, `editor`, `cursor`, `vscode`, and `zed`. `editor`
uses the configured system editor; the named values target that application
directly.

For another editor or workspace tool, use a custom action:

```json
{
  "open": {
    "default": {
      "label": "Workbench",
      "action": "my-editor ."
    },
    "links": "system_browser",
    "chat_links": "verde_browser",
    "terminal_links": "global"
  }
}
```

The custom command runs through the platform shell with the imported project
as its working directory. `open.links` accepts `verde_browser` or
`system_browser` and sets the global destination for web links. `open.chat_links`
and `open.terminal_links` optionally override it for GUI chat and terminal links;
each accepts `global`, `verde_browser`, or `system_browser`. New installations
default to `system_browser` when `open.links` is not configured.

## Chat titles

Automatic titles are enabled by default and run after the opening user and
assistant exchange completes. `chat.title_provider` accepts `codex`, `claude`,
`cursor`, or `opencode`; `chat.title_model` is the model reference understood
by that provider. The default is GPT-6 Luna from Codex / ChatGPT. A title
generation failure leaves Verde's prompt-derived fallback title unchanged.

## New chat defaults and favorite models

New GUI chats start with `chat.default_provider`, `chat.default_model`, and
`chat.default_reasoning`. Providers accept `codex`, `claude`, `cursor`,
`opencode`, `pi`, `fx`, or `grok`; reasoning accepts `default`, `low`,
`medium`, `high`, `xhigh`, or `max` when the chosen model supports it. These
values are also available under **Settings → Chat → New chat defaults**.

The model picker’s star tab shows only `chat.favorite_models`. Use the star on
any provider/model row to add or remove it; provider tabs continue to show the
full model list for that provider.

The workspace pencil button creates and focuses a new chat pane. With prefix
mode enabled, `Ctrl+B`, then `c` adds a new tab (chat by default). Set
`chat.new_pane_behavior` to `replace_pane`, or choose **Replace chat pane**
under **Settings → Workspace → New chat action**, to reuse an existing visible
chat pane instead.

## Updates

Automatic update checks are enabled by default. Disable them in Settings or
with:

```json
{
  "updates": {
    "check_automatically": false
  }
}
```

The Updates card shows the installed version and a wrapped release-note
preview. Use **Show more** to expand the notes in place or **Open release page**
for the complete GitHub release. You can also install the newest release
without opening Settings:

```bash
verde update
```

On Linux and macOS, restart Verde after the installer completes. AUR-managed
Linux installs open `yay` or `paru` in an interactive terminal pane. The
Windows updater exits the running app, installs the release, and relaunches it.

## Transcript preferences

`transcript.tool_call_groups` controls how consecutive transcript tool calls
open: `collapsed`, `expanded`, or `remember_last`. Failed groups open so their
error remains visible. With `remember_last`, Verde also maintains its internal
last-expanded state for the next group. See [Chat, models & runs](/docs/chat).

## verde.toml stack config

Project stack config is loaded from `verde.toml` in the workspace
root. `[processes.<name>]` and `[agents.<name>]` entries both run in terminal docks; agent
entries may also declare `provider` (`codex`, `claude`, `opencode`, `cursor`,
`grok`, `amp`, or `other`), `revive`, `notify`, `mcp`, and `hooks` metadata. New agent
metadata defaults to disabled unless explicitly set.

```toml
version = 1

[workspace]
default_folder = "app"

[folders.app]
path = "."

[folders.api]
path = "../api"

[processes.web]
command = "npm run dev"
cwd = "."
restart = "on_crash"

[agents.codex]
provider = "codex"
command = "codex"
cwd = "."
revive = "attach_or_create"
notify = true
mcp = true
hooks = true

[agents.grok]
provider = "grok"
command = "grok --no-auto-update --continue"
cwd = "."
revive = "attach_or_create"
```

Open **Workspace settings → Folders** to add existing directories, remove them,
or choose the default working folder. **Edit TOML** opens the manifest for renaming
folder aliases and editing paths. Relative paths resolve from `verde.toml`, not the
agent's current directory. Folder aliases use letters, numbers, hyphens, and
underscores (up to 64 characters); a workspace supports up to 32 active entries.

All native chats receive the folder map on each turn, including resumed and
Verde-delegated chats. Codex writable roots and Claude additional directories are
configured explicitly. OpenCode external-directory requests are approved only when
they resolve inside the configured roots; its other tool permissions are unchanged.
Other providers retain their native approval rules; Muse
Supervised mode cannot currently grant multiple writable roots and reports that
limitation. Full access is never enabled just by adding a folder. Relaunch existing
terminal agents after changing folders. Verde-launched Codex, Claude, and Pi TUIs
receive the directory context automatically.

New automatic workspace directories set `workspace.links = true`. Verde creates
named symlinks, `.verde/WORKSPACE.md`, and initial `AGENTS.md` / `CLAUDE.md` files.
Existing instruction files are preserved. Imported directories do not create links
unless you enable that option. A folder's original files and Git checkout remain
shared; removing it never deletes its files. Removal sets `enabled = false` in its
TOML table, retaining comments, and removes only unchanged links owned by Verde.
Disabled entries can be deleted manually or re-enabled in the manifest.

`workspace.default_folder` selects the working directory for chats following the workspace; omitting it (or
setting it to an empty string) uses the workspace home. Explicit per-thread working
directories take precedence. File mentions search all configured real roots.
Each repository retains its own Git history; run Git commands within that folder.

Only `verde.toml` is loaded. YAML stack files are no longer supported.

Use `[processes.<name>]` for normal long-running commands such as dev servers. Use
`[agents.<name>]` for terminal/TUI AI tools that should behave like first-class Verde
surfaces. With the Codex example above, Verde creates or reuses a terminal dock
for the agent and wires Codex hook events into pane/workspace attention. Plain
`codex` managed commands are launched with `features.hooks=true` when
`hooks = true` is set, so `PermissionRequest` can mark the surface `waiting` and
`Stop` can mark it `done`.

Use `grok --no-auto-update` for a fresh Grok session, `--continue` for the most
recent session in the workspace, or `--resume <session-id-or-title>` for a
specific session stored by Grok.

Start or restart a configured Codex agent with:

```bash
verde live agent open --provider codex
verde live process restart --name codex
```

Use `verde live agent open --provider codex` for the default Codex TUI flow; it
creates a managed terminal surface, applies Codex hook setup, and does not need
a `verde.toml` entry. Use `verde live process restart --name codex` when you want
to launch or restart the named agent declared in `verde.toml`. The same default
Codex TUI action is available from the workspace sidebar by right-clicking the
workspace new-thread/pencil button and choosing `Open Codex TUI`.

A Codex TUI opened manually in any Verde terminal still gets Verde identity
environment variables and can update the surface through `verde notify`, BEL,
OSC 777, or MCP, but it is not automatically a managed `verde.toml` agent unless
it is launched through the configured process entry.

## Themes

Verde ships three built-in palettes: **Verde Dark**, **Verde Light** and
**Verde Legacy** (the original Verde colors). Pick one, **Auto**, **Omarchy**, or
an installed theme from **Settings → Appearance → Theme**. Auto follows the
operating system's light/dark appearance and switches live when it changes; it
is the default on macOS, Windows and Linux without Omarchy. When an Omarchy
install is detected, the default is Omarchy and that entry appears in the
dropdown. The website's theme
gallery provides portable packages that import and activate in one command:

```bash
verde theme import https://verdeai.dev/themes/kanagawa.json
```

Imported themes remain in the same Settings dropdown after switching away.
You can also import a local JSON file or a GitHub file-page URL. Use
`verde theme validate <file-or-url>` to check a package without installing it,
and `verde theme export [file] --name "My theme"` to create a portable package
from the currently resolved colors.

To override individual theme tokens manually, edit `verde.json` under
`theme.colors`:

```json
{
  "theme": {
    "colors": {
      "background": "#101820",
      "panel": "#151b24",
      "accent": "#50c878",
      "text": "#f0f0f5",
      "selection": "#58a6ff"
    }
  }
}
```

`theme.theme` selects the base palette: `"auto"`, `"verde-dark"`,
`"verde-light"`, `"verde-legacy"`, or `"omarchy"`. Omit it to get the platform
default (Omarchy when installed, otherwise Auto). The older `"default"` and
`"verde"` values still work and mean Verde Legacy. `"omarchy"` falls back to
Auto on systems without Omarchy.

## Omarchy color auto-detection

With the Omarchy source, UI colors are loaded from an Omarchy-compatible
`colors.toml`. Verde honors the first found of:

1. `VERDE_OMARCHY_COLORS=/path/to/colors.toml`
2. `~/.local/state/omarchy/current/theme/colors.toml` (Omarchy Quattro)
3. `$XDG_CONFIG_HOME/omarchy/current/theme/colors.toml` (pre-Quattro fallback)
4. Named Omarchy themes such as `$XDG_CONFIG_HOME/omarchy/themes/verde/colors.toml`
   or `~/.config/omarchy/themes/verde/colors.toml`

Verde reads the current Omarchy (Quattro) keys (`background`,
`lighter_background`, `foreground`, `light_foreground`, `dark_foreground`,
`accent`, `selection`, `muted`, `red`, `green`, `yellow`) as well as the older
`color0`–`color8` and `selection_background` keys. A `[verde]` section, when
present, sets Verde's UI roles directly and wins over the mapped values; other
sections are ignored. Missing values fall back to Verde Legacy for dark themes
and Verde Light for `mode = "light"` themes. The
[`examples/omarchy/`](https://github.com/JonathanRiche/verde/tree/master/examples/omarchy)
folders contain installable Omarchy themes for Verde Dark, Verde Light and
Verde Legacy, including wallpapers.

## State files

App state is saved through SDL's pref path in `state.sqlite`. Discover the
exact path on your machine with:

```bash
verde state path --json
```

You can read projects, panes, threads, and transcripts offline:

```bash
verde state workspaces --json
verde state panes --project current --json
verde state threads --project current --json
verde state transcript --project current --thread 0 --json
```

See [CLI reference](/docs/cli) for the full state command surface.

## Logs

Verde writes runtime logs under SDL's platform pref path. Discover the exact
directory on your machine with `verde state path --json`. On Linux, the usual
paths are:

- `~/.local/share/verde/Native/logs/verde.stderr.log`
- `~/.local/share/verde/Native/logs/last-crash.log`

Those files capture Zig panic output, provider helper stderr, and the last
panic marker written before the app aborted. Tail the stderr log to diagnose
provider crashes, prompt-send failures, or rendering issues.

## Third-party components

Main third-party components used by the desktop app:

- `@anthropic-ai/claude-agent-sdk` for Claude Code provider integration.
- `fff.nvim` / `fff-c` / `fff-search` for fast file indexing and search, vendored in [`vendor/fff`](https://github.com/JonathanRiche/verde/tree/master/vendor/fff). License: MIT.
- Ghostty / `libghostty-vt` for terminal emulation and VT parsing. License: MIT.
- `zsdl` from `zig-gamedev` for Zig bindings to SDL3. License: MIT.
- SDL3 from libsdl-org for windowing, input, display integration, and rendering support.
- `zqlite` by Karl Seguin for SQLite access. License: MIT-style.
- `zig_dif` and `zig_markdown` for chat markdown and code rendering.
- `stb_image` by Sean Barrett and contributors for image decoding, vendored in [`vendor/stb_image.h`](https://github.com/JonathanRiche/verde/blob/master/vendor/stb_image.h). License: public domain or MIT.
- Codicon, Nerd Fonts, Noto Sans, JetBrains Mono Nerd Font, and Cal Sans font assets for the native UI. See notices in [`packages/desktop/src/assets/fonts`](https://github.com/JonathanRiche/verde/tree/master/packages/desktop/src/assets/fonts).

If you redistribute Verde, keep the relevant upstream notices and license
texts with the distributed app and any vendored source. Verde is licensed
under the MIT License — see [LICENSE](https://github.com/JonathanRiche/verde/blob/master/LICENSE).
