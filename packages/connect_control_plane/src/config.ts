import type { JWK } from "jose";
import { constants } from "node:fs";
import { lstat, open } from "node:fs/promises";
import { isIP } from "node:net";

import { parseStrictJson } from "./json.ts";
import type { PublicSigningJwk } from "./types.ts";

export type Environment = "production" | "development" | "test";

export interface OidcAuthConfig {
  mode: "oidc";
  issuer: string;
  audience: string;
  expectedJwksUri: string | null;
  algorithms: readonly ("RS256" | "ES256" | "EdDSA")[];
  metadataTimeoutMs: number;
  jwksRefreshSeconds: number;
  maximumTokenAgeSeconds: number;
}

export interface TestAuthConfig {
  mode: "test";
  token: string;
  principalIssuer: string;
  principalSubject: string;
}

export interface Config {
  environment: Environment;
  listenHost: string;
  port: number;
  publicBaseUrl: string;
  issuer: string;
  databaseUrl: string;
  auth: OidcAuthConfig | TestAuthConfig;
  signerPrivateJwk: JWK & { d: string; kid: string };
  signerPreviousJwks: { jwk: PublicSigningJwk; retainUntil: Date }[];
  endpointAdapter: "external" | "noop_test";
  operatorToken: string | null;
  challengeLifetimeSeconds: number;
  grantLifetimeSeconds: number;
  enrollmentLifetimeSeconds: number;
  requestDeadlineMs: number;
  oauthClient: {
    clientId: string;
    scopes: string[];
    redirectUris: string[];
  };
  trustedProxyIps: string[];
}

