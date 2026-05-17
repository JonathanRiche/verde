# `verde` Desktop

This package contains Verde's standalone Zig desktop app. It uses SDL3, SDL_GPU, and [`palette`](../palette), Verde's in-repo Zig GUI framework.

## Prerequisites

- Zig `0.16.0` through the repo-root [`mise.toml`](../../mise.toml)
- SDL3 development files for your platform
- Provider setup for the providers you want to use:
  - Codex: `codex` on your `PATH` and `codex login`
  - Claude Code: Claude Code installed and logged in locally; Verde talks to it through Anthropic's Claude Agent SDK
  - OpenCode: `opencode` on your `PATH`
  - Cursor: `CURSOR_API_KEY` set in the environment used to launch Verde

## Development

Run development tasks from the repo root with `mise`:

```bash
mise install
mise run setup
mise run dev
```

Common tasks:

- `mise run setup`: downloads the CEF SDK into the local build cache.
- `mise run dev`: builds and runs Verde from the repo-local Zig build output.
- `mise run run`: builds and launches Verde in development mode.
- `mise run debug`: launches Verde with the in-app diagnostics window enabled.
- `mise run build`: creates a local release-style build for the current platform.
- `mise run dev-sdl-gpu`: runs with the SDL_GPU Palette renderer.

### Hyprland UI Polish Checks

For chat UI readability or DPI polish work, run Verde from the repo root and capture comparison screenshots into `goal_samples/`:

```bash
mise run dev
hyprctl clients -j
grim -g "$(slurp)" goal_samples/chat-after.png
```

Use the same approximate window size for before/after captures. For fractional-scale checks, adjust your Hyprland monitor scale, restart `mise run dev`, then capture another image such as `goal_samples/chat-after-1-25x.png`.

## CEF Browser Pane

The in-app browser pane uses CEF when a CEF SDK is available. The `mise` tasks and release install scripts use the repo's CEF helper scripts so developers do not need to pass CEF build flags manually.

Useful environment variables:

- `VERDE_CEF_SDK_PATH`: use a specific cached CEF SDK.
- `VERDE_CEF_DISABLE_DOWNLOAD=1`: skip the CEF download and build without CEF for faster local iteration.
- `VERDE_OPEN_BROWSER_ON_START=1`: smoke-test the browser pane during startup.

Keep the CEF SDK in a persistent directory such as `$HOME/.cache/verde/cef-sdk`; do not keep it under `/tmp`.

## Embedded Terminal

The desktop shell includes embedded terminal panes powered by Ghostty's `libghostty-vt`.

- Create a terminal pane with `CommandOrControl+Shift+T`.
- Move between workspace panes with `Alt+Arrow` or `Ctrl+H/J/K/L`.
- It starts in the selected project's directory.
- `Ctrl+-` and `Ctrl+=` adjust only the terminal font scale while the terminal is focused.

Use `mise run debug` when you need the diagnostics window for focus, input-routing, or terminal hitbox debugging.

## Providers

The desktop app talks to local provider runtimes rather than a hosted Verde backend.

- Codex uses the local `codex` CLI and starts `codex app-server` automatically when needed.
- Claude Code uses Anthropic's Claude Agent SDK and requires Claude Code to be installed and logged in on your machine.
- OpenCode uses the local `opencode` CLI and can start `opencode serve` automatically when needed.
- Cursor uses `@cursor/sdk` and requires `CURSOR_API_KEY`.

Requests run against the project directory selected in Verde. If prompt sending fails, check that the selected provider is installed, available to Verde's launch environment, and authenticated.

## State And Config

App state is stored through SDL's pref path in `state.sqlite`. User config is loaded from:

- `$XDG_CONFIG_HOME/verde/verde.json`
- `~/.config/verde/verde.json`

Config supports UI and terminal font size, keybind overrides, and the default action behind the main `Open` button plus `Alt+O`.

