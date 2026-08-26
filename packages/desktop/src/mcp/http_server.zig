//! Daemon-owned loopback Streamable HTTP transport for Verde MCP.

const std = @import("std");
const endpoint_mod = @import("endpoint.zig");
const telemetry = @import("telemetry.zig");

const log = std.log.scoped(.mcp_http);

pub const MODERN_PROTOCOL_VERSION = "2026-07-28";
pub const SUPPORTED_PROTOCOL_VERSIONS = [_][]const u8{
    MODERN_PROTOCOL_VERSION,
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
};
const MAX_REQUEST_BYTES: usize = 1024 * 1024;

pub const RequestContext = struct {
    protocol_version: []const u8,
    client_name: []const u8,
    owner: []const u8,
    transport: enum { streamable_http } = .streamable_http,
};

/// A null response means the JSON-RPC message was a notification.
pub const Handler = *const fn (
    allocator: std.mem.Allocator,
    io: std.Io,
    request: []const u8,
    context: RequestContext,
) anyerror!?[]u8;

pub const Server = struct {
    state: *State,

    pub fn deinit(self: *Server) void {
        const state = self.state;
        state.stopping.store(true, .release);
        state.listener.socket.close(state.threaded.io());
        state.thread.join();
        state.endpoint.deinit(state.allocator);
        state.allocator.free(state.pref_path);
        state.threaded.deinit();
        state.allocator.destroy(state);
        self.* = undefined;
    }

    pub fn endpoint(self: *const Server) endpoint_mod.Endpoint {
        return self.state.endpoint;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    listener: std.Io.net.Server,
    endpoint: endpoint_mod.Endpoint,
    pref_path: []u8,
    handler: Handler,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
};

pub fn start(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    handler: Handler,
) !Server {
    const state = try allocator.create(State);
    errdefer allocator.destroy(state);
    state.* = .{
        .allocator = allocator,
        .threaded = .init(allocator, .{}),
        .listener = undefined,
        .endpoint = undefined,
        .pref_path = try allocator.dupe(u8, pref_path),
        .handler = handler,
    };
    errdefer allocator.free(state.pref_path);
    errdefer state.threaded.deinit();
    const io = state.threaded.io();

    var existing = try endpoint_mod.load(allocator, io, pref_path);
    defer if (existing) |*value| value.deinit(allocator);
    const preferred_port = if (existing) |value| value.port else endpoint_mod.DEFAULT_PORT;
    const bound = try bindLoopback(io, preferred_port);
    state.listener = bound.listener;
    errdefer state.listener.socket.close(io);
    state.endpoint = try endpoint_mod.loadOrCreateForPort(allocator, io, pref_path, bound.port);
    errdefer state.endpoint.deinit(allocator);

    state.thread = try std.Thread.spawn(.{}, acceptLoop, .{state});
    log.info("MCP Streamable HTTP listening on 127.0.0.1:{d}", .{bound.port});
    return .{ .state = state };
}

const BoundListener = struct {
    listener: std.Io.net.Server,
    port: u16,
};

fn bindLoopback(io: std.Io, preferred_port: u16) !BoundListener {
    if (try tryBind(io, preferred_port)) |listener| return .{ .listener = listener, .port = preferred_port };
    var offset: u16 = 0;
    while (offset < endpoint_mod.PORT_SCAN_COUNT) : (offset += 1) {
        const port = endpoint_mod.DEFAULT_PORT + offset;
        if (port == preferred_port) continue;
        if (try tryBind(io, port)) |listener| return .{ .listener = listener, .port = port };
    }
    return error.McpHttpPortUnavailable;
}

fn tryBind(io: std.Io, port: u16) !?std.Io.net.Server {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    // Provider MCP clients retain this URL across daemon restarts. Reuse the
    // loopback listener immediately instead of drifting to the next port while
    // accepted sockets from the previous daemon remain in TIME_WAIT.
    return address.listen(io, .{ .reuse_address = true }) catch |err| switch (err) {
        error.AddressInUse => null,
        else => |other| return other,
    };
}

fn acceptLoop(state: *State) void {
    const io = state.threaded.io();
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    while (!state.stopping.load(.acquire)) {
        const stream = state.listener.accept(io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled => return,
            else => {
                if (!state.stopping.load(.acquire)) log.warn("MCP HTTP accept failed: {s}", .{@errorName(err)});
                continue;
            },
        };
        group.concurrent(io, handleConnection, .{ state, stream }) catch |err| {
            log.warn("MCP HTTP worker spawn failed: {s}", .{@errorName(err)});
            stream.close(io);
        };
    }
}

fn handleConnection(state: *State, stream: std.Io.net.Stream) void {
    const io = state.threaded.io();
    defer stream.close(io);
    var send_buffer: [8 * 1024]u8 = undefined;
    var receive_buffer: [32 * 1024]u8 = undefined;
    var connection_reader = stream.reader(io, &receive_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);
    var request = server.receiveHead() catch return;
    handleRequest(state, io, &request) catch |err| {
        log.warn("MCP HTTP request failed: {s}", .{@errorName(err)});
    };
}

const RequestHeaders = struct {
    authorization: [96]u8 = undefined,
    authorization_len: usize = 0,
    origin: [256]u8 = undefined,
    origin_len: usize = 0,
    protocol_version: [32]u8 = undefined,
    protocol_version_len: usize = 0,
    method: [64]u8 = undefined,
    method_len: usize = 0,
    name: [128]u8 = undefined,
    name_len: usize = 0,
    client: [64]u8 = undefined,
    client_len: usize = 0,

    fn authorizationValue(self: *const RequestHeaders) []const u8 {
        return self.authorization[0..self.authorization_len];
    }

    fn originValue(self: *const RequestHeaders) ?[]const u8 {
        return if (self.origin_len == 0) null else self.origin[0..self.origin_len];
    }

    fn protocolVersion(self: *const RequestHeaders) ?[]const u8 {
        return if (self.protocol_version_len == 0) null else self.protocol_version[0..self.protocol_version_len];
    }

    fn methodValue(self: *const RequestHeaders) ?[]const u8 {
        return if (self.method_len == 0) null else self.method[0..self.method_len];
    }

    fn nameValue(self: *const RequestHeaders) ?[]const u8 {
        return if (self.name_len == 0) null else self.name[0..self.name_len];
    }

    fn clientValue(self: *const RequestHeaders) []const u8 {
        return if (self.client_len == 0) "unknown" else self.client[0..self.client_len];
    }
};

fn handleRequest(state: *State, io: std.Io, request: *std.http.Server.Request) !void {
    const started_ns = monotonicTimestampNs(io);
    var headers: RequestHeaders = .{};
    collectHeaders(request, &headers);
    if (!std.mem.eql(u8, request.head.target, "/mcp")) {
        recordHttpFailure(state, io, &headers, "transport", null, -32601, "MCP endpoint not found", started_ns);
        return respondJsonRpcError(request, .not_found, .null, -32601, "MCP endpoint not found");
    }
    if (request.head.method != .POST) {
        // Streamable HTTP clients may probe GET to discover whether the
        // optional server-to-client event stream is available. A 405 is the
        // supported no-stream response, not a failed MCP call.
        if (request.head.method != .GET) {
            recordHttpFailure(state, io, &headers, "transport", null, -32600, "HTTP method must be POST", started_ns);
        }
        const allow_headers = [_]std.http.Header{.{ .name = "allow", .value = "POST" }};
        return request.respond("", .{ .status = .method_not_allowed, .keep_alive = false, .extra_headers = &allow_headers });
    }
    if (!contentTypeIsJson(request.head.content_type)) {
        recordHttpFailure(state, io, &headers, "transport", null, -32600, "Content-Type must be application/json", started_ns);
        return respondJsonRpcError(request, .unsupported_media_type, .null, -32600, "Content-Type must be application/json");
    }

    if (!authorized(headers.authorizationValue(), state.endpoint.token)) {
        recordHttpFailure(state, io, &headers, "transport", null, -32001, "unauthorized", started_ns);
        return respondJsonRpcError(request, .unauthorized, .null, -32001, "unauthorized");
    }
    if (!originAllowed(headers.originValue(), state.endpoint.port)) {
        recordHttpFailure(state, io, &headers, "transport", null, -32002, "origin not allowed", started_ns);
        return respondJsonRpcError(request, .forbidden, .null, -32002, "origin not allowed");
    }

    const body_reader = try request.readerExpectContinue(&.{});
    const body = body_reader.allocRemaining(state.allocator, .limited(MAX_REQUEST_BYTES)) catch |err| switch (err) {
        error.StreamTooLong => {
            recordHttpFailure(state, io, &headers, "transport", null, -32600, "request too large", started_ns);
            return respondJsonRpcError(request, .payload_too_large, .null, -32600, "request too large");
        },
        else => return err,
    };
    defer state.allocator.free(body);

    var parsed = std.json.parseFromSlice(std.json.Value, state.allocator, body, .{}) catch {
        recordHttpFailure(state, io, &headers, "invalid", null, -32700, "invalid JSON", started_ns);
        return respondJsonRpcError(request, .bad_request, .null, -32700, "invalid JSON");
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        recordHttpFailure(state, io, &headers, "invalid", null, -32600, "request must be an object", started_ns);
        return respondJsonRpcError(request, .bad_request, .null, -32600, "request must be an object");
    }
    const id_value = parsed.value.object.get("id") orelse .null;
    const method = jsonString(parsed.value.object.get("method") orelse .null) orelse {
        recordHttpFailure(state, io, &headers, "invalid", null, -32600, "missing method", started_ns);
        return respondJsonRpcError(request, .bad_request, id_value, -32600, "missing method");
    };
    const params = parsed.value.object.get("params") orelse .null;
    const tool_name = requestName(method, params);
    const protocol_version = requestProtocolVersion(headers.protocolVersion(), params, method) orelse {
        recordHttpFailure(state, io, &headers, method, tool_name, -32022, "unsupported or missing protocol version", started_ns);
        return respondUnsupportedProtocolVersion(
            request,
            id_value,
            requestedProtocolVersion(headers.protocolVersion(), params) orelse "missing",
        );
    };
    if (std.mem.eql(u8, protocol_version, MODERN_PROTOCOL_VERSION)) {
        validateModernHeaders(&headers, method, params) catch {
            recordHttpFailure(state, io, &headers, method, tool_name, -32020, "MCP headers do not match the JSON-RPC request", started_ns);
            return respondJsonRpcError(request, .bad_request, id_value, -32020, "MCP headers do not match the JSON-RPC request");
        };
    }

    var client_buffer: [64]u8 = undefined;
    const client_name = sanitizeClientName(&headers, &client_buffer);
    var owner_buffer: [96]u8 = undefined;
    const owner = try std.fmt.bufPrint(&owner_buffer, "mcp:http:{s}", .{client_name});
    const response = state.handler(state.allocator, io, body, .{
        .protocol_version = protocol_version,
        .client_name = client_name,
        .owner = owner,
    }) catch |err| {
        recordHttpFailure(state, io, &headers, method, tool_name, -32603, @errorName(err), started_ns);
        return respondJsonRpcError(request, .internal_server_error, id_value, -32603, @errorName(err));
    };
    if (response) |bytes| {
        defer state.allocator.free(bytes);
        return respondJson(request, .ok, std.mem.trimEnd(u8, bytes, "\r\n"), protocol_version);
    }
    return request.respond("", .{ .status = .accepted, .keep_alive = false });
}

fn recordHttpFailure(
    state: *State,
    io: std.Io,
    headers: *const RequestHeaders,
    method: []const u8,
    tool: ?[]const u8,
    code: i64,
    detail: []const u8,
    started_ns: u64,
) void {
    var client_buffer: [64]u8 = undefined;
    const client_name = sanitizeClientName(headers, &client_buffer);
    telemetry.append(state.allocator, io, state.pref_path, .{
        .transport = "streamable_http",
        .client = client_name,
        .method = method,
        .tool = tool,
        .ok = false,
        .code = code,
        .detail = detail,
        .duration_ms = elapsedMs(io, started_ns),
    }) catch |err| log.warn("MCP HTTP telemetry append failed: {s}", .{@errorName(err)});
}

fn monotonicTimestampNs(io: std.Io) u64 {
    const timestamp = std.Io.Clock.awake.now(io);
    return @intCast(@max(timestamp.nanoseconds, 0));
}

fn elapsedMs(io: std.Io, started_ns: u64) u64 {
    const now_ns = monotonicTimestampNs(io);
    return if (now_ns >= started_ns) (now_ns - started_ns) / std.time.ns_per_ms else 0;
}

fn collectHeaders(request: *const std.http.Server.Request, out: *RequestHeaders) void {
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
            out.authorization_len = copyHeader(&out.authorization, header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "origin")) {
            out.origin_len = copyHeader(&out.origin, header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "mcp-protocol-version")) {
            out.protocol_version_len = copyHeader(&out.protocol_version, header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "mcp-method")) {
            out.method_len = copyHeader(&out.method, header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "mcp-name")) {
            out.name_len = copyHeader(&out.name, header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-verde-mcp-client")) {
            out.client_len = copyHeader(&out.client, header.value);
        }
    }
}

