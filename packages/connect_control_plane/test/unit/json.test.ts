import { describe, expect, test } from "bun:test";

import {
  MAX_REQUEST_BODY_BYTES,
  parseStrictJson,
  readJsonBody,
  validateHeaderBudget,
} from "../../src/json.ts";

describe("strict JSON", () => {
  test("rejects identical and security-sensitive duplicate keys", () => {
    expect(() => parseStrictJson('{"a":1,"a":1}')).toThrow();
    expect(() => parseStrictJson('{"authorization":"a","authorization":"a"}')).toThrow();
  });

  test("rejects prototype-polluting keys recursively", () => {
    expect(() => parseStrictJson('{"nested":{"__proto__":{"admin":true}}}')).toThrow();
    expect(() => parseStrictJson('{"constructor":{"prototype":{"admin":true}}}')).toThrow();
  });

  test("rejects oversized and wrong-media request bodies", async () => {
    const oversized = new Request("https://connect.test/v1/x", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "x".repeat(MAX_REQUEST_BODY_BYTES + 1),
    });
    await expect(readJsonBody(oversized)).rejects.toMatchObject({ status: 413 });
    const wrongType = new Request("https://connect.test/v1/x", {
      method: "POST",
      headers: { "content-type": "text/plain" },
      body: "{}",
    });
    await expect(readJsonBody(wrongType)).rejects.toMatchObject({ status: 415 });
  });

  test("rejects a header set over 16 KiB", () => {
    expect(() => validateHeaderBudget(new Headers({ "x-large": "x".repeat(17_000) }))).toThrow();
  });
});
