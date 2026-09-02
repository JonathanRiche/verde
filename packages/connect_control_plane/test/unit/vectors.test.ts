import { describe, expect, test } from "bun:test";
import { compactDecrypt, decodeJwt, importJWK } from "jose";

import { stableDigest } from "../../src/ids.ts";
import {
  encryptionKeyThumbprint,
  runtimeKeyThumbprint,
  verifyEndpointEnrollmentProof,
  verifyRuntimeLinkProof,
} from "../../src/signer.ts";
import type {
  LinkChallengeRecord,
  PublicEncryptionJwk,
  PublicSigningJwk,
} from "../../src/types.ts";

const vectorRoot = new URL("../../../../specs/control-plane/v1/test-vectors/", import.meta.url);

describe("published interoperability vectors", () => {
  test("canonical digest and runtime link proof remain stable", async () => {
    const canonical = await json("canonicalization.json");
    expect(await stableDigest(canonical.input)).toBe(canonical.digest as string);
    const vector = await json("runtime-link-proof.json");
    await expect(
      verifyRuntimeLinkProof(
        vector.jwt as string,
        await challengeFromVector(vector),
        new Date(vector.now as string),
      ),
    ).resolves.toBeUndefined();
  });

  test("connector JWE decrypts to the fixed raw bytes", async () => {
    const vector = await json("connector-credential-jwe.json");
    const key = await importJWK(vector.recipient_private_jwk as never, "ECDH-ES");
    const result = await compactDecrypt(vector.compact_jwe as string, key);
    expect(Buffer.from(result.plaintext).toString("hex")).toBe(vector.plaintext_hex as string);
    result.plaintext.fill(0);
  });

  test("published tamper vectors all fail closed with the stable error", async () => {
    const runtimeVector = await json("runtime-link-proof.json");
    const challenge = await challengeFromVector(runtimeVector);
    const negatives = await json("negative-cases.json");
    const cases = negatives.cases as Record<string, unknown>[];

    for (const testCase of cases.filter((value) => value.kind === "runtime_link_proof")) {
      await expect(
        verifyRuntimeLinkProof(
          testCase.jwt as string,
          challenge,
          new Date(testCase.verify_at as string),
        ),
      ).rejects.toMatchObject({ code: testCase.expected_error });
    }

    const tampered = cases.find((value) => value.kind === "endpoint_enrollment_request")!;
    const endpointVector = await json(tampered.source_vector as string);
    const endpointPayload = decodeJwt(endpointVector.jwt as string);
    const signing = endpointVector.public_jwk as PublicSigningJwk;
    const request = tampered.mutated_unsigned_request as Record<string, unknown>;
    await expect(
      verifyEndpointEnrollmentProof({
        compactJwt: endpointVector.jwt as string,
        linkId: endpointPayload.link_id as string,
        runtimeId: endpointPayload.runtime_id as string,
        instanceId: endpointPayload.instance_id as string,
        runtimeSigningJwk: signing,
        runtimeKeyThumbprint: await runtimeKeyThumbprint(signing),
        requestId: request.request_id as string,
        requestDigest: tampered.mutated_request_digest as string,
        controlPlaneAudience: endpointPayload.aud as string,
        requestExpiresAt: new Date((endpointPayload.exp as number) * 1_000),
        now: new Date(tampered.verify_at as string),
      }),
    ).rejects.toMatchObject({ code: tampered.expected_error });
  });
});

async function challengeFromVector(vector: Record<string, unknown>): Promise<LinkChallengeRecord> {
  const payload = decodeJwt(vector.jwt as string);
  const signing = vector.public_jwk as PublicSigningJwk;
  const encryption = vector.encryption_public_jwk as PublicEncryptionJwk;
  return {
    challengeId: payload.challenge_id as string,
    requestId: "req_22222222222222222222222222222222",
    requestDigest: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    principal: payload.principal as { issuer: string; subject: string },
    runtimeId: payload.runtime_id as string,
    instanceId: payload.instance_id as string,
    runtimeSigningJwk: signing,
    runtimeKeyThumbprint: await runtimeKeyThumbprint(signing),
    runtimeEncryptionJwk: encryption,
    runtimeEncryptionKeyThumbprint: await encryptionKeyThumbprint(encryption),
    nonce: payload.nonce as string,
    nonceHash: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
    audience: payload.aud as string,
    expiresAt: new Date((payload.exp as number) * 1_000),
    createdAt: new Date((payload.iat as number) * 1_000),
    consumedAt: null,
    proofDigest: null,
    linkId: null,
  };
}

async function json(name: string): Promise<Record<string, unknown>> {
  return (await Bun.file(new URL(name, vectorRoot)).json()) as Record<string, unknown>;
}
