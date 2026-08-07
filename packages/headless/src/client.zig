//! Transport-neutral typed client for the headless protocol.
//!
//! Builds request envelopes and parses response envelopes. The caller injects
//! a send function so unit tests need no sockets or daemon process.

const std = @import("std");
const protocol = @import("protocol.zig");
const registry = @import("registry_protocol.zig");

/// Sends one request JSON document and returns an allocator-owned response JSON document.
pub const TransportFn = *const fn (ctx: *anyopaque, request_json: []const u8) anyerror![]u8;

/// Coarse and granular capabilities that a direct daemon client may require.
/// The registry capabilities are deliberately included here while their
/// advertisement remains false during the phase-2 dual-write rollout.
pub const RequiredCapability = enum {
    terminal_raw,
    terminal_grid,
    chat,
    processes,
    leases,
    browser_execution,
    browser_presentation,
    browser_session_state,
    browser_create,
    browser_navigation,
    browser_history,
    browser_javascript_eval,
    browser_dom_inspection,
    browser_selector_actions,
    browser_form_input,
    browser_low_level_pointer,
    browser_screenshot,
    browser_lifecycle_restart,
    browser_lifecycle_reset,
    browser_frame_streaming,
    browser_downloads,
    browser_uploads,

    pub fn wireName(self: @This()) []const u8 {
        return switch (self) {
            .terminal_raw => "terminal_raw",
            .terminal_grid => "terminal_grid",
            .chat => "chat",
            .processes => "processes",
            .leases => "leases",
            .browser_execution => "browser_execution",
            .browser_presentation => "browser_presentation",
            .browser_session_state => "browser.session_state",
            .browser_create => "browser.create",
            .browser_navigation => "browser.navigation",
            .browser_history => "browser.history",
            .browser_javascript_eval => "browser.javascript_eval",
            .browser_dom_inspection => "browser.dom_inspection",
            .browser_selector_actions => "browser.selector_actions",
            .browser_form_input => "browser.form_input",
            .browser_low_level_pointer => "browser.low_level_pointer",
            .browser_screenshot => "browser.screenshot",
            .browser_lifecycle_restart => "browser.lifecycle_restart",
            .browser_lifecycle_reset => "browser.lifecycle_reset",
            .browser_frame_streaming => "browser.frame_streaming",
            .browser_downloads => "browser.downloads",
            .browser_uploads => "browser.uploads",
        };
    }
};

/// The typed client-side error used when a direct daemon lacks a feature.
pub const CapabilityError = error{CapabilityUnavailable};

/// Check a coarse or granular advertised capability before a direct call.
pub fn requireCapability(capabilities: protocol.Capabilities, feature: RequiredCapability) CapabilityError!void {
    return requireCapabilityChecked(capabilities, feature);
}

fn requireCapabilityChecked(capabilities: protocol.Capabilities, feature: RequiredCapability) CapabilityError!void {
    const available = switch (feature) {
        .terminal_raw => capabilities.terminal_raw,
        .terminal_grid => capabilities.terminal_grid,
        .chat => capabilities.chat,
        .processes => capabilities.processes,
        .leases => capabilities.leases,
        .browser_execution => capabilities.browser_execution,
        .browser_presentation => capabilities.browser_presentation,
        .browser_session_state => capabilities.isFeatureAvailable(.browser_session_state),
        .browser_create => capabilities.isFeatureAvailable(.browser_create),
        .browser_navigation => capabilities.isFeatureAvailable(.browser_navigation),
        .browser_history => capabilities.isFeatureAvailable(.browser_history),
        .browser_javascript_eval => capabilities.isFeatureAvailable(.browser_javascript_eval),
        .browser_dom_inspection => capabilities.isFeatureAvailable(.browser_dom_inspection),
        .browser_selector_actions => capabilities.isFeatureAvailable(.browser_selector_actions),
        .browser_form_input => capabilities.isFeatureAvailable(.browser_form_input),
        .browser_low_level_pointer => capabilities.isFeatureAvailable(.browser_low_level_pointer),
        .browser_screenshot => capabilities.isFeatureAvailable(.browser_screenshot),
        .browser_lifecycle_restart => capabilities.isFeatureAvailable(.browser_lifecycle_restart),
        .browser_lifecycle_reset => capabilities.isFeatureAvailable(.browser_lifecycle_reset),
        .browser_frame_streaming => capabilities.isFeatureAvailable(.browser_frame_streaming),
        .browser_downloads => capabilities.isFeatureAvailable(.browser_downloads),
        .browser_uploads => capabilities.isFeatureAvailable(.browser_uploads),
    };
    if (!available) return error.CapabilityUnavailable;
}

