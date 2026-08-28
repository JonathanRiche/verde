import {
  calculateJwkThumbprint,
  CompactEncrypt,
  decodeProtectedHeader,
  importJWK,
  jwtVerify,
  SignJWT,
  type JWK,
} from "jose";

import { ApiError } from "./errors.ts";
import type {
  BootstrapClaims,
  LinkChallengeRecord,
  Principal,
  PublicEncryptionJwk,
  PublicSigningJwk,
} from "./types.ts";

export class GrantSigner {
  readonly #privateKey: CryptoKey;
  readonly #publicJwk: PublicSigningJwk;
  readonly #previousJwks: { jwk: PublicSigningJwk; retainUntil: Date }[];

  private constructor(
    privateKey: CryptoKey,
    publicJwk: PublicSigningJwk,
    previousJwks: { jwk: PublicSigningJwk; retainUntil: Date }[],
  ) {
    this.#privateKey = privateKey;
    this.#publicJwk = publicJwk;
    this.#previousJwks = previousJwks.map((entry) => structuredClone(entry));
  }

  static async create(
    privateJwk: JWK & { d: string; kid: string },
    previousJwks: { jwk: PublicSigningJwk; retainUntil: Date }[] = [],
  ): Promise<GrantSigner> {
    const privateKey = await importJWK(privateJwk, "EdDSA");
    if (privateKey instanceof Uint8Array) throw new Error("grant signing key must be asymmetric");
    const publicJwk: PublicSigningJwk = {
      kty: "OKP",
      crv: "Ed25519",
      x: privateJwk.x!,
      kid: privateJwk.kid,
      use: "sig",
      alg: "EdDSA",
    };
    return new GrantSigner(privateKey, publicJwk, previousJwks);
  }

