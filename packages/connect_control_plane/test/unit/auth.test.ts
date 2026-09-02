import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { exportJWK, generateKeyPair, SignJWT } from "jose";

import { OidcAuthenticator } from "../../src/auth.ts";
import type { OidcAuthConfig } from "../../src/config.ts";

describe("OIDC JWT access-token profile", () => {
  let server: ReturnType<typeof Bun.serve>;
  let baseUrl = "";
  let privateKey: CryptoKey;
  let config: OidcAuthConfig;
  let reportedIssuer = "";
  let metadataContentType = "application/json";
  let jwksFetches = 0;
  let jwksDelayMs = 0;

  beforeAll(async () => {
    const pair = await generateKeyPair("EdDSA", { crv: "Ed25519", extractable: true });
    privateKey = pair.privateKey;
    const jwk = {
      ...(await exportJWK(pair.publicKey)),
      kid: "test-oidc-signing-key",
      use: "sig",
      alg: "EdDSA",
    };
    server = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      async fetch(request) {
        const path = new URL(request.url).pathname;
        if (path === "/.well-known/openid-configuration") {
          return new Response(
            JSON.stringify({
              issuer: reportedIssuer,
              authorization_endpoint: `${baseUrl}/authorize`,
              token_endpoint: `${baseUrl}/token`,
              jwks_uri: `${baseUrl}/jwks`,
              code_challenge_methods_supported: ["S256"],
            }),
            { headers: { "content-type": metadataContentType } },
          );
        }
        if (path === "/jwks") {
          jwksFetches += 1;
          if (jwksDelayMs > 0) await Bun.sleep(jwksDelayMs);
          return Response.json({ keys: [jwk] });
        }
        return new Response("not found", { status: 404 });
      },
    });
    baseUrl = `http://127.0.0.1:${server.port}`;
    reportedIssuer = baseUrl;
    config = {
      mode: "oidc",
      issuer: baseUrl,
      audience: "verde-connect",
      expectedJwksUri: `${baseUrl}/jwks`,
      algorithms: ["EdDSA"],
      metadataTimeoutMs: 1_000,
      jwksRefreshSeconds: 300,
      maximumTokenAgeSeconds: 300,
    };
  });

  afterAll(() => server.stop(true));

  test("accepts bounded at+jwt and rejects missing exp or wrong typ", async () => {
    const authenticator = await OidcAuthenticator.create(config, "test");
    const now = Math.floor(Date.now() / 1_000);
    const valid = await token({ typ: "at+jwt", iat: now, exp: now + 60 });
    await expect(authenticator.authenticate(`Bearer ${valid}`)).resolves.toEqual({
      issuer: baseUrl,
      subject: "user-1",
    });
    const missingExp = await token({ typ: "at+jwt", iat: now });
    await expect(authenticator.authenticate(`Bearer ${missingExp}`)).rejects.toMatchObject({
      status: 401,
    });
    const wrongTyp = await token({ typ: "JWT", iat: now, exp: now + 60 });
    await expect(authenticator.authenticate(`Bearer ${wrongTyp}`)).rejects.toMatchObject({
      status: 401,
    });
  });

  test("requires exact discovery issuer and JSON MIME", async () => {
    reportedIssuer = `${baseUrl}/`;
    await expect(OidcAuthenticator.create(config, "test")).rejects.toThrow("exactly match");
    reportedIssuer = baseUrl;
    metadataContentType = "text/plain";
    await expect(OidcAuthenticator.create(config, "test")).rejects.toThrow("JSON content type");
    metadataContentType = "application/json";
  });

  test("coalesces concurrent unknown-kid refresh", async () => {
    jwksFetches = 0;
    const authenticator = await OidcAuthenticator.create(config, "test");
    const unknownPair = await generateKeyPair("EdDSA", { crv: "Ed25519" });
    const now = Math.floor(Date.now() / 1_000);
    const unknown = await new SignJWT({})
      .setProtectedHeader({ alg: "EdDSA", kid: "unknown-signing-key", typ: "at+jwt" })
      .setIssuer(baseUrl)
      .setSubject("user-1")
      .setAudience("verde-connect")
      .setIssuedAt(now)
      .setExpirationTime(now + 60)
      .sign(unknownPair.privateKey);
    jwksDelayMs = 20;
    const results = await Promise.allSettled(
      Array.from({ length: 8 }, () => authenticator.authenticate(`Bearer ${unknown}`)),
    );
    jwksDelayMs = 0;
    expect(results.every((result) => result.status === "rejected")).toBeTrue();
    expect(jwksFetches).toBe(2);
    await expect(authenticator.authenticate(`Bearer ${unknown}`)).rejects.toMatchObject({
      status: 401,
    });
    expect(jwksFetches).toBe(2);
  });

  async function token(input: { typ: string; iat: number; exp?: number }): Promise<string> {
    let jwt = new SignJWT({})
      .setProtectedHeader({ alg: "EdDSA", kid: "test-oidc-signing-key", typ: input.typ })
      .setIssuer(baseUrl)
      .setSubject("user-1")
      .setAudience("verde-connect")
      .setIssuedAt(input.iat);
    if (input.exp !== undefined) jwt = jwt.setExpirationTime(input.exp);
    return jwt.sign(privateKey);
  }
});
