import type { JWK } from "jose";

export const CONTRACT_VERSION = "1" as const;

export const ALL_SCOPES = [
  "runtime:read",
  "chat:read",
  "chat:write",
  "terminal:read",
  "terminal:write",
  "repository:read",
  "repository:write",
  "device:read",
] as const;

export type Scope = (typeof ALL_SCOPES)[number];

export interface Principal {
  issuer: string;
  subject: string;
}

export interface PublicSigningJwk extends JWK {
  kty: "OKP";
  crv: "Ed25519";
  x: string;
  kid: string;
  use?: "sig";
  alg?: "EdDSA";
}

export interface PublicEncryptionJwk extends JWK {
  kty: "OKP";
  crv: "X25519";
  x: string;
  kid: string;
  use?: "enc";
  alg?: "ECDH-ES";
}

export interface TlsIdentity {
  kind: "spki_sha256";
  sha256: string;
}

export interface RuntimeDescriptor {
  contract_version: typeof CONTRACT_VERSION;
  runtime_id: string;
  instance_id: string;
  https_url: string;
  wss_url: string;
  tls_identity: TlsIdentity;
  protocol: {
    major: 1;
    minor: number;
  };
  capabilities: string[];
}

export interface LinkChallengeRecord {
  challengeId: string;
  requestId: string;
  requestDigest: string;
  principal: Principal;
  runtimeId: string;
  instanceId: string;
  runtimeSigningJwk: PublicSigningJwk;
  runtimeKeyThumbprint: string;
  runtimeEncryptionJwk: PublicEncryptionJwk;
  runtimeEncryptionKeyThumbprint: string;
  nonce: string;
  nonceHash: string;
  audience: string;
  expiresAt: Date;
  createdAt: Date;
  consumedAt: Date | null;
  proofDigest: string | null;
  linkId: string | null;
}

export interface RuntimeLinkRecord {
  linkId: string;
  challengeId: string;
  principal: Principal;
  runtimeId: string;
  instanceId: string;
  runtimeSigningJwk: PublicSigningJwk;
  runtimeKeyThumbprint: string;
  runtimeEncryptionJwk: PublicEncryptionJwk;
  runtimeEncryptionKeyThumbprint: string;
  descriptor: RuntimeDescriptor | null;
  status: "linked" | "unlinked";
  createdAt: Date;
  unlinkedAt: Date | null;
}

export interface EndpointEnrollmentRecord {
  enrollmentId: string;
  requestId: string;
  requestDigest: string;
  linkId: string;
  principal: Principal;
  provider: "external" | "noop_test";
  descriptor: RuntimeDescriptor | null;
  status: "pending" | "active" | "revoked";
  secretVerifier: string | null;
  secretExpiresAt: Date | null;
  createdAt: Date;
  activatedAt: Date | null;
  revokedAt: Date | null;
}

export interface BootstrapClaims {
  grantId: string;
  requestId: string;
  linkId: string;
  principal: Principal;
  runtimeId: string;
  instanceId: string;
  deviceId: string;
  deviceKeyThumbprint: string;
  deviceSigningJwk: PublicSigningJwk;
  audience: string;
  clientNonce: string;
  scopes: Scope[];
  issuedAtSeconds: number;
  expiresAtSeconds: number;
}

export interface BootstrapRecord extends BootstrapClaims {
  requestDigest: string;
  createdAt: Date;
}

export type RevocableEntityType = "runtime_link" | "device" | "endpoint_enrollment";

export interface RevocationRecord {
  revocationId: string;
  requestId: string;
  requestDigest: string;
  principal: Principal;
  entityType: RevocableEntityType;
  entityId: string;
  reason: string | null;
  revokedAt: Date;
}

export interface ProviderCleanupJob {
  jobId: string;
  claimToken: string;
  linkId: string;
  action: "reconcile_link" | "remove_link" | "remove_enrollment";
  targetId: string;
  activeEnrollmentId: string | null;
  attempt: number;
}

export type AuditEventType =
  | "authentication.succeeded"
  | "authentication.failed"
  | "link.challenge_issued"
  | "link.challenge_consumed"
  | "link.challenge_rejected"
  | "link.created"
  | "link.unlinked"
  | "endpoint.enrollment_reserved"
  | "endpoint.enrollment_rejected"
  | "endpoint.enrolled"
  | "endpoint.revoked"
  | "bootstrap.issued"
  | "bootstrap.rejected"
  | "entity.revoked";

export interface AuditEvent {
  eventId: string;
  eventType: AuditEventType;
  outcome: "success" | "rejected" | "failure";
  actor: Principal | { service: "control-plane" | "operator" };
  correlationId: string;
  requestId?: string;
  runtimeId?: string;
  instanceId?: string;
  deviceId?: string;
  linkId?: string;
  grantId?: string;
  enrollmentId?: string;
  reasonCode?: string;
  occurredAt: Date;
}

export interface OidcMetadata {
  issuer: string;
  authorization_endpoint: string;
  token_endpoint: string;
  jwks_uri: string;
  device_authorization_endpoint?: string;
  code_challenge_methods_supported?: string[];
  id_token_signing_alg_values_supported?: string[];
}

export function samePrincipal(left: Principal, right: Principal): boolean {
  return left.issuer === right.issuer && left.subject === right.subject;
}
