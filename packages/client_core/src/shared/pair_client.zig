//! Pure Pair authentication helpers.

const std = @import("std");
const access_protocol = @import("headless").access_protocol;
const connection = @import("connection.zig");
const profile = @import("profile.zig");

pub const MAX_AUTH_PATH_BYTES: usize = 64;
pub const Error = connection.TransportError || error{RateLimited};

/// Builds `VerdeDevice <device_id>.<credential>`; the caller zeroes it.
pub fn deviceAuthorizationAlloc(
    allocator: std.mem.Allocator,
    device_id: []const u8,
    device_credential: []const u8,
) ![]u8 {
    try access_protocol.validateDeviceId(device_id);
    try access_protocol.validateSecret(device_credential);
    return std.fmt.allocPrint(allocator, "{s} {s}.{s}", .{
        access_protocol.DEVICE_AUTHORIZATION_SCHEME,
        device_id,
        device_credential,
    });
}

pub fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > MAX_AUTH_PATH_BYTES or path[0] != '/') return error.InvalidAuthPath;
    for (path) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '/' and byte != '-' and byte != '_') {
            return error.InvalidAuthPath;
        }
    }
}

test "pair client only accepts the runtime auth path shapes" {
    try validatePath(access_protocol.HTTP_PAIR_EXCHANGE_PATH);
    try validatePath(access_protocol.HTTP_ACCESS_TOKEN_PATH);
    try validatePath(access_protocol.HTTP_WEBSOCKET_TICKET_PATH);
    try std.testing.expectError(error.InvalidAuthPath, validatePath("auth/pair"));
    try std.testing.expectError(error.InvalidAuthPath, validatePath("/auth/pair?x=1"));
    try std.testing.expectError(error.InvalidAuthPath, validatePath("/auth/../x"));
}

test "device authorization header is scheme id dot credential" {
    const header = try deviceAuthorizationAlloc(
        std.testing.allocator,
        "0123456789abcdef0123456789abcdef",
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    );
    defer std.testing.allocator.free(header);
    try std.testing.expect(std.mem.startsWith(u8, header, "VerdeDevice 0123456789abcdef0123456789abcdef."));
    try std.testing.expectError(error.InvalidDeviceId, deviceAuthorizationAlloc(
        std.testing.allocator,
        "short",
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    ));
}

const RuntimeDiscovery = struct {
    access_protocol_version: u32,
    runtime_id: []const u8,
    instance_id: []const u8,
    https_url: []const u8,
    wss_url: []const u8,
    capabilities: []const []const u8,
};

/// Validates a descriptor body supplied by the platform HTTP adapter.
pub fn validateDirectDiscovery(allocator: std.mem.Allocator, https_url: []const u8, body: []const u8) !void {
    var parsed = try std.json.parseFromSlice(RuntimeDiscovery, allocator, body, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    const value = parsed.value;
    if (value.access_protocol_version != access_protocol.ACCESS_PROTOCOL_VERSION) return error.ProtocolRejected;
    try connection.validateRuntimeId(value.runtime_id);
    try connection.validateRuntimeId(value.instance_id);
    try profile.validateRuntimeEndpointPair(value.https_url, value.wss_url);
    const expected = try profile.sanitizedRuntimeHttpsOriginAlloc(allocator, https_url);
    defer allocator.free(expected);
    if (!std.mem.eql(u8, expected, value.https_url)) return error.ProtocolRejected;
    for (value.capabilities) |capability| {
        if (std.mem.eql(u8, capability, "access.pair.v1")) return;
    }
    return error.ProtocolRejected;
}

pub fn mapPostError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AuthenticationRequired => error.AuthenticationRequired,
        error.RateLimited => error.RateLimited,
        error.RequestTimedOut => error.RequestTimedOut,
        error.RedirectRejected,
        error.GatewayRejected,
        error.RequestTooLarge,
        error.ResponseTooLarge,
        error.EmptyRequest,
        error.InvalidPort,
        error.InvalidTimeout,
        error.InvalidDirectUrl,
        error.ProtocolRejected,
        => error.ProtocolRejected,
        else => error.NetworkUnavailable,
    };
}
