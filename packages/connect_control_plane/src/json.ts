import { parse } from "lossless-json";
import secureJsonParse from "secure-json-parse";

import { ApiError } from "./errors.ts";

export const MAX_REQUEST_BODY_BYTES = 64 * 1024;
export const MAX_REQUEST_HEADER_BYTES = 16 * 1024;
export const MAX_OUTBOUND_JSON_BYTES = 512 * 1024;

export function parseStrictJson(text: string): unknown {
  try {
    const safeValue: unknown = secureJsonParse(text, {
      protoAction: "error",
      constructorAction: "error",
    });
    assertNoDuplicateKeys(text);
    parse(text, null, {
      parseNumber: (value) => {
        const parsed = Number(value);
        if (!Number.isFinite(parsed)) {
          throw new SyntaxError("JSON number is outside the finite number range");
        }
        return parsed;
      },
      onDuplicateKey: ({ key }) => {
        throw new SyntaxError(`duplicate JSON key: ${key}`);
      },
    });
    return safeValue;
  } catch {
    throw new ApiError(
      400,
      "invalid_json",
      "Request body must be valid JSON without duplicate keys",
    );
  }
}

function assertNoDuplicateKeys(text: string): void {
  let index = 0;
  const skipWhitespace = (): void => {
    while (index < text.length && /[\u0009\u000a\u000d\u0020]/.test(text[index]!)) index += 1;
  };
  const parseString = (): string => {
    const start = index;
    index += 1;
    while (index < text.length) {
      if (text[index] === "\\") {
        index += text[index + 1] === "u" ? 6 : 2;
      } else if (text[index] === '"') {
        index += 1;
        return JSON.parse(text.slice(start, index)) as string;
      } else {
        index += 1;
      }
    }
    throw new SyntaxError("unterminated JSON string");
  };
  const parseValue = (): void => {
    skipWhitespace();
    if (text[index] === "{") {
      index += 1;
      skipWhitespace();
      const keys = new Set<string>();
      if (text[index] === "}") {
        index += 1;
        return;
      }
      while (true) {
        skipWhitespace();
        if (text[index] !== '"') throw new SyntaxError("invalid JSON object key");
        const key = parseString();
        if (keys.has(key)) throw new SyntaxError(`duplicate JSON key: ${key}`);
        keys.add(key);
        skipWhitespace();
        if (text[index] !== ":") throw new SyntaxError("invalid JSON object separator");
        index += 1;
        parseValue();
        skipWhitespace();
        if (text[index] === "}") {
          index += 1;
          return;
        }
        if (text[index] !== ",") throw new SyntaxError("invalid JSON object delimiter");
        index += 1;
      }
    }
    if (text[index] === "[") {
      index += 1;
      skipWhitespace();
      if (text[index] === "]") {
        index += 1;
        return;
      }
      while (true) {
        parseValue();
        skipWhitespace();
        if (text[index] === "]") {
          index += 1;
          return;
        }
        if (text[index] !== ",") throw new SyntaxError("invalid JSON array delimiter");
        index += 1;
      }
    }
    if (text[index] === '"') {
      parseString();
      return;
    }
    while (index < text.length && !/[\s,\]}]/.test(text[index]!)) index += 1;
  };
  parseValue();
  skipWhitespace();
  if (index !== text.length) throw new SyntaxError("trailing JSON data");
}

export async function readJsonBody(request: Request): Promise<unknown> {
  const contentType = request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase();
  if (contentType !== "application/json") {
    throw new ApiError(415, "unsupported_media_type", "Content-Type must be application/json");
  }

  const declaredLength = request.headers.get("content-length");
  if (declaredLength !== null) {
    const length = Number(declaredLength);
    if (!Number.isSafeInteger(length) || length < 0 || length > MAX_REQUEST_BODY_BYTES) {
      throw new ApiError(413, "request_too_large", "Request body exceeds the 64 KiB limit");
    }
  }

  const bytes = await readBoundedStream(request.body, MAX_REQUEST_BODY_BYTES);
  try {
    return parseStrictJson(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(400, "invalid_json", "Request body must be UTF-8 JSON");
  } finally {
    bytes.fill(0);
  }
}

export function validateHeaderBudget(headers: Headers): void {
  let total = 0;
  for (const [name, value] of headers) {
    total += name.length + value.length + 4;
  }
  if (total > MAX_REQUEST_HEADER_BYTES) {
    throw new ApiError(431, "headers_too_large", "Request headers exceed the 16 KiB limit");
  }
}

export async function boundedJsonFetch(
  url: string,
  timeoutMs: number,
  init?: RequestInit,
): Promise<unknown> {
  const signal = AbortSignal.timeout(timeoutMs);
  const response = await fetch(url, {
    ...init,
    redirect: "error",
    signal,
    headers: {
      accept: "application/json",
      "user-agent": "verde-connect-control-plane/0.1",
      ...init?.headers,
    },
  });
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error(`outbound metadata request returned HTTP ${response.status}`);
  }
  let headerBytes = 0;
  for (const [name, value] of response.headers) headerBytes += name.length + value.length + 4;
  if (headerBytes > MAX_REQUEST_HEADER_BYTES) {
    await response.body?.cancel();
    throw new Error("outbound metadata response headers exceed 16 KiB");
  }
  const contentType = response.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase();
  if (contentType !== "application/json" && contentType !== "application/jwk-set+json") {
    await response.body?.cancel();
    throw new Error("outbound metadata response must use a JSON content type");
  }
  const bytes = await readBoundedStream(response.body, MAX_OUTBOUND_JSON_BYTES);
  try {
    return parseStrictJson(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } finally {
    bytes.fill(0);
  }
}

async function readBoundedStream(
  stream: ReadableStream<Uint8Array> | null,
  maximumBytes: number,
): Promise<Uint8Array> {
  if (stream === null) return new Uint8Array();
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const result = await reader.read();
      if (result.done) break;
      total += result.value.byteLength;
      if (total > maximumBytes) {
        throw new ApiError(413, "response_too_large", `JSON payload exceeds ${maximumBytes} bytes`);
      }
      chunks.push(result.value);
    }
    const output = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      output.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return output;
  } finally {
    await reader.cancel().catch(() => undefined);
  }
}
