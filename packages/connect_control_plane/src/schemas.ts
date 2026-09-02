import Ajv2020, { type ErrorObject, type ValidateFunction } from "ajv/dist/2020";
import addFormats from "ajv-formats";

import auditEventSchema from "../../../specs/control-plane/v1/schemas/audit-event.schema.json" with { type: "json" };
import bootstrapSchema from "../../../specs/control-plane/v1/schemas/bootstrap.schema.json" with { type: "json" };
import bootstrapGrantClaimsSchema from "../../../specs/control-plane/v1/schemas/bootstrap-grant-claims.schema.json" with { type: "json" };
import commonSchema from "../../../specs/control-plane/v1/schemas/common.schema.json" with { type: "json" };
import connectorCredentialJweSchema from "../../../specs/control-plane/v1/schemas/connector-credential-jwe.schema.json" with { type: "json" };
import discoverySchema from "../../../specs/control-plane/v1/schemas/discovery.schema.json" with { type: "json" };
import endpointEnrollmentSchema from "../../../specs/control-plane/v1/schemas/endpoint-enrollment.schema.json" with { type: "json" };
import inventorySchema from "../../../specs/control-plane/v1/schemas/inventory.schema.json" with { type: "json" };
import oidcPrincipalSchema from "../../../specs/control-plane/v1/schemas/oidc-principal.schema.json" with { type: "json" };
import proofClaimsSchema from "../../../specs/control-plane/v1/schemas/proof-claims.schema.json" with { type: "json" };
import revocationSchema from "../../../specs/control-plane/v1/schemas/revocation.schema.json" with { type: "json" };
import runtimeDescriptorSchema from "../../../specs/control-plane/v1/schemas/runtime-descriptor.schema.json" with { type: "json" };
import runtimeLinkSchema from "../../../specs/control-plane/v1/schemas/runtime-link.schema.json" with { type: "json" };
import signerDiscoverySchema from "../../../specs/control-plane/v1/schemas/signer-discovery.schema.json" with { type: "json" };

import { ApiError } from "./errors.ts";

const ajv = new Ajv2020({
  allErrors: true,
  strict: true,
  removeAdditional: false,
  coerceTypes: false,
  useDefaults: false,
  ownProperties: true,
});
addFormats(ajv);
for (const schema of [
  commonSchema,
  auditEventSchema,
  bootstrapSchema,
  bootstrapGrantClaimsSchema,
  discoverySchema,
  connectorCredentialJweSchema,
  endpointEnrollmentSchema,
  inventorySchema,
  oidcPrincipalSchema,
  proofClaimsSchema,
  revocationSchema,
  runtimeDescriptorSchema,
  runtimeLinkSchema,
  signerDiscoverySchema,
]) {
  ajv.addSchema(schema);
}

const validators = {
  challengeRequest: ajv.getSchema(`${runtimeLinkSchema.$id}#/$defs/challengeRequest`),
  challengeResponse: ajv.getSchema(`${runtimeLinkSchema.$id}#/$defs/challengeResponse`),
  proofRequest: ajv.getSchema(`${runtimeLinkSchema.$id}#/$defs/proofRequest`),
  link: ajv.getSchema(`${runtimeLinkSchema.$id}#/$defs/link`),
  unlinkRequest: ajv.getSchema(`${runtimeLinkSchema.$id}#/$defs/unlinkRequest`),
  inventoryRequest: ajv.getSchema(`${inventorySchema.$id}#/$defs/request`),
  inventoryResponse: ajv.getSchema(`${inventorySchema.$id}#/$defs/response`),
  bootstrapRequest: ajv.getSchema(`${bootstrapSchema.$id}#/$defs/request`),
  bootstrapResponse: ajv.getSchema(`${bootstrapSchema.$id}#/$defs/response`),
  revocationRequest: ajv.getSchema(`${revocationSchema.$id}#/$defs/request`),
  revocationResponse: ajv.getSchema(`${revocationSchema.$id}#/$defs/response`),
  endpointEnrollmentRequest: ajv.getSchema(`${endpointEnrollmentSchema.$id}#/$defs/request`),
  endpointEnrollmentResponse: ajv.getSchema(`${endpointEnrollmentSchema.$id}#/$defs/response`),
  runtimeDescriptor: ajv.getSchema(runtimeDescriptorSchema.$id),
  discovery: ajv.getSchema(discoverySchema.$id),
  signerDiscovery: ajv.getSchema(signerDiscoverySchema.$id),
  auditEvent: ajv.getSchema(auditEventSchema.$id),
  runtimeLinkProofClaims: ajv.getSchema(`${proofClaimsSchema.$id}#/$defs/runtimeLink`),
  endpointEnrollmentProofClaims: ajv.getSchema(
    `${proofClaimsSchema.$id}#/$defs/endpointEnrollment`,
  ),
  deviceBootstrapProofClaims: ajv.getSchema(`${proofClaimsSchema.$id}#/$defs/deviceBootstrap`),
  bootstrapGrantClaims: ajv.getSchema(bootstrapGrantClaimsSchema.$id),
  connectorCredentialJweHeader: ajv.getSchema(connectorCredentialJweSchema.$id),
} satisfies Record<string, ValidateFunction<unknown> | undefined>;

export type SchemaName = keyof typeof validators;

export function validateSchema<T>(name: SchemaName, value: unknown): asserts value is T {
  const validator = validators[name];
  if (validator === undefined) throw new Error(`validator was not compiled: ${name}`);
  if (!validator(value)) {
    throw new ApiError(
      400,
      "invalid_request",
      "Request does not match the Verde Connect v1 schema",
      {
        violations: formatErrors(validator.errors),
      },
    );
  }
}

export function assertSchemasCompile(): void {
  for (const [name, validator] of Object.entries(validators)) {
    if (validator === undefined) throw new Error(`validator was not compiled: ${name}`);
  }
}

function formatErrors(errors: ErrorObject[] | null | undefined): { path: string; rule: string }[] {
  return (errors ?? []).slice(0, 16).map((error) => ({
    path: error.instancePath || "/",
    rule: error.keyword,
  }));
}
