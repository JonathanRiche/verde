import { describe, expect, test } from "bun:test";

import { resolveClientKey } from "../../src/app.ts";

describe("request boundary", () => {
  test("trusts one forwarded IP only from an exact configured proxy", () => {
    const request = new Request("https://connect.test", {
      headers: { "x-forwarded-for": "203.0.113.7" },
    });
    expect(resolveClientKey(request, "10.0.0.2", ["10.0.0.2"])).toBe("203.0.113.7");
    expect(resolveClientKey(request, "10.0.0.3", ["10.0.0.2"])).toBe("10.0.0.3");
    expect(() =>
      resolveClientKey(
        new Request("https://connect.test", {
          headers: { "x-forwarded-for": "203.0.113.7, 10.0.0.1" },
        }),
        "10.0.0.2",
        ["10.0.0.2"],
      ),
    ).toThrow();
  });

});
