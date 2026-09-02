//! Unix-socket JSON-RPC transport to the authoritative session daemon.

const std = @import("std");
const headless = @import("headless");

const config_mod = @import("config.zig");

const protocol = headless.protocol;
const access_protocol = headless.access_protocol;
const connect_protocol = headless.connect_protocol;

const INITIAL_RESPONSE_CAPACITY: usize = 64 * 1024;
pub const MAX_GATEWAY_RPC_BYTES: usize = 1024 * 1024;

pub const CallResult = struct {
    json: []u8,
};

pub const Daemon = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod,
    next_id: std.atomic.Value(u64) = .init(1),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: config_mod) Daemon {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
        };
    }

    pub fn callRaw(self: *Daemon, request_json: []const u8) !CallResult {
        return self.callRawWith(request_json, tryUnix);
    }

    fn callRawWith(self: *Daemon, request_json: []const u8, unix_request: anytype) !CallResult {
        if (request_json.len == 0 or request_json.len > MAX_GATEWAY_RPC_BYTES) {
            return error.RequestTooLarge;
        }
        return .{
            .json = try unix_request(
                self.io,
                self.allocator,
                self.config.sessionizer_endpoint,
                request_json,
            ),
        };
    }

    /// Anonymous `.{}` is an empty tuple and stringifies as `[]`. Core methods
    /// reject that; this typed object stringifies as `{}`.
    pub const EmptyObject = struct {};

    pub fn callMethod(self: *Daemon, method: []const u8, params: anytype) !CallResult {
        const id = self.next_id.fetchAdd(1, .monotonic);
        var client = headless.Client.initEncoder(self.allocator);
        const request_json = try client.encodeRequestWithId(id, method, params);
        defer {
            std.crypto.secureZero(u8, request_json);
            self.allocator.free(request_json);
        }
        return self.callRaw(request_json);
    }

    /// Call the local daemon while binding the request to the runtime
    /// generation learned by an authenticated network session. The target is
    /// copied into the encoder and cannot be omitted by the individual call.
    pub fn callMethodTargeted(
        self: *Daemon,
        method: []const u8,
        params: anytype,
        target: protocol.RequestTarget,
    ) !CallResult {
        const id = self.next_id.fetchAdd(1, .monotonic);
        var client = try headless.Client.initTargetedEncoder(self.allocator, target);
        const request_json = try client.encodeRequestWithId(id, method, params);
        defer {
            std.crypto.secureZero(u8, request_json);
            self.allocator.free(request_json);
        }
        return self.callRaw(request_json);
    }

    /// Send the one Pair bridge request whose plaintext grant secret must be
    /// deliberately encoded rather than passed through generic redaction.
    pub fn callPairingExchangeTargeted(
        self: *Daemon,
        request: access_protocol.PairingGrantExchangeRequest,
        target: protocol.RequestTarget,
    ) !CallResult {
        return self.callSecretMethodTargetedWith(.{ .pairing_exchange = request }, target, tryUnix);
    }

    /// Send the one device-auth bridge request whose plaintext credential
    /// must be deliberately encoded rather than passed through redaction.
    pub fn callDeviceAuthenticateTargeted(
        self: *Daemon,
        request: access_protocol.DeviceAuthenticateRequest,
        target: protocol.RequestTarget,
    ) !CallResult {
        return self.callSecretMethodTargetedWith(.{ .device_authenticate = request }, target, tryUnix);
    }

    /// Send the signed Connect bootstrap grant only through the explicit
    /// secret-bearing private daemon encoder.
    pub fn callConnectBootstrapTargeted(
        self: *Daemon,
        request: connect_protocol.BootstrapConsumeRequest,
        target: protocol.RequestTarget,
    ) !CallResult {
        return self.callSecretMethodTargetedWith(.{ .connect_bootstrap = request }, target, tryUnix);
    }

    fn callSecretMethodTargetedWith(
        self: *Daemon,
        request: SecretBridgeRequest,
        target: protocol.RequestTarget,
        unix_request: anytype,
    ) !CallResult {
        const id = self.next_id.fetchAdd(1, .monotonic);
        const request_json = try encodeSecretTargetedRequest(self.allocator, id, request, target);
        defer {
            std.crypto.secureZero(u8, request_json);
            self.allocator.free(request_json);
        }
        return self.callRawWith(request_json, unix_request);
    }
};