export async function loadConfig(
  environmentVariables: Readonly<Record<string, string | undefined>> = process.env,
): Promise<Config> {
  const environment = enumValue(environmentVariables, "VERDE_ENV", [
    "production",
    "development",
    "test",
  ] as const);
  const listenHost = optional(environmentVariables, "VERDE_LISTEN_HOST", "127.0.0.1");
  const port = integer(environmentVariables, "VERDE_PORT", 8787, 1, 65_535);
  const publicBaseUrl = required(environmentVariables, "VERDE_PUBLIC_BASE_URL");
  const issuer = required(environmentVariables, "VERDE_CONTROL_PLANE_ISSUER");
  const databaseUrl = required(environmentVariables, "DATABASE_URL");

  validateServiceUrl(publicBaseUrl, environment, "VERDE_PUBLIC_BASE_URL");
  validateServiceUrl(issuer, environment, "VERDE_CONTROL_PLANE_ISSUER");
  validateDatabaseUrl(databaseUrl);

  const authMode = enumValue(environmentVariables, "VERDE_AUTH_MODE", ["oidc", "test"] as const);
  let auth: OidcAuthConfig | TestAuthConfig;
  if (authMode === "oidc") {
    const oidcIssuer = required(environmentVariables, "VERDE_OIDC_ISSUER");
    validateOidcUrl(oidcIssuer, environment, "VERDE_OIDC_ISSUER");
    const audience = required(environmentVariables, "VERDE_OIDC_AUDIENCE");
    validateBoundedText(audience, "VERDE_OIDC_AUDIENCE", 512);
    const expectedJwksUri = environmentVariables.VERDE_OIDC_JWKS_URI ?? null;
    if (environment === "production" && expectedJwksUri === null) {
      throw new Error("VERDE_OIDC_JWKS_URI is required in production to pin OIDC key egress");
    }
    if (expectedJwksUri !== null) {
      validateOidcUrl(expectedJwksUri, environment, "VERDE_OIDC_JWKS_URI");
    }
    auth = {
      mode: "oidc",
      issuer: oidcIssuer,
      audience,
      expectedJwksUri,
      algorithms: algorithmList(environmentVariables.VERDE_OIDC_JWT_ALGORITHMS),
      metadataTimeoutMs: integer(
        environmentVariables,
        "VERDE_OIDC_METADATA_TIMEOUT_MS",
        5_000,
        250,
        15_000,
      ),
      jwksRefreshSeconds: integer(
        environmentVariables,
        "VERDE_OIDC_JWKS_REFRESH_SECONDS",
        300,
        30,
        3_600,
      ),
      maximumTokenAgeSeconds: integer(
        environmentVariables,
        "VERDE_OIDC_MAX_TOKEN_AGE_SECONDS",
        900,
        30,
        3_600,
      ),
    };
  } else {
    if (environment !== "test") {
      throw new Error("VERDE_AUTH_MODE=test is permitted only when VERDE_ENV=test");
    }
    const token = required(environmentVariables, "VERDE_TEST_AUTH_TOKEN");
    requireSecretLength(token, "VERDE_TEST_AUTH_TOKEN");
    const principalIssuer = required(environmentVariables, "VERDE_TEST_PRINCIPAL_ISSUER");
    validateOidcUrl(principalIssuer, environment, "VERDE_TEST_PRINCIPAL_ISSUER");
    const principalSubject = required(environmentVariables, "VERDE_TEST_PRINCIPAL_SUBJECT");
    validateBoundedText(principalSubject, "VERDE_TEST_PRINCIPAL_SUBJECT", 255);
    auth = {
      mode: "test",
      token,
      principalIssuer,
      principalSubject,
    };
  }

  const signerPrivateJwk = await loadSignerJwk(
    required(environmentVariables, "VERDE_GRANT_SIGNING_JWK_FILE"),
  );
  const signerPreviousJwks = await loadPreviousSignerJwks(
    environmentVariables.VERDE_GRANT_PREVIOUS_JWKS_FILE,
    signerPrivateJwk.kid,
  );
  const adapterValue = enumValue(environmentVariables, "VERDE_ENDPOINT_ADAPTER", [
    "external",
    "noop",
  ] as const);
  if (adapterValue === "noop" && environment !== "test") {
    throw new Error("VERDE_ENDPOINT_ADAPTER=noop is permitted only when VERDE_ENV=test");
  }
  const operatorToken = environmentVariables.VERDE_OPERATOR_TOKEN?.trim() || null;
  if (operatorToken !== null) requireSecretLength(operatorToken, "VERDE_OPERATOR_TOKEN");

  const oauthClient = {
    clientId: required(environmentVariables, "VERDE_OAUTH_PUBLIC_CLIENT_ID"),
    scopes: boundedCsv(
      environmentVariables,
      "VERDE_OAUTH_SCOPES",
      environment === "test" ? "openid,profile" : undefined,
      16,
      128,
    ),
    redirectUris: boundedCsv(
      environmentVariables,
      "VERDE_OAUTH_REDIRECT_URIS",
      environment === "test" ? "http://127.0.0.1:48123/callback" : undefined,
      16,
      2_048,
    ),
  };
  validateBoundedText(oauthClient.clientId, "VERDE_OAUTH_PUBLIC_CLIENT_ID", 255);
  for (const redirectUri of oauthClient.redirectUris) {
    validateOAuthRedirectUri(redirectUri);
  }
  const trustedProxyIps = boundedCsv(
    environmentVariables,
    "VERDE_TRUSTED_PROXY_IPS",
    "",
    32,
    64,
    true,
  );
  for (const address of trustedProxyIps) {
    if (isIP(address) === 0)
      throw new Error("VERDE_TRUSTED_PROXY_IPS must contain exact IP addresses");
  }

  return {
    environment,
    listenHost,
    port,
    publicBaseUrl,
    issuer,
    databaseUrl,
    auth,
    signerPrivateJwk,
    signerPreviousJwks,
    endpointAdapter: adapterValue === "noop" ? "noop_test" : "external",
    operatorToken,
    challengeLifetimeSeconds: integer(
      environmentVariables,
      "VERDE_CHALLENGE_LIFETIME_SECONDS",
      120,
      30,
      300,
    ),
    grantLifetimeSeconds: integer(
      environmentVariables,
      "VERDE_GRANT_LIFETIME_SECONDS",
      90,
      15,
      300,
    ),
    enrollmentLifetimeSeconds: integer(
      environmentVariables,
      "VERDE_ENROLLMENT_LIFETIME_SECONDS",
      300,
      30,
      900,
    ),
    requestDeadlineMs: integer(
      environmentVariables,
      "VERDE_REQUEST_DEADLINE_MS",
      10_000,
      500,
      30_000,
    ),
    oauthClient,
    trustedProxyIps,
  };
}

