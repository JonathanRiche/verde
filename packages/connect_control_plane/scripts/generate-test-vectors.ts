import { importJWK, SignJWT } from "jose";
import { mkdir } from "node:fs/promises";
import { resolve } from "node:path";
import { format } from "prettier";

import { stableDigest } from "../src/ids.ts";
import {
  encryptionKeyThumbprint,
  runtimeKeyThumbprint,
  sealConnectorCredential,
} from "../src/signer.ts";

const vectorDirectory = resolve(import.meta.dir, "../../../specs/control-plane/v1/test-vectors");
await mkdir(vectorDirectory, { recursive: true });

const signingPrivateJwk = {
  kty: "OKP",
  crv: "Ed25519",
  d: "nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A",
  x: "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
  kid: "test-runtime-signing-v1",
  use: "sig",
  alg: "EdDSA",
} as const;
const signingPublicJwk = { ...signingPrivateJwk } as Record<string, unknown>;
delete signingPublicJwk.d;
const encryptionPrivateJwk = {
  kty: "OKP",
  crv: "X25519",
  d: "dwdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LCo",
  x: "hSDwCYkwp1R0i33ctD73Wg2_Og0mOBr066SpjqqbTmo",
  kid: "test-runtime-encryption-v1",
  use: "enc",
  alg: "ECDH-ES",
} as const;
const encryptionPublicJwk = { ...encryptionPrivateJwk } as Record<string, unknown>;
delete encryptionPublicJwk.d;

const principal = { issuer: "https://id.example.test", subject: "test-subject" };
const runtimeId = "0123456789abcdef0123456789abcdef";
const instanceId = "abcdef0123456789abcdef0123456789";
const challengeId = "chl_11111111111111111111111111111111";
const requestId = "req_22222222222222222222222222222222";
const deviceId = "dev_33333333333333333333333333333333";
const linkId = "lnk_44444444444444444444444444444444";
const enrollmentId = "enr_55555555555555555555555555555555";
const nonce = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const issuedAt = 1_893_456_000;
const expiresAt = issuedAt + 90;
const runtimeThumbprint = await runtimeKeyThumbprint(signingPublicJwk as never);
const encryptionThumbprint = await encryptionKeyThumbprint(encryptionPublicJwk as never);
const signingKey = await importJWK(signingPrivateJwk, "EdDSA");

const canonicalInput = {
  z: [3, { b: true, a: "é" }],
  a: { negative_zero: -0, text: "line\nfeed" },
};
const canonicalDigest = await stableDigest(canonicalInput);

const runtimeLinkClaims = {
  contract_version: "1",
  challenge_id: challengeId,
  principal,
  runtime_id: runtimeId,
  instance_id: instanceId,
  runtime_key_thumbprint: runtimeThumbprint,
  runtime_encryption_key_thumbprint: encryptionThumbprint,
  nonce,
};
const runtimeLinkProof = await signRuntimeLinkProof(runtimeLinkClaims, signingPrivateJwk.kid);
const wrongPrincipalProof = await signRuntimeLinkProof(
  { ...runtimeLinkClaims, principal: { ...principal, subject: "mallory" } },
  signingPrivateJwk.kid,
);
const unknownClaimProof = await signRuntimeLinkProof(
  { ...runtimeLinkClaims, admin: true },
  signingPrivateJwk.kid,
);
const unknownKidProof = await signRuntimeLinkProof(runtimeLinkClaims, "test-unknown-signing-v1");

const endpointUnsigned = {
  contract_version: "1",
  request_id: requestId,
  provider: "noop_test",
  expires_at: new Date(expiresAt * 1_000).toISOString(),
};
const endpointDigest = await stableDigest(endpointUnsigned);
const tamperedEndpointUnsigned = {
  ...endpointUnsigned,
  request_id: "req_77777777777777777777777777777777",
};
const tamperedEndpointDigest = await stableDigest(tamperedEndpointUnsigned);
const endpointProof = await new SignJWT({
  contract_version: "1",
  link_id: linkId,
  request_id: requestId,
  request_digest: endpointDigest,
  runtime_id: runtimeId,
  instance_id: instanceId,
  runtime_key_thumbprint: runtimeThumbprint,
})
  .setProtectedHeader({
    alg: "EdDSA",
    kid: signingPrivateJwk.kid,
    typ: "verde-endpoint-enrollment+jwt",
  })
  .setIssuer(`urn:verde:runtime:${runtimeId}`)
  .setSubject(runtimeId)
  .setAudience("https://connect.example.test")
  .setJti(requestId)
  .setIssuedAt(issuedAt)
  .setNotBefore(issuedAt)
  .setExpirationTime(expiresAt)
  .sign(signingKey);

const bootstrapUnsigned = {
  contract_version: "1",
  request_id: requestId,
  runtime_id: runtimeId,
  instance_id: instanceId,
  device_id: deviceId,
  device_signing_jwk: signingPublicJwk,
  audience: "https://runtime.example.test",
  client_nonce: nonce,
  scopes: ["runtime:read", "chat:write"],
  expires_at: new Date(expiresAt * 1_000).toISOString(),
};
const bootstrapRequestDigest = await stableDigest(bootstrapUnsigned);
const deviceProof = await new SignJWT({
  contract_version: "1",
  request_id: requestId,
  request_digest: bootstrapRequestDigest,
  device_id: deviceId,
  device_key_thumbprint: runtimeThumbprint,
  principal,
})
  .setProtectedHeader({
    alg: "EdDSA",
    kid: signingPrivateJwk.kid,
    typ: "verde-connect-device-proof+jwt",
  })
  .setIssuer(`urn:verde:connect-device:${deviceId}`)
  .setSubject(deviceId)
  .setAudience("https://connect.example.test")
  .setJti(requestId)
  .setIssuedAt(issuedAt)
  .setNotBefore(issuedAt)
  .setExpirationTime(expiresAt)
  .sign(signingKey);
