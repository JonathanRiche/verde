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
    transport_ctx: ?*anyopaque,
    transport: ?TransportFn,
    next_id: u64 = 1,
    negotiated_version: ?u32 = null,

    /// Successful `core.status` handshake result. Requests remain wire-compatible;
    /// the selected protocol version exists only in client state this milestone.
    pub const HandshakeResult = struct {
        status: protocol.StatusResult,
        negotiated_version: u32,
    };

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

    /// Creates an encoder/parser-only client for adapters that own transport.
    pub fn initEncoder(allocator: std.mem.Allocator) Client {
        return .{
            .allocator = allocator,
            .transport_ctx = null,
            .transport = null,
        };
    }

    /// Encode a typed request, hand it to the transport, and parse the envelope.
    /// Caller owns the returned ParsedResponse and must call deinit.
    pub fn call(self: *Client, method: []const u8, params: anytype) !protocol.ParsedResponse {
        const id = self.next_id;
        self.next_id += 1;
        return try self.callWithId(id, method, params);
    }

    /// Encode and send a request with the caller's existing request id.
    pub fn callWithId(self: *Client, id: u64, method: []const u8, params: anytype) !protocol.ParsedResponse {
        const request_json = try self.encodeRequestWithId(id, method, params);
        defer self.allocator.free(request_json);

        const response_json = try self.send(request_json);
        defer self.allocator.free(response_json);

        return try self.parseResponseWithId(id, response_json);
    }

    /// Result of a call when the transport adapter must return the original response bytes.
    pub const CallResult = struct {
        response_json: ?[]u8,
        parsed: protocol.ParsedResponse,

        pub fn takeResponse(self: *CallResult) []u8 {
            const response_json = self.response_json orelse unreachable;
            self.response_json = null;
            return response_json;
        }

        pub fn deinit(self: *CallResult, allocator: std.mem.Allocator) void {
            self.parsed.deinit();
            if (self.response_json) |response_json| allocator.free(response_json);
            self.* = undefined;
        }
    };

    /// Encode, send, and parse while retaining ownership of the original response JSON.
    pub fn callAllocWithId(self: *Client, id: u64, method: []const u8, params: anytype) !CallResult {
        const request_json = try self.encodeRequestWithId(id, method, params);
        defer self.allocator.free(request_json);

        const response_json = try self.send(request_json);
        errdefer self.allocator.free(response_json);
        var parsed = try self.parseResponseWithId(id, response_json);
        errdefer parsed.deinit();
        return .{
            .response_json = response_json,
            .parsed = parsed,
        };
    }

    /// Build a request envelope without sending (useful for custom transports).
    pub fn encodeRequest(self: *Client, method: []const u8, params: anytype) !struct { id: u64, json: []u8 } {
        const id = self.next_id;
        self.next_id += 1;
        const json = try self.encodeRequestWithId(id, method, params);
        return .{ .id = id, .json = json };
    }

    /// Build a request envelope with an explicit id without advancing the generated id.
    pub fn encodeRequestWithId(self: *Client, id: u64, method: []const u8, params: anytype) ![]u8 {
        return try protocol.encodeRequest(self.allocator, id, method, params);
    }

    /// Parse a response envelope produced by any transport.
    pub fn parseResponse(self: *Client, response_json: []const u8) !protocol.ParsedResponse {
        return try protocol.parseResponse(self.allocator, response_json);
    }

    /// Parse and correlate a response with the request that produced it.
    /// Numeric mismatches return `error.ResponseIdMismatch`; null-id errors are
    /// uncorrelated daemon failures and remain valid error responses.
    pub fn parseResponseWithId(self: *Client, request_id: u64, response_json: []const u8) !protocol.ParsedResponse {
        var parsed = try protocol.parseResponse(self.allocator, response_json);
        errdefer parsed.deinit();
        if (parsed.response.id) |response_id| {
            if (response_id != request_id) return error.ResponseIdMismatch;
        }
        return parsed;
    }

    /// Perform the client-side protocol handshake using the daemon's advertised
    /// `core.status` range. Call this before normal calls when using `Client` as
    /// a long-lived connection; no negotiation fields are added to requests.
    pub fn handshake(self: *Client) !HandshakeResult {
        const empty_params: struct {} = .{};
        var parsed = try self.call("core.status", empty_params);
        defer parsed.deinit();
        const status = try self.decodeStatus(&parsed);
        return .{
            .status = status,
            .negotiated_version = self.negotiated_version.?,
        };
    }

    /// Return the version selected by the most recent successful status or
    /// capabilities decode. Before a successful handshake this returns
    /// `error.HandshakeRequired`.
    pub fn negotiatedProtocolVersion(self: *const Client) !u32 {
        return self.negotiated_version orelse error.HandshakeRequired;
    }

    /// Decode a successful `core.status` response into its typed result.
    pub fn decodeStatus(self: *Client, parsed: *const protocol.ParsedResponse) !protocol.StatusResult {
        const result = try self.resultValue(parsed);
        const status = try std.json.parseFromValueLeaky(protocol.StatusResult, self.allocator, result, .{
            .ignore_unknown_fields = true,
        });
        _ = try self.recordNegotiatedRange(status.min_supported, status.max_supported);
        return status;
    }

    /// Decode a successful `core.capabilities` response into its typed result.
    pub fn decodeCapabilities(self: *Client, parsed: *const protocol.ParsedResponse) !protocol.CapabilitiesResult {
        const result = try self.resultValue(parsed);
        const capabilities = try std.json.parseFromValueLeaky(protocol.CapabilitiesResult, self.allocator, result, .{
            .ignore_unknown_fields = true,
        });
        _ = try self.recordNegotiatedRange(capabilities.min_supported, capabilities.max_supported);
        return capabilities;
    }

    fn recordNegotiatedRange(self: *Client, daemon_min: u32, daemon_max: u32) !u32 {
        self.negotiated_version = null;
        const negotiated_version = try protocol.negotiateProtocolVersion(
            .{
                .min = protocol.MIN_SUPPORTED_PROTOCOL_VERSION,
                .max = protocol.MAX_SUPPORTED_PROTOCOL_VERSION,
            },
            .{ .min = daemon_min, .max = daemon_max },
        );
        self.negotiated_version = negotiated_version;
        return negotiated_version;
    }

    fn resultValue(_: *Client, parsed: *const protocol.ParsedResponse) !std.json.Value {
        if (!parsed.response.isOk()) return error.RemoteError;
        return parsed.response.result orelse error.InvalidResponse;
    }

    fn send(self: *Client, request_json: []const u8) ![]u8 {
        const transport = self.transport orelse return error.TransportUnavailable;
        const context = self.transport_ctx orelse return error.TransportUnavailable;
        return try transport(context, request_json);
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
    try std.testing.expectEqual(@as(?u64, 1), parsed.response.id);
    try std.testing.expect(parsed.response.result.?.object.get("capabilities") != null);
    const capabilities = try client.decodeCapabilities(&parsed);
    try std.testing.expectEqual(@as(u32, 1), capabilities.headless_protocol_version);
    try std.testing.expect(capabilities.capabilities.terminal_raw);
    try std.testing.expect(mock.last_request != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_request.?, "core.capabilities") != null);

    const status_body = try protocol.encodeOkResponse(allocator, 2, .{
        .headless_protocol_version = protocol.HEADLESS_PROTOCOL_VERSION,
        .min_supported = protocol.MIN_SUPPORTED_PROTOCOL_VERSION,
        .max_supported = protocol.MAX_SUPPORTED_PROTOCOL_VERSION,
        .protocol_version = 18,
        .pid = 4242,
        .session_count = 2,
        .chat_turn_count = 1,
        .capabilities = protocol.Capabilities.phase1(),
    });
    defer allocator.free(status_body);
    var parsed_status = try client.parseResponse(status_body);
    defer parsed_status.deinit();
    const status = try client.decodeStatus(&parsed_status);
    try std.testing.expectEqual(@as(u32, 18), status.protocol_version);
    try std.testing.expectEqual(@as(usize, 2), status.session_count);
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

