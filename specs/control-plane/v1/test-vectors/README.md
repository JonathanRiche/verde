# Verde Connect v1 test vectors

These vectors use the public RFC 8032 Ed25519 and RFC 7748 X25519 test keys. Every private value here is intentionally public test material and must never be used outside interoperability tests.

`canonicalization.json` fixes the RFC 8785 + SHA-256 digest contract. The proof and grant files contain deterministic compact JWS values at `2030-01-01T00:00:00Z`. `connector-credential-jwe.json` contains a valid compact ECDH-ES/A256GCM example; its ephemeral key and ciphertext change when regenerated while the decrypted bytes/header contract remain identical. `negative-cases.json` contains concrete, signed wrong-principal/extra-claim/unknown-key proofs, an expired proof, and an exact request-digest tamper case; every case must fail closed with the listed stable error.

Regenerate from the reference implementation with:

```sh
cd packages/connect_control_plane
bun run vectors
```
