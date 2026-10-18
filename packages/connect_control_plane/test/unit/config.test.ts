import { describe, expect, test } from "bun:test";

import { validateOidcUrl } from "../../src/config.ts";

describe("exact URL validation", () => {
  test("rejects normalization-prone or ambiguous configured URLs", () => {
    expect(() => validateOidcUrl(" https://id.example.test", "production", "issuer")).toThrow();
    expect(() => validateOidcUrl("https://user@id.example.test", "production", "issuer")).toThrow();
    expect(() =>
      validateOidcUrl("https://id.example.test?tenant=a", "production", "issuer"),
    ).toThrow();
    expect(() =>
      validateOidcUrl("https://id.example.test#fragment", "production", "issuer"),
    ).toThrow();
  });

});
