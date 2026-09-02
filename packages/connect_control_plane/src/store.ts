import type {
  AuditEvent,
  BootstrapRecord,
  EndpointEnrollmentRecord,
  LinkChallengeRecord,
  Principal,
  ProviderCleanupJob,
  RevocableEntityType,
  RevocationRecord,
  RuntimeDescriptor,
  RuntimeLinkRecord,
} from "./types.ts";

export interface StoreResult<T> {
  record: T;
  created: boolean;
}

export interface ControlPlaneStore {
  health(): Promise<void>;
  prune(now: Date): Promise<void>;
  close(): Promise<void>;

  issueChallenge(
    record: LinkChallengeRecord,
    audit: AuditEvent,
  ): Promise<StoreResult<LinkChallengeRecord>>;
  getChallenge(challengeId: string, principal: Principal): Promise<LinkChallengeRecord | null>;
  consumeChallengeAndCreateLink(input: {
    challengeId: string;
    principal: Principal;
    proofDigest: string;
    linkId: string;
    now: Date;
    audit: AuditEvent;
  }): Promise<StoreResult<RuntimeLinkRecord>>;

  getLink(linkId: string, principal: Principal): Promise<RuntimeLinkRecord | null>;
  unlinkLink(
    linkId: string,
    principal: Principal,
    now: Date,
    audit: AuditEvent,
  ): Promise<RuntimeLinkRecord | null>;
  queryInventory(principal: Principal, runtimeIds: string[] | null): Promise<RuntimeLinkRecord[]>;

  reserveEndpointEnrollment(
    record: EndpointEnrollmentRecord,
    audit: AuditEvent,
  ): Promise<StoreResult<EndpointEnrollmentRecord>>;
  activateEndpointEnrollment(input: {
    enrollmentId: string;
    principal: Principal;
    descriptor: RuntimeDescriptor;
    secretVerifier: string | null;
    secretExpiresAt: Date | null;
    now: Date;
    audit: AuditEvent;
  }): Promise<EndpointEnrollmentRecord>;

  reserveBootstrap(
    record: BootstrapRecord,
    audit: AuditEvent,
  ): Promise<StoreResult<BootstrapRecord>>;
  revoke(input: {
    revocationId: string;
    requestId: string;
    requestDigest: string;
    principal: Principal;
    entityType: RevocableEntityType;
    entityId: string;
    reason: string | null;
    now: Date;
    audit: AuditEvent;
  }): Promise<StoreResult<RevocationRecord> | null>;
  isRevoked(
    principal: Principal,
    entityType: RevocableEntityType,
    entityId: string,
  ): Promise<boolean>;

  appendAudit(event: AuditEvent): Promise<void>;
  queryAudit(afterEventId: string | null, limit: number): Promise<AuditEvent[]>;
  claimProviderCleanup(now: Date, limit: number): Promise<ProviderCleanupJob[]>;
  completeProviderCleanup(jobId: string, claimToken: string): Promise<boolean>;
  retryProviderCleanup(jobId: string, claimToken: string, nextAttemptAt: Date): Promise<boolean>;
}

export interface EndpointEnrollmentInput {
  enrollmentId: string;
  requestId: string;
  requestDigest: string;
  link: RuntimeLinkRecord;
  requestedDescriptor: RuntimeDescriptor | null;
  now: Date;
}