const SecretBridgeRequest = union(enum) {
    pairing_exchange: access_protocol.PairingGrantExchangeRequest,
    device_authenticate: access_protocol.DeviceAuthenticateRequest,
    connect_bootstrap: connect_protocol.BootstrapConsumeRequest,
};

/// Encode only the three private-daemon requests that intentionally reveal a
/// secret. `access_protocol.Secret` remains redacted everywhere generic.
fn encodeSecretTargetedRequest(
    allocator: std.mem.Allocator,
    id: u64,
    request: SecretBridgeRequest,
    target: protocol.RequestTarget,
) ![]u8 {
    try protocol.validateRequestTarget(target);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer {
        std.crypto.secureZero(u8, writer.written());
        writer.deinit();
    }
    var json: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try json.beginObject();
    try json.objectField("id");
    try json.write(id);
    try json.objectField("method");
    try json.write(switch (request) {
        .pairing_exchange => access_protocol.METHOD_DAEMON_PAIRING_EXCHANGE,
        .device_authenticate => access_protocol.METHOD_DAEMON_DEVICE_AUTHENTICATE,
        .connect_bootstrap => connect_protocol.METHOD_BOOTSTRAP_CONSUME,
    });
    try json.objectField("params");
    try json.beginObject();
    switch (request) {
        .pairing_exchange => |params| {
            try json.objectField("access_protocol_version");
            try json.write(params.access_protocol_version);
            try json.objectField("grant_id");
            try json.write(params.grant_id);
            try json.objectField("pairing_token");
            try json.write(params.pairing_token.reveal());
            try json.objectField("device_label");
            try json.write(params.device_label);
        },
        .device_authenticate => |params| {
            try json.objectField("access_protocol_version");
            try json.write(params.access_protocol_version);
            try json.objectField("device_id");
            try json.write(params.device_id);
            try json.objectField("device_credential");
            try json.write(params.device_credential.reveal());
            try json.objectField("requested_scopes");
            try json.write(params.requested_scopes);
        },
        .connect_bootstrap => |params| {
            try json.objectField("connect_protocol_version");
            try json.write(params.connect_protocol_version);
            try json.objectField("grant_jwt");
            try json.write(params.grant_jwt.reveal());
            try json.objectField("expected_issuer");
            try json.write(params.expected_issuer);
            try json.objectField("expected_audience");
            try json.write(params.expected_audience);
            try json.objectField("client_nonce");
            try json.write(params.client_nonce);
            try json.objectField("device_id");
            try json.write(params.device_id);
            try json.objectField("device_key_thumbprint");
            try json.write(params.device_key_thumbprint);
            try json.objectField("device_label");
            try json.write(params.device_label);
        },
    }
    try json.endObject();
    try json.objectField("target");
    try json.write(target);
    try json.endObject();
    return try writer.toOwnedSlice();
}

fn tryUnix(io: std.Io, allocator: std.mem.Allocator, endpoint: []const u8, request_json: []const u8) ![]u8 {
    if (endpoint.len == 0) return error.FileNotFound;
    const address = std.Io.net.UnixAddress.init(endpoint) catch return error.NameTooLong;
    var stream = address.connect(io) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied => return error.FileNotFound,
        else => return err,
    };
    defer stream.close(io);

    var write_buf: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, write_buf[0..]);
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(request_json);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();

    var read_buf: [64 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, read_buf[0..]);
    var reader = stream.reader(io, &read_buf);
    return try readResponseAlloc(allocator, &reader.interface, MAX_GATEWAY_RPC_BYTES);
}

