import { describe, expect, test } from "bun:test";
import { compactDecrypt, importJWK, SignJWT } from "jose";

import type { Config } from "../../src/config.ts";
import { NoopTestEndpointProvider } from "../../src/endpoint_provider.ts";
import { stableDigest } from "../../src/ids.ts";
import { MemoryStore } from "../../src/memory_store.ts";
import { ConnectService } from "../../src/service.ts";
import { encryptionKeyThumbprint, GrantSigner, runtimeKeyThumbprint } from "../../src/signer.ts";
import type {
  AuditEvent,
  LinkChallengeRecord,
  PublicEncryptionJwk,
  PublicSigningJwk,
} from "../../src/types.ts";

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
const principal = { issuer: "https://id.example.test", subject: "alice" };

describe("endpoint enrollment boundary", () => {
  test("returns only runtime-recipient JWE and reproduces an idempotent retry", async () => {
    const store = new MemoryStore();
    const now = new Date();
    const challenge: LinkChallengeRecord = {
      challengeId: "chl_11111111111111111111111111111111",
      requestId: "req_11111111111111111111111111111111",
      requestDigest: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      principal,
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
    await store.issueChallenge(challenge, audit("link.challenge_issued"));
    const link = await store.consumeChallengeAndCreateLink({
      challengeId: challenge.challengeId,
      principal,
      proofDigest: "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
      linkId: "lnk_44444444444444444444444444444444",
      now,
      audit: audit("link.created"),
    });
    const service = new ConnectService(
      config(),
      store,
      await GrantSigner.create(signingPrivate),
      new NoopTestEndpointProvider(),
    );
    const expiresAt = new Date(Date.now() + 60_000);
    const unsigned = {
      contract_version: "1" as const,
      request_id: "req_22222222222222222222222222222222",
      provider: "noop_test" as const,
      expires_at: expiresAt.toISOString(),
    };
    const key = await importJWK(signingPrivate, "EdDSA");
    const seconds = Math.floor(Date.now() / 1_000);
    const proof = await new SignJWT({
      contract_version: "1",
      link_id: link.record.linkId,
      request_id: unsigned.request_id,
      request_digest: await stableDigest(unsigned),
      runtime_id: link.record.runtimeId,
      instance_id: link.record.instanceId,
      runtime_key_thumbprint: link.record.runtimeKeyThumbprint,
    })
      .setProtectedHeader({
        alg: "EdDSA",
        kid: signingPublic.kid,
        typ: "verde-endpoint-enrollment+jwt",
      })
      .setIssuer(`urn:verde:runtime:${link.record.runtimeId}`)
      .setSubject(link.record.runtimeId)
      .setAudience("https://connect.example.test")
      .setJti(unsigned.request_id)
      .setIssuedAt(seconds)
      .setNotBefore(seconds)
      .setExpirationTime(Math.floor(expiresAt.getTime() / 1_000))
      .sign(key);
    const request = { ...unsigned, runtime_proof_jwt: proof };
    const first = await service.enrollEndpoint(
      principal,
      link.record.linkId,
      request,
      correlationId(),
      AbortSignal.timeout(5_000),
    );
    const retry = await service.enrollEndpoint(
      principal,
      link.record.linkId,
      request,
      correlationId(),
      AbortSignal.timeout(5_000),
    );
    expect(first.status).toBe(201);
    expect(retry.status).toBe(200);
    expect(JSON.stringify(first.body)).not.toContain("__WRITE_AT_WIRE_BOUNDARY__");
    expect(JSON.stringify(first.body)).not.toContain("secret");
    const firstPlaintext = await decryptCredential(first.body);
    const retryPlaintext = await decryptCredential(retry.body);
    expect(firstPlaintext).toEqual(retryPlaintext);
    firstPlaintext.fill(0);
    retryPlaintext.fill(0);
  });
});

async function decryptCredential(body: Record<string, unknown>): Promise<Uint8Array> {
  const connector = body.connector_enrollment as { encrypted_credential: string };
  const key = await importJWK(encryptionPrivate, "ECDH-ES");
  return (await compactDecrypt(connector.encrypted_credential, key)).plaintext;
}

function config(): Config {
  return {
    environment: "test",
    listenHost: "127.0.0.1",
    port: 8787,
    publicBaseUrl: "https://connect.example.test",
    issuer: "https://connect.example.test",
    databaseUrl: "postgres://unused:unused@127.0.0.1/unused",
    auth: {
      mode: "test",
      token: "x".repeat(32),
      principalIssuer: principal.issuer,
      principalSubject: principal.subject,
    },
    signerPrivateJwk: signingPrivate,
    signerPreviousJwks: [],
    endpointAdapter: "noop_test",
    operatorToken: null,
    challengeLifetimeSeconds: 120,
    grantLifetimeSeconds: 90,
    enrollmentLifetimeSeconds: 300,
    requestDeadlineMs: 5_000,
    oauthClient: {
      clientId: "test",
      scopes: ["openid"],
      redirectUris: ["http://127.0.0.1:48123/callback"],
    },
    trustedProxyIps: [],
  };
}

function audit(eventType: AuditEvent["eventType"]): AuditEvent {
  return {
    eventId: `evt_${crypto.randomUUID().replaceAll("-", "")}`,
    eventType,
    outcome: "success",
    actor: principal,
    correlationId: correlationId(),
    occurredAt: new Date(),
  };
}

function correlationId(): string {
  return `cor_${crypto.randomUUID().replaceAll("-", "")}`;
}
