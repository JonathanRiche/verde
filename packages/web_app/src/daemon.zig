//! Unix-socket JSON-RPC transport to the session daemon and optional Live socket.

const std = @import("std");
const headless = @import("headless");

const config_mod = @import("config.zig");
const mock = @import("mock.zig");

const protocol = headless.protocol;

const log = std.log.scoped(.web_daemon);

pub const Source = enum { daemon, live, mock };

pub const CallResult = struct {
    json: []u8,
    source: Source,
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
        // Detached UIs read the headless daemon. Live is only a last-resort
        // fallback for methods the sessionizer does not implement.
        if (tryUnix(self.io, self.allocator, self.config.sessionizer_endpoint, request_json)) |json| {
            if (isUnknownMethod(json)) {
                self.allocator.free(json);
            } else {
                return .{ .json = json, .source = .daemon };
            }
        } else |_| {}

        if (tryUnix(self.io, self.allocator, self.config.live_endpoint, request_json)) |json| {
            return .{ .json = json, .source = .live };
        } else |_| {}

        if (!self.config.allow_mock) return error.DaemonUnavailable;
        return .{
            .json = try mock.respond(self.allocator, request_json),
            .source = .mock,
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

    pub fn probe(self: *Daemon) Source {
        if (endpointExists(self.io, self.config.sessionizer_endpoint)) return .daemon;
        if (endpointExists(self.io, self.config.live_endpoint)) return .live;
        return .mock;
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
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    errdefer allocating.deinit();
    _ = reader.interface.streamDelimiter(&allocating.writer, '\n') catch |err| switch (err) {
        error.EndOfStream => {
            if (allocating.written().len == 0) return error.ConnectionAborted;
        },
        else => return err,
    };
    if (reader.interface.bufferedLen() > 0) {
        _ = reader.interface.takeByte() catch {};
    }
    return try allocating.toOwnedSlice();
}

fn isUnknownMethod(json: []const u8) bool {
    return std.mem.indexOf(u8, json, "\"unknown_method\"") != null or
        std.mem.indexOf(u8, json, "\"method_not_found\"") != null;
}

fn endpointExists(io: std.Io, path: []const u8) bool {
    if (path.len == 0) return false;
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "unknown-method detector" {
    try std.testing.expect(isUnknownMethod("{\"error\":{\"code\":\"unknown_method\"}}"));
    try std.testing.expect(!isUnknownMethod("{\"result\":{}}"));
}

test "daemon-first probe prefers the sessionizer socket path" {
    try std.testing.expect(isUnknownMethod("{\"error\":{\"code\":\"unknown_method\"}}"));
    try std.testing.expect(isUnknownMethod("{\"error\":{\"code\":\"method_not_found\"}}"));
}

test {
    _ = protocol;
    _ = mock;
}