export function loadDatabaseUrl(
  environmentVariables: Readonly<Record<string, string | undefined>> = process.env,
): string {
  const databaseUrl = required(environmentVariables, "DATABASE_URL");
  validateDatabaseUrl(databaseUrl);
  return databaseUrl;
}

export function validateOidcUrl(value: string, environment: Environment, name: string): URL {
  const parsed = validateUrlShape(value, name);
  if (parsed.protocol === "https:") return parsed;
  if (environment === "test" && parsed.protocol === "http:" && isLoopback(parsed.hostname)) {
    return parsed;
  }
  throw new Error(`${name} must use HTTPS; HTTP loopback is allowed only in test mode`);
}

export function validateServiceUrl(value: string, environment: Environment, name: string): URL {
  return validateOidcUrl(value, environment, name);
}

export function validateEndpointUrl(value: string, protocol: "https:" | "wss:", name: string): URL {
  const parsed = validateUrlShape(value, name);
  if (parsed.protocol !== protocol) throw new Error(`${name} must use ${protocol.slice(0, -1)}`);
  return parsed;
}

export function joinUrl(base: string, path: string): string {
  if (!path.startsWith("/")) throw new Error("joined URL path must start with /");
  return `${base.endsWith("/") ? base.slice(0, -1) : base}${path}`;
}

function validateOAuthRedirectUri(value: string): void {
  const parsed = validateUrlShape(value, "OAuth redirect URI");
  if (parsed.protocol === "https:") return;
  if (parsed.protocol === "http:" && isLoopback(parsed.hostname)) return;
  throw new Error("OAuth redirect URIs must use HTTPS or an HTTP loopback address");
}

function validateUrlShape(value: string, name: string): URL {
  if (value !== value.trim()) throw new Error(`${name} must not contain surrounding whitespace`);
  if (!/^[\x21-\x7e]{1,2048}$/.test(value)) {
    throw new Error(`${name} must be 1 through 2048 ASCII bytes without controls`);
  }
  if (value.includes("?") || value.includes("#")) {
    throw new Error(`${name} must not contain a query string or fragment`);
  }
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error(`${name} must be an absolute URL`);
  }
  if (parsed.username !== "" || parsed.password !== "") {
    throw new Error(`${name} must not contain URL userinfo`);
  }
  if (parsed.hostname === "") throw new Error(`${name} must include a host`);
  return parsed;
}

function isLoopback(hostname: string): boolean {
  const lowered = hostname.toLowerCase();
  return lowered === "localhost" || lowered === "::1" || /^127(?:\.\d{1,3}){3}$/.test(lowered);
}

function validateDatabaseUrl(value: string): void {
  const parsed = new URL(value);
  if (parsed.protocol !== "postgres:" && parsed.protocol !== "postgresql:") {
    throw new Error("DATABASE_URL must use postgres:// or postgresql://");
  }
  if (parsed.hostname === "" || parsed.pathname.length <= 1) {
    throw new Error("DATABASE_URL must include a host and database name");
  }
}

