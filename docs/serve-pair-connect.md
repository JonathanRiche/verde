# Verde Serve, Pair, and Connect

Status: product and protocol contract with the first complete account-free
Serve/Pair network-authentication slice implemented. The open-source boundary includes account-free
Serve/Pair and a runnable self-hostable Connect reference control plane. A
private Verde Cloud deployment may operate and extend that reference service,
but it is not required.

Store-backed runtimes now advertise `access.pair.v1`. The implementation has
frozen scope names, strict/redacting DTOs, and durable
identity-bound tables for one-time grants and revocable device verifiers. The
owner-only `verde-daemon pair ...` and `verde-daemon device ...` administrator
commands create/list/revoke those records through the private daemon endpoint;
their one-time secret output is explicit and cleared from staging buffers.
The loopback gateway implements rate-limited HTTP exchange, 15-minute scoped
access tokens, 30-second one-use WebSocket tickets, current device-revocation
checks, and one fail-closed scope policy shared by HTTP and WebSocket RPCs.
Each device has at most one live access token and one unconsumed WebSocket
ticket: issuing a replacement atomically invalidates the prior credential
without consuming another device's bounded slot. A durable authorization
rejection also clears that device's in-memory tokens and tickets.
Direct non-loopback HTTPS remains a later slice. The native desktop pairs
through the SSH-forwarded loopback transport today: Settings › Runtimes &
connections › Add connection › **Pair this device** collects the grant id,
masked one-time code, and device label, exchanges them over the forward, shows
the returned runtime/instance identity for explicit confirmation, and then
keeps only a credential reference in the profile (device credential in the OS
Secret Service when available, otherwise process memory with a visible
"pair again after relaunch" warning).

## Three separate concerns

Remote access is easier to reason about when launch, authorization, and access
are not treated as one transport:

- **Serve** starts and supervises one Verde runtime. The runtime owns the
  daemon, network gateway, repositories, providers, chat turns, attachments,
  and PTYs.
- **Pair** authorizes a device to use a directly reachable runtime and requires
  no Verde account. The implemented path is an SSH-forwarded loopback endpoint;
  approved administrator-provided or private-network HTTPS endpoints are the
  next transport adapters.
- **Connect** optionally links a runtime to a compatible control plane, either
  self-hosted or operated by Verde Cloud. It gives a runtime behind NAT a
  discoverable HTTPS/WSS endpoint through an outbound connector. It does not
  create a second execution protocol.

The desktop connection manager normalizes every access method into one
authenticated runtime endpoint:

```text
saved runtime
    -> connection resolver (Local | SSH | direct HTTPS | Connect endpoint)
    -> authenticated HTTP/WSS endpoint
    -> Verde daemon protocol
```

SSH remains a launch/access helper and a recovery path. It is not a separate
kind of workspace, thread, provider, or daemon.

## User-facing server CLI

The dependency-light `verde-server` command is implemented as a thin
administrator and supervisor over the existing `verde-daemon` and `verde-web`
artifacts. It preserves their trust boundaries rather than introducing another
server implementation.

Implemented account-free commands:

```text
verde-server init
verde-server serve
verde-server status [--json]
verde-server pair create [--expires 10m] [--label TEXT] [--json]
verde-server pair list [--json]
verde-server pair revoke --id ID
verde-server device list [--json]
verde-server device revoke --id ID
verde-server service install|status|update|uninstall
```

`verde-server serve` foreground-supervises `verde-daemon` and `verde-web` for
interactive use and containers. Installed system services may continue to run
the two processes as separate units. The command reports their exact data,
log, and endpoint locations and never daemonizes an untracked child.

The existing lower-level commands remain supported for administrators and
debugging. `verde-daemon serve` continues to mean only the private session
daemon; changing it to expose a network listener would break the existing
security boundary.

The current owner-only lower-level Pair administration surface is:

```text
verde-daemon pair create [--expires 10m] [--label TEXT] [--scope SCOPE]... [--json]
verde-daemon pair list [--json]
verde-daemon pair revoke --id ID [--json]
verde-daemon device list [--json]
verde-daemon device revoke --id ID [--json]
```

These commands require a running daemon and accept `--data-dir PATH`. They
operate only through its private local transport and are blocked by
`verde-web`'s generic forwarding surfaces. Omitting `--scope` selects the
documented single-user default scope set. `pair create` prints the grant secret
exactly once; `--json` is also an explicit secret-bearing output mode.

