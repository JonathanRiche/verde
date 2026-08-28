import postgres, { type Sql, type TransactionSql } from "postgres";

import { conflict } from "./errors.ts";
import type { ControlPlaneStore, StoreResult } from "./store.ts";
import type {
  AuditEvent,
  BootstrapRecord,
  EndpointEnrollmentRecord,
  LinkChallengeRecord,
  Principal,
  ProviderCleanupJob,
  PublicEncryptionJwk,
  PublicSigningJwk,
  RevocableEntityType,
  RevocationRecord,
  RuntimeDescriptor,
  RuntimeLinkRecord,
  Scope,
} from "./types.ts";

type Queryable = Sql | TransactionSql;

interface ChallengeRow {
  challenge_id: string;
  request_id: string;
  request_digest: string;
  principal_issuer: string;
  principal_subject: string;
  runtime_id: string;
  instance_id: string;
  runtime_signing_jwk: PublicSigningJwk;
  runtime_key_thumbprint: string;
  runtime_encryption_jwk: PublicEncryptionJwk;
  runtime_encryption_key_thumbprint: string;
  nonce: string;
  nonce_hash: string;
  audience: string;
  expires_at: Date;
  created_at: Date;
  consumed_at: Date | null;
  proof_digest: string | null;
  link_id: string | null;
}

interface LinkRow {
  link_id: string;
  challenge_id: string;
  principal_issuer: string;
  principal_subject: string;
  runtime_id: string;
  instance_id: string;
  runtime_signing_jwk: PublicSigningJwk;
  runtime_key_thumbprint: string;
  runtime_encryption_jwk: PublicEncryptionJwk;
  runtime_encryption_key_thumbprint: string;
  descriptor: RuntimeDescriptor | null;
  status: "linked" | "unlinked";
  created_at: Date;
  unlinked_at: Date | null;
}

interface EnrollmentRow {
  enrollment_id: string;
  request_id: string;
  request_digest: string;
  link_id: string;
  principal_issuer: string;
  principal_subject: string;
  provider: "external" | "noop_test";
  descriptor: RuntimeDescriptor | null;
  status: "pending" | "active" | "revoked";
  secret_verifier: string | null;
  secret_expires_at: Date | null;
  created_at: Date;
  activated_at: Date | null;
  revoked_at: Date | null;
}

interface BootstrapRow {
  grant_id: string;
  request_id: string;
  request_digest: string;
  link_id: string;
  principal_issuer: string;
  principal_subject: string;
  runtime_id: string;
  instance_id: string;
  device_id: string;
  device_signing_jwk: PublicSigningJwk;
  device_key_thumbprint: string;
  audience: string;
  client_nonce: string;
  scopes: Scope[];
  issued_at_seconds: string | number;
  expires_at_seconds: string | number;
  created_at: Date;
}

interface DeviceRow {
  device_key_thumbprint: string;
  status: "active" | "revoked";
}

interface RevocationRow {
  revocation_id: string;
  request_id: string;
  request_digest: string;
  principal_issuer: string;
  principal_subject: string;
  entity_type: RevocableEntityType;
  entity_id: string;
  reason: string | null;
  revoked_at: Date;
}

interface AuditRow {
  event_id: string;
  event_type: AuditEvent["eventType"];
  outcome: AuditEvent["outcome"];
  actor: AuditEvent["actor"];
  correlation_id: string;
  request_id: string | null;
  runtime_id: string | null;
  instance_id: string | null;
  device_id: string | null;
  link_id: string | null;
  grant_id: string | null;
  enrollment_id: string | null;
  reason_code: string | null;
  occurred_at: Date;
}

interface CleanupRow {
  job_id: string;
  link_id: string;
  action: ProviderCleanupJob["action"];
  target_id: string;
  active_enrollment_id: string | null;
  attempt: number;
}

export class PostgresStore implements ControlPlaneStore {
  readonly #sql: Sql;