fn copyHeader(buffer: []u8, value: []const u8) usize {
    const count = @min(buffer.len, value.len);
    @memcpy(buffer[0..count], value[0..count]);
    return count;
}

fn contentTypeIsJson(value: ?[]const u8) bool {
    const content_type = value orelse return false;
    const media_type = if (std.mem.indexOfScalar(u8, content_type, ';')) |index| content_type[0..index] else content_type;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, media_type, &std.ascii.whitespace), "application/json");
}

fn authorized(value: []const u8, token: []const u8) bool {
    const prefix = "Bearer ";
    if (!std.ascii.startsWithIgnoreCase(value, prefix)) return false;
    const candidate = value[prefix.len..];
    if (candidate.len != token.len) return false;
    return std.crypto.timing_safe.eql([endpoint_mod.TOKEN_HEX_LEN]u8, candidate[0..endpoint_mod.TOKEN_HEX_LEN].*, token[0..endpoint_mod.TOKEN_HEX_LEN].*);
}

fn originAllowed(origin: ?[]const u8, port: u16) bool {
    const value = origin orelse return true;
    var first_buffer: [64]u8 = undefined;
    const first = std.fmt.bufPrint(&first_buffer, "http://127.0.0.1:{d}", .{port}) catch return false;
    if (std.mem.eql(u8, value, first)) return true;
    var second_buffer: [64]u8 = undefined;
    const second = std.fmt.bufPrint(&second_buffer, "http://localhost:{d}", .{port}) catch return false;
    return std.ascii.eqlIgnoreCase(value, second);
}

