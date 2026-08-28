//! Bounded, no-redirect Verde Connect public-v1 control-plane client.

const std = @import("std");
const headless = @import("headless");

const connect = headless.connect_protocol;

pub const MAX_RESPONSE_BYTES: usize = 512 * 1024;
pub const MAX_REQUEST_BYTES: usize = 64 * 1024;
pub const DEFAULT_TIMEOUT_MS: i64 = 15_000;

pub const Request = struct {
    method: std.http.Method,
    url: []const u8,
    bearer_token: ?[]const u8 = null,
    body: ?[]const u8 = null,
    /// Overrides the JSON default; the desktop OIDC code exchange must post
    /// `application/x-www-form-urlencoded`.
    content_type: ?[]const u8 = null,
    timeout_ms: i64 = DEFAULT_TIMEOUT_MS,
};

pub const Response = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const Transport = struct {
    context: *anyopaque,
    send_fn: *const fn (*anyopaque, std.mem.Allocator, Request) anyerror!Response,

    pub fn send(self: Transport, allocator: std.mem.Allocator, request: Request) !Response {
        return self.send_fn(self.context, allocator, request);
    }
};

pub const HttpTransport = struct {
    pub fn transport(self: *HttpTransport) Transport {
        return .{ .context = self, .send_fn = send };
    }

    fn send(_: *anyopaque, allocator: std.mem.Allocator, request: Request) !Response {
        try validateRequest(request);
        const response_buffer = try allocator.alloc(u8, MAX_RESPONSE_BYTES);
        defer allocator.free(response_buffer);
        var response_writer: std.Io.Writer = .fixed(response_buffer);

        var authorization: ?[]u8 = null;
        defer if (authorization) |value| {
            std.crypto.secureZero(u8, value);
            allocator.free(value);
        };
        if (request.bearer_token) |token| {
            authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
        }

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        var client: std.http.Client = .{
            .allocator = allocator,
            .io = threaded.io(),
            .read_buffer_size = 16 * 1024,
        };
        defer client.deinit();
        // Proxy fields intentionally remain null. A configured proxy could
        // receive the bearer credential or rewrite the pinned destination.

        const options: std.http.Client.FetchOptions = .{
            .location = .{ .url = request.url },
            .method = request.method,
            .payload = request.body,
            .response_writer = &response_writer,
            .keep_alive = false,
            .redirect_behavior = .not_allowed,
            .headers = .{
                .authorization = if (authorization) |value| .{ .override = value } else .default,
                .content_type = if (request.body != null) .{ .override = request.content_type orelse "application/json" } else .default,
                .user_agent = .{ .override = "verde-connect-runtime/1" },
            },
            .privileged_headers = &.{.{ .name = "accept", .value = "application/json" }},
        };
        const SelectResult = union(enum) {
            fetch: std.http.Client.FetchError!std.http.Client.FetchResult,
            timeout: std.Io.Cancelable!void,
        };
        var select_buffer: [2]SelectResult = undefined;
        var select = std.Io.Select(SelectResult).init(threaded.io(), &select_buffer);
        select.async(.fetch, std.http.Client.fetch, .{ &client, options });
        select.async(.timeout, std.Io.sleep, .{
            threaded.io(),
            std.Io.Duration.fromMilliseconds(request.timeout_ms),
            .awake,
        });
        defer select.cancelDiscard();
        const selected = try select.await();
        const result = switch (selected) {
            .fetch => |fetch| fetch catch |err| switch (err) {
                error.WriteFailed => if (response_writer.end == response_buffer.len)
                    return error.ControlPlaneResponseTooLarge
                else
                    return err,
                else => return err,
            },
            .timeout => |timeout| {
                try timeout;
                return error.ControlPlaneTimedOut;
            },
        };
        if (isRedirect(result.status)) return error.ControlPlaneRedirectRejected;
        return .{ .status = result.status, .body = try allocator.dupe(u8, response_writer.buffered()) };
    }
};

pub const Discovery = struct {
    contract_version: []const u8,
    issuer: []const u8,
    api_base_url: []const u8,
    oidc: Oidc,
    jwks_uri: []const u8,
    signer_metadata_url: []const u8,
    capabilities: []const []const u8,

    pub const Oidc = struct {
        issuer: []const u8,
        authorization_endpoint: []const u8,
        token_endpoint: []const u8,
        device_authorization_endpoint: ?[]const u8 = null,
        code_challenge_methods_supported: []const []const u8,
        public_client: struct {
            client_id: []const u8,
            scopes: []const []const u8,
            redirect_uris: []const []const u8,
            response_type: []const u8,
            token_endpoint_auth_method: []const u8,
        },
        headless_authorization: struct {
            supported: bool,
            grant_type: ?[]const u8 = null,
        },
    };
};

