# D-09 approval fixtures

Every `approval-*.json` file is a verbatim `thread:` query envelope returned by the real client
core for `["chat-fixture-ws","chat-fixture-thread"]`. `ApprovalTest` replays them; its fake core
only synthesizes operation receipts (as in D-06), never thread projections.

## Provenance

Captured with the core's chat harness (`packages/client_core/src/chat_test.zig`, `Fixture`):
`open()` replays the K-10 recorded first page, `seedTurn()` starts turn `fixture-turn`, and
`chat.turn.tail` replies carry `pending_approval` exactly as the daemon's `writePendingApproval`
emits it (`{call_id,title,body}`).

| File | Core state |
| --- | --- |
| `approval-edit.json` | pending Claude `Edit` request (bridge `approvalRequestBody` shape: `Tool:`/`Path:` sections + tool input JSON), `idle` |
| `approval-command.json` | pending Codex `Command approval` (bare command body), `idle` |
| `approval-pending.json` | after `approval_decide` (approve), before the RPC answers: `resolution: pending` |
| `approval-stale.json` | `chat.turn.approve` answered JSON-RPC `not_found` ("approval not found", as the daemon does for a resolved/replaced call): `resolution: failed`, `rpc_code: not_found`; the core mirrors it into `thread.error` |
| `approval-failed.json` | `approval_decide` (deny) then a transport timeout: `resolution: failed`, `delivery: uncertain` |
| `approval-sent.json` | `chat.turn.approve` accepted; still `pending` until the tail clears it |
| `approval-resolved.json` | the next tail reports `pending_approval: null` with the turn still running |

## Regenerating

Add a temporary test to `chat_test.zig` that drives those `Fixture` steps and prints
`f.query("thread")` for each state, run `zig build test --release=safe` in
`packages/client_core` (take the `build` lease), split the output into these files and revert the
temporary test. Nothing here is generated at build time.
