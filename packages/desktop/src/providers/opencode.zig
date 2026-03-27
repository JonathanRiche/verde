//! OpenCode provider harness backed by the local HTTP server.

const std = @import("std");
const provider_types = @import("../provider_types.zig");

const MAX_HTTP_BODY_BYTES = 8 * 1024 * 1024;
const MAX_HEALTH_WAIT_ATTEMPTS = 30;
const DEFAULT_BASE_URL = "http://127.0.0.1:4096";

pub const Config = struct {
    allocator: std.mem.Allocator,
    executable: []const u8 = "opencode",
    base_url: []const u8 = DEFAULT_BASE_URL,
    working_directory: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    launch_if_missing: bool = false,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    http_client: std.http.Client,
    child: ?std.process.Child = null,
    owns_child: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Client {
        var client: Client = .{
            .allocator = allocator,
            .config = config,
            .http_client = .{ .allocator = allocator },
        };
        try client.ensureServer();
        return client;
    }

    pub fn deinit(self: *Client) void {
        if (self.child) |*child| {
            if (self.owns_child) {
                _ = child.kill() catch {};
                _ = child.wait() catch {};
            }
            self.child = null;
            self.owns_child = false;
        }
        self.http_client.deinit();
    }

    pub fn authState(self: *Client) !provider_types.AuthState {
        const response = try self.requestJson(.GET, "/provider", null);
        defer self.allocator.free(response.body);

        if (response.status != .ok) return error.OpencodeRequestFailed;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();

        const connected = getObjectField(parsed.value, "connected") orelse return .unknown;
        return switch (connected) {
            .array => |items| if (items.items.len > 0) .signed_in else .signed_out,
            else => .unknown,
        };
    }

    pub fn listThreads(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ChatThreadSummary {
        const response = try self.requestJson(.GET, "/session", null);
        defer self.allocator.free(response.body);

        if (response.status != .ok) return error.OpencodeRequestFailed;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();

        if (parsed.value != .array) {
            return allocator.alloc(provider_types.ChatThreadSummary, 0);
        }

        var threads: std.ArrayList(provider_types.ChatThreadSummary) = .empty;
        defer threads.deinit(allocator);

        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const id = getOptionalObjectString(item, "id") orelse continue;
            const title = getOptionalObjectString(item, "title") orelse id;
            try threads.append(allocator, .{
                .id = try allocator.dupe(u8, id),
                .title = try allocator.dupe(u8, title),
            });
        }

        return threads.toOwnedSlice(allocator);
    }

    pub fn sendPrompt(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.SendPromptRequest,
    ) !provider_types.SendPromptResult {
        const session_id = if (request.thread_id) |existing|
            try allocator.dupe(u8, existing)
        else
            try self.createSession(allocator);
        errdefer allocator.free(session_id);

        const path = try std.fmt.allocPrint(self.allocator, "/session/{s}/message", .{session_id});
        defer self.allocator.free(path);

        const body = if (request.model) |model_ref|
            try buildMessageBodyWithModel(self.allocator, request.prompt, model_ref)
        else
            try stringifyAlloc(self.allocator, .{
                .parts = &.{.{ .type = "text", .text = request.prompt }},
            });
        defer self.allocator.free(body);

        const response = try self.requestJson(.POST, path, body);
        defer self.allocator.free(response.body);
        if (response.status != .ok) return error.OpencodeRequestFailed;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();

        const reply_text = try extractAssistantTextAlloc(allocator, parsed.value);
        errdefer allocator.free(reply_text);

        return .{
            .thread_id = session_id,
            .reply_text = reply_text,
        };
    }

    fn ensureServer(self: *Client) !void {
        if (self.checkHealth()) {
            return;
        }

        if (!self.config.launch_if_missing) {
            return error.OpencodeServerUnavailable;
        }

        try self.spawnServer();

        var attempt: usize = 0;
        while (attempt < MAX_HEALTH_WAIT_ATTEMPTS) : (attempt += 1) {
            if (self.checkHealth()) {
                return;
            }
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }

        return error.OpencodeServerUnavailable;
    }

    fn checkHealth(self: *Client) bool {
        const result = self.requestJson(.GET, "/global/health", null);
        if (result) |response| {
            defer self.allocator.free(response.body);
            return response.status == .ok;
        } else |_| {
            return false;
        }
    }

    fn spawnServer(self: *Client) !void {
        if (self.child != null) return;

        const uri = try std.Uri.parse(self.config.base_url);
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) {
            return error.UnsupportedOpencodeScheme;
        }

        const host = try uri.getHostAlloc(self.allocator);
        defer if (uri.host != null and host.ptr != switch (uri.host.?) {
            .raw => |raw| raw.ptr,
            .percent_encoded => |encoded| encoded.ptr,
        }) self.allocator.free(host);

        const port = uri.port orelse 4096;
        const port_text = try std.fmt.allocPrint(self.allocator, "{d}", .{port});
        defer self.allocator.free(port_text);

        var argv = [_][]const u8{
            self.config.executable,
            "serve",
            "--hostname",
            host,
            "--port",
            port_text,
        };

        var child = std.process.Child.init(argv[0..], self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.cwd = self.config.working_directory;
        try child.spawn();
        child.argv = &.{};

        self.child = child;
        self.owns_child = true;
    }

    fn createSession(self: *Client, allocator: std.mem.Allocator) ![]u8 {
        const body = try stringifyAlloc(self.allocator, .{
            .title = "Verde",
        });
        defer self.allocator.free(body);

        const response = try self.requestJson(.POST, "/session", body);
        defer self.allocator.free(response.body);
        if (response.status != .ok) return error.OpencodeRequestFailed;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();

        const id = getOptionalObjectString(parsed.value, "id") orelse return error.MissingSessionId;
        return allocator.dupe(u8, id);
    }

    fn requestJson(
        self: *Client,
        method: std.http.Method,
        path: []const u8,
        payload: ?[]const u8,
    ) !HttpResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.config.base_url, path });
        defer self.allocator.free(url);

        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer body_writer.deinit();

        const auth_header = try self.makeAuthorizationHeader();
        defer if (auth_header) |header| self.allocator.free(header.value);

        var headers_storage: [3]std.http.Header = undefined;
        var header_count: usize = 0;
        if (payload != null) {
            headers_storage[header_count] = .{ .name = "content-type", .value = "application/json" };
            header_count += 1;
        }
        if (self.config.working_directory) |dir| {
            headers_storage[header_count] = .{ .name = "x-opencode-directory", .value = dir };
            header_count += 1;
        }
        if (auth_header) |header| {
            headers_storage[header_count] = header;
            header_count += 1;
        }

        const result = try self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .response_writer = &body_writer.writer,
            .extra_headers = headers_storage[0..header_count],
        });

        return .{
            .status = result.status,
            .body = try body_writer.toOwnedSlice(),
        };
    }

    fn makeAuthorizationHeader(self: *Client) !?std.http.Header {
        const password = self.config.password orelse return null;
        const username = self.config.username orelse "opencode";
        const combined = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ username, password });
        defer self.allocator.free(combined);
        const encoded = try encodeBase64Alloc(self.allocator, combined);
        errdefer self.allocator.free(encoded);
        const value = try std.fmt.allocPrint(self.allocator, "Basic {s}", .{encoded});
        self.allocator.free(encoded);
        return .{ .name = "authorization", .value = value };
    }
};

