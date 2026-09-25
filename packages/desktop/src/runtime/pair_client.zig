//! Client for the runtime's Pair auth endpoints over either an SSH-forwarded
//! numeric loopback port or verified Direct / Tailnet HTTPS. Secrets are
//! borrowed for exactly one request and zeroed where copied.

const std = @import("std");
const headless = @import("headless");
const gateway_transport = @import("gateway_transport.zig");

const access_protocol = headless.access_protocol;

const remote = @import("verde_remote").pair_client;

pub const MAX_AUTH_PATH_BYTES = remote.MAX_AUTH_PATH_BYTES;
pub const deviceAuthorizationAlloc = remote.deviceAuthorizationAlloc;
const validatePath = remote.validatePath;

/// Transport outcome for one Pair auth exchange. `RateLimited` is separate
/// because the user must be told to wait rather than retry the same grant.
pub const Error = remote.Error;

/// A single authenticated or anonymous POST to one Pair auth path. The
/// authorization value is the full header (`VerdeDevice <id>.<credential>`).
pub const Request = struct {
    local_port: u16,
    path: []const u8,
    authorization: ?[]const u8,
    body: []const u8,
    timeout_ms: i64 = gateway_transport.DEFAULT_TIMEOUT_MS,
};

pub const DirectRequest = struct {
    https_url: []const u8,
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

/// Direct equivalent of `postAlloc`; authentication and response semantics
/// are identical, with only the verified HTTPS endpoint differing.
pub fn postDirectAlloc(allocator: std.mem.Allocator, request: DirectRequest) Error![]u8 {
    validatePath(request.path) catch return error.ProtocolRejected;
    if (std.mem.eql(u8, request.path, access_protocol.HTTP_PAIR_EXCHANGE_PATH)) {
        validateDirectDiscovery(allocator, request.https_url) catch |err| return mapPostError(err);
    }
    const url = gateway_transport.endpointUrlAlloc(allocator, request.https_url, request.path) catch
        return error.ProtocolRejected;
    defer allocator.free(url);
    var response = gateway_transport.postHttpsAlloc(allocator, .{
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

fn validateDirectDiscovery(allocator: std.mem.Allocator, https_url: []const u8) !void {
    const url = try gateway_transport.endpointUrlAlloc(allocator, https_url, "/.well-known/verde-runtime");
    defer allocator.free(url);
    var response = try gateway_transport.getHttpsAlloc(allocator, url, gateway_transport.DEFAULT_TIMEOUT_MS);
    defer response.deinit(allocator);
    if (response.status != .ok) return error.GatewayRejected;
    return remote.validateDirectDiscovery(allocator, https_url, response.body);
}

const mapPostError = remote.mapPostError;

test {
    _ = remote;
}