fn requestProtocolVersion(header: ?[]const u8, params: std.json.Value, method: []const u8) ?[]const u8 {
    if (header) |value| {
        if (supportedProtocolVersion(value)) return value;
        return null;
    }
    if (requestMetaProtocolVersion(params)) |value| {
        if (supportedProtocolVersion(value)) return value;
        return null;
    }
    if (std.mem.eql(u8, method, "initialize")) {
        if (params == .object) {
            if (jsonString(params.object.get("protocolVersion") orelse .null)) |value| {
                if (supportedProtocolVersion(value) and !std.mem.eql(u8, value, MODERN_PROTOCOL_VERSION)) return value;
            }
        }
    }
    return "2025-03-26";
}

fn supportedProtocolVersion(value: []const u8) bool {
    for (SUPPORTED_PROTOCOL_VERSIONS) |supported| {
        if (std.mem.eql(u8, value, supported)) return true;
    }
    return false;
}

fn requestedProtocolVersion(header: ?[]const u8, params: std.json.Value) ?[]const u8 {
    return header orelse requestMetaProtocolVersion(params);
}

fn requestMetaProtocolVersion(params: std.json.Value) ?[]const u8 {
    if (params != .object) return null;
    const meta = params.object.get("_meta") orelse return null;
    if (meta != .object) return null;
    return jsonString(meta.object.get("io.modelcontextprotocol/protocolVersion") orelse .null);
}

