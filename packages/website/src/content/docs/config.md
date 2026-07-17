---
title: Configuration & state
description: verde.json user config, verde.yml stack config, theme tokens, Omarchy color auto-detection, state files, and runtime logs.
section: Reference
order: 6
slug: config
---

## verde.json

User config is loaded from `$XDG_CONFIG_HOME/verde/verde.json` or
`~/.config/verde/verde.json`. It is read on startup and on app refresh.

```json
{
  "theme": {
    "theme": "default",
    "colors": {
      "background": "#101820",
      "panel": "#151b24",
      "accent": "#50c878",
      "text": "#f0f0f5",
      "selection": "#58a6ff"
    }
  },
  "ui": {
    "font_size": 20
  },
  "terminal": {
    "font_size": 18,
    "profiles": [
      { "label": "Local Agent", "command": ["my-agent", "--interactive"] }
    ]
  },
  "keybinds": {
    "new_thread": "CommandOrControl+T",
    "browser": "Ctrl+B",
    "workspace": {
      "focus_up": "Ctrl+K",
      "focus_down": "Ctrl+J",
      "focus_left": "Ctrl+H",
      "focus_right": "Ctrl+L",
      "previous": "Alt+Up",
      "next": "Alt+Down"
    }
  }
}
```

Keybinds are loaded on startup and on app refresh. Use a string for one
shortcut or a string array for multiple shortcuts. Use `null`, an empty string,
or an empty array to disable a binding. See [Keybinds](/docs/keybinds) for the
full keybinds reference.

## verde.yml stack config

Project stack config is loaded from `verde.yml` or `verde.yaml` in the workspace
root. `processes:` and `agents:` entries both run in terminal docks; agent
entries may also declare `provider` (`codex`, `claude`, `opencode`, `cursor`,
`amp`, or `other`), `revive`, `notify`, `mcp`, and `hooks` metadata. New agent
metadata defaults to disabled unless explicitly set.

```yaml
processes:
  web:
    command: "npm run dev"
    cwd: "."
    restart: on_crash

agents:
  codex:
    provider: codex
    command: "codex"
    cwd: "."
    revive: attach_or_create
    notify: true
    mcp: true
    hooks: true
```

Use `processes:` for normal long-running commands such as dev servers. Use
`agents:` for terminal/TUI AI tools that should behave like first-class Verde
surfaces. With the Codex example above, Verde creates or reuses a terminal dock
for the agent and wires Codex hook events into pane/workspace attention. Plain
`codex` managed commands are launched with `features.codex_hooks=true` when
`hooks: true` is set, so `PermissionRequest` can mark the surface `waiting` and
`Stop` can mark it `done`.

Start or restart a configured Codex agent with:

```bash
verde live agent open --provider codex
verde live process restart --name codex
```

Use `verde live agent open --provider codex` for the default Codex TUI flow; it
creates a managed terminal surface, applies Codex hook setup, and does not need
a `verde.yml` entry. Use `verde live process restart --name codex` when you want
to launch or restart the named agent declared in `verde.yml`. The same default
Codex TUI action is available from the workspace sidebar by right-clicking the
workspace new-thread/pencil button and choosing `Open Codex TUI`.

A Codex TUI opened manually in any Verde terminal still gets Verde identity
environment variables and can update the surface through `verde notify`, BEL,
OSC 777, or MCP, but it is not automatically a managed `verde.yml` agent unless
it is launched through the configured process entry.

## Themes

Verde ships a warm-green native theme out of the box. Choose Verde, Omarchy, or
an installed theme from **Settings → Appearance → Theme**. The website's theme
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

Omit `theme.theme` to keep Omarchy auto-detection (see below), or set it to
`"default"` to start from Verde's built-in colors.

## Omarchy color auto-detection

On Omarchy systems, UI colors are loaded from an Omarchy-compatible
`colors.toml`. Verde honors the first found of:

1. `VERDE_OMARCHY_COLORS=/path/to/colors.toml`
2. `$XDG_CONFIG_HOME/omarchy/current/theme/colors.toml`
3. Named Omarchy themes such as `$XDG_CONFIG_HOME/omarchy/themes/verde/colors.toml`
   or `~/.config/omarchy/themes/verde/colors.toml`

Missing values fall back to Verde defaults. See
[`examples/omarchy/verde/colors.toml`](https://github.com/JonathanRiche/verde/blob/master/examples/omarchy/verde/colors.toml)
for the shape.

## State files

App state is saved through SDL's pref path in `state.sqlite`. Discover the
exact path on your machine with:

```bash
verde state path --json
```

You can read projects, panes, threads, and transcripts offline:

```bash
verde state projects --json
verde state panes --project current --json
verde state threads --project current --json
verde state transcript --project current --thread 0 --json
```

See [CLI reference](/docs/cli) for the full state command surface.

## Logs

On Linux, Verde writes runtime logs under SDL's pref path:

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