async function loadSignerJwk(path: string): Promise<JWK & { d: string; kid: string }> {
  const pathStat = await lstat(path).catch(() => null);
  if (pathStat === null) throw new Error(`signing JWK file does not exist: ${path}`);
  if (!pathStat.isFile() || pathStat.isSymbolicLink()) {
    throw new Error("signing JWK path must be a regular file, not a symlink");
  }
  if (process.platform !== "win32" && (pathStat.mode & 0o077) !== 0) {
    throw new Error("signing JWK file must not be readable or writable by group/other");
  }
  const handle = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  let text: string;
  try {
    const openedStat = await handle.stat();
    if (!openedStat.isFile() || openedStat.size > 16 * 1024) {
      throw new Error("signing JWK must be a regular file no larger than 16 KiB");
    }
    if (process.platform !== "win32" && (openedStat.mode & 0o077) !== 0) {
      throw new Error("opened signing JWK file must not be accessible by group/other");
    }
    text = await handle.readFile({ encoding: "utf8" });
  } finally {
    await handle.close();
  }
  const parsed = parseStrictJson(text);
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("signing JWK must be a JSON object");
  }
  const jwk = parsed as Record<string, unknown>;
  const allowed = new Set(["kty", "crv", "x", "d", "kid", "use", "alg"]);
  for (const key of Object.keys(jwk)) {
    if (!allowed.has(key)) throw new Error(`signing JWK has unknown field: ${key}`);
  }
  if (
    jwk.kty !== "OKP" ||
    jwk.crv !== "Ed25519" ||
    typeof jwk.x !== "string" ||
    typeof jwk.d !== "string" ||
    typeof jwk.kid !== "string" ||
    !/^[A-Za-z0-9_-]{43}$/.test(jwk.x) ||
    !/^[A-Za-z0-9_-]{43}$/.test(jwk.d) ||
    !/^[A-Za-z0-9_-]{16,128}$/.test(jwk.kid) ||
    (jwk.use !== undefined && jwk.use !== "sig") ||
    (jwk.alg !== undefined && jwk.alg !== "EdDSA")
  ) {
    throw new Error("signing JWK must be a private Ed25519 key with canonical x, d, and kid");
  }
  return jwk as JWK & { d: string; kid: string };
}

async function loadPreviousSignerJwks(
  path: string | undefined,
  currentKid: string,
): Promise<{ jwk: PublicSigningJwk; retainUntil: Date }[]> {
  if (path === undefined || path === "") return [];
  const pathStat = await lstat(path).catch(() => null);
  if (pathStat === null || !pathStat.isFile() || pathStat.isSymbolicLink()) {
    throw new Error("previous signing JWKS path must be a regular file, not a symlink");
  }
  const handle = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  let text: string;
  try {
    const openedStat = await handle.stat();
    if (!openedStat.isFile() || openedStat.size > 64 * 1024) {
      throw new Error("previous signing JWKS file must be no larger than 64 KiB");
    }
    text = await handle.readFile({ encoding: "utf8" });
  } finally {
    await handle.close();
  }
  const parsed = parseStrictJson(text);
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("previous signing JWKS must be an object");
  }
  const root = parsed as Record<string, unknown>;
  if (!exactObjectKeys(root, ["keys"])) {
    throw new Error("previous signing JWKS must contain only keys");
  }
  const keys = root.keys;
  if (!Array.isArray(keys) || keys.length > 16) {
    throw new Error("previous signing JWKS must contain at most 16 entries");
  }
  const seen = new Set([currentKid]);
  const result: { jwk: PublicSigningJwk; retainUntil: Date }[] = [];
  for (const value of keys) {
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
      throw new Error("previous signing key entry must be an object");
    }
    const entry = value as Record<string, unknown>;
    if (!exactObjectKeys(entry, ["jwk", "retired_at"])) {
      throw new Error("previous signing key entry has unknown or missing fields");
    }
    const jwkValue = entry.jwk;
    if (jwkValue === null || typeof jwkValue !== "object" || Array.isArray(jwkValue)) {
      throw new Error("previous signing JWK must be an object");
    }
    const jwk = jwkValue as Record<string, unknown>;
    if (
      !exactObjectKeys(jwk, ["alg", "crv", "kid", "kty", "use", "x"]) ||
      jwk.kty !== "OKP" ||
      jwk.crv !== "Ed25519" ||
      jwk.use !== "sig" ||
      jwk.alg !== "EdDSA" ||
      typeof jwk.x !== "string" ||
      !/^[A-Za-z0-9_-]{43}$/.test(jwk.x) ||
      typeof jwk.kid !== "string" ||
      !/^[A-Za-z0-9_-]{16,128}$/.test(jwk.kid) ||
      seen.has(jwk.kid)
    ) {
      throw new Error("previous signing JWK must be a unique public Ed25519 verification key");
    }
    if (typeof entry.retired_at !== "string") throw new Error("retired_at must be a timestamp");
    const retiredAt = new Date(entry.retired_at);
    if (!Number.isFinite(retiredAt.getTime())) throw new Error("retired_at must be a timestamp");
    const retainUntil = new Date(retiredAt.getTime() + 300_000);
    if (retainUntil.getTime() <= Date.now()) {
      throw new Error("expired previous signing keys must be removed from the rotation bundle");
    }
    seen.add(jwk.kid);
    result.push({
      jwk: jwk as unknown as PublicSigningJwk,
      retainUntil,
    });
  }
  return result;
}

