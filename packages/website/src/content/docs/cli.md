---
title: CLI reference
description: The verde CLI surface — updates, offline state, live browser and chat control, persistent terminal sessions, integrations, completion, and exit codes.
section: Reference
order: 7
slug: cli
---

## Overview

`verde` is both the desktop launcher and a CLI for reading persisted state and
controlling a running app. CLI-only commands run before SDL startup, so you can
use them from scripts without opening a window.

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
verde integrations <command>  # Inspect and install optional provider hooks
verde theme <command>         # Import, validate, export, or reset themes
verde session <command>       # Manage persistent terminal sessions
verde mcp                     # Run Verde's stdio MCP bridge
verde herdr <command>         # Open or inspect Herdr-backed remote workspaces
verde live <command>          # Control or inspect the running app
```

Use `--json` when scripting. Live IPC responses use a stable envelope:

```json
{ "id": 1, "ok": true, "result": {} }
```

Errors return `ok: false` with an `error.code` and `error.message`.

## Updates

```bash
verde update
verde update --json
```

`verde update` launches the official installer for the current platform. For
an Arch installation owned by the `verde-bin` AUR package, it reports the
detected `yay` or `paru` command instead so the package manager remains the
owner of the installation. On Linux and macOS, restart Verde after the
installer finishes. On Windows, the updater waits for the running app to exit,
installs the new release, and starts Verde again. The command requires network
access to the release assets.

You can also check and install releases from **Settings → Updates**. For an AUR
install, Verde opens `yay` or `paru` in an interactive terminal pane so sudo
password prompts and package progress remain visible. The card shows the
installed version, release notes, **Check now**, **Install update**, and the
**Check automatically** preference.

## Theme packages

Theme commands run without launching the desktop UI. Imports accept local JSON,
ordinary HTTP(S) URLs, and GitHub `blob` links. A successful import installs and
activates the theme; it then appears alongside Verde and Omarchy in the Settings
theme dropdown.

```bash
verde theme import <file-or-url> [--dry-run] [--json]
verde theme validate <file-or-url> [--json]
verde theme export [file] [--name <name>] [--json]
verde theme reset [--json]

# Hosted example from the Verde theme gallery
verde theme validate https://verdeai.dev/themes/kanagawa.json
verde theme import https://verdeai.dev/themes/kanagawa.json
```

`validate` and `import --dry-run` do not change `verde.json`. `export` resolves
Omarchy-derived colors into a portable package, so the result can be used on
Linux, macOS, or Windows. Theme packages only apply allowlisted visual colors
and optional UI/terminal font sizes; font-family and command settings are never
imported.

## Offline state commands

State commands read Verde's persisted SQLite state and do not require the app
to be running.

```bash
verde state path [--json]
verde state workspaces [--json]
verde state panes --project <id|index|path|current> [--json]
verde state threads --project <id|index|path|current> [--json]
verde state transcript --project <id|index|path|current> --thread <index|provider-id> [--json]
```

- `path` prints the SDL pref path and `state.sqlite` location.
- `workspaces` lists imported projects and the selected workspace. `projects`
  remains an alias for compatibility.
- `panes` prints the saved workspace layout and terminal dock state for a project.
- `threads` lists saved chat threads for a project.
- `transcript` prints one saved chat transcript by thread index or provider thread id.

## Live discovery commands

Live commands talk to the running desktop app over current-user local IPC: a
Unix socket on Linux/macOS or a named pipe on Windows. Start the app first.

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
verde live workspace select --project <id|index|path|current> [--json]
verde live workspace create --path /path/to/project [--json]
verde live workspace rename --project <id|index|path|current> --label "New name" [--json]
verde live workspace close --project <id|index|path|current> [--json]
verde live workspace reopen [--project <id|index|path>] [--json]
```

- `capabilities` prints the live method list without requiring the app to be running.
- `status` returns protocol version, app pid, selected project, focused pane, current pane graph, terminal/process summary, and browser runtime state.
- `active` returns the current project and focused pane.
- `surfaces` lists terminal surface status and attention metadata. Unacknowledged
  completions persist across app and terminal-daemon restarts until the pane is
  focused or the completion is cleared through the surface controls.
