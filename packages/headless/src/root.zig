//! Headless Verde core: typed protocol, dispatcher, and transport-neutral client.
//!
//! Dependency rule: std only. No SDL, Palette, browser, Ghostty, zqlite, or
//! desktop AppState. Transport adapters live in packages/desktop.

const std = @import("std");

pub const protocol = @import("protocol.zig");
pub const dispatch = @import("dispatch.zig");
pub const client = @import("client.zig");

pub const HEADLESS_PROTOCOL_VERSION = protocol.HEADLESS_PROTOCOL_VERSION;
pub const MIN_SUPPORTED_PROTOCOL_VERSION = protocol.MIN_SUPPORTED_PROTOCOL_VERSION;
pub const MAX_SUPPORTED_PROTOCOL_VERSION = protocol.MAX_SUPPORTED_PROTOCOL_VERSION;

pub const Error = protocol.Error;
pub const Capabilities = protocol.Capabilities;
pub const StatusResult = protocol.StatusResult;
pub const CapabilitiesResult = protocol.CapabilitiesResult;
pub const Request = protocol.Request;
pub const Response = protocol.Response;
pub const ParsedRequest = protocol.ParsedRequest;
pub const ParsedResponse = protocol.ParsedResponse;

pub const encodeRequest = protocol.encodeRequest;
pub const encodeOkResponse = protocol.encodeOkResponse;
pub const encodeErrorResponse = protocol.encodeErrorResponse;
pub const parseRequest = protocol.parseRequest;
pub const parseResponse = protocol.parseResponse;

pub const Context = dispatch.Context;
pub const DispatchResponse = dispatch.Response;
pub const dispatchMethod = dispatch.dispatch;

pub const Client = client.Client;
pub const TransportFn = client.TransportFn;

// Ensure inline tests in submodules run when this package is the test root.
test {
    std.testing.refAllDecls(@This());
}
