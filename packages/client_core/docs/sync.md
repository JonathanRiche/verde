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
that envelope. K-09 itself sends no `core.changes.mode` request (see K-16 below).
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

## K-16 delta mode

`sync_delta.zig` opts into the gateway's A-11 delta feed only when
`core.changes.delta.v1` is advertised in the handshake capabilities; otherwise
everything above is unchanged (the K-09 tests are the legacy-host baseline).

**Seed and opt-in.** On a verified handshake the core first reads the resume
checkpoint (`vc/1/<host_id>/sync`). Without a usable one it seeds exactly like
K-09 (all five scopes plus the catalog), then sends
`{"method":"core.changes.mode","params":{"mode":"delta","cursor":C},"target":…}`
on the socket that delivered `core.hello`, where `C` is the incorporated cursor.
The explicit cursor makes the gateway replay every change after the seed, so
the gateway's bootstrap `core.snapshot` push and any feed frames that arrive
before the acknowledgement (or during a recovery refresh) are ignored rather
than applied. The acknowledgement must echo the id, `mode:"delta"` and `C`.
After it the core never requests a full snapshot unless it falls back.

**Scoped refreshes.** Each `core.changes` notice is validated (same
`instance_nonce`, not `expired`, `next_cursor` not behind the last seen cursor,
entries within it) and mapped to snapshot scopes: `workspace`, `chat.thread`,
`chat.completion` → `workspaces` plus a catalog re-page; `surface` →
`workspaces`; `chat.turn` → `turns`; `process`/`lease` → `registry`;
`session` → `sessions`; `notification` → nothing (the cursor advances without a
read). Unknown topics refresh every scope but stay in delta mode. `config` is
not journaled, so it rides along with every scoped read. Replayed entries at or
below the last seen cursor are skipped; notices that arrive during a read are
coalesced into one follow-up read. Scoped reads go through the same
`applySnapshotScopes` merge and projection path as legacy reads, and the cursor
advances only after the read (and its catalog) commits, so delta and legacy
produce identical projections for the same daemon state.

**Fallback.** An expired journal, a changed nonce, a regressed or invalid
notice, a notice carrying an error, or a failed scoped read drops the cursor and
runs a K-09 full refresh, then opts in again with the new cursor. After three
recoveries on one socket, an opt-in rejection (including the id-0 invalid
request reply of older gateways) or no acknowledgement within 10 s, that socket
stays on K-09 handling. The gateway cannot leave delta mode, but it keeps
delivering `core.changes` (and recovery snapshots), which K-09 already treats as
full invalidations. The next socket tries again.

**Resume.** Transport invalidation keeps the incorporated inputs. A reconnect
to the same `instance_id` with complete, error-free inputs skips the seed and
opts in at the saved cursor; the gateway replays anything missed while
offline. A scoped read cancelled by the transport keeps the previous cursor, so
the replay repeats it. A different instance reseeds.

**Checkpoint.** After each incorporated cursor the core stores
`{version:1, runtime_id, instance_id, nonce, cursor (decimal string), snapshot,
catalog}` in the secure store. Only one write is in flight; newer cursors
coalesce behind it and an unchanged cursor is not rewritten. A cold start with a
record for the same runtime and instance restores it (validating nonce,
envelope and catalog identities) and resumes without any snapshot request.
Missing, corrupt or foreign records only cost a seed. Write failures are not
sync errors; the next cursor retries. Records over half the local input limit
(512 KiB) are deleted once instead of left to resume from an ever-older cursor.

**Conservative choices and follow-ups.**
- Catalog changes re-page the whole cross-workspace catalog. Per-thread
  refresh needs a single-thread read and is a follow-up.
- The checkpoint is written on every incorporated cursor. Debouncing it, or
  moving it to app-local encrypted storage for large hosts, is a follow-up.
- Sign-out and forget-host (D-04) delete `vc/1/<host_id>/sync` after the
  credential and profile. The checkpoint's own completion hook only claims its
  in-flight read or write, so the wipe's delete reaches D-04.
- `Checkpoint` is internal persisted state, not an exported model, so the
  model registry and generated Kotlin/Swift files are unchanged.

### Delta fixture provenance

`src/fixtures/delta/record.py /abs/verde-daemon /abs/verde-web <leased-port>`
starts its own daemon (`TemporaryDirectory` data, private Unix socket, isolated
HOME/XDG) and a gateway bound to `127.0.0.1` on a leased port with a random
token file. It seeds one synthetic thread, records the seed, `core.hello`, the
bootstrap push, the opt-in acknowledgement, one `chat.thread` change, the
matching scoped (`workspaces,config`) and full reads, then closes the socket,
edits the thread while offline, reconnects, opts in at the saved cursor and
records the replayed change and the reads after it. It asserts that only
`core.changes` frames follow an acknowledgement. Both children are stopped and
awaited in `finally`. `provenance.json` records binary hashes and the protocol
version. The tests re-key recorded acknowledgements to the core's request id;
other adversarial notices are synthesized from the recorded nonce.
