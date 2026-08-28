import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import postgres from "postgres";

import { runMigrations } from "../../src/migrations.ts";
import { PostgresStore } from "../../src/postgres_store.ts";
import type {
  AuditEvent,
  EndpointEnrollmentRecord,
  LinkChallengeRecord,
  PublicEncryptionJwk,
  PublicSigningJwk,
  RuntimeDescriptor,
  RuntimeLinkRecord,
} from "../../src/types.ts";

const databaseUrl = process.env.TEST_DATABASE_URL;
const describeDatabase = databaseUrl === undefined ? describe.skip : describe;
const principal = { issuer: "https://id.example.test", subject: "postgres-alice" };
let store: PostgresStore;

describeDatabase("PostgreSQL concurrency and durability", () => {
  beforeAll(async () => {
    await runMigrations(databaseUrl!);
    const sql = postgres(databaseUrl!, { max: 1 });
    try {
      await sql.unsafe(`
        TRUNCATE provider_cleanup_jobs, audit_events, revocations, bootstrap_grants,
          connect_devices, endpoint_enrollments, runtime_links, runtime_link_challenges
        RESTART IDENTITY CASCADE
      `);
    } finally {
      await sql.end();
    }
    store = new PostgresStore(databaseUrl!, 5_000);
  });

  afterAll(async () => store?.close());

  test("concurrent idempotent challenge and link operations return one durable record", async () => {
    const first = challenge("chl_11111111111111111111111111111111");
    const second = challenge("chl_22222222222222222222222222222222");
    const issued = await Promise.all([
      store.issueChallenge(first, audit("link.challenge_issued")),
      store.issueChallenge(second, audit("link.challenge_issued")),
    ]);
    expect(issued.filter((result) => result.created)).toHaveLength(1);
    expect(new Set(issued.map((result) => result.record.challengeId)).size).toBe(1);
    const persisted = issued[0]!.record;
    const linked = await Promise.all([
      store.consumeChallengeAndCreateLink({
        challengeId: persisted.challengeId,
        principal,
        proofDigest: "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
        linkId: "lnk_11111111111111111111111111111111",
        now: new Date(),
        audit: audit("link.created"),
      }),
      store.consumeChallengeAndCreateLink({
        challengeId: persisted.challengeId,
        principal,
        proofDigest: "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
        linkId: "lnk_22222222222222222222222222222222",
        now: new Date(),
        audit: audit("link.created"),
      }),
    ]);
    expect(linked.filter((result) => result.created)).toHaveLength(1);
    expect(new Set(linked.map((result) => result.record.linkId)).size).toBe(1);
    expect(await store.queryAudit(null, 100)).toHaveLength(2);
  });

  test("endpoint reservation/rotation is race-safe and cleanup is durable", async () => {
    const link = (await store.queryInventory(principal, null))[0] ?? (await linkedRecord());
    const base = {
      requestId: "req_33333333333333333333333333333333",
      requestDigest: "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
      linkId: link.linkId,
      principal,
      provider: "external" as const,
      descriptor: null,
      status: "pending" as const,
      secretVerifier: null,
      secretExpiresAt: null,
      createdAt: new Date(),
      activatedAt: null,
      revokedAt: null,
    };
    const reservations = await Promise.all([
      store.reserveEndpointEnrollment(
        { ...base, enrollmentId: "enr_11111111111111111111111111111111" },
        audit("endpoint.enrollment_reserved"),
      ),
      store.reserveEndpointEnrollment(
        { ...base, enrollmentId: "enr_22222222222222222222222222222222" },
        audit("endpoint.enrollment_reserved"),
      ),
    ]);
    expect(reservations.filter((result) => result.created)).toHaveLength(1);
    const enrollment = reservations[0]!.record;
    const descriptor = {
      contract_version: "1" as const,
      runtime_id: link.runtimeId,
      instance_id: link.instanceId,
      https_url: "https://runtime.example.test",
      wss_url: "wss://runtime.example.test/v1/ws",
      tls_identity: {
        kind: "spki_sha256" as const,
        sha256: "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE",
      },
      protocol: { major: 1 as const, minor: 0 },
      capabilities: ["test"],
    };
    await store.activateEndpointEnrollment({
      enrollmentId: enrollment.enrollmentId,
      principal,
      descriptor,
      secretVerifier: null,
      secretExpiresAt: null,
      now: new Date(),
      audit: audit("endpoint.enrolled"),
    });
    expect(await store.queryInventory(principal, [link.runtimeId])).toHaveLength(1);
    const firstClaimAt = new Date(Date.now() + 1_000);
    const firstClaim = await store.claimProviderCleanup(firstClaimAt, 10);
    const staleJob = firstClaim.find(
      (job) => job.action === "reconcile_link" && job.targetId === link.linkId,
    );
    expect(staleJob).toBeDefined();
    const reclaimed = await store.claimProviderCleanup(
      new Date(firstClaimAt.getTime() + 30_001),
      10,
    );
    const currentJob = reclaimed.find((job) => job.jobId === staleJob!.jobId);
    expect(currentJob).toBeDefined();
    expect(currentJob!.claimToken).not.toBe(staleJob!.claimToken);
    expect(await store.completeProviderCleanup(staleJob!.jobId, staleJob!.claimToken)).toBeFalse();
    expect(
      await store.retryProviderCleanup(
        staleJob!.jobId,
        staleJob!.claimToken,
        new Date(firstClaimAt.getTime() + 60_000),
      ),
    ).toBeFalse();
    expect(
      await store.completeProviderCleanup(currentJob!.jobId, currentJob!.claimToken),
    ).toBeTrue();

    const enrollmentB = endpointEnrollment(
      link,
      "enr_33333333333333333333333333333333",
      "req_77777777777777777777777777777777",
      "I".repeat(43),
    );
    await store.reserveEndpointEnrollment(enrollmentB, audit("endpoint.enrollment_reserved"));
    await store.activateEndpointEnrollment({
      enrollmentId: enrollmentB.enrollmentId,
      principal,
      descriptor: endpointDescriptor(link, "b"),
      secretVerifier: null,
      secretExpiresAt: null,
      now: new Date(),
      audit: audit("endpoint.enrolled"),
    });
    const staleRevocation = {
      revocationId: "rev_33333333333333333333333333333333",
      requestId: "req_88888888888888888888888888888888",
      requestDigest: "J".repeat(43),
      principal,
      entityType: "endpoint_enrollment" as const,
      entityId: enrollment.enrollmentId,
      reason: "stale rotation",
      now: new Date(),
      audit: audit("entity.revoked"),
    };
    expect((await store.revoke(staleRevocation))?.created).toBeTrue();
    expect(
      (await store.revoke({ ...staleRevocation, audit: audit("entity.revoked") }))?.created,
    ).toBeFalse();
    expect(
      (await store.queryInventory(principal, [link.runtimeId]))[0]?.descriptor?.capabilities,
    ).toEqual(["endpoint-b"]);
    const delayedClaimAt = new Date(Date.now() + 1_000);
    const delayedReconcile = await store.claimProviderCleanup(delayedClaimAt, 10);
    expect(delayedReconcile).toMatchObject([
      {
        linkId: link.linkId,
        action: "reconcile_link",
        targetId: link.linkId,
        activeEnrollmentId: enrollmentB.enrollmentId,
      },
    ]);
    const reconcileRetryAt = new Date(delayedClaimAt.getTime() + 60_000);
    expect(
      await store.retryProviderCleanup(
        delayedReconcile[0]!.jobId,
        delayedReconcile[0]!.claimToken,
        reconcileRetryAt,
      ),
    ).toBeTrue();
    expect(await store.claimProviderCleanup(new Date(reconcileRetryAt.getTime() - 1), 10)).toEqual(
      [],
    );

    const providerCalls: string[] = [];
    for (const expected of [
      { action: "reconcile_link", targetId: link.linkId, enrollmentId: enrollmentB.enrollmentId },
      { action: "remove_enrollment", targetId: enrollment.enrollmentId, enrollmentId: null },
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
      `reconcile_link:${link.linkId}:${enrollmentB.enrollmentId}`,
      `remove_enrollment:${enrollment.enrollmentId}:`,
    ]);

    await store.revoke({
      revocationId: "rev_44444444444444444444444444444444",
      requestId: "req_99999999999999999999999999999999",
      requestDigest: "K".repeat(43),
      principal,
      entityType: "endpoint_enrollment",
      entityId: enrollmentB.enrollmentId,
      reason: "current endpoint",
      now: new Date(),
      audit: audit("entity.revoked"),
    });
    expect(await store.queryInventory(principal, [link.runtimeId])).toEqual([]);
    const currentCleanup = await store.claimProviderCleanup(reconcileRetryAt, 10);
    expect(
      currentCleanup.filter(
        (job) => job.action === "remove_enrollment" && job.targetId === enrollmentB.enrollmentId,
      ),
    ).toHaveLength(1);
    for (const job of currentCleanup) {
      expect(await store.completeProviderCleanup(job.jobId, job.claimToken)).toBeTrue();
    }

    const enrollmentC = endpointEnrollment(
      link,
      "enr_44444444444444444444444444444444",
      "req_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "L".repeat(43),
    );
    await store.reserveEndpointEnrollment(enrollmentC, audit("endpoint.enrollment_reserved"));
    await store.activateEndpointEnrollment({
      enrollmentId: enrollmentC.enrollmentId,
      principal,
      descriptor: endpointDescriptor(link, "c"),
      secretVerifier: null,
      secretExpiresAt: null,
      now: new Date(),
      audit: audit("endpoint.enrolled"),
    });
    expect(await store.queryInventory(principal, [link.runtimeId])).toHaveLength(1);
  });

  test("revocation checks request id before entity id and disables inventory", async () => {
    const link = (await store.queryInventory(principal, null))[0]!;
    const first = await store.revoke({
      revocationId: "rev_11111111111111111111111111111111",
      requestId: "req_44444444444444444444444444444444",
      requestDigest: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
      principal,
      entityType: "runtime_link",
      entityId: link.linkId,
      reason: "test",
      now: new Date(),
      audit: audit("entity.revoked"),
    });
    expect(first?.created).toBeTrue();
    await expect(
      store.revoke({
        revocationId: "rev_22222222222222222222222222222222",
        requestId: "req_44444444444444444444444444444444",
        requestDigest: "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",
        principal,
        entityType: "runtime_link",
        entityId: link.linkId,
        reason: "changed",
        now: new Date(),
        audit: audit("entity.revoked"),
      }),
    ).rejects.toMatchObject({ status: 409, code: "idempotency_conflict" });
    expect(await store.queryInventory(principal, null)).toEqual([]);
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
    createdAt: new Date(),
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
      sha256: "M".repeat(43),
    },
    protocol: { major: 1, minor: 0 },
    capabilities: [`endpoint-${label}`],
  };
}

async function linkedRecord() {
  const rows = await store.queryAudit(null, 100);
  expect(rows.length).toBeGreaterThanOrEqual(2);
  const challengeValue = await store.getChallenge(
    "chl_11111111111111111111111111111111",
    principal,
  );
  const fallback =
    challengeValue ?? (await store.getChallenge("chl_22222222222222222222222222222222", principal));
  if (fallback?.linkId === null || fallback === null) throw new Error("linked fixture disappeared");
  const link = await store.getLink(fallback.linkId, principal);
  if (link === null) throw new Error("linked fixture disappeared");
  return link;
}

function challenge(challengeId: string): LinkChallengeRecord {
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
  const now = new Date();
  return {
    challengeId,
    requestId: "req_11111111111111111111111111111111",
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
    expiresAt: new Date(now.getTime() + 60_000),
    createdAt: now,
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
