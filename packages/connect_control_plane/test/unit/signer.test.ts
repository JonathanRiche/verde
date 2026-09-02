import { describe, expect, test } from "bun:test";
import { compactDecrypt, decodeJwt, decodeProtectedHeader, importJWK, SignJWT } from "jose";

import {
  encryptionKeyThumbprint,
  GrantSigner,
  runtimeKeyThumbprint,
  sealConnectorCredential,
  verifyDeviceBootstrapProof,
  verifyRuntimeLinkProof,
} from "../../src/signer.ts";
import type {
  BootstrapRecord,
  LinkChallengeRecord,
  PublicEncryptionJwk,
  PublicSigningJwk,
} from "../../src/types.ts";
import { validateSchema } from "../../src/schemas.ts";

const signingPrivate = {
  kty: "OKP",
  crv: "Ed25519",
  d: "nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A",
  x: "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
  kid: "test-runtime-signing-v1",
  use: "sig",
  alg: "EdDSA",
} as const;
const signingPublic: PublicSigningJwk = {
  kty: "OKP",
  crv: "Ed25519",
  x: signingPrivate.x,
  kid: signingPrivate.kid,
  use: "sig",
  alg: "EdDSA",
};
const encryptionPrivate = {
  kty: "OKP",
  crv: "X25519",
  d: "dwdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LCo",
  x: "hSDwCYkwp1R0i33ctD73Wg2_Og0mOBr066SpjqqbTmo",
  kid: "test-runtime-encryption-v1",
  use: "enc",
  alg: "ECDH-ES",
} as const;
const encryptionPublic: PublicEncryptionJwk = {
  kty: "OKP",
  crv: "X25519",
  x: encryptionPrivate.x,
  kid: encryptionPrivate.kid,
  use: "enc",
  alg: "ECDH-ES",
};

