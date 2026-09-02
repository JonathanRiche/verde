import type { Config } from "./config.ts";
import { joinUrl, validateEndpointUrl } from "./config.ts";
import type { EndpointProvider } from "./endpoint_provider.ts";
import { validateDescriptor } from "./endpoint_provider.ts";
import { ApiError, conflict, notFound } from "./errors.ts";
import { newId, randomNonce, sha256Base64Url, stableDigest } from "./ids.ts";
import { validateSchema } from "./schemas.ts";
import { SecretBytes } from "./secrets.ts";
import {
  GrantSigner,
  encryptionKeyThumbprint,
  runtimeKeyThumbprint,
  sealConnectorCredential,
  verifyDeviceBootstrapProof,
  verifyEndpointEnrollmentProof,
  verifyRuntimeLinkProof,
} from "./signer.ts";
import type { ControlPlaneStore } from "./store.ts";
import {
  CONTRACT_VERSION,
  type AuditEvent,
  type BootstrapRecord,
  type Principal,
  type PublicEncryptionJwk,
  type PublicSigningJwk,
  type RevocableEntityType,
  type RuntimeDescriptor,
  type RuntimeLinkRecord,
  type Scope,
} from "./types.ts";

interface ChallengeRequest {
  contract_version: "1";
  request_id: string;
  runtime_id: string;
  instance_id: string;
  runtime_signing_jwk: PublicSigningJwk;
  runtime_encryption_jwk: PublicEncryptionJwk;
}

interface ProofRequest {
  contract_version: "1";
  challenge_id: string;
  proof_jwt: string;
}

interface InventoryRequest {
  contract_version: "1";
  request_id: string;
  runtime_ids?: string[];
}

interface EnrollmentRequest {
  contract_version: "1";
  request_id: string;
  provider: "external" | "noop_test";
  external_descriptor?: RuntimeDescriptor;
  runtime_proof_jwt: string;
  expires_at: string;
}

interface BootstrapRequest {
  contract_version: "1";
  request_id: string;
  runtime_id: string;
  instance_id: string;
  device_id: string;
  device_signing_jwk: PublicSigningJwk;
  device_proof_jwt: string;
  audience: string;
  client_nonce: string;
  scopes: Scope[];
  expires_at: string;
}

interface UnlinkRequest {
  contract_version: "1";
  request_id: string;
}

interface RevocationRequest {
  contract_version: "1";
  request_id: string;
  entity_type: RevocableEntityType;
  entity_id: string;
  reason?: string;
}

export interface EnrollmentWireResult {
  status: number;
  body: Record<string, unknown>;
}

export class ConnectService {
  constructor(
    readonly config: Config,
    readonly store: ControlPlaneStore,
    readonly signer: GrantSigner,
    readonly endpointProvider: EndpointProvider,
  ) {}

  discovery(oidc: {
    issuer: string;
    authorization_endpoint: string;
    token_endpoint: string;
    device_authorization_endpoint?: string;
  }): Record<string, unknown> {
    return {
      contract_version: CONTRACT_VERSION,
      issuer: this.config.issuer,
      api_base_url: this.config.publicBaseUrl,
      oidc: {
        issuer: oidc.issuer,
        authorization_endpoint: oidc.authorization_endpoint,
        token_endpoint: oidc.token_endpoint,
        ...(oidc.device_authorization_endpoint === undefined
          ? {}
          : { device_authorization_endpoint: oidc.device_authorization_endpoint }),
        code_challenge_methods_supported: ["S256"],
        public_client: {
          client_id: this.config.oauthClient.clientId,
          scopes: this.config.oauthClient.scopes,
          redirect_uris: this.config.oauthClient.redirectUris,
          response_type: "code",
          token_endpoint_auth_method: "none",
        },
        headless_authorization:
          oidc.device_authorization_endpoint === undefined
            ? { supported: false }
            : {
                supported: true,
                grant_type: "urn:ietf:params:oauth:grant-type:device_code",
              },
      },
      jwks_uri: joinUrl(this.config.publicBaseUrl, "/v1/.well-known/jwks.json"),
      signer_metadata_url: joinUrl(this.config.publicBaseUrl, "/v1/signer-metadata"),
      capabilities: [
        "runtime-link-proof-ed25519",
        "inventory-v1",
        "bootstrap-grant-eddsa",
        "connector-credential-jwe-x25519",
        this.endpointProvider.kind === "external" ? "endpoint-external" : "endpoint-noop-test",
        ...(this.config.operatorToken === null ? [] : ["audit-export-v1"]),
      ],
    };
  }

