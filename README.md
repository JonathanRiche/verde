# verde

`verde` is a desktop GUI for coding agents. It currently supports Codex, Claude Code, OpenCode, and Cursor.

The desktop app lives in [`packages/desktop/`](packages/desktop). Verde's UI is built with [`palette`](packages/palette), our own Zig GUI framework package for native UI primitives and render-batch driven desktop rendering.

<img width="2560" height="1080" alt="image" src="https://github.com/user-attachments/assets/252b51ed-2780-4362-b3d5-afdf72e5087d" />

## Getting Started

Verde talks to provider runtimes on your machine rather than bundling its own hosted backend. Install and authenticate at least one provider before using the app:

- Codex: install [Codex CLI](https://github.com/openai/codex) and run `codex login`.
- Claude Code: install [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and log in on your machine. Verde uses Anthropic's Claude Agent SDK to talk to the local Claude Code runtime.
- OpenCode: install [OpenCode](https://github.com/anomalyco/opencode) and make sure `opencode` is on your `PATH`.
- Cursor: set `CURSOR_API_KEY` in the environment used to launch Verde. The Cursor provider uses `@cursor/sdk`, which requires this API key.

Cursor example:

```bash
export CURSOR_API_KEY=...
verde
```

## Install

Install the latest release from the website:

```bash
curl -fsSL https://openverde.ai/install.sh | sh
```

Or download a release from [GitHub Releases](https://github.com/JonathanRiche/verde/releases).

- Linux: download `verde-<version>-linux-x86_64.tar.gz`, extract it, then run `./install-local.sh`.
- macOS: download the `.dmg` or `.zip` for your architecture, then move `Verde.app` into `Applications`.
- Arch Linux: install [`verde-bin`](https://aur.archlinux.org/packages/verde-bin) from the AUR.

Verde can also be installed through the platform-specific npm launcher:

```bash
npx verde-app
npm install -g verde-app
verde
```

The npm package is intended for macOS Apple Silicon, macOS Intel, and Linux x86_64 developer machines.

## Source Builds

Source builds require Zig `0.16.0`, SDL3 development files, and OpenGL development libraries for your platform.

For release-style local installs, use the packaged install scripts:

```bash
bash ./scripts/release/install-linux-local-cef.sh
./scripts/release/install-macos-local.sh
```

The macOS installer downloads and bundles the matching CEF runtime by default. To use an existing CEF SDK cache, set `VERDE_CEF_SDK_PATH`. To build a no-CEF app bundle for faster local iteration, set `VERDE_CEF_DISABLE_DOWNLOAD=1`.

## Development

Use [`mise`](https://mise.jdx.dev/) from the repo root. The repo pins Zig and ZLS to `0.16.0` in [`mise.toml`](mise.toml).

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

## Provider Notes

- Codex threads use the local `codex` CLI and start `codex app-server` automatically when needed.
- Claude Code threads use Anthropic's Claude Agent SDK and require Claude Code to be installed and logged in locally.
- OpenCode threads use the local `opencode` CLI and can start `opencode serve` automatically when needed.
- Cursor threads use `@cursor/sdk` and require `CURSOR_API_KEY`.
- Providers run against the project directory you import into Verde.

If prompt sending fails, first check that the selected provider is installed, available to Verde's launch environment, and authenticated.

## Embedded Terminal

Verde includes a project-scoped embedded terminal dock powered by Ghostty's `libghostty-vt` terminal engine.

- Toggle it with `CommandOrControl+J`.
- It starts in the selected project's working directory.
- Per-terminal zoom works with `Ctrl+-` and `Ctrl+=` while the terminal is focused.

## Config And State

- App state is saved through SDL's pref path in `state.sqlite`.
- User config is loaded from `$XDG_CONFIG_HOME/verde/verde.json` or `~/.config/verde/verde.json`.

Example config:

```json
{
  "ui": {
    "font_size": 20
  },
  "keybinds": {
    "refresh": ["CommandOrControl+R", "F5"],
    "sidebar": "CommandOrControl+S",
    "browser": "Ctrl+B",
    "terminal": {
      "toggle": "CommandOrControl+J",
      "new_tab": "CommandOrControl+Shift+T",
      "close": "CommandOrControl+Shift+W",
      "rename_tab": "CommandOrControl+Shift+R",
      "tab_previous": "CommandOrControl+Shift+PageUp",
      "tab_next": "CommandOrControl+Shift+PageDown",
      "split_up": "CommandOrControl+Shift+Up",
      "split_down": ["CommandOrControl+Shift+E", "CommandOrControl+Shift+Down"],
      "split_left": "CommandOrControl+Shift+Left",
      "split_right": ["CommandOrControl+Shift+O", "CommandOrControl+Shift+Right"],
      "focus_up": "CommandOrControl+Alt+Up",
      "focus_down": "CommandOrControl+Alt+Down",
      "focus_left": "CommandOrControl+Alt+Left",
      "focus_right": "CommandOrControl+Alt+Right"
    }
  }
}
```

Keybinds are loaded on startup and app refresh. Use a string for one shortcut or a string array for multiple shortcuts.

## Logs

On Linux, Verde writes runtime logs under SDL's pref path:

- `~/.local/share/verde/Native/logs/verde.stderr.log`
- `~/.local/share/verde/Native/logs/last-crash.log`

Those files capture Zig panic output, provider helper stderr, and the last panic marker written before the app aborted.

## Third-Party Components

Main third-party components used by the desktop app:

- `@cursor/sdk` for Cursor provider integration.
- `@anthropic-ai/claude-agent-sdk` for Claude Code provider integration.
- `fff.nvim` / `fff-c` / `fff-search` for fast file indexing and search, vendored in [`vendor/fff`](vendor/fff). License: MIT.
- Ghostty / `libghostty-vt` for terminal emulation and VT parsing. License: MIT.
- `zsdl` from `zig-gamedev` for Zig bindings to SDL3. License: MIT.
- SDL3 from libsdl-org for windowing, input, display integration, and rendering support.
- `zqlite` by Karl Seguin for SQLite access. License: MIT-style.
- `zig_dif` and `zig_markdown` for chat markdown and code rendering.
- `stb_image` by Sean Barrett and contributors for image decoding, vendored in [`vendor/stb_image.h`](vendor/stb_image.h). License: public domain or MIT.
- Codicon, Nerd Fonts, Noto Sans, JetBrains Mono Nerd Font, and Cal Sans font assets for the native UI. See notices in [`packages/desktop/src/assets/fonts`](packages/desktop/src/assets/fonts).

If you redistribute Verde, keep the relevant upstream notices and license texts with the distributed app and any vendored source.

## License

Verde is licensed under the MIT License. See [LICENSE](LICENSE).