fn validateModernHeaders(headers: *const RequestHeaders, method: []const u8, params: std.json.Value) !void {
    const header_version = headers.protocolVersion() orelse return error.HeaderMismatch;
    if (!std.mem.eql(u8, header_version, MODERN_PROTOCOL_VERSION)) return error.HeaderMismatch;
    const meta_version = requestMetaProtocolVersion(params) orelse return error.HeaderMismatch;
    if (!std.mem.eql(u8, meta_version, MODERN_PROTOCOL_VERSION)) return error.HeaderMismatch;
    const meta = params.object.get("_meta") orelse return error.HeaderMismatch;
    const capabilities = meta.object.get("io.modelcontextprotocol/clientCapabilities") orelse return error.HeaderMismatch;
    if (capabilities != .object) return error.HeaderMismatch;
    if (meta.object.get("io.modelcontextprotocol/clientInfo")) |client_info| {
        if (client_info != .object) return error.HeaderMismatch;
    }
    const header_method = headers.methodValue() orelse return error.HeaderMismatch;
    if (!std.mem.eql(u8, header_method, method)) return error.HeaderMismatch;
    const expected_name = requestName(method, params);
    if (expected_name) |name| {
        const header_name = headers.nameValue() orelse return error.HeaderMismatch;
        if (!std.mem.eql(u8, header_name, name)) return error.HeaderMismatch;
    } else if (headers.nameValue() != null) {
        return error.HeaderMismatch;
    }
}

