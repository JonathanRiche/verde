# Verde MCP tools

Every tool exposed by the `verde` MCP server (`verde mcp`, or the HTTP server
registered by **Settings → Agents → Enable Verde MCP**). **Bold** parameters are
required. **RO** marks tools annotated read-only (safe to call without asking).

Workspace selectors: `workspace_id` wants a stable id; `workspace` accepts an id,
index, path, or `current`. Prefer stable ids.

## Discovery and chats

| Tool | Parameters | Notes |
| --- | --- | --- |
| `list_workspaces` (RO) | none | Durable workspaces from the session daemon. |
| `list_panes` (RO) | `workspace` | Chat and terminal panes grouped into tabs. |
| `list_chat_threads` (RO) | `workspace_id`, `query`, `open`, `limit`, `cursor` | Search chat history, including closed chats. |
| `read_chat_thread` (RO) | **`workspace_id`**, **`local_thread_id`** | Durable transcript, works without the GUI. |
| `open_chat` | **`workspace_id`**, **`provider`**, `parent_thread_id`, `model`, `reasoning_effort` or `reasoning_variant`, `fast_mode`, `target_pane_id`, `axis` | Creates a durable thread; never creates workspaces or takes focus. |
| `present_chat` | **`workspace_id`**, **`local_thread_id`**, `target_pane_id`, `axis` | Shows (and reopens if closed) a saved chat without focus. |
| `send_chat_message` | **`workspace_id`**, **`local_thread_id`**, **`prompt`**, `parent_thread_id`, `title`, `project_path`, `turn_id` | Returns `turn_id`; queued if the thread is busy. `turn_id` makes retries idempotent. |
| `queue_chat_followup` | **`workspace_id`**, **`pane_id`**, **`prompt`**, `image_paths`, `steer_id`, `parent_thread_id` | Steers a running turn; `invalid_state` when idle or unsupported. Reuse `steer_id` on retry. |
| `tail_chat_turn` (RO) | **`turn_id`**, `after_seq` | Streamed events and status, for clients without automatic delivery. |
| `approve_chat_turn` | **`turn_id`**, **`call_id`**, `decision` (`approve`/`deny`) | Answers a pending tool approval. |
| `stop_chat_turn` (destructive) | **`turn_id`**, `followup_pending` | Stopping a finished turn is a no-op. |
| `get_chat_draft` (RO) / `set_chat_draft` | `pane_id` or `local_thread_id` (+ `workspace_id`), `text`, `append` | Reads or stages composer text without sending. |
| `list_linked_chats` (RO) | **`workspace_id`**, **`parent_thread_id`** | Your delegated children and their status. |
| `clear_linked_chats` | **`workspace_id`**, **`parent_thread_id`**, `link_id` | Unlinks one child, or all finished ones. Does not cancel. |
| `report_chat_blocked` | **`turn_id`**, **`reason`**, `waiting_for_resources` | Notifies the parent (or user), then yield. Resources such as `build` or `port:3000` resume you automatically when free. |
| `add_workspace_tab` | `kind` (`chat`/`terminal`), `workspace` | Opens a background tab without changing selection. |
| `close_pane` (destructive) | **`workspace`**, **`pane_id`** | Only when the user asked. |

## Schedules

| Tool | Parameters | Notes |
| --- | --- | --- |
| `list_schedules` (RO) | `workspace_id` | Soonest first, with last-run status. |
| `create_schedule` | **`prompt`**, **`target`**, **`repeat`**, `name`, `parent_thread_id`, `parent_workspace_id`, `enabled`, `created_by` | See target/repeat shapes in SKILL.md. Works without the GUI. |
| `update_schedule` | **`id`**, `name`, `prompt`, `target`, `repeat`, `enabled` | Only passed fields change. |
| `delete_schedule` (destructive) | **`id`** | Chats from earlier runs are kept. |
| `run_schedule` | **`id`** | Runs now; a one-time task is used up. |

`target.provider` for `new_chat` accepts `codex`, `claude`, `opencode`,
`cursor`, `pi`, or `grok`.

## Leases and processes