  constructor(databaseUrl: string, statementTimeoutMs = 10_000) {
    this.#sql = postgres(databaseUrl, {
      max: 10,
      connect_timeout: 5,
      idle_timeout: 30,
      max_lifetime: 60 * 30,
      prepare: true,
      connection: {
        statement_timeout: Math.max(250, statementTimeoutMs - 100),
        lock_timeout: Math.max(100, Math.min(2_000, statementTimeoutMs - 200)),
      },
      onnotice: () => undefined,
    });
  }

  async health(): Promise<void> {
    await this.#sql`SELECT 1`;
  }

  async prune(now: Date): Promise<void> {
    const oneDayAgo = new Date(now.getTime() - 24 * 60 * 60 * 1_000);
    const thirtyDaysAgo = new Date(now.getTime() - 30 * 24 * 60 * 60 * 1_000);
    const expiredGrantCutoff = Math.floor(oneDayAgo.getTime() / 1_000);
    await this.#sql.begin(async (sql) => {
      await sql`
        DELETE FROM runtime_link_challenges
        WHERE link_id IS NULL AND expires_at < ${oneDayAgo}
      `;
      await sql`DELETE FROM bootstrap_grants WHERE expires_at_seconds < ${expiredGrantCutoff}`;
      await sql`
        DELETE FROM endpoint_enrollments
        WHERE status = 'revoked' AND revoked_at < ${thirtyDaysAgo}
      `;
      const staleLinks = await sql<{ link_id: string; challenge_id: string }[]>`
        SELECT link_id, challenge_id FROM runtime_links AS candidate
        WHERE status = 'unlinked' AND unlinked_at < ${thirtyDaysAgo}
          AND NOT EXISTS (
            SELECT 1 FROM endpoint_enrollments WHERE link_id = candidate.link_id
          )
          AND NOT EXISTS (
            SELECT 1 FROM bootstrap_grants WHERE link_id = candidate.link_id
          )
        LIMIT 1000
      `;
      if (staleLinks.length > 0) {
        await sql`
          DELETE FROM runtime_links
          WHERE link_id IN ${sql(staleLinks.map((row) => row.link_id))}
        `;
        await sql`
          DELETE FROM runtime_link_challenges
          WHERE challenge_id IN ${sql(staleLinks.map((row) => row.challenge_id))}
        `;
      }
      await sql`DELETE FROM audit_events WHERE occurred_at < ${thirtyDaysAgo}`;
      await sql`
        DELETE FROM audit_events
        WHERE sequence_id IN (
          SELECT sequence_id FROM audit_events ORDER BY sequence_id DESC OFFSET 100000
        )
      `;
    });
  }

  async close(): Promise<void> {
    await this.#sql.end({ timeout: 5 });
  }

  async issueChallenge(
    record: LinkChallengeRecord,
    audit: AuditEvent,
  ): Promise<StoreResult<LinkChallengeRecord>> {
    return this.#sql.begin(async (sql) => {
      await advisoryLock(
        sql,
        `challenge-request:${record.principal.issuer}\u0000${record.principal.subject}\u0000${record.requestId}`,
      );
      const existing = await sql<ChallengeRow[]>`
        SELECT * FROM runtime_link_challenges
        WHERE principal_issuer = ${record.principal.issuer}
          AND principal_subject = ${record.principal.subject}
          AND request_id = ${record.requestId}
        FOR UPDATE
      `;
      if (existing[0] !== undefined) {
        if (existing[0].request_digest !== record.requestDigest) {
          conflict("idempotency_conflict", "request_id was already used with a different request");
        }
        return { record: challengeFromRow(existing[0]), created: false };
      }
      await enforcePrincipalCap(sql, "runtime_link_challenges", record.principal, 1_000);
      const inserted = await sql<ChallengeRow[]>`
        INSERT INTO runtime_link_challenges (
          challenge_id, request_id, request_digest, principal_issuer, principal_subject,
          runtime_id, instance_id, runtime_signing_jwk, runtime_key_thumbprint,
          runtime_encryption_jwk, runtime_encryption_key_thumbprint, nonce,
          nonce_hash, audience, expires_at, created_at
        ) VALUES (
          ${record.challengeId}, ${record.requestId}, ${record.requestDigest},
          ${record.principal.issuer}, ${record.principal.subject}, ${record.runtimeId},
          ${record.instanceId}, ${sql.json(jsonValue(record.runtimeSigningJwk))},
          ${record.runtimeKeyThumbprint}, ${sql.json(jsonValue(record.runtimeEncryptionJwk))},
          ${record.runtimeEncryptionKeyThumbprint}, ${record.nonce}, ${record.nonceHash},
          ${record.audience}, ${record.expiresAt}, ${record.createdAt}
        ) RETURNING *
      `;
      if (inserted[0] === undefined) throw new Error("challenge insert returned no row");
      await insertAudit(sql, audit);
      return { record: challengeFromRow(inserted[0]), created: true };
    });
  }

  async getChallenge(
    challengeId: string,
    principal: Principal,
  ): Promise<LinkChallengeRecord | null> {
    const rows = await this.#sql<ChallengeRow[]>`
      SELECT * FROM runtime_link_challenges
      WHERE challenge_id = ${challengeId}
        AND principal_issuer = ${principal.issuer}
        AND principal_subject = ${principal.subject}
    `;
    return rows[0] === undefined ? null : challengeFromRow(rows[0]);
  }

  async consumeChallengeAndCreateLink(input: {
    challengeId: string;
    principal: Principal;
    proofDigest: string;
    linkId: string;
    now: Date;
    audit: AuditEvent;
  }): Promise<StoreResult<RuntimeLinkRecord>> {
    return this.#sql.begin(async (sql) => {
      const challenges = await sql<ChallengeRow[]>`
        SELECT * FROM runtime_link_challenges
        WHERE challenge_id = ${input.challengeId}
          AND principal_issuer = ${input.principal.issuer}
          AND principal_subject = ${input.principal.subject}
        FOR UPDATE
      `;
      const challenge = challenges[0];
      if (challenge === undefined) unavailableChallenge();
      if (challenge.consumed_at !== null) {
        if (challenge.proof_digest === input.proofDigest && challenge.link_id !== null) {
          const links = await sql<
            LinkRow[]
          >`SELECT * FROM runtime_links WHERE link_id = ${challenge.link_id}`;
          if (links[0] !== undefined) return { record: linkFromRow(links[0]), created: false };
        }
        unavailableChallenge();
      }
      if (challenge.expires_at.getTime() <= input.now.getTime()) unavailableChallenge();
      await advisoryLock(
        sql,
        `active-link:${input.principal.issuer}\u0000${input.principal.subject}\u0000${challenge.runtime_id}`,
      );
      const active = await sql<{ link_id: string }[]>`
        SELECT link_id FROM runtime_links
        WHERE principal_issuer = ${input.principal.issuer}
          AND principal_subject = ${input.principal.subject}
          AND runtime_id = ${challenge.runtime_id}
          AND status = 'linked'
        FOR UPDATE
      `;
      if (active[0] !== undefined) {
        conflict("runtime_already_linked", "Runtime is already linked to this principal");
      }
      await enforcePrincipalCap(sql, "runtime_links", input.principal, 1_000);
      const links = await sql<LinkRow[]>`
        INSERT INTO runtime_links (
          link_id, challenge_id, principal_issuer, principal_subject, runtime_id,
          instance_id, runtime_signing_jwk, runtime_key_thumbprint, runtime_encryption_jwk,
          runtime_encryption_key_thumbprint, status, created_at
        ) VALUES (
          ${input.linkId}, ${challenge.challenge_id}, ${challenge.principal_issuer},
          ${challenge.principal_subject}, ${challenge.runtime_id}, ${challenge.instance_id},
          ${sql.json(jsonValue(challenge.runtime_signing_jwk))}, ${challenge.runtime_key_thumbprint},
          ${sql.json(jsonValue(challenge.runtime_encryption_jwk))},
          ${challenge.runtime_encryption_key_thumbprint},
          'linked', ${input.now}
        ) RETURNING *
      `;
      await sql`
        UPDATE runtime_link_challenges
        SET consumed_at = ${input.now}, proof_digest = ${input.proofDigest}, link_id = ${input.linkId}
        WHERE challenge_id = ${challenge.challenge_id}
      `;
      if (links[0] === undefined) throw new Error("runtime link insert returned no row");
      await insertAudit(sql, input.audit);
      return { record: linkFromRow(links[0]), created: true };
    });
  }

  async getLink(linkId: string, principal: Principal): Promise<RuntimeLinkRecord | null> {
    const rows = await this.#sql<LinkRow[]>`
      SELECT * FROM runtime_links
      WHERE link_id = ${linkId}
        AND principal_issuer = ${principal.issuer}
        AND principal_subject = ${principal.subject}
    `;
    return rows[0] === undefined ? null : linkFromRow(rows[0]);
  }

  async unlinkLink(
    linkId: string,
    principal: Principal,
    now: Date,
    audit: AuditEvent,
  ): Promise<RuntimeLinkRecord | null> {
    return this.#sql.begin(async (sql) => {
      const rows = await sql<LinkRow[]>`
        SELECT * FROM runtime_links
        WHERE link_id = ${linkId}
          AND principal_issuer = ${principal.issuer}
          AND principal_subject = ${principal.subject}
        FOR UPDATE
      `;
      const existing = rows[0];
      if (existing === undefined) return null;
      if (existing.status === "linked") {
        const updated = await sql<LinkRow[]>`
          UPDATE runtime_links SET status = 'unlinked', descriptor = NULL, unlinked_at = ${now}
          WHERE link_id = ${linkId} RETURNING *
        `;
        await sql`
          UPDATE endpoint_enrollments
          SET status = 'revoked', descriptor = NULL, revoked_at = COALESCE(revoked_at, ${now})
          WHERE link_id = ${linkId}
        `;
        await enqueueCleanup(sql, "remove_link", linkId, linkId, null, now);
        if (updated[0] === undefined) throw new Error("runtime unlink returned no row");
        await insertAudit(sql, audit);
        return linkFromRow(updated[0]);
      }
      return linkFromRow(existing);
    });
  }

  async queryInventory(
    principal: Principal,
    runtimeIds: string[] | null,
  ): Promise<RuntimeLinkRecord[]> {
    const rows =
      runtimeIds === null
        ? await this.#sql<LinkRow[]>`
            SELECT * FROM runtime_links
            WHERE principal_issuer = ${principal.issuer}
              AND principal_subject = ${principal.subject}
              AND status = 'linked' AND descriptor IS NOT NULL
            ORDER BY runtime_id
            LIMIT 100
          `
        : await this.#sql<LinkRow[]>`
            SELECT * FROM runtime_links
            WHERE principal_issuer = ${principal.issuer}
              AND principal_subject = ${principal.subject}
              AND status = 'linked' AND descriptor IS NOT NULL
              AND runtime_id IN ${this.#sql(runtimeIds)}
            ORDER BY runtime_id
            LIMIT 100
          `;
    return rows.map(linkFromRow);
  }

  async reserveEndpointEnrollment(
    record: EndpointEnrollmentRecord,
    audit: AuditEvent,
  ): Promise<StoreResult<EndpointEnrollmentRecord>> {
    return this.#sql.begin(async (sql) => {
      await advisoryLock(
        sql,
        `enrollment-request:${record.principal.issuer}\u0000${record.principal.subject}\u0000${record.requestId}`,
      );
      const existing = await sql<EnrollmentRow[]>`
        SELECT * FROM endpoint_enrollments
        WHERE principal_issuer = ${record.principal.issuer}
          AND principal_subject = ${record.principal.subject}
          AND request_id = ${record.requestId}
        FOR UPDATE
      `;
      if (existing[0] !== undefined) {
        if (existing[0].request_digest !== record.requestDigest) {
          conflict("idempotency_conflict", "request_id was already used with a different request");
        }
        return { record: enrollmentFromRow(existing[0]), created: false };
      }
      const links = await sql<LinkRow[]>`
        SELECT * FROM runtime_links
        WHERE link_id = ${record.linkId}
          AND principal_issuer = ${record.principal.issuer}
          AND principal_subject = ${record.principal.subject}
          AND status = 'linked'
        FOR UPDATE
      `;
      if (links[0] === undefined) conflict("link_unavailable", "Runtime link is unavailable");
      await enforcePrincipalCap(sql, "endpoint_enrollments", record.principal, 1_000);
      const inserted = await sql<EnrollmentRow[]>`
        INSERT INTO endpoint_enrollments (
          enrollment_id, request_id, request_digest, link_id, principal_issuer,
          principal_subject, provider, status, created_at
        ) VALUES (
          ${record.enrollmentId}, ${record.requestId}, ${record.requestDigest}, ${record.linkId},
          ${record.principal.issuer}, ${record.principal.subject}, ${record.provider},
          'pending', ${record.createdAt}
        ) RETURNING *
      `;
      if (inserted[0] === undefined) throw new Error("endpoint enrollment insert returned no row");
      await insertAudit(sql, audit);
      return { record: enrollmentFromRow(inserted[0]), created: true };
    });
  }

  async activateEndpointEnrollment(input: {
    enrollmentId: string;
    principal: Principal;
    descriptor: RuntimeDescriptor;
    secretVerifier: string | null;
    secretExpiresAt: Date | null;
    now: Date;
    audit: AuditEvent;
  }): Promise<EndpointEnrollmentRecord> {
    return this.#sql.begin(async (sql) => {
      const rows = await sql<EnrollmentRow[]>`
        SELECT * FROM endpoint_enrollments
        WHERE enrollment_id = ${input.enrollmentId}
          AND principal_issuer = ${input.principal.issuer}
          AND principal_subject = ${input.principal.subject}
        FOR UPDATE
      `;
      const record = rows[0];
      if (record === undefined)
        conflict("enrollment_unavailable", "Endpoint enrollment is unavailable");
      await advisoryLock(sql, `enrollment-link:${record.link_id}`);
      if (record.status === "active") return enrollmentFromRow(record);
      if (record.status !== "pending") {
        conflict("enrollment_unavailable", "Endpoint enrollment is unavailable");
      }
      const links = await sql<LinkRow[]>`
        SELECT * FROM runtime_links WHERE link_id = ${record.link_id} AND status = 'linked' FOR UPDATE
      `;
      if (links[0] === undefined) conflict("link_unavailable", "Runtime link is unavailable");
      await sql`
        UPDATE endpoint_enrollments
        SET status = 'revoked', descriptor = NULL, revoked_at = ${input.now}
        WHERE link_id = ${record.link_id} AND status = 'active'
      `;
      const updated = await sql<EnrollmentRow[]>`
        UPDATE endpoint_enrollments
        SET status = 'active', descriptor = ${sql.json(jsonValue(input.descriptor))},
          secret_verifier = ${input.secretVerifier}, secret_expires_at = ${input.secretExpiresAt},
          activated_at = ${input.now}
        WHERE enrollment_id = ${input.enrollmentId} AND status = 'pending'
        RETURNING *
      `;
      await sql`
        UPDATE runtime_links SET descriptor = ${sql.json(jsonValue(input.descriptor))}
        WHERE link_id = ${record.link_id}
      `;
      if (updated[0] === undefined) throw new Error("endpoint activation returned no row");
      await enqueueCleanup(
        sql,
        "reconcile_link",
        record.link_id,
        record.link_id,
        input.enrollmentId,
        input.now,
      );
      await insertAudit(sql, input.audit);
      return enrollmentFromRow(updated[0]);
    });
  }

  async reserveBootstrap(
    record: BootstrapRecord,
    audit: AuditEvent,
  ): Promise<StoreResult<BootstrapRecord>> {
    return this.#sql.begin(async (sql) => {
      await advisoryLock(
        sql,
        `bootstrap-request:${record.principal.issuer}\u0000${record.principal.subject}\u0000${record.requestId}`,
      );
      await advisoryLock(
        sql,
        `device:${record.principal.issuer}\u0000${record.principal.subject}\u0000${record.deviceId}`,
      );
      const devices = await sql<DeviceRow[]>`
        SELECT device_key_thumbprint, status FROM connect_devices
        WHERE principal_issuer = ${record.principal.issuer}
          AND principal_subject = ${record.principal.subject}
          AND device_id = ${record.deviceId}
        FOR UPDATE
      `;
      const device = devices[0];
      if (device === undefined) {
        await enforcePrincipalCap(sql, "connect_devices", record.principal, 1_000);
        await sql`
          INSERT INTO connect_devices (
            principal_issuer, principal_subject, device_id, device_signing_jwk,
            device_key_thumbprint, status, created_at
          ) VALUES (
            ${record.principal.issuer}, ${record.principal.subject}, ${record.deviceId},
            ${sql.json(jsonValue(record.deviceSigningJwk))}, ${record.deviceKeyThumbprint},
            'active', ${record.createdAt}
          )
        `;
      } else if (device.device_key_thumbprint !== record.deviceKeyThumbprint) {
        conflict("device_key_mismatch", "device_id is already bound to another signing key");
      } else if (device.status === "revoked") {
        conflict("bootstrap_revoked", "Bootstrap request targets a revoked device");
      }
      const revoked = await sql<{ present: boolean }[]>`
        SELECT EXISTS (
          SELECT 1 FROM revocations
          WHERE principal_issuer = ${record.principal.issuer}
            AND principal_subject = ${record.principal.subject}
            AND ((entity_type = 'runtime_link' AND entity_id = ${record.linkId})
              OR (entity_type = 'device' AND entity_id = ${record.deviceId}))
        ) AS present
      `;
      if (revoked[0]?.present === true) {
        conflict("bootstrap_revoked", "Bootstrap request targets a revoked entity");
      }
      const existing = await sql<BootstrapRow[]>`
        SELECT * FROM bootstrap_grants
        WHERE principal_issuer = ${record.principal.issuer}
          AND principal_subject = ${record.principal.subject}
          AND request_id = ${record.requestId}
        FOR UPDATE
      `;
      if (existing[0] !== undefined) {
        if (existing[0].request_digest !== record.requestDigest) {
          conflict("idempotency_conflict", "request_id was already used with a different request");
        }
        return { record: bootstrapFromRow(existing[0]), created: false };
      }
      const links = await sql<LinkRow[]>`
        SELECT * FROM runtime_links
        WHERE link_id = ${record.linkId}
          AND principal_issuer = ${record.principal.issuer}
          AND principal_subject = ${record.principal.subject}
          AND status = 'linked' AND descriptor IS NOT NULL
        FOR UPDATE
      `;
      if (links[0] === undefined) conflict("link_unavailable", "Runtime link is unavailable");
      await enforcePrincipalCap(sql, "bootstrap_grants", record.principal, 10_000);
      const inserted = await sql<BootstrapRow[]>`
        INSERT INTO bootstrap_grants (
          grant_id, request_id, request_digest, link_id, principal_issuer, principal_subject,
          runtime_id, instance_id, device_id, device_signing_jwk, device_key_thumbprint, audience, client_nonce,
          scopes, issued_at_seconds, expires_at_seconds, created_at
        ) VALUES (
          ${record.grantId}, ${record.requestId}, ${record.requestDigest}, ${record.linkId},
          ${record.principal.issuer}, ${record.principal.subject}, ${record.runtimeId},
          ${record.instanceId}, ${record.deviceId}, ${sql.json(jsonValue(record.deviceSigningJwk))},
          ${record.deviceKeyThumbprint},
          ${record.audience}, ${record.clientNonce}, ${record.scopes}, ${record.issuedAtSeconds},
          ${record.expiresAtSeconds}, ${record.createdAt}
        ) RETURNING *
      `;
      if (inserted[0] === undefined) throw new Error("bootstrap insert returned no row");
      await insertAudit(sql, audit);
      return { record: bootstrapFromRow(inserted[0]), created: true };
    });
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
    return this.#sql.begin(async (sql) => {
      await advisoryLock(
        sql,
        `revocation-request:${input.principal.issuer}\u0000${input.principal.subject}\u0000${input.requestId}`,
      );
      await advisoryLock(
        sql,
        `revocation-entity:${input.principal.issuer}\u0000${input.principal.subject}\u0000${input.entityType}\u0000${input.entityId}`,
      );
      const requestExisting = await sql<RevocationRow[]>`
        SELECT * FROM revocations
        WHERE principal_issuer = ${input.principal.issuer}
          AND principal_subject = ${input.principal.subject}
          AND request_id = ${input.requestId}
        FOR UPDATE
      `;
      if (requestExisting[0] !== undefined) {
        if (requestExisting[0].request_digest !== input.requestDigest) {
          conflict("idempotency_conflict", "request_id was already used with a different request");
        }
        return { record: revocationFromRow(requestExisting[0]), created: false };
      }
      if (!(await ownsEntity(sql, input.principal, input.entityType, input.entityId))) return null;
      await enforcePrincipalCap(sql, "revocations", input.principal, 10_000);
      const inserted = await sql<RevocationRow[]>`
        INSERT INTO revocations (
          revocation_id, request_id, request_digest, principal_issuer, principal_subject, entity_type,
          entity_id, reason, revoked_at
        ) VALUES (
          ${input.revocationId}, ${input.requestId}, ${input.requestDigest},
          ${input.principal.issuer}, ${input.principal.subject},
          ${input.entityType}, ${input.entityId}, ${input.reason}, ${input.now}
        )
        ON CONFLICT DO NOTHING
        RETURNING *
      `;
      if (inserted[0] !== undefined) {
        if (input.entityType === "runtime_link") {
          await sql`
            UPDATE runtime_links
            SET status = 'unlinked', descriptor = NULL, unlinked_at = COALESCE(unlinked_at, ${input.now})
            WHERE link_id = ${input.entityId}
          `;
          await sql`
            UPDATE endpoint_enrollments
            SET status = 'revoked', descriptor = NULL, revoked_at = COALESCE(revoked_at, ${input.now})
            WHERE link_id = ${input.entityId}
          `;
          await enqueueCleanup(sql, "remove_link", input.entityId, input.entityId, null, input.now);
        } else if (input.entityType === "endpoint_enrollment") {
          const enrollments = await sql<{ link_id: string; status: EnrollmentRow["status"] }[]>`
            SELECT link_id, status FROM endpoint_enrollments
            WHERE enrollment_id = ${input.entityId}
              AND principal_issuer = ${input.principal.issuer}
              AND principal_subject = ${input.principal.subject}
            FOR UPDATE
          `;
          const enrollment = enrollments[0];
          if (enrollment === undefined) throw new Error("revoked enrollment disappeared");
          await sql`
            UPDATE endpoint_enrollments
            SET status = 'revoked', descriptor = NULL, revoked_at = COALESCE(revoked_at, ${input.now})
            WHERE enrollment_id = ${input.entityId} AND status <> 'revoked'
          `;
          if (enrollment.status === "active") {
            await sql`
              UPDATE runtime_links SET descriptor = NULL WHERE link_id = ${enrollment.link_id}
            `;
          }
          await enqueueCleanup(
            sql,
            "remove_enrollment",
            enrollment.link_id,
            input.entityId,
            null,
            input.now,
          );
        } else if (input.entityType === "device") {
          await sql`
            UPDATE connect_devices SET status = 'revoked', revoked_at = COALESCE(revoked_at, ${input.now})
            WHERE principal_issuer = ${input.principal.issuer}
              AND principal_subject = ${input.principal.subject}
              AND device_id = ${input.entityId}
          `;
        }
        await insertAudit(sql, input.audit);
        return { record: revocationFromRow(inserted[0]), created: true };
      }
      const existing = await sql<RevocationRow[]>`
        SELECT * FROM revocations
        WHERE principal_issuer = ${input.principal.issuer}
          AND principal_subject = ${input.principal.subject}
          AND entity_type = ${input.entityType} AND entity_id = ${input.entityId}
      `;
      if (existing[0] === undefined) throw new Error("revocation idempotency row disappeared");
      return { record: revocationFromRow(existing[0]), created: false };
    });
  }

  async isRevoked(
    principal: Principal,
    entityType: RevocableEntityType,
    entityId: string,
  ): Promise<boolean> {
    const rows = await this.#sql<{ present: boolean }[]>`
      SELECT EXISTS (
        SELECT 1 FROM revocations
        WHERE principal_issuer = ${principal.issuer}
          AND principal_subject = ${principal.subject}
          AND entity_type = ${entityType} AND entity_id = ${entityId}
      ) AS present
    `;
    return rows[0]?.present === true;
  }

  async appendAudit(event: AuditEvent): Promise<void> {
    await this.#sql.begin(async (sql) => {
      await insertAudit(sql, event);
    });
  }

  async queryAudit(afterEventId: string | null, limit: number): Promise<AuditEvent[]> {
    const rows =
      afterEventId === null
        ? await this.#sql<AuditRow[]>`
            SELECT * FROM audit_events ORDER BY sequence_id LIMIT ${limit}
          `
        : await this.#sql<AuditRow[]>`
            SELECT * FROM audit_events
            WHERE sequence_id > COALESCE(
              (SELECT sequence_id FROM audit_events WHERE event_id = ${afterEventId}), 0
            )
            ORDER BY sequence_id LIMIT ${limit}
          `;
    return rows.map(auditFromRow);
  }

  async claimProviderCleanup(now: Date, limit: number): Promise<ProviderCleanupJob[]> {
    return this.#sql.begin(async (sql) => {
      const rows = await sql<CleanupRow[]>`
        SELECT candidate.job_id, candidate.link_id, candidate.action, candidate.target_id,
          candidate.active_enrollment_id, candidate.attempt
        FROM provider_cleanup_jobs AS candidate
        WHERE candidate.next_attempt_at <= ${now}
          AND NOT EXISTS (
            SELECT 1 FROM provider_cleanup_jobs AS earlier
            WHERE earlier.link_id = candidate.link_id
              AND earlier.sequence_id < candidate.sequence_id
          )
        ORDER BY candidate.sequence_id
        LIMIT ${limit}
        FOR UPDATE SKIP LOCKED
      `;
      if (rows.length === 0) return [];
      const leaseUntil = new Date(now.getTime() + 30_000);
      const claimed: ProviderCleanupJob[] = [];
      for (const row of rows) {
        const claimToken = `clm_${crypto.randomUUID().replaceAll("-", "")}`;
        await sql`
          UPDATE provider_cleanup_jobs
          SET attempt = attempt + 1, claim_token = ${claimToken}, next_attempt_at = ${leaseUntil}
          WHERE job_id = ${row.job_id}
        `;
        claimed.push({
          jobId: row.job_id,
          claimToken,
          linkId: row.link_id,
          action: row.action,
          targetId: row.target_id,
          activeEnrollmentId: row.active_enrollment_id,
          attempt: row.attempt + 1,
        });
      }
      return claimed;
    });
  }

  async completeProviderCleanup(jobId: string, claimToken: string): Promise<boolean> {
    const rows = await this.#sql<{ job_id: string }[]>`
      DELETE FROM provider_cleanup_jobs
      WHERE job_id = ${jobId} AND claim_token = ${claimToken}
      RETURNING job_id
    `;
    return rows.length === 1;
  }

  async retryProviderCleanup(
    jobId: string,
    claimToken: string,
    nextAttemptAt: Date,
  ): Promise<boolean> {
    const rows = await this.#sql<{ job_id: string }[]>`
      UPDATE provider_cleanup_jobs
      SET claim_token = NULL, next_attempt_at = ${nextAttemptAt}
      WHERE job_id = ${jobId} AND claim_token = ${claimToken}
      RETURNING job_id
    `;
    return rows.length === 1;
  }
}

async function ownsEntity(
  sql: Queryable,
  principal: Principal,
  entityType: RevocableEntityType,
  entityId: string,
): Promise<boolean> {
  let rows: { present: boolean }[];
  switch (entityType) {
    case "runtime_link":
      rows = await sql<{ present: boolean }[]>`
        SELECT EXISTS (SELECT 1 FROM runtime_links WHERE link_id = ${entityId}
          AND principal_issuer = ${principal.issuer} AND principal_subject = ${principal.subject}) AS present`;
      break;
    case "endpoint_enrollment":
      rows = await sql<{ present: boolean }[]>`
        SELECT EXISTS (SELECT 1 FROM endpoint_enrollments WHERE enrollment_id = ${entityId}
          AND principal_issuer = ${principal.issuer} AND principal_subject = ${principal.subject}) AS present`;
      break;
    case "device":
      rows = await sql<{ present: boolean }[]>`
        SELECT EXISTS (SELECT 1 FROM connect_devices WHERE device_id = ${entityId}
          AND principal_issuer = ${principal.issuer} AND principal_subject = ${principal.subject}) AS present`;
      break;
  }
  return rows[0]?.present === true;
}

function unavailableChallenge(): never {
  conflict("challenge_unavailable", "Link challenge is invalid, expired, or already consumed");
}

function principal(issuer: string, subject: string): Principal {
  return { issuer, subject };
}
function challengeFromRow(row: ChallengeRow): LinkChallengeRecord {
  return {
    challengeId: row.challenge_id,
    requestId: row.request_id,
    requestDigest: row.request_digest,
    principal: principal(row.principal_issuer, row.principal_subject),
    runtimeId: row.runtime_id,
    instanceId: row.instance_id,
    runtimeSigningJwk: row.runtime_signing_jwk,
    runtimeKeyThumbprint: row.runtime_key_thumbprint,
    runtimeEncryptionJwk: row.runtime_encryption_jwk,
    runtimeEncryptionKeyThumbprint: row.runtime_encryption_key_thumbprint,
    nonce: row.nonce,
    nonceHash: row.nonce_hash,
    audience: row.audience,
    expiresAt: row.expires_at,
    createdAt: row.created_at,
    consumedAt: row.consumed_at,
    proofDigest: row.proof_digest,
    linkId: row.link_id,
  };
}
function linkFromRow(row: LinkRow): RuntimeLinkRecord {
  return {
    linkId: row.link_id,
    challengeId: row.challenge_id,
    principal: principal(row.principal_issuer, row.principal_subject),
    runtimeId: row.runtime_id,
    instanceId: row.instance_id,
    runtimeSigningJwk: row.runtime_signing_jwk,
    runtimeKeyThumbprint: row.runtime_key_thumbprint,
    runtimeEncryptionJwk: row.runtime_encryption_jwk,
    runtimeEncryptionKeyThumbprint: row.runtime_encryption_key_thumbprint,
    descriptor: row.descriptor,
    status: row.status,
    createdAt: row.created_at,
    unlinkedAt: row.unlinked_at,
  };
}
function enrollmentFromRow(row: EnrollmentRow): EndpointEnrollmentRecord {
  return {
    enrollmentId: row.enrollment_id,
    requestId: row.request_id,
    requestDigest: row.request_digest,
    linkId: row.link_id,
    principal: principal(row.principal_issuer, row.principal_subject),
    provider: row.provider,
    descriptor: row.descriptor,
    status: row.status,
    secretVerifier: row.secret_verifier,
    secretExpiresAt: row.secret_expires_at,
    createdAt: row.created_at,
    activatedAt: row.activated_at,
    revokedAt: row.revoked_at,
  };
}
function bootstrapFromRow(row: BootstrapRow): BootstrapRecord {
  return {
    grantId: row.grant_id,
    requestId: row.request_id,
    requestDigest: row.request_digest,
    linkId: row.link_id,
    principal: principal(row.principal_issuer, row.principal_subject),
    runtimeId: row.runtime_id,
    instanceId: row.instance_id,
    deviceId: row.device_id,
    deviceSigningJwk: row.device_signing_jwk,
    deviceKeyThumbprint: row.device_key_thumbprint,
    audience: row.audience,
    clientNonce: row.client_nonce,
    scopes: row.scopes,
    issuedAtSeconds: Number(row.issued_at_seconds),
    expiresAtSeconds: Number(row.expires_at_seconds),
    createdAt: row.created_at,
  };
}
function revocationFromRow(row: RevocationRow): RevocationRecord {
  return {
    revocationId: row.revocation_id,
    requestId: row.request_id,
    requestDigest: row.request_digest,
    principal: principal(row.principal_issuer, row.principal_subject),
    entityType: row.entity_type,
    entityId: row.entity_id,
    reason: row.reason,
    revokedAt: row.revoked_at,
  };
}
function auditFromRow(row: AuditRow): AuditEvent {
  return {
    eventId: row.event_id,
    eventType: row.event_type,
    outcome: row.outcome,
    actor: row.actor,
    correlationId: row.correlation_id,
    ...(row.request_id === null ? {} : { requestId: row.request_id }),
    ...(row.runtime_id === null ? {} : { runtimeId: row.runtime_id }),
    ...(row.instance_id === null ? {} : { instanceId: row.instance_id }),
    ...(row.device_id === null ? {} : { deviceId: row.device_id }),
    ...(row.link_id === null ? {} : { linkId: row.link_id }),
    ...(row.grant_id === null ? {} : { grantId: row.grant_id }),
    ...(row.enrollment_id === null ? {} : { enrollmentId: row.enrollment_id }),
    ...(row.reason_code === null ? {} : { reasonCode: row.reason_code }),
    occurredAt: row.occurred_at,
  };
}

function jsonValue(value: unknown): postgres.JSONValue {
  return value as postgres.JSONValue;
}

async function advisoryLock(sql: Queryable, key: string): Promise<void> {
  await sql`SELECT pg_advisory_xact_lock(hashtextextended(${key}, 0))`;
}

async function insertAudit(sql: Queryable, event: AuditEvent): Promise<void> {
  await sql`
    INSERT INTO audit_events (
      event_id, event_type, outcome, actor, correlation_id, request_id, runtime_id,
      instance_id, device_id, link_id, grant_id, enrollment_id, reason_code, occurred_at
    ) VALUES (
      ${event.eventId}, ${event.eventType}, ${event.outcome}, ${sql.json(jsonValue(event.actor))},
      ${event.correlationId}, ${event.requestId ?? null}, ${event.runtimeId ?? null},
      ${event.instanceId ?? null}, ${event.deviceId ?? null}, ${event.linkId ?? null},
      ${event.grantId ?? null}, ${event.enrollmentId ?? null}, ${event.reasonCode ?? null},
      ${event.occurredAt}
    )
  `;
  await sql`
    DELETE FROM audit_events
    WHERE sequence_id IN (
      SELECT sequence_id FROM audit_events ORDER BY sequence_id DESC OFFSET 100000
    )
  `;
}

async function enqueueCleanup(
  sql: Queryable,
  action: ProviderCleanupJob["action"],
  linkId: string,
  targetId: string,
  activeEnrollmentId: string | null,
  now: Date,
): Promise<void> {
  const capacity = await sql<{ count: string | number }[]>`
    SELECT count(*) AS count FROM provider_cleanup_jobs
  `;
  if (Number(capacity[0]?.count ?? 0) >= 100_000) {
    conflict(
      "cleanup_capacity_exceeded",
      "Provider cleanup backlog reached its safety limit; mutations are paused",
    );
  }
  const jobId = `pcj_${crypto.randomUUID().replaceAll("-", "")}`;
  await sql`
    INSERT INTO provider_cleanup_jobs (
      job_id, link_id, action, target_id, active_enrollment_id, next_attempt_at, created_at
    ) VALUES (
      ${jobId}, ${linkId}, ${action}, ${targetId}, ${activeEnrollmentId}, ${now}, ${now}
    )
    ON CONFLICT DO NOTHING
  `;
}

async function enforcePrincipalCap(
  sql: Queryable,
  table:
    | "runtime_link_challenges"
    | "runtime_links"
    | "endpoint_enrollments"
    | "connect_devices"
    | "bootstrap_grants"
    | "revocations",
  principalValue: Principal,
  maximum: number,
): Promise<void> {
  const rows = await sql<{ count: string | number }[]>`
    SELECT count(*) AS count FROM ${sql(table)}
    WHERE principal_issuer = ${principalValue.issuer}
      AND principal_subject = ${principalValue.subject}
  `;
  if (Number(rows[0]?.count ?? 0) >= maximum) {
    conflict(
      "principal_capacity_exceeded",
      "Principal reached the reference service retention limit; prune or unlink old records",
    );
  }
}