The owner-only daemon Connect lifecycle is implemented through:

```text
verde-daemon connect login --control-plane URL --credential-file PATH
verde-daemon connect link --descriptor-file PATH
verde-daemon connect status [--json]
verde-daemon connect unlink [--json]
verde-daemon connect logout [--json]
```

`login` stores authorization for the selected control plane without exposing
the runtime. `link` enables the desired linked state; `unlink` disables
exposure while retaining authorization; `logout` also removes that
authorization. The desktop implements control-plane discovery, OIDC PKCE
sign-in, runtime inventory, selection, and endpoint pinning UI. The open-source
reference service, v1 contract, self-host guide, runtime connector lifecycle,
and external endpoint adapter are runnable now.

The `verde-server connect ...` convenience commands and the desktop's direct
Connect HTTPS/WSS bootstrap and data-plane transport remain incomplete. No
production managed-cloud or managed-tunnel implementation is claimed or
bundled.

## Direct pairing flow

Pairing replaces repeated entry of the whole-runtime administrator token with
a narrowly scoped, revocable device relationship.

1. The operator runs `verde-daemon pair create` locally on the runtime, or
   `verde-server pair create` as a convenience wrapper over the same
   daemon-owned operation.
2. The runtime creates a cryptographically random, single-use grant with a
   short expiry and stores only its verifier.
3. The command prints the grant once. URL/QR output is opt-in because terminals,
   screenshots, shell capture, and OS URL dispatch can retain the secret.
4. A Pair client generates or selects its device identity and submits the grant
   directly to the advertised runtime endpoint. The desktop wizard's Pair step
   does this over the SSH forward; there is no import string, the three grant
   fields are typed or pasted (hex-filtered) and the code is wiped as soon as
   the exchange starts.
5. The runtime consumes the grant exactly once and creates a durable device
   record with explicit scopes.
6. The client safeguards the returned device credential. The desktop stores it
   in the OS credential store (Linux Secret Service) and keeps only a
   credential reference in the runtime profile; without a usable store it is
   memory-only and the settings row says so.
7. Later sessions use the device credential to obtain short-lived access and
   WebSocket credentials. The original pairing grant is never reused.

Grant consumption and device creation are one atomic operation. If the runtime
commits that operation but the gateway or client disconnects before the
one-time device credential is received, retrying the grant correctly fails as
a replay. The operator must revoke the orphaned device when identifiable and
create a new grant; the runtime never reissues the lost credential.

A browser-oriented pairing link may carry the one-time grant only in the URL
fragment so the page origin does not receive it in an HTTP request. That is a
narrow exception, not a claim that fragments are generally secret: browser
history, OS URL dispatch, screenshots, and extensions may still expose them.
The grant must never appear in server logs, analytics, query parameters,
process arguments, or ordinary config. The native connection string should be
imported directly without launching an external browser when possible.

The implemented direct pairing contract supports administrator-approved scopes
appropriate to a single-user runtime:

```text
runtime:read
chat:read chat:write
terminal:read terminal:write
repository:read repository:write
device:read
```

Pairing and device records are runtime-owned durable data. They are keyed to
the runtime/instance identity pair and cannot silently survive restoration
onto a mismatched runtime identity. Store only hashes/verifiers or public keys,
never returned bearer material.

## HTTP and WebSocket authentication

Long-lived credentials are sent only in authenticated HTTP headers over an
approved transport. They are never placed in a WebSocket URL or ordinary
structured request log. Secret-bearing DTO fields redact themselves during
generic JSON serialization. The HTTP adapter deliberately writes only the
exact secret-bearing response field and clears request, response, and IPC
staging buffers after use.

The implemented loopback connection bootstrap is:

```text
`Authorization: VerdeDevice <device-id>.<device-credential>`
    -> POST /auth/access-token
    -> 15-minute scoped runtime access token
    -> POST /auth/websocket-ticket
    -> single-use 30-second WebSocket ticket
    -> WS through the approved SSH loopback tunnel with
       `Sec-WebSocket-Protocol: verde.v1,
       verde.ticket.<one-time-ticket>`
```

Every daemon RPC still checks its own scope and expected runtime/instance
target. A WebSocket ticket authenticates the transport; it is not blanket
authorization for every method.