  signerMetadata(): Record<string, unknown> {
    return {
      contract_version: CONTRACT_VERSION,
      issuer: this.config.issuer,
      jwks_uri: joinUrl(this.config.publicBaseUrl, "/v1/.well-known/jwks.json"),
      algorithms: ["EdDSA"],
      maximum_grant_lifetime_seconds: this.config.grantLifetimeSeconds,
    };
  }

  async createChallenge(
    principal: Principal,
    raw: unknown,
    correlationId: string,
  ): Promise<{ body: unknown; status: number }> {
    validateSchema<ChallengeRequest>("challengeRequest", raw);
    const now = new Date();
    const thumbprint = await runtimeKeyThumbprint(raw.runtime_signing_jwk);
    const encryptionThumbprint = await encryptionKeyThumbprint(raw.runtime_encryption_jwk);
    const nonce = randomNonce();
    const record = {
      challengeId: newId("chl"),
      requestId: raw.request_id,
      requestDigest: await stableDigest(raw),
      principal,
      runtimeId: raw.runtime_id,
      instanceId: raw.instance_id,
      runtimeSigningJwk: raw.runtime_signing_jwk,
      runtimeKeyThumbprint: thumbprint,
      runtimeEncryptionJwk: raw.runtime_encryption_jwk,
      runtimeEncryptionKeyThumbprint: encryptionThumbprint,
      nonce,
      nonceHash: await sha256Base64Url(nonce),
      audience: this.config.issuer,
      expiresAt: new Date(now.getTime() + this.config.challengeLifetimeSeconds * 1_000),
      createdAt: now,
      consumedAt: null,
      proofDigest: null,
      linkId: null,
    };
    const result = await this.store.issueChallenge(
      record,
      this.makeAudit({
        eventType: "link.challenge_issued",
        outcome: "success",
        actor: principal,
        correlationId,
        requestId: record.requestId,
        runtimeId: record.runtimeId,
        instanceId: record.instanceId,
      }),
    );
    return { body: challengeWire(result.record), status: result.created ? 201 : 200 };
  }

  async createLink(
    principal: Principal,
    raw: unknown,
    correlationId: string,
  ): Promise<{ body: unknown; status: number }> {
    validateSchema<ProofRequest>("proofRequest", raw);
    const challenge = await this.store.getChallenge(raw.challenge_id, principal);
    if (challenge === null) unavailableChallenge();
    const proofDigest = await sha256Base64Url(raw.proof_jwt);
    if (challenge.consumedAt === null) {
      try {
        await verifyRuntimeLinkProof(raw.proof_jwt, challenge, new Date());
      } catch (error) {
        await this.audit({
          eventType: "link.challenge_rejected",
          outcome: "rejected",
          actor: principal,
          correlationId,
          requestId: challenge.requestId,
          runtimeId: challenge.runtimeId,
          instanceId: challenge.instanceId,
          reasonCode: "runtime_proof_invalid",
        });
        throw error;
      }
    } else if (challenge.proofDigest !== proofDigest) {
      unavailableChallenge();
    }
    const linkId = challenge.linkId ?? newId("lnk");
    const result = await this.store.consumeChallengeAndCreateLink({
      challengeId: challenge.challengeId,
      principal,
      proofDigest,
      linkId,
      now: new Date(),
      audit: this.makeAudit({
        eventType: "link.created",
        outcome: "success",
        actor: principal,
        correlationId,
        requestId: challenge.requestId,
        runtimeId: challenge.runtimeId,
        instanceId: challenge.instanceId,
        linkId,
      }),
    });
    return { body: linkWire(result.record), status: result.created ? 201 : 200 };
  }