| Tool | Parameters | Notes |
| --- | --- | --- |
| `list_processes` (RO) | `workspace` | Configured processes, terminal commands, agent turns, background tasks, active leases. |
| `check_command` (RO) | **`command`**, `resources`, `owner`, `workspace` | Classifies a command and reports conflicts before you start it. |
| `acquire_lease` | **`command`**, `resources`, `owner`, `ttl_ms` (default 120000, max 1 h), `force`, `workspace` | Call again to renew. Never set `force` without the user's say-so. |
| `release_lease` | `lease_id`, `owner`, `workspace` | Omitting `lease_id` releases all of the owner's leases. |
| `wait_for_process` (RO) | **`process_id`**, `timeout_ms` (default 300000, max 900000), `workspace` | `completed` is not success; read status and exit fields. |
| `start_process` / `restart_process` / `stop_process` | **`name`**, `workspace` | `verde.toml` processes; start and restart keep focus. Stop and restart are destructive. |
| `inspect_process` (RO) | **`name`**, `workspace` | |
| `tail_process_logs` (RO) | **`name`**, `workspace`, `lines` | |

Pass your Verde thread id as `owner`; chats on the same provider otherwise
share one owner. It defaults to `VERDE_SESSION_ID`.

## Terminals

| Tool | Parameters | Notes |
| --- | --- | --- |
| `read_surface_screen` (RO) | `pane_id` + `workspace`, or `session_id` | Visible screen text. |
| `tail_surface_output` (RO) | `pane_id` + `workspace`, or `session_id`; `lines` | Recent output. |
| `send_terminal_key` | `pane_id` + `workspace`, or `session_id`; `key` + `ctrl`/`alt`/`shift`/`super`, or `chord` | Keys: `enter`, `escape`, `tab`, `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`, `backspace`, `delete`, `space`, `f1`-`f12`, `a`-`z`, `0`-`9`. |
| `write_surface_text` | `pane_id` + `workspace`, or `session_id`; **`text`** | Raw write; can restart a stopped session. |
| `list_surfaces` (RO) / `inspect_surface` (RO) | | Registered terminal control surfaces; use `list_panes` for ordinary panes. |
| `notify_surface` / `clear_surface_attention` | | Set or clear a terminal surface's status and attention. |

`session_id` addressing talks to the session daemon directly and needs no GUI.

## Browser

All browser tools accept `workspace` or `workspace_id` (default: the agent's
workspace) and `thread_id` (address the browser in that chat's tab). Unknown
arguments are rejected.

| Tool | Parameters | Notes |
| --- | --- | --- |
| `browser_status` (RO) | | URL, tabs, last action result. |
| `open_browser` | `url` | Opens in your tab's side panel without focus. |
| `open_browser_tab` | **`url`** | Background tab in the existing browser pane; returns `tab_index`. |
| `navigate_browser` | **`url`** | |
| `inspect_browser_page` (RO) | `max_elements` (100), `text_limit` (12000) | Visible text plus interactive elements with refs. |
| `click_browser_element` | one of `selector`, `ref`, `role` (+ `name`), `label`; `confirmed` | Sensitive actions need `confirmed: true` after user confirmation. |
| `type_browser_text` | one target as above; **`text`**, `submit`, `confirmed` | Passwords and submission need confirmation. |
| `evaluate_browser_js` | **`script`**, `timeout_ms` (default 30000, max 60000) | Function body; use `return`. |
| `browser_pointer_input` | **`action`** (`pointerDown`/`pointerMove`/`pointerUp`), **`x`**, **`y`**, `button`, modifiers | Pane-local coordinates. |
| `capture_browser_screenshot` (RO) | | PNG when the backend supports CPU-frame capture. |
| `reset_browser` (destructive) / `restart_browser` | | Blank document / recreate backend. Only on a browser you own. |

## Remote runtimes

| Tool | Parameters | Notes |
| --- | --- | --- |
| `pair_runtime` | **`link`**, `label`, `device_label`, `expect_runtime_id` | The `verde://pair` link is a one-time secret: never echo or log it. |
| `runtime_pair_status` | **`profile_id`** | `exchanging`, `awaiting_confirmation`, `paired`, `failed`, `unknown_profile`. |
