---
name: verde
description: Drive Verde, the native agent workspace, through its `verde` MCP tools and the `verde` CLI. Use when running inside or beside Verde (a `<verde_orchestration>` or `<verde_parent_message>` block in the prompt, `VERDE=1` in the environment, or `verde` MCP tools available) and the task involves delegating work to another Verde chat or agent, reporting back to or being blocked for a parent chat, running builds, installs, or migrations under a shared lease, starting or watching dev servers and tracked processes, reading or typing into Verde terminal panes, driving Verde's built-in browser, or scheduling prompts for later or on a repeat. Also use when the user mentions Verde chats, panes, leases, processes, or schedules. Never use it to launch, restart, or quit Verde itself.
license: MIT
---

# Verde

Verde is a native desktop workspace for coding agents. Chat turns and terminal
sessions run in a **session daemon**; the desktop GUI, the `verde` CLI, the MCP
bridge, and the web/mobile clients are all clients of it. Work you start keeps
running if the window closes.

## 1. Confirm you can reach Verde

- **Native Verde chat:** your prompt carries a `<verde_orchestration>` block with
  your `workspace_id`, this chat's thread id, and your current `turn_id`. Keep
  them; most tools need them.
- **Delegated chat:** the prompt is wrapped in
  `<verde_parent_message from_thread="...">`. See section 4.
- **Terminal pane** (shell or TUI agent): the environment has `VERDE=1`,
  `VERDE_WORKSPACE_ID`, `VERDE_WORKSPACE_PATH`, `VERDE_PANE_ID`,
  `VERDE_SESSION_ID`, and `VERDE_CLI` (path to the `verde` binary).
- **Otherwise:** run `verde live status --json` and require `"ok": true`
  (exit code 3 means the app is not running). If Verde is unreachable, say so
  and stop. Never start Verde yourself.

## 2. Pick the access path

| Path | Use it for |
| --- | --- |
| **MCP server `verde`** (tools such as `open_chat`; Claude Code shows `mcp__verde__open_chat`) | Delegation and chat control, leases, processes, terminals, browser automation, schedules. Structured results, daemon-direct where possible, never moves desktop focus. |
| **CLI `verde`** (or `"$VERDE_CLI"`) | Builds under a lease (`verde lease run`), shell scripts and hooks, persistent sessions, and live commands MCP lacks (pane layout, workspace management, `stack`, browser back/forward/reload). |

- MCP is enabled in **Settings → Agents → Enable Verde MCP**, which registers a
  `verde` server for detected providers. Any MCP client can also run
  `verde mcp` as a stdio server.
- Discover what this install supports with `verde capabilities --json`. A tool
  that cannot run here returns `capability_unavailable`; do not retry it blindly.
- With the CLI, always pass `--json`, an explicit `--workspace <id>` and
  `--pane <id>`, and check both the exit code and the envelope's `ok` /
  `error.code`.

Full parameter lists: [references/mcp-tools.md](references/mcp-tools.md) and
[references/cli.md](references/cli.md).

## 3. Safety rules (always)

1. **Never restart, quit, or launch Verde** from inside it: no `pkill verde`, no
   bare `verde` / `verde app`, no running generated desktop binaries. Build,
   then ask the user to relaunch.
2. **Address things explicitly:** stable workspace id, pane id, thread id,
   process id, session id. Do not depend on whatever is selected or focused.
3. **Preserve the user's focus.** Do not focus panes, select workspaces or tabs,
   or focus the browser to look at something. MCP tools work without it. With
   `verde live chat open`, pass `--no-focus`.
4. **Shared resources go through leases** (section 5). Never `force` a lease,
   kill processes you did not start, or take over another process's port.
5. **No polling loops.** No `sleep`, `pgrep`, or timed retries. Child-chat
   results are delivered to you; builds wait in the lease queue;
   `wait_for_process` is a single bounded wait.
6. **Terminals:** prefer `send_terminal_key`, and read the screen before sending
   Enter, Ctrl+C, or other consequential input. Raw text writes restart a stopped
   session and can execute whatever is already typed.
7. **Everything is real.** `open_chat` and `send_chat_message` start real agent
   turns in the user's app. Only `close_pane` when the user asked for it.
8. **Browser:** pass `confirmed: true` for sensitive clicks, password entry, or
   form submission only after the user confirmed. Never navigate or close
   another pane's browser.
9. Never echo or log secrets, including `verde://pair` links.

## 4. Delegate to another chat (orchestration)

1. Get the workspace id from `<verde_orchestration>`, `VERDE_WORKSPACE_ID`, or
   `list_workspaces`.
2. `open_chat` with `workspace_id`, `provider` (for example `claude`, `codex`,
   `opencode`, `cursor`), optional `model` / `reasoning_effort`, and
   `parent_thread_id` = **your** thread id. It returns the child's
   `local_thread_id` and shows it beside you without taking focus.
3. `send_chat_message` with `workspace_id`, `local_thread_id`, a self-contained
   `prompt`, `parent_thread_id`, and a short `title`. It returns a `turn_id`. If
   the child is busy, the prompt is queued as its next turn.
4. **Yield or keep working on something else.** Completion, failure,
   cancellation, and approval-needed events arrive in your chat automatically
   (as a steering message or a new turn). Do not tail the child in a loop.
5. Follow up as needed:
   - `approve_chat_turn` (`turn_id`, `call_id`, `decision`) only when the approval
     is within what the user already authorized; otherwise ask the user.
   - `queue_chat_followup` steers a **running** child pane; `invalid_state` means
     it is idle or the provider cannot steer, so use `send_chat_message` instead.
   - `stop_chat_turn` cancels; `read_chat_thread` reads the transcript.
   - Reuse a child for a new task by calling `send_chat_message` again with a new
     `title`.
