# K-09 legacy sync and projections

`sync.zig` consumes K-08's full-resync signal after a verified handshake and
requests `core.snapshot` with `workspaces,registry,sessions,turns,config`, then
pages the cross-workspace `chat.thread.list` query. It never fetches transcripts
or uses desktop-mirror RPCs. `Host.handle` pumps owned results before committing;
other engines' RPC outcomes remain queued. Internal `@sync` correlations let a
new resync discard superseded sync results without discarding chat outcomes.

WS connections belong to K-07. After socket/generation validation the host feeds
legacy `core.hello`, `core.snapshot` and `core.changes` notifications to sync.
The gateway wraps the daemon RPC response in notification `params`; sync unwraps
that envelope. There is no `core.changes.mode` request or delta subscription.
Changes invalidate reads and coalesce while a snapshot/catalog refresh runs.
A later invalidation schedules one more refresh. Heartbeat cursors are not
acknowledged; the incorporated cursor is the snapshot cursor after its catalog
finishes. Instance changes use K-08's handshake path; registry nonce changes or
expired change journals reset sync and fetch again. Catalog expiration/revision
changes restart that query and stable workspace/thread identities deduplicate
rows. Repeated/non-string cursors fail visibly instead of looping.

`applySnapshotScopes` accepts the *request's* scopes. The daemon serializes empty
section defaults even for omitted scopes, so field presence alone cannot decide
whether to clear a section. K-09's HTTP and legacy gateway snapshots request all
five scopes. The scoped helper preserves omitted sections for future callers.
`incomplete_scopes` remains visible in Home. Failures preserve the last usable
view and mark it stale. Background/network invalidation cancels transport via
K-06/K-08; K-07 owns reconnect scheduling.

`projection.zig` ports the detached branches of web `store.ts`: persisted layout
binding uses `sort_index`, stable identities deduplicate panes, open committed
web threads survive layout lag, subagents are excluded from fallback panes,
missing terminal sessions are unavailable placeholders, and live unmatched
sessions are included. The no-layout fallback is limited to 16 recent threads.
Catalog controls omitted by older daemons inherit snapshot/previous values;
explicit nulls remain explicit. History uses rolling 24-hour/seven-day buckets
with injected wall time, and converts wire seconds to milliseconds. Home places
attention first, then orders ties by stable workspace-qualified pane IDs.
Notification transition/suppression state remains K-17; chat/terminal actions
remain K-10/K-12. K-09 introduces no C/JNI exports.

Pane, ThreadSummary and Workspace are registered in K-15's model registry;
Home/History/Workspaces collections now use these types. Generated Kotlin and
Swift files are committed with them.

## Fixture provenance

`src/fixtures/sync/record.py /absolute/path/to/verde-daemon` starts its own daemon
with `TemporaryDirectory`, explicit `--data-dir`, isolated XDG config/data,
a private Unix socket, five-second RPC deadlines, and bounded startup/teardown.
It seeds only synthetic threads/layout via `state.snapshot.replace`, records
full/config-only snapshots, two catalog pages (`limit:2`), and change results.
No TCP listener, providers, desktop, or user daemon are used. The script stops
and waits for its child in `finally`. `provenance.json` records the binary hash
and protocol version. Random runtime nonces/cursors are kept as recorded.
Harness adversarial cases derive additional inputs from those fixtures; they
are not represented as daemon recordings. Ordinary tests do not start a daemon.