- `panes` and `threads` expose native-chat `completion_pending` and
  `completed_at_ms` fields. Focusing that chat pane through `pane focus`
  acknowledges and clears the durable completion.
- `workspace close` removes a workspace from the active sidebar without
  deleting its saved threads or layout. `archive` is an alias for `close`.
- `workspace reopen` restores the specified closed workspace, or the most
  recently closed one when `--project` is omitted.

## Browser control

```bash
verde live browser status [--json]
verde live browser open --url https://example.com [--project <id|index|path|current|self>] [--json]
verde live browser navigate --url https://example.com [--json]
verde live browser close [--json]
verde live browser toggle [--json]
verde live browser back [--json]
verde live browser forward [--json]
verde live browser reload [--json]
verde live browser focus [--json]
verde live browser blur [--json]
verde live browser select-all [--json]
verde live browser copy [--json]
verde live browser cut [--json]
verde live browser paste-text --text "hello" [--json]
verde live browser eval --script "document.title" [--json]
verde live browser screenshot [--json]
verde live browser post-json --json-payload '{"type":"ping"}' [--json]
verde live browser inspector-enable [--json]
verde live browser inspector-disable [--json]
verde live browser inspector-toggle [--json]
verde live browser inspector-mode --mode point|draw-box|draw-freeform [--json]
```

The browser pane uses the host platform's native webview (WPE WebKit, WKWebView,
or WebView2). `browser open` opens a URL in the workspace's browser pane,
creating one if needed. `browser eval` runs JavaScript in the loaded page and
returns the result as JSON. The inspector commands control
[Design Mode](/docs/design-mode) for browser-to-agent visual feedback.
`browser screenshot` stores and returns the visible viewport as PNG data when
the active presentation exposes a CPU-side frame. Native child-view backends
return `unsupported` until their platform snapshot path is available.
`select-all` and `copy` operate on the focused page element or selection;
`cut` and `paste-text` target the focused editable element.

## Chat control

Chat commands resolve the target workspace pane to a chat thread and drive it
through the same composer / send path as the UI.

```bash
verde live chat open --workspace <id> --provider codex [--model <id>] [--reasoning low|medium|high|xhigh] [--fast|--no-fast] [--json]
verde live chat status --pane <pane-id> [--json]
verde live chat transcript --pane <pane-id> [--json]
verde live chat draft set --pane <pane-id> --text "Reply with exactly: ok" [--json]
verde live chat draft append --pane <pane-id> --text " and more" [--json]
verde live chat send --pane <pane-id> [--prompt "fix the tests"] [--json]
verde live chat followup --pane <pane-id> --prompt "now run the linter" [--json]
verde live chat stop --pane <pane-id> [--json]
verde live chat approve --pane <pane-id> --decision approve|deny [--call <id>] [--json]
```

- `open` validates provider/model reasoning and Fast settings before creating
  the pane. Its response and subsequent `status` responses report the effective
  reasoning effort, reasoning variant, Fast mode, and service tier.
- `status` returns the current draft, send state, and pending approval status.
- `transcript` returns persisted messages for the pane's thread.
- `draft set` replaces the current draft; `draft append` appends to it.
- `send` sends `--prompt`, `--text`, or a trailing prompt argument. If no prompt is supplied, it sends the current draft.
- `followup` steers a prompt into the pane's **running** turn. It is
  daemon-led: it resolves the pane's thread through the session daemon, never
  changes focus, presentation, or the composer draft, and returns structured
  results — `disposition: "steered"` on success, `invalid_state` when the pane
  has no running turn (nothing is staged as a draft), and `not_found` for a
  missing pane or thread. Steering currently supports Claude local-CLI turns;
  other provider harnesses return a structured unsupported error.
- `stop` aborts the current send for that chat thread.
- `approve` resolves the current pending approval. `--decision` accepts `approve` or `deny`.

