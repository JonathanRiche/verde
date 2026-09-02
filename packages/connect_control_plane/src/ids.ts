import canonicalize from "canonicalize";

const HEX = "0123456789abcdef";

function randomHex(bytes: number): string {
  const input = crypto.getRandomValues(new Uint8Array(bytes));
  let output = "";
  for (const value of input) {
    output += HEX[value >>> 4]! + HEX[value & 0x0f]!;
  }
  input.fill(0);
  return output;
}

export function newId(
  prefix: "req" | "chl" | "lnk" | "grt" | "enr" | "rev" | "evt" | "cor",
): string {
  return `${prefix}_${randomHex(16)}`;
}

export function randomNonce(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  try {
    return Buffer.from(bytes).toString("base64url");
  } finally {
    bytes.fill(0);
  }
}

export async function sha256Base64Url(value: string | Uint8Array): Promise<string> {
  let bytes: Uint8Array<ArrayBuffer>;
  if (typeof value === "string") {
    bytes = new TextEncoder().encode(value);
  } else {
    bytes = new Uint8Array(value.byteLength);
    bytes.set(value);
  }
  try {
    const digest = await crypto.subtle.digest("SHA-256", bytes);
    return Buffer.from(digest).toString("base64url");
  } finally {
    bytes.fill(0);
  }
}

export async function stableDigest(value: unknown): Promise<string> {
  const canonical = canonicalize(value);
  if (canonical === undefined) throw new Error("value cannot be represented as RFC 8785 JSON");
  return sha256Base64Url(canonical);
}
