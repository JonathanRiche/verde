# /goal Persistent Verde Terminal Sessions

Implement Verde-native terminal session persistence so terminal panes can survive Verde UI crashes/closes and be reattached by the desktop app or by the `verde` CLI over SSH, without using `tmux` by default.

## Intent

Verde already persists pane layout, terminal tabs/splits, and chat threads. The missing layer is long-lived ownership of terminal PTYs. Today terminal children are direct Verde UI process children, so when the app exits, running TUIs such as `claude`, `codex`, `opencode`, `btop`, shells, etc. exit with it.

Build a small Verde sessionizer layer that gives Verde the tmux-like parts we want:

- persistent PTY ownership outside the UI process
- attach/detach from multiple clients over a local Unix socket
- input/output streaming
- resize propagation
- screen and scrollback snapshots
- session metadata and lifecycle commands

Do not use `tmux` as the default implementation. Users should still be free to run `tmux` manually inside a Verde terminal pane if they want.

## Architecture

Target shape:

```text
verde UI process
  - owns windows, pane layout, rendering, focus, mouse/key routing
  - attaches terminal panes to persistent Verde sessions
  - does not directly own long-lived terminal children when session persistence is enabled

verde session daemon / broker
  - owns PTYs and terminal child processes
  - keeps sessions alive when the UI process exits
  - exposes a local Unix socket API for attach/input/output/resize/snapshot/lifecycle

verde CLI
  - talks to the same daemon
  - supports SSH-friendly attach, list, kill, inspect, write, tail/screen
```

Mapping:

```text
workspace pane -> dock_id/pane_id -> terminal leaf -> session_id -> daemon-owned PTY
```

On app reopen, Verde loads the existing pane layout, reads each leaf's `session_id`, reconnects to the session daemon, restores screen contents from daemon state, and resumes streaming output. If the session is gone, Verde should show a clear exited/missing state and optionally restart according to an explicit revive policy.

## Important File Boundary

Keep most of this implementation in a new Zig module. Do not bury the sessionizer inside `packages/desktop/src/terminal/terminal.zig`.

Suggested files:

- `packages/desktop/src/terminal/sessionizer.zig`
- optionally `packages/desktop/src/terminal/session_protocol.zig`
- optionally `packages/desktop/src/terminal/session_daemon.zig`

`terminal.zig` should import the new module and adapt `UnixSession`/`Dock` to use it. Keep `terminal.zig` focused on terminal UI integration, ghostty VT rendering, pane/tab layout, key translation, and high-level terminal session plumbing.

This is important for reviewability. The persistent session owner, socket protocol, attach state, PTY lifecycle, and CLI-facing behavior should be trackable as a distinct feature area.

## Implementation Status

Status after the first implementation pass:

- Complete: `packages/desktop/src/terminal/sessionizer.zig` exists and owns the Verde-native session daemon, PTY lifecycle, socket protocol helpers, stable session IDs, lazy daemon start, output rings, and background PTY draining.
- Complete: `packages/desktop/src/terminal/terminal.zig` imports the sessionizer module and keeps the UI/rendering responsibilities local to `terminal.zig`.
- Complete: terminal leaf layout JSON now persists `session_id`, launch kind/label/command, and revive policy.
- Complete: base terminal docks and extra terminal docks persist deterministic session IDs using project/dock/pane context.
- Complete: `tui_dock_id` is persisted through SQLite schema/client changes.
- Complete: UI terminal panes attach to daemon-backed sessions and feed daemon output into the existing `ghostty_vt.Terminal` render path.
- Complete: UI input and resize are propagated to daemon-owned PTYs.
- Complete: closing/reopening the Verde app with running TUIs has been manually tested and works: the panes reopen and reattach to the still-running sessions.
- Complete: CLI session commands exist for `list`, `inspect`, `new`, `attach`, `write`, `tail`, `screen`, `kill`, and `cleanup`.
- Complete: local CLI smoke tests passed for create/tail/kill and attach.
- Complete: daemon output draining was tested with large detached output, confirming daemon-owned PTYs keep draining while no UI/CLI client is attached.
- Complete: `mise run build` passes.

Additional completed work after the follow-up pass:

- Complete: daemon protocol methods for `session.attach` and `session.detach` now create/remove daemon-side attach records.
- Complete: CLI attach now registers a daemon attach record and detaches it on exit.
- Complete: daemon-side stale attach cleanup is implemented for clients that disappear without a clean detach.
- Complete: `verde session attach` polls the caller terminal size and propagates resize changes to the daemon-owned PTY.
- Complete: daemon idle exit is implemented when no sessions are running, with pid/socket marker cleanup.
- Complete: normal terminal pane/tab close now detaches/removes the UI pane without killing the daemon-owned session. Explicit terminal termination still kills the daemon session.
- Complete: daemon-backed terminal status text now distinguishes missing daemon sessions from daemon connection loss.
- Complete: attach/detach smoke verified that detach leaves the PTY running and clears daemon attach records.
- Complete: idle-exit smoke verified that the daemon exits and removes its pid marker after the last session exits.

