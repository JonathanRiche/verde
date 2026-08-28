# Security deployment notes

## Network topology

Run the service directly or behind one explicitly configured reverse proxy. By default, rate limiting uses the socket peer address and ignores forwarded headers. If `VERDE_TRUSTED_PROXY_IPS` lists that exact socket IP, every request from it must carry one syntactically valid IP in `X-Forwarded-For`; comma-separated chains are rejected. Never place an unlisted hop between the configured proxy and the service.

TLS termination must preserve the configured public URL and issuer exactly. OIDC issuer equality deliberately does not normalize trailing slashes or default ports. All configured security URLs reject surrounding whitespace, non-ASCII bytes, userinfo, queries, and fragments.

## Secret handling

- Keep the active private signing JWK in a no-follow regular file. On POSIX it must not be group/other readable or writable; use mode `0600` (or stricter) and mount it read-only in a container.
- Connector credentials exist only as mutable memory in an adapter result. The service hashes a verifier for idempotency, seals the bytes as runtime-recipient JWE, zeroes temporary buffers, and destroys the source. Raw credential bytes are never database fields, logs, command arguments, or ordinary JSON responses.
- The operator audit token and test token must contain at least 32 UTF-8 bytes. Test authentication is never a production option.
- Production OIDC clients should use short-lived, audience-bound access tokens. Static bearer tokens are supported only by the local test authenticator.

## Resource bounds and retention

Incoming JSON bodies are limited to 64 KiB, headers to 16 KiB, and outbound metadata/JWKS JSON to 512 KiB. OIDC/provider calls and database statements have finite deadlines; PostgreSQL `statement_timeout` and `lock_timeout` are below the request deadline. Per-client and per-principal rate limits protect pre-authentication and mutation surfaces.

The reference caps principal-owned rows and prunes expired challenges/grants, old revoked enrollments, unlinked runtimes after 30 days once dependents have expired, and audit history. Audit history is retained for 30 days and at most 100,000 rows by default. Operators needing different compliance retention should change these explicit policies with matching capacity controls.

## Endpoint adapters

The bundled `external` adapter validates an endpoint descriptor managed entirely by the operator and returns no connector secret. `noop` is deterministic, network-free, and rejected outside test mode. A production managed adapter must make `enroll(enrollment_id, ...)` idempotent, honor abort/deadline signals, reproduce the same credential on exact retry, and implement idempotent cleanup/reconciliation. `removeEnrollment` must durably dominate an in-flight `enroll` for the same ID so revocation cannot recreate a removed provider resource. The durable cleanup outbox retries failures and executes every operation for one runtime link in insertion order, including delayed retries; different links remain independent. Adapter logs must never contain credentials.

## Incident semantics

Unlink and revocation atomically hide inventory, disable new bootstrap issuance, revoke endpoint enrollment state, append audit, and enqueue provider cleanup. Runtime-side offline grants cannot consume a central revocation feed in v1, so already-issued one-use grants remain valid only to their configured `exp` (maximum 300 seconds). Rotate a compromised grant signing key while retaining its public verifier through that same bounded window.
