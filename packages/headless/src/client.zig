//! Transport-neutral typed client for the headless protocol.
//!
//! Builds request envelopes and parses response envelopes. The caller injects
//! a send function so unit tests need no sockets or daemon process.

const std = @import("std");
const protocol = @import("protocol.zig");

/// Sends one request JSON document and returns an allocator-owned response JSON document.
pub const TransportFn = *const fn (ctx: *anyopaque, request_json: []const u8) anyerror![]u8;

pub const Client = struct {
    allocator: std.mem.Allocator,
    transport_ctx: *anyopaque,
    transport: TransportFn,
    next_id: u64 = 1,

    pub fn init(
        allocator: std.mem.Allocator,
        transport_ctx: *anyopaque,
        transport: TransportFn,
    ) Client {
        return .{
            .allocator = allocator,
            .transport_ctx = transport_ctx,
            .transport = transport,
        };
    }

    /// Encode a typed request, hand it to the transport, and parse the envelope.
    /// Caller owns the returned ParsedResponse and must call deinit.
    pub fn call(self: *Client, method: []const u8, params: anytype) !protocol.ParsedResponse {
        const id = self.next_id;
        self.next_id += 1;
        const request_json = try protocol.encodeRequest(self.allocator, id, method, params);
        defer self.allocator.free(request_json);

        const response_json = try self.transport(self.transport_ctx, request_json);
        defer self.allocator.free(response_json);

        return try protocol.parseResponse(self.allocator, response_json);
    }

    /// Build a request envelope without sending (useful for custom transports).
    pub fn encodeRequest(self: *Client, method: []const u8, params: anytype) !struct { id: u64, json: []u8 } {
        const id = self.next_id;
        self.next_id += 1;
        const json = try protocol.encodeRequest(self.allocator, id, method, params);
        return .{ .id = id, .json = json };
    }

    /// Parse a response envelope produced by any transport.
    pub fn parseResponse(self: *Client, response_json: []const u8) !protocol.ParsedResponse {
        return try protocol.parseResponse(self.allocator, response_json);
    }
};

const MockTransport = struct {
    allocator: std.mem.Allocator,
    last_request: ?[]u8 = null,
    canned_response: []const u8,

    fn deinit(self: *MockTransport) void {
        if (self.last_request) |bytes| self.allocator.free(bytes);
    }

    fn send(ctx: *anyopaque, request_json: []const u8) anyerror![]u8 {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        if (self.last_request) |bytes| self.allocator.free(bytes);
        self.last_request = try self.allocator.dupe(u8, request_json);
        return try self.allocator.dupe(u8, self.canned_response);
    }
};

test "client parses ok envelope via injected transport" {
    const allocator = std.testing.allocator;
    const ok_body = try protocol.encodeOkResponse(allocator, 1, .{
        .headless_protocol_version = protocol.HEADLESS_PROTOCOL_VERSION,
        .min_supported = protocol.MIN_SUPPORTED_PROTOCOL_VERSION,
        .max_supported = protocol.MAX_SUPPORTED_PROTOCOL_VERSION,
        .capabilities = protocol.Capabilities.phase1(),
    });
    defer allocator.free(ok_body);

    var mock: MockTransport = .{
        .allocator = allocator,
        .canned_response = ok_body,
    };
    defer mock.deinit();

    var client = Client.init(allocator, &mock, MockTransport.send);
    var parsed = try client.call("core.capabilities", .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.response.isOk());
    try std.testing.expectEqual(@as(u64, 1), parsed.response.id);
    try std.testing.expect(parsed.response.result.?.object.get("capabilities") != null);
    try std.testing.expect(mock.last_request != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_request.?, "core.capabilities") != null);
}

test "client parses error envelope via injected transport" {
    const allocator = std.testing.allocator;
    const err_body = try protocol.encodeErrorResponse(
        allocator,
        1,
        protocol.ERR_UNKNOWN_METHOD,
        "unknown method",
    );
    defer allocator.free(err_body);

    var mock: MockTransport = .{
        .allocator = allocator,
        .canned_response = err_body,
    };
    defer mock.deinit();

    var client = Client.init(allocator, &mock, MockTransport.send);
    var parsed = try client.call("core.nope", .{});
    defer parsed.deinit();

    try std.testing.expect(!parsed.response.isOk());
    try std.testing.expectEqualStrings(protocol.ERR_UNKNOWN_METHOD, parsed.response.err.?.code);
}

test "client encodeRequest assigns monotonic ids" {
    const allocator = std.testing.allocator;
    var mock: MockTransport = .{
        .allocator = allocator,
        .canned_response = "{}",
    };
    defer mock.deinit();
    var client = Client.init(allocator, &mock, MockTransport.send);

    const first = try client.encodeRequest("core.status", .{});
    defer allocator.free(first.json);
    const second = try client.encodeRequest("core.capabilities", .{});
    defer allocator.free(second.json);

    try std.testing.expectEqual(@as(u64, 1), first.id);
    try std.testing.expectEqual(@as(u64, 2), second.id);
}