Paired WebSockets require `runtime:read`, `chat:read`, `terminal:read`, and
`repository:read` because the initial hello plus snapshot/change feed projects
all four categories. The gateway revalidates expiry and current device status
before every received RPC and before and after each bounded change poll, so an
expired token or revoked device closes an existing socket without waiting for
reconnect. Individual RPCs still require their exact read/write scope; unknown,
process-control, lease, daemon-lifecycle, and private access methods fail
closed. Specialized `/api/*` routes use the same scope checks.

Pair exchange, failed device authentication, and failed access-token/ticket
bootstrap are independently rate-limited by bounded client tables. A valid
credential clears only its own non-blocked bucket. In the current
SSH-to-loopback topology client addresses can collapse to the loopback peer, so
this is intentionally a runtime-wide abuse bound. A future approved TLS adapter
must supply a trusted, normalized client key without accepting arbitrary
forwarded headers.

Device authentication returns only the requested scope subset after proving it
is authorized. The token issuer never receives the device's broader scope mask
as its grant input, so asking for `runtime:read` cannot accidentally mint a
token containing write scopes.

The two private daemon bridge requests that carry a pairing token or device
credential use narrow explicit encoders and immediately clear their transient
wire buffers. Generic DTO serialization remains redacted and cannot reveal a
secret accidentally.

Version-1 security requests require the exact protocol version, reject unknown
JSON fields and duplicate fields, validate canonical lowercase identifiers,
and reject unknown or duplicate scopes. Compatibility defaults are not used on
authentication inputs.

For the first account-free release, a high-entropy per-device secret stored as
a verifier is acceptable over the approved encrypted SSH/TLS transport. The
desktop keeps the credential in the OS credential store by reference;
non-desktop Pair clients must protect the returned credential explicitly. The
wire contract leaves room for proof-of-possession device keys so a later
control-plane grant can be bound to the same device identity without changing
the daemon protocol.

## Direct endpoints

The current Pair network path supports one safe arrangement:

- the existing SSH-to-loopback gateway.

The handlers and transport-neutral DTOs can be reused by a future HTTPS/WSS
adapter with a certificate or SPKI identity that the desktop validates and
pins alongside the Verde runtime identity.

Plain public HTTP/WS is never a supported Internet deployment. The first HTTPS
profile may rely on an administrator-managed reverse proxy or private-network
TLS endpoint, but Verde must define and test the forwarded-origin, client-IP,
body-bound, upgrade, timeout, and certificate-diagnostic contract before
accepting a non-loopback listener.

## Open control-plane contract

Connect is an optional open interface, not shorthand for Verde Cloud. The
open-source milestone includes a self-hostable reference service whose
operator supplies an identity provider and an endpoint provider. A private
Verde Cloud deployment may compose the same service with subscriptions,
organization policy, fleet provisioning, managed infrastructure, and private
operational integrations. Those additions must not become requirements for a
compatible desktop or runtime, and Verde Cloud must use the shared grant
issuer and validation contract rather than reimplementing grant cryptography.

The repository now contains a runnable Bun/PostgreSQL reference service at
`packages/connect_control_plane/`, including migration and server entrypoints,
a Dockerfile/Compose package, operator guidance, and a provider-neutral
external endpoint adapter. Canonical language-neutral artifact locations are:

- `specs/control-plane/v1/openapi.yaml` for the public HTTP service;
- `specs/control-plane/v1/schemas/*.schema.json` for language-neutral link,
  descriptor, bootstrap, revocation, audit, discovery, and endpoint-adapter
  messages; and
- `specs/control-plane/v1/test-vectors/*.json` for signature, expiry,
  audience, scope, key-rotation, and replay conformance.

The schemas and generated JWS/JWE/JCS conformance vectors are checked by the
reference package. Breaking wire changes use a new major contract directory;
signed messages never gain compatibility defaults or ambiguous field aliases.
The bundled production adapter validates an endpoint managed by the operator;
the noop adapter is test-only, and no managed tunnel or connector binary is
bundled.

At this implementation checkpoint, `bun run check` passes formatting,
TypeScript, 26 unit/security tests, and the Bun build. Key generation and
`docker compose config --quiet` also pass. The PostgreSQL concurrency suite is
present but was skipped because no `TEST_DATABASE_URL` was available and the
Docker socket was not accessible; the container image itself was therefore not
built in this environment.

The normalized version-1 service sequence is:

1. **OIDC principal.** The deployment publishes its configured control-plane
   and OIDC issuers. OIDC discovery must match the configured issuer exactly;
   issuer aliases are rejected, and the discovered `jwks_uri` must use HTTPS.
   Principal identity is the `(issuer, subject)` pair, never an email address.
   Interactive public clients use authorization code with PKCE and a loopback
   redirect where supported. Headless authorization is advertised only when
   the upstream provider publishes an RFC 8628 device authorization endpoint;
   the reference service does not claim to be an authorization broker or
   invent a custom out-of-band code flow.
