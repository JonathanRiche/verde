# K-06 host skeleton

Implements the [core-api.md revision 1](core-api.md) boundary. The original
K-06 skeleton returned failed `unsupported` operations for feature intents;
K-07–K-12 supply the feature engines. K-11 implements pure markdown/highlight/
diff utility queries; see [rendering.md](rendering.md). Unknown utilities return
`unsupported`; unknown selectors/resources return `not_found`.

The C header, `root.zig` exports and Zig JNI wrappers are maintained together.
JNI methods for `dev.verdeai.core.Native` (declare `@JvmStatic external fun`):

```kotlin
fun version(): String
fun hostNew(json: ByteArray, status: IntArray): Long
fun hostFree(host: Long)
fun hostHandle(host: Long, json: ByteArray, status: IntArray): ByteArray?
fun hostQuery(host: Long, selector: ByteArray, status: IntArray): ByteArray?
```

`status` must have at least one element and receives the C `vc_status`.
Zero/null is returned on failure; a pending JVM exception is preserved.
Handles are opaque `Long` tokens. JVM arrays are copied, never pinned. Native
buffers are copied and freed inside the wrapper, so there is no JVM buffer-free
method. JNI stages through JVM output allocation as well as native allocation:
a failed output copy never consumes an event. D-02 owns the app bridge.

Each call decodes into a temporary transaction arena, clones retained state,
then allocates a clean retained arena and the entire output before committing.
No caller pointers or temporary event/effect payloads survive. Queries are pure.
C outputs use `c_allocator` and outlive the handle. Internal allocator injection
supports exhaustive allocation-failure tests. The clone strategy favors simple,
verifiable rollback over performance; future feature engines may replace it
with equivalent transactional ownership without changing the ABI.

## Conservative choices where revision 1 leaves details open

- Input limit: 1 MiB, JSON nesting: 64 levels, outstanding correlations: 256,
  lifetime receipts: 1024. Exhaustion is `vc_status=5`; receipts never evict,
  except settled `terminal_input`/`terminal_resize` receipts (D-11, [terminal.md](terminal.md)).
- Host IDs are 1–128 ASCII letters/digits/underscore/hyphen. Nonces are exactly
  32 hexadecimal digits. URLs use shared `verde_remote.profile` endpoint-pair
  validation, including same authority and `/ws`. Both endpoints may be null.
- `start` requests `profile`, then `credential`. The future receipt index belongs
  to the profile record; receipt discovery/decoding is deferred to K-07/K-10,
  because revision 1 defines no storage listing effect or index wire shape.
  Opaque stored bytes never imply pairing or authorize traffic. Missing
  credentials mean unpaired; a storage failure stays visible and does not
  become unpaired. Loaded nonempty credentials await K-07 validation.
- Background/network changes invalidate transport, but preserve all issued
  storage operations with their original generations. Shutdown invalidates
  everything. Free itself performs no I/O. Reconnect scheduling is K-07/K-08;
  the timer and cancellation machinery is exercised through internal fixtures.
- An early timer delivery consumes the old ID and emits a replacement with the
  remaining monotonic delay and a fresh ID, so a duplicate early event is stale.
- Receipt identity hashes normalized known payload fields, excluding injected
  times and unknown fields; key order is irrelevant. IDs with changed payloads
  fail with status 1. Receipts retain digests rather than sensitive payloads.
- `TransportFailure.code` is not enumerated in revision 1. The initial allowlist
  is `unknown`, `offline`, `dns`, `refused`, `reset`, `timeout`, `cancelled`,
  `certificate`, `hostname`, `pin_mismatch`, `unavailable`, `resource`.
  Adapters must map diagnostics into this vocabulary. Platform failures use
  exactly the five specified codes. Arbitrary exception text is rejected.
- K-12 now routes `terminal_reply` through the attached session pump; see
  [terminal.md](terminal.md) for its C/JNI handles and acknowledgement contract.

The harness covers ownership, independent hosts, ordered dispatch/out-of-order
completion, cancellations, generations, timer replacement/early delivery,
shutdown, failure shapes, malformed events, bounded receipts, unsupported
intents, 64-bit counters, pure queries and allocation rollback. A fake JNI table
also tests real slot indices and JVM allocation failure. The C smoke links and
calls every implemented C export. No live daemon/provider or persistent state
is used.

Panics emit only `core_invariant_failure` via Android liblog or iOS stderr,
then abort. They never print the panic text or backtrace. Signal handling and
Zig's per-thread alternate signal stack are disabled for the library.

Native wire models and the single export registry are documented in
[model-codegen.md](model-codegen.md). D-02/I-02 consume the committed generated
Kotlin/Swift files; new core features append their exported types to that registry.

K-10 implements chat intents and thread/composer queries in [chat.md](chat.md).
Chat dispatch is explicitly limited to its own intent tags so later auth and
terminal additions retain their own operation outcomes.
