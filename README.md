# verde

`verde` is a desktop GUI for coding agents. It currently supports Codex, Claude Code, OpenCode, and Cursor.

The desktop app lives in [`packages/desktop/`](packages/desktop). Verde's UI is built with [`palette`](packages/palette), our own Zig GUI framework package for native UI primitives and render-batch driven desktop rendering.

<img width="2536" height="1030" alt="image" src="https://github.com/user-attachments/assets/397a7d76-98c0-4258-9827-61aa329a99df" />

## Getting Started

Verde talks to provider runtimes on your machine rather than bundling its own hosted backend. Install and authenticate at least one provider before using the app:

- Codex: install [Codex CLI](https://github.com/openai/codex) and run `codex login`.
- Claude Code: install [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and log in on your machine. Verde uses Anthropic's Claude Agent SDK to talk to the local Claude Code runtime.
- OpenCode: install [OpenCode](https://github.com/anomalyco/opencode) and make sure `opencode` is on your `PATH`.
- Cursor: install the [Cursor CLI](https://cursor.com/docs/cli/installation), make sure `agent` is on your `PATH`, and run `agent login`. `CURSOR_API_KEY` is also supported for headless environments.

Cursor example:

```bash
agent login
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

Linux browser support uses the system WPE WebKit runtime. AUR installs it as a
package dependency; tarball installs will warn if required WPE libraries are
missing.

Verde can also be installed through the platform-specific npm launcher:

```bash
npx verde-app
npm install -g verde-app
verde
```

The npm package is intended for macOS Apple Silicon, macOS Intel, and Linux x86_64 developer machines.

## Source Builds

Source builds require Zig `0.16.0` and SDL3 development files for your platform.
The default browser backend uses the host platform webview instead of bundled
Chromium. Linux builds also require WPE WebKit development
packages. Windows native-webview builds require the Microsoft WebView2 SDK
headers at compile time and `WebView2Loader.dll` next to `verde.exe` or on the
DLL search path.

For release-style local installs, use the packaged install scripts:

```bash
bash ./scripts/release/install-linux-local.sh
./scripts/release/install-macos-local.sh
```

Source builds use the native webview backend by default and do not download CEF.
CEF is still available as an explicit fallback:

```bash
mise run build-cef
# or
zig build --release=safe -Dbrowser-backend=cef -Dcef-sdk-path=/path/to/cef
```

The native browser runtime targets the host platform webview stack: WPE WebKit on
Linux, WKWebView on macOS, and WebView2 on Windows. Linux requires WPE WebKit
runtime packages. Windows systems that do not include WebView2 need the
Microsoft WebView2 Runtime installed separately, and packaged builds must ship
or locate `WebView2Loader.dll`.

## Development

Use [`mise`](https://mise.jdx.dev/) from the repo root. The repo pins Zig and ZLS to `0.16.0` in [`mise.toml`](mise.toml).

```bash
mise install
mise run setup
mise run dev
```

Common tasks:

- `mise run setup`: checks desktop build dependencies.
- `mise run dev`: builds and runs Verde with the native webview backend.
- `mise run run`: builds and launches Verde in development mode.
- `mise run debug`: launches Verde with the in-app diagnostics window enabled.
- `mise run build`: creates a local release-style build for the current platform.
- `mise run check-mac-webview`: on macOS, rebuilds/installs the WKWebView app and runs automated package/runtime readiness checks, including Swift/CEF-free packaging and native-keyboard ownership guards.
- `mise run mac-webview-manual-signoff`: on macOS, runs the guided foreground physical-input signoff flow and writes a timestamped evidence run.
- `mise run check-mac-webview-manual`: on macOS, checks the latest timestamped physical-input evidence run required for final WKWebView signoff.
- `mise run dev-cef`: builds and runs Verde with the legacy CEF backend.
- `mise run build-cef`: creates a release-style build with the legacy CEF backend.
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
verde live browser eval --script "document.title" [--json]
verde live browser post-json --json-payload '{"type":"ping"}' [--json]
```

- `capabilities` prints the live method list without requiring the app to be
  running.
- `status` returns protocol version, app pid, selected project, focused pane,
  current pane graph, terminal/process summary, and browser runtime state,
  including backend kind, presentation kind, initialized/visible state, URL,
  last browser error, last bridge message, and last eval result.
- `projects` lists live projects.
- `active` returns the current project and focused pane.
- `panes`, `threads`, and `terminals` inspect one project.
- `processes` returns the terminal-pane process graph currently available to
  Verde.
- `inspect` returns details for a specific pane or the focused pane.

### Browser Control

Browser commands require the browser pane to be visible. They route through the
same backend-neutral browser contract used by the Palette toolbar and inspector.

```bash
verde live browser eval --script "JSON.stringify({title:document.title,url:location.href})" [--json]
verde live browser post-json --json-payload '{"type":"ping"}' [--json]
```

- `eval` queues JavaScript evaluation in the active browser runtime; inspect
  `verde live status --json` for `browser.last_eval_result`.
- `post-json` sends a JSON payload through the host-to-page bridge.
- Page-to-host bridge messages are processed only for app and loopback pages by
  default: `app://`, `localhost`, `127.0.0.1`, and `[::1]`. Set
  `VERDE_BROWSER_ALLOW_UNTRUSTED_BRIDGE=1` only for local diagnostics that need
  arbitrary pages or `data:` URLs to call back into Verde.

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
- Cursor threads use the local Cursor CLI ACP server (`agent acp`) and require `agent login` or `CURSOR_API_KEY`.
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
      "minimize": "CommandOrControl+Alt+Minus",
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

Keybinds are loaded on startup and app refresh. Use a string for one shortcut or a string array for multiple shortcuts. Use `null`, an empty string, or an empty array to disable a binding.

## Logs

On Linux, Verde writes runtime logs under SDL's pref path:

- `~/.local/share/verde/Native/logs/verde.stderr.log`
- `~/.local/share/verde/Native/logs/last-crash.log`

Those files capture Zig panic output, provider helper stderr, and the last panic marker written before the app aborted.

## Third-Party Components

Main third-party components used by the desktop app:

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