const HttpResponse = struct {
    status: std.http.Status,
    body: []u8,
};

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{
        .writer = &writer.writer,
        .options = .{},
    };
    try stringify.write(value);
    return writer.toOwnedSlice();
}

fn encodeBase64Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const size = std.base64.standard.Encoder.calcSize(bytes.len);
    const out = try allocator.alloc(u8, size);
    _ = std.base64.standard.Encoder.encode(out, bytes);
    return out;
}

fn getObjectField(value: std.json.Value, field: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(field);
}

fn getOptionalObjectString(value: std.json.Value, field: []const u8) ?[]const u8 {
    const field_value = getObjectField(value, field) orelse return null;
    return switch (field_value) {
        .string => |text| text,
        else => null,
    };
}

fn extractAssistantTextAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    const parts = getObjectField(value, "parts") orelse return allocator.dupe(u8, "");
    if (parts != .array) return allocator.dupe(u8, "");

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);

    for (parts.array.items) |part| {
        if (part != .object) continue;
        const type_name = getOptionalObjectString(part, "type") orelse continue;
        if (!std.mem.eql(u8, type_name, "text")) continue;
        const chunk = getOptionalObjectString(part, "text") orelse "";
        try text.appendSlice(allocator, chunk);
    }

    return text.toOwnedSlice(allocator);
}

fn buildMessageBodyWithModel(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    model_ref: []const u8,
) ![]u8 {
    const provider_id, const model_id = parseModelRef(model_ref);
    return stringifyAlloc(allocator, .{
        .model = .{
            .providerID = provider_id,
            .modelID = model_id,
        },
        .parts = &.{.{ .type = "text", .text = prompt }},
    });
}

fn parseModelRef(model_ref: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.indexOfScalar(u8, model_ref, '/')) |slash| {
        const provider_id = model_ref[0..slash];
        const model_id = model_ref[slash + 1 ..];
        if (provider_id.len > 0 and model_id.len > 0) {
            return .{ provider_id, model_id };
        }
    }

    return .{ "opencode", model_ref };
}

test "extractAssistantTextAlloc joins text parts" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"parts":[{"type":"text","text":"hello "},{"type":"text","text":"world"},{"type":"tool","text":"ignored"}]}
    , .{});
    defer parsed.deinit();

    const text = try extractAssistantTextAlloc(allocator, parsed.value);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello world", text);
}