  async enrollEndpoint(
    principal: Principal,
    linkId: string,
    raw: unknown,
    correlationId: string,
    signal: AbortSignal,
  ): Promise<EnrollmentWireResult> {
    validateSchema<EnrollmentRequest>("endpointEnrollmentRequest", raw);
    if (raw.provider !== this.endpointProvider.kind) {
      throw new ApiError(
        400,
        "endpoint_provider_disabled",
        "Requested endpoint provider is not enabled",
      );
    }
    const link = await this.store.getLink(linkId, principal);
    if (link === null || link.status !== "linked")
      notFound("link_not_found", "Runtime link was not found");
    const now = new Date();
    const proofExpiresAt = boundedProofExpiry(raw.expires_at, now);
    const unsignedDigest = await stableDigest(withoutField(raw, "runtime_proof_jwt"));
    try {
      await verifyEndpointEnrollmentProof({
        compactJwt: raw.runtime_proof_jwt,
        linkId,
        runtimeId: link.runtimeId,
        instanceId: link.instanceId,
        runtimeSigningJwk: link.runtimeSigningJwk,
        runtimeKeyThumbprint: link.runtimeKeyThumbprint,
        requestId: raw.request_id,
        requestDigest: unsignedDigest,
        controlPlaneAudience: this.config.issuer,
        requestExpiresAt: proofExpiresAt,
        now,
      });
    } catch (error) {
      await this.audit({
        eventType: "endpoint.enrollment_rejected",
        outcome: "rejected",
        actor: principal,
        correlationId,
        requestId: raw.request_id,
        runtimeId: link.runtimeId,
        instanceId: link.instanceId,
        linkId,
        reasonCode: "runtime_proof_invalid",
      });
      throw error;
    }
    const requestDigest = await stableDigest(raw);
    const enrollmentId = newId("enr");
    const reservation = await this.store.reserveEndpointEnrollment(
      {
        enrollmentId,
        requestId: raw.request_id,
        requestDigest,
        linkId,
        principal,
        provider: raw.provider,
        descriptor: null,
        status: "pending",
        secretVerifier: null,
        secretExpiresAt: null,
        createdAt: now,
        activatedAt: null,
        revokedAt: null,
      },
      this.makeAudit({
        eventType: "endpoint.enrollment_reserved",
        outcome: "success",
        actor: principal,
        correlationId,
        requestId: raw.request_id,
        runtimeId: link.runtimeId,
        instanceId: link.instanceId,
        linkId,
        enrollmentId,
      }),
    );
    if (reservation.record.status === "revoked") {
      conflict("enrollment_unavailable", "Endpoint enrollment is unavailable");
    }
    const providerResult = await this.endpointProvider.enroll(
      {
        enrollmentId: reservation.record.enrollmentId,
        requestId: raw.request_id,
        requestDigest,
        link,
        requestedDescriptor: raw.external_descriptor ?? null,
        now: reservation.record.createdAt,
      },
      this.config.enrollmentLifetimeSeconds,
      signal,
    );
    try {
      await validateProviderResult(
        providerResult,
        reservation.record,
        this.config.enrollmentLifetimeSeconds,
        link.runtimeId,
        link.instanceId,
      );
    } catch (error) {
      providerResult.connectorSecret?.destroy();
      throw error;
    }
    if (reservation.record.status === "active") {
      return enrollmentResult(200, reservation.record, providerResult.connectorSecret, link);
    }
    let secretVerifier: string | null = null;
    if (providerResult.connectorSecret !== null) {
      secretVerifier = await providerResult.connectorSecret.verifier();
    }
    let active;
    try {
      active = await this.store.activateEndpointEnrollment({
        enrollmentId: reservation.record.enrollmentId,
        principal,
        descriptor: providerResult.descriptor,
        secretVerifier,
        secretExpiresAt: providerResult.connectorSecretExpiresAt,
        now: new Date(),
        audit: this.makeAudit({
          eventType: "endpoint.enrolled",
          outcome: "success",
          actor: principal,
          correlationId,
          requestId: raw.request_id,
          runtimeId: link.runtimeId,
          instanceId: link.instanceId,
          linkId,
          enrollmentId: reservation.record.enrollmentId,
        }),
      });
    } catch (error) {
      providerResult.connectorSecret?.destroy();
      throw error;
    }
    return enrollmentResult(201, active, providerResult.connectorSecret, link);
  }

  async inventory(principal: Principal, raw: unknown): Promise<unknown> {
    validateSchema<InventoryRequest>("inventoryRequest", raw);
    const records = await this.store.queryInventory(principal, raw.runtime_ids ?? null);
    return {
      contract_version: CONTRACT_VERSION,
      request_id: raw.request_id,
      runtimes: records.map((record) => ({
        link_id: record.linkId,
        status: "ready",
        descriptor: record.descriptor,
        linked_at: record.createdAt.toISOString(),
      })),
    };
  }

