# Verde Connect control plane

This package is the runnable MIT-licensed reference control plane for self-hosted Verde Connect v1. It links an authenticated OIDC principal to runtime identities, publishes normalized HTTPS/WSS inventory, issues short-lived scoped bootstrap grants, and revokes links/devices/enrollments. It never stores prompts, terminal output, repository contents, or provider credentials.

The reference deliberately stops at the public boundary. It includes an operator-supplied external endpoint adapter and a test-only noop adapter. It does **not** bundle a production managed tunnel, connector binary, billing, subscriptions, hosted-runtime marketplace, private organization policy, or support/admin systems. Those are separate deployment products built against the same versioned contract.

## Run locally with Bun

Requirements: Bun 1.4+, PostgreSQL 17, and an owner-only Ed25519 signing-key file.

```sh
cd packages/connect_control_plane
bun install --frozen-lockfile
mkdir -p .local
chmod 700 .local
bun run keygen > .local/grant-signing.jwk
chmod 600 .local/grant-signing.jwk
cp config/example.env .env
```

Set `DATABASE_URL`, a random `VERDE_TEST_AUTH_TOKEN` of at least 32 bytes, and the OAuth public-client values in `.env`, then run:

```sh
set -a
. ./.env
set +a
bun run migrate
bun run start
```

`GET http://127.0.0.1:8787/healthz` is process liveness. `GET /readyz` checks PostgreSQL, authentication metadata, and the configured endpoint adapter. Run migrations before starting; the migration command intentionally needs only `DATABASE_URL`.

## Run with Compose

Docker Compose 2.17+ with BuildKit is required for the isolated spec build context. Generate the key as above, make its absolute path readable by the configured container UID, then:

```sh
export POSTGRES_PASSWORD="$(openssl rand -hex 24)"
export VERDE_TEST_AUTH_TOKEN="$(openssl rand -hex 32)"
export VERDE_GRANT_SIGNING_JWK_HOST_FILE="$PWD/.local/grant-signing.jwk"
docker compose up --build
```

Compose binds PostgreSQL and the API to loopback and runs migrations before the API. The supplied authentication mode is for local testing only; `VERDE_AUTH_MODE=test` is rejected unless `VERDE_ENV=test`. For a VM deployment, terminate TLS at a reverse proxy, configure the exact public HTTPS issuer/base URL, and follow the OIDC and proxy rules below.

## Production OIDC profile

Production accepts JWT access tokens only; opaque tokens/introspection are not implemented. A token must have:

- protected `typ` exactly `at+jwt`, an allowlisted `alg`, and a bounded `kid`;
- `iss` exactly byte-for-byte equal to `VERDE_OIDC_ISSUER`;
- the configured `VERDE_OIDC_AUDIENCE`;
- bounded `sub`, integer `iat`, and integer `exp`; and
- a lifetime and age no greater than `VERDE_OIDC_MAX_TOKEN_AGE_SECONDS`.

Discovery and JWKS fetches require HTTPS, JSON MIME types, finite time/body bounds, no redirects, and URLs without userinfo/query/fragment. `VERDE_OIDC_JWKS_URI` is mandatory in production and must exactly match discovery, preventing metadata-driven JWKS egress. Unknown-key refresh is single-flight and limited to one outbound attempt per 30-second cooldown.

Discovery publishes the exact configured public `client_id`, scopes, redirect URIs, authorization-code response type, and PKCE S256. Headless authorization is advertised only when the upstream provider publishes an RFC 8628 `device_authorization_endpoint`; this service does not claim or implement an authorization broker. If the upstream provider lacks RFC 8628, headless login is unsupported in v1.

The principal comes only from the validated bearer token. Request bodies cannot supply `principal`, organization, or `act_as` fields. A hosted Verde Cloud can compose with this service as an audience-bound, short-lived OIDC service principal and request only explicit runtime IDs; organization/user policy remains in Cloud.

## Security and protocol contracts

The normative API is [the OpenAPI document](../../specs/control-plane/v1/openapi.yaml). Exact JWT/JWE claims and canonicalization are described in [docs/PROTOCOL.md](docs/PROTOCOL.md), with machine-readable schemas and test vectors under `specs/control-plane/v1/`.

The flow is:

1. OIDC principal requests a challenge with an Ed25519 runtime signing key and X25519 runtime encryption key.
2. The runtime proves possession of the signing key over the exact challenge, principal, runtime identity, nonce, and both key thumbprints.
3. Endpoint enrollment requires a fresh runtime proof over the RFC 8785 digest of the exact request.
4. Any connector credential is returned only as compact `ECDH-ES` + `A256GCM` JWE encrypted to the linked X25519 runtime key. Plaintext connector material is never logged, stored, or returned to the ordinary OIDC caller.
5. Bootstrap requires a principal-bound device Ed25519 proof over the exact request. A principal-scoped `dev_...` Connect identity is distinct from Pair's runtime-local bare device ID; the runtime receives the actual public JWK and recomputes its thumbprint.

Bootstrap grants expire in at most 300 seconds. Revocation blocks future issuance immediately. A grant already issued for offline validation remains valid only until its `exp`; the API intentionally does not advertise instantaneous offline-grant revocation.

Mutations and security audit records commit in one PostgreSQL transaction. Endpoint side effects are reserved before adapter calls, and rotation/unlink/revoke cleanup is placed in a durable retry outbox. Request IDs are principal-scoped idempotency keys; reuse with a different canonical body fails with `idempotency_conflict`.

See [docs/SECURITY.md](docs/SECURITY.md) before exposing the service publicly.

## Key rotation

`VERDE_GRANT_SIGNING_JWK_FILE` is the active private Ed25519 key. Never pass private key material in arguments or environment variables. To rotate:

1. record the old public JWK and the exact `retired_at` timestamp in a bundle shaped as `{"keys":[{"jwk":{...},"retired_at":"..."}]}`;
2. set `VERDE_GRANT_PREVIOUS_JWKS_FILE` to that bundle;
3. atomically replace the owner-only active private JWK; and
4. keep the old key configured for at least 300 seconds after retirement.

The JWKS endpoint publishes retained verification keys until `retired_at + 300s`, covering the maximum grant lifetime. Removing a prior key earlier breaks outstanding grants and is unsupported.

## Verification

```sh
bun run vectors
bun run check
TEST_DATABASE_URL=postgres://... bun run test:integration
```

`bun run check` performs formatting verification, TypeScript checking, hermetic unit tests, and a Bun build. PostgreSQL integration tests are skipped unless `TEST_DATABASE_URL` is explicitly provided.
