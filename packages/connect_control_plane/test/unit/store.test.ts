import { describe, expect, test } from "bun:test";

import { MemoryStore } from "../../src/memory_store.ts";
import type {
  AuditEvent,
  EndpointEnrollmentRecord,
  LinkChallengeRecord,
  PublicEncryptionJwk,
  PublicSigningJwk,
  RuntimeDescriptor,
  RuntimeLinkRecord,
} from "../../src/types.ts";

const principal = { issuer: "https://id.example.test", subject: "alice" };
const signingJwk: PublicSigningJwk = {
  kty: "OKP",
  crv: "Ed25519",
  x: "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
  kid: "test-runtime-signing-v1",
};
const encryptionJwk: PublicEncryptionJwk = {
  kty: "OKP",
  crv: "X25519",
  x: "hSDwCYkwp1R0i33ctD73Wg2_Og0mOBr066SpjqqbTmo",
  kid: "test-runtime-encryption-v1",
};

describe("memory state machines", () => {
  test("challenge consumption is one-time and idempotent with atomic audit", async () => {
    const store = new MemoryStore();
    const record = challenge();
    const first = await store.issueChallenge(record, audit("link.challenge_issued"));
    const retry = await store.issueChallenge(
      structuredClone(record),
      audit("link.challenge_issued"),
    );
    expect(first.created).toBeTrue();
    expect(retry.created).toBeFalse();
    const link = await store.consumeChallengeAndCreateLink({
      challengeId: record.challengeId,
      principal,
      proofDigest: "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
      linkId: "lnk_44444444444444444444444444444444",
      now: new Date("2030-01-01T00:00:01.000Z"),
      audit: audit("link.created"),
    });
    const linkRetry = await store.consumeChallengeAndCreateLink({
      challengeId: record.challengeId,
      principal,
      proofDigest: "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
      linkId: "lnk_99999999999999999999999999999999",
      now: new Date("2030-01-01T00:00:02.000Z"),
      audit: audit("link.created"),
    });
    expect(link.created).toBeTrue();
    expect(linkRetry).toMatchObject({ created: false, record: { linkId: link.record.linkId } });
    expect(await store.queryAudit(null, 100)).toHaveLength(2);
  });

  test("unlink clears endpoint readiness and durably queues provider cleanup", async () => {
    const store = new MemoryStore();
    const record = challenge();
    await store.issueChallenge(record, audit("link.challenge_issued"));
    const link = await store.consumeChallengeAndCreateLink({
      challengeId: record.challengeId,
      principal,
      proofDigest: "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
      linkId: "lnk_44444444444444444444444444444444",
      now: new Date("2030-01-01T00:00:01.000Z"),
      audit: audit("link.created"),
    });
    await store.unlinkLink(link.record.linkId, principal, new Date(), audit("link.unlinked"));
    expect(await store.queryInventory(principal, null)).toEqual([]);
    const firstClaimAt = new Date(Date.now() + 1_000);
    const firstClaim = await store.claimProviderCleanup(firstClaimAt, 10);
    expect(firstClaim).toMatchObject([{ action: "remove_link", targetId: link.record.linkId }]);
    const reclaimed = await store.claimProviderCleanup(
      new Date(firstClaimAt.getTime() + 30_001),
      10,
    );
    expect(reclaimed).toHaveLength(1);
    expect(reclaimed[0]!.claimToken).not.toBe(firstClaim[0]!.claimToken);
    expect(
      await store.completeProviderCleanup(firstClaim[0]!.jobId, firstClaim[0]!.claimToken),
    ).toBeFalse();
    expect(
      await store.retryProviderCleanup(
        firstClaim[0]!.jobId,
        firstClaim[0]!.claimToken,
        new Date(firstClaimAt.getTime() + 60_000),
      ),
    ).toBeFalse();
    expect(
      await store.completeProviderCleanup(reclaimed[0]!.jobId, reclaimed[0]!.claimToken),
    ).toBeTrue();
  });

  test("revoking a stale enrollment preserves its replacement while current revocation disables it", async () => {
    const store = new MemoryStore();
    const record = challenge();
    await store.issueChallenge(record, audit("link.challenge_issued"));
    const link = (
      await store.consumeChallengeAndCreateLink({
        challengeId: record.challengeId,
        principal,
        proofDigest: "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
        linkId: "lnk_44444444444444444444444444444444",
        now: new Date("2030-01-01T00:00:01.000Z"),
        audit: audit("link.created"),
      })
    ).record;
    const enrollmentA = endpointEnrollment(
      link,
      "enr_11111111111111111111111111111111",
      "req_33333333333333333333333333333333",
      "D".repeat(43),
    );
    const enrollmentB = endpointEnrollment(
      link,
      "enr_22222222222222222222222222222222",
      "req_44444444444444444444444444444444",
      "E".repeat(43),
    );
    await store.reserveEndpointEnrollment(enrollmentA, audit("endpoint.enrollment_reserved"));
    await store.activateEndpointEnrollment({
      enrollmentId: enrollmentA.enrollmentId,
      principal,
      descriptor: endpointDescriptor(link, "a"),
      secretVerifier: null,
      secretExpiresAt: null,
      now: new Date("2030-01-01T00:00:02.000Z"),
      audit: audit("endpoint.enrolled"),
    });
    await store.reserveEndpointEnrollment(enrollmentB, audit("endpoint.enrollment_reserved"));
    await store.activateEndpointEnrollment({
      enrollmentId: enrollmentB.enrollmentId,
      principal,
      descriptor: endpointDescriptor(link, "b"),
      secretVerifier: null,
      secretExpiresAt: null,
      now: new Date("2030-01-01T00:00:03.000Z"),
      audit: audit("endpoint.enrolled"),
    });

    const staleRevocation = {
      revocationId: "rev_11111111111111111111111111111111",
      requestId: "req_55555555555555555555555555555555",
      requestDigest: "F".repeat(43),
      principal,
      entityType: "endpoint_enrollment" as const,
      entityId: enrollmentA.enrollmentId,
      reason: "stale rotation",
      now: new Date("2030-01-01T00:00:04.000Z"),
      audit: audit("entity.revoked"),
    };
    expect((await store.revoke(staleRevocation))?.created).toBeTrue();
    expect(
      (await store.revoke({ ...staleRevocation, audit: audit("entity.revoked") }))?.created,
    ).toBeFalse();
    expect((await store.queryInventory(principal, null))[0]?.descriptor?.capabilities).toEqual([
      "endpoint-b",
    ]);
    const firstReconcile = await store.claimProviderCleanup(
      new Date("2030-01-01T00:01:00.000Z"),
      10,
    );
    expect(firstReconcile).toMatchObject([
      {
        linkId: link.linkId,
        action: "reconcile_link",
        targetId: link.linkId,
        activeEnrollmentId: enrollmentA.enrollmentId,
      },
    ]);
    const reconcileRetryAt = new Date("2030-01-01T00:02:00.000Z");
    expect(
      await store.retryProviderCleanup(
        firstReconcile[0]!.jobId,
        firstReconcile[0]!.claimToken,
        reconcileRetryAt,
      ),
    ).toBeTrue();

    // The newer rotation and removal must not bypass an older delayed operation for this link.
    expect(await store.claimProviderCleanup(new Date("2030-01-01T00:01:59.999Z"), 10)).toEqual([]);
    const providerCalls: string[] = [];
    for (const expected of [
      { action: "reconcile_link", targetId: link.linkId, enrollmentId: enrollmentA.enrollmentId },
      { action: "reconcile_link", targetId: link.linkId, enrollmentId: enrollmentB.enrollmentId },
      { action: "remove_enrollment", targetId: enrollmentA.enrollmentId, enrollmentId: null },
    ] as const) {
      const claimed = await store.claimProviderCleanup(reconcileRetryAt, 10);
      expect(claimed).toHaveLength(1);
      const job = claimed[0]!;
      expect(job).toMatchObject({
        linkId: link.linkId,
        action: expected.action,
        targetId: expected.targetId,
        activeEnrollmentId: expected.enrollmentId,
      });
      providerCalls.push(`${job.action}:${job.targetId}:${job.activeEnrollmentId ?? ""}`);
      expect(await store.completeProviderCleanup(job.jobId, job.claimToken)).toBeTrue();
    }
    expect(providerCalls).toEqual([
      `reconcile_link:${link.linkId}:${enrollmentA.enrollmentId}`,
      `reconcile_link:${link.linkId}:${enrollmentB.enrollmentId}`,
      `remove_enrollment:${enrollmentA.enrollmentId}:`,
    ]);

    await store.revoke({
      revocationId: "rev_22222222222222222222222222222222",
      requestId: "req_66666666666666666666666666666666",
      requestDigest: "G".repeat(43),
      principal,
      entityType: "endpoint_enrollment",
      entityId: enrollmentB.enrollmentId,
      reason: "current endpoint",
      now: new Date("2030-01-01T00:02:01.000Z"),
      audit: audit("entity.revoked"),
    });
    expect(await store.queryInventory(principal, null)).toEqual([]);
    const currentCleanup = await store.claimProviderCleanup(
      new Date("2030-01-01T00:02:31.001Z"),
      10,
    );
    expect(
      currentCleanup.filter(
        (job) => job.action === "remove_enrollment" && job.targetId === enrollmentB.enrollmentId,
      ),
    ).toHaveLength(1);
  });
});