describe("public cryptographic contract", () => {
  test("runtime link proof binds signing and encryption keys and rejects extra claims", async () => {
    const now = new Date("2030-01-01T00:00:00.000Z");
    const challenge = await challengeRecord(now);
    const valid = await runtimeProof(challenge, now, {});
    await expect(verifyRuntimeLinkProof(valid, challenge, now)).resolves.toBeUndefined();
    expect(() => validateSchema("runtimeLinkProofClaims", decodeJwt(valid))).not.toThrow();
    const extra = await runtimeProof(challenge, now, { admin: true });
    await expect(verifyRuntimeLinkProof(extra, challenge, now)).rejects.toMatchObject({
      status: 409,
    });
  });

  test("runtime link proof rejects non-integer and pre-challenge NumericDates", async () => {
    const now = new Date("2030-01-01T00:00:00.000Z");
    const challenge = await challengeRecord(now);
    const fractional = await runtimeProof(
      challenge,
      now,
      {},
      {
        iat: now.getTime() / 1_000 + 0.5,
        nbf: now.getTime() / 1_000 + 0.5,
        exp: now.getTime() / 1_000 + 30.5,
      },
    );
    await expect(verifyRuntimeLinkProof(fractional, challenge, now)).rejects.toMatchObject({
      status: 409,
    });

    const beforeChallenge = await runtimeProof(
      challenge,
      now,
      {},
      {
        iat: now.getTime() / 1_000 - 10,
        nbf: now.getTime() / 1_000 - 10,
        exp: now.getTime() / 1_000 + 30,
      },
    );
    await expect(verifyRuntimeLinkProof(beforeChallenge, challenge, now)).rejects.toMatchObject({
      status: 409,
    });
  });

  test("device proof is bound to the exact authenticated principal", async () => {
    const now = new Date("2030-01-01T00:00:00.000Z");
    const expiresAt = new Date(now.getTime() + 60_000);
    const requestId = "req_22222222222222222222222222222222";
    const deviceId = "dev_33333333333333333333333333333333";
    const thumbprint = await runtimeKeyThumbprint(signingPublic);
    const key = await importJWK(signingPrivate, "EdDSA");
    const principal = { issuer: "https://id.example.test", subject: "alice" };
    const claims = {
      contract_version: "1",
      request_id: requestId,
      request_digest: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      device_id: deviceId,
      device_key_thumbprint: thumbprint,
      principal,
    };
    const jwt = await new SignJWT(claims)
      .setProtectedHeader({
        alg: "EdDSA",
        kid: signingPublic.kid,
        typ: "verde-connect-device-proof+jwt",
      })
      .setIssuer(`urn:verde:connect-device:${deviceId}`)
      .setSubject(deviceId)
      .setAudience("https://connect.example.test")
      .setJti(requestId)
      .setIssuedAt(Math.floor(now.getTime() / 1_000))
      .setNotBefore(Math.floor(now.getTime() / 1_000))
      .setExpirationTime(Math.floor(expiresAt.getTime() / 1_000))
      .sign(key);
    await expect(
      verifyDeviceBootstrapProof({
        compactJwt: jwt,
        deviceId,
        deviceSigningJwk: signingPublic,
        deviceKeyThumbprint: thumbprint,
        principal: { ...principal, subject: "mallory" },
        requestId,
        requestDigest: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        controlPlaneAudience: "https://connect.example.test",
        requestExpiresAt: expiresAt,
        now,
      }),
    ).rejects.toMatchObject({ status: 409 });

    const stale = await new SignJWT(claims)
      .setProtectedHeader({
        alg: "EdDSA",
        kid: signingPublic.kid,
        typ: "verde-connect-device-proof+jwt",
      })
      .setIssuer(`urn:verde:connect-device:${deviceId}`)
      .setSubject(deviceId)
      .setAudience("https://connect.example.test")
      .setJti(requestId)
      .setIssuedAt(Math.floor(now.getTime() / 1_000) - 600)
      .setNotBefore(Math.floor(now.getTime() / 1_000) - 600)
      .setExpirationTime(Math.floor(expiresAt.getTime() / 1_000))
      .sign(key);
    await expect(
      verifyDeviceBootstrapProof({
        compactJwt: stale,
        deviceId,
        deviceSigningJwk: signingPublic,
        deviceKeyThumbprint: thumbprint,
        principal,
        requestId,
        requestDigest: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        controlPlaneAudience: "https://connect.example.test",
        requestExpiresAt: expiresAt,
        now,
      }),
    ).rejects.toMatchObject({ status: 409 });
  });

  test("connector credential is JWE-only and decrypts with the bound X25519 key", async () => {
    const plaintext = Uint8Array.from({ length: 32 }, (_, index) => index);
    const compact = await sealConnectorCredential({
      secretBytes: plaintext,
      runtimeEncryptionJwk: encryptionPublic,
      enrollmentId: "enr_55555555555555555555555555555555",
      expiresAt: new Date("2030-01-01T00:01:00.000Z"),
    });
    expect(compact.split(".")).toHaveLength(5);
    expect(compact).not.toContain(Buffer.from(plaintext).toString("base64url"));
    const key = await importJWK(encryptionPrivate, "ECDH-ES");
    const decrypted = await compactDecrypt(compact, key);
    expect(decrypted.plaintext).toEqual(plaintext);
    expect(decrypted.protectedHeader).toMatchObject({
      alg: "ECDH-ES",
      enc: "A256GCM",
      typ: "verde-connect-credential+jwe",
      enrollment_id: "enr_55555555555555555555555555555555",
    });
    expect(() =>
      validateSchema("connectorCredentialJweHeader", decrypted.protectedHeader),
    ).not.toThrow();
    plaintext.fill(0);
    decrypted.plaintext.fill(0);
  });

  test("bootstrap grant has an exact short-lived profile and publishes overlap keys", async () => {
    const signer = await GrantSigner.create(signingPrivate, [
      {
        jwk: { ...signingPublic, kid: "previous-signing-key-v1" },
        retainUntil: new Date(Date.now() + 300_000),
      },
    ]);
    const record: BootstrapRecord = {
      grantId: "grt_66666666666666666666666666666666",
      requestId: "req_22222222222222222222222222222222",
      requestDigest: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      linkId: "lnk_44444444444444444444444444444444",
      principal: { issuer: "https://id.example.test", subject: "alice" },
      runtimeId: "0123456789abcdef0123456789abcdef",
      instanceId: "abcdef0123456789abcdef0123456789",
      deviceId: "dev_33333333333333333333333333333333",
      deviceSigningJwk: signingPublic,
      deviceKeyThumbprint: await runtimeKeyThumbprint(signingPublic),
      audience: "https://runtime.example.test",
      clientNonce: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      scopes: ["runtime:read"],
      issuedAtSeconds: 1_893_456_000,
      expiresAtSeconds: 1_893_456_090,
      createdAt: new Date(1_893_456_000_000),
    };
    const jwt = await signer.signBootstrap("https://connect.example.test", record);
    expect(() => validateSchema("bootstrapGrantClaims", decodeJwt(jwt))).not.toThrow();
    expect(decodeProtectedHeader(jwt)).toEqual({
      alg: "EdDSA",
      kid: signingPublic.kid,
      typ: "verde-connect-bootstrap+jwt",
    });
    expect(Object.keys(decodeJwt(jwt)).sort()).toEqual(
      [
        "aud",
        "client_nonce",
        "contract_version",
        "device_id",
        "device_key_thumbprint",
        "exp",
        "iat",
        "instance_id",
        "iss",
        "jti",
        "link_id",
        "nbf",
        "principal",
        "request_id",
        "runtime_id",
        "scopes",
        "sub",
      ].sort(),
    );
    expect(signer.publicJwks().keys.map((keyValue) => keyValue.kid)).toEqual([
      signingPublic.kid,
      "previous-signing-key-v1",
    ]);
  });
});

