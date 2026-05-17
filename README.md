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

Source builds require Zig `0.16.0` and SDL3 development files for your platform.

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

## CLI And Live Control

`verde` is both the desktop launcher and a CLI for reading persisted state or
controlling a running desktop app. CLI-only commands run before SDL startup, so
they can be used from scripts without opening a window.

Top-level commands:

```bash
verde                         # Launch the desktop app
verde app                     # Launch the desktop app explicitly
verde --help                  # Show CLI help
verde version [--json]        # Print version metadata
verde capabilities [--json]   # Print supported CLI/live features
verde completion <shell>      # Print shell completion script
verde state <command>         # Read persisted state while the app is closed
verde live <command>          # Control or inspect the running app
```

Use `--json` when scripting. Live IPC responses use a stable envelope:

```json
{
  "id": 1,
  "ok": true,
  "result": {}
}
```

Errors return `ok: false` with an `error.code` and `error.message`.

### Shell Completion

`verde completion` prints static completion scripts for the supported shells.
The generated completions cover command names, nested live-control commands,
flags, and fixed flag values such as `--kind chat|terminal`,
`--axis horizontal|vertical`, and `--decision approve|deny`.

```bash
verde completion bash
verde completion zsh
verde completion fish
```

Common install patterns:

```bash
# bash
verde completion bash > ~/.local/share/bash-completion/completions/verde

# zsh
mkdir -p ~/.zfunc
verde completion zsh > ~/.zfunc/_verde
# Ensure ~/.zfunc is in fpath before compinit, for example:
# fpath=(~/.zfunc $fpath)

# fish
verde completion fish > ~/.config/fish/completions/verde.fish
```

The first completion slice is intentionally static so tab completion stays fast
and never depends on the desktop app being open. Dynamic project, pane, process,
and thread completions can be layered on top of this later.

### Offline State Commands

State commands read Verde's persisted SQLite state and do not require the app to
be running.

```bash
verde state path [--json]
verde state projects [--json]
verde state panes --project <id|index|path|current> [--json]
verde state threads --project <id|index|path|current> [--json]
verde state transcript --project <id|index|path|current> --thread <index|provider-id> [--json]
```

- `path` prints the SDL pref path and `state.sqlite` location.
- `projects` lists imported projects and the selected project.
- `panes` prints the saved workspace layout and terminal dock state for a
  project.
- `threads` lists saved chat threads for a project.
- `transcript` prints one saved chat transcript by thread index or provider
  thread id.

### Live Discovery Commands

Live commands talk to the running desktop app over a current-user Unix socket at
Verde's SDL pref path. Start the app normally first, for example with `verde` or
from source with `mise run dev`.

```bash
verde live capabilities [--json]
verde live status [--json]
verde live projects [--json]
verde live active [--json]
verde live panes [--project <id|index|path|current>] [--json]
verde live threads [--project <id|index|path|current>] [--json]
verde live terminals [--project <id|index|path|current>] [--json]
verde live processes [--json]
verde live inspect --pane <pane-id> [--project <id|index|path|current>] [--json]
verde live inspect --focused [--json]
```

- `capabilities` prints the live method list without requiring the app to be
  running.
- `status` returns protocol version, app pid, selected project, focused pane,
  current pane graph, and terminal/process summary.
- `projects` lists live projects.
- `active` returns the current project and focused pane.
- `panes`, `threads`, and `terminals` inspect one project.
- `processes` returns the terminal-pane process graph currently available to
  Verde.
- `inspect` returns details for a specific pane or the focused pane.

### Pane Control

Workspace panes are the primary live-control target. Most commands return the
updated pane graph so scripts can keep using the returned pane IDs.

```bash
verde live pane focus --pane <pane-id> [--project <id|index|path|current>] [--json]
verde live pane focus --focused [--json]
verde live pane split --pane <pane-id> --kind chat --axis horizontal [--json]
verde live pane split --pane <pane-id> --kind terminal --axis vertical [--json]
verde live pane resize --pane <pane-id> --first <pane-id> --second <pane-id> --axis horizontal --ratio 0.6 [--json]
verde live pane minimize --pane <pane-id> [--json]
verde live pane maximize --pane <pane-id> [--json]
verde live pane restore --pane <pane-id> [--json]
verde live pane close --pane <pane-id> [--json]
```

- `split` creates a chat or terminal workspace pane next to the target pane.
  `--kind` accepts `chat` or `terminal`; `--axis` accepts `horizontal` or
  `vertical`.
- `resize` updates the split ratio between two sibling panes. `--ratio` is a
  floating-point value such as `0.6`.
- `minimize`, `maximize`, `restore`, and `close` match the pane header actions
  in the UI.

### Chat Control

Chat commands resolve the target pane to its backing chat thread. They use the
same draft, composer, send, stop, and approval paths as the UI.

```bash
verde live chat status --pane <pane-id> [--json]
verde live chat status --focused [--json]
verde live chat transcript --pane <pane-id> [--json]
verde live chat draft set --pane <pane-id> --text "explain this failure" [--json]
verde live chat draft append --pane <pane-id> --text "more detail" [--json]
verde live chat send --pane <pane-id> --prompt "run the tests and fix failures" [--json]
verde live chat send --pane <pane-id> "run the tests and fix failures" [--json]
verde live chat followup --pane <pane-id> --prompt "then update docs" [--json]
verde live chat stop --pane <pane-id> [--json]
verde live chat approve --pane <pane-id> --decision approve [--json]
verde live chat approve --pane <pane-id> --decision deny [--json]
```

