import {
  createLocalJWKSet,
  decodeProtectedHeader,
  errors as joseErrors,
  jwtVerify,
  type JSONWebKeySet,
} from "jose";
import { timingSafeEqual } from "node:crypto";

import {
  type Environment,
  type OidcAuthConfig,
  type TestAuthConfig,
  validateOidcUrl,
} from "./config.ts";
import { ApiError } from "./errors.ts";
import { boundedJsonFetch } from "./json.ts";
import type { OidcMetadata, Principal } from "./types.ts";

export interface Authenticator {
  readonly metadata: OidcMetadata;
  authenticate(authorizationHeader: string | null): Promise<Principal>;
  ready(): boolean;
}

export class OidcAuthenticator implements Authenticator {
  readonly metadata: OidcMetadata;
  readonly #config: OidcAuthConfig;
  readonly #environment: Environment;
  #keySet: ReturnType<typeof createLocalJWKSet>;
  #keySetRefreshedAt: number;
  #refreshPromise: Promise<void> | null = null;
  #unknownKidRefreshAttemptedAt = 0;

  private constructor(
    config: OidcAuthConfig,
    environment: Environment,
    metadata: OidcMetadata,
    jwks: JSONWebKeySet,
  ) {
    this.#config = config;
    this.#environment = environment;
    this.metadata = metadata;
    this.#keySet = createLocalJWKSet(jwks);
    this.#keySetRefreshedAt = Date.now();
  }

  static async create(
    config: OidcAuthConfig,
    environment: Environment,
  ): Promise<OidcAuthenticator> {
    const metadata = await fetchAndValidateMetadata(config, environment);
    const jwks = await fetchAndValidateJwks(metadata.jwks_uri, config, environment);
    return new OidcAuthenticator(config, environment, metadata, jwks);
  }

  ready(): boolean {
    return true;
  }

  async authenticate(authorizationHeader: string | null): Promise<Principal> {
    const token = bearerToken(authorizationHeader);
    if (Date.now() - this.#keySetRefreshedAt > this.#config.jwksRefreshSeconds * 1_000) {
      await this.refreshKeys();
    }
    try {
      return await this.verify(token);
    } catch (error) {
      if (error instanceof joseErrors.JWKSNoMatchingKey) {
        await this.refreshKeysForUnknownKid();
        try {
          return await this.verify(token);
        } catch {
          throw unauthorized();
        }
      }
      throw unauthorized();
    }
  }

  private async verify(token: string): Promise<Principal> {
    const header = decodeProtectedHeader(token);
    if (
      header.typ !== "at+jwt" ||
      typeof header.kid !== "string" ||
      !/^[A-Za-z0-9._~-]{1,128}$/.test(header.kid) ||
      typeof header.alg !== "string" ||
      !this.#config.algorithms.includes(header.alg as "RS256" | "ES256" | "EdDSA")
    ) {
      throw unauthorized();
    }
    const verified = await jwtVerify(token, this.#keySet, {
      algorithms: [...this.#config.algorithms],
      issuer: this.#config.issuer,
      audience: this.#config.audience,
      clockTolerance: 0,
    });
    const now = Math.floor(Date.now() / 1_000);
    if (
      !Number.isSafeInteger(verified.payload.iat) ||
      !Number.isSafeInteger(verified.payload.exp) ||
      verified.payload.iat! > now + 1 ||
      verified.payload.exp! <= verified.payload.iat! ||
      verified.payload.exp! - verified.payload.iat! > this.#config.maximumTokenAgeSeconds ||
      now - verified.payload.iat! > this.#config.maximumTokenAgeSeconds ||
      verified.payload.iss !== this.#config.issuer ||
      verified.payload.aud !== this.#config.audience ||
      (verified.payload.nbf !== undefined && !Number.isSafeInteger(verified.payload.nbf))
    ) {
      throw unauthorized();
    }
    if (
      typeof verified.payload.sub !== "string" ||
      !/^[^\u0000-\u001f\u007f]{1,255}$/u.test(verified.payload.sub) ||
      new TextEncoder().encode(verified.payload.sub).byteLength > 1_020
    ) {
      throw unauthorized();
    }
    // The issuer returned here was already checked byte-for-byte by jose.
    return { issuer: this.#config.issuer, subject: verified.payload.sub };
  }

  private async refreshKeys(): Promise<void> {
    if (this.#refreshPromise !== null) return this.#refreshPromise;
    this.#refreshPromise = (async () => {
      const jwks = await fetchAndValidateJwks(
        this.metadata.jwks_uri,
        this.#config,
        this.#environment,
      );
      this.#keySet = createLocalJWKSet(jwks);
      this.#keySetRefreshedAt = Date.now();
    })();
    try {
      await this.#refreshPromise;
    } finally {
      this.#refreshPromise = null;
    }
  }