const bootstrapGrant = await new SignJWT({
  contract_version: "1",
  principal,
  link_id: linkId,
  runtime_id: runtimeId,
  instance_id: instanceId,
  device_id: deviceId,
  device_key_thumbprint: runtimeThumbprint,
  client_nonce: nonce,
  request_id: requestId,
  scopes: bootstrapUnsigned.scopes,
})
  .setProtectedHeader({
    alg: "EdDSA",
    kid: signingPrivateJwk.kid,
    typ: "verde-connect-bootstrap+jwt",
  })
  .setIssuer("https://connect.example.test")
  .setSubject(`${principal.issuer}\u0000${principal.subject}`)
  .setAudience(bootstrapUnsigned.audience)
  .setJti("grt_66666666666666666666666666666666")
  .setIssuedAt(issuedAt)
  .setNotBefore(issuedAt)
  .setExpirationTime(expiresAt)
  .sign(signingKey);

const secretBytes = Uint8Array.from({ length: 32 }, (_, index) => index);
const credentialJwe = await sealConnectorCredential({
  secretBytes,
  runtimeEncryptionJwk: encryptionPublicJwk as never,
  enrollmentId,
  expiresAt: new Date(expiresAt * 1_000),
});
secretBytes.fill(0);

await write("canonicalization.json", {
  contract_version: "1",
  algorithm: "RFC8785-JCS+SHA-256-base64url",
  input: canonicalInput,
  digest: canonicalDigest,
});
await write("runtime-link-proof.json", {
  contract_version: "1",
  protected_header: { alg: "EdDSA", kid: signingPrivateJwk.kid, typ: "verde-runtime-link+jwt" },
  public_jwk: signingPublicJwk,
  encryption_public_jwk: encryptionPublicJwk,
  jwt: runtimeLinkProof,
  now: new Date(issuedAt * 1_000).toISOString(),
});
await write("endpoint-enrollment-proof.json", {
  contract_version: "1",
  unsigned_request: endpointUnsigned,
  request_digest: endpointDigest,
  jwt: endpointProof,
  public_jwk: signingPublicJwk,
  now: new Date(issuedAt * 1_000).toISOString(),
});
await write("connector-credential-jwe.json", {
  contract_version: "1",
  recipient_private_jwk: encryptionPrivateJwk,
  recipient_public_jwk: encryptionPublicJwk,
  plaintext_hex: Array.from({ length: 32 }, (_, index) => index.toString(16).padStart(2, "0")).join(
    "",
  ),
  compact_jwe: credentialJwe,
  enrollment_id: enrollmentId,
  expires_at: new Date(expiresAt * 1_000).toISOString(),
});
await write("device-bootstrap-proof.json", {
  contract_version: "1",
  unsigned_request: bootstrapUnsigned,
  request_digest: bootstrapRequestDigest,
  jwt: deviceProof,
  public_jwk: signingPublicJwk,
  principal,
  now: new Date(issuedAt * 1_000).toISOString(),
});
await write("bootstrap-grant.json", {
  contract_version: "1",
  protected_header: {
    alg: "EdDSA",
    kid: signingPrivateJwk.kid,
    typ: "verde-connect-bootstrap+jwt",
  },
  public_jwk: signingPublicJwk,
  jwt: bootstrapGrant,
  maximum_lifetime_seconds: 300,
  offline_revocation_semantics:
    "future issuance stops immediately; this grant remains usable only until exp",
});
await write("negative-cases.json", {
  contract_version: "1",
  cases: [
    {
      id: "wrong-principal",
      kind: "runtime_link_proof",
      jwt: wrongPrincipalProof,
      verify_at: new Date(issuedAt * 1_000).toISOString(),
      expected_error: "runtime_proof_invalid",
    },
    {
      id: "unknown-claim",
      kind: "runtime_link_proof",
      jwt: unknownClaimProof,
      verify_at: new Date(issuedAt * 1_000).toISOString(),
      expected_error: "runtime_proof_invalid",
    },
    {
      id: "tampered-request",
      kind: "endpoint_enrollment_request",
      source_vector: "endpoint-enrollment-proof.json",
      mutated_unsigned_request: tamperedEndpointUnsigned,
      mutated_request_digest: tamperedEndpointDigest,
      verify_at: new Date(issuedAt * 1_000).toISOString(),
      expected_error: "possession_proof_invalid",
    },
    {
      id: "expired",
      kind: "runtime_link_proof",
      jwt: runtimeLinkProof,
      verify_at: new Date((expiresAt + 1) * 1_000).toISOString(),
      expected_error: "runtime_proof_invalid",
    },
    {
      id: "unknown-kid",
      kind: "runtime_link_proof",
      jwt: unknownKidProof,
      verify_at: new Date(issuedAt * 1_000).toISOString(),
      expected_error: "runtime_proof_invalid",
    },
  ],
});

async function signRuntimeLinkProof(claims: Record<string, unknown>, kid: string): Promise<string> {
  return new SignJWT(claims)
    .setProtectedHeader({ alg: "EdDSA", kid, typ: "verde-runtime-link+jwt" })
    .setIssuer(`urn:verde:runtime:${runtimeId}`)
    .setSubject(runtimeId)
    .setAudience("https://connect.example.test")
    .setJti(challengeId)
    .setIssuedAt(issuedAt)
    .setNotBefore(issuedAt)
    .setExpirationTime(expiresAt)
    .sign(signingKey);
}

async function write(name: string, value: unknown): Promise<void> {
  const source = await format(JSON.stringify(value), { parser: "json", printWidth: 80 });
  await Bun.write(resolve(vectorDirectory, name), source);
}
