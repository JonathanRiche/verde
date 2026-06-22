---
title: CLI reference
description: The full verde CLI surface — top-level commands, offline state, live discovery, browser, chat, terminal, and process control, shell completion, and exit codes.
section: Reference
order: 5
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
verde capabilities [--json]   # Print supported CLI/live features
verde open <url> [--json]     # Open a URL in this Verde workspace's browser pane
verde completion <shell>      # Print shell completion script
verde state <command>         # Read persisted state while the app is closed
verde notify [options]        # Update the current terminal surface
verde live <command>          # Control or inspect the running app
```

Use `--json` when scripting. Live IPC responses use a stable envelope:

```json
{ "id": 1, "ok": true, "result": {} }
```

Errors return `ok: false` with an `error.code` and `error.message`.

## Offline state commands

State commands read Verde's persisted SQLite state and do not require the app
to be running.

```bash
verde state path [--json]
verde state projects [--json]
verde state panes --project <id|index|path|current> [--json]
verde state threads --project <id|index|path|current> [--json]
verde state transcript --project <id|index|path|current> --thread <index|provider-id> [--json]
```

- `path` prints the SDL pref path and `state.sqlite` location.
- `projects` lists imported projects and the selected project.
- `panes` prints the saved workspace layout and terminal dock state for a project.
- `threads` lists saved chat threads for a project.
- `transcript` prints one saved chat transcript by thread index or provider thread id.

## Live discovery commands

Live commands talk to the running desktop app over a current-user Unix socket at
Verde's SDL pref path. Start the app first (`verde` or `mise run dev` from
source).

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
verde live workspace archive --project <id|index|path|current> [--json]
```

- `capabilities` prints the live method list without requiring the app to be running.
- `status` returns protocol version, app pid, selected project, focused pane, current pane graph, terminal/process summary, and browser runtime state.
- `active` returns the current project and focused pane.
- `surfaces` lists in-memory terminal surface status and attention metadata.

## Browser control

```bash
verde live browser status [--json]
verde live browser open --url https://example.com [--project <id|index|path|current|self>] [--json]
verde live browser navigate --url https://example.com [--json]
verde live browser eval --script "document.title" [--json]
verde live browser post-json --json-payload '{"type":"ping"}' [--json]
```

The browser pane uses the host platform's native webview (WPE WebKit, WKWebView,
or WebView2). `browser open` opens a URL in the workspace's browser pane,
creating one if needed. `browser eval` runs JavaScript in the loaded page and
returns the result as JSON.

## Chat control

Chat commands resolve the target workspace pane to a chat thread and drive it
through the same composer / send path as the UI.

```bash
verde live chat status --pane <pane-id> [--json]
verde live chat transcript --pane <pane-id> [--json]
verde live chat draft set --pane <pane-id> --text "Reply with exactly: ok" [--json]
verde live chat draft append --pane <pane-id> --text " and more" [--json]
verde live chat send --pane <pane-id> [--prompt "fix the tests"] [--json]
verde live chat followup --pane <pane-id> --prompt "now run the linter" [--json]
verde live chat stop --pane <pane-id> [--json]
verde live chat approve --pane <pane-id> --decision approve|deny [--call <id>] [--json]
```

- `status` returns the current draft, send state, and pending approval status.
- `transcript` returns persisted messages for the pane's thread.
- `draft set` replaces the current draft; `draft append` appends to it.
- `send` sends `--prompt`, `--text`, or a trailing prompt argument. If no prompt is supplied, it sends the current draft.
- `followup` queues or steers a prompt while a send is active.
- `stop` aborts the current send for that chat thread.
- `approve` resolves the current pending approval. `--decision` accepts `approve` or `deny`.

## Terminal and process control

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

- `terminal write` sends text to the active terminal tab/pane. Include `\r` when you want to submit a shell command.
- `process start`, `stop`, and `restart` control entries loaded from `verde.yml`.
- `agent open --provider codex` opens a first-class Codex TUI in the selected workspace without requiring a `verde.yml` entry.
- `stack start`, `stop`, and `restart` apply the same action to every configured process and agent in the selected workspace.

## Pane management

```bash
verde live pane split --pane <pane-id> --kind chat|terminal --axis horizontal|vertical [--json]
verde live pane move --pane <pane-id> --direction left|right|up|down [--json]
verde live pane close --pane <pane-id> [--json]
verde live palette list [--json]
verde live palette run --command pane.split_terminal_down [--json]
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

`verde completion` prints static completion scripts for bash, zsh, and fish.
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
and never depends on the desktop app being open. Dynamic project, pane,
process, and thread completions can be layered on top of this later.
