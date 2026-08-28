//! Headless Verde core: typed protocol, dispatcher, and transport-neutral client.
//!
//! Dependency rule: std only. No SDL, Palette, browser, Ghostty, zqlite, or
//! desktop AppState. Transport adapters live in packages/desktop.

const std = @import("std");

pub const protocol = @import("protocol.zig");
pub const runtime_identity = @import("runtime_identity.zig");
pub const pagination = @import("pagination.zig");
pub const registry = @import("registry_protocol.zig");
pub const store_protocol = @import("store_protocol.zig");
pub const changes_protocol = @import("changes_protocol.zig");
pub const providers_protocol = @import("providers_protocol.zig");
pub const access_protocol = @import("access_protocol.zig");
pub const dispatch = @import("dispatch.zig");
pub const client = @import("client.zig");
// Deliberate second alias for store_protocol: `.store` predates it and is
// consumed by the daemon store and IT binary; consolidate to one name only
// when those consumers' owning chunks are free to edit.
pub const store = @import("store_protocol.zig");

pub const HEADLESS_PROTOCOL_VERSION = protocol.HEADLESS_PROTOCOL_VERSION;
pub const MIN_SUPPORTED_PROTOCOL_VERSION = protocol.MIN_SUPPORTED_PROTOCOL_VERSION;
pub const MAX_SUPPORTED_PROTOCOL_VERSION = protocol.MAX_SUPPORTED_PROTOCOL_VERSION;
pub const ProtocolRange = protocol.ProtocolRange;
pub const RuntimeProtocolVersion = protocol.RuntimeProtocolVersion;
pub const RuntimeLimits = protocol.RuntimeLimits;
pub const RuntimeWorkspaceId = protocol.RuntimeWorkspaceId;
pub const RuntimeRepositoryId = protocol.RuntimeRepositoryId;
pub const RuntimeThreadId = protocol.RuntimeThreadId;
pub const BorrowedRuntimeThreadId = runtime_identity.BorrowedRuntimeThreadId;
pub const OwnedRuntimeThreadId = runtime_identity.OwnedRuntimeThreadId;
pub const RuntimePaneId = protocol.RuntimePaneId;
pub const RuntimeTurnId = protocol.RuntimeTurnId;

pub const Error = protocol.Error;
pub const CapabilityFeature = protocol.CapabilityFeature;
pub const BrowserFeatures = protocol.BrowserFeatures;
pub const BrowserCapabilities = protocol.BrowserCapabilities;
pub const Capabilities = protocol.Capabilities;
pub const StatusResult = protocol.StatusResult;
pub const CapabilitiesResult = protocol.CapabilitiesResult;
pub const RequestTarget = protocol.RequestTarget;
pub const Request = protocol.Request;
pub const Response = protocol.Response;
pub const ParsedRequest = protocol.ParsedRequest;
pub const ParsedResponse = protocol.ParsedResponse;

pub const encodeRequest = protocol.encodeRequest;
pub const encodeTargetedRequest = protocol.encodeTargetedRequest;
pub const encodeOkResponse = protocol.encodeOkResponse;
pub const encodeErrorResponse = protocol.encodeErrorResponse;
pub const parseRequest = protocol.parseRequest;
pub const parseRequestTarget = protocol.parseRequestTarget;
pub const parseResponse = protocol.parseResponse;
pub const validateRequestTarget = protocol.validateRequestTarget;
pub const validateProtocolRange = protocol.validateProtocolRange;
pub const negotiateProtocolVersion = protocol.negotiateProtocolVersion;
pub const capabilityUnavailable = protocol.capabilityUnavailable;

pub const Context = dispatch.Context;
pub const DispatchResponse = dispatch.Response;
pub const dispatchMethod = dispatch.dispatch;
pub const isMutatingMethod = dispatch.isMutatingMethod;

pub const Client = client.Client;
pub const TransportFn = client.TransportFn;
pub const RequiredCapability = client.RequiredCapability;
pub const CapabilityError = client.CapabilityError;
pub const RuntimeHandshakeError = client.RuntimeHandshakeError;
pub const requireCapability = client.requireCapability;
pub const requireFeature = client.requireFeature;
pub const requireDaemonDirectCapability = client.requireDaemonDirectCapability;
pub const verifyRuntimeHandshake = client.verifyRuntimeHandshake;

// Ensure inline tests in submodules run when this package is the test root.
test {
    std.testing.refAllDecls(@This());
}
