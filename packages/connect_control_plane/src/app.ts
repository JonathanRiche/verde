import { authenticateOperator, type Authenticator } from "./auth.ts";
import { isIP } from "node:net";
import type { Config } from "./config.ts";
import { ApiError } from "./errors.ts";
import { newId } from "./ids.ts";
import { readJsonBody, validateHeaderBudget } from "./json.ts";
import { FixedWindowRateLimiter } from "./rate_limit.ts";
import type { EnrollmentWireResult, ConnectService } from "./service.ts";
import type { ControlPlaneStore } from "./store.ts";
import type { AuditEvent, Principal } from "./types.ts";

export interface ConnectApp {
  fetch(request: Request, clientKey?: string): Promise<Response>;
}

export function createConnectApp(
  config: Config,
  authenticator: Authenticator,
  service: ConnectService,
  store: ControlPlaneStore,
): ConnectApp {
  const unauthenticatedLimiter = new FixedWindowRateLimiter(120, 60_000);
  const challengeLimiter = new FixedWindowRateLimiter(10, 60_000);
  const mutationLimiter = new FixedWindowRateLimiter(60, 60_000);

  return {
    async fetch(request: Request, socketIp = "unknown"): Promise<Response> {
      const correlationId = newId("cor");
      const mutationSignal = AbortSignal.any([
        request.signal,
        AbortSignal.timeout(config.requestDeadlineMs),
      ]);
      try {
        validateHeaderBudget(request.headers);
        const clientKey = resolveClientKey(request, socketIp, config.trustedProxyIps);
        if (!unauthenticatedLimiter.allow(clientKey)) rateLimited();
        const url = new URL(request.url);
        const path = url.pathname;
        if (url.search !== "") {
          throw new ApiError(
            400,
            "query_not_allowed",
            "This endpoint does not accept query parameters",
          );
        }

        if (request.method === "GET" && path === "/healthz") {
          return jsonResponse({ ok: true }, 200, correlationId);
        }
        if (request.method === "GET" && path === "/readyz") {
          try {
            await withDeadline(
              Promise.all([store.health(), service.endpointProvider.ready()]),
              config.requestDeadlineMs,
            );
            if (!authenticator.ready()) throw new Error("authenticator is not ready");
            return jsonResponse({ ok: true }, 200, correlationId);
          } catch {
            return jsonResponse({ ok: false }, 503, correlationId);
          }
        }
        if (request.method === "GET" && path === "/.well-known/verde-connect-configuration") {
          return jsonResponse(service.discovery(authenticator.metadata), 200, correlationId, true);
        }
        if (request.method === "GET" && path === "/v1/signer-metadata") {
          return jsonResponse(service.signerMetadata(), 200, correlationId, true);
        }
        if (request.method === "GET" && path === "/v1/.well-known/jwks.json") {
          return jsonResponse(
            service.signer.publicJwks(),
            200,
            correlationId,
            true,
            "application/jwk-set+json",
          );
        }

        if (request.method === "POST" && path === "/v1/operator/audit-events/query") {
          authenticateOperator(request.headers.get("authorization"), config.operatorToken);
          const body = await readJsonBody(request);
          const query = auditQuery(body);
          const events = await withDeadline(
            store.queryAudit(query.afterEventId, query.limit),
            config.requestDeadlineMs,
          );
          return jsonResponse(
            {
              contract_version: "1",
              events: events.map(auditWire),
              next_after_event_id: events.at(-1)?.eventId ?? null,
            },
            200,
            correlationId,
          );
        }

        const principal = await withDeadline(
          authenticator.authenticate(request.headers.get("authorization")),
          config.requestDeadlineMs,
        );
        const principalKey = `${principal.issuer}\u0000${principal.subject}`;
        const body = await readJsonBody(request);

        if (request.method === "POST" && path === "/v1/runtime-links/challenges") {
          if (!challengeLimiter.allow(principalKey)) rateLimited();
          const result = await service.createChallenge(principal, body, correlationId);
          return jsonResponse(result.body, result.status, correlationId);
        }
        if (request.method === "POST" && path === "/v1/runtime-links") {
          if (!mutationLimiter.allow(principalKey)) rateLimited();
          const result = await service.createLink(principal, body, correlationId);
          return jsonResponse(result.body, result.status, correlationId);
        }
        if (request.method === "POST" && path === "/v1/runtime-inventory/query") {
          const response = await withDeadline(
            service.inventory(principal, body),
            config.requestDeadlineMs,
          );
          return jsonResponse(response, 200, correlationId);
        }
        if (request.method === "POST" && path === "/v1/connection-bootstraps") {
          if (!mutationLimiter.allow(principalKey)) rateLimited();
          const result = await service.bootstrap(principal, body, correlationId);
          return jsonResponse(result.body, result.status, correlationId);
        }
        if (request.method === "POST" && path === "/v1/revocations") {
          if (!mutationLimiter.allow(principalKey)) rateLimited();
          const response = await service.revoke(principal, body, correlationId);
          return jsonResponse(response, 200, correlationId);
        }

        const enrollmentMatch = path.match(
          /^\/v1\/runtime-links\/(lnk_[0-9a-f]{32})\/endpoint-enrollments$/,
        );
        if (request.method === "POST" && enrollmentMatch?.[1] !== undefined) {
          if (!mutationLimiter.allow(principalKey)) rateLimited();
          const result = await service.enrollEndpoint(
            principal,
            enrollmentMatch[1],
            body,
            correlationId,
            mutationSignal,
          );
          return enrollmentResponse(result, correlationId);
        }

        const unlinkMatch = path.match(/^\/v1\/runtime-links\/(lnk_[0-9a-f]{32})$/);
        if (request.method === "DELETE" && unlinkMatch?.[1] !== undefined) {
          if (!mutationLimiter.allow(principalKey)) rateLimited();
          const response = await service.unlink(principal, unlinkMatch[1], body, correlationId);
          return jsonResponse(response, 200, correlationId);
        }

        throw new ApiError(404, "not_found", "Endpoint was not found");
      } catch (error) {
        if (error instanceof ApiError) {
          if (error.status === 401) {
            await store
              .appendAudit({
                eventId: newId("evt"),
                eventType: "authentication.failed",
                outcome: "rejected",
                actor: { service: "control-plane" },
                correlationId,
                reasonCode: "bearer_authentication_failed",
                occurredAt: new Date(),
              })
              .catch(() => undefined);
          }
          return jsonResponse(
            {
              error: error.code,
              message: error.message,
              correlation_id: correlationId,
              ...(error.details === undefined ? {} : { details: error.details }),
            },
            error.status,
            correlationId,
          );
        }
        return jsonResponse(
          {
            error: "internal_error",
            message: "The control plane could not complete the request",
            correlation_id: correlationId,
          },
          500,
          correlationId,
        );
      }
    },
  };
}

