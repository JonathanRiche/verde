//! Transport-independent headless method dispatcher.
//!
//! Takes method + params + a small context filled by the daemon host. Imports no
//! daemon code so the headless package stays free of SDL/Palette/sessionizer.

const std = @import("std");
const protocol = @import("protocol.zig");

/// Daemon-filled snapshot for core.* methods. No pointers into daemon types.
pub const Context = struct {
    pid: u32,
    sessionizer_protocol_version: u32,
    session_count: usize,
    chat_turn_count: usize,
};

/// Dispatcher outcome: structured result payloads or a stable protocol error.
pub const Response = struct {
    id: u64,
    body: Body,

    pub const Body = union(enum) {
        status: protocol.StatusResult,
        capabilities: protocol.CapabilitiesResult,
        err: protocol.Error,
    };

    pub fn isOk(self: Response) bool {
        return switch (self.body) {
            .err => false,
            else => true,
        };
    }
};

/// Dispatch a core.* (or other headless) method. Unknown methods return unknown_method.
pub fn dispatch(
    id: u64,
    method: []const u8,
    params: std.json.Value,
    ctx: Context,
) Response {
    if (!paramsAreAcceptable(params)) {
        return .{
            .id = id,
            .body = .{ .err = .{
                .code = protocol.ERR_INVALID_PARAMS,
                .message = "params must be an object or null",
            } },
        };
    }

    if (std.mem.eql(u8, method, "core.status")) {
        return .{
            .id = id,
            .body = .{ .status = buildStatus(ctx) },
        };
    }
    if (std.mem.eql(u8, method, "core.capabilities")) {
        return .{
            .id = id,
            .body = .{ .capabilities = buildCapabilities() },
        };
    }

    return .{
        .id = id,
        .body = .{ .err = .{
            .code = protocol.ERR_UNKNOWN_METHOD,
            .message = "unknown method",
        } },
    };
}

fn buildStatus(ctx: Context) protocol.StatusResult {
    return .{
        .headless_protocol_version = protocol.HEADLESS_PROTOCOL_VERSION,
        .min_supported = protocol.MIN_SUPPORTED_PROTOCOL_VERSION,
        .max_supported = protocol.MAX_SUPPORTED_PROTOCOL_VERSION,
        .protocol_version = ctx.sessionizer_protocol_version,
        .pid = ctx.pid,
        .session_count = ctx.session_count,
        .chat_turn_count = ctx.chat_turn_count,
        .capabilities = .phase1(),
    };
}

fn buildCapabilities() protocol.CapabilitiesResult {
    return .{
        .headless_protocol_version = protocol.HEADLESS_PROTOCOL_VERSION,
        .min_supported = protocol.MIN_SUPPORTED_PROTOCOL_VERSION,
        .max_supported = protocol.MAX_SUPPORTED_PROTOCOL_VERSION,
        .capabilities = .phase1(),
    };
}

/// Params may be null or an object; unknown object fields are ignored by callers.
fn paramsAreAcceptable(params: std.json.Value) bool {
    return switch (params) {
        .null, .object => true,
        else => false,
    };
}

fn fakeContext() Context {
    return .{
        .pid = 4242,
        .sessionizer_protocol_version = 18,
        .session_count = 3,
        .chat_turn_count = 5,
    };
}

test "core.status happy path with fake context" {
    const response = dispatch(1, "core.status", .null, fakeContext());
    try std.testing.expect(response.isOk());
    const status = response.body.status;
    try std.testing.expectEqual(protocol.HEADLESS_PROTOCOL_VERSION, status.headless_protocol_version);
    try std.testing.expectEqual(protocol.MIN_SUPPORTED_PROTOCOL_VERSION, status.min_supported);
    try std.testing.expectEqual(protocol.MAX_SUPPORTED_PROTOCOL_VERSION, status.max_supported);
    try std.testing.expectEqual(@as(u32, 18), status.protocol_version);
    try std.testing.expectEqual(@as(u32, 4242), status.pid);
    try std.testing.expectEqual(@as(usize, 3), status.session_count);
    try std.testing.expectEqual(@as(usize, 5), status.chat_turn_count);
    try std.testing.expect(status.capabilities.terminal_raw);
    try std.testing.expect(!status.capabilities.chat);
    try std.testing.expect(!status.capabilities.terminal_grid);
    try std.testing.expect(!status.capabilities.processes);
    try std.testing.expect(!status.capabilities.leases);
    try std.testing.expect(!status.capabilities.browser_execution);
    try std.testing.expect(!status.capabilities.browser_presentation);
}

test "core.capabilities content" {
    var empty_object: std.json.ObjectMap = .empty;
    defer empty_object.deinit(std.testing.allocator);
    // Object with no fields — and any future fields would be ignored by dispatch.
    const params: std.json.Value = .{ .object = empty_object };
    const response = dispatch(2, "core.capabilities", params, fakeContext());
    try std.testing.expect(response.isOk());
    const caps = response.body.capabilities;
    try std.testing.expectEqual(protocol.HEADLESS_PROTOCOL_VERSION, caps.headless_protocol_version);
    try std.testing.expectEqual(protocol.MIN_SUPPORTED_PROTOCOL_VERSION, caps.min_supported);
    try std.testing.expectEqual(protocol.MAX_SUPPORTED_PROTOCOL_VERSION, caps.max_supported);
    try std.testing.expect(caps.capabilities.terminal_raw);
    try std.testing.expect(!caps.capabilities.browser_presentation);
}

test "unknown method yields unknown_method" {
    const response = dispatch(3, "core.snapshot", .null, fakeContext());
    try std.testing.expect(!response.isOk());
    try std.testing.expectEqualStrings(protocol.ERR_UNKNOWN_METHOD, response.body.err.code);
}

test "invalid params yields invalid_params" {
    const response = dispatch(4, "core.status", .{ .string = "nope" }, fakeContext());
    try std.testing.expect(!response.isOk());
    try std.testing.expectEqualStrings(protocol.ERR_INVALID_PARAMS, response.body.err.code);
}

test "params object with unknown fields is accepted" {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "future_field", .{ .bool = true });
    const response = dispatch(5, "core.status", .{ .object = obj }, fakeContext());
    try std.testing.expect(response.isOk());
}