Chat turns run in the session daemon, so an accepted turn keeps running and
lands durably even if the desktop window is closed or restarted mid-turn.
Drafts and staged image attachments persist with their thread across pane
switches and app restarts.

## Terminal and process control

Terminal commands resolve the target workspace pane to its terminal dock and
write through the same active PTY input path as the UI.

```bash
verde live terminal write --pane <pane-id> --text $'cargo test\r' [--json]
verde live terminal write --focused --text $'printf "ok\\n"\r' [--json]
verde live terminal key --pane <pane-id> --key enter [--json]
verde live terminal key --pane <pane-id> --chord ctrl+c [--json]
verde live terminal submit --pane <pane-id> [--json]
verde live terminal tail --pane <pane-id> [--lines <count>] [--json]
verde live terminal screen --pane <pane-id> [--lines <count>] [--json]
verde live process list [--project <id|index|path|current>] [--json]
verde live process start --name <name> [--project <id|index|path|current>] [--json]
verde live process stop --name <name> [--project <id|index|path|current>] [--json]
verde live process restart --name <name> [--project <id|index|path|current>] [--json]
verde live process inspect --name <name> [--project <id|index|path|current>] [--json]
verde live process logs --name <name> [--project <id|index|path|current>] [--json]
verde live agent open --provider codex|claude|opencode|cursor|grok [--project <id|index|path|current>] [--json]
verde live stack start [--project <id|index|path|current>] [--json]
verde live stack stop [--project <id|index|path|current>] [--json]
verde live stack restart [--project <id|index|path|current>] [--json]
verde live stack status [--project <id|index|path|current>] [--json]
```

- `terminal write` sends raw text to the active terminal tab/pane. Include `\r`
  when you want to submit a shell command. A stopped session is restarted
  before the write.
- `terminal key` sends one validated atomic key chord without changing desktop
  focus. Use `--key` with `--ctrl`, `--alt`, `--shift`, or `--super`, or pass a
  chord such as `ctrl+c`. `terminal submit` is an atomic Enter alias.
- Supported keys are Enter, Escape, Tab, arrows, Home/End, PageUp/PageDown,
  Backspace/Delete, Space, F1-F12, letters, and digits. Arbitrary escape
  sequences are rejected.
- Key actions do not restart stopped or missing sessions. They can still submit
  or interrupt work, so automation should resolve an explicit pane id and
  inspect the target before sending Enter or another consequential key.
- `terminal tail` returns recent terminal output; `screen` returns the current
  visible terminal screen.
- `process start`, `stop`, and `restart` control entries loaded from `verde.yml`.
- `agent open --provider <name>` opens that provider's first-class TUI in the
  selected workspace without requiring a `verde.yml` entry. Grok is detected
  from `PATH` and launched with `--no-auto-update`.
- `stack start`, `stop`, and `restart` apply the same action to every configured process and agent in the selected workspace.

## Pane management

```bash
verde live pane split --pane <pane-id> --kind chat|terminal --axis horizontal|vertical [--json]
verde live pane focus --pane <pane-id> [--json]
verde live pane resize --first <pane-id> --second <pane-id> --axis horizontal|vertical --ratio <0..1> [--json]
verde live pane move --pane <pane-id> --direction left|right|up|down [--json]
verde live pane maximize --pane <pane-id> [--json]
verde live pane close --pane <pane-id> [--json]
verde live palette list [--json]
verde live palette run --command pane.split_terminal_down [--json]
```

## Persistent terminal sessions

The session daemon keeps terminal processes addressable independently of a
particular visible pane. List and inspect sessions even when the desktop app is
not running; persisted metadata remains available if the daemon is offline.

```bash
verde session list [--json]
verde session inspect --id <session-id> [--json]
verde session new [--workspace <id>] [--cwd <path>] [--name <name>] -- <command...>
verde session attach --id <session-id>
verde session write --id <session-id> --text $'cargo test\r' [--json]
verde session tail --id <session-id> [--lines <count>] [--json]
verde session screen --id <session-id> [--lines <count>] [--json]
verde session kill --id <session-id> [--json]
verde session cleanup [--json]
```