Remaining optional follow-up:

- Optionally add provider-aware revive for missing AI TUI sessions using `codex resume`, `claude --resume`, `opencode --session`, etc.

## Original Code Context

Relevant existing behavior:

- `packages/desktop/src/terminal/terminal.zig` persists terminal tab/split layout via `PersistedWorkspace`, `PersistedTab`, and `PersistedNode`.
- `Dock.applyPersistedLayoutJson` rebuilds the terminal layout, but leaves sessions null until `ensureWorkspace` starts fresh sessions.
- `UnixSession` currently owns `master_fd`, `child_pid`, ghostty terminal state, and output ring directly.
- `UnixSession.spawnCommand` uses `forkpty`, making child processes owned by the Verde UI process.
- `packages/desktop/src/cli.zig` already has live IPC commands for `terminal write|tail|screen`, but no offline/persistent `session` command group.
- `packages/desktop/src/ipc/server.zig` exposes terminal inspection and write/tail/screen commands against the running app only.
- `db/types.zig` includes `PersistedThread.tui_dock_id`, but the SQLite schema/client currently do not appear to persist that field. Fix this while touching session restore metadata.

## Data Model

Add stable terminal session identity to persisted terminal leaves.

Extend the terminal layout JSON leaf metadata with fields like:

```zig
session_id: ?[]const u8 = null,
launch_kind: TerminalLaunchKind = .shell,
launch_label: ?[]const u8 = null,
launch_command: []const []const u8 = &.{},
revive_policy: TerminalRevivePolicy = .attach_or_create,
```

Suggested revive policies:

- `attach_or_create`: attach to existing daemon session if present; create a new one if missing.
- `attach_only`: attach if present; otherwise show missing/exited state.
- `restart`: always start a new process for the leaf on reopen.
- `manual`: never auto-create; user must start/attach explicitly.

Stable session IDs should be deterministic enough for CLI use and unique enough to avoid collisions. Example:

```text
verde:<project_id>:dock:<dock_id>:pane:<pane_id>
```

Persist enough metadata for the daemon and CLI to display helpful session lists:

- `session_id`
- `project_id`
- `project_path`
- `dock_id`
- `pane_id`
- tab title / launch label
- original launch profile
- created/last attached timestamps if convenient
- running/exited status

## Protocol

Use a local-user Unix socket under the existing Verde pref/runtime area. Keep the protocol JSON-line based at first, matching the existing app IPC style.

Minimum daemon methods:

- Complete: `session.list`
- Complete: `session.inspect`
- Complete: `session.create`
- Complete: `session.attach`
- Complete: `session.detach`
- Complete: `session.write`
- Complete: `session.resize`
- Complete: `session.tail`
- Complete: `session.screen`
- Complete: `session.kill`
- Complete: `session.cleanup`

For the desktop app, streaming output can start simple:

- UI polls or receives output chunks from the daemon.
- UI feeds bytes into the existing ghostty VT parser/render path.
- Daemon retains a bounded output ring per session.

Do not overbuild binary frames on the first pass unless JSON-line output proves inadequate. The existing app IPC reports `terminal_binary_frames = false`; it is acceptable to keep this simple initially.

## CLI Shape

Add a new top-level CLI group:

```sh
[x] verde session list [--json]
[x] verde session inspect --id <session-id> [--json]
[x] verde session new --project <id|index|current> [--name <name>] [-- <command>...]
[x] verde session attach --id <session-id>
[x] verde session attach --project <id|index|current> --pane <pane-id>
[x] verde session write --id <session-id> --text <text>
[x] verde session tail --id <session-id> [--lines <n>] [--json]
[x] verde session screen --id <session-id> [--json]
[x] verde session kill --id <session-id>
[x] verde session cleanup
```

`verde session attach` must work from SSH. It should put the caller's terminal into raw mode, proxy stdin/stdout to the daemon-owned PTY, handle terminal resize, and detach cleanly when the user exits the attach client. This is the tmux-like behavior we want, implemented by Verde rather than by tmux.

Current state: local attach works and is SSH-friendly in shape. Live resize handling is implemented by polling the caller terminal size and sending `session.resize` when it changes. A real SSH acceptance test passed using a temporary localhost `sshd`, temporary key material, and a pseudo-terminal.

