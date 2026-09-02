import { validateEndpointUrl } from "./config.ts";
import { ApiError } from "./errors.ts";
import { sha256Base64Url } from "./ids.ts";
import { SecretBytes } from "./secrets.ts";
import type { EndpointEnrollmentInput } from "./store.ts";
import { CONTRACT_VERSION, type RuntimeDescriptor } from "./types.ts";

export interface EndpointEnrollmentResult {
  provider: "external" | "noop_test";
  descriptor: RuntimeDescriptor;
  connectorSecret: SecretBytes | null;
  connectorSecretExpiresAt: Date | null;
}

export interface EndpointProvider {
  readonly kind: EndpointEnrollmentResult["provider"];
  enroll(
    input: EndpointEnrollmentInput,
    enrollmentLifetimeSeconds: number,
    signal: AbortSignal,
  ): Promise<EndpointEnrollmentResult>;
  removeLink(linkId: string, signal: AbortSignal): Promise<void>;
  removeEnrollment(enrollmentId: string, signal: AbortSignal): Promise<void>;
  reconcileLink(linkId: string, activeEnrollmentId: string, signal: AbortSignal): Promise<void>;
  ready(): Promise<void>;
}

/** Registers an HTTPS/WSS endpoint managed entirely by the self-hosting operator. */
export class ExternalEndpointProvider implements EndpointProvider {
  readonly kind = "external" as const;

  async enroll(
    input: EndpointEnrollmentInput,
    _enrollmentLifetimeSeconds: number,
    _signal: AbortSignal,
  ): Promise<EndpointEnrollmentResult> {
    if (input.requestedDescriptor === null) {
      throw new ApiError(
        400,
        "descriptor_required",
        "external endpoint enrollment requires external_descriptor",
      );
    }
    validateDescriptor(input.requestedDescriptor, input.link.runtimeId, input.link.instanceId);
    return {
      provider: this.kind,
      descriptor: structuredClone(input.requestedDescriptor),
      connectorSecret: null,
      connectorSecretExpiresAt: null,
    };
  }

  async removeLink(_linkId: string, _signal: AbortSignal): Promise<void> {}
  async removeEnrollment(_enrollmentId: string, _signal: AbortSignal): Promise<void> {}
  async reconcileLink(
    _linkId: string,
    _activeEnrollmentId: string,
    _signal: AbortSignal,
  ): Promise<void> {}
  async ready(): Promise<void> {}
}

/** Hermetic adapter for tests. It never contacts or provisions external infrastructure. */
export class NoopTestEndpointProvider implements EndpointProvider {
  readonly kind = "noop_test" as const;
  readonly #derivationKey = crypto.getRandomValues(new Uint8Array(32));

  async enroll(
    input: EndpointEnrollmentInput,
    enrollmentLifetimeSeconds: number,
    _signal: AbortSignal,
  ): Promise<EndpointEnrollmentResult> {
    const hostname = `${input.link.runtimeId}.noop.connect.invalid`;
    const descriptor: RuntimeDescriptor = {
      contract_version: CONTRACT_VERSION,
      runtime_id: input.link.runtimeId,
      instance_id: input.link.instanceId,
      https_url: `https://${hostname}`,
      wss_url: `wss://${hostname}/v1/ws`,
      tls_identity: {
        kind: "spki_sha256",
        sha256: await sha256Base64Url(`noop-spki:${input.link.runtimeId}:${input.link.instanceId}`),
      },
      protocol: { major: 1, minor: 0 },
      capabilities: ["noop-test-endpoint"],
    };
    const key = await crypto.subtle.importKey(
      "raw",
      this.#derivationKey,
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const signature = new Uint8Array(
      await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(input.enrollmentId)),
    );
    const connectorSecret = SecretBytes.copy(signature);
    signature.fill(0);
    return {
      provider: this.kind,
      descriptor,
      connectorSecret,
      connectorSecretExpiresAt: new Date(input.now.getTime() + enrollmentLifetimeSeconds * 1_000),
    };
  }

  async removeLink(_linkId: string, _signal: AbortSignal): Promise<void> {}
  async removeEnrollment(_enrollmentId: string, _signal: AbortSignal): Promise<void> {}
  async reconcileLink(
    _linkId: string,
    _activeEnrollmentId: string,
    _signal: AbortSignal,
  ): Promise<void> {}
  async ready(): Promise<void> {}
}

export function validateDescriptor(
  descriptor: RuntimeDescriptor,
  runtimeId: string,
  instanceId: string,
): void {
  if (descriptor.runtime_id !== runtimeId || descriptor.instance_id !== instanceId) {
    throw new ApiError(
      400,
      "descriptor_identity_mismatch",
      "Endpoint descriptor identity does not match the linked runtime",
    );
  }
  const https = validateEndpointUrl(descriptor.https_url, "https:", "descriptor https_url");
  const wss = validateEndpointUrl(descriptor.wss_url, "wss:", "descriptor wss_url");
  if (https.origin.replace(/^https:/, "wss:") !== wss.origin) {
    throw new ApiError(
      400,
      "descriptor_origin_mismatch",
      "HTTPS and WSS descriptor endpoints must use the same origin",
    );
  }
}