2. **Runtime link challenge and proof.** An authenticated principal requests a
   unique, short-lived challenge. The runtime signs a proof binding the exact
   control-plane audience, principal, runtime and instance identities, runtime
   Ed25519 signing key, X25519 encryption key, challenge ID, nonce, expiry, and
   both JWK thumbprints. The control plane atomically consumes the challenge
   and records the principal/runtime link.
3. **Inventory and descriptor.** The principal can list only linked runtimes
   and obtain a normalized descriptor containing runtime identity, protocol
   metadata, HTTPS/WSS endpoint, and TLS identity material. Tunnel-provider
   account IDs and provider-specific endpoint state never enter this public
   descriptor.
4. **Scoped bootstrap request and response.** An authenticated device requests
   a bootstrap for one linked runtime and an explicit scope set. The request
   binds the principal, device key, runtime and instance, audience, client
   nonce, request ID, and expiry. The response carries a short-lived signed
   grant with an immutable grant ID and the approved scope subset. The runtime
   validates the configured control-plane issuer, signature, key ID, audience,
   identities, nonce, times, and scopes, then atomically records one-time
   consumption before minting runtime-local access. A grant is not a reusable
   runtime access token.
5. **Unlink and revoke.** Unlinking is idempotent, disables new bootstrap
   issuance, and tears down endpoint publication without deleting runtime data.
   Grants, link credentials, device associations, connector enrollment, and
   signer keys have explicit immutable IDs and revocation paths. Issuance and
   exchange check current revocation state; short expiries bound an offline
   runtime's exposure.

Control-plane signer discovery is separate from upstream OIDC discovery. It
publishes the exact grant issuer, supported contract version and algorithms,
and an HTTPS JWKS location. Runtimes pin the configured issuer and fail closed
on an unknown key ID, invalid signature, issuer/audience mismatch, expired or
not-yet-valid grant, reused grant ID, or reused request nonce. Key rotation
retains verification keys only for the bounded lifetime of grants already
issued under them.

Every security transition produces a structured audit event: OIDC login,
challenge issue/consume/failure, link/unlink, endpoint provision/rotation,
bootstrap issue/consume/reject, revocation, and signer rotation. Events include
stable actor, runtime, device, link, grant, request, and correlation IDs plus
outcome and timestamp. They never include bearer values, signed grant bodies,
provider credentials, connector enrollment secrets, prompt content, terminal
bytes, or file data. The reference service must expose an operator-owned audit
sink/export path without making a Verde-operated telemetry service mandatory.

## Endpoint-provider adapter

The reference control plane owns a provider-neutral adapter for provisioning,
observing, rotating, and removing the HTTPS/WSS endpoint. The adapter returns a
normalized endpoint descriptor and connector enrollment result; only the
adapter sees provider-specific tunnel IDs and API shapes. Operators may supply
an externally managed endpoint adapter, a self-hosted tunnel adapter, or a
managed provider adapter without changing the desktop, runtime, or public
control-plane contract.

Provider API credentials remain control-plane-only secrets. A connector
enrollment secret is a separate, high-value, rotatable credential returned
only as compact `ECDH-ES` + `A256GCM` JWE encrypted to the exact runtime's
linked X25519 key. Plaintext connector material is never stored or returned to
the ordinary OIDC caller and must never appear in process arguments, logs,
descriptors, or desktop responses. A remotely managed Cloudflare tunnel token
is one example of such a secret; `cloudflared` may be supported behind an
adapter, but Cloudflare identifiers, credentials, and lifecycle semantics are
never part of the Verde contract.

## Planned Connect flow

The optional Connect path adds discovery and NAT traversal while preserving the
runtime as the execution and credential authority:

1. The desktop and runtime select a compatible control-plane URL, validate its
   discovery metadata, and authenticate through the deployment's generic OIDC
   configuration.
2. `connect link` creates durable local intent, obtains a one-time link
   challenge, and submits the runtime's signed proof.
3. The control plane records the principal/runtime link. Its endpoint adapter
   returns a stable normalized endpoint plus a short-lived connector enrollment
   result.
4. The server launches a pinned, verified outbound connector and supplies its
   enrollment secret without argv or log exposure. No inbound port or SSH
   session is required.
