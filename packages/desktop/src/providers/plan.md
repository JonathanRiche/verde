# Native Provider Plan

This directory holds the Zig-native provider implementations for `@packages/native`.

## Goal

Build a thin native harness in Zig that talks directly to:

- OpenCode over its local HTTP server
- Codex over `codex app-server`

The package should reuse each tool's existing local auth, config, and workspace behavior instead of reimplementing provider logic in another runtime.

## File Layout

- `../provider_types.zig`: shared provider-neutral request/response types
- `../harness.zig`: shared provider-neutral interface used by the native UI
- `opencode.zig`: OpenCode transport and response mapping
- `codex.zig`: Codex transport and response mapping

## Architecture

Keep the abstraction thin:

1. `main.zig` depends on `harness.zig`
2. `harness.zig` exposes shared request/response types and dispatch
3. Each provider file owns its own transport, parsing, auth checks, and provider-specific state

Do not force identical wire protocols. Normalize only the small app-facing surface:

- `connect`
- `authState`
- `listThreads`
- `sendPrompt`
- later: `streamEvents`, `approve`, `cancel`, `listModels`

## OpenCode Implementation Plan

Use the OpenCode HTTP server directly.

1. Add a small HTTP layer in `opencode.zig` using Zig stdlib HTTP client.
2. Support `base_url`, optional working directory header, and optional basic auth.
3. Implement health/auth bootstrap:
   - `GET /global/health`
   - `GET /provider`
   - `GET /config/providers`
4. Implement session flow:
   - `GET /session`
   - `POST /session`
   - `POST /session/:id/message` or `POST /session/:id/prompt_async`
   - `GET /session/:id/message`
5. Convert OpenCode responses into `harness.ChatThreadSummary` and `harness.SendPromptResult`.
6. Add SSE support for `GET /global/event` if streaming is needed in the UI.
7. If `launch_if_missing` stays enabled, optionally spawn `opencode serve` when health checks fail.

### OpenCode Notes

- Prefer direct HTTP first; it is the simplest provider to get working.
- Keep JSON decoding typed with `std.json`; do not use `any`.
- Do not store editor runtime behavior in persisted chat data.

## Codex Implementation Plan

Use `codex app-server` directly from Zig.

1. Start with WebSocket transport as the primary path.
2. Spawn `codex app-server --listen ws://127.0.0.1:4500` from Zig using `std.process.Child`.
3. Build a small WebSocket client in Zig that can:
   - open and close the socket cleanly
   - send one JSON-RPC message per text frame
   - receive request responses and notifications on the same stream
   - reconnect or fail cleanly if the socket drops
4. Build a small JSON-RPC client layer on top:
   - incrementing request ids
   - request/response correlation
   - notification routing
   - graceful shutdown
5. Implement initialization flow:
   - send `initialize`
   - send `initialized`
6. Implement auth/account flow:
   - `account/read`
   - `account/login/start` when explicit login UX is added
   - `account/logout`
7. Implement thread and turn flow:
   - `thread/start`
   - `turn/start`
   - consume streamed notifications until completion
   - handle `item/agentMessage/delta` and final turn completion
8. Add backpressure handling for WebSocket mode:
   - detect JSON-RPC `-32001`
   - retry with exponential backoff and jitter
   - avoid flooding the socket with overlapping requests
9. Map final assistant output into `harness.SendPromptResult`.
10. Add handling for approvals and server requests later:
   - `tool/requestUserInput`
   - `serverRequest/*`
11. Keep `stdio` JSONL as a fallback transport for debugging and protocol comparison.

### Codex Notes

- The official app-server docs still describe WebSocket as experimental, so the implementation should expect protocol churn and queue limits.
- WebSocket is still a good fit for a native rich client if we own reconnect, retry, and message routing explicitly.
- Auth should ride through the installed Codex binary rather than adding a second auth stack in native code.
- We need explicit process lifecycle handling so the UI does not leak child processes.

## Shared Harness Work

`harness.zig` should stay small and only own:

- shared enums and data types
- provider config union
- provider client union
- dispatch for common calls

It should not own provider-specific parsing, endpoint paths, or JSON-RPC method names.

## Integration Steps For `main.zig`

After the transport code exists:

1. Import `harness.zig`
2. Replace the placeholder provider replies in `sendDraft()`
3. Store one connected provider client per thread or per project
4. Append streamed/provider replies into the transcript
5. Surface auth and connection failures in the existing sidebar notice area

## Testing Plan

1. Add small inline Zig tests for parsing and message conversion in each provider file.
2. Add smoke tests for:
   - OpenCode health and session creation
   - Codex app-server initialization and thread creation
3. Keep live-provider tests opt-in so local CI does not require both CLIs installed.

## Immediate Next Steps

1. Flesh out `harness.zig` with thread/model/event APIs once the first transport is wired.
2. Implement OpenCode first to establish the harness shape against a simpler protocol.
3. Implement Codex WebSocket JSON-RPC second, with `stdio` retained as a fallback path.
4. Only then wire `main.zig` to the new harness.
