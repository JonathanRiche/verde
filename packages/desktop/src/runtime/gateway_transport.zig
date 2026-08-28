//! Bounded bearer-authenticated RPC transport for an SSH-forwarded Verde gateway.

const std = @import("std");

pub const MAX_RPC_FRAME_BYTES: usize = 1024 * 1024;
pub const MIN_BEARER_TOKEN_BYTES: usize = 32;
pub const MAX_BEARER_TOKEN_BYTES: usize = 4 * 1024;
pub const DEFAULT_TIMEOUT_MS: i64 = 15_000;
pub const MAX_TIMEOUT_MS: i64 = 60_000;

/// One daemon RPC sent only to a numeric loopback endpoint. Remote profiles
/// reach that endpoint through a separately supervised SSH tunnel.
pub const Call = struct {
    local_port: u16,
    bearer_token: []const u8,
    rpc_json: []const u8,
    timeout_ms: i64 = DEFAULT_TIMEOUT_MS,
};

/// POST one JSON-RPC frame to the authenticated gateway and return the
/// caller-owned response. Tokens are borrowed for the call and never logged
/// or retained by the transport.
pub fn callAlloc(allocator: std.mem.Allocator, call: Call) ![]u8 {
    try validateCall(call);

    const url = try gatewayUrlAlloc(allocator, call.local_port);
    defer allocator.free(url);
    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{call.bearer_token});
    defer {
        std.crypto.secureZero(u8, authorization);
        allocator.free(authorization);
    }

    const response_buffer = try allocator.alloc(u8, MAX_RPC_FRAME_BYTES);
    defer allocator.free(response_buffer);
    var response_writer: std.Io.Writer = .fixed(response_buffer);

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = threaded.io(),
        // The gateway deliberately keeps response headers small. Bounding the
        // client parser prevents a loopback peer from growing this allocation.
        .read_buffer_size = 4 * 1024,
    };
    defer client.deinit();
    // Proxy fields remain null: loopback daemon traffic must never honor
    // ambient HTTP(S)_PROXY configuration.

    const fetch_options: std.http.Client.FetchOptions = .{
        .location = .{ .url = url },
        .method = .POST,
        .payload = call.rpc_json,
        .response_writer = &response_writer,
        .keep_alive = false,
        .redirect_behavior = .not_allowed,
        .headers = .{
            .authorization = .{ .override = authorization },
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = "verde-desktop-runtime" },
        },
        .privileged_headers = &.{.{ .name = "accept", .value = "application/json" }},
    };
    const SelectResult = union(enum) {
        fetch: std.http.Client.FetchError!std.http.Client.FetchResult,
        timeout: std.Io.Cancelable!void,
    };
    var select_buffer: [2]SelectResult = undefined;
    var select = std.Io.Select(SelectResult).init(threaded.io(), &select_buffer);
    select.async(.fetch, std.http.Client.fetch, .{ &client, fetch_options });
    select.async(.timeout, std.Io.sleep, .{
        threaded.io(),
        std.Io.Duration.fromMilliseconds(call.timeout_ms),
        .awake,
    });
    defer select.cancelDiscard();

    const selected = try select.await();
    const result = switch (selected) {
        .fetch => |fetch_result| fetch_result catch |err| switch (err) {
            error.WriteFailed => if (response_writer.end == response_buffer.len)
                return error.ResponseTooLarge
            else
                return err,
            else => return err,
        },
        .timeout => |timeout_result| {
            try timeout_result;
            return error.RequestTimedOut;
        },
    };
    try validateStatus(result.status);
    return try allocator.dupe(u8, response_writer.buffered());
}

fn validateCall(call: Call) !void {
    if (call.local_port == 0) return error.InvalidPort;
    if (call.rpc_json.len == 0) return error.EmptyRequest;
    if (call.rpc_json.len > MAX_RPC_FRAME_BYTES) return error.RequestTooLarge;
    if (call.timeout_ms <= 0 or call.timeout_ms > MAX_TIMEOUT_MS) return error.InvalidTimeout;
    if (call.bearer_token.len < MIN_BEARER_TOKEN_BYTES) return error.WeakToken;
    if (call.bearer_token.len > MAX_BEARER_TOKEN_BYTES) return error.TokenTooLong;
    for (call.bearer_token) |byte| {
        if (byte < 0x21 or byte > 0x7e) return error.InvalidTokenEncoding;
    }
}

fn gatewayUrlAlloc(allocator: std.mem.Allocator, local_port: u16) ![]u8 {
    if (local_port == 0) return error.InvalidPort;
    return try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/api/rpc", .{local_port});
}

fn validateStatus(status: std.http.Status) !void {
    return switch (status) {
        .ok => {},
        .unauthorized, .forbidden => error.AuthenticationRequired,
        .payload_too_large => error.RequestTooLarge,
        .service_unavailable, .bad_gateway, .gateway_timeout => error.DaemonUnavailable,
        .moved_permanently, .found, .see_other, .temporary_redirect, .permanent_redirect => error.RedirectRejected,
        else => error.GatewayRejected,
    };
}

test "gateway URL is fixed to numeric loopback and one RPC path" {
    const url = try gatewayUrlAlloc(std.testing.allocator, 43127);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://127.0.0.1:43127/api/rpc", url);
    try std.testing.expectError(error.InvalidPort, gatewayUrlAlloc(std.testing.allocator, 0));
}

test "call validation rejects unsafe credentials and unbounded frames" {
    const valid_token = "0123456789abcdef0123456789abcdef";
    try validateCall(.{
        .local_port = 43127,
        .bearer_token = valid_token,
        .rpc_json = "{}",
    });
    try std.testing.expectError(error.WeakToken, validateCall(.{
        .local_port = 43127,
        .bearer_token = "short",
        .rpc_json = "{}",
    }));
    try std.testing.expectError(error.InvalidTokenEncoding, validateCall(.{
        .local_port = 43127,
        .bearer_token = "0123456789abcdef0123456789abcde\n",
        .rpc_json = "{}",
    }));
    try std.testing.expectError(error.RequestTooLarge, validateCall(.{
        .local_port = 43127,
        .bearer_token = valid_token,
        .rpc_json = &([_]u8{'x'} ** (MAX_RPC_FRAME_BYTES + 1)),
    }));
    try std.testing.expectError(error.InvalidTimeout, validateCall(.{
        .local_port = 43127,
        .bearer_token = valid_token,
        .rpc_json = "{}",
        .timeout_ms = MAX_TIMEOUT_MS + 1,
    }));
}

test "gateway status mapping keeps auth and redirect failures distinct" {
    try validateStatus(.ok);
    try std.testing.expectError(error.AuthenticationRequired, validateStatus(.unauthorized));
    try std.testing.expectError(error.DaemonUnavailable, validateStatus(.service_unavailable));
    try std.testing.expectError(error.RedirectRejected, validateStatus(.temporary_redirect));
    try std.testing.expectError(error.GatewayRejected, validateStatus(.not_found));
}
