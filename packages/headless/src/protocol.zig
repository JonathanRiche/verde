//! Headless Verde protocol envelopes, versions, error codes, and capabilities.
//!
//! Pure allocator + std.json only. No sockets, pipes, or daemon imports.
//! Wire shape matches the existing sessionizer JSON-RPC envelope so core.*
//! methods stay byte-compatible with the daemon's beginOk / errorResponseAlloc.

const std = @import("std");

/// Current headless protocol version advertised by core.status / core.capabilities.
pub const HEADLESS_PROTOCOL_VERSION: u32 = 1;
/// Oldest headless protocol version this implementation understands.
pub const MIN_SUPPORTED_PROTOCOL_VERSION: u32 = 1;
/// Newest headless protocol version this implementation understands.
pub const MAX_SUPPORTED_PROTOCOL_VERSION: u32 = 1;

/// Soft upper bound for a single envelope. Oversized input is rejected as invalid_request.
pub const MAX_MESSAGE_BYTES: usize = 8 * 1024 * 1024;

// Stable machine-readable error codes. Keep these strings frozen once published.
pub const ERR_INVALID_REQUEST: []const u8 = "invalid_request";
pub const ERR_UNKNOWN_METHOD: []const u8 = "unknown_method";
pub const ERR_INVALID_PARAMS: []const u8 = "invalid_params";
pub const ERR_CAPABILITY_UNAVAILABLE: []const u8 = "capability_unavailable";
pub const ERR_RESOURCE_NOT_FOUND: []const u8 = "resource_not_found";
pub const ERR_INTERNAL: []const u8 = "internal";
pub const ERR_CONFLICT: []const u8 = "conflict";
pub const ERR_INVALID_STATE: []const u8 = "invalid_state";

/// Typed protocol error carried inside a response envelope.
pub const Error = struct {
    code: []const u8,
    message: []const u8,
};

/// Capabilities currently offered by the headless core. Phase 1 only claims terminal_raw.
pub const Capabilities = struct {
    terminal_raw: bool = true,
    terminal_grid: bool = false,
    chat: bool = false,
    processes: bool = false,
    leases: bool = false,
    browser_execution: bool = false,
    browser_presentation: bool = false,

    pub fn phase1() Capabilities {
        return .{
            .terminal_raw = true,
            .terminal_grid = false,
            .chat = false,
            .processes = false,
            .leases = false,
            .browser_execution = false,
            .browser_presentation = false,
        };
    }
};

/// Result payload for `core.status`.
pub const StatusResult = struct {
    headless_protocol_version: u32,
    min_supported: u32,
    max_supported: u32,
    /// Sessionizer RPC protocol version (daemon-owned sessions / chat turns).
    protocol_version: u32,
    pid: u32,
    session_count: usize,
    chat_turn_count: usize,
    capabilities: Capabilities,
};

/// Result payload for `core.capabilities`.
pub const CapabilitiesResult = struct {
    headless_protocol_version: u32,
    min_supported: u32,
    max_supported: u32,
    capabilities: Capabilities,
};

/// Typed request envelope. Params stay as dynamic JSON for tolerant readers.
pub const Request = struct {
    id: u64,
    method: []const u8,
    params: std.json.Value = .null,
};

/// Typed response envelope: exactly one of result or err is meaningful.
pub const Response = struct {
    id: u64,
    result: ?std.json.Value = null,
    err: ?Error = null,

    pub fn isOk(self: Response) bool {
        return self.err == null;
    }
};

/// Encode a request matching the sessionizer client shape (id/method/params).
/// Field order is part of the compatibility contract with existing callers.
pub fn encodeRequest(allocator: std.mem.Allocator, id: u64, method: []const u8, params: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("id");
    try s.write(id);
    try s.objectField("method");
    try s.write(method);
    try s.objectField("params");
    try s.write(params);
    try s.endObject();
    return try writer.toOwnedSlice();
}

/// Encode an ok response envelope (jsonrpc + id + result).
pub fn encodeOkResponse(allocator: std.mem.Allocator, id: u64, result: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("result");
    try s.write(result);
    try s.endObject();
    return try writer.toOwnedSlice();
}