export function resolveClientKey(
  request: Request,
  socketIp: string,
  trustedProxyIps: readonly string[],
): string {
  if (!trustedProxyIps.includes(socketIp)) return socketIp;
  const forwarded = request.headers.get("x-forwarded-for");
  if (
    forwarded === null ||
    forwarded !== forwarded.trim() ||
    forwarded.includes(",") ||
    isIP(forwarded) === 0
  ) {
    throw new ApiError(
      400,
      "invalid_forwarded_address",
      "Trusted proxy requests require one exact X-Forwarded-For IP address",
    );
  }
  return forwarded;
}

function enrollmentResponse(result: EnrollmentWireResult, correlationId: string): Response {
  return jsonResponse(result.body, result.status, correlationId);
}

function jsonResponse(
  body: unknown,
  status: number,
  correlationId: string,
  publiclyCacheable = false,
  contentType = "application/json",
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": `${contentType}; charset=utf-8`,
      "cache-control": publiclyCacheable ? "public, max-age=60" : "no-store",
      "x-content-type-options": "nosniff",
      "x-correlation-id": correlationId,
      "referrer-policy": "no-referrer",
    },
  });
}

async function withDeadline<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  let timeout: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_resolve, reject) => {
    timeout = setTimeout(
      () => reject(new ApiError(503, "request_deadline", "Request deadline was exceeded")),
      timeoutMs,
    );
  });
  try {
    return await Promise.race([promise, deadline]);
  } finally {
    if (timeout !== undefined) clearTimeout(timeout);
  }
}

function rateLimited(): never {
  throw new ApiError(429, "rate_limited", "Request rate limit was exceeded");
}

function auditQuery(value: unknown): { afterEventId: string | null; limit: number } {
  if (value === null || typeof value !== "object" || Array.isArray(value)) invalidAuditQuery();
  const record = value as Record<string, unknown>;
  const allowed = new Set(["contract_version", "after_event_id", "limit"]);
  if (Object.keys(record).some((key) => !allowed.has(key)) || record.contract_version !== "1") {
    invalidAuditQuery();
  }
  if (
    record.after_event_id !== undefined &&
    (typeof record.after_event_id !== "string" || !/^evt_[0-9a-f]{32}$/.test(record.after_event_id))
  ) {
    invalidAuditQuery();
  }
  const limit = record.limit ?? 100;
  if (!Number.isSafeInteger(limit) || (limit as number) < 1 || (limit as number) > 100) {
    invalidAuditQuery();
  }
  return {
    afterEventId: (record.after_event_id as string | undefined) ?? null,
    limit: limit as number,
  };
}

function invalidAuditQuery(): never {
  throw new ApiError(400, "invalid_request", "Audit query does not match the v1 schema");
}

function auditWire(event: AuditEvent): Record<string, unknown> {
  return {
    contract_version: "1",
    event_id: event.eventId,
    event_type: event.eventType,
    outcome: event.outcome,
    actor: event.actor,
    correlation_id: event.correlationId,
    ...(event.requestId === undefined ? {} : { request_id: event.requestId }),
    ...(event.runtimeId === undefined ? {} : { runtime_id: event.runtimeId }),
    ...(event.instanceId === undefined ? {} : { instance_id: event.instanceId }),
    ...(event.deviceId === undefined ? {} : { device_id: event.deviceId }),
    ...(event.linkId === undefined ? {} : { link_id: event.linkId }),
    ...(event.grantId === undefined ? {} : { grant_id: event.grantId }),
    ...(event.enrollmentId === undefined ? {} : { enrollment_id: event.enrollmentId }),
    ...(event.reasonCode === undefined ? {} : { reason_code: event.reasonCode }),
    occurred_at: event.occurredAt.toISOString(),
  };
}