fn requestName(method: []const u8, params: std.json.Value) ?[]const u8 {
    const named = std.mem.eql(u8, method, "tools/call") or
        std.mem.eql(u8, method, "resources/read") or
        std.mem.eql(u8, method, "prompts/get");
    if (!named or params != .object) return null;
    return jsonString(params.object.get("name") orelse .null) orelse
        jsonString(params.object.get("uri") orelse .null);
}

fn sanitizeClientName(headers: *const RequestHeaders, client_buffer: *[64]u8) []const u8 {
    const raw = headers.clientValue();
    const capacity = @min(raw.len, client_buffer.len);
    for (raw[0..capacity], 0..) |byte, index| {
        const safe = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-';
        client_buffer[index] = if (safe) byte else '_';
    }
    return client_buffer[0..capacity];
}

fn respondJson(
    request: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
    protocol_version: []const u8,
) !void {
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "mcp-protocol-version", .value = protocol_version },
    };
    try request.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = &headers });
}

fn respondJsonRpcError(
    request: *std.http.Server.Request,
    status: std.http.Status,
    id_value: std.json.Value,
    code: i32,
    message: []const u8,
) !void {
    var writer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginObject();
    try stringify.objectField("jsonrpc");
    try stringify.write("2.0");
    try stringify.objectField("id");
    try writeJsonValue(&stringify, id_value);
    try stringify.objectField("error");
    try stringify.beginObject();
    try stringify.objectField("code");
    try stringify.write(code);
    try stringify.objectField("message");
    try stringify.write(message);
    try stringify.endObject();
    try stringify.endObject();
    const headers = [_]std.http.Header{.{ .name = "content-type", .value = "application/json; charset=utf-8" }};
    try request.respond(writer.written(), .{ .status = status, .keep_alive = false, .extra_headers = &headers });
}

