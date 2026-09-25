# K-07 authentication engine

`src/auth.zig` plugs into the transactional host engine. It adds no C/JNI
exports. All effects use the existing revision-1 contract. `auth_harness.zig`
exercises the real host handle boundary without network, files, or live state.

Pairing proceeds through system-validated TLS probe → pinned public discovery
→ explicit trust proposal → durable profile acknowledgement → exchange →
durable credential acknowledgement → access token → single-use ticket → WS.
Every actual HTTP/WS effect includes the observed/accepted SPKI constraint.
Adapters must enforce it before sending bytes, including on pooled connections.
Discovery never changes the requested origin. Runtime/SPKI/origin changes need
explicit trust; an instance change on the same runtime/key updates the durable
profile before authentication resumes. Changed runtime identity cannot reuse an
old device credential.

Accepted links are exactly `verde://pair?...#code=...` and
`https://verdeai.dev/pair?...#code=...`. Both require one `host` and one
`grant_id`; unknown/duplicate query fields, noncanonical identifiers, insecure
origins, and secrets outside the fragment fail closed. The nonce is exactly 32
lowercase hex characters. A grant/nonce remains in private memory through a
lost response and credential-save failure, then is discarded after the durable
credential acknowledgement. There is no cross-process automatic pair retry.
Automatic exchange retries require `access.pair.idempotent.v1` from pinned
discovery. Legacy lost responses become `uncertain`; create a new grant.

## Local persistence and trust representation

Revision 1 does not prescribe record payloads or the SPKI string encoding.
K-07 uses canonical lowercase 64-character hex for SHA-256 SPKI digests and
versioned JSON bytes encoded in the existing `value_base64` field:

- `vc/1/<host_id>/profile`: `{version:1,origin,wss_url,spki_sha256,runtime_id,instance_id}`.
- `vc/1/<host_id>/credential`: `{version:1,runtime_id,device_id,device_credential,scopes}`.

A `hosts.items[].trust_proposal` is either null or
`{id,origin,spki_sha256,runtime_id}`. Proposal IDs are opaque
correlation IDs, invalidated with the transport generation. Accepted proposals
are not adopted until their write succeeds. Denial disables traffic. Storage
failures remain visible; `retry_connection` retries the failed read/write without
turning locked storage into an unpaired profile. The platform should pass stored
records back unchanged and protect credentials with Keystore/Keychain.

## Token and consumer integration

Tokens remain private in `State.auth`; queries contain no token/credential/grant.
Refresh is single-flight, two minutes before wall-clock expiry. Foreground and
network changes re-evaluate time and redo TLS/discovery. Backgrounding cancels
transport/timers but preserves issued writes and their original correlations.
Token replacement closes the previous socket and requests a fresh ticket.
No ticket is reused or put in a URL. Authentication stops in `repair_required`
after one rejected credential/token retry. Ordinary transport failures use the
shared bounded jittered exponential delay and never imply revocation.

`auth_rpc.zig` bridges K-08's correlated HTTP completions: on a first 401 it
holds the rejected call, single-flights refresh, then re-emits exactly the same
encoded envelope and numeric RPC ID with a new effect ID and token. A second
401 finishes the rejected call and enters `repair_required`. A 403 is a scope
denial, never a refresh/re-pair trigger. Transport failures are never replayed.
The RPC call retains only its bounded request body and retry metadata for this
purpose. Background/network/trust invalidation cancels waiting retries too.

New tokens attach through K-08's `attachBearer`; initial/reconnected sessions
start its `core.status` → targeted `core.capabilities` handshake. Auth exposes
`unauthorized(tx, already_retried)` for future non-RPC HTTP consumers, which
must retain their own one-retry bit and rejected operation. Instance-only RPC
invalidation keeps the already verified TLS/token context; external lifecycle
and trust changes clear it. K-09 owns snapshot readiness/projections.

Conservative choices: discovery is required before credential transmission;
tokens with two minutes or less remaining are rejected to avoid refresh loops;
HTTP auth bodies are capped at 64 KiB; no redirects, cookies or Origin injection
are permitted. The adapter's existing HTTP contract enforces these restrictions.