`attach` is interactive. For automation, prefer `write`, `tail`, and `screen`
with an explicit session id.

## MCP bridge

`verde mcp` starts a JSONL stdio MCP server that exposes Verde's local live
controls to compatible agents. It is primarily used by agent integrations;
most users do not invoke it directly. The bridge handles MCP initialization,
tool discovery, and tool calls, and requires the relevant live Verde target for
operations that control the app.

The bridge includes embedded-browser tools for status, open/navigation, DOM
inspection, selector-based click and typing, and viewport screenshots. Browser
actions correlate asynchronous webview evaluation results before returning to
the agent. Potentially sensitive clicks, password entry, and form submission
require an explicit confirmed retry so the agent client can ask the user first.

`send_terminal_key` exposes the same atomic terminal-key path to MCP clients. It
requires `pane_id`, accepts an optional workspace selector, and takes either a
named key plus modifier booleans or a chord. It preserves desktop focus and
does not restart a stopped session.

### Chat control over MCP

The bridge exposes the full GUI-chat surface to agents: `open_chat`,
`present_chat`, `send_chat_message`, `get_chat_draft` / `set_chat_draft`,
`read_chat_thread`, `tail_chat_turn`, `stop_chat_turn`, `approve_chat_turn`,
and `queue_chat_followup`, plus `list_workspaces` / `list_panes` for
discovery.

- `read_chat_thread` and `queue_chat_followup` are **daemon-direct**: they
  read persisted thread state through the session daemon, so they work even
  when the GUI has paged the thread out of memory.
- `queue_chat_followup` steers a prompt into a running turn with the same
  semantics as `verde live chat followup` — structured
  `steered` / `invalid_state` / `not_found` results, no focus or composer
  changes, and no silent draft staging when the turn is idle.
- Capabilities are granular: a tool that cannot run in the current
  configuration returns `capability_unavailable` instead of failing
  ambiguously. Discover the active surface with `verde capabilities --json`.

### Process coordination and retained outcomes

The MCP bridge exposes `list_processes`, `check_command`, `acquire_lease`,
`release_lease`, and `wait_for_process` for shared workspace coordination.
`list_processes` combines configured processes, active terminal commands, GUI
agent turns, background tasks, and active leases.

Terminal commands keep the same stable process id as they move from active to
final. Final records are retained in memory for 15 minutes, up to 32 per
workspace, and report status `completed`, `failed`, `cancelled`, `crashed`, or
`unknown`. When available they also include `finished_at_ms`, `exit_code`,
`signal`, `cancellation_reason`, and ownership details. Retained records do not
survive an app restart.

`wait_for_process` waits up to 300 seconds by default, with a 900-second cap.
Its tracking outcome is `completed`, `replaced`, `gone`, or `timed_out`.
`completed` means a final record for that id was found; it does not mean the
command exited successfully. Inspect the returned `process.status` and exit
fields. A disappearing terminal command remains observable as `stopping`
during a short finalization grace period so waiters do not receive a premature
`gone`.

## Provider integrations

Provider hooks are optional add-ons that let agent CLIs drive Verde's sidebar
status pips. They never overwrite provider config or change provider
login/auth behavior.

```bash
verde integrations list [--json]
verde integrations doctor [--json]
verde integrations install <claude|codex|amp|opencode|cursor|grok|pi|fx> [--global]
verde integrations remove <claude|codex|amp|opencode|cursor|grok|pi|fx> [--global]
verde integrations disable <claude|codex|amp|opencode|cursor|grok|pi|fx>
```

- **Claude / Codex** hooks are project-local (`.claude/settings.local.json` / `.codex/hooks.json`); `--global` installs them in `~/.claude/settings.json` / `~/.codex/hooks.json` instead.
- **Cursor** supports project-local `.cursor/hooks.json` and a `--global`
  installer at `~/.cursor/hooks.json`. Verde merges its entries without
  replacing unrelated hooks.