/// Encode an error response envelope (jsonrpc + id + error{code,message}).
pub fn encodeErrorResponse(allocator: std.mem.Allocator, id: u64, code: []const u8, message: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.write(code);
    try s.objectField("message");
    try s.write(message);
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

pub const ParsedRequest = struct {
    arena_parsed: std.json.Parsed(std.json.Value),
    request: Request,

    pub fn deinit(self: *ParsedRequest) void {
        self.arena_parsed.deinit();
        self.* = undefined;
    }
};

pub const ParsedResponse = struct {
    arena_parsed: std.json.Parsed(std.json.Value),
    response: Response,

    pub fn deinit(self: *ParsedResponse) void {
        self.arena_parsed.deinit();
        self.* = undefined;
    }
};

/// Parse a request envelope. Unknown fields are ignored; bad/oversized JSON is invalid_request.
pub fn parseRequest(allocator: std.mem.Allocator, json_bytes: []const u8) !ParsedRequest {
    try rejectOversizedOrEmpty(json_bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidRequest;
    errdefer parsed.deinit();

    if (parsed.value != .object) return error.InvalidRequest;
    const obj = parsed.value.object;
    const id = jsonU64(obj.get("id") orelse .null) orelse return error.InvalidRequest;
    const method = jsonString(obj.get("method") orelse .null) orelse return error.InvalidRequest;
    const params = obj.get("params") orelse .null;

    return .{
        .arena_parsed = parsed,
        .request = .{
            .id = id,
            .method = method,
            .params = params,
        },
    };
}

/// Parse a response envelope. Unknown fields are ignored; bad/oversized JSON is invalid_request.
pub fn parseResponse(allocator: std.mem.Allocator, json_bytes: []const u8) !ParsedResponse {
    try rejectOversizedOrEmpty(json_bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidRequest;
    errdefer parsed.deinit();

    if (parsed.value != .object) return error.InvalidRequest;
    const obj = parsed.value.object;
    const id = jsonU64(obj.get("id") orelse .null) orelse return error.InvalidRequest;

    if (obj.get("error")) |err_value| {
        if (err_value != .object) return error.InvalidRequest;
        const code = jsonString(err_value.object.get("code") orelse .null) orelse return error.InvalidRequest;
        const message = jsonString(err_value.object.get("message") orelse .null) orelse "";
        return .{
            .arena_parsed = parsed,
            .response = .{
                .id = id,
                .err = .{ .code = code, .message = message },
            },
        };
    }

    const result = obj.get("result") orelse return error.InvalidRequest;
    return .{
        .arena_parsed = parsed,
        .response = .{
            .id = id,
            .result = result,
        },
    };
}

fn rejectOversizedOrEmpty(json_bytes: []const u8) !void {
    if (json_bytes.len == 0 or json_bytes.len > MAX_MESSAGE_BYTES) return error.InvalidRequest;
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |int| if (int >= 0) @intCast(int) else null,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch null,
        else => null,
    };
}

test "envelope round-trip encode/decode request and ok response" {
    const allocator = std.testing.allocator;
    const req_json = try encodeRequest(allocator, 42, "core.status", .{ .extra = true });
    defer allocator.free(req_json);

    var parsed_req = try parseRequest(allocator, req_json);
    defer parsed_req.deinit();
    try std.testing.expectEqual(@as(u64, 42), parsed_req.request.id);
    try std.testing.expectEqualStrings("core.status", parsed_req.request.method);
    // Unknown params fields are retained in the dynamic value for the dispatcher to ignore.
    try std.testing.expect(parsed_req.request.params == .object);

    const status: StatusResult = .{
        .headless_protocol_version = HEADLESS_PROTOCOL_VERSION,
        .min_supported = MIN_SUPPORTED_PROTOCOL_VERSION,
        .max_supported = MAX_SUPPORTED_PROTOCOL_VERSION,
        .protocol_version = 18,
        .pid = 1234,
        .session_count = 2,
        .chat_turn_count = 1,
        .capabilities = .phase1(),
    };
    const ok_json = try encodeOkResponse(allocator, 42, status);
    defer allocator.free(ok_json);

    var parsed_ok = try parseResponse(allocator, ok_json);
    defer parsed_ok.deinit();
    try std.testing.expect(parsed_ok.response.isOk());
    try std.testing.expectEqual(@as(u64, 42), parsed_ok.response.id);
    const result = parsed_ok.response.result.?;
    try std.testing.expect(result == .object);
    try std.testing.expectEqual(
        @as(i64, HEADLESS_PROTOCOL_VERSION),
        result.object.get("headless_protocol_version").?.integer,
    );
    try std.testing.expectEqual(@as(i64, 18), result.object.get("protocol_version").?.integer);
}

test "parseResponse reads error envelopes" {
    const allocator = std.testing.allocator;
    const err_json = try encodeErrorResponse(allocator, 7, ERR_UNKNOWN_METHOD, "nope");
    defer allocator.free(err_json);

    var parsed = try parseResponse(allocator, err_json);
    defer parsed.deinit();
    try std.testing.expect(!parsed.response.isOk());
    try std.testing.expectEqualStrings(ERR_UNKNOWN_METHOD, parsed.response.err.?.code);
    try std.testing.expectEqualStrings("nope", parsed.response.err.?.message);
}

test "invalid or empty JSON yields InvalidRequest" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidRequest, parseRequest(allocator, ""));
    try std.testing.expectError(error.InvalidRequest, parseRequest(allocator, "{not-json"));
    try std.testing.expectError(error.InvalidRequest, parseResponse(allocator, "[]"));
}

test "unknown fields in params are tolerated by request parse" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"jsonrpc":"2.0","id":1,"method":"core.capabilities","params":{"future_flag":true,"nested":{"x":1}},"extra":"ignored"}
    ;
    var parsed = try parseRequest(allocator, raw);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("core.capabilities", parsed.request.method);
    try std.testing.expect(parsed.request.params.object.get("future_flag") != null);
}