/// Check a protocol capability using the protocol's established feature enum.
/// This is convenient for callers that already use `protocol.CapabilityFeature`.
pub fn requireFeature(capabilities: protocol.Capabilities, feature: protocol.CapabilityFeature) CapabilityError!void {
    return requireFeatureChecked(capabilities, feature);
}

fn requireFeatureChecked(capabilities: protocol.Capabilities, feature: protocol.CapabilityFeature) CapabilityError!void {
    if (!capabilities.isFeatureAvailable(feature)) return error.CapabilityUnavailable;
}

/// Alias documenting that the check is for a direct daemon request.
pub fn requireDaemonDirectCapability(capabilities: protocol.Capabilities, feature: RequiredCapability) CapabilityError!void {
    return requireCapabilityChecked(capabilities, feature);
}

/// Convert a failed direct-mode capability check to the protocol error payload.
pub fn capabilityUnavailable(feature: RequiredCapability) protocol.Error {
    return .{
        .code = protocol.ERR_CAPABILITY_UNAVAILABLE,
        .message = switch (feature) {
            .terminal_raw => "terminal_raw capability is unavailable",
            .terminal_grid => "terminal_grid capability is unavailable",
            .chat => "chat capability is unavailable",
            .processes => "processes capability is unavailable",
            .leases => "leases capability is unavailable",
            .browser_execution => "browser_execution capability is unavailable",
            .browser_presentation => "browser_presentation capability is unavailable",
            .browser_session_state => "browser.session_state capability is unavailable",
            .browser_create => "browser.create capability is unavailable",
            .browser_navigation => "browser.navigation capability is unavailable",
            .browser_history => "browser.history capability is unavailable",
            .browser_javascript_eval => "browser.javascript_eval capability is unavailable",
            .browser_dom_inspection => "browser.dom_inspection capability is unavailable",
            .browser_selector_actions => "browser.selector_actions capability is unavailable",
            .browser_form_input => "browser.form_input capability is unavailable",
            .browser_low_level_pointer => "browser.low_level_pointer capability is unavailable",
            .browser_screenshot => "browser.screenshot capability is unavailable",
            .browser_lifecycle_restart => "browser.lifecycle_restart capability is unavailable",
            .browser_lifecycle_reset => "browser.lifecycle_reset capability is unavailable",
            .browser_frame_streaming => "browser.frame_streaming capability is unavailable",
            .browser_downloads => "browser.downloads capability is unavailable",
            .browser_uploads => "browser.uploads capability is unavailable",
        },
    };
}

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
        const status = try self.decodeResult(protocol.StatusResult, parsed);
        _ = try self.recordNegotiatedRange(status.min_supported, status.max_supported);
        return status;
    }

    /// Decode a successful `core.capabilities` response into its typed result.
    pub fn decodeCapabilities(self: *Client, parsed: *const protocol.ParsedResponse) !protocol.CapabilitiesResult {
        const capabilities = try self.decodeResult(protocol.CapabilitiesResult, parsed);
        _ = try self.recordNegotiatedRange(capabilities.min_supported, capabilities.max_supported);
        return capabilities;
    }

    /// Decode a successful `process.list` response.
    pub fn decodeProcessList(self: *Client, parsed: *const protocol.ParsedResponse) !registry.ProcessListResult {
        return try self.decodeResult(registry.ProcessListResult, parsed);
    }

    /// Decode a successful `lease.check` response.
    pub fn decodeLeaseCheck(self: *Client, parsed: *const protocol.ParsedResponse) !registry.LeaseCheckResult {
        return try self.decodeResult(registry.LeaseCheckResult, parsed);
    }

    /// Decode a successful `lease.acquire` response.
    pub fn decodeLeaseAcquire(self: *Client, parsed: *const protocol.ParsedResponse) !registry.LeaseAcquireResult {
        return try self.decodeResult(registry.LeaseAcquireResult, parsed);
    }

    /// Decode a successful `lease.renew` response.
    pub fn decodeLeaseRenew(self: *Client, parsed: *const protocol.ParsedResponse) !registry.LeaseRenewResult {
        return try self.decodeResult(registry.LeaseRenewResult, parsed);
    }

    /// Decode a successful `lease.release` response.
    pub fn decodeLeaseRelease(self: *Client, parsed: *const protocol.ParsedResponse) !registry.LeaseReleaseResult {
        return try self.decodeResult(registry.LeaseReleaseResult, parsed);
    }

    /// Decode a successful `daemon.notifications` response.
    pub fn decodeNotifications(self: *Client, parsed: *const protocol.ParsedResponse) !registry.NotificationsResult {
        return try self.decodeResult(registry.NotificationsResult, parsed);
    }

    /// Decode a successful `daemon.client.register` response.
    pub fn decodeClientRegister(self: *Client, parsed: *const protocol.ParsedResponse) !registry.ClientRegisterResult {
        return try self.decodeResult(registry.ClientRegisterResult, parsed);
    }

    /// Decode a successful `daemon.client.heartbeat` response.
    pub fn decodeClientHeartbeat(self: *Client, parsed: *const protocol.ParsedResponse) !registry.ClientHeartbeatResult {
        return try self.decodeResult(registry.ClientHeartbeatResult, parsed);
    }

    /// Decode a successful `daemon.client.close` response.
    pub fn decodeClientClose(self: *Client, parsed: *const protocol.ParsedResponse) !registry.ClientCloseResult {
        return try self.decodeResult(registry.ClientCloseResult, parsed);
    }

    /// Decode a successful `daemon.stop` response.
    pub fn decodeDaemonStop(self: *Client, parsed: *const protocol.ParsedResponse) !registry.DaemonStopResult {
        return try self.decodeResult(registry.DaemonStopResult, parsed);
    }

    /// Decode a successful `workspace.resolve` response.
    pub fn decodeWorkspaceResolve(self: *Client, parsed: *const protocol.ParsedResponse) !registry.WorkspaceResolveResult {
        return try self.decodeResult(registry.WorkspaceResolveResult, parsed);
    }

    /// Require a capability on this client before a direct daemon request.
    pub fn requireCapability(_: *Client, capabilities: protocol.Capabilities, feature: RequiredCapability) CapabilityError!void {
        return requireCapabilityChecked(capabilities, feature);
    }

    /// Require a protocol feature on this client before a direct request.
    pub fn requireFeature(_: *Client, capabilities: protocol.Capabilities, feature: protocol.CapabilityFeature) CapabilityError!void {
        return requireFeatureChecked(capabilities, feature);
    }

    /// Require a capability for a daemon-direct operation.
    pub fn requireDaemonDirectCapability(_: *Client, capabilities: protocol.Capabilities, feature: RequiredCapability) CapabilityError!void {
        return requireCapabilityChecked(capabilities, feature);
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

    /// Re-encode the parsed result before typed parsing so `.alloc_always`
    /// produces values independent of the response envelope's arena.
    fn decodeResult(self: *Client, comptime T: type, parsed: *const protocol.ParsedResponse) !T {
        const result = try self.resultValue(parsed);
        const result_json = try std.json.Stringify.valueAlloc(self.allocator, result, .{});
        defer self.allocator.free(result_json);
        return try std.json.parseFromSliceLeaky(T, self.allocator, result_json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
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

test "registry decoders are tolerant and own result strings" {
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    var client = Client.initEncoder(result_arena.allocator());
    const response_allocator = std.testing.allocator;

    var process_list = try protocol.parseResponse(response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"registry_revision\":7,\"processes\":[{\"id\":\"p1\",\"status\":\"running\"}],\"future\":true}}",
    );
    defer process_list.deinit();
    const process_list_result = try client.decodeProcessList(&process_list);
    try std.testing.expectEqual(@as(u64, 7), process_list_result.registry_revision);
    try std.testing.expectEqualStrings("p1", process_list_result.processes[0].id);
    try std.testing.expectEqual(registry.ProcessStatus.running, process_list_result.processes[0].status);

    var lease_check = try protocol.parseResponse(response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"allowed\":false,\"conflicts\":[{\"id\":\"l1\"}],\"future\":true}}",
    );
    defer lease_check.deinit();
    const lease_check_result = try client.decodeLeaseCheck(&lease_check);
    try std.testing.expect(!lease_check_result.allowed);
    try std.testing.expectEqualStrings("l1", lease_check_result.conflicts[0].id);

    var lease_acquire = try protocol.parseResponse(response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"acquired\":true,\"lease_id\":\"l1\"}}",
    );
    defer lease_acquire.deinit();
    const lease_acquire_result = try client.decodeLeaseAcquire(&lease_acquire);
    try std.testing.expect(lease_acquire_result.acquired);
    try std.testing.expectEqualStrings("l1", lease_acquire_result.lease_id.?);

    var lease_renew = try protocol.parseResponse(response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"renewed\":true,\"lease_id\":\"l1\"}}",
    );
    defer lease_renew.deinit();
    const lease_renew_result = try client.decodeLeaseRenew(&lease_renew);
    try std.testing.expect(lease_renew_result.renewed);
    try std.testing.expectEqualStrings("l1", lease_renew_result.lease_id);

    var lease_release = try protocol.parseResponse(response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"released\":true,\"released_count\":1}}",
    );
    defer lease_release.deinit();
    const lease_release_result = try client.decodeLeaseRelease(&lease_release);
    try std.testing.expect(lease_release_result.released);
    try std.testing.expectEqual(@as(u32, 1), lease_release_result.released_count);

    var notifications = try protocol.parseResponse(response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"result\":{\"notifications\":[{\"seq\":4,\"body\":\"conflict\"}],\"next_notification_seq\":5}}",
    );
    defer notifications.deinit();
    const notifications_result = try client.decodeNotifications(&notifications);
    try std.testing.expectEqual(@as(u64, 5), notifications_result.next_notification_seq);
    try std.testing.expectEqualStrings("conflict", notifications_result.notifications[0].body);

    var client_register = try protocol.parseResponse(response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"client_id\":\"c1\",\"persistent\":true}}",
    );
    defer client_register.deinit();
    const client_register_result = try client.decodeClientRegister(&client_register);
    try std.testing.expectEqualStrings("c1", client_register_result.client_id);
    try std.testing.expect(client_register_result.persistent);

    var client_heartbeat = try protocol.parseResponse(response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{\"client_id\":\"c1\",\"accepted\":true}}",
    );
    defer client_heartbeat.deinit();
    const client_heartbeat_result = try client.decodeClientHeartbeat(&client_heartbeat);
    try std.testing.expectEqualStrings("c1", client_heartbeat_result.client_id);
    try std.testing.expect(client_heartbeat_result.accepted);

    var client_close = try protocol.parseResponse(response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{\"client_id\":\"c1\",\"closed\":true,\"released_leases\":2}}",
    );
    defer client_close.deinit();
    const client_close_result = try client.decodeClientClose(&client_close);
    try std.testing.expectEqualStrings("c1", client_close_result.client_id);
    try std.testing.expect(client_close_result.closed);
    try std.testing.expectEqual(@as(u32, 2), client_close_result.released_leases);

    var daemon_stop = try protocol.parseResponse(response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":10,\"result\":{\"accepted\":true,\"stopping\":true}}",
    );
    defer daemon_stop.deinit();
    const daemon_stop_result = try client.decodeDaemonStop(&daemon_stop);
    try std.testing.expect(daemon_stop_result.accepted);
    try std.testing.expect(daemon_stop_result.stopping);

    var workspace_resolve = try protocol.parseResponse(response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":11,\"result\":{\"workspace\":{\"id\":\"w1\",\"path\":\"/tmp/w\"}}}",
    );
    defer workspace_resolve.deinit();
    const workspace_resolve_result = try client.decodeWorkspaceResolve(&workspace_resolve);
    try std.testing.expectEqualStrings("w1", workspace_resolve_result.workspace.id);
    try std.testing.expectEqualStrings("/tmp/w", workspace_resolve_result.workspace.path);
}

test "registry decoders return RemoteError for error envelopes" {
    var client = Client.initEncoder(std.testing.allocator);
    var parsed = try protocol.parseResponse(std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":\"capability_unavailable\",\"message\":\"processes capability is unavailable\",\"data\":{\"feature\":\"processes\"}}}",
    );
    defer parsed.deinit();

    try std.testing.expectError(error.RemoteError, client.decodeProcessList(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeLeaseCheck(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeLeaseAcquire(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeLeaseRenew(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeLeaseRelease(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeNotifications(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeClientRegister(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeClientHeartbeat(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeClientClose(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeDaemonStop(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeWorkspaceResolve(&parsed));
}

test "capability checks support direct registry mode" {
    const phase1 = protocol.Capabilities.phase1();
    try requireCapability(phase1, .terminal_raw);
    try std.testing.expectError(error.CapabilityUnavailable, requireCapability(phase1, .processes));
    try std.testing.expectError(error.CapabilityUnavailable, requireDaemonDirectCapability(phase1, .leases));
    try std.testing.expectError(error.CapabilityUnavailable, requireFeature(phase1, .browser_navigation));

    const unavailable = capabilityUnavailable(.processes);
    try std.testing.expectEqualStrings(protocol.ERR_CAPABILITY_UNAVAILABLE, unavailable.code);
    try std.testing.expectEqualStrings("processes capability is unavailable", unavailable.message);

    const capable = protocol.Capabilities.withBrowser(.{ .navigation = true }, false);
    try requireCapability(capable, .browser_navigation);
    try requireFeature(capable, .browser_navigation);
}