test "client rejects mismatched response ids in both call paths" {
    const allocator = std.testing.allocator;
    const wrong_id_body = try protocol.encodeOkResponse(allocator, 99, .{ .ok = true });
    defer allocator.free(wrong_id_body);

    var mock: MockTransport = .{
        .allocator = allocator,
        .canned_response = wrong_id_body,
    };
    defer mock.deinit();

    var client = Client.init(allocator, &mock, MockTransport.send);
    try std.testing.expectError(error.ResponseIdMismatch, client.callWithId(1, "core.status", .{}));
    try std.testing.expectError(error.ResponseIdMismatch, client.callAllocWithId(1, "core.status", .{}));
}

test "client accepts null id error as an uncorrelated failure" {
    const allocator = std.testing.allocator;
    const body = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":\"internal_error\",\"message\":\"OutOfMemory\"}}";
    var mock: MockTransport = .{
        .allocator = allocator,
        .canned_response = body,
    };
    defer mock.deinit();

    var client = Client.init(allocator, &mock, MockTransport.send);
    var parsed = try client.callWithId(7, "core.status", .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.response.isOk());
    try std.testing.expect(parsed.response.id == null);
    try std.testing.expectEqualStrings("internal_error", parsed.response.err.?.code);
}

test "client handshake returns and records negotiated version" {
    const allocator = std.testing.allocator;
    const status_body = try protocol.encodeOkResponse(allocator, 1, .{
        .headless_protocol_version = protocol.HEADLESS_PROTOCOL_VERSION,
        .min_supported = protocol.MIN_SUPPORTED_PROTOCOL_VERSION,
        .max_supported = protocol.MAX_SUPPORTED_PROTOCOL_VERSION,
        .protocol_version = 18,
        .pid = 4242,
        .session_count = 0,
        .chat_turn_count = 0,
        .capabilities = protocol.Capabilities.phase1(),
    });
    defer allocator.free(status_body);

    var mock: MockTransport = .{
        .allocator = allocator,
        .canned_response = status_body,
    };
    defer mock.deinit();

    var client = Client.init(allocator, &mock, MockTransport.send);
    try std.testing.expectError(error.HandshakeRequired, client.negotiatedProtocolVersion());
    const result = try client.handshake();
    try std.testing.expectEqual(protocol.HEADLESS_PROTOCOL_VERSION, result.negotiated_version);
    try std.testing.expectEqual(result.negotiated_version, try client.negotiatedProtocolVersion());
    try std.testing.expectEqual(@as(u32, 4242), result.status.pid);
}

