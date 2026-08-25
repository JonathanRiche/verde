# Pi Provider (pi.dev)

`pi.zig` integrates the [pi coding agent](https://pi.dev) as a GUI chat
provider through pi's programmatic RPC mode: `pi --mode rpc` speaks strict
JSONL (LF-delimited, one JSON object per line) over stdin/stdout. There is no
bridge process; Verde spawns the `pi` binary directly, one process per turn
(the claude.zig per-turn model, not a resident server).

Validated against pi 0.84.2.

## Process model

- **Turn**: `pi --mode rpc [--session-id <uuid>] [--model <provider/id>]
  [--thinking <level>]` with piped stdio. Verde writes a `get_state` command
  (id `state-0`) to learn the session id, then the `prompt` command
  (id `turn-1`), then streams events until `agent_settled` or EOF.
- **Queries** (auth/model/state lookups) spawn short-lived processes guarded
  by a 10s `QueryDeadline` watchdog that terminates the process tree on
  expiry — never block readiness on provider I/O (see the opencode
  readiness-freeze incident).
- Active turns are registered in a process registry keyed by thread id so
  `interruptThread` can terminate the exact child; a `StopMonitor` polls
  `on_should_stop` every 20ms.

## Harness call → pi RPC mapping

| Verde harness call    | pi surface                                                        |
| --------------------- | ----------------------------------------------------------------- |
| `sendPrompt`          | `prompt` command; images as base64 `images[]` attachments         |
| `steerThread`         | `prompt` with `"streamingBehavior": "steer"` (id `steer-N`)       |
| `interruptThread`     | registry `terminateTree` of the turn's process                    |
| `authState`           | `get_state` → provider, then `pi auth check --provider X --json --no-refresh` |
| `listModels`          | `get_available_models` → `data.models[]`                          |
| `listThreads`         | reads `~/.pi/agent/sessions/<encoded-cwd>/*.jsonl` (cwd-filtered) |
| `readThread`          | parses the session JSONL transcript                               |
| `slashCommands`       | none (empty list; `runSlashCommand` → `error.UnsupportedOperation`) |

## Event mapping

| pi event                                | Verde stream surface                          |
| --------------------------------------- | --------------------------------------------- |
| `message_update` `text_delta`           | `on_stream_delta` (turn reply accumulator)    |
| `message_update` `thinking_*`           | ignored in v1 (follow-up: render thinking)    |
| `tool_execution_start` (bash)           | `.message` titled exactly `Ran command`, body = command |
| `tool_execution_end` (bash, `isError`)  | `.message` titled exactly `Command failed`, body = command |
| `tool_execution_start/update/end`       | `tool_call` lifecycle updates (stable `toolCallId`) |
| `agent_settled`                         | turn completion (authoritative done signal)   |
| `message_end` assistant `stopReason:"error"` | records `errorMessage` → `on_failure` (prompt response stays `success:true` in this case) |
| response `success:false`                | `.pi_rpc` diagnostics + `on_failure`          |

Tool kinds: `read` → `.read`, `edit`/`write` → `.edit`, `bash` → `.execute`,
everything else `.other`.

## Identity, models, reasoning

- **Thread id** = pi session UUID (from the pipelined `get_state` response),
  reported via `on_thread_id`; resume passes `--session-id <uuid>`. Sessions
  are project-scoped by cwd, which is why `listThreads` filters on the
  session header's `cwd`.
- **Model ref** = pi's `"provider/id"` string, passed via `--model`. The
  sentinel `"default"` omits the flag so pi uses its configured model
  (`DEFAULT_PI_MODEL`).
- **Reasoning**: Verde `ReasoningEffort` tags (low/medium/high/xhigh/max) are
  passed verbatim as `--thinking <tag>` — pi's thinking levels are a strict
  superset-compatible match.
- No service tier (Fast/Default hidden), no sandbox mode, no approvals.

## Capability wiring elsewhere

- Enums: `providers/types.zig` (`pi`), `db/types.zig` (`pi = 4`, persisted —
  never renumber), `app/config.zig` `ChatProvider`. `ChatTitleProvider`
  deliberately excludes pi.
- Steering: daemon `chat.turn.steer` accepts `.pi` alongside `.claude`
  (`terminal/sessionizer.zig`).
- Readiness: `commandExists("pi")` + authState probe
  (`state/provider_controller.zig`).
- HERDR panes, agent-TUI stack profiles (`stack_config.AgentProvider`), and
  `SurfaceProvider` have no pi entry yet (mapped to unknown/unsupported).

## Limits

`MAX_RPC_LINE_BYTES` 8MB, `MAX_IMAGE_FILE_BYTES` 16MB,
`MAX_SESSION_FILE_BYTES` 64MB, `SESSION_LIST_HEAD_BYTES` 64KB,
`RPC_QUERY_DEADLINE_MS` 10s.

## Known v1 gaps

- Thinking deltas are consumed but not rendered.
- `extension_ui_request` prompts are ignored (queries time out after 10s).
- `pi auth check --no-refresh` reports expired-but-refreshable OAuth as
  signed out.
- `get_available_models` may list models whose provider is not authenticated;
  the list is surfaced as-is.
- No bundled pi logo asset; UI falls back to the "P" letter glyph.
