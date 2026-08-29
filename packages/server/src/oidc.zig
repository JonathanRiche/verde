//! Memory-only RFC 8628 public-client authorization.

const std = @import("std");

pub const MAX_RESPONSE_BYTES: usize = 512 * 1024;
pub const DEFAULT_TIMEOUT_MS: u32 = 30_000;
pub const MAX_TIMEOUT_MS: u32 = 120_000;
const REDIRECT_BEHAVIOR: std.http.Client.Request.RedirectBehavior = .not_allowed;

pub const Token = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn deinit(self: *Token) void {
        std.crypto.secureZero(u8, self.bytes);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Response = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, self.body);
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const Transport = struct {
    context: *anyopaque,
    send_fn: *const fn (*anyopaque, std.mem.Allocator, std.http.Method, []const u8, ?[]const u8) anyerror!Response,

    pub fn send(self: Transport, allocator: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?[]const u8) !Response {
        return self.send_fn(self.context, allocator, method, url, body);
    }
};

pub const HttpTransport = struct {
    timeout_ms: u32 = DEFAULT_TIMEOUT_MS,

    pub fn transport(self: *HttpTransport) Transport {
        return .{ .context = self, .send_fn = send };
    }

    fn send(context: *anyopaque, allocator: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?[]const u8) !Response {
        const self: *HttpTransport = @ptrCast(@alignCast(context));
        try validateHttpsUrl(url);
        const timeout = try timeoutDuration(self.timeout_ms);
        const response_buffer = try allocator.alloc(u8, MAX_RESPONSE_BYTES);
        defer {
            // Token responses are first written here before the owned response
            // copy is made, so this allocation is secret-bearing on every path.
            std.crypto.secureZero(u8, response_buffer);
            allocator.free(response_buffer);
        }
        var response_writer: std.Io.Writer = .fixed(response_buffer);
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        var client: std.http.Client = .{
            .allocator = allocator,
            .io = threaded.io(),
            .read_buffer_size = 16 * 1024,
        };
        defer client.deinit();
        const fetch_options: std.http.Client.FetchOptions = .{
            .location = .{ .url = url },
            .method = method,
            .payload = body,
            .redirect_behavior = REDIRECT_BEHAVIOR,
            .response_writer = &response_writer,
            .headers = .{
                .content_type = if (body != null) .{ .override = "application/x-www-form-urlencoded" } else .default,
                .user_agent = .{ .override = "verde-server-connect/1" },
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
        select.async(.timeout, std.Io.sleep, .{ threaded.io(), timeout, .awake });
        // Cancellation completes before the client, threaded I/O, writer, and
        // secret-bearing response allocation are torn down.
        defer select.cancelDiscard();
        const selected = try select.await();
        const result = switch (selected) {
            .fetch => |fetch_result| fetch_result catch |err| switch (err) {
                error.TooManyHttpRedirects => return error.OidcRedirectRejected,
                error.WriteFailed => if (response_writer.end == response_buffer.len)
                    return error.OidcResponseTooLarge
                else
                    return err,
                else => return err,
            },
            .timeout => |timeout_result| {
                try timeout_result;
                return error.OidcRequestTimedOut;
            },
        };
        if (@intFromEnum(result.status) >= 300 and @intFromEnum(result.status) < 400) return error.OidcRedirectRejected;
        return .{ .status = result.status, .body = try allocator.dupe(u8, response_writer.buffered()) };
    }
};

fn timeoutDuration(timeout_ms: u32) !std.Io.Duration {
    if (timeout_ms == 0 or timeout_ms > MAX_TIMEOUT_MS) return error.InvalidOidcTimeout;
    return .fromMilliseconds(timeout_ms);
}

pub const Session = struct {
    allocator: std.mem.Allocator,
    token_endpoint: []u8,
    client_id: []u8,
    device_code: []u8,
    user_code: []u8,
    verification_uri: []u8,
    expires_in: u32,
    interval: u16,

    pub fn deinit(self: *Session) void {
        self.allocator.free(self.token_endpoint);
        self.allocator.free(self.client_id);
        std.crypto.secureZero(u8, self.device_code);
        self.allocator.free(self.device_code);
        std.crypto.secureZero(u8, self.user_code);
        self.allocator.free(self.user_code);
        self.allocator.free(self.verification_uri);
        self.* = undefined;
    }
};

pub fn start(allocator: std.mem.Allocator, transport: Transport, control_plane_url: []const u8) !Session {
    try validateHttpsUrl(control_plane_url);
    const discovery_url = try std.fmt.allocPrint(allocator, "{s}/.well-known/verde-connect-configuration", .{control_plane_url});
    defer allocator.free(discovery_url);
    var response = try transport.send(allocator, .GET, discovery_url, null);
    defer response.deinit(allocator);
    if (response.status != .ok) return error.ConnectDiscoveryFailed;
    const Discovery = struct {
        contract_version: []const u8,
        api_base_url: []const u8,
        oidc: struct {
            token_endpoint: []const u8,
            device_authorization_endpoint: ?[]const u8 = null,
            public_client: struct { client_id: []const u8, scopes: []const []const u8 },
            headless_authorization: struct { supported: bool },
        },
    };
    var discovery = std.json.parseFromSlice(Discovery, allocator, response.body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidConnectDiscovery;
    defer discovery.deinit();
    if (!std.mem.eql(u8, discovery.value.contract_version, "1") or
        !std.mem.eql(u8, discovery.value.api_base_url, control_plane_url) or
        !discovery.value.oidc.headless_authorization.supported or
        discovery.value.oidc.device_authorization_endpoint == null)
    {
        return error.ConnectDeviceFlowUnavailable;
    }
    try validateHttpsUrl(discovery.value.oidc.token_endpoint);
    try validateHttpsUrl(discovery.value.oidc.device_authorization_endpoint.?);
    const scopes = try std.mem.join(allocator, " ", discovery.value.oidc.public_client.scopes);
    defer allocator.free(scopes);
    const request_body = try formAlloc(allocator, &.{
        .{ discovery.value.oidc.public_client.client_id, "client_id" },
        .{ scopes, "scope" },
    });
    defer allocator.free(request_body);
    var device_response = try transport.send(allocator, .POST, discovery.value.oidc.device_authorization_endpoint.?, request_body);
    defer device_response.deinit(allocator);
    if (device_response.status != .ok) return error.ConnectDeviceAuthorizationFailed;
    const Device = struct {
        device_code: []const u8,
        user_code: []const u8,
        verification_uri: []const u8,
        expires_in: u32,
        interval: u16 = 5,
    };
    var device = std.json.parseFromSlice(Device, allocator, device_response.body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidDeviceAuthorization;
    defer device.deinit();
    try validateHttpsUrl(device.value.verification_uri);
    if (device.value.device_code.len < 16 or device.value.device_code.len > 4096 or
        device.value.user_code.len == 0 or device.value.user_code.len > 128 or
        device.value.expires_in < 30 or device.value.expires_in > 1800 or
        device.value.interval == 0 or device.value.interval > 60)
    {
        return error.InvalidDeviceAuthorization;
    }
    const token_endpoint = try allocator.dupe(u8, discovery.value.oidc.token_endpoint);
    errdefer allocator.free(token_endpoint);
    const client_id = try allocator.dupe(u8, discovery.value.oidc.public_client.client_id);
    errdefer allocator.free(client_id);
    const device_code = try allocator.dupe(u8, device.value.device_code);
    errdefer {
        std.crypto.secureZero(u8, device_code);
        allocator.free(device_code);
    }
    const user_code = try allocator.dupe(u8, device.value.user_code);
    errdefer {
        std.crypto.secureZero(u8, user_code);
        allocator.free(user_code);
    }
    const verification_uri = try allocator.dupe(u8, device.value.verification_uri);
    errdefer allocator.free(verification_uri);
    return .{
        .allocator = allocator,
        .token_endpoint = token_endpoint,
        .client_id = client_id,
        .device_code = device_code,
        .user_code = user_code,
        .verification_uri = verification_uri,
        .expires_in = device.value.expires_in,
        .interval = device.value.interval,
    };
}

pub fn poll(allocator: std.mem.Allocator, transport: Transport, session: Session) !?Token {
    const request_body = try formAlloc(allocator, &.{
        .{ "urn:ietf:params:oauth:grant-type:device_code", "grant_type" },
        .{ session.device_code, "device_code" },
        .{ session.client_id, "client_id" },
    });
    defer {
        std.crypto.secureZero(u8, request_body);
        allocator.free(request_body);
    }
    var response = try transport.send(allocator, .POST, session.token_endpoint, request_body);
    defer response.deinit(allocator);
    if (response.status == .bad_request) {
        const Failure = struct { @"error": []const u8 };
        var failure = std.json.parseFromSlice(Failure, allocator, response.body, .{
            .ignore_unknown_fields = true,
        }) catch return error.ConnectTokenExchangeFailed;
        defer failure.deinit();
        if (std.mem.eql(u8, failure.value.@"error", "authorization_pending")) return null;
        if (std.mem.eql(u8, failure.value.@"error", "slow_down")) return error.ConnectSlowDown;
        if (std.mem.eql(u8, failure.value.@"error", "access_denied")) return error.ConnectAuthorizationDenied;
        if (std.mem.eql(u8, failure.value.@"error", "expired_token")) return error.ConnectAuthorizationExpired;
        return error.ConnectTokenExchangeFailed;
    }
    if (response.status != .ok) return error.ConnectTokenExchangeFailed;
    const Success = struct { access_token: []const u8, token_type: []const u8 };
    var success = std.json.parseFromSlice(Success, allocator, response.body, .{
        .ignore_unknown_fields = true,
    }) catch return error.ConnectTokenExchangeFailed;
    defer success.deinit();
    if (!std.ascii.eqlIgnoreCase(success.value.token_type, "Bearer")) return error.ConnectTokenExchangeFailed;
    try validateToken(success.value.access_token);
    return .{ .allocator = allocator, .bytes = try allocator.dupe(u8, success.value.access_token) };
}

pub fn writeHandoff(io: std.Io, allocator: std.mem.Allocator, state_dir: []const u8, token: []const u8) ![]u8 {
    try validateToken(token);
    try std.Io.Dir.cwd().createDirPath(io, state_dir);
    if (@import("builtin").os.tag != .windows and std.posix.mode_t != u0) {
        try std.Io.Dir.cwd().setFilePermissions(io, state_dir, @enumFromInt(0o700), .{ .follow_symlinks = false });
    }
    var random: [16]u8 = undefined;
    defer std.crypto.secureZero(u8, &random);
    try io.randomSecure(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    const path = try std.fmt.allocPrint(allocator, "{s}/.connect-handoff-{s}", .{ state_dir, @as([]const u8, &suffix) });
    errdefer allocator.free(path);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{
        .exclusive = true,
        .permissions = @enumFromInt(0o600),
    });
    defer file.close(io);
    try file.writeStreamingAll(io, token);
    try file.writeStreamingAll(io, "\n");
    try file.sync(io);
    return path;
}

pub fn removeFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn formAlloc(allocator: std.mem.Allocator, fields: []const struct { []const u8, []const u8 }) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (fields, 0..) |field, index| {
        if (index > 0) try output.writer.writeByte('&');
        try formComponent(&output.writer, field[1]);
        try output.writer.writeByte('=');
        try formComponent(&output.writer, field[0]);
    }
    return output.toOwnedSlice();
}

fn formComponent(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            try writer.writeByte(byte);
        } else {
            try writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 0xf] });
        }
    }
}

