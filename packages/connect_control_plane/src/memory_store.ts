import { conflict } from "./errors.ts";
import type { ControlPlaneStore, StoreResult } from "./store.ts";
import {
  samePrincipal,
  type AuditEvent,
  type BootstrapRecord,
  type EndpointEnrollmentRecord,
  type LinkChallengeRecord,
  type Principal,
  type ProviderCleanupJob,
  type RevocableEntityType,
  type RevocationRecord,
  type RuntimeLinkRecord,
} from "./types.ts";

/** Hermetic store used by unit tests. Production always uses PostgresStore. */
export class MemoryStore implements ControlPlaneStore {
  readonly #challenges = new Map<string, LinkChallengeRecord>();
  readonly #links = new Map<string, RuntimeLinkRecord>();
  readonly #enrollments = new Map<string, EndpointEnrollmentRecord>();
  readonly #bootstraps = new Map<string, BootstrapRecord>();
  readonly #devices = new Map<
    string,
    { principal: Principal; deviceId: string; thumbprint: string; status: "active" | "revoked" }
  >();
  readonly #revocations = new Map<string, RevocationRecord>();
  readonly #audits: AuditEvent[] = [];
  readonly #cleanupJobs = new Map<
    string,
    Omit<ProviderCleanupJob, "claimToken"> & { claimToken: string | null; nextAttemptAt: Date }
  >();

  async health(): Promise<void> {}
  async prune(_now: Date): Promise<void> {}
  async close(): Promise<void> {}

  async issueChallenge(
    record: LinkChallengeRecord,
    audit: AuditEvent,
  ): Promise<StoreResult<LinkChallengeRecord>> {
    const existing = [...this.#challenges.values()].find(
      (item) =>
        samePrincipal(item.principal, record.principal) && item.requestId === record.requestId,
    );
    if (existing !== undefined) {
      if (existing.requestDigest !== record.requestDigest) {
        conflict("idempotency_conflict", "request_id was already used with a different request");
      }
      return { record: cloneChallenge(existing), created: false };
    }
    this.#challenges.set(record.challengeId, cloneChallenge(record));
    this.#audits.push(structuredClone(audit));
    return { record: cloneChallenge(record), created: true };
  }

  async getChallenge(
    challengeId: string,
    principal: Principal,
  ): Promise<LinkChallengeRecord | null> {
    const record = this.#challenges.get(challengeId);
    return record !== undefined && samePrincipal(record.principal, principal)
      ? cloneChallenge(record)
      : null;
  }

  async consumeChallengeAndCreateLink(input: {
    challengeId: string;
    principal: Principal;
    proofDigest: string;
    linkId: string;
    now: Date;
    audit: AuditEvent;
  }): Promise<StoreResult<RuntimeLinkRecord>> {
    const challenge = this.#challenges.get(input.challengeId);
    if (challenge === undefined || !samePrincipal(challenge.principal, input.principal)) {
      conflict("challenge_unavailable", "Link challenge is invalid, expired, or already consumed");
    }
    if (challenge.consumedAt !== null) {
      if (challenge.proofDigest === input.proofDigest && challenge.linkId !== null) {
        const existingLink = this.#links.get(challenge.linkId);
        if (existingLink !== undefined) return { record: cloneLink(existingLink), created: false };
      }
      conflict("challenge_unavailable", "Link challenge is invalid, expired, or already consumed");
    }
    if (challenge.expiresAt.getTime() <= input.now.getTime()) {
      conflict("challenge_unavailable", "Link challenge is invalid, expired, or already consumed");
    }
    const activeLink = [...this.#links.values()].find(
      (link) =>
        samePrincipal(link.principal, input.principal) &&
        link.runtimeId === challenge.runtimeId &&
        link.status === "linked",
    );
    if (activeLink !== undefined) {
      conflict("runtime_already_linked", "Runtime is already linked to this principal");
    }
    const link: RuntimeLinkRecord = {
      linkId: input.linkId,
      challengeId: challenge.challengeId,
      principal: challenge.principal,
      runtimeId: challenge.runtimeId,
      instanceId: challenge.instanceId,
      runtimeSigningJwk: challenge.runtimeSigningJwk,
      runtimeKeyThumbprint: challenge.runtimeKeyThumbprint,
      runtimeEncryptionJwk: challenge.runtimeEncryptionJwk,
      runtimeEncryptionKeyThumbprint: challenge.runtimeEncryptionKeyThumbprint,
      descriptor: null,
      status: "linked",
      createdAt: input.now,
      unlinkedAt: null,
    };
    challenge.consumedAt = input.now;
    challenge.proofDigest = input.proofDigest;
    challenge.linkId = input.linkId;
    this.#links.set(link.linkId, cloneLink(link));
    this.#audits.push(structuredClone(input.audit));
    return { record: cloneLink(link), created: true };
  }