function endpointEnrollment(
  link: RuntimeLinkRecord,
  enrollmentId: string,
  requestId: string,
  requestDigest: string,
): EndpointEnrollmentRecord {
  return {
    enrollmentId,
    requestId,
    requestDigest,
    linkId: link.linkId,
    principal,
    provider: "external",
    descriptor: null,
    status: "pending",
    secretVerifier: null,
    secretExpiresAt: null,
    createdAt: new Date("2030-01-01T00:00:01.500Z"),
    activatedAt: null,
    revokedAt: null,
  };
}

function endpointDescriptor(link: RuntimeLinkRecord, label: string): RuntimeDescriptor {
  return {
    contract_version: "1",
    runtime_id: link.runtimeId,
    instance_id: link.instanceId,
    https_url: "https://runtime.example.test",
    wss_url: "wss://runtime.example.test/v1/ws",
    tls_identity: {
      kind: "spki_sha256",
      sha256: "H".repeat(43),
    },
    protocol: { major: 1, minor: 0 },
    capabilities: [`endpoint-${label}`],
  };
}

function challenge(): LinkChallengeRecord {
  return {
    challengeId: "chl_11111111111111111111111111111111",
    requestId: "req_22222222222222222222222222222222",
    requestDigest: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    principal,
    runtimeId: "0123456789abcdef0123456789abcdef",
    instanceId: "abcdef0123456789abcdef0123456789",
    runtimeSigningJwk: signingJwk,
    runtimeKeyThumbprint: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    runtimeEncryptionJwk: encryptionJwk,
    runtimeEncryptionKeyThumbprint: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
    nonce: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    nonceHash: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
    audience: "https://connect.example.test",
    expiresAt: new Date("2030-01-01T00:02:00.000Z"),
    createdAt: new Date("2030-01-01T00:00:00.000Z"),
    consumedAt: null,
    proofDigest: null,
    linkId: null,
  };
}

function audit(eventType: AuditEvent["eventType"]): AuditEvent {
  return {
    eventId: `evt_${crypto.randomUUID().replaceAll("-", "")}`,
    eventType,
    outcome: "success",
    actor: principal,
    correlationId: `cor_${crypto.randomUUID().replaceAll("-", "")}`,
    occurredAt: new Date(),
  };
}