pub const SignerMetadata = struct {
    contract_version: []const u8,
    issuer: []const u8,
    jwks_uri: []const u8,
    algorithms: []const []const u8,
    maximum_grant_lifetime_seconds: ?u16 = null,
};

pub const Jwks = struct {
    keys: []const @import("connect_crypto.zig").PublicJwk,
};

pub const OwnedDiscovery = struct {
    parsed: std.json.Parsed(Discovery),

    pub fn deinit(self: *OwnedDiscovery) void {
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn value(self: *const OwnedDiscovery) Discovery {
        return self.parsed.value;
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    base_url: []const u8,

    pub fn init(allocator: std.mem.Allocator, transport: Transport, base_url: []const u8) !Client {
        try connect.validateControlPlaneUrl(base_url);
        return .{ .allocator = allocator, .transport = transport, .base_url = base_url };
    }

    pub fn discover(self: Client) !OwnedDiscovery {
        const url = try self.urlAlloc("/.well-known/verde-connect-configuration");
        defer self.allocator.free(url);
        var response = try self.transport.send(self.allocator, .{ .method = .GET, .url = url });
        defer response.deinit(self.allocator);
        try requireStatus(response.status, &.{.ok});
        var parsed = std.json.parseFromSlice(Discovery, self.allocator, response.body, .{
            .allocate = .alloc_always,
        }) catch return error.InvalidConnectDiscovery;
        errdefer parsed.deinit();
        try validateDiscovery(self.base_url, parsed.value);
        return .{ .parsed = parsed };
    }

    pub fn signerMetadata(self: Client, discovery: Discovery) !std.json.Parsed(SignerMetadata) {
        var response = try self.transport.send(self.allocator, .{
            .method = .GET,
            .url = discovery.signer_metadata_url,
        });
        defer response.deinit(self.allocator);
        try requireStatus(response.status, &.{.ok});
        var parsed = std.json.parseFromSlice(SignerMetadata, self.allocator, response.body, .{
            .allocate = .alloc_always,
        }) catch return error.InvalidSignerMetadata;
        errdefer parsed.deinit();
        const value = parsed.value;
        if (!std.mem.eql(u8, value.contract_version, connect.CONTRACT_VERSION) or
            !std.mem.eql(u8, value.issuer, discovery.issuer) or
            !std.mem.eql(u8, value.jwks_uri, discovery.jwks_uri) or
            value.algorithms.len != 1 or !std.mem.eql(u8, value.algorithms[0], "EdDSA") or
            (value.maximum_grant_lifetime_seconds != null and
                (value.maximum_grant_lifetime_seconds.? < 15 or value.maximum_grant_lifetime_seconds.? > 300)))
        {
            return error.InvalidSignerMetadata;
        }
        return parsed;
    }

    pub fn signerJwks(self: Client, discovery: Discovery) !std.json.Parsed(Jwks) {
        var response = try self.transport.send(self.allocator, .{
            .method = .GET,
            .url = discovery.jwks_uri,
        });
        defer response.deinit(self.allocator);
        try requireStatus(response.status, &.{.ok});
        var parsed = std.json.parseFromSlice(Jwks, self.allocator, response.body, .{
            .allocate = .alloc_always,
        }) catch return error.InvalidSignerJwks;
        errdefer parsed.deinit();
        if (parsed.value.keys.len == 0 or parsed.value.keys.len > 17) return error.InvalidSignerJwks;
        for (parsed.value.keys, 0..) |key, index| {
            if (!std.mem.eql(u8, key.kty, "OKP") or
                !std.mem.eql(u8, key.crv, "Ed25519") or
                (key.use != null and !std.mem.eql(u8, key.use.?, "sig")) or
                (key.alg != null and !std.mem.eql(u8, key.alg.?, "EdDSA")) or
                key.kid.len < 16 or key.kid.len > 128 or !validBase64Url(key.kid) or
                key.x.len != 43 or !validBase64Url(key.x))
            {
                return error.InvalidSignerJwks;
            }
            for (parsed.value.keys[0..index]) |prior| {
                if (std.mem.eql(u8, prior.kid, key.kid)) return error.InvalidSignerJwks;
            }
        }
        return parsed;
    }

    pub fn authenticatedJson(
        self: Client,
        method: std.http.Method,
        path: []const u8,
        bearer_token: []const u8,
        body: []const u8,
        accepted: []const std.http.Status,
    ) !Response {
        const url = try self.urlAlloc(path);
        defer self.allocator.free(url);
        var response = try self.transport.send(self.allocator, .{
            .method = method,
            .url = url,
            .bearer_token = bearer_token,
            .body = body,
        });
        errdefer response.deinit(self.allocator);
        try requireStatus(response.status, accepted);
        return response;
    }

    fn urlAlloc(self: Client, path: []const u8) ![]u8 {
        if (!std.mem.startsWith(u8, path, "/") or std.mem.startsWith(u8, path, "//")) {
            return error.InvalidControlPlanePath;
        }
        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
    }
};

pub fn validateDiscovery(base_url: []const u8, discovery: Discovery) !void {
    if (!std.mem.eql(u8, discovery.contract_version, connect.CONTRACT_VERSION) or
        !std.mem.eql(u8, discovery.api_base_url, base_url) or
        !validHttpsUrl(discovery.issuer) or
        !validHttpsUrl(discovery.jwks_uri) or
        !validHttpsUrl(discovery.signer_metadata_url) or
        !validHttpsUrl(discovery.oidc.issuer) or
        !validHttpsUrl(discovery.oidc.authorization_endpoint) or
        !validHttpsUrl(discovery.oidc.token_endpoint)) return error.InvalidConnectDiscovery;
    if (discovery.oidc.device_authorization_endpoint) |url| {
        if (!validHttpsUrl(url)) return error.InvalidConnectDiscovery;
    }
    if (discovery.oidc.code_challenge_methods_supported.len != 1 or
        !std.mem.eql(u8, discovery.oidc.code_challenge_methods_supported[0], "S256") or
        discovery.oidc.public_client.client_id.len == 0 or
        discovery.oidc.public_client.client_id.len > 255 or
        discovery.oidc.public_client.scopes.len == 0 or discovery.oidc.public_client.scopes.len > 16 or
        discovery.oidc.public_client.redirect_uris.len == 0 or discovery.oidc.public_client.redirect_uris.len > 16 or
        !std.mem.eql(u8, discovery.oidc.public_client.response_type, "code") or
        !std.mem.eql(u8, discovery.oidc.public_client.token_endpoint_auth_method, "none"))
    {
        return error.InvalidConnectDiscovery;
    }
    if (discovery.oidc.headless_authorization.supported) {
        if (discovery.oidc.device_authorization_endpoint == null or
            discovery.oidc.headless_authorization.grant_type == null or
            !std.mem.eql(u8, discovery.oidc.headless_authorization.grant_type.?, "urn:ietf:params:oauth:grant-type:device_code"))
        {
            return error.InvalidConnectDiscovery;
        }
    } else if (discovery.oidc.headless_authorization.grant_type != null) {
        return error.InvalidConnectDiscovery;
    }
    try validateUniqueBounded(discovery.oidc.public_client.scopes, 128);
    try validateUniqueUris(discovery.oidc.public_client.redirect_uris);
    const known_capabilities = [_][]const u8{
        "runtime-link-proof-ed25519",      "inventory-v1",      "bootstrap-grant-eddsa",
        "connector-credential-jwe-x25519", "endpoint-external", "endpoint-noop-test",
        "audit-export-v1",
    };
    try validateKnownUnique(discovery.capabilities, &known_capabilities);
    inline for (.{
        "runtime-link-proof-ed25519",
        "inventory-v1",
        "bootstrap-grant-eddsa",
        "connector-credential-jwe-x25519",
        "endpoint-external",
    }) |required| if (!contains(discovery.capabilities, required)) return error.ConnectCapabilityMissing;
}

fn validateRequest(request: Request) !void {
    if (!validHttpsUrl(request.url)) return error.InvalidControlPlaneUrl;
    if (request.timeout_ms <= 0 or request.timeout_ms > 60_000) return error.InvalidControlPlaneTimeout;
    if (request.body) |body| if (body.len > MAX_REQUEST_BYTES) return error.ControlPlaneRequestTooLarge;
    if (request.bearer_token) |token| {
        if (token.len < 32 or token.len > 4096) return error.InvalidConnectCredential;
        for (token) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidConnectCredential;
    }
}

fn validHttpsUrl(value: []const u8) bool {
    if (value.len > 2048) return false;
    for (value) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    const uri = std.Uri.parse(value) catch return false;
    return std.mem.eql(u8, uri.scheme, "https") and
        uri.host != null and !uri.host.?.isEmpty() and
        uri.user == null and uri.password == null and
        uri.query == null and uri.fragment == null;
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}

fn validateUniqueBounded(values: []const []const u8, maximum_length: usize) !void {
    for (values, 0..) |value, index| {
        if (value.len == 0 or value.len > maximum_length) return error.InvalidConnectDiscovery;
        for (values[0..index]) |prior| if (std.mem.eql(u8, prior, value)) return error.InvalidConnectDiscovery;
    }
}

fn validateUniqueUris(values: []const []const u8) !void {
    for (values, 0..) |value, index| {
        if (value.len == 0 or value.len > 2048) return error.InvalidConnectDiscovery;
        const uri = std.Uri.parse(value) catch return error.InvalidConnectDiscovery;
        if (uri.scheme.len == 0) return error.InvalidConnectDiscovery;
        for (values[0..index]) |prior| if (std.mem.eql(u8, prior, value)) return error.InvalidConnectDiscovery;
    }
}

fn validateKnownUnique(values: []const []const u8, known: []const []const u8) !void {
    for (values, 0..) |value, index| {
        if (!contains(known, value)) return error.InvalidConnectDiscovery;
        for (values[0..index]) |prior| if (std.mem.eql(u8, prior, value)) return error.InvalidConnectDiscovery;
    }
}

fn validBase64Url(value: []const u8) bool {
    for (value) |byte| switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

fn requireStatus(actual: std.http.Status, accepted: []const std.http.Status) !void {
    for (accepted) |status| if (actual == status) return;
    return switch (actual) {
        .unauthorized, .forbidden => error.ConnectAuthenticationRejected,
        .conflict => error.ConnectConflict,
        .too_many_requests => error.ConnectRateLimited,
        .service_unavailable, .bad_gateway, .gateway_timeout => error.ConnectUnavailable,
        else => error.ControlPlaneRejected,
    };
}

fn isRedirect(status: std.http.Status) bool {
    return switch (status) {
        .moved_permanently, .found, .see_other, .temporary_redirect, .permanent_redirect => true,
        else => false,
    };
}

const FakeTransport = struct {
    body: []const u8,
    status: std.http.Status = .ok,
    saw_bearer: bool = false,

    fn transport(self: *FakeTransport) Transport {
        return .{ .context = self, .send_fn = send };
    }

    fn send(raw: *anyopaque, allocator: std.mem.Allocator, request: Request) !Response {
        const self: *FakeTransport = @ptrCast(@alignCast(raw));
        self.saw_bearer = request.bearer_token != null;
        return .{ .status = self.status, .body = try allocator.dupe(u8, self.body) };
    }
};

test "strict discovery pins base, issuer metadata, and headless auth semantics" {
    const body =
        \\{"contract_version":"1","issuer":"https://connect.example.test","api_base_url":"https://connect.example.test","oidc":{"issuer":"https://id.example.test","authorization_endpoint":"https://id.example.test/auth","token_endpoint":"https://id.example.test/token","device_authorization_endpoint":"https://id.example.test/device","code_challenge_methods_supported":["S256"],"public_client":{"client_id":"verde","scopes":["openid"],"redirect_uris":["http://127.0.0.1:48123/callback"],"response_type":"code","token_endpoint_auth_method":"none"},"headless_authorization":{"supported":true,"grant_type":"urn:ietf:params:oauth:grant-type:device_code"}},"jwks_uri":"https://connect.example.test/v1/.well-known/jwks.json","signer_metadata_url":"https://connect.example.test/v1/signer-metadata","capabilities":["runtime-link-proof-ed25519","inventory-v1","bootstrap-grant-eddsa","connector-credential-jwe-x25519","endpoint-external"]}
    ;
    var fake: FakeTransport = .{ .body = body };
    const client = try Client.init(std.testing.allocator, fake.transport(), "https://connect.example.test");
    var discovery = try client.discover();
    defer discovery.deinit();
    try std.testing.expect(discovery.value().oidc.headless_authorization.supported);
    try std.testing.expect(!fake.saw_bearer);
}

test "HTTP request policy rejects redirects, proxies by construction, and oversized bodies" {
    try std.testing.expectError(error.InvalidControlPlaneUrl, validateRequest(.{ .method = .GET, .url = "http://connect.example.test" }));
    try std.testing.expectError(error.InvalidControlPlaneUrl, validateRequest(.{ .method = .GET, .url = "https:///missing-host" }));
    try std.testing.expectError(error.InvalidControlPlaneUrl, validateRequest(.{ .method = .GET, .url = "https://user@connect.example.test" }));
    try std.testing.expectError(error.ControlPlaneRequestTooLarge, validateRequest(.{
        .method = .POST,
        .url = "https://connect.example.test/v1/runtime-links",
        .body = &([_]u8{'x'} ** (MAX_REQUEST_BYTES + 1)),
    }));
    try std.testing.expect(isRedirect(.temporary_redirect));
}
