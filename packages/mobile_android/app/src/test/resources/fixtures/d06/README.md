# D-06 transcript fixtures

Every `thread-*.json` / `composer-*.json` file is a verbatim query envelope
(`{api_version, revision, data, error}`) returned by the real client core for the
`thread:` / `composer:` selectors of `["chat-fixture-ws","chat-fixture-thread"]`.
`render.json` holds real K-11 utility results. The Android tests only replay these; the
fake core in `TranscriptTest` never invents projections.

## Provenance

Captured with the core's own chat harness (`packages/client_core/src/chat_test.zig`,
`Fixture`), replaying the K-10 recorded daemon responses in
`packages/client_core/src/fixtures/chat/` (wall clock `1790363191000 + now_ms`):

| File | Core state |
| --- | --- |
| `thread-loading.json` | first focus, page request in flight (no rows yet) |
| `thread-open.json` | first page: 40 rows, `has_older`, cursor `b:5` |
| `thread-loading-older.json` | `thread_load_older` in flight |
| `thread-older.json` | after the older page: 45 rows, no more history |
| `thread-running.json` | recorded send, turn `fixture-turn` running, optimistic prompt overlay |
| `thread-streaming.json` | recorded tail seq 1 (`stub-ok`) applied, still running |
| `thread-stopping.json` | `turn_cancel` accepted, `stop_pending` |
| `thread-completed-overlay.json` | terminal tail event, reconcile page pending |
| `thread-committed.json` | reconciled page incl. the A-09 `access-cap:fixture` notice |
| `thread-error.json` | page rejected by the runtime (`remote_error`) |
| `composer-*.json` | composer projection at idle / running / stopping / committed |

**Derived (not K-10 recordings):**

- `thread-rich.json` is the same core projection after loading `rich-page.input.json`.
  That file is a hand-written daemon `chat.message.list` response covering the row kinds
  D-06 renders: image attachment, think, command/read/failed tool calls, subagent,
  VERDE_DIFF_V2 "Changed files", markdown with citation/link/list/quote/code/table,
  notice and Codex usage.
- `thread-streaming.json` stops the recorded tail after its first event, so a
  running-with-partial-output state exists.

`render.json` is `[{query:{kind,text,language?}, result}]`. It holds the core's `markdown`
result for every distinct row body above, the `highlight` result for the rich reply's
`ts` block, and the `diff` result for the rich diff row.

## Regenerating

Add a temporary test to `chat_test.zig` that drives the same `Fixture` steps and prints
`f.query(selector)` / `h.query("{\"utility\":…}")` for each state, then run
`zig build test` in `packages/client_core` (take the `build` lease) and split the output
into these files. Revert the temporary test afterwards; nothing here is generated at
build time.

## Fake-core fallback

The scroll/anchoring test synthesizes 500+ rows with bodies that are not in the
recording. For those bodies only, the fake answers `markdown` with a single
document → paragraph → text AST (`highlight`: no spans, `diff`: no files) and counts it
in `fallbackRenders`. Tests over recorded bodies assert that count is 0.