```json
{
  "ui": {
    "font_size": 20
  },
  "terminal": {
    "font_size": 18
  },
  "open": {
    "default": "editor"
  },
  "keybinds": {
    "refresh": ["CommandOrControl+R", "F5"],
    "open": "Alt+O",
    "new_thread": "CommandOrControl+T",
    "sidebar": "CommandOrControl+S",
    "sidebar_hidden": "Alt+B",
    "browser": "Ctrl+B",
    "workspace": {
      "split_terminal_horizontal": "CommandOrControl+Shift+T",
      "focus_up": ["Alt+Up", "Ctrl+K"],
      "focus_down": ["Alt+Down", "Ctrl+J"],
      "focus_left": ["Alt+Left", "Ctrl+H"],
      "focus_right": ["Alt+Right", "Ctrl+L"],
      "close": ["CommandOrControl+W", "Alt+X"]
    },
    "terminal": {
      "toggle": null,
      "new_tab": "CommandOrControl+Alt+T",
      "close": "CommandOrControl+Shift+W",
      "rename_tab": "CommandOrControl+Shift+R",
      "tab_previous": "CommandOrControl+Shift+PageUp",
      "tab_next": "CommandOrControl+Shift+PageDown",
      "split_up": null,
      "split_down": null,
      "split_left": null,
      "split_right": null,
      "focus_up": "CommandOrControl+Alt+Up",
      "focus_down": "CommandOrControl+Alt+Down",
      "focus_left": "CommandOrControl+Alt+Left",
      "focus_right": "CommandOrControl+Alt+Right"
    }
  }
}
```

Keybind values can be a string, a string array, `null`, an empty string, or an empty array. `null` and empty values disable that binding.

`open.default` accepts `folder`, `editor`, `cursor`, `vscode`, `zed`, or a custom shell action:

```json
{
  "open": {
    "default": {
      "label": "Workbench",
      "action": "cursor ."
    }
  }
}
```

Custom actions run through `sh -lc` with the selected project as the working directory. The command also receives the project path as `$1`.

## Key Files

- [`src/main.zig`](src/main.zig): app entrypoint, window/UI shell, provider controls
- [`src/state.zig`](src/state.zig): app state, persistence, projects, threads
- [`src/harness.zig`](src/harness.zig): provider-neutral interface
- [`src/providers/codex.zig`](src/providers/codex.zig): Codex integration
- [`src/providers/opencode.zig`](src/providers/opencode.zig): OpenCode integration
- [`src/providers/claude.zig`](src/providers/claude.zig): Claude Code integration
- [`src/providers/cursor.zig`](src/providers/cursor.zig): Cursor integration
- [`src/config.zig`](src/config.zig): user config loading
- [`src/keybinds.zig`](src/keybinds.zig): keyboard shortcut parsing and overrides

## Dependencies

Third-party Zig dependencies are declared in [`build.zig.zon`](build.zig.zon):

- `palette`
- `zsdl`
- `zqlite`
- `zig_dif`
- `zig_markdown`
- `ghostty`

The repo also uses `@anthropic-ai/claude-agent-sdk` and `@cursor/sdk` from the root npm package for Claude Code and Cursor provider integration.

## Third-Party Attribution

Main upstream components used by the desktop app:

- `@cursor/sdk` for Cursor provider integration.
- `@anthropic-ai/claude-agent-sdk` for Claude Code provider integration.
- `fff.nvim` / `fff-c` / `fff-search` for project-scoped file indexing and composer file search, vendored in [`../../vendor/fff`](../../vendor/fff). License: MIT.
- Ghostty / `libghostty-vt` for terminal emulation and VT parsing. License: MIT.
- `zsdl` from `zig-gamedev` for Zig bindings to SDL3. License: MIT.
- SDL3 from libsdl-org for window creation, events, monitor/display integration, and rendering support.
- `zqlite` by Karl Seguin for SQLite-backed state and persistence. License: MIT-style.
- `zig_dif` and `zig_markdown` for chat markdown and code rendering.
- `stb_image` by Sean Barrett and contributors for image decoding, vendored in [`../../vendor/stb_image.h`](../../vendor/stb_image.h). License: public domain or MIT.
- Codicon, Nerd Fonts, Noto Sans, JetBrains Mono Nerd Font, and Cal Sans font assets for the native UI. See notices in [`src/assets/fonts`](src/assets/fonts).

When distributing the desktop app, keep the applicable upstream licenses and notices for vendored or bundled components.