  async bootstrap(
    principal: Principal,
    raw: unknown,
    correlationId: string,
  ): Promise<{ body: unknown; status: number }> {
    validateSchema<BootstrapRequest>("bootstrapRequest", raw);
    const now = new Date();
    const requestedExpiry = new Date(raw.expires_at);
    if (
      !Number.isFinite(requestedExpiry.getTime()) ||
      requestedExpiry.getTime() <= now.getTime() + 5_000 ||
      requestedExpiry.getTime() > now.getTime() + 300_000
    ) {
      throw new ApiError(
        400,
        "invalid_expiry",
        "expires_at must be 5 through 300 seconds in the future",
      );
    }
    const audience = validateEndpointUrl(raw.audience, "https:", "bootstrap audience").origin;
    if (audience !== raw.audience) {
      throw new ApiError(400, "invalid_audience", "Bootstrap audience must be an HTTPS origin");
    }
    const links = await this.store.queryInventory(principal, [raw.runtime_id]);
    const link = links.find(
      (candidate) =>
        candidate.runtimeId === raw.runtime_id && candidate.instanceId === raw.instance_id,
    );
    if (link?.descriptor === null || link === undefined) {
      notFound("runtime_not_found", "Linked runtime was not found");
    }
    if (new URL(link.descriptor.https_url).origin !== audience) {
      throw new ApiError(
        400,
        "invalid_audience",
        "Bootstrap audience does not match the runtime endpoint",
      );
    }
    const deviceKeyThumbprint = await runtimeKeyThumbprint(raw.device_signing_jwk);
    const unsignedDigest = await stableDigest(withoutField(raw, "device_proof_jwt"));
    try {
      await verifyDeviceBootstrapProof({
        compactJwt: raw.device_proof_jwt,
        deviceId: raw.device_id,
        deviceSigningJwk: raw.device_signing_jwk,
        deviceKeyThumbprint,
        principal,
        requestId: raw.request_id,
        requestDigest: unsignedDigest,
        controlPlaneAudience: this.config.issuer,
        requestExpiresAt: requestedExpiry,
        now,
      });
    } catch (error) {
      await this.audit({
        eventType: "bootstrap.rejected",
        outcome: "rejected",
        actor: principal,
        correlationId,
        requestId: raw.request_id,
        runtimeId: raw.runtime_id,
        instanceId: raw.instance_id,
        deviceId: raw.device_id,
        linkId: link.linkId,
        reasonCode: "device_proof_invalid",
      });
      throw error;
    }
    const issuedAtSeconds = Math.floor(now.getTime() / 1_000);
    const expiresAtSeconds = Math.min(
      issuedAtSeconds + this.config.grantLifetimeSeconds,
      Math.floor(requestedExpiry.getTime() / 1_000),
    );
    const record: BootstrapRecord = {
      grantId: newId("grt"),
      requestId: raw.request_id,
      requestDigest: await stableDigest(raw),
      linkId: link.linkId,
      principal,
      runtimeId: raw.runtime_id,
      instanceId: raw.instance_id,
      deviceId: raw.device_id,
      deviceKeyThumbprint,
      deviceSigningJwk: raw.device_signing_jwk,
      audience,
      clientNonce: raw.client_nonce,
      scopes: [...raw.scopes],
      issuedAtSeconds,
      expiresAtSeconds,
      createdAt: now,
    };
    const result = await this.store.reserveBootstrap(
      record,
      this.makeAudit({
        eventType: "bootstrap.issued",
        outcome: "success",
        actor: principal,
        correlationId,
        requestId: record.requestId,
        runtimeId: record.runtimeId,
        instanceId: record.instanceId,
        deviceId: record.deviceId,
        linkId: record.linkId,
        grantId: record.grantId,
      }),
    );
    const grantJwt = await this.signer.signBootstrap(this.config.issuer, result.record);
    return {
      status: result.created ? 201 : 200,
      body: {
        contract_version: CONTRACT_VERSION,
        request_id: result.record.requestId,
        grant_id: result.record.grantId,
        issuer: this.config.issuer,
        audience: result.record.audience,
        scopes: result.record.scopes,
        expires_at: new Date(result.record.expiresAtSeconds * 1_000).toISOString(),
        grant_jwt: grantJwt,
      },
    };
  }

