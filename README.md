# verde

`verde` is a tiling desktop workspace for AI coding agents. It runs Codex, Claude Code, OpenCode, and Cursor side by side in one native window — tile chat, terminal, and browser panes with vim-style keybinds, jump anywhere from a `Ctrl+Shift+P` command palette, and drive long-running project processes from chat. Verde talks to the provider CLIs already installed on your machine; there is no hosted relay, so your tokens, transcripts, and project files stay local.

The desktop app lives in [`packages/desktop/`](packages/desktop). Verde's UI is built with [`palette`](packages/palette), our own Zig GUI framework package for native UI primitives and render-batch driven desktop rendering.

<img width="2536" height="1030" alt="ristretto_verde" src="https://github.com/user-attachments/assets/a4e7d21c-006f-4ff4-87a1-3bfd30b9ae94" />


## Features

- **Every agent, one window.** Run Codex, Claude Code, OpenCode, and Cursor as tiled chat threads side by side.
- **A real tiling workspace.** Split chat, terminal, and browser panes, then rearrange, resize, zoom, and persist layouts with vim-style keybinds.
- **Command palette (`Ctrl+Shift+P`).** A launcher that ranks chat threads, open panes, workspaces, and app commands in one searchable list.
- **Embedded browser pane.** A native webview (WPE WebKit on Linux, WKWebView on macOS, WebView2 on Windows) tiled next to your agent.
- **Project-scoped terminal dock.** Ghostty-powered terminals with shell tabs and agent launch-profile tabs that persist with the layout.
- **Managed workspace processes.** Declare dev servers or workers in `verde.yml` and control them from chat with the `/stack` and `/process` slash commands.
- **Local-first.** No hosted inference and no relay; Verde drives the provider CLIs already on your machine.
- **Scriptable.** Every running instance exposes per-user local control through
  `verde live` (Windows named pipes or Unix sockets); `verde state` inspects the
  persisted state without launching the app.
- **Native, not Electron.** A Zig + SDL3 app built on Verde's own Palette UI framework.

## Getting Started

Verde talks to provider runtimes on your machine rather than bundling its own hosted backend. Install and authenticate at least one provider before using the app:

- Codex: install [Codex CLI](https://github.com/openai/codex) and run `codex login`.
- Claude Code: install [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and log in on your machine. Verde uses Anthropic's Claude Agent SDK to talk to the local Claude Code runtime.
- OpenCode: install [OpenCode](https://github.com/anomalyco/opencode) and make sure `opencode` is on your `PATH`.
- Cursor: install the [Cursor CLI](https://cursor.com/docs/cli/installation), make sure `agent` is on your `PATH`, and run `agent login`. `CURSOR_API_KEY` is also supported for headless environments.

## Install

On Linux or macOS, install the latest release from the website:

```bash
curl -fsSL https://verdeai.dev/install.sh | sh
```

On Windows x64, open PowerShell and run:

```powershell
irm https://verdeai.dev/install.ps1 | iex
```

The Windows installer downloads and verifies the latest package, installs it
for the current user, adds a Start Menu shortcut, and launches Verde. It does
not require administrator access.

Or download a release from [GitHub Releases](https://github.com/JonathanRiche/verde/releases).

- Linux: download `verde-v<version>-linux-x86_64.tar.gz`, extract it, then run `./install-local.sh`.
- macOS: download the `.dmg` or `.zip` for your architecture, then move `Verde.app` into `Applications`.
- Windows x64 preview: download `verde-v<version>-windows-x86_64.zip` and its
  adjacent `.sha256` file. Verify and extract the ZIP, then run the included
  `install.ps1`. The script copies the complete package to
  `%LOCALAPPDATA%\Programs\Verde` and creates a Start Menu shortcut; it does not
  require administrator access.
- Arch Linux: install [`verde-bin`](https://aur.archlinux.org/packages/verde-bin) from the AUR.

```bash
yay -S verde-bin
```

For a manual Windows install, open Windows PowerShell in the download directory
and run:

```powershell
$zip = Get-Item .\verde-v*-windows-x86_64.zip
$expected = ((Get-Content "$($zip.FullName).sha256" -Raw) -split '\s+')[0]
$actual = (Get-FileHash $zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected.ToLowerInvariant()) { throw "ZIP checksum mismatch" }
Expand-Archive $zip.FullName -DestinationPath '.\Verde' -Force
$root = Get-ChildItem '.\Verde' -Directory | Select-Object -First 1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'install.ps1')
```

Launch **Verde** from the Start Menu afterward. The GUI executable is
`%LOCALAPPDATA%\Programs\Verde\app\Verde.exe`; the console CLI is
`%LOCALAPPDATA%\Programs\Verde\bin\verde.exe` and is not automatically added to
`PATH`. The package also contains adjacent runtime DLLs, so do not copy either
EXE out of its directory or run it from inside Explorer's compressed-folder
view. You can run `app\Verde.exe` directly from the extracted tree for a
portable test without installing it.

Check `WINDOWS-SIGNING.json` inside the extracted package for its signing
state. If the release is unsigned, Windows may show an unknown-publisher or
SmartScreen warning; verify the adjacent `.sha256` file before choosing
**More info → Run anyway**.

The Windows preview requires the Microsoft Edge WebView2 Evergreen Runtime;
the packaged `WebView2Loader.dll` is only its application loader. Verde live
control and persistent-terminal control use current-logon Windows named pipes,
not TCP, and do not need a firewall exception. Codex app-server and OpenCode do
open provider-local listeners, bound by default to `127.0.0.1` (`4500` and
`4096` respectively). Do not expose those listeners on `0.0.0.0` or add a
public/LAN inbound rule. If Windows Defender Firewall, a third-party firewall,
or enterprise policy blocks loopback traffic, allow only the relevant provider
executable's local-loopback traffic as policy permits, or ask the administrator.

Linux browser support uses the system WPE WebKit runtime. AUR installs it as a
package dependency; tarball installs will warn if required WPE libraries are
missing. On Arch-based systems, install `wpewebkit` and `wpebackend-fdo`; on
Debian 13+ systems, install `libwpewebkit-2.0-1`, `libwpebackend-fdo-1.0-1`,
`libjavascriptcoregtk-6.0-1`, `libegl1`, and `libgles2`.

## Source Builds

Source builds require Zig `0.16.0` and SDL3 development files for your platform.
The default browser backend uses the host platform webview instead of bundled
Chromium. Linux builds also require WPE WebKit development
packages. Windows native-webview builds require the Microsoft WebView2 SDK
headers at compile time and `WebView2Loader.dll` next to `verde.exe` or on the
DLL search path.

From Arch/Linux, `mise run build-windows` cross-builds the pinned
`x86_64-windows-gnu` lane after validating the Rust target and
`cargo-zigbuild`. On Windows, `scripts\dev\build-windows.ps1` builds the native
MSVC lane. Both use `scripts/windows-dependencies.json` and the deterministic
bootstrap cache instead of discovering arbitrary system SDK copies.

Building the native MSVC lane on Windows additionally requires:

- **Visual Studio Build Tools with the Windows SDK**, with the build run from a
  Developer shell (`vcvars64.bat`) so `INCLUDE` exposes the SDK's `winrt`
  headers. The WebView2 C++ layer includes `wrl.h`, which Zig does not locate on
  its own; without the Developer environment the build fails with
  `'wrl.h' file not found`.
- **LLVM** on `PATH` (or `LIBCLANG_PATH` pointing at its `bin`); the vendored
  `fff` crate's `bindgen` build step loads `libclang.dll`. Without it the build
  fails with "Unable to find libclang".
- Rust `1.95.0` with the `x86_64-pc-windows-msvc` target, Bun, and Node 18+.

Run `scripts\dev\build-windows.ps1` from a Developer Command Prompt (or a `cmd`
shell that has called `vcvars64.bat`). Windows PowerShell 5.1 can misreport a
successful build by treating tool stderr as a fatal error, so prefer `cmd` or
PowerShell 7.

For release-style local installs, use the packaged install scripts:

```bash
bash ./scripts/release/install-linux-local.sh
./scripts/release/install-macos-local.sh
```

Source builds use the native webview backend by default.

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
- `mise run check-mac-webview`: on macOS, rebuilds/installs the WKWebView app and runs automated package/runtime readiness checks, including Swift packaging and native-keyboard ownership guards.
- `mise run mac-webview-manual-signoff`: on macOS, runs the guided foreground physical-input signoff flow and writes a timestamped evidence run.
- `mise run check-mac-webview-manual`: on macOS, checks the latest timestamped physical-input evidence run required for final WKWebView signoff.
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
verde update [--json]         # Install the latest Verde release
verde capabilities [--json]   # Print supported CLI/live features
verde open <url> [--json]     # Open a URL in this Verde workspace's browser pane
verde completion <shell>      # Print shell completion script
verde state <command>         # Read persisted state while the app is closed
verde notify [options]        # Update the current terminal surface
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
verde live surfaces [--json]
verde live processes [--json]
verde live inspect --pane <pane-id> [--project <id|index|path|current>] [--json]
verde live inspect --focused [--json]
verde live browser status [--json]
verde live browser open --url https://example.com [--project <id|index|path|current|self>] [--json]
verde live browser navigate --url https://example.com [--json]
verde live browser eval --script "document.title" [--json]
verde live browser screenshot [--json]
verde live browser post-json --json-payload '{"type":"ping"}' [--json]
verde live palette list [--json]
verde live palette run --command pane.split_terminal_down [--json]
verde live workspace select --project <id|index|path|current> [--json]
verde live workspace create --path /path/to/project [--json]
verde live workspace rename --project <id|index|path|current> --label "New name" [--json]
verde live workspace archive --project <id|index|path|current> [--json]
verde live chat open --workspace <id|index|path> --provider cursor [--model <id>] [--json]
```

- `capabilities` prints the live method list without requiring the app to be
  running.
- `status` returns protocol version, app pid, selected project, focused pane,
  current pane graph, terminal/process summary, and browser runtime state,
  including backend kind, presentation kind, initialized/visible state, URL,
  last browser error, last bridge message, and last eval result.
- `projects` lists live projects.
- `active` returns the current project and focused pane.
- `surfaces` lists in-memory terminal surface status and attention metadata.

### Terminal Surface Notifications

Verde terminal children receive identity variables such as `VERDE=1`,
`VERDE_SESSION_ID`, `VERDE_WORKSPACE_ID`, `VERDE_WORKSPACE_PATH`,
`VERDE_DOCK_ID`, `VERDE_PANE_ID`, `VERDE_SOCKET`,
`VERDE_LIVE_ENDPOINT`, `VERDE_LIVE_SOCKET`, `VERDE_SESSIONIZER_SOCKET`, and
`VERDE_CLI`. `VERDE_LIVE_ENDPOINT` is the transport-neutral live-control
address: a named-pipe name on Windows and a Unix-socket path elsewhere.
`VERDE_LIVE_SOCKET` remains a Unix compatibility alias.
Terminal tools can use those variables to update their pane surface:

```bash
verde notify --title "Codex needs input" --body "Approve command?" --status waiting
verde notify --status working --progress 0.4 --label "Running tests"
verde notify --status done --title "Agent finished"
verde notify --clear
```

`verde notify` infers `--session` from `VERDE_SESSION_ID`; scripts can pass
`--session`, `--workspace`, `--dock`, or `--pane` explicitly. If the desktop app
is not running, `verde notify --quiet` exits without launching Verde or showing
an OS notification.

Provider hook integrations are intentionally opt-in and conservative:

```bash
verde integrations list
verde integrations doctor
verde integrations install codex
verde integrations install claude
verde integrations install cursor
```

`verde integrations` reports hook support without touching provider auth.
Codex, Claude, and Cursor support project-local and `--global` hook installers.
Cursor's `.cursor/hooks.json` format is shared by Cursor Agent's terminal and
desktop Agent UIs; Verde status updates remain a no-op unless that Cursor
session inherited a Verde pane identity. On Windows the generated scripts use
`.ps1`; Unix hosts use `.sh` scripts. Verde merges Cursor hooks without
replacing unrelated user entries and refuses to replace unmanaged Claude/Codex
project settings. Amp supports its global plugin; OpenCode remains usable as a
chat provider without a managed hook installer. The generic `verde notify`,
OSC notification, and MCP surface paths remain available for terminal tools.

Windows hook commands invoke the generated script with Windows PowerShell using
`-NoProfile -NonInteractive -ExecutionPolicy Bypass -File`. `Bypass` applies
only to that child PowerShell process; Verde does not change the user's or
machine's saved execution policy. Domain Group Policy, AppLocker, WDAC, or
endpoint security can still block the unsigned generated script. Inspect the
script before enabling hooks, and if policy blocks it, leave the optional hook
disabled or ask the administrator rather than weakening machine policy.

- `panes`, `threads`, and `terminals` inspect one project.
- `processes` returns the terminal-pane process graph currently available to
  Verde.
- `inspect` returns details for a specific pane or the focused pane.

### Palette Control

Palette commands act on the currently selected desktop workspace, matching what
the user could run from the command palette UI.

```bash
verde live palette list [--json]
verde live palette run --command pane.split_terminal_down [--json]
```

- `list` returns every stable static command-palette id with title, section, and
  current enabled state.
- `run` invokes one enabled command by stable id. Disabled commands return a
  `rejected` live error; unknown ids return `not_found`.

### Browser Control

`verde open <url>` is shorthand for `verde live browser open --url <url>`.
When run inside a Verde terminal pane, browser open defaults to that terminal's
workspace by resolving `VERDE_WORKSPACE_ID`; outside Verde it defaults to the
currently selected desktop workspace. The browser is a singleton runtime: opening
it in another workspace moves the browser pane there.

Browser commands route through the same backend-neutral browser contract used by
the Palette toolbar and inspector. Commands other than `open` and `status`
require the browser runtime to be visible somewhere.

```bash
verde open https://example.com [--json]
verde live browser status [--json]
verde live browser open --url https://example.com [--project <id|index|path|current|self>] [--json]
verde live browser navigate --url https://ziglang.org [--json]
verde live browser eval --script "JSON.stringify({title:document.title,url:location.href})" [--json]
verde live browser screenshot [--json]
verde live browser post-json --json-payload '{"type":"ping"}' [--json]
```

- `status` returns browser visibility, suspension, URL, lifecycle status, and
  the workspace/pane currently hosting the singleton browser.
- `open` ensures a browser pane exists in the target workspace and optionally
  navigates it without switching the selected workspace or focusing the URL bar.
- `navigate` normalizes and loads a URL in the active singleton browser runtime.
- `eval` queues JavaScript evaluation in the active browser runtime; inspect
  `verde live status --json` for `browser.last_eval_result`.
- `screenshot` stores and returns the visible viewport as PNG data when the
  active browser presentation exposes a CPU-side frame. Native child-view
  backends currently return `unsupported`.
- `post-json` sends a JSON payload through the host-to-page bridge.
- Page-to-host bridge messages are processed only for app and loopback pages by
  default: `app://`, `localhost`, `127.0.0.1`, and `[::1]`. Set
  `VERDE_BROWSER_ALLOW_UNTRUSTED_BRIDGE=1` only for local diagnostics that need
  arbitrary pages or `data:` URLs to call back into Verde.

Managed agents receive the browser through Verde's MCP bridge. Browser tools
open and navigate the pane, inspect visible text and interactive elements,
click or type by CSS selector, and return screenshots as MCP image content.
Potentially sensitive clicks, password entry, and form submission require an
explicit confirmed retry so the agent client can ask the user first.

The MCP bridge also advertises `open_chat`. It requires `workspace_id` and one
of the native GUI providers (`opencode`, `codex`, `claude`, or `cursor`), with
optional `model`, `target_pane_id`, `axis`, and `focus` arguments. This is
separate from terminal/TUI agent opening and never requires compositor or mouse
automation.

Workspace command coordination is available through `list_processes`,
`check_command`, `acquire_lease`, `release_lease`, and `wait_for_process`.
The process registry combines configured processes, each dock's currently
active terminal command, GUI agent turns, and background tasks. Coordination
clients can declare explicit resources such as `build`, `deps`, `db`, or
`port:3000`; leases expire automatically so a crashed owner cannot permanently
block the workspace.

### Workspace Control

Workspace commands mutate the project rail and return the updated workspace
list.

```bash
verde live workspace select --project <id|index|path|current> [--json]
verde live workspace create --path /path/to/project [--json]
verde live workspace rename --project <id|index|path|current> --label "New name" [--json]
verde live workspace archive --project <id|index|path|current> [--json]
```

- `create` resolves `~` and relative paths the same way as the workspace import
  modal, and restores an archived workspace if the path was archived.
- `select`, `rename`, and `archive` accept `--project` or `--workspace` using
  id, index, path, or `current`.

### Pane Control

Workspace panes are the primary live-control target. Most commands return the
updated pane graph so scripts can keep using the returned pane IDs.

```bash
verde live pane focus --pane <pane-id> [--project <id|index|path|current>] [--json]
verde live pane focus --focused [--json]
verde live pane split --pane <pane-id> --kind chat --axis horizontal [--json]
verde live pane split --pane <pane-id> --kind terminal --axis vertical [--json]
verde live pane resize --pane <pane-id> --first <pane-id> --second <pane-id> --axis horizontal --ratio 0.6 [--json]
verde live pane move --pane <pane-id> --direction left|right|up|down [--json]
verde live pane maximize --pane <pane-id> [--json]
verde live pane close --pane <pane-id> [--json]
```

- `split` creates a chat or terminal workspace pane next to the target pane.
  `--kind` accepts `chat` or `terminal`; `--axis` accepts `horizontal` or
  `vertical`.
- `resize` updates the split ratio between two sibling panes. `--ratio` is a
  floating-point value such as `0.6`.
- `move` swaps the target pane with the adjacent structural pane in the given
  direction, matching the keyboard move action.
- `maximize` and `close` match the pane actions in the UI.

### Chat Control

Chat commands resolve the target pane to its backing chat thread. They use the
same draft, composer, send, stop, and approval paths as the UI.

```bash
verde live chat open --workspace <id|index|path> --provider opencode|codex|claude|cursor [--model <id>] [--pane <pane-id>] [--axis horizontal|vertical] [--no-focus] [--json]
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

- `open` atomically creates a fresh native GUI thread and chat pane in the
  explicitly supplied workspace. It validates the provider/model combination
  before changing the workspace, defaults to the provider's current model and
  the workspace's focused pane, and focuses the new workspace/pane unless
  `--no-focus` is passed. The result includes stable `workspace_id`, `pane_id`,
  `thread_id`, `provider`, and `model` fields.
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
verde live process list [--project <id|index|path|current>] [--json]
verde live process start --name <name> [--project <id|index|path|current>] [--json]
verde live process stop --name <name> [--project <id|index|path|current>] [--json]
verde live process restart --name <name> [--project <id|index|path|current>] [--json]
verde live process inspect --name <name> [--project <id|index|path|current>] [--json]
verde live process logs --name <name> [--project <id|index|path|current>] [--json]
verde live agent open --provider codex [--project <id|index|path|current>] [--json]
verde live stack start [--project <id|index|path|current>] [--json]
verde live stack stop [--project <id|index|path|current>] [--json]
verde live stack restart [--project <id|index|path|current>] [--json]
```

- `terminal write` sends text to the active terminal tab/pane. Include `\r` when
  you want to submit a shell command.
- `process start`, `stop`, and `restart` control entries loaded from
  `verde.yml`.
- `agent open --provider codex` opens a first-class Codex TUI in the selected
  workspace without requiring a `verde.yml` entry.
- `stack start`, `stop`, and `restart` apply the same action to every configured
  process and agent in the selected workspace.

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

- Open the command palette with `Ctrl+Shift+P` to search chat threads, jump to open panes, switch workspaces, or run an app command. `Ctrl+Enter` opens a thread in a new pane.
- In a chat composer, run slash commands such as `/stack` and `/process` to control configured workspace processes, alongside each provider's own slash commands.
- Create a new chat thread with `CommandOrControl+T`, or split a terminal pane below the focused workspace pane with `CommandOrControl+Shift+T`.
- Switch workspaces by sidebar order with `Alt+1` through `Alt+9`, and `Alt+0` for the tenth workspace.
- Move between workspace panes with `Alt+Arrow` or `Ctrl+H/J/K/L`.
- Move the focused workspace pane by swapping it with the adjacent pane using `Ctrl+Shift+H/J/K/L`.
- In a focused chat thread pane, press `Tab` to return keyboard focus to the prompt box.
- Workspace pane headers can split chat or terminal panes vertically (`C|`, `T|`) or horizontally (`C-`, `T-`), zoom or unzoom a pane, or close it.
- Drag the divider between workspace panes to resize the split.
- Right-click inside a terminal pane to create normal shell tabs, launch-profile tabs for Claude, OpenCode, Codex, and Cursor, or new workspace terminal panes around the focused pane.
- Terminal-internal tabs remain inside the focused terminal pane. Terminal split actions create workspace terminal panes.
- Per-terminal zoom works with `Ctrl+-` and `Ctrl+=` while the terminal is focused, and the chosen zoom is restored with the terminal layout.

## Config And State

- App state is saved through SDL's pref path in `state.sqlite`.
- User config is loaded from `$XDG_CONFIG_HOME/verde/verde.json` or `~/.config/verde/verde.json` on Unix, and `%APPDATA%\Verde\verde.json` on Windows. `VERDE_CONFIG` overrides either location.
- Project stack config is loaded from `verde.yml` or `verde.yaml` in the workspace root. `processes:` and `agents:` entries both run in terminal docks; agent entries may also declare `provider`, `revive`, `notify`, `mcp`, and `hooks` metadata. New agent metadata defaults to disabled unless explicitly set.
- On Omarchy systems, UI colors are loaded from an Omarchy-compatible `colors.toml`. Verde first honors `VERDE_OMARCHY_COLORS=/path/to/colors.toml`, then `$XDG_CONFIG_HOME/omarchy/current/theme/colors.toml`, then named Omarchy themes such as `$XDG_CONFIG_HOME/omarchy/themes/verde/colors.toml` or `~/.config/omarchy/themes/verde/colors.toml`. Missing values fall back to Verde defaults. See [`examples/omarchy/verde/colors.toml`](examples/omarchy/verde/colors.toml).
- `theme.colors` in `verde.json` can override Verde theme tokens. Omit `theme.theme` to keep Omarchy auto-detection, or set it to `"default"` to start from Verde's built-in colors.

Example project stack config:

```yaml
processes:
  web:
    command: "npm run dev"
    command_windows: "npm.cmd run dev"
    cwd: "."
    restart: on_crash
    resources:
      - "port:3000"

  worker:
    # Structured argv bypasses the local shell and preserves spaces exactly.
    argv:
      - "node"
      - "scripts/worker task.mjs"
      - "--label=client repo"

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
`codex` managed commands are launched with `features.hooks=true` when
`hooks: true` is set, so `PermissionRequest` can mark the surface `waiting` and
`Stop` can mark it `done`. Add `resources:` to either kind when the command owns
shared output, dependencies, a database, or a fixed server port; these values
are used by workspace conflict checks in addition to conservative command
classification.

For portable stacks, prefer `argv:` when the executable and arguments are the
same on every platform. Use `command_windows:` and `command_unix:` only when a
shell command genuinely differs; these override `command:` on their platform.
`argv_windows:` and `argv_unix:` provide the same override for structured
arguments. A legacy `command:` keeps its existing `/bin/sh -lc` behavior on
Unix. On Windows it runs in PowerShell 7 when available, then Windows
PowerShell; Bash syntax is never silently sent to `cmd.exe`. Managed terminal
processes are owned as a process tree (a Job Object on Windows), so stop,
restart, or closing the managed pane also cleans up descendants.

Start or restart a configured Codex agent with:

```bash
verde live agent open --provider codex
verde live process restart --name codex
```

Use `verde live agent open --provider codex` for the default Codex TUI flow; it
creates a managed terminal surface, applies Codex hook setup, and does not need
a `verde.yml` entry. Use `verde live process restart --name codex` when you
want to launch or restart the named agent declared in `verde.yml`. The same
default Codex TUI action is available from the workspace sidebar by
right-clicking the workspace new-thread/pencil button and choosing `Open Codex
TUI`.

A Codex TUI opened manually in any Verde terminal still gets Verde identity
environment variables and can update the surface through `verde notify`, BEL,
OSC 777, or MCP, but it is not automatically a managed `verde.yml` agent unless
it is launched through the configured process entry.

Example config:

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
      {
        "label": "Local Agent",
        "command": ["my-agent", "--interactive"]
      }
    ]
  },
  "keybinds": {
    "refresh": ["CommandOrControl+R", "CommandOrControl+Shift+R", "Ctrl+Shift+R", "F5"],
    "new_thread": "CommandOrControl+T",
    "sidebar": "CommandOrControl+S",
    "sidebar_hidden": "Ctrl+Shift+S",
    "browser": "Ctrl+Shift+B",
    "chat": {
      "model_picker": "Alt+M",
      "run_config": "Alt+R"
    },
    "workspace": {
      "split_chat_vertical": "CommandOrControl+Alt+C",
      "split_chat_horizontal": "CommandOrControl+Alt+Shift+C",
      "split_terminal_vertical": "CommandOrControl+Alt+J",
      "split_terminal_horizontal": "CommandOrControl+Shift+T",
      "focus_up": ["Alt+Up", "Ctrl+K"],
      "focus_down": ["Alt+Down", "Ctrl+J"],
      "focus_left": ["Alt+Left", "Ctrl+H"],
      "focus_right": ["Alt+Right", "Ctrl+L"],
      "pane_previous": "Ctrl+Shift+Tab",
      "pane_next": "Ctrl+Tab",
      "focus_prompt": "Tab",
      "move_up": "Ctrl+Shift+K",
      "move_down": "Ctrl+Shift+J",
      "move_left": "Ctrl+Shift+H",
      "move_right": "Ctrl+Shift+L",
      "toggle_maximize": "CommandOrControl+Alt+M",
      "close": ["CommandOrControl+W", "Alt+X"],
      "select": [
        "Alt+1",
        "Alt+2",
        "Alt+3",
        "Alt+4",
        "Alt+5",
        "Alt+6",
        "Alt+7",
        "Alt+8",
        "Alt+9",
        "Alt+0"
      ]
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
The nested `chat` bindings only run while a GUI chat pane is focused; they do not intercept input in terminal or browser panes. The model picker includes initial provider selection on a fresh thread.

## Logs

On Linux, Verde writes runtime logs under SDL's pref path:

- `~/.local/share/verde/Native/logs/verde.stderr.log`
- `~/.local/share/verde/Native/logs/last-crash.log`

On Windows, run `bin\verde.exe state path --json` to locate the authoritative
per-user state directory; the same `logs\verde.stderr.log` and
`logs\last-crash.log` files are below it. Windows user configuration defaults
to `%APPDATA%\Verde\verde.json` and can be overridden with `VERDE_CONFIG`.

Those log files capture Zig panic output, provider helper stderr, and the last
panic marker written before the app aborted.

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