fn respondUnsupportedProtocolVersion(
    request: *std.http.Server.Request,
    id_value: std.json.Value,
    requested: []const u8,
) !void {
    var writer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginObject();
    try stringify.objectField("jsonrpc");
    try stringify.write("2.0");
    try stringify.objectField("id");
    try writeJsonValue(&stringify, id_value);
    try stringify.objectField("error");
    try stringify.beginObject();
    try stringify.objectField("code");
    try stringify.write(@as(i32, -32022));
    try stringify.objectField("message");
    try stringify.write("unsupported protocol version");
    try stringify.objectField("data");
    try stringify.beginObject();
    try stringify.objectField("supported");
    try stringify.write(&SUPPORTED_PROTOCOL_VERSIONS);
    try stringify.objectField("requested");
    try stringify.write(requested);
    try stringify.endObject();
    try stringify.endObject();
    try stringify.endObject();
    const response_headers = [_]std.http.Header{.{ .name = "content-type", .value = "application/json; charset=utf-8" }};
    try request.respond(writer.written(), .{ .status = .bad_request, .keep_alive = false, .extra_headers = &response_headers });
}

fn writeJsonValue(stringify: *std.json.Stringify, value: std.json.Value) !void {
    try stringify.write(value);
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn testHandler(
    allocator: std.mem.Allocator,
    _: std.Io,
    _: []const u8,
    context: RequestContext,
) !?[]u8 {
    try std.testing.expectEqualStrings(MODERN_PROTOCOL_VERSION, context.protocol_version);
    try std.testing.expectEqualStrings("test-client", context.client_name);
    return @as(?[]u8, try allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}"));
}

test "modern requests require matching routable headers" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"name":"list_processes","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}
    , .{});
    defer parsed.deinit();
    var headers: RequestHeaders = .{};
    headers.protocol_version_len = copyHeader(&headers.protocol_version, MODERN_PROTOCOL_VERSION);
    headers.method_len = copyHeader(&headers.method, "tools/call");
    headers.name_len = copyHeader(&headers.name, "list_processes");
    try validateModernHeaders(&headers, "tools/call", parsed.value);
    headers.name_len = copyHeader(&headers.name, "wrong");
    try std.testing.expectError(error.HeaderMismatch, validateModernHeaders(&headers, "tools/call", parsed.value));
}

test "origin policy accepts only the bound loopback origin" {
    try std.testing.expect(originAllowed(null, 47_371));
    try std.testing.expect(originAllowed("http://127.0.0.1:47371", 47_371));
    try std.testing.expect(originAllowed("http://localhost:47371", 47_371));
    try std.testing.expect(!originAllowed("https://attacker.invalid", 47_371));
}

test "daemon HTTP transport accepts a stateless request and keeps its port across restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const pref_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(pref_path);
    var first_port: u16 = undefined;
    {
        var server = start(std.testing.allocator, pref_path, testHandler) catch |err| switch (err) {
            // The test runner's filesystem sandbox can also deny creating sockets.
            error.Unexpected => return error.SkipZigTest,
            else => |other| return other,
        };
        defer server.deinit();
        const bound_endpoint = server.endpoint();
        first_port = bound_endpoint.port;
        const url = try bound_endpoint.urlAlloc(std.testing.allocator);
        defer std.testing.allocator.free(url);
        const authorization = try bound_endpoint.authorizationAlloc(std.testing.allocator);
        defer std.testing.allocator.free(authorization);

        var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
        defer threaded.deinit();
        var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = threaded.io() };
        defer client.deinit();
        var response_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer response_writer.deinit();
        const payload =
            \\{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"test-client","version":"1"}}}}
        ;
        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .response_writer = &response_writer.writer,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "authorization", .value = authorization },
                .{ .name = "mcp-protocol-version", .value = MODERN_PROTOCOL_VERSION },
                .{ .name = "mcp-method", .value = "tools/list" },
                .{ .name = "x-verde-mcp-client", .value = "test-client" },
            },
        });
        try std.testing.expectEqual(std.http.Status.ok, result.status);
        try std.testing.expect(std.mem.indexOf(u8, response_writer.written(), "\"tools\":[]") != null);
    }

    var restarted = start(std.testing.allocator, pref_path, testHandler) catch |err| switch (err) {
        error.Unexpected => return error.SkipZigTest,
        else => |other| return other,
    };
    defer restarted.deinit();
    try std.testing.expectEqual(first_port, restarted.endpoint().port);
}