- **Grok** uses an isolated personal hook at
  `$GROK_HOME/hooks/verde-notify.json`, defaulting to
  `~/.grok/hooks/verde-notify.json`; install or remove it with `--global`.
- **Amp** uses a global lifecycle plugin at `~/.config/amp/plugins/verde-notify.ts` (install with `--global`). The plugin is a no-op outside Verde panes.
- **OpenCode** uses a global lifecycle plugin at
  `~/.config/opencode/plugin/verde-notify.ts`.
- **Pi** uses a global extension at
  `~/.pi/agent/extensions/verde-notify.ts`. It reports settled lifecycle state
  and follows `/name` session-title changes, falling back to the submitted
  prompt before a session is named.
- **FX** reports lifecycle directly through Verde's built-in compatibility
  endpoint. Its native session/workspace terminal title remains authoritative,
  so no hook file is required.

## Remote workspaces (Herdr)

Herdr opens or attaches Verde workspaces on a remote host over SSH and syncs
pane state, with handoff to move a local workspace to a remote (and unlink to
bring it back) and reusable connection profiles. `handoff` and `unlink`
require the app to be running.

```bash
verde herdr status [--json]
verde herdr open --herdr-workspace <id> --session <name> [--profile <name>|--remote <ssh-alias>] [--remote-cwd <path>] [--local-dir <path>] [--json]
verde herdr handoff [--workspace <id|index|path|current>] [--all] [--session <name>] [--profile <name>|--remote <ssh-alias>] [--remote-cwd <path>] [--dry-run] [--json]
verde herdr unlink [--workspace <id|index|path|current>] [--all] [--json]
verde herdr profiles list [--json]
verde herdr profiles add --name <name> --ssh-target <alias> [--session <name>] [--remote-cwd <path>] [--local-dir <path>] [--json]
verde herdr profiles remove <name> [--json]
verde herdr profiles test <name> [--json]
```

## Terminal surface notifications

Verde terminal children receive identity variables such as `VERDE=1`,
`VERDE_SESSION_ID`, `VERDE_WORKSPACE_ID`, `VERDE_WORKSPACE_PATH`, `VERDE_DOCK_ID`,
`VERDE_PANE_ID`, `VERDE_SOCKET`, `VERDE_LIVE_SOCKET`,
`VERDE_SESSIONIZER_SOCKET`, and `VERDE_CLI`. Terminal tools can use those
variables to update their pane surface:

```bash
verde notify --title "Codex needs input" --body "Approve command?" --status waiting
verde notify --status working --progress 0.4 --label "Running tests"
verde notify --status done --title "Agent finished"
verde notify --clear
```

`--status` accepts `idle`, `working`, `waiting`, `done`, or `error`. Combined
with `--progress` (0..1), it drives the surface's progress bar.

## Selectors and exit codes

- Use `--pane <id>` for deterministic automation.
- Use `--focused` for interactive smoke tests.
- Use `--project current` for the selected project, or pass a project index, id, or path.
- Chat commands require a chat pane. Terminal commands require a terminal pane.

| Exit | Meaning                                                                            |
| ---- | --------------------------------------------------------------------------------- |
| `0`  | CLI command parsed and, for live commands, received a live response.             |
| `1`  | Command failure before a structured live response.                                |
| `2`  | Invalid CLI arguments.                                                              |
| `3`  | Live server is not running or not ready.                                            |
| `4`  | Offline state target not found.                                                    |

Live IPC request failures return JSON error codes such as `not_found`,
`invalid_request`, `invalid_target`, `rejected`, `unsupported`, or
`method_not_found`. Scripts must check the JSON envelope's `ok` field, not only
the process exit code.

## Shell completion

`verde completion` prints static completion scripts for bash, zsh, fish, and
PowerShell.
The generated completions cover command names, nested live-control commands,
flags, and fixed flag values such as `--kind chat|terminal`,
`--axis horizontal|vertical`, and `--decision approve|deny`.

```bash
verde completion bash
verde completion zsh
verde completion fish
verde completion powershell
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
and never depends on the desktop app being open. Dynamic project, pane,
process, and thread completions can be layered on top of this later.