fn validateToken(token: []const u8) !void {
    if (token.len < 32 or token.len > 4096) return error.InvalidConnectToken;
    for (token) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidConnectToken;
}

fn validateHttpsUrl(value: []const u8) !void {
    const uri = std.Uri.parse(value) catch return error.InvalidConnectUrl;
    if (!std.mem.eql(u8, uri.scheme, "https") or uri.host == null or uri.host.?.isEmpty() or
        uri.user != null or uri.password != null or uri.fragment != null)
    {
        return error.InvalidConnectUrl;
    }
}

test "form encoding does not use shell or argv" {
    const encoded = try formAlloc(std.testing.allocator, &.{
        .{ "openid profile", "scope" },
        .{ "a+b/c", "device_code" },
    });
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("scope=openid%20profile&device_code=a%2Bb%2Fc", encoded);
}

test "OIDC HTTP transport rejects redirects before following" {
    try std.testing.expectEqual(std.http.Client.Request.RedirectBehavior.not_allowed, REDIRECT_BEHAVIOR);
}

test "OIDC HTTP timeout policy is finite and configurable" {
    const default = try timeoutDuration(DEFAULT_TIMEOUT_MS);
    const readiness = try timeoutDuration(2_000);
    try std.testing.expect(!std.meta.eql(default, readiness));
    try std.testing.expectError(error.InvalidOidcTimeout, timeoutDuration(0));
    try std.testing.expectError(error.InvalidOidcTimeout, timeoutDuration(MAX_TIMEOUT_MS + 1));
}