test "client status decode rejects invalid and incompatible daemon ranges" {
    const allocator = std.testing.allocator;
    var client = Client.initEncoder(allocator);

    const invalid_body = try protocol.encodeOkResponse(allocator, 1, .{
        .headless_protocol_version = 3,
        .min_supported = 3,
        .max_supported = 2,
        .protocol_version = 18,
        .pid = 1,
        .session_count = 0,
        .chat_turn_count = 0,
        .capabilities = protocol.Capabilities.phase1(),
    });
    defer allocator.free(invalid_body);
    var invalid = try client.parseResponseWithId(1, invalid_body);
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidProtocolRange, client.decodeStatus(&invalid));

    const incompatible_body = try protocol.encodeOkResponse(allocator, 2, .{
        .headless_protocol_version = 3,
        .min_supported = 2,
        .max_supported = 3,
        .protocol_version = 18,
        .pid = 1,
        .session_count = 0,
        .chat_turn_count = 0,
        .capabilities = protocol.Capabilities.phase1(),
    });
    defer allocator.free(incompatible_body);
    var incompatible = try client.parseResponseWithId(2, incompatible_body);
    defer incompatible.deinit();
    try std.testing.expectError(error.IncompatibleProtocolVersion, client.decodeStatus(&incompatible));
}

test "client encodeRequest assigns monotonic ids" {
    const allocator = std.testing.allocator;
    var client = Client.initEncoder(allocator);

    const first = try client.encodeRequest("session.list", .{});
    defer allocator.free(first.json);
    const second = try client.encodeRequest("chat.turn.tail", .{
        .turn_id = "turn-1",
        .after_seq = 7,
    });
    defer allocator.free(second.json);

    try std.testing.expectEqual(@as(u64, 1), first.id);
    try std.testing.expectEqual(@as(u64, 2), second.id);
    try std.testing.expectEqualStrings(
        "{\"id\":1,\"method\":\"session.list\",\"params\":[]}",
        first.json,
    );
    try std.testing.expectEqualStrings(
        "{\"id\":2,\"method\":\"chat.turn.tail\",\"params\":{\"turn_id\":\"turn-1\",\"after_seq\":7}}",
        second.json,
    );

    const core_status = try client.encodeRequestWithId(3, "core.status", .{});
    defer allocator.free(core_status);
    try std.testing.expectEqualStrings(
        "{\"id\":3,\"method\":\"core.status\",\"params\":[]}",
        core_status,
    );
}