async function challengeRecord(now: Date): Promise<LinkChallengeRecord> {
  return {
    challengeId: "chl_11111111111111111111111111111111",
    requestId: "req_22222222222222222222222222222222",
    requestDigest: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    principal: { issuer: "https://id.example.test", subject: "alice" },
    runtimeId: "0123456789abcdef0123456789abcdef",
    instanceId: "abcdef0123456789abcdef0123456789",
    runtimeSigningJwk: signingPublic,
    runtimeKeyThumbprint: await runtimeKeyThumbprint(signingPublic),
    runtimeEncryptionJwk: encryptionPublic,
    runtimeEncryptionKeyThumbprint: await encryptionKeyThumbprint(encryptionPublic),
    nonce: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    nonceHash: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
    audience: "https://connect.example.test",
    expiresAt: new Date(now.getTime() + 60_000),
    createdAt: now,
    consumedAt: null,
    proofDigest: null,
    linkId: null,
  };
}

async function runtimeProof(
  challenge: LinkChallengeRecord,
  now: Date,
  extra: Record<string, unknown>,
  numericDates?: { iat: number; nbf: number; exp: number },
): Promise<string> {
  const key = await importJWK(signingPrivate, "EdDSA");
  const seconds = Math.floor(now.getTime() / 1_000);
  const dates = numericDates ?? { iat: seconds, nbf: seconds, exp: seconds + 60 };
  return new SignJWT({
    contract_version: "1",
    challenge_id: challenge.challengeId,
    principal: challenge.principal,
    runtime_id: challenge.runtimeId,
    instance_id: challenge.instanceId,
    runtime_key_thumbprint: challenge.runtimeKeyThumbprint,
    runtime_encryption_key_thumbprint: challenge.runtimeEncryptionKeyThumbprint,
    nonce: challenge.nonce,
    ...extra,
  })
    .setProtectedHeader({ alg: "EdDSA", kid: signingPublic.kid, typ: "verde-runtime-link+jwt" })
    .setIssuer(`urn:verde:runtime:${challenge.runtimeId}`)
    .setSubject(challenge.runtimeId)
    .setAudience(challenge.audience)
    .setJti(challenge.challengeId)
    .setIssuedAt(dates.iat)
    .setNotBefore(dates.nbf)
    .setExpirationTime(dates.exp)
    .sign(key);
}