5. A signed-in desktop discovers its runtime inventory and selects a normalized
   descriptor without learning tunnel-provider state.
6. The desktop sends a scoped bootstrap request. The control plane authorizes
   it and returns a signed, short-lived, replay-protected grant.
7. The runtime validates and atomically consumes that grant, intersects its
   scopes with runtime-local policy, and mints one-time runtime bootstrap
   material for the requesting device.
8. The desktop exchanges that material directly with the runtime, obtains
   runtime access plus a WebSocket ticket, and opens the ordinary Verde WSS
   session.

The control-plane API brokers identity, endpoint discovery, grants, revocation,
audit, and runtime lifecycle metadata. Normal prompts, terminal bytes, files,
and repository operations travel to the runtime through the provisioned
endpoint; they are not executed or retained by the control-plane application.

## Connection supervision

There is one retry owner per runtime profile. UI components never create their
own transport or retry loops.

Each supervisor:

- resolves the saved profile into one prepared endpoint;
- obtains or refreshes the appropriate credential;
- opens one HTTP/WSS protocol session;
- synchronizes from bounded snapshot/change cursors;
- retries transient failures indefinitely with jittered exponential backoff;
- pauses without burning retries while the device is offline;
- remains blocked on authentication, identity, certificate, or configuration
  failures until the relevant input changes;
- resumes the same runtime-qualified threads and PTYs after reconnect; and
- removes cached credentials and runtime-owned client state on explicit
  removal, without deleting server data.

SSH, direct HTTPS, and Connect-resolved targets differ only in endpoint
resolution and credential acquisition. Everything after the resolver uses the
same connection driver and daemon client.

## Delivery order

1. **Foundation landed:** identity-bound grant/device tables, one-time atomic
   exchange logic, scope-subset authentication, revocation, age-or-count
   retention, secret redaction, and tests.
2. **Local administration landed:** owner-only create/list/revoke commands for
   pairing grants and list/revoke commands for devices, exact generation
   targeting, strict inputs, and explicit one-time secret output.
3. **Loopback Pair exchange landed:** strict rate-limited exchange,
   verifier-only durable storage, and explicit lost-response semantics.
4. **Network enforcement landed:** short-lived verifier-only access tokens,
   atomic one-use WebSocket tickets, prompt revocation/expiry checks, shared
   per-RPC scope enforcement, and `access.pair.v1` advertisement.
5. **Desktop pairing landed:** grant entry, identity confirmation, credential
   reference in the profile, OS credential-store persistence with an explicit
   memory-only fallback, forget/re-pair from Settings and the runtime picker.
   **Desktop Connect onboarding partially landed:** control-plane URL entry
   with discovery validation, OIDC PKCE loopback sign-in, runtime inventory
   and selection, and endpoint/SPKI pinning into the profile. Connecting is
   still blocked: the desktop has no direct HTTPS/WSS data plane with SPKI
   pinning, and the runtime exposes no HTTP surface that consumes a Connect
   bootstrap grant (it is consumed only via daemon IPC). The UI shows that
   blocker instead of a fake connected state.
6. Direct HTTPS/WSS profile support and certificate diagnostics.
7. Shared resolver/driver supervision across SSH and HTTPS.
8. Reconnectable PTYs, attachments, repositories, and provider login parity.
9. **Reference contract landed:** versioned OpenAPI/JSON Schema contract and
   generated JWS/JWE/JCS conformance vectors for Connect.
10. **Reference service landed:** self-hostable Bun/PostgreSQL control plane
    with generic OIDC, runtime linking/discovery, signed and replay-safe grant
    issuance, revocation/audit, and an operator-managed external endpoint
    adapter.
11. **Runtime Connect lifecycle landed:** owner-only daemon RPC/CLI login,
    link, status, unlink, logout, durable identity-bound state, public-v1
    proof/enrollment/JWE handling, bootstrap-grant validation, and the
    provider-neutral external/test connector seam. Desktop direct data-plane
    transport and an optional production managed-tunnel adapter remain future
    work behind the public interface.
12. Version-skew guidance and safe service installation/update lifecycle.

The account-free Serve/Pair path is complete before Connect becomes a
requirement. A manually administered VM or container never needs a control
plane. Connect users may self-host the reference service with a compatible
OIDC provider and endpoint adapter; a Verde account or Verde-operated relay is
not required. Private Verde Cloud deployment and subscription features are not
an open-source completion gate.
