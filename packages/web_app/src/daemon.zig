//! Unix-socket JSON-RPC transport to the authoritative session daemon.

const std = @import("std");
const headless = @import("headless");

const config_mod = @import("config.zig");

const protocol = headless.protocol;

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
        defer self.allocator.free(request_json);
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
        defer self.allocator.free(request_json);
        return self.callRaw(request_json);
    }
};

fn tryUnix(io: std.Io, allocator: std.mem.Allocator, endpoint: []const u8, request_json: []const u8) ![]u8 {
    if (endpoint.len == 0) return error.FileNotFound;
    const address = std.Io.net.UnixAddress.init(endpoint) catch return error.NameTooLong;
    var stream = address.connect(io) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied => return error.FileNotFound,
        else => return err,
    };
    defer stream.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(request_json);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();

    var read_buf: [64 * 1024]u8 = undefined;
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
    errdefer allocating.deinit();
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