- `status` returns thread title, provider, model, message count, send state, and
  pending approval status.
- `transcript` returns persisted messages for the pane's thread.
- `draft set` replaces the current draft; `draft append` appends to it.
- `send` sends `--prompt`, `--text`, or a trailing prompt argument. If no prompt
  is supplied, it sends the current draft.
- `followup` queues or steers a prompt while a send is active.
- `stop` aborts the current send for that chat thread.
- `approve` resolves the current pending approval. `--decision` accepts
  `approve` or `deny`; `--call <id>` is accepted for future call-id targeting.

### Terminal And Process Control

Terminal commands resolve the target workspace pane to its terminal dock and
write through the same active PTY input path as the UI.

```bash
verde live terminal write --pane <pane-id> --text $'cargo test\r' [--json]
verde live terminal write --focused --text $'printf "ok\\n"\r' [--json]
verde live process inspect --pane <pane-id> [--json]
verde live process inspect --focused [--json]
```

- `terminal write` sends text to the active terminal tab/pane. Include `\r` when
  you want to submit a shell command.
- `process inspect` currently returns the same pane/terminal details as
  `inspect` for a terminal pane. Process spawn, restart, and rename are reserved
  for a later slice.

### Selectors And Exit Codes

- Use `--pane <id>` for deterministic automation.
- Use `--focused` for interactive smoke tests.
- Use `--project current` for the selected project, or pass a project index, id,
  or path.
- Chat commands require a chat pane. Terminal commands require a terminal pane.
- Exit `0` means the CLI command parsed and, for live commands, received a live
  response. Scripts should still check the JSON envelope's `ok` field.
- Exit `1` means command failure before a structured live response, `2` invalid
  arguments, `3` live server not running, and `4` offline state target not
  found.
- Live IPC request failures return JSON error codes such as `not_found`,
  `invalid_request`, `invalid_target`, `rejected`, `unsupported`, or
  `method_not_found`.

## Provider Notes

- Codex threads use the local `codex` CLI and start `codex app-server` automatically when needed.
- Claude Code threads use Anthropic's Claude Agent SDK and require Claude Code to be installed and logged in locally.
- OpenCode threads use the local `opencode` CLI and can start `opencode serve` automatically when needed.
- Cursor threads use `@cursor/sdk` and require `CURSOR_API_KEY`.
- Providers run against the project directory you import into Verde.

If prompt sending fails, first check that the selected provider is installed, available to Verde's launch environment, and authenticated.

## Embedded Terminal

Verde includes embedded terminal panes powered by Ghostty's `libghostty-vt` terminal engine.

- Create a new chat thread with `CommandOrControl+T`, or split a terminal pane below the focused workspace pane with `CommandOrControl+Shift+T`.
- Move between workspace panes with `Alt+Arrow` or `Ctrl+H/J/K/L`.
- Workspace pane headers can split chat or terminal panes vertically (`C|`, `T|`) or horizontally (`C-`, `T-`), maximize or restore a pane, minimize it into the restore strip, or close it.
- Drag the divider between workspace panes to resize the split.
- Right-click inside a terminal pane to create normal shell tabs, launch-profile tabs for Claude, OpenCode, Codex, and Cursor, or new workspace terminal panes around the focused pane.
- Terminal-internal tabs remain inside the focused terminal pane. Terminal split actions create workspace terminal panes.
- Per-terminal zoom works with `Ctrl+-` and `Ctrl+=` while the terminal is focused, and the chosen zoom is restored with the terminal layout.

## Config And State

- App state is saved through SDL's pref path in `state.sqlite`.
- User config is loaded from `$XDG_CONFIG_HOME/verde/verde.json` or `~/.config/verde/verde.json`.

Example config:

```json
{
  "ui": {
    "font_size": 20
  },
  "terminal": {
    "font_size": 18,
    "profiles": [
      {
        "label": "Local Agent",
        "command": ["my-agent", "--interactive"]
      }
    ]
  },
  "keybinds": {
    "refresh": ["CommandOrControl+R", "F5"],
    "new_thread": "CommandOrControl+T",
    "sidebar": "CommandOrControl+S",
    "sidebar_hidden": "Alt+B",
    "browser": "Ctrl+B",
    "workspace": {
      "split_chat_vertical": "CommandOrControl+Alt+C",
      "split_chat_horizontal": "CommandOrControl+Alt+Shift+C",
      "split_terminal_vertical": "CommandOrControl+Alt+J",
      "split_terminal_horizontal": "CommandOrControl+Shift+T",
      "focus_up": ["Alt+Up", "Ctrl+K"],
      "focus_down": ["Alt+Down", "Ctrl+J"],
      "focus_left": ["Alt+Left", "Ctrl+H"],
      "focus_right": ["Alt+Right", "Ctrl+L"],
      "toggle_maximize": "CommandOrControl+Alt+M",
      "minimize": "CommandOrControl+Alt+Minus"
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

Keybinds are loaded on startup and app refresh. Use a string for one shortcut or a string array for multiple shortcuts. Use `null`, an empty string, or an empty array to disable a binding.

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