  publicJwks(): { keys: PublicSigningJwk[] } {
    const now = Date.now();
    return {
      keys: [
        { ...this.#publicJwk },
        ...this.#previousJwks
          .filter((entry) => entry.retainUntil.getTime() > now)
          .map((entry) => ({ ...entry.jwk })),
      ],
    };
  }

  keyId(): string {
    return this.#publicJwk.kid;
  }

  async signBootstrap(issuer: string, claims: BootstrapClaims): Promise<string> {
    return new SignJWT({
      contract_version: "1",
      principal: claims.principal,
      link_id: claims.linkId,
      runtime_id: claims.runtimeId,
      instance_id: claims.instanceId,
      device_id: claims.deviceId,
      device_key_thumbprint: claims.deviceKeyThumbprint,
      client_nonce: claims.clientNonce,
      request_id: claims.requestId,
      scopes: claims.scopes,
    })
      .setProtectedHeader({
        alg: "EdDSA",
        kid: this.#publicJwk.kid,
        typ: "verde-connect-bootstrap+jwt",
      })
      .setIssuer(issuer)
      .setSubject(`${claims.principal.issuer}\u0000${claims.principal.subject}`)
      .setAudience(claims.audience)
      .setJti(claims.grantId)
      .setIssuedAt(claims.issuedAtSeconds)
      .setNotBefore(claims.issuedAtSeconds)
      .setExpirationTime(claims.expiresAtSeconds)
      .sign(this.#privateKey);
  }
}

export async function runtimeKeyThumbprint(jwk: PublicSigningJwk): Promise<string> {
  return calculateJwkThumbprint(jwk, "sha256");
}

export async function encryptionKeyThumbprint(jwk: PublicEncryptionJwk): Promise<string> {
  return calculateJwkThumbprint(jwk, "sha256");
}

export async function sealConnectorCredential(input: {
  secretBytes: Uint8Array;
  runtimeEncryptionJwk: PublicEncryptionJwk;
  enrollmentId: string;
  expiresAt: Date;
}): Promise<string> {
  const key = await importJWK(input.runtimeEncryptionJwk, "ECDH-ES");
  return new CompactEncrypt(input.secretBytes)
    .setProtectedHeader({
      alg: "ECDH-ES",
      enc: "A256GCM",
      typ: "verde-connect-credential+jwe",
      kid: input.runtimeEncryptionJwk.kid,
      enrollment_id: input.enrollmentId,
      expires_at: input.expiresAt.toISOString(),
    })
    .encrypt(key);
}

export async function verifyDeviceBootstrapProof(input: {
  compactJwt: string;
  deviceId: string;
  deviceSigningJwk: PublicSigningJwk;
  deviceKeyThumbprint: string;
  principal: Principal;
  requestId: string;
  requestDigest: string;
  controlPlaneAudience: string;
  requestExpiresAt: Date;
  now: Date;
}): Promise<void> {
  await verifyPossessionProof({
    compactJwt: input.compactJwt,
    publicJwk: input.deviceSigningJwk,
    typ: "verde-connect-device-proof+jwt",
    issuer: `urn:verde:connect-device:${input.deviceId}`,
    subject: input.deviceId,
    audience: input.controlPlaneAudience,
    jti: input.requestId,
    expiresAt: input.requestExpiresAt,
    now: input.now,
    customClaims: {
      contract_version: "1",
      request_id: input.requestId,
      request_digest: input.requestDigest,
      device_id: input.deviceId,
      device_key_thumbprint: input.deviceKeyThumbprint,
      principal: input.principal,
    },
  });
}

export async function verifyEndpointEnrollmentProof(input: {
  compactJwt: string;
  linkId: string;
  runtimeId: string;
  instanceId: string;
  runtimeSigningJwk: PublicSigningJwk;
  runtimeKeyThumbprint: string;
  requestId: string;
  requestDigest: string;
  controlPlaneAudience: string;
  requestExpiresAt: Date;
  now: Date;
}): Promise<void> {
  await verifyPossessionProof({
    compactJwt: input.compactJwt,
    publicJwk: input.runtimeSigningJwk,
    typ: "verde-endpoint-enrollment+jwt",
    issuer: `urn:verde:runtime:${input.runtimeId}`,
    subject: input.runtimeId,
    audience: input.controlPlaneAudience,
    jti: input.requestId,
    expiresAt: input.requestExpiresAt,
    now: input.now,
    customClaims: {
      contract_version: "1",
      link_id: input.linkId,
      request_id: input.requestId,
      request_digest: input.requestDigest,
      runtime_id: input.runtimeId,
      instance_id: input.instanceId,
      runtime_key_thumbprint: input.runtimeKeyThumbprint,
    },
  });
}

export async function verifyRuntimeLinkProof(
  compactJwt: string,
  challenge: LinkChallengeRecord,
  now: Date,
): Promise<void> {
  const protectedHeader = decodeProtectedHeader(compactJwt);
  if (
    !exactKeys(protectedHeader, ["alg", "kid", "typ"]) ||
    protectedHeader.alg !== "EdDSA" ||
    protectedHeader.typ !== "verde-runtime-link+jwt" ||
    protectedHeader.kid !== challenge.runtimeSigningJwk.kid
  ) {
    throw invalidProof();
  }
  const key = await importJWK(challenge.runtimeSigningJwk, "EdDSA");
  const verified = await jwtVerify(compactJwt, key, {
    algorithms: ["EdDSA"],
    issuer: `urn:verde:runtime:${challenge.runtimeId}`,
    subject: challenge.runtimeId,
    audience: challenge.audience,
    currentDate: now,
    clockTolerance: 0,
  }).catch(() => {
    throw invalidProof();
  });
  const payload = verified.payload;
  if (
    !exactKeys(payload, [
      "aud",
      "challenge_id",
      "contract_version",
      "exp",
      "iat",
      "instance_id",
      "iss",
      "jti",
      "nbf",
      "nonce",
      "principal",
      "runtime_id",
      "runtime_encryption_key_thumbprint",
      "runtime_key_thumbprint",
      "sub",
    ]) ||
    payload.aud !== challenge.audience ||
    payload.iss !== `urn:verde:runtime:${challenge.runtimeId}` ||
    payload.sub !== challenge.runtimeId
  ) {
    throw invalidProof();
  }
  const expected: Record<string, unknown> = {
    contract_version: "1",
    challenge_id: challenge.challengeId,
    principal: challenge.principal,
    runtime_id: challenge.runtimeId,
    instance_id: challenge.instanceId,
    runtime_key_thumbprint: challenge.runtimeKeyThumbprint,
    runtime_encryption_key_thumbprint: challenge.runtimeEncryptionKeyThumbprint,
    nonce: challenge.nonce,
  };
  for (const [keyName, expectedValue] of Object.entries(expected)) {
    if (!deepEqual(payload[keyName], expectedValue)) throw invalidProof();
  }
  if (payload.jti !== challenge.challengeId) throw invalidProof();
  if (
    !isSafeNumericDate(payload.exp) ||
    payload.exp * 1_000 > challenge.expiresAt.getTime() ||
    !isSafeNumericDate(payload.iat) ||
    !isSafeNumericDate(payload.nbf) ||
    payload.nbf !== payload.iat ||
    payload.exp <= payload.iat ||
    payload.iat * 1_000 < challenge.createdAt.getTime() - 1_000 ||
    payload.iat * 1_000 > now.getTime() + 1_000
  ) {
    throw invalidProof();
  }
}

function exactKeys(value: object, expected: string[]): boolean {
  const actual = Object.keys(value).sort();
  const sortedExpected = [...expected].sort();
  return (
    actual.length === sortedExpected.length &&
    actual.every((key, index) => key === sortedExpected[index])
  );
}

export function assertPrincipalClaim(value: unknown, expected: Principal): void {
  if (!deepEqual(value, expected)) throw invalidProof();
}

async function verifyPossessionProof(input: {
  compactJwt: string;
  publicJwk: PublicSigningJwk;
  typ: string;
  issuer: string;
  subject: string;
  audience: string;
  jti: string;
  expiresAt: Date;
  now: Date;
  customClaims: Record<string, unknown>;
}): Promise<void> {
  try {
    const header = decodeProtectedHeader(input.compactJwt);
    if (
      !exactKeys(header, ["alg", "kid", "typ"]) ||
      header.alg !== "EdDSA" ||
      header.typ !== input.typ ||
      header.kid !== input.publicJwk.kid
    ) {
      throw invalidPossessionProof();
    }
    const key = await importJWK(input.publicJwk, "EdDSA");
    const verified = await jwtVerify(input.compactJwt, key, {
      algorithms: ["EdDSA"],
      issuer: input.issuer,
      subject: input.subject,
      audience: input.audience,
      currentDate: input.now,
      clockTolerance: 0,
    });
    const payload = verified.payload;
    const expectedKeys = [
      "aud",
      "exp",
      "iat",
      "iss",
      "jti",
      "nbf",
      "sub",
      ...Object.keys(input.customClaims),
    ];
    if (
      !exactKeys(payload, expectedKeys) ||
      payload.aud !== input.audience ||
      payload.iss !== input.issuer ||
      payload.sub !== input.subject ||
      payload.jti !== input.jti ||
      !isSafeNumericDate(payload.iat) ||
      !isSafeNumericDate(payload.nbf) ||
      payload.nbf !== payload.iat ||
      payload.iat * 1_000 > input.now.getTime() + 1_000 ||
      !isSafeNumericDate(payload.exp) ||
      payload.exp <= payload.iat ||
      payload.exp - payload.iat > 300 ||
      payload.exp * 1_000 > input.expiresAt.getTime()
    ) {
      throw invalidPossessionProof();
    }
    for (const [name, expected] of Object.entries(input.customClaims)) {
      if (!deepEqual(payload[name], expected)) throw invalidPossessionProof();
    }
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw invalidPossessionProof();
  }
}

function isSafeNumericDate(value: unknown): value is number {
  if (typeof value !== "number") return false;
  return Number.isSafeInteger(value) && value >= 0 && Number.isSafeInteger(value * 1_000);
}

function deepEqual(left: unknown, right: unknown): boolean {
  if (left === right) return true;
  if (left === null || right === null || typeof left !== "object" || typeof right !== "object") {
    return false;
  }
  if (Array.isArray(left) || Array.isArray(right)) {
    if (!Array.isArray(left) || !Array.isArray(right) || left.length !== right.length) return false;
    return left.every((value, index) => deepEqual(value, right[index]));
  }
  const leftRecord = left as Record<string, unknown>;
  const rightRecord = right as Record<string, unknown>;
  const leftKeys = Object.keys(leftRecord).sort();
  const rightKeys = Object.keys(rightRecord).sort();
  return (
    leftKeys.length === rightKeys.length &&
    leftKeys.every(
      (key, index) => key === rightKeys[index] && deepEqual(leftRecord[key], rightRecord[key]),
    )
  );
}

function invalidProof(): ApiError {
  return new ApiError(409, "runtime_proof_invalid", "Runtime link proof is invalid or expired");
}

function invalidPossessionProof(): ApiError {
  return new ApiError(
    409,
    "possession_proof_invalid",
    "Required proof of possession is invalid or expired",
  );
}
