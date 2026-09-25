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

## D-04 sign-out and local removal

`sign_out {host_id}` uses targeted, authenticated `device.self.revoke` and
consumes only its correlated RPC result. A rejected access token follows the
normal single refresh/retry flow; only a definitive repeated unauthorized
result marks the credential invalid. An identity mismatch or ordinary transport
failure never counts as revocation. Already invalid credentials can be removed
without another RPC. A successful result must have the expected device identity
and access protocol version.

Offline, unavailable authentication, timeout, cancellation and ambiguous
responses return an `uncertain` operation with `sign_out_unconfirmed`; persisted
credentials remain intact. The UI may retry with a new intent ID or explicitly
send `forget_host {host_id}`, warning that the device may still be listed on the
desktop and should be revoked there. `forget_host` is also accepted while a
revoke is still pending (for example behind a stalled token refresh); that
`sign_out` operation then becomes `uncertain`. Neither intent can target another
handle.

Once removal starts, transport/timers are cancelled, in-memory tokens and
projections are dropped, and `auth_state` becomes `signing_out`. The core deletes
`credential`, then `profile`, waiting for each secure-store acknowledgement.
Failure leaves `sign_out_delete_failed` visible; `retry_connection` (or a new
removal intent) retries the failed delete without repeating remote revocation.
Only the final acknowledgement produces `auth_state:signed_out` and a succeeded
operation. Outstanding storage writes/reads must finish before removal starts.
A new pairing intent can then reuse the same host ID with fresh trust. Shutdown
still preserves pairing; it is not sign-out. Process interruption between deletes
can leave a pin but no credential, so no authenticated traffic can resume.

These intents are exported through the existing `Event` registry entry as
`EventSignOut` and `EventForgetHost`; no new C or JNI functions are required.