  private async refreshKeysForUnknownKid(): Promise<void> {
    if (this.#refreshPromise !== null) return this.#refreshPromise;
    const now = Date.now();
    const cooldownMs = Math.min(30_000, this.#config.jwksRefreshSeconds * 1_000);
    if (now - this.#unknownKidRefreshAttemptedAt < cooldownMs) return;
    // Set before I/O so repeated failures cannot amplify outbound JWKS traffic.
    this.#unknownKidRefreshAttemptedAt = now;
    await this.refreshKeys();
  }
}

export class TestAuthenticator implements Authenticator {
  readonly metadata: OidcMetadata;

  constructor(readonly config: TestAuthConfig) {
    this.metadata = {
      issuer: config.principalIssuer,
      authorization_endpoint: `${config.principalIssuer.replace(/\/$/, "")}/authorize`,
      token_endpoint: `${config.principalIssuer.replace(/\/$/, "")}/token`,
      jwks_uri: `${config.principalIssuer.replace(/\/$/, "")}/jwks.json`,
      code_challenge_methods_supported: ["S256"],
      id_token_signing_alg_values_supported: ["EdDSA"],
    };
  }

  ready(): boolean {
    return true;
  }

  async authenticate(authorizationHeader: string | null): Promise<Principal> {
    const token = bearerToken(authorizationHeader);
    if (!constantTimeEqual(token, this.config.token)) throw unauthorized();
    return { issuer: this.config.principalIssuer, subject: this.config.principalSubject };
  }
}

export function authenticateOperator(
  authorizationHeader: string | null,
  configuredToken: string | null,
): void {
  if (configuredToken === null) {
    throw new ApiError(404, "operator_export_disabled", "Operator audit export is disabled");
  }
  const token = bearerToken(authorizationHeader);
  if (!constantTimeEqual(token, configuredToken)) throw unauthorized();
}

async function fetchAndValidateMetadata(
  config: OidcAuthConfig,
  environment: Environment,
): Promise<OidcMetadata> {
  const metadataUrl = `${config.issuer.endsWith("/") ? config.issuer.slice(0, -1) : config.issuer}/.well-known/openid-configuration`;
  validateOidcUrl(metadataUrl, environment, "OIDC metadata URL");
  const raw = await boundedJsonFetch(metadataUrl, config.metadataTimeoutMs);
  const metadata = objectRecord(raw, "OIDC metadata");
  if (metadata.issuer !== config.issuer) {
    throw new Error("OIDC discovery issuer does not exactly match VERDE_OIDC_ISSUER");
  }
  const authorizationEndpoint = stringField(metadata, "authorization_endpoint");
  const tokenEndpoint = stringField(metadata, "token_endpoint");
  const jwksUri = stringField(metadata, "jwks_uri");
  validateOidcUrl(authorizationEndpoint, environment, "OIDC authorization_endpoint");
  validateOidcUrl(tokenEndpoint, environment, "OIDC token_endpoint");
  validateOidcUrl(jwksUri, environment, "OIDC jwks_uri");
  if (config.expectedJwksUri !== null && jwksUri !== config.expectedJwksUri) {
    throw new Error("OIDC discovery jwks_uri does not exactly match VERDE_OIDC_JWKS_URI");
  }
  const methods = stringArray(metadata.code_challenge_methods_supported);
  if (!methods.includes("S256")) throw new Error("OIDC provider must advertise PKCE S256");

  let deviceAuthorizationEndpoint: string | undefined;
  if (metadata.device_authorization_endpoint !== undefined) {
    deviceAuthorizationEndpoint = stringField(metadata, "device_authorization_endpoint");
    validateOidcUrl(deviceAuthorizationEndpoint, environment, "OIDC device_authorization_endpoint");
  }

  return {
    issuer: config.issuer,
    authorization_endpoint: authorizationEndpoint,
    token_endpoint: tokenEndpoint,
    jwks_uri: jwksUri,
    ...(deviceAuthorizationEndpoint === undefined
      ? {}
      : { device_authorization_endpoint: deviceAuthorizationEndpoint }),
    code_challenge_methods_supported: ["S256"],
    id_token_signing_alg_values_supported: stringArray(
      metadata.id_token_signing_alg_values_supported,
    ),
  };
}

async function fetchAndValidateJwks(
  url: string,
  config: OidcAuthConfig,
  environment: Environment,
): Promise<JSONWebKeySet> {
  validateOidcUrl(url, environment, "OIDC jwks_uri");
  const raw = objectRecord(await boundedJsonFetch(url, config.metadataTimeoutMs), "OIDC JWKS");
  if (!Array.isArray(raw.keys) || raw.keys.length === 0 || raw.keys.length > 64) {
    throw new Error("OIDC JWKS must contain 1 through 64 keys");
  }
  for (const key of raw.keys) {
    const record = objectRecord(key, "OIDC JWK");
    if ("d" in record || typeof record.kty !== "string") {
      throw new Error("OIDC JWKS must contain public keys only");
    }
  }
  return { keys: raw.keys as JSONWebKeySet["keys"] };
}

function bearerToken(header: string | null): string {
  const match = header?.match(/^Bearer ([A-Za-z0-9._~-]+)$/);
  if (match?.[1] === undefined || match[1].length > 16_384) throw unauthorized();
  return match[1];
}

function constantTimeEqual(left: string, right: string): boolean {
  const leftBytes = new TextEncoder().encode(left);
  const rightBytes = new TextEncoder().encode(right);
  const size = Math.max(leftBytes.length, rightBytes.length, 1);
  const paddedLeft = new Uint8Array(size);
  const paddedRight = new Uint8Array(size);
  paddedLeft.set(leftBytes);
  paddedRight.set(rightBytes);
  const same = timingSafeEqual(paddedLeft, paddedRight) && leftBytes.length === rightBytes.length;
  paddedLeft.fill(0);
  paddedRight.fill(0);
  leftBytes.fill(0);
  rightBytes.fill(0);
  return same;
}

function unauthorized(): ApiError {
  return new ApiError(401, "authentication_failed", "Bearer authentication failed");
}

function objectRecord(value: unknown, name: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${name} must be a JSON object`);
  }
  return value as Record<string, unknown>;
}

function stringField(record: Record<string, unknown>, field: string): string {
  const value = record[field];
  if (typeof value !== "string" || value.length === 0 || value.length > 2_048) {
    throw new Error(`OIDC metadata ${field} must be a bounded string`);
  }
  return value;
}

function stringArray(value: unknown): string[] {
  if (value === undefined) return [];
  if (
    !Array.isArray(value) ||
    value.length > 64 ||
    value.some((item) => typeof item !== "string")
  ) {
    throw new Error("OIDC metadata string array is invalid");
  }
  return value as string[];
}