fn readResponseAlloc(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    max_response_bytes: usize,
) ![]u8 {
    std.debug.assert(max_response_bytes > 0 and max_response_bytes < std.math.maxInt(usize));
    var allocating = try std.Io.Writer.Allocating.initCapacity(
        allocator,
        @min(INITIAL_RESPONSE_CAPACITY, max_response_bytes + 1),
    );
    errdefer {
        std.crypto.secureZero(u8, allocating.written());
        allocating.deinit();
    }
    _ = reader.streamDelimiterLimit(&allocating.writer, '\n', .limited(max_response_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.ResponseTooLarge,
        else => return err,
    };
    if (allocating.written().len > max_response_bytes) return error.ResponseTooLarge;
    const delimiter = reader.takeByte() catch return error.ConnectionAborted;
    if (delimiter != '\n') return error.InvalidResponse;
    return try allocating.toOwnedSlice();
}

const TestTransport = struct {
    fn unavailable(
        _: std.Io,
        _: std.mem.Allocator,
        endpoint: []const u8,
        _: []const u8,
    ) ![]u8 {
        if (!std.mem.eql(u8, endpoint, "/sessionizer-only.sock")) return error.UnexpectedBackend;
        return error.FileNotFound;
    }

    fn failed(
        _: std.Io,
        _: std.mem.Allocator,
        endpoint: []const u8,
        _: []const u8,
    ) ![]u8 {
        if (!std.mem.eql(u8, endpoint, "/sessionizer-only.sock")) return error.UnexpectedBackend;
        return error.ConnectionResetByPeer;
    }

    fn unknownMethod(
        _: std.Io,
        allocator: std.mem.Allocator,
        endpoint: []const u8,
        _: []const u8,
    ) ![]u8 {
        if (!std.mem.eql(u8, endpoint, "/sessionizer-only.sock")) return error.UnexpectedBackend;
        return allocator.dupe(u8, "{\"id\":7,\"ok\":false,\"error\":{\"code\":\"unknown_method\"}}");
    }

    fn secretBridge(
        _: std.Io,
        allocator: std.mem.Allocator,
        endpoint: []const u8,
        request_json: []const u8,
    ) ![]u8 {
        if (!std.mem.eql(u8, endpoint, "/sessionizer-only.sock")) return error.UnexpectedBackend;
        var parsed = try headless.parseRequest(allocator, request_json);
        defer parsed.deinit();
        const params = parsed.request.params;
        if (params != .object or parsed.request.target == null) return error.InvalidRequest;
        if (std.mem.eql(u8, parsed.request.method, access_protocol.METHOD_DAEMON_PAIRING_EXCHANGE)) {
            try std.testing.expectEqualStrings(
                "a" ** access_protocol.SECRET_HEX_BYTES,
                params.object.get("pairing_token").?.string,
            );
        } else if (std.mem.eql(u8, parsed.request.method, access_protocol.METHOD_DAEMON_DEVICE_AUTHENTICATE)) {
            try std.testing.expectEqualStrings(
                "b" ** access_protocol.SECRET_HEX_BYTES,
                params.object.get("device_credential").?.string,
            );
        } else if (std.mem.eql(u8, parsed.request.method, connect_protocol.METHOD_BOOTSTRAP_CONSUME)) {
            try std.testing.expectEqualStrings(
                "header.payload.signature",
                params.object.get("grant_jwt").?.string,
            );
        } else return error.UnexpectedMethod;
        return allocator.dupe(u8, "{\"id\":1,\"result\":{}}");
    }
};

fn testDaemon() Daemon {
    const config: config_mod = .{
        .sessionizer_endpoint = "/sessionizer-only.sock",
    };
    return .init(std.testing.allocator, std.testing.io, config);
}

test "missing daemon fails without fallback" {
    var daemon = testDaemon();
    try std.testing.expectError(
        error.FileNotFound,
        daemon.callRawWith("{\"id\":1,\"method\":\"core.status\",\"params\":{}}", TestTransport.unavailable),
    );
}

test "empty daemon endpoint fails closed through the production transport" {
    var daemon = testDaemon();
    daemon.config.sessionizer_endpoint = "";
    try std.testing.expectError(
        error.FileNotFound,
        daemon.callRaw("{\"id\":1,\"method\":\"core.status\",\"params\":{}}"),
    );
}

test "daemon transport failure is returned without another backend" {
    var daemon = testDaemon();
    try std.testing.expectError(
        error.ConnectionResetByPeer,
        daemon.callRawWith("{\"id\":2,\"method\":\"chat.turn.start\",\"params\":{}}", TestTransport.failed),
    );
}

test "daemon response remains authoritative" {
    var daemon = testDaemon();
    const result = try daemon.callRawWith(
        "{\"id\":7,\"method\":\"future.method\",\"params\":{}}",
        TestTransport.unknownMethod,
    );
    defer std.testing.allocator.free(result.json);
    try std.testing.expectEqualStrings(
        "{\"id\":7,\"ok\":false,\"error\":{\"code\":\"unknown_method\"}}",
        result.json,
    );
}

test "access bridges deliberately reveal only transient daemon request secrets" {
    const target: protocol.RequestTarget = .{
        .runtime_id = "0123456789abcdef0123456789abcdef",
        .instance_id = "00112233445566778899aabbccddeeff",
    };
    const pairing_request: access_protocol.PairingGrantExchangeRequest = .{
        .access_protocol_version = access_protocol.ACCESS_PROTOCOL_VERSION,
        .grant_id = "fedcba9876543210fedcba9876543210",
        .pairing_token = .{ .bytes = "a" ** access_protocol.SECRET_HEX_BYTES },
        .device_label = "Test device",
    };
    const generic = try protocol.encodeTargetedRequest(
        std.testing.allocator,
        9,
        access_protocol.METHOD_DAEMON_PAIRING_EXCHANGE,
        pairing_request,
        target,
    );
    defer std.testing.allocator.free(generic);
    try std.testing.expect(std.mem.indexOf(u8, generic, "a" ** access_protocol.SECRET_HEX_BYTES) == null);
    try std.testing.expect(std.mem.indexOf(u8, generic, access_protocol.REDACTED_SECRET) != null);

    var daemon = testDaemon();
    const exchange_result = try daemon.callSecretMethodTargetedWith(
        .{ .pairing_exchange = pairing_request },
        target,
        TestTransport.secretBridge,
    );
    defer std.testing.allocator.free(exchange_result.json);

    const authenticate_request: access_protocol.DeviceAuthenticateRequest = .{
        .access_protocol_version = access_protocol.ACCESS_PROTOCOL_VERSION,
        .device_id = "0123456789abcdef0123456789abcdef",
        .device_credential = .{ .bytes = "b" ** access_protocol.SECRET_HEX_BYTES },
        .requested_scopes = &.{"runtime:read"},
    };
    const authenticate_result = try daemon.callSecretMethodTargetedWith(
        .{ .device_authenticate = authenticate_request },
        target,
        TestTransport.secretBridge,
    );
    defer std.testing.allocator.free(authenticate_result.json);

    const connect_secret = "header.payload.signature";
    const connect_request: connect_protocol.BootstrapConsumeRequest = .{
        .connect_protocol_version = connect_protocol.CONNECT_PROTOCOL_VERSION,
        .grant_jwt = .{ .bytes = connect_secret },
        .expected_issuer = "https://connect.example.test",
        .expected_audience = "https://runtime.example.test",
        .client_nonce = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        .device_id = "dev_33333333333333333333333333333333",
        .device_key_thumbprint = "kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k",
        .device_label = "Connect laptop",
    };
    const generic_connect = try protocol.encodeTargetedRequest(
        std.testing.allocator,
        10,
        connect_protocol.METHOD_BOOTSTRAP_CONSUME,
        connect_request,
        target,
    );
    defer std.testing.allocator.free(generic_connect);
    try std.testing.expect(std.mem.indexOf(u8, generic_connect, connect_secret) == null);
    const connect_result = try daemon.callSecretMethodTargetedWith(
        .{ .connect_bootstrap = connect_request },
        target,
        TestTransport.secretBridge,
    );
    defer std.testing.allocator.free(connect_result.json);
}

test "gateway request and response bounds are enforced" {
    var daemon = testDaemon();
    const oversized = try std.testing.allocator.alloc(u8, MAX_GATEWAY_RPC_BYTES + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'a');
    try std.testing.expectError(error.RequestTooLarge, daemon.callRawWith(oversized, TestTransport.failed));

    var at_limit = std.Io.Reader.fixed("12345678\n");
    const response = try readResponseAlloc(std.testing.allocator, &at_limit, 8);
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings("12345678", response);

    var too_large = std.Io.Reader.fixed("123456789\n");
    try std.testing.expectError(
        error.ResponseTooLarge,
        readResponseAlloc(std.testing.allocator, &too_large, 8),
    );

    var unterminated = std.Io.Reader.fixed("{}");
    try std.testing.expectError(
        error.ConnectionAborted,
        readResponseAlloc(std.testing.allocator, &unterminated, 8),
    );
}

test {
    _ = protocol;
}
