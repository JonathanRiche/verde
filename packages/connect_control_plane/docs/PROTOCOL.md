# Verde Connect v1 wire profile

The OpenAPI and JSON Schemas in `specs/control-plane/v1` are normative. Unknown object properties, duplicate JSON keys (including identical duplicates), prototype-polluting keys, non-finite numbers, and non-UTF-8 request bodies are rejected.

## Canonical request digests

`request_digest` is `base64url(SHA-256(UTF8(RFC8785-JCS(request))))`, without padding. For a proof-bearing request, remove only the proof field (`runtime_proof_jwt` or `device_proof_jwt`) before canonicalization. Arrays retain order. No Unicode normalization is performed beyond RFC 8785 serialization.

## Proof JWTs

All proof JWTs use compact JWS, `alg=EdDSA`, an exact bounded `kid`, and one exact `typ`. Protected headers contain only `alg`, `kid`, and `typ`. Payloads contain only the registered and custom claims listed by `proof-claims.schema.json`; unexpected claims fail closed. `iat` and `nbf` are equal integers, proof lifetime is at most 300 seconds, `exp` is bounded by the corresponding request/challenge expiry, and issuer/subject/audience/JTI are checked exactly.

- Runtime link: `typ=verde-runtime-link+jwt`. It binds challenge, authenticated principal, runtime/instance, nonce, Ed25519 signing thumbprint, and X25519 encryption thumbprint.
- Endpoint enrollment: `typ=verde-endpoint-enrollment+jwt`. It binds the link and exact RFC 8785 request digest.
- Device bootstrap: `typ=verde-connect-device-proof+jwt`. It binds device ID/key, exact authenticated principal, and exact bootstrap request digest.

JWK thumbprints use RFC 7638 SHA-256. The bootstrap exchange supplies the complete device public JWK; receivers compute the thumbprint themselves and never trust an unverified thumbprint string.

## Bootstrap grant

The compact JWS protected header is exactly `{"alg":"EdDSA","kid":"...","typ":"verde-connect-bootstrap+jwt"}`. Claims are exactly those in `bootstrap-grant-claims.schema.json`. The subject is the byte concatenation `<principal issuer> + U+0000 + <principal subject>`. Runtime implementations must require the advertised Connect issuer, their exact HTTPS audience, a known retained `kid`, the complete claim set, an allowlisted scope set, and lifetime at most 300 seconds. A grant is distinct from a provider credential and from the runtime's eventual session/access token.

## Connector credential JWE

The plaintext is the raw adapter credential bytes—not JSON or a bearer response field. It is compact JWE using `alg=ECDH-ES` and `enc=A256GCM` to the X25519 key bound during runtime linking. Protected fields include `typ=verde-connect-credential+jwe`, recipient `kid`, enrollment ID, expiry, and the JOSE-generated ephemeral public key. The response also carries the recipient key thumbprint and expiry so the runtime can select its private key before decryption; all security-relevant values are integrity-protected in the JWE header.

## Device identity boundary

Connect's `dev_<32 hex>` identifier is scoped to an OIDC principal and permanently bound to one Ed25519 public key until revoked. Pair's daemon-local device identifier and local mapping are separate runtime concepts. Implementations must explicitly map them after verifying the signed Connect bootstrap rather than assuming the strings are interchangeable.
