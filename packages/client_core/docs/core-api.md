# Mobile client core API, revision 1

Status: K-03 specification for orchestrator review before K-06. This is a
proposed local ABI and JSON contract, not a claim that the exports exist yet.
Only `vc_version` exists in the current [header](../include/verde_client.h).
K-06 implements the boundary; K-07–K-12 implement the features below. The
[plan §5](../../../docs/mobile-app-plan.md#5-the-zig-client-core-packagesclient_core)
and [task definitions](../../../docs/mobile-app-tasks.md) define scope.

## 1. Ownership and ABI

One host handle represents one saved host profile, including its auth,
connection, sync, chat and terminal-pump state. The platform owns the host
list, active-host selection and one handle per loaded profile. `hosts` returns
one host row; the platform concatenates these rows, never merges runtime data.
A local `host_id` survives re-pairing and is distinct from the remote
`runtime_id`. Thread identity is `(host_id, workspace_id, local_thread_id)`;
a provider thread ID is not a local thread ID.

The core performs no sockets, filesystem access, thread creation, clock reads,
OS entropy reads or platform callbacks. It returns effects. The platform runs
those effects and serializes their completions back onto the owning executor.
Android uses a single-thread coroutine dispatcher per host; Swift uses an
actor per host. Calls on one handle must never overlap or re-enter. Separate
hosts and independent terminal handles may run concurrently. No global
current-host state is permitted.

The following declarations are **new API to implement**, including the local
C types; they are not existing headless wire types:

```c
typedef struct vc_host vc_host;
typedef struct vc_term vc_term;
typedef struct { unsigned char *ptr; size_t len; } vc_buf;
/* 0 = success, 1 = invalid argument/JSON, 2 = unsupported API revision,
   3 = allocation failure, 4 = invalid lifecycle, 5 = resource limit. */
typedef int32_t vc_status;

vc_status vc_host_new(const unsigned char *json, size_t len, vc_host **out);
void vc_host_free(vc_host *host);
vc_status vc_host_handle(vc_host *host, const unsigned char *json,
                         size_t len, vc_buf *out);
vc_status vc_host_query(vc_host *host, const unsigned char *selector,
                        size_t len, vc_buf *out);
void vc_buf_free(vc_buf buf);
const char *vc_version(void);
```

Use C `size_t`/`int32_t` from the standard headers. Inputs are borrowed only
for the duration of a call; any retained strings/bytes are copied. Null input
is legal only with zero length. Strings are UTF-8, length-delimited, not
NUL-terminated. Outputs use `std.heap.c_allocator` and remain valid across
subsequent calls and even handle destruction. Free each exactly once with
`vc_buf_free`; `{NULL,0}` is a no-op. Never free the static `vc_version` string.
Constructors clear `*out` on failure; buffer-returning functions clear `*out`
before work. No Zig error, panic, exception or arena pointer crosses the ABI.
Invalid pointers and use-after-free remain caller bugs.

A call arena holds decoding and temporary work; retained state and output
buffers have separate ownership. An allocation/encoding failure must not
silently commit an event while losing its effects: stage and commit state and
the complete output together. Malformed events leave state unchanged.
JNI mirrors these operations, copying JVM byte arrays; it must not retain a
pinned JVM pointer. Native handles are opaque tokens to Kotlin. C buffers are
copied and freed by the wrapper before returning to Kotlin. K-06 maintains
the header, exports and JNI wrappers together.

Constructor JSON:

```json
{"api_version":1,"host_id":"phone-profile-1","label":"Dev host",
 "https_url":"https://host.example","wss_url":"wss://host.example/ws",
 "client_revision":1,"session_nonce":"platform-generated-128-bit-hex",
 "jitter_seed":12345}
```

The platform generates fresh cryptographic `session_nonce` and a jitter seed
for each handle; the core derives local operation IDs from nonce + counters.
This is not device authentication material. Pair exchange nonces are supplied
separately by the pairing intent and retained across retries. URL validation
uses the shared profile rules and requires HTTPS/WSS for mobile; reject URL
userinfo, fragments and credential query parameters. Discovery cannot silently
change a trusted origin. URLs may be null for an unpaired profile; the `pair` intent supplies and
validates them before any transport effect. A new handle starts inert;
construction emits no I/O.

## 2. JSON framing, IDs and time

Every event has `{api_version:1,type,now_ms,wall_time_ms,...payload}`.
`now_ms` is platform monotonic milliseconds, nondecreasing for the handle;
`wall_time_ms` is Unix milliseconds, used for token expiry/history. The core
never obtains time itself. Re-evaluate expiries on foreground/network events;
wall-clock changes do not move monotonic timers. Injected seed and time make
harness runs deterministic.

`vc_host_handle` returns `{api_version:1,revision,effects:[...]}`. Each effect
has `{type,effect_id,generation,...payload}`. IDs are opaque strings unique
within the handle, including across reconnects. `generation` is a decimal
string counter incremented when transport/sync work is invalidated. Platform
completion events echo the effect's ID and generation. A WS connection uses
its opening `effect_id` as `socket_id` on all subsequent events. Timers have
unique `timer_id`s; replacing a timer allocates a new ID. Unknown, duplicate,
cancelled or old-generation completions are ignored and return an empty batch.
Storage operations are tracked separately: reconnecting must not discard a
pending credential write; only shutdown/removal invalidates those completions.

A user intent has `intent_id`, retained in its operation result. Repeated IDs
with identical payload return the existing outcome, never send twice; reuse
with a different payload is rejected. Completed receipts are retained for the
handle lifetime within a bounded budget; on exhaustion reject new intents
with `resource_limit`, do not evict IDs and accidentally replay mutations.
Persistence receipts extend this protection across process death where noted.
Daemon RPC IDs are numeric `u64` as required by `protocol.Request`, independent
of local correlation IDs. Match response IDs as well as the owning HTTP effect.

The adapter must execute every effect from a successfully returned batch or
report its typed failure; dropping a batch is a host-fatal integration error.
It must not replay a batch after partial execution.

All local JSON counters, revisions, offsets and sequences that may exceed
2^53 are decimal strings. Pixel/grid sizes and bounded millisecond delays are
JSON integers; timestamps fit signed 64-bit milliseconds. Daemon JSON remains
unchanged: convert losslessly in the core, never via a floating-point parser.
Nullable fields use explicit `null`; arrays are always arrays. Ignore unknown
object fields for forward compatibility, reject unknown input event tags and
unsupported `api_version`. Unsupported feature intents return an operation
error rather than being silently accepted by the K-06 skeleton.

Effects in a batch are ordered for dispatch, not completion. Issue independent
HTTP requests concurrently; a parked tail must not block an interactive send
or approval. Dependencies are expressed by waiting for completion before
emitting the dependent effect. The platform may complete synchronously but
must enqueue that event after the current call returns. Queries are pure and
never drain effects, start requests or advance timers.

## 3. Lifecycle and platform events

The connection phase follows existing `connection.Phase`: `disabled`,
`connecting`, `handshaking`, `awaiting_trust`, `ready`, `failed`, `reconnecting`.
The local host model adds `lifecycle` (`created`, `foreground`, `background`,
`stopped`), `auth_state` (`loading`, `unpaired`, `paired`, `repair_required`)
and `sync_state` (`empty`, `loading`, `ready`, `stale`). These are orthogonal.

| Event | Payload and behavior |
| --- | --- |
| `start` | `foreground:bool, network_available:bool`; once per handle, read stored profile/credentials and local receipts. No authenticated I/O until reads and trust checks succeed. |
| `foreground` | Resume auth, handshake/snapshot and active tails; repeated events are harmless. |
| `background` | Immediately close WS, cancel polling/reconnect timers and HTTP work; mark views stale. Finish already-issued storage writes. No automatic queued send while backgrounded. |
| `network_changed` | `available:bool, network_id:string`; invalidate transport attempts on a changed network, reconnect with shared jittered backoff only while foregrounded and available. |
| `http_response` | `effect_id,generation,status:int|null,headers:[{name,value}],body_base64:string|null,error:TransportFailure|null`; exactly one HTTP response or transport failure. Body contains original bytes, even for non-2xx responses. |
| `ws_open` | `socket_id,generation,protocol:string`; handshake completed, never means core sync is ready. |
| `ws_message` | `socket_id,generation,text:string`; one complete text message, fragments assembled by platform. Binary/oversized frames close with a protocol failure. |
| `ws_closed` | `socket_id,generation,code:int|null,clean:bool,error:TransportFailure|null`; also reports failed opens. Do not pass an arbitrary peer reason into logs. |
| `timer_fired` | `timer_id,generation`; one-shot, at or after its deadline. Ignore cancelled IDs; if delivered early re-arm for the remaining delay. |
| `secure_store_value` | `effect_id,generation,key,value_base64:string|null,error:PlatformFailure|null`; null without error means missing, not storage failure. |
| `secure_store_done` | `effect_id,generation,key,error:PlatformFailure|null`; acknowledgement for put/delete, required before dependent auth/send effects. |
| `tls_peer` | `effect_id,generation,origin,spki_sha256,system_trusted:bool`; preflight result for the same origin, before sending sensitive bytes (see below). |
| `terminal_applied` | `effect_id,generation,terminal_id,grid_revision,error:PlatformFailure|null`; acknowledgement that a PTY output batch reached its VT handle. |
| `terminal_reply` | `terminal_id,bytes_base64`; raw VT-generated device reply, as described in §10. |
| `shutdown` | Stop all networking/timers, invalidate callbacks and emit needed cancellations; does not revoke or erase pairing. No later event except duplicate shutdown is accepted. |

`TransportFailure` is a new local shape `{kind,code}`: `kind` is `network`,
`timeout`, `cancelled`, `tls`, `server_unavailable` or `resource`; `code` is a
small allowlisted platform diagnostic, never exception text. `PlatformFailure`
is `{code}` with `unavailable`, `locked`, `denied`, `io` or `resource`.

Before `vc_host_free`, run shutdown's cancellations, detach the platform's
callback routing and ensure no call is in flight. Free itself performs no
I/O and cannot return cleanup effects. Host free never frees independently
created terminal handles. App termination may prevent shutdown; persisted
state must recover without assuming callbacks were delivered.

## 4. Effects

| Effect | Payload and executor contract |
| --- | --- |
| `http_request` | `method,url,headers:[{name,value}],body_base64:string|null,timeout_ms,max_response_bytes,tls:{origin,spki_sha256}`. Report one `http_response`; no automatic application-level retry, redirects or cookie/Origin injection. Enforce the response byte cap while streaming. |
| `http_cancel` | `request_id`; cancel locally, never interpreted as undoing a daemon mutation. Late responses are harmless. |
| `ws_open` | `url,protocols:[string],tls:{origin,spki_sha256},max_message_bytes`; protocols include `verde.v1` and a single-use `verde.ticket.<ticket>`, never a ticket in the URL. |
| `ws_send` | `socket_id,text`; ordered on that socket. Send failures report `ws_closed`; no interactive/parked RPCs here. Reserved for negotiated feed controls in K-16. |
| `ws_close` | `socket_id,code`; idempotent local close. |
| `set_timer` | `timer_id,delay_ms,purpose`; one-shot monotonic timer. `purpose` is a non-sensitive enum for tests/diagnostics. |
| `cancel_timer` | `timer_id`; idempotent cancellation. |
| `secure_store_get` | `key`; return `secure_store_value`. |
| `secure_store_put` | `key,value_base64`; atomic durable replacement; return `secure_store_done`. |
| `secure_store_delete` | `key`; absent already is success; return `secure_store_done`. |
| `state_changed` | `revision,scopes:[query-selector]`; coalesced once per batch, after state commit; platform re-queries affected selectors. |
| `notify` | `notification_id,kind,title,body,target:{host_id,workspace_id,thread_id},actions:[string]`; sensitive UI content, not a log. Platform chooses native presentation; focused-pane suppression is owned by the core (K-17). |
| `log` | `level,code,fields`; fixed event codes and allowlisted counts/statuses only. No bodies, paths, URLs, headers, pair links, tokens, credentials, clipboard or provider error text. |
| `tls_probe` | `origin`; platform performs system trust validation and obtains SPKI without transmitting pair/device secrets, reports `tls_peer`. |
| `terminal_output` | `terminal_id,reset:bool,bytes_base64,next_offset`; adapter resets/recreates VT when requested, writes bytes once, then reports `terminal_applied`. |

The last two effects, `http_cancel`, `secure_store_done`, `tls_peer`,
`terminal_applied` and `shutdown` are deliberate additions to the plan's sketch:
they close the TLS, cancellation, persistence and separate-VT ownership loops.

TLS uses normal platform certificate/hostname validation **and** the accepted
SPKI SHA-256 pin. A probe is not authorization to send secrets: every actual
HTTP/WS connection must enforce the pin before request bytes leave the device,
including when connection pooling is used. A changed key requires explicit
re-trust. Never accept an invalid system certificate just because its key is
pinned. Trust UI reads a proposal from `hosts`; `trust_decision` names its ID.
Persist the accepted proposal before pairing/auth. Existing `pin_controller`
models durable runtime identity adoption; its current file performs I/O and
does not implement SPKI validation. K-04/K-07 reuse the pure decision rules,
not its filesystem implementation or an imaginary existing TLS API.

Storage keys are scoped as `vc/1/<host_id>/<record>`, where host IDs are locally
generated safe components. Records are `profile`, `credential`, and encoded
thread-specific `draft`/`followup` receipts. Never concatenate unescaped daemon
IDs into paths. Platforms may implement content receipts in encrypted app-local
storage behind this interface; credentials use Keystore/Keychain and no cloud
backup. Access tokens and WS tickets remain in memory only. Missing credentials
mean unpaired; locked storage means retry/unlock, not unpaired. Write failures
remain visible in host/composer errors and must not lose drafts. Queries and
logs never expose stored credentials or tokens.

## 5. User intents

Each row is an event `type`, with common event fields and `intent_id`.
Optional values below may be null. These are new local names, not RPC names.

| Intent | Payload / result |
| --- | --- |
| `pair` | `link,device_label,client_nonce`; parse supported custom/App Link form, code only from fragment. Keep nonce stable across a lost exchange response. Manual entry is normalized by the platform to the same link. |
| `trust_decision` | `proposal_id,accept:bool`; reject stale proposals. Denial leaves host disabled without auth traffic. |
| `retry_connection` | Retry a recoverable connection; cannot override identity/TLS rejection. |
| `focus` | `workspace_id,thread_id,terminal_id` nullable; controls active reads, PTY pump and foreground attention suppression. |
| `thread_open` / `thread_load_older` | `workspace_id,thread_id`; load first/next transcript page, one outstanding older-page request per thread. |
| `history_search` / `history_load_more` | `query,workspace_id` / no extra fields; results live in `workspaces.history`, new query invalidates previous cursor. |
| `draft_set` | `workspace_id,thread_id,text,attachments:[AttachmentInput]`; replace and persist local draft. |
| `composer_select` | `workspace_id,thread_id,provider,model,effort,access,speed`; validate against available catalogs. |
| `send` | `workspace_id,thread_id,draft_revision`; snapshot draft/settings into a stable operation, reject stale revision or unsupported scope. |
| `turn_cancel` | `workspace_id,thread_id,turn_id`; cancellation is pending until daemon state confirms. |
| `followup_submit` | `workspace_id,thread_id,draft_revision,kind:queue|steer`; stable receipt before dispatch. |
| `followup_retry` / `followup_pull_back` / `followup_cancel` | `workspace_id,thread_id,followup_id`; enforce delivery state, not just UI button state. |
| `approval_decide` | `workspace_id,thread_id,turn_id,call_id,decision:approve|deny`; explicit current approval only. |
| `shell_prepare` / `shell_confirm` | `workspace_id,thread_id,command` / `confirmation_id,accept`; confirmation is bound to exact command, cwd, host and thread. |
| `slash_search` / `slash_run` | `workspace_id,thread_id,query` / `workspace_id,thread_id,command,args`; use daemon catalogs. |
| `mention_search` | `workspace_id,thread_id,query`; latest query wins; no local file reads. |
| `terminal_create` | `workspace_id,cwd,cols,rows`; daemon session only (paired mobile uses `session.*`). |
| `terminal_attach` / `terminal_detach` | `terminal_id`; subscribe/unsubscribe local pumping, does not kill the remote session. |
| `terminal_input` | `terminal_id,vt_modes:{application_cursor,bracketed_paste},input:{kind:text|key|paste,text?,key?,ctrl,alt,shift}`; core encodes keys and ordered paste chunks. |
| `terminal_resize` | `terminal_id,cols,rows`; positive bounded grid, coalesce pending resize. |
| `terminal_kill` | `terminal_id`; explicit session kill. |

`AttachmentInput` (new local type) is `{local_id,name,mime,byte_size,
bytes_base64}`. Platform reads picker data before the event; the core never
opens a picker URI or host path. Bound decoded bytes by advertised attachment
limits and reject oversized inputs before allocating/uploading. Initial API
copies supplied bytes; chunking is on the remote upload, not hidden platform
file callbacks. The view model exposes metadata and upload progress, never
base64 payloads. A cached attachment without bytes after restart requires
reselection; do not silently send only its text.

## 6. Queries and new local view models

Required UTF-8 selectors: `hosts`, `home`, `workspaces`, `thread:<id>`,
`composer:<thread>`, `terminal:<id>`. Thread suffix is a percent-encoded JSON
array `[workspace_id,local_thread_id]`, terminal suffix an encoded session ID;
decode once. This avoids collisions without assuming IDs are globally unique.
`<id>` is a placeholder, not a literal identifier.

Each returns `{api_version:1,revision,data,error}`. `error` is null on success;
unknown selector/resource returns `data:null` and a local typed error.
`state_changed.scopes` uses these exact selectors; `workspaces` invalidates its
history too. `revision` is a monotonically increasing local view revision,
not the daemon store revision. Query results are complete immutable snapshots.
Arrays use stable IDs and deterministic order; native widgets diff by ID.
All shapes in this section are **new** local types for K-06/K-09–K-12/K-15.
Fields marked `?` mean nullable, not unspecified data.

| Selector | `data` shape |
| --- | --- |
| `hosts` | `{items:[Host],operations:[Operation]}` (exactly this handle's host) |
| `home` | `{items:[Pane],loading,stale,incomplete_scopes:[string],error:Error?}`; attention/running order follows web projection, stable ID tie-break. |
| `workspaces` | `{items:[Workspace],loading,stale,error:Error?,history:{query,items:[ThreadSummary],next_cursor:string?,loading,error:Error?}}` |
| `thread:<id>` | `{thread:ThreadSummary,rows:[Row],page:{has_older,cursor:string?,loading},turn:Turn?,approval:Approval?,usage:Usage?,stale,error:Error?}` |
| `composer:<thread>` | `{draft:{revision,text,attachments:[Attachment],persisted},selection:{provider,model,effort,access,speed},catalogs:{models:[Choice],efforts:[Choice],access:[Choice],speeds:[Choice],slash:[Choice]},mentions:[{path,label}],provider_ready,can_send,can_stop,send_operation:Operation?,followup:Followup?,shell_confirmation:{id,command,cwd}?,error:Error?}` |
| `terminal:<id>` | `{terminal_id,workspace_id,label,session_status,attached,cols,rows,next_offset:string?,grid_revision,stale,error:Error?}`; grid cells come from the independent VT snapshot below. |

Supporting shapes:

- `Host`: `{host_id,label,https_url,runtime_id?,instance_id?,phase,lifecycle,
  auth_state,sync_state,capabilities:[string],scopes:[string],retry_at_ms?,
  trust_proposal:{id,origin,spki_sha256,runtime_id?}?,update_required,error?}`.
- `Workspace`: `{workspace_id,label,path,open,panes:[Pane],threads:[ThreadSummary]}`.
- `Pane`: `{id,workspace_id,kind:chat|terminal|browser,title,thread_id?,
  terminal_id?,status,attention,started_at_ms?,can_stop}`. Browser is a
  placeholder only. Never synthesize a working terminal from a missing session.
- `ThreadSummary`: `{workspace_id,thread_id,title,provider,model?,cwd?,open,
  archived,last_activity_at_ms?,status,history_bucket}`. Normalize the existing
  wire seconds timestamp to milliseconds. Buckets use injected wall time.
- `Row`: `{id,role,kind,body,created_at_ms?,delivery:optimistic|streaming|committed|failed,
  attachments:[Attachment],tool:{id,kind,status}?,subagent:{thread_id,title}?,
  citation:{path,line?}?}`. K-11 parses `body` through utility queries; unknown
  provider content falls back to readable text, never silently disappears.
- `Attachment`: `{local_id,name,mime,byte_size,attachment_id?,reference?,
  uploaded_bytes,status,error?}`; `reference` is daemon-returned, not a phone path.
- `Turn`: `{turn_id,status,after_seq,started_at_ms?,elapsed_ms,stop_pending}`.
- `Approval`: `{turn_id,call_id,title,body,resolution:idle|pending|failed,error?}`.
- `Followup`: `{id,kind:queue|steer,state:pending|sent_inline|fallback_next_turn,
  delivery:unsent|sending|uncertain|accepted,turn_id,steer_id,next_turn_id,text,
  attachments:[Attachment],paused,can_retry,can_pull_back,error?}`.
- `Choice`: `{id,label,enabled,reason?,favorite}`; IDs preserve provider values.
- `Usage`: `{input_tokens?,output_tokens?,cached_tokens?,cost?,currency?,
  context_used?,context_limit?}`; missing/unreported values remain null, not zero.
- `Operation`: `{intent_id,state:pending|succeeded|failed|uncertain,error:Error?}`.
  Keep asynchronous intent outcomes queryable in `hosts.operations` even if
  their screen is no longer focused.

## 7. Auth, RPC and sync behavior

K-07 exchanges pairing for a device credential using the existing access
protocol. It saves credentials successfully before token minting. Token refresh
is single-flight, scheduled two minutes before `expires_at_ms`. On 401, refresh
and retry the rejected authorized operation once; a second auth rejection
marks `repair_required` and stops automatic traffic. Transport loss after a
mutation is not proof of a 401 or of non-delivery. Do not re-pair on an ordinary
network failure. WS reconnect always obtains a new single-use ticket.

The existing `PairingGrantExchangeRequest` has no `client_nonce` at the initial
K-03 baseline: A-05 must add idempotent exchange before K-07 enables automatic
exchange retry. Likewise, App Link parsing is K-07 work; do not imply the old
request parser accepts additional fields (it is strict).

K-08 uses `core.status` for initial unpinned discovery, validates runtime
identity/protocol, then includes `target:{runtime_id,instance_id}` on **every**
other RPC, including `core.capabilities`. All RPCs use HTTP `/api/rpc`; WS is
push-only in K-09. The gateway response is decoded by the shared headless codec;
do not invent a JSON-RPC 2.0 envelope or copy the internal `Response.err` field
name into wire JSON. Respect negotiated `RuntimeLimits`, including body/page/
parked-wait caps; large legacy snapshots need an explicit bounded allowance
(up to existing `protocol.MAX_MESSAGE_BYTES`), not unbounded buffering.

A changed instance on the same verified runtime invalidates old callbacks,
volatile state and cursors, and silently triggers handshake + full resync.
Changed runtime identity or TLS pin requires trust intervention. Never replay
an uncertain mutation into a new instance merely because reads resumed.

K-09 requests `core.snapshot` with scopes `workspaces,registry,sessions,turns,
config`, then pages `chat.thread.list`; it does not load every transcript.
Use `CoreSnapshotResult.incomplete_scopes` honestly. Match web
`panesForWorkspace`, `parseWorkspaceLayout`, `mergeThreadCatalogSettings` and
attention ordering. Persisted layout indices use thread `sort_index`, not the
index of a filtered/paginated list. Omitted snapshot scopes do not clear cached
sections. Cursors belong to their query and revision; expiration restarts that
query and de-duplicates by stable identity.

Legacy WS `core.hello`, `core.snapshot` and `core.changes` are decoded from the
existing gateway pushes. Changes contain identities/revisions, not resource
payloads. Coalesce invalidations while refresh is in flight and perform another
refresh if a later change arrived; never advance a cursor beyond incorporated
state. Do not opt into delta mode in K-09. K-16 adds negotiated delta behavior
after A-11; `expired`, a changed `instance_nonce`, or `revision_expired` requires
a full snapshot and cursor reseed. `instance_nonce` is the registry revision
namespace, not `instance_id` or the TLS pin. Never call the desktop-mirror RPCs
`workspaces`, `panes` or `chat.status`.

## 8. Chat behavior (K-10)

Load `chat.message.list` in pages of 40 with its opaque cursor; fall back to
`chat.thread.get` only for unsupported paging, not arbitrary failures. Merge
older pages by message ID without dropping the current streaming overlay.
Tail with `chat.turn.tail` and `after_seq`, one outstanding tail per turn.
Advance only through applied events, ignore replayed sequence numbers and
resume after recoverable failures. Use `transcript_apply` for overlay assembly;
on `completed`, `failed` or `aborted`, reconcile committed rows before clearing
the overlay. Retention expiry fetches committed transcript/current turn state
before reseeding; do not append duplicate partial output.

Send: freeze draft/settings → optimistic row → `chat.thread.upsert` → each
`chat.attachment.create`, ordered `append` chunks, `commit` → `chat.turn.start`
→ tail. Respect server upload offsets/limits, preserve operation/turn IDs on
safe retry, and retain the draft on failure. Clear only the submitted draft
revision, never newer typing. No host-path upload shortcut. For ambiguous
start/upsert/upload outcomes, reconcile using existing wire idempotency and
read APIs; expose `uncertain` where delivery cannot be established.

Port `followups.ts`: no daemon queue or pull-back RPC exists. Persist a receipt
before dispatch; restore `sending` as `uncertain`, with restored work paused.
Only explicit user retry resumes restored work. Preserve steer/next-turn IDs;
a lost steer response never automatically becomes a new queued turn. Only the
web's explicit pre-acceptance rejection rules permit fallback. Pull-back/cancel
is allowed only for unsent work. Remote image follow-ups queue for the next
turn. Auto-dispatch a locally active queue only after successful parent
completion while foregrounded; aborted/failed parents leave it paused.

Approval comes from the current turn summary/tail (`approvalFromTurn` rules),
not only an approval event. `chat.turn.approve` uses `turn_id`, `call_id` and
`approve|deny`; mark pending and reconcile approval resolved by another client.
Shell confirmation precedes `chat.shell.run`. Port web model/effort/access,
usage and history rules, use `provider.slash.list`/`provider.slash.run` and
`workspace.files.search`. Draft changes emit acknowledged persistence effects.

## 9. Pure rendering utilities (K-11)

In addition to string selectors, `vc_host_query` accepts a UTF-8 JSON utility
selector. These calls are pure, do not change view revision and use the same
query envelope/error model. Types here are proposed output types:

- `{utility:"markdown",text}` → `{nodes:[Node]}`. `Node` has
  `{kind,start,end,text?,level?,ordered?,url?,language?,children:[Node],
  citation:{path,line?}?}`. Kinds: document, paragraph, heading, text, emphasis,
  strong, strike, code, code_block, link, image, list, item, quote, thematic_break,
  line_break, table, table_row, table_cell. Raw HTML is inert text. Parse with
  `zig_markdown`; expose citations as abstract targets, never auto-open paths.
- `{utility:"highlight",text,language}` → `{spans:[{start,end,kind}]}` via
  `zig_treesitter`. Unsupported language returns empty spans and plain text.
- `{utility:"diff",text}` → `{files:[{old_path?,new_path?,binary,hunks:[{old_start,
  old_count,new_start,new_count,lines:[{kind,text,old_line?,new_line?,
  spans:[{start,end,kind}]}]}]}]}`. Line kinds: context, add, delete, meta;
  span kinds: add, delete. Match web `parseDiffV2` for `VERDE_DIFF_V2`, using
  `zig_dif` parsing where applicable; malformed input returns a typed error
  so the renderer can show source text.

Offsets are half-open UTF-8 byte offsets into the supplied source (highlight/
markdown) or the returned line text (diff spans). Native bridges translate to
UTF-16/String indices; offsets never split a code point. Citation and diff line
numbers are one-based; absent numbers are null. Utility calls are bounded by
input/output budgets and never fetch links, files, images or grammars online.

## 10. Terminal handles and pump (K-12)

Proposed terminal ABI uses the same ownership/status rules:

```c
vc_status vc_term_new(const unsigned char *json, size_t len, vc_term **out);
vc_status vc_term_write(vc_term *term, const unsigned char *bytes, size_t len);
vc_status vc_term_resize(vc_term *term, uint16_t cols, uint16_t rows);
vc_status vc_term_snapshot(vc_term *term, vc_buf *out);
vc_status vc_term_scroll(vc_term *term, int32_t delta_rows);
void vc_term_free(vc_term *term);
```

Constructor JSON is `{api_version:1,cols,rows,scrollback_rows}`; dimensions must
be positive, scrollback bounded. Write consumes raw VT bytes (not necessarily
UTF-8), retaining partial escape/UTF-8 sequences in libghostty-vt. Scroll uses
positive rows toward older history, negative toward live bottom and clamps.
Resize changes only the local emulator; platform also sends `terminal_resize`
to the host to request `session.resize`. A terminal handle is not a remote PTY
and freeing it never kills the daemon session. Use the desktop's dependency pin.

Snapshot returns `{api_version:1,revision,cols,rows,scroll_offset,scrollback_rows,
reply_bytes_base64,reverse_video,vt_modes:{application_cursor,bracketed_paste},cursor:{row,col,visible,shape},cells:[Cell],title}`. Cells are
row-major, exactly `cols*rows`; `Cell` is `{text,width,fg,bg,bold,italic,
underline,strikethrough,inverse}`. Width is 0 for continuation, 1 or 2 for a
leading cell; colors are resolved `#RRGGBB`; row/col are zero-based. Cursor
shape is block, underline or bar. This is a new renderer model, not a direct
export of libghostty internal structs. Return a full visible grid initially;
future dirty-region optimization must be additive. Snapshot is read-only for
the grid; its reply-byte queue is drained only after successful output
allocation, so the same generated reply is not sent repeatedly. Never log
grid contents.

Host pump uses `session.tail {id,offset?,max_bytes}` and response `next_offset`,
`text`, `running`, `truncated`. Omit offset on initial replay; trim that replay
using `alignPtyStream` rules, without deriving the daemon offset from trimmed
text length. Emit one `terminal_output` at a time; commit next offset only on
`terminal_applied`. On failure retry/reset rather than skip bytes. On truncation
or new session, reset emulator and replay. Poll at 160 ms with new output,
1 s while idle, only for attached terminals in the foreground. Resume from
known offsets on reconnect; a recreated VT requires a fresh initial replay.

The platform routes `terminal_output` to its terminal handle and publishes a
new grid snapshot; it performs no PTY parsing. Key encoding belongs in the
core: Ctrl character mapping, Alt escape prefix, named Escape/Tab/Enter/
Backspace/Delete/arrows/Home/End/PageUp/PageDown, and paste chunks of at most
4096 UTF-8 bytes without splitting code points. Preserve order, never retry
ambiguous input automatically. The two boolean `vt_modes` flags come from the
latest VT snapshot and accompany `terminal_input`: application cursor selects
SS3 versus CSI arrows; bracketed paste wraps the complete paste once with
start/end markers, not once per chunk. The platform forwards these flags
without encoding keys itself. Terminal replies to device-status queries are
returned as `reply_bytes_base64` by `vc_term_snapshot` (drained on snapshot);
the adapter submits a `terminal_reply` event with `terminal_id,bytes_base64`.
That event is distinct from a user intent and routes the raw reply through
`session.write`, with no logging or automatic replay.
Use `session.create/resize/write/kill` only. A-02 deliberately leaves desktop
`terminal.*` unmapped for paired devices. K-12 implementation details and
bounds are in [terminal.md](terminal.md).

## 11. Errors and recovery

The new local `Error` is `{domain,code,message,failure_kind?,retryable,
retry_after_ms?,intent_id?,rpc_code?,delivery:rejected|uncertain|null}`.
Domains: input, lifecycle, transport, auth, identity, protocol, rpc, storage,
resource. Messages are sanitized for UI; diagnostics log only fixed codes.
Daemon `protocol.Error.code`/structured data are interpreted in the core;
unknown daemon error codes remain visible as an RPC error, never success.
`failure_kind` uses existing `connection.FailureKind`: authentication, network,
server_unavailable, identity, protocol, wrong_service, resource. Only network
and server_unavailable have general automatic reconnect eligibility; retrying
a connection does not authorize replaying a mutation.

Distinguish malformed local API calls (nonzero `vc_status`, no state change)
from a valid intent rejected by policy/daemon (successful handle call with a
failed `Operation`, invalidated query and no unauthorized effect). Unknown
query/utility errors use the query envelope. Missing scopes disable affected
controls and return typed denial; they do not trigger re-pair loops. Protocol
or `mobile.min_client` incompatibility sets `update_required`. Resource limits
must fail visibly, not truncate transcripts or acknowledge unprocessed bytes.

## 12. Existing code anchors and implementation checks

These are existing sources, not proposed mobile type definitions:

| Contract | Existing source / names |
| --- | --- |
| RPC envelope, errors, target, limits | [protocol.zig](../../headless/src/protocol.zig): `Request`, `Response`, `RequestTarget`, `Error`, `StatusResult`, `RuntimeLimits`, `MobileCompatibility`; `core.status`, `core.capabilities` |
| Snapshot and transcript paging | [store_protocol.zig](../../headless/src/store_protocol.zig): `CoreSnapshotRequest`, `CoreSnapshotResult`, `ThreadListRequest`, `ThreadListResult`, `MessageListRequest`, `MessageListResult`, `ThreadGetRequest`, `ThreadGetResult`, `ThreadUpsertRequest`, `TurnRecord`; `core.snapshot`, `chat.thread.list`, `chat.message.list`, `chat.thread.get`, `chat.thread.upsert`, `chat.shell.run` |
| Feed | [changes_protocol.zig](../../headless/src/changes_protocol.zig): `ChangeEntry`, `ChangesResult`; `core.changes`. Gateway `core.hello`/snapshot/change push framing: [http.zig](../../web_app/src/http.zig) |
| Auth | [access_protocol.zig](../../headless/src/access_protocol.zig): `PairingGrantExchangeRequest`, `PairingGrantExchangeResult`, `RuntimeEndpointMetadata`, `AccessTokenResult`, `WebSocketTicketResult`, `requiredScopeMaskForRpc`; auth/discovery paths and protocol headers |
| Chat turns and terminal dispatch | [sessionizer.zig](../../desktop/src/terminal/sessionizer.zig): `chat.turn.start`, `chat.turn.tail`, `chat.turn.cancel`, `chat.turn.steer`, `chat.turn.approve`, [ipc/server.zig](../../desktop/src/ipc/server.zig) owns `terminal.open`; [dispatch.zig](../../headless/src/dispatch.zig) also records headless methods |
| Attachments | [attachment_protocol.zig](../../headless/src/attachment_protocol.zig): `chat.attachment.create`, `chat.attachment.append`, `chat.attachment.commit` |
| Catalogs | [providers_protocol.zig](../../headless/src/providers_protocol.zig): `provider.models.list`, `provider.slash.list`, `provider.slash.run`; file search: [dispatch.zig](../../headless/src/dispatch.zig), `workspace.files.search` |
| Sessions | [session_protocol.zig](../../headless/src/session_protocol.zig): `Method`, `SessionStatus`; [pty.ts](../../web_app/web/src/lib/pty.ts) for tail offsets and `alignPtyStream` |
| Shared extraction inputs (K-04 may move these) | [connection.zig](../../desktop/src/runtime/connection.zig): `Phase`, `FailureKind`; [pin_controller.zig](../../desktop/src/runtime/pin_controller.zig); [transcript_apply.zig](../../desktop/src/chat/transcript_apply.zig) |
| Web behavior to port | [store.ts](../../web_app/web/src/lib/store.ts), [followups.ts](../../web_app/web/src/lib/followups.ts), [models.ts](../../web_app/web/src/lib/models.ts), [usage.ts](../../web_app/web/src/lib/usage.ts), [history.ts](../../web_app/web/src/lib/history.ts), [ChatPane.tsx](../../web_app/web/src/ui/ChatPane.tsx) (`parseDiffV2`) |

K-06 harness must prove input/output ownership, ordered effects with out-of-order
completions, timer replacement, duplicate/stale callbacks, shutdown, invalid
JSON and atomic allocation-failure behavior. K-07 adds lost pairing response,
storage failure, trust and single-flight refresh fixtures; K-08 adds identity
restart and uncertain-mutation fixtures; K-09 adds legacy push/paging fixtures;
K-10 adds transcript/follow-up/approval replays; K-11/K-12 add golden render/VT
fixtures. Use temporary state and recorded fixtures from a temporary daemon,
never the user's daemon or live providers. K-13 checks every actual outgoing
method against `requiredScopeMaskForRpc`; method existence does not imply
paired-device authorization before A-02.

Review decisions: one host per handle; explicit storage acknowledgements and
cancellation; platform time/entropy; decimal local 64-bit counters; pure utility
queries; separate VT handles with acknowledged byte delivery; no mutation
replay after uncertain delivery. No blocking product decision is required.
A-05 exchange nonce and A-11 delta protocol remain their owning tasks' wire
additions, not invented existing RPCs. Future terminal protocols beyond the
two specified mode flags require an additive extension and matching fixtures.
