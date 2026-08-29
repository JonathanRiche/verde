//! Bounded bearer-authenticated RPC transport for Verde gateways.

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

/// HTTPS endpoint call used by Direct/Tailnet and Connect-resolved profiles.
/// Zig's HTTP client performs normal CA-chain and hostname verification. It
/// currently exposes no peer certificate/SPKI callback; descriptor SPKI is
/// therefore checked for canonical form by the profile layer but is not used
/// to weaken or replace PKIX verification.
pub const DirectCall = struct {
    https_url: []const u8,
    bearer_token: []const u8,
    rpc_json: []const u8,
    timeout_ms: i64 = DEFAULT_TIMEOUT_MS,
};

pub const TLS_TRUST_BOUNDARY: []const u8 =
    "Direct HTTPS requires a system-trusted certificate for the exact URL hostname; " ++
    "runtime and instance identity are pinned separately after authenticated handshake.";

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
    var response = try postLoopbackAlloc(allocator, .{
        .url = url,
        .authorization = authorization,
        .body = call.rpc_json,
        .timeout_ms = call.timeout_ms,
    });
    errdefer response.deinit(allocator);
    try validateStatus(response.status);
    return response.body;
}

/// POST one RPC directly over verified HTTPS. Redirects are rejected so a
/// bearer can never be forwarded to a different origin.
pub fn callDirectAlloc(allocator: std.mem.Allocator, call: DirectCall) ![]u8 {
    try validateDirectCall(call);
    const url = try endpointUrlAlloc(allocator, call.https_url, "/api/rpc");
    defer allocator.free(url);
    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{call.bearer_token});
    defer {
        std.crypto.secureZero(u8, authorization);
        allocator.free(authorization);
    }
    var response = try postHttpsAlloc(allocator, .{
        .url = url,
        .authorization = authorization,
        .body = call.rpc_json,
        .timeout_ms = call.timeout_ms,
    });
    errdefer response.deinit(allocator);
    try validateStatus(response.status);
    return response.body;
}

/// One bounded loopback POST whose status is returned instead of mapped, so
/// the Pair auth endpoints can distinguish rejection from rate limiting.
pub const LoopbackPost = struct {
    url: []const u8,
    /// Full header value (`Bearer …` or `VerdeDevice …`); zeroed by the caller.
    authorization: ?[]const u8,
    body: []const u8,
    timeout_ms: i64 = DEFAULT_TIMEOUT_MS,
};

pub const LoopbackResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *LoopbackResponse, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, self.body);
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const HttpsPost = struct {
    url: []const u8,
    authorization: ?[]const u8,
    body: []const u8,
    timeout_ms: i64 = DEFAULT_TIMEOUT_MS,
};

/// Bounded HTTPS POST with strict PKIX/hostname verification and no redirects.
pub fn postHttpsAlloc(allocator: std.mem.Allocator, post: HttpsPost) !LoopbackResponse {
    if (!std.mem.startsWith(u8, post.url, "https://")) return error.InvalidDirectUrl;
    const uri = std.Uri.parse(post.url) catch return error.InvalidDirectUrl;
    if (uri.host == null or uri.user != null or uri.password != null or uri.fragment != null) {
        return error.InvalidDirectUrl;
    }
    return fetchNetworkAlloc(allocator, .POST, post.url, post.authorization, post.body, post.timeout_ms);
}

pub fn getHttpsAlloc(allocator: std.mem.Allocator, url: []const u8, timeout_ms: i64) !LoopbackResponse {
    if (!std.mem.startsWith(u8, url, "https://")) return error.InvalidDirectUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidDirectUrl;
    if (uri.host == null or uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidDirectUrl;
    return fetchNetworkAlloc(allocator, .GET, url, null, null, timeout_ms);
}

pub fn postLoopbackAlloc(allocator: std.mem.Allocator, post: LoopbackPost) !LoopbackResponse {
    if (!std.mem.startsWith(u8, post.url, "http://127.0.0.1:")) return error.InvalidPort;
    return fetchNetworkAlloc(allocator, .POST, post.url, post.authorization, post.body, post.timeout_ms);
}

fn fetchNetworkAlloc(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    authorization: ?[]const u8,
    body: ?[]const u8,
    timeout_ms: i64,
) !LoopbackResponse {
    if (method == .POST and (body == null or body.?.len == 0)) return error.EmptyRequest;
    if (body) |value| if (value.len > MAX_RPC_FRAME_BYTES) return error.RequestTooLarge;
    if (timeout_ms <= 0 or timeout_ms > MAX_TIMEOUT_MS) return error.InvalidTimeout;

    const response_buffer = try allocator.alloc(u8, MAX_RPC_FRAME_BYTES);
    defer {
        std.crypto.secureZero(u8, response_buffer);
        allocator.free(response_buffer);
    }
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
        .method = method,
        .payload = body,
        .response_writer = &response_writer,
        .keep_alive = false,
        .redirect_behavior = .not_allowed,
        .headers = .{
            .authorization = if (authorization) |value| .{ .override = value } else .omit,
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
        std.Io.Duration.fromMilliseconds(timeout_ms),
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
    const response_body = try allocator.dupe(u8, response_writer.buffered());
    return .{ .status = result.status, .body = response_body };
}

fn validateDirectCall(call: DirectCall) !void {
    try validateCall(.{
        .local_port = 1,
        .bearer_token = call.bearer_token,
        .rpc_json = call.rpc_json,
        .timeout_ms = call.timeout_ms,
    });
    if (!std.mem.startsWith(u8, call.https_url, "https://")) return error.InvalidDirectUrl;
}

pub fn endpointUrlAlloc(allocator: std.mem.Allocator, origin: []const u8, path: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, origin, "https://") or path.len == 0 or path[0] != '/') {
        return error.InvalidDirectUrl;
    }
    const trimmed = std.mem.trimEnd(u8, origin, "/");
    const uri = std.Uri.parse(trimmed) catch return error.InvalidDirectUrl;
    if (uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) {
        return error.InvalidDirectUrl;
    }
    const origin_path = switch (uri.path) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
    if (origin_path.len != 0) return error.InvalidDirectUrl;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed, path });
}

/// Maps a Pair auth endpoint status to a transport-level outcome. 401/403 is
/// "this credential or grant is not accepted"; 429 is the runtime's own
/// rate limit and must be surfaced to the user rather than retried blindly.
pub fn validateAuthStatus(status: std.http.Status) !void {
    return switch (status) {
        .ok => {},
        .unauthorized, .forbidden => error.AuthenticationRequired,
        .too_many_requests => error.RateLimited,
        else => validateStatus(status),
    };
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

test "direct endpoint keeps credentials on one verified origin" {
    const url = try endpointUrlAlloc(std.testing.allocator, "https://runtime.tailnet.ts.net/", "/api/rpc");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://runtime.tailnet.ts.net/api/rpc", url);
    try std.testing.expectError(error.InvalidDirectUrl, endpointUrlAlloc(std.testing.allocator, "http://runtime.test", "/api/rpc"));
    try std.testing.expectError(error.InvalidDirectUrl, endpointUrlAlloc(std.testing.allocator, "https://user@runtime.test", "/api/rpc"));
    try std.testing.expectError(error.InvalidDirectUrl, endpointUrlAlloc(std.testing.allocator, "https://runtime.test/base", "/api/rpc"));
    try std.testing.expectError(error.InvalidDirectUrl, endpointUrlAlloc(std.testing.allocator, "https://runtime.test?tenant=one", "/api/rpc"));
}