  async unlink(
    principal: Principal,
    linkId: string,
    raw: unknown,
    correlationId: string,
  ): Promise<unknown> {
    validateSchema<UnlinkRequest>("unlinkRequest", raw);
    const record = await this.store.unlinkLink(
      linkId,
      principal,
      new Date(),
      this.makeAudit({
        eventType: "link.unlinked",
        outcome: "success",
        actor: principal,
        correlationId,
        requestId: raw.request_id,
        linkId,
      }),
    );
    if (record === null) notFound("link_not_found", "Runtime link was not found");
    return linkWire(record);
  }

  async revoke(principal: Principal, raw: unknown, correlationId: string): Promise<unknown> {
    validateSchema<RevocationRequest>("revocationRequest", raw);
    const result = await this.store.revoke({
      revocationId: newId("rev"),
      requestId: raw.request_id,
      requestDigest: await stableDigest(raw),
      principal,
      entityType: raw.entity_type,
      entityId: raw.entity_id,
      reason: raw.reason ?? null,
      now: new Date(),
      audit: this.makeAudit({
        eventType: "entity.revoked",
        outcome: "success",
        actor: principal,
        correlationId,
        requestId: raw.request_id,
        ...(raw.entity_type === "runtime_link" ? { linkId: raw.entity_id } : {}),
        ...(raw.entity_type === "endpoint_enrollment" ? { enrollmentId: raw.entity_id } : {}),
        ...(raw.entity_type === "device" ? { deviceId: raw.entity_id } : {}),
        reasonCode: raw.reason === undefined ? "operator_request" : "operator_reason",
      }),
    });
    if (result === null) notFound("entity_not_found", "Revocable entity was not found");
    return {
      contract_version: CONTRACT_VERSION,
      revocation_id: result.record.revocationId,
      entity_type: result.record.entityType,
      entity_id: result.record.entityId,
      revoked_at: result.record.revokedAt.toISOString(),
    };
  }

  async audit(event: Omit<AuditEvent, "eventId" | "occurredAt">): Promise<void> {
    await this.store.appendAudit(this.makeAudit(event));
  }

  private makeAudit(event: Omit<AuditEvent, "eventId" | "occurredAt">): AuditEvent {
    return { ...event, eventId: newId("evt"), occurredAt: new Date() };
  }
}

async function enrollmentResult(
  status: number,
  record: {
    enrollmentId: string;
    provider: "external" | "noop_test";
    descriptor: RuntimeDescriptor | null;
    createdAt: Date;
    secretExpiresAt: Date | null;
  },
  connectorSecret: SecretBytes | null,
  link: RuntimeLinkRecord,
): Promise<EnrollmentWireResult> {
  let encryptedCredential: string | null = null;
  if (connectorSecret !== null) {
    if (record.secretExpiresAt === null) {
      connectorSecret.destroy();
      throw new Error("connector credential expiry was not persisted");
    }
    const bytes = connectorSecret.copyForSealing();
    try {
      encryptedCredential = await sealConnectorCredential({
        secretBytes: bytes,
        runtimeEncryptionJwk: link.runtimeEncryptionJwk,
        enrollmentId: record.enrollmentId,
        expiresAt: record.secretExpiresAt,
      });
    } finally {
      bytes.fill(0);
      connectorSecret.destroy();
    }
  }
  return {
    status,
    body: {
      ...enrollmentWire(record),
      ...(encryptedCredential === null
        ? {}
        : {
            connector_enrollment: {
              encrypted_credential: encryptedCredential,
              expires_at: record.secretExpiresAt?.toISOString(),
              key_thumbprint: link.runtimeEncryptionKeyThumbprint,
              alg: "ECDH-ES",
              enc: "A256GCM",
            },
          }),
    },
  };
}