  async getLink(linkId: string, principal: Principal): Promise<RuntimeLinkRecord | null> {
    const record = this.#links.get(linkId);
    return record !== undefined && samePrincipal(record.principal, principal)
      ? cloneLink(record)
      : null;
  }

  async unlinkLink(
    linkId: string,
    principal: Principal,
    now: Date,
    audit: AuditEvent,
  ): Promise<RuntimeLinkRecord | null> {
    const record = this.#links.get(linkId);
    if (record === undefined || !samePrincipal(record.principal, principal)) return null;
    if (record.status === "linked") {
      record.status = "unlinked";
      record.unlinkedAt = now;
      for (const enrollment of this.#enrollments.values()) {
        if (enrollment.linkId === linkId && enrollment.status !== "revoked") {
          enrollment.status = "revoked";
          enrollment.descriptor = null;
          enrollment.revokedAt = now;
        }
      }
      record.descriptor = null;
      this.enqueueCleanup("remove_link", linkId, linkId, null, now);
      this.#audits.push(structuredClone(audit));
    }
    return cloneLink(record);
  }

  async queryInventory(
    principal: Principal,
    runtimeIds: string[] | null,
  ): Promise<RuntimeLinkRecord[]> {
    const selected = runtimeIds === null ? null : new Set(runtimeIds);
    return [...this.#links.values()]
      .filter(
        (link) =>
          samePrincipal(link.principal, principal) &&
          link.status === "linked" &&
          link.descriptor !== null &&
          (selected === null || selected.has(link.runtimeId)),
      )
      .sort((left, right) => left.runtimeId.localeCompare(right.runtimeId))
      .map(cloneLink);
  }

  async reserveEndpointEnrollment(
    record: EndpointEnrollmentRecord,
    audit: AuditEvent,
  ): Promise<StoreResult<EndpointEnrollmentRecord>> {
    const existing = [...this.#enrollments.values()].find(
      (item) =>
        samePrincipal(item.principal, record.principal) && item.requestId === record.requestId,
    );
    if (existing !== undefined) {
      if (existing.requestDigest !== record.requestDigest) {
        conflict("idempotency_conflict", "request_id was already used with a different request");
      }
      return { record: cloneEnrollment(existing), created: false };
    }
    const link = this.#links.get(record.linkId);
    if (
      link === undefined ||
      !samePrincipal(link.principal, record.principal) ||
      link.status !== "linked"
    ) {
      conflict("link_unavailable", "Runtime link is unavailable");
    }
    this.#enrollments.set(record.enrollmentId, cloneEnrollment(record));
    this.#audits.push(structuredClone(audit));
    return { record: cloneEnrollment(record), created: true };
  }

  async activateEndpointEnrollment(input: {
    enrollmentId: string;
    principal: Principal;
    descriptor: import("./types.ts").RuntimeDescriptor;
    secretVerifier: string | null;
    secretExpiresAt: Date | null;
    now: Date;
    audit: AuditEvent;
  }): Promise<EndpointEnrollmentRecord> {
    const record = this.#enrollments.get(input.enrollmentId);
    if (record === undefined || !samePrincipal(record.principal, input.principal)) {
      conflict("enrollment_unavailable", "Endpoint enrollment is unavailable");
    }
    if (record.status === "active") return cloneEnrollment(record);
    if (record.status !== "pending") {
      conflict("enrollment_unavailable", "Endpoint enrollment is unavailable");
    }
    const link = this.#links.get(record.linkId);
    if (link === undefined || link.status !== "linked") {
      conflict("link_unavailable", "Runtime link is unavailable");
    }
    for (const existing of this.#enrollments.values()) {
      if (existing.linkId === record.linkId && existing.status === "active") {
        existing.status = "revoked";
        existing.descriptor = null;
        existing.revokedAt = input.now;
      }
    }
    record.descriptor = structuredClone(input.descriptor);
    record.secretVerifier = input.secretVerifier;
    record.secretExpiresAt = input.secretExpiresAt;
    record.status = "active";
    record.activatedAt = input.now;
    link.descriptor = structuredClone(input.descriptor);
    this.enqueueCleanup(
      "reconcile_link",
      record.linkId,
      record.linkId,
      record.enrollmentId,
      input.now,
    );
    this.#audits.push(structuredClone(input.audit));
    return cloneEnrollment(record);
  }

  async reserveBootstrap(
    record: BootstrapRecord,
    audit: AuditEvent,
  ): Promise<StoreResult<BootstrapRecord>> {
    const deviceKey = `${record.principal.issuer}\u0000${record.principal.subject}\u0000${record.deviceId}`;
    const device = this.#devices.get(deviceKey);
    if (device === undefined) {
      this.#devices.set(deviceKey, {
        principal: record.principal,
        deviceId: record.deviceId,
        thumbprint: record.deviceKeyThumbprint,
        status: "active",
      });
    } else if (device.thumbprint !== record.deviceKeyThumbprint) {
      conflict("device_key_mismatch", "device_id is already bound to another signing key");
    } else if (device.status === "revoked") {
      conflict("bootstrap_revoked", "Bootstrap request targets a revoked device");
    }
    if (
      (await this.isRevoked(record.principal, "runtime_link", record.linkId)) ||
      (await this.isRevoked(record.principal, "device", record.deviceId))
    ) {
      conflict("bootstrap_revoked", "Bootstrap request targets a revoked entity");
    }
    const existing = [...this.#bootstraps.values()].find(
      (item) =>
        samePrincipal(item.principal, record.principal) && item.requestId === record.requestId,
    );
    if (existing !== undefined) {
      if (existing.requestDigest !== record.requestDigest) {
        conflict("idempotency_conflict", "request_id was already used with a different request");
      }
      return { record: cloneBootstrap(existing), created: false };
    }
    const link = this.#links.get(record.linkId);
    if (
      link === undefined ||
      !samePrincipal(link.principal, record.principal) ||
      link.status !== "linked" ||
      link.descriptor === null
    ) {
      conflict("link_unavailable", "Runtime link is unavailable");
    }
    this.#bootstraps.set(record.grantId, cloneBootstrap(record));
    this.#audits.push(structuredClone(audit));
    return { record: cloneBootstrap(record), created: true };
  }

  async revoke(input: {
    revocationId: string;
    requestId: string;
    requestDigest: string;
    principal: Principal;
    entityType: RevocableEntityType;
    entityId: string;
    reason: string | null;
    now: Date;
    audit: AuditEvent;
  }): Promise<StoreResult<RevocationRecord> | null> {
    const requestExisting = [...this.#revocations.values()].find(
      (value) =>
        samePrincipal(value.principal, input.principal) && value.requestId === input.requestId,
    );
    if (requestExisting !== undefined) {
      if (requestExisting.requestDigest !== input.requestDigest) {
        conflict("idempotency_conflict", "request_id was already used with a different request");
      }
      return { record: cloneRevocation(requestExisting), created: false };
    }
    if (!this.ownsEntity(input.principal, input.entityType, input.entityId)) return null;
    const key = revocationKey(input.principal, input.entityType, input.entityId);
    const existing = this.#revocations.get(key);
    if (existing !== undefined) return { record: cloneRevocation(existing), created: false };
    const record: RevocationRecord = {
      revocationId: input.revocationId,
      requestId: input.requestId,
      requestDigest: input.requestDigest,
      principal: input.principal,
      entityType: input.entityType,
      entityId: input.entityId,
      reason: input.reason,
      revokedAt: input.now,
    };
    this.#revocations.set(key, cloneRevocation(record));
    if (input.entityType === "runtime_link") {
      const link = this.#links.get(input.entityId);
      if (link !== undefined && link.status === "linked") {
        link.status = "unlinked";
        link.descriptor = null;
        link.unlinkedAt = input.now;
      }
      for (const enrollment of this.#enrollments.values()) {
        if (enrollment.linkId === input.entityId && enrollment.status !== "revoked") {
          enrollment.status = "revoked";
          enrollment.descriptor = null;
          enrollment.revokedAt = input.now;
        }
      }
      this.enqueueCleanup("remove_link", input.entityId, input.entityId, null, input.now);
    } else if (input.entityType === "endpoint_enrollment") {
      const enrollment = this.#enrollments.get(input.entityId);
      const wasActive = enrollment?.status === "active";
      if (enrollment !== undefined && enrollment.status !== "revoked") {
        enrollment.status = "revoked";
        enrollment.descriptor = null;
        enrollment.revokedAt = input.now;
      }
      if (enrollment !== undefined && wasActive) {
        const link = this.#links.get(enrollment.linkId);
        if (link !== undefined) link.descriptor = null;
      }
      if (enrollment !== undefined) {
        this.enqueueCleanup(
          "remove_enrollment",
          enrollment.linkId,
          enrollment.enrollmentId,
          null,
          input.now,
        );
      }
    } else if (input.entityType === "device") {
      const device = this.#devices.get(
        `${input.principal.issuer}\u0000${input.principal.subject}\u0000${input.entityId}`,
      );
      if (device !== undefined) device.status = "revoked";
    }
    this.#audits.push(structuredClone(input.audit));
    return { record: cloneRevocation(record), created: true };
  }

  async isRevoked(
    principal: Principal,
    entityType: RevocableEntityType,
    entityId: string,
  ): Promise<boolean> {
    return this.#revocations.has(revocationKey(principal, entityType, entityId));
  }

  async appendAudit(event: AuditEvent): Promise<void> {
    this.#audits.push(structuredClone(event));
  }

  async queryAudit(afterEventId: string | null, limit: number): Promise<AuditEvent[]> {
    const start =
      afterEventId === null
        ? 0
        : Math.max(0, this.#audits.findIndex((event) => event.eventId === afterEventId) + 1);
    return this.#audits.slice(start, start + limit).map((event) => structuredClone(event));
  }

  async claimProviderCleanup(now: Date, limit: number): Promise<ProviderCleanupJob[]> {
    const firstLinkJob = new Set<string>();
    return [...this.#cleanupJobs.values()]
      .filter((job) => {
        if (firstLinkJob.has(job.linkId)) return false;
        firstLinkJob.add(job.linkId);
        return true;
      })
      .filter((job) => job.nextAttemptAt.getTime() <= now.getTime())
      .slice(0, limit)
      .map((job) => {
        const claimToken = `clm_${crypto.randomUUID().replaceAll("-", "")}`;
        job.attempt += 1;
        job.claimToken = claimToken;
        job.nextAttemptAt = new Date(now.getTime() + 30_000);
        return {
          jobId: job.jobId,
          claimToken,
          linkId: job.linkId,
          action: job.action,
          targetId: job.targetId,
          activeEnrollmentId: job.activeEnrollmentId,
          attempt: job.attempt,
        };
      });
  }

  async completeProviderCleanup(jobId: string, claimToken: string): Promise<boolean> {
    const job = this.#cleanupJobs.get(jobId);
    if (job?.claimToken !== claimToken) return false;
    this.#cleanupJobs.delete(jobId);
    return true;
  }

  async retryProviderCleanup(
    jobId: string,
    claimToken: string,
    nextAttemptAt: Date,
  ): Promise<boolean> {
    const job = this.#cleanupJobs.get(jobId);
    if (job?.claimToken !== claimToken) return false;
    job.claimToken = null;
    job.nextAttemptAt = new Date(nextAttemptAt);
    return true;
  }

  private ownsEntity(
    principal: Principal,
    entityType: RevocableEntityType,
    entityId: string,
  ): boolean {
    switch (entityType) {
      case "runtime_link": {
        const value = this.#links.get(entityId);
        return value !== undefined && samePrincipal(value.principal, principal);
      }
      case "endpoint_enrollment": {
        const value = this.#enrollments.get(entityId);
        return value !== undefined && samePrincipal(value.principal, principal);
      }
      case "device":
        return this.#devices.has(`${principal.issuer}\u0000${principal.subject}\u0000${entityId}`);
    }
  }

  private enqueueCleanup(
    action: ProviderCleanupJob["action"],
    linkId: string,
    targetId: string,
    activeEnrollmentId: string | null,
    now: Date,
  ): void {
    const existing = [...this.#cleanupJobs.values()].find(
      (job) =>
        job.action === action &&
        job.targetId === targetId &&
        job.activeEnrollmentId === activeEnrollmentId,
    );
    if (existing !== undefined) return;
    const jobId = `pcj_${crypto.randomUUID().replaceAll("-", "")}`;
    this.#cleanupJobs.set(jobId, {
      jobId,
      linkId,
      action,
      targetId,
      activeEnrollmentId,
      attempt: 0,
      claimToken: null,
      nextAttemptAt: new Date(now),
    });
  }
}

function revocationKey(
  principal: Principal,
  entityType: RevocableEntityType,
  entityId: string,
): string {
  return `${principal.issuer}\u0000${principal.subject}\u0000${entityType}\u0000${entityId}`;
}

function cloneChallenge(value: LinkChallengeRecord): LinkChallengeRecord {
  return structuredClone(value);
}
function cloneLink(value: RuntimeLinkRecord): RuntimeLinkRecord {
  return structuredClone(value);
}
function cloneEnrollment(value: EndpointEnrollmentRecord): EndpointEnrollmentRecord {
  return structuredClone(value);
}
function cloneBootstrap(value: BootstrapRecord): BootstrapRecord {
  return structuredClone(value);
}
function cloneRevocation(value: RevocationRecord): RevocationRecord {
  return structuredClone(value);
}
