# K-10 chat engine

`chat.zig` runs inside the host transaction, owns only its correlated RPC
results, and uses the existing C/JNI host boundary. It adds no C exports or
platform I/O. `chat_models.zig` defines the native views and
`chat_catalogs.zig` ports the web composer catalogs and Usage cards. All wire
views and query envelopes are in `model_registry.zig`.

Open a thread with `thread_open {workspace_id,thread_id}` (or `focus`). Query
`thread:<suffix>` and `composer:<suffix>`, where the suffix is the percent-encoded
JSON array `[workspace_id,thread_id]`, as specified in core-api.md. Core change
notifications use those same qualified selectors. There are no desktop-mirror
RPCs, host-path uploads, or platform-side transcript reducers.

## Transcript and sends

Backward pages request 40 rows, reduced only by the negotiated page cap, with
opaque cursors. Unsupported first-page methods alone fall back to
`chat.thread.get`. Pages merge by stable message identity without replacing the
streaming overlay. A single independent parked HTTP tail tracks each observed
turn; only applied event sequences advance its cursor. Retried reads preserve
that cursor. Retention gaps refresh committed data before reseeding. Terminal
status triggers a committed transcript read before the overlay is discarded.
The shared `transcript_apply` reducer assembles streamed messages, tools and
diffs. Unknown provider events have a readable system-row fallback.

Sending freezes the draft and settings, creates an optimistic user row,
registers an ephemeral store client if necessary, upserts metadata without
transcript bodies, uploads image bytes through create/ordered append/commit,
then starts a stable turn/message ID and tails it. Append acknowledgements must
match the transmitted offset. A successful start clears only the submitted
draft revision. Ambiguous mutations are visible as uncertain and never replay
automatically. An immediate transcript refresh after start also surfaces the
A-09 gateway's durable access-cap notice while work is running.

Approval state comes from snapshots and tails, including explicit null
resolution by another client. Decisions must identify the current turn and
call. Stop remains pending until tail confirms terminal status. Shell commands
require a confirmation bound to the command and route and both chat:write and
terminal:write. Slash runs use the current daemon catalog; mentions and history
use query generations so late results cannot replace a newer search.

## Persistence and follow-ups

Thread records live at `vc/1/<host_id>/chat/<sha256(JSON identity)>` and contain
versioned draft/selection data plus the optional frozen follow-up receipt and
route. They are loaded lazily when that thread is opened; no storage-listing
API is required. All writes use the acknowledged secure-store effects; one
write per thread is in flight and later edits coalesce behind it. An attachment
is copied from the platform's `AttachmentInput`, never read from a URI. The
initial local event budget still limits total supplied bytes; a record is
bounded to 512 KiB and exhaustion returns resource_limit without committing.

There is no daemon queue/pull-back RPC. Queue/steer receipts are durable before
clearing the draft; a second durable `sending` receipt gates network dispatch.
Host receipts that chat will still update (queued follow-up, send, unacked
storage write, open request) count as in flight and survive rolling eviction,
so a settled-looking follow-up keeps its dedupe until it is dispatched.
Remote image follow-ups queue. Restored work is paused and restored `sending`
is uncertain. Retry of uncertain delivery reads tail evidence instead of
reinvoking a steer. Pull-back/cancel applies only to unsent work. Only the web's
four exact pre-acceptance invalid_state rejections permit steer fallback; RPC
converts that allowlist to a boolean and does not expose daemon error prose.
Successful parent completion can dispatch an active local queue in foreground;
failed/aborted parents leave it paused. Background/reconnect never unpauses it.

## Models and interpretation of revision 1

Composer choices retain provider IDs, effort/variant rules, access choices,
fast-mode support and dynamic catalog overrides. The usage view carries the
web's structured provider limits/statistics/recent values rather than guessing
numeric token counts from formatted prose. Only system messages authored
`Usage` are parsed. History uses the same rolling 24-hour/seven-day buckets as
K-09, with injected wall time.

The engine opens threads known to K-09's snapshot/catalog and rejects foreign
runtime/profile bindings. Workspace/thread creation and cross-host routing
remain their owning UI/runtime tasks. Thread records are restored on opening
that thread, and no background/offline queue dispatch is performed.

## Fixtures and verification

`src/fixtures/chat/record.py /absolute/path/to/verde-daemon` owns a temporary
state/config directory, private Unix socket, finite request/startup deadlines,
and deterministic teardown. It enables only the daemon's built-in hermetic
stub. It records two pages, start, tail events and committed messages; there is
no live provider, user daemon or network. The access-cap fixture is seeded
through real `chat.message.append` using A-09's exact text; it is explicitly
not represented as a gateway recording. Provenance includes the binary hash.
Ordinary tests replay the committed recordings without launching a daemon.

The host harness additionally covers stale approvals, read retries, chunk
offsets, newer draft preservation, storage acknowledgements/failures, restored
and uncertain follow-ups, explicit fallback, shell confirmation and scope
rejection. K-14 owns the real gateway/daemon end-to-end contract suite.