6. `list_linked_chats` shows your children; `clear_linked_chats` (with a
   `link_id`, or none to clear finished ones) unlinks them once you no longer need
   their updates. Clearing never cancels work or deletes the chat.

**No Verde thread id** (a TUI agent in a terminal pane, or an external MCP
client)? Omit `parent_thread_id`; nothing is delivered to you. Task-capable MCP
clients get a task handle from `send_chat_message`; others read
`tail_chat_turn` (with `after_seq`) when they actually need the result.

**When you are the child** (prompt wrapped in `<verde_parent_message>`): your
final reply goes to the parent agent automatically and is often relayed to the
human. Open with one or two plain sentences (outcome, anything the human must
do), then details: decisions, changed paths, verification, open risks. If you
need a human decision or are blocked, call `report_chat_blocked` with your
`turn_id` and a precise `reason`, then stop. Messages from the human in the same
chat take precedence over the parent.

## 5. Builds and shared resources

Run builds, dependency installs, and migrations as one leased command:

```bash
verde lease run --owner <your thread id> -- <command>
```

- It queues for the resource (`build`, `deps`, `db`, `browser`, `port:<n>`;
  inferred from the command, or pass `--resource`), holds it only while the
  command runs, releases on exit, and returns the command's exit status.
- If an identical command is running or just succeeded on unchanged sources, it
  replays that result. Read its `verde lease:` lines before trusting the output.
- Waiting can take minutes: run it as a background task when your shell tool
  has a short timeout. `--owner` makes your chat show "Waiting · build"; outside
  a native chat it defaults to `VERDE_SESSION_ID`.

For shared work that is **not** one command (browser automation, a dev server
on a port), use `acquire_lease` (`command`, `resources`, `owner`, short
`ttl_ms`), call it again to renew while working, and `release_lease` on success,
failure, or cancellation. Use `check_command` to see conflicts before starting
something. On a conflict, do not force or wait: use `verde lease run`, or call
`report_chat_blocked` with `waiting_for_resources: ["build"]` (etc.) and yield;
Verde starts a follow-up turn in your chat when the resource frees up.

## 6. Dev servers and processes

- Processes configured in the workspace's `verde.toml` (`[processes.<name>]`):
  `list_processes`, `start_process`, `restart_process`, `stop_process`,
  `inspect_process`, `tail_process_logs`, each with `name` and `workspace`.
- `list_processes` also shows terminal commands, agent turns, background tasks,
  and active leases. `wait_for_process` (`process_id`, `timeout_ms`, default 5
  min, max 15) returns `completed`, `replaced`, `gone`, or `timed_out`.
  **`completed` is not success:** check `process.status`, `exit_code`, `signal`,
  and `cancellation_reason`.
- Ad hoc long-running commands go in a tracked session, never `nohup`, `&`,
  `setsid`, or `disown`:
  `verde session new --workspace <id> --cwd <path> --name <name> -- <command>`.
  Read it with `tail_surface_output` / `read_surface_screen` using `session_id`,
  and `verde session kill --id <id>` it when you are done. Hold a `port:<n>`
  lease while you own a port.

## 7. Terminals

- Find terminal panes with `list_panes` (`workspace`), or open one in the
  background with `add_workspace_tab` (`kind: "terminal"`).
- Read: `read_surface_screen` (visible screen) or `tail_surface_output`
  (recent output, `lines`), addressed by `pane_id` + `workspace`, or by
  `session_id` without the GUI.
- Keys: `send_terminal_key` with `key` (`enter`, `escape`, `tab`, arrows,
  `f1`-`f12`, letters, digits, ...) plus `ctrl` / `alt` / `shift` / `super`, or a
  `chord` such as `ctrl+c`. It never changes focus or restarts a session.
- Text: `write_surface_text` (`text`) types raw input. Include a carriage return
  (`\r`) only when you mean to submit.

## 8. Built-in browser

Each workspace has an embedded browser. Browser tools take `workspace` (or
`workspace_id`) and optional `thread_id` (your thread id addresses the browser
in your own tab); unknown arguments are rejected.

1. `browser_status` first. `open_browser` (`url`) opens it in your tab's side
   panel without taking focus; `open_browser_tab` adds a background tab;
   `navigate_browser` changes the URL.
2. `inspect_browser_page` returns visible text and interactive elements with
   refs. Act with `click_browser_element` / `type_browser_text` using exactly one
   of `selector`, `ref`, `role` (+ `name`), or `label`. A new inspection
   invalidates old refs.
3. `evaluate_browser_js` takes `script` as a function **body**: write
   `return document.title;`, not a bare expression.
4. `capture_browser_screenshot` may return `unsupported` on some backends.
5. `reset_browser` / `restart_browser` only for a browser you own. Hold a
   `browser` lease for multi-step automation in a shared workspace.

## 9. Schedules

When the user wants something later or on a repeat ("in an hour", "every
weekday at 9"), create a schedule instead of waiting:

- `create_schedule` with `prompt`, `target`, `repeat`, and `parent_thread_id`
  (your thread id, so chats a run opens report back to you).
  - `target`: `{"kind":"thread","workspace_id":"...","thread_id":"..."}` or
    `{"kind":"new_chat","workspace_id":"...","provider":"codex"}`.
  - `repeat`: `{"kind":"once","at_ms":<UTC epoch ms>}`,
    `{"kind":"interval","every_minutes":120}` (5 to 10080), or
    `{"kind":"daily","time":"09:00","weekdays":[1,2,3,4,5]}` (0 = Sunday).
- `list_schedules`, `update_schedule` (`enabled: false` pauses),
  `delete_schedule`, `run_schedule` (fire now). Times are the desktop host's
  local time. The CLI equivalent is `verde schedule add|list|enable|disable|remove|run`.