async function validateProviderResult(
  result: {
    provider: "external" | "noop_test";
    descriptor: RuntimeDescriptor;
    connectorSecret: SecretBytes | null;
    connectorSecretExpiresAt: Date | null;
  },
  reservation: {
    provider: "external" | "noop_test";
    descriptor: RuntimeDescriptor | null;
    secretVerifier: string | null;
    secretExpiresAt: Date | null;
    createdAt: Date;
  },
  lifetimeSeconds: number,
  runtimeId: string,
  instanceId: string,
): Promise<void> {
  try {
    validateSchema<RuntimeDescriptor>("runtimeDescriptor", result.descriptor);
    validateDescriptor(result.descriptor, runtimeId, instanceId);
  } catch {
    result.connectorSecret?.destroy();
    throw new ApiError(
      503,
      "endpoint_provider_invalid",
      "Endpoint provider returned an invalid descriptor",
    );
  }
  const hasSecret = result.connectorSecret !== null;
  const hasExpiry = result.connectorSecretExpiresAt !== null;
  const latestExpiry = reservation.createdAt.getTime() + lifetimeSeconds * 1_000;
  if (
    result.provider !== reservation.provider ||
    hasSecret !== hasExpiry ||
    (hasExpiry &&
      (!Number.isFinite(result.connectorSecretExpiresAt!.getTime()) ||
        result.connectorSecretExpiresAt!.getTime() <= reservation.createdAt.getTime() ||
        result.connectorSecretExpiresAt!.getTime() > latestExpiry))
  ) {
    result.connectorSecret?.destroy();
    throw new ApiError(
      503,
      "endpoint_provider_invalid",
      "Endpoint provider returned an invalid result",
    );
  }
  if (reservation.descriptor !== null) {
    const verifier =
      result.connectorSecret === null ? null : await result.connectorSecret.verifier();
    if (
      (await stableDigest(result.descriptor)) !== (await stableDigest(reservation.descriptor)) ||
      verifier !== reservation.secretVerifier ||
      result.connectorSecretExpiresAt?.getTime() !== reservation.secretExpiresAt?.getTime()
    ) {
      result.connectorSecret?.destroy();
      throw new ApiError(
        503,
        "endpoint_provider_inconsistent",
        "Endpoint provider did not reproduce the reserved enrollment",
      );
    }
  }
}

function enrollmentWire(record: {
  enrollmentId: string;
  provider: "external" | "noop_test";
  descriptor: RuntimeDescriptor | null;
  createdAt: Date;
}): Record<string, unknown> {
  if (record.descriptor === null) throw new Error("active endpoint enrollment lost descriptor");
  return {
    contract_version: CONTRACT_VERSION,
    enrollment_id: record.enrollmentId,
    provider: record.provider,
    descriptor: record.descriptor,
    created_at: record.createdAt.toISOString(),
  };
}

function challengeWire(record: {
  challengeId: string;
  audience: string;
  principal: Principal;
  nonce: string;
  expiresAt: Date;
}): unknown {
  return {
    contract_version: CONTRACT_VERSION,
    challenge_id: record.challengeId,
    audience: record.audience,
    principal: record.principal,
    nonce: record.nonce,
    expires_at: record.expiresAt.toISOString(),
  };
}

function linkWire(record: RuntimeLinkRecord): unknown {
  return {
    contract_version: CONTRACT_VERSION,
    link_id: record.linkId,
    runtime_id: record.runtimeId,
    instance_id: record.instanceId,
    runtime_key_thumbprint: record.runtimeKeyThumbprint,
    runtime_encryption_key_thumbprint: record.runtimeEncryptionKeyThumbprint,
    status: record.status,
    created_at: record.createdAt.toISOString(),
    ...(record.unlinkedAt === null ? {} : { unlinked_at: record.unlinkedAt.toISOString() }),
  };
}

function unavailableChallenge(): never {
  conflict("challenge_unavailable", "Link challenge is invalid, expired, or already consumed");
}

function withoutField<T extends object>(value: T, field: keyof T): Record<string, unknown> {
  const copy = { ...value } as Record<string, unknown>;
  delete copy[field as string];
  return copy;
}

function boundedProofExpiry(value: string, now: Date): Date {
  const expiresAt = new Date(value);
  if (
    !Number.isFinite(expiresAt.getTime()) ||
    expiresAt.getTime() <= now.getTime() + 5_000 ||
    expiresAt.getTime() > now.getTime() + 300_000
  ) {
    throw new ApiError(
      400,
      "invalid_expiry",
      "expires_at must be 5 through 300 seconds in the future",
    );
  }
  return expiresAt;
}