## UI Behavior

When a terminal pane is opened:

1. Complete: resolve or create a `session_id` for the terminal leaf.
2. Complete: ask the sessionizer for an existing session.
3. Complete: if found, attach and render current screen/snapshot.
4. Complete: if not found, apply the leaf's revive policy.
5. Complete: stream future bytes into the existing terminal renderer.

When the app closes gracefully:

- Complete: detach UI clients from daemon sessions by dropping the UI-side session object without killing daemon-owned PTYs.
- Complete: do not kill daemon-owned sessions when the Verde UI closes.
- Complete: persist layout and session IDs.

When the app crashes:

- Complete: daemon keeps PTYs alive.
- Complete: stale attach clients are removed after they stop touching their daemon attach record.

When the user closes a terminal pane:

- Complete: normal pane/tab close means detach/remove the pane and keep the daemon-owned session alive. Explicit terminal termination or `verde session kill` means kill the child process.

## Daemon Lifetime

Acceptable first implementation:

- Complete: spawn the session daemon lazily when the UI or CLI needs it.
- Complete: daemon exits after an idle timeout only if it has no running sessions.
- Complete: if sessions are running, daemon stays alive after the UI exits.

Complete: the daemon writes a pid/socket marker and handles stale socket cleanup on start.

## Recovery Limits

Be explicit in code comments and UI/API behavior:

- Verde-native sessions survive Verde UI close/crash.
- They do not survive daemon crash, machine reboot, or killed child processes.
- For AI TUIs, a missing session can optionally be revived by provider/thread resume commands (`codex resume`, `claude --resume`, `opencode --session`, etc.) when Verde has the provider thread ID.
- For arbitrary commands like `btop` or a shell, a missing daemon session can only restart the command, not recover the exact process state.

## Non-Goals

Do not implement tmux panes/windows/layouts inside the sessionizer. Verde already owns layout.

Do not use tmux by default.

Do not rewrite the whole terminal renderer. Reuse the existing ghostty VT path.

Do not make SSH attach depend on the Verde desktop app being open. SSH attach should talk to the session daemon directly.

Do not require users to know session internals for normal desktop usage.

## Suggested Implementation Slices

1. Persistence metadata
   - Complete: add session IDs and launch/revive metadata to persisted terminal leaf JSON.
   - Complete: fix persistence of `tui_dock_id` in SQLite if still missing.
   - Complete: keep backward compatibility with old terminal layout JSON.

2. Sessionizer module skeleton
   - Complete: add `terminal/sessionizer.zig`.
   - Complete: define session IDs, metadata structs, protocol helpers, and local socket path helpers.
   - Complete: tests exist for ID/path helpers and old terminal layout JSON compatibility.

3. Daemon-owned PTY
   - Complete: move PTY ownership logic out of direct `UnixSession` ownership path into the sessionizer layer.
   - Complete: start daemon sessions with `forkpty`.
   - Complete: maintain output ring and process status in daemon memory.
   - Complete: drain daemon-owned PTYs in a background loop.

4. UI attach path
   - Complete: change `UnixSession` to attach to a sessionizer session instead of always spawning a direct child.
   - Complete: feed daemon output into the existing `ghostty_vt.Terminal`.
   - Complete: propagate input and resize to daemon.

5. CLI session commands
   - Complete: add `verde session list/inspect/tail/screen/write/kill`.
   - Complete: add `verde session attach` with raw terminal proxy and live resize propagation.

6. Lifecycle polish
   - Complete: graceful detach on UI shutdown.
   - Complete: stale attach cleanup.
   - Complete: idle daemon exit behavior.
   - Complete: clear status text for missing daemon sessions and daemon connection loss.

## Acceptance Criteria

- Complete, manually verified: open a terminal pane, run TUIs, close Verde, reopen Verde, and see the same session still running.
- Complete, manually verified: start running TUIs in terminal panes, close Verde, reopen Verde, and reattach to the still-running TUI when the daemon stayed alive.
- Complete: SSH into the same machine and run `verde session attach --id <session-id>`, and interact with the same PTY. Verified with a temporary localhost `sshd` and pseudo-terminal; the attach command wrote to the daemon PTY and detached cleanly.
- Complete: closing the Verde UI does not kill daemon-owned sessions.
- Complete: explicitly killing a session from the CLI terminates the child process.
- Complete: normal UI pane/tab close detaches without killing; explicit kill from CLI or terminal termination kills the child process.
- Complete: existing terminal layout persistence still works for old state files.
- Complete: users who want tmux can run tmux manually, but Verde does not launch tmux automatically.
