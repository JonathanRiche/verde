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

  test("preserves exact trailing slash and explicit default port strings for issuer comparison", () => {
    expect(validateOidcUrl("https://id.example.test/", "production", "issuer").href).toBe(
      "https://id.example.test/",
    );
    // URL parsing normalizes the object, but auth retains and compares the original configured string.
    expect(() =>
      validateOidcUrl("https://id.example.test:443", "production", "issuer"),
    ).not.toThrow();
  });
});
