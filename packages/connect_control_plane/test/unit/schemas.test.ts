import { describe, expect, test } from "bun:test";
import { parse as parseYaml } from "yaml";

import { assertSchemasCompile, validateSchema } from "../../src/schemas.ts";

describe("published contract", () => {
  test("all runtime validators and OpenAPI document compile", async () => {
    expect(() => assertSchemasCompile()).not.toThrow();
    const source = await Bun.file(
      new URL("../../../../specs/control-plane/v1/openapi.yaml", import.meta.url),
    ).text();
    expect(parseYaml(source)).toMatchObject({ openapi: "3.1.0" });
  });

  test("runtime challenge requires distinct signing and encryption keys", () => {
    expect(() =>
      validateSchema("challengeRequest", {
        contract_version: "1",
        request_id: "req_22222222222222222222222222222222",
        runtime_id: "0123456789abcdef0123456789abcdef",
        instance_id: "abcdef0123456789abcdef0123456789",
        runtime_signing_jwk: {
          kty: "OKP",
          crv: "Ed25519",
          x: "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
          kid: "test-runtime-signing-v1",
        },
      }),
    ).toThrow();
  });
});
