# K-08 RPC integration

`src/rpc.zig` runs inside `host.Transaction`; call its methods on a staged
transaction and commit the output batch using the existing host machinery.
It has no additional C/JNI exports or public platform events.

K-07 calls `attachBearer(tx, token, verified_runtime_id, accepted_spki_sha256)`
after trust and auth succeed, then `beginHandshake(tx)` when foreground and
online. Attachment copies its inputs and sends nothing. `clearBearer` blocks
new requests; invalidate transport when revoking trust or stopping outstanding
work. A different runtime cannot be silently attached to an existing pin.
Token minting, refresh, ticket creation and reconnect scheduling remain K-07.

`request(tx, method, params, options)` returns a numeric daemon ID and emits a
POST to `/api/rpc`. Every request except `core.status` includes both target IDs.
There is no RPC-over-WS path. Status validates identity/protocol/limits and
issues targeted `core.capabilities`; completion marks the connection ready.
Interactive calls and parked calls are independent effects. Options bound
parked waits, pages and responses; callers supply actual daemon parameters.
Mutations are the conservative default; specify `mutation=false` for reads.
An `intent_id` associates the result with the feature engine's receipt. The
feature engine must enforce intent deduplication before calling this layer.

K-09/K-10/K-12 drain `takeResult(tx)` inside the completion transaction and
apply the returned DOM or typed error to their own models before committing.
The bounded result queue never evicts outcomes. `takeFullResync(tx)` requests
clearing volatile projections/cursors and fetching a full snapshot after a
successful handshake. `host.state.stale` remains true until the sync engine
applies that snapshot. An instance change on the verified runtime cancels old
work and advances the host generation; mutations get uncertain outcomes and
are never replayed. A target-mismatch rejection re-discovers status, allowing
instance restarts without treating them as runtime trust changes.

Only network/server-unavailable FailureKind classes are reconnect eligible.
That eligibility never authorizes automatic mutation replay. HTTP 401 is an
auth failure for K-07; HTTP 403 is a scope denial and must not cause re-pairing.
Errors keep RPC codes but never copy daemon message text into UI messages.

Conservative choices: missing numeric response IDs are protocol errors even
though the generic codec accepts uncorrelated null-ID error envelopes. Legacy
snapshot responses require `legacy_snapshot=true` and are capped at the wire
8 MiB maximum; ordinary responses use negotiated limits. HTTP event input has
a 12 MiB ceiling to accommodate base64 plus framing. Other local events retain
the skeleton's 1 MiB limit. No automatic request replay is implemented here.