function exactObjectKeys(record: Record<string, unknown>, expected: string[]): boolean {
  const actual = Object.keys(record).sort();
  const wanted = [...expected].sort();
  return actual.length === wanted.length && actual.every((key, index) => key === wanted[index]);
}

function algorithmList(value: string | undefined): readonly ("RS256" | "ES256" | "EdDSA")[] {
  const entries = (value ?? "RS256").split(",").map((entry) => entry.trim());
  if (entries.length === 0 || new Set(entries).size !== entries.length) {
    throw new Error("VERDE_OIDC_JWT_ALGORITHMS must contain unique algorithms");
  }
  for (const entry of entries) {
    if (entry !== "RS256" && entry !== "ES256" && entry !== "EdDSA") {
      throw new Error(`unsupported OIDC JWT algorithm: ${entry}`);
    }
  }
  return entries as ("RS256" | "ES256" | "EdDSA")[];
}

function required(values: Readonly<Record<string, string | undefined>>, name: string): string {
  const value = values[name];
  if (value === undefined || value.trim() === "") throw new Error(`${name} is required`);
  return value;
}

function optional(
  values: Readonly<Record<string, string | undefined>>,
  name: string,
  fallback: string,
): string {
  const value = values[name];
  return value === undefined || value.trim() === "" ? fallback : value;
}

function integer(
  values: Readonly<Record<string, string | undefined>>,
  name: string,
  fallback: number,
  minimum: number,
  maximum: number,
): number {
  const raw = values[name];
  const value = raw === undefined || raw.trim() === "" ? fallback : Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer from ${minimum} through ${maximum}`);
  }
  return value;
}

function enumValue<const Values extends readonly string[]>(
  values: Readonly<Record<string, string | undefined>>,
  name: string,
  allowed: Values,
): Values[number] {
  const value = required(values, name);
  if (!allowed.includes(value)) throw new Error(`${name} must be one of: ${allowed.join(", ")}`);
  return value as Values[number];
}

function requireSecretLength(value: string, name: string): void {
  if (new TextEncoder().encode(value).byteLength < 32) {
    throw new Error(`${name} must contain at least 32 UTF-8 bytes`);
  }
}

function validateBoundedText(value: string, name: string, maximum: number): void {
  if (!new RegExp(`^[^\\u0000-\\u001f\\u007f]{1,${maximum}}$`, "u").test(value)) {
    throw new Error(`${name} must be 1 through ${maximum} characters without control characters`);
  }
}

function boundedCsv(
  values: Readonly<Record<string, string | undefined>>,
  name: string,
  fallback: string | undefined,
  maximumEntries: number,
  maximumEntryLength: number,
  allowEmpty = false,
): string[] {
  const raw = values[name] ?? fallback;
  if (raw === undefined) throw new Error(`${name} is required`);
  if (raw === "" && allowEmpty) return [];
  const entries = raw.split(",");
  if (
    entries.length === 0 ||
    entries.length > maximumEntries ||
    new Set(entries).size !== entries.length
  ) {
    throw new Error(`${name} must contain unique comma-separated values`);
  }
  for (const entry of entries) {
    if (entry !== entry.trim())
      throw new Error(`${name} entries must not contain surrounding whitespace`);
    validateBoundedText(entry, name, maximumEntryLength);
  }
  return entries;
}
