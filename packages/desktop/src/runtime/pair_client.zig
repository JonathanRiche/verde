//! Loopback client for the runtime's Pair auth endpoints.
//!
//! Every call travels through the SSH-forwarded numeric loopback port that
//! the tunnel supervisor owns, so this module never sees a remote address.
//! Secrets are borrowed for exactly one request and zeroed where copied.

const std = @import("std");
const headless = @import("headless");
const connection = @import("connection.zig");
const gateway_transport = @import("gateway_transport.zig");

const access_protocol = headless.access_protocol;

pub const MAX_AUTH_PATH_BYTES: usize = 64;

/// Transport outcome for one Pair auth exchange. `RateLimited` is separate
/// because the user must be told to wait rather than retry the same grant.
pub const Error = connection.TransportError || error{RateLimited};

/// A single authenticated or anonymous POST to one Pair auth path. The
/// authorization value is the full header (`VerdeDevice <id>.<credential>`).
pub const Request = struct {
    local_port: u16,
    path: []const u8,
    authorization: ?[]const u8,
    body: []const u8,
    timeout_ms: i64 = gateway_transport.DEFAULT_TIMEOUT_MS,
};

/// Returns the 200 body; every other status becomes an `Error`. Error bodies
/// are dropped so a daemon cannot echo secrets back into desktop state.
pub fn postAlloc(allocator: std.mem.Allocator, request: Request) Error![]u8 {
    validatePath(request.path) catch return error.ProtocolRejected;
    if (request.local_port == 0) return error.ProtocolRejected;
    const url = std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{
        request.local_port,
        request.path,
    }) catch return error.OutOfMemory;
    defer allocator.free(url);

    var response = gateway_transport.postLoopbackAlloc(allocator, .{
        .url = url,
        .authorization = request.authorization,
        .body = request.body,
        .timeout_ms = request.timeout_ms,
    }) catch |err| return mapPostError(err);
    errdefer response.deinit(allocator);
    gateway_transport.validateAuthStatus(response.status) catch |err| return mapPostError(err);
    if (response.body.len > access_protocol.MAX_PAIR_EXCHANGE_BODY_BYTES) return error.ProtocolRejected;
    return response.body;
}

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

fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > MAX_AUTH_PATH_BYTES or path[0] != '/') return error.InvalidAuthPath;
    for (path) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '/' and byte != '-' and byte != '_') {
            return error.InvalidAuthPath;
        }
    }
}

fn mapPostError(err: anyerror) Error {
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
        => error.ProtocolRejected,
        else => error.NetworkUnavailable,
    };
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
