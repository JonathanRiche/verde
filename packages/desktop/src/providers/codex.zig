//! Codex provider harness backed by `codex app-server`.

const std = @import("std");
const process_env = @import("../process_env.zig");
const provider_types = @import("../provider_types.zig");

const log = std.log.scoped(.native_codex);

const OVERLOAD_ERROR_CODE = -32001;
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const DEFAULT_WS_URL = "ws://127.0.0.1:4500";
const MAX_WS_MESSAGE_BYTES = 8 * 1024 * 1024;
const MAX_HTTP_LINE_BYTES = 16 * 1024;
const MAX_RPC_RETRIES = 4;
const MAX_CONNECT_WAIT_ATTEMPTS = 30;

fn sleepMs(ms: u64) void {
    const request: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&request, null);
}

const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

pub const Transport = enum(u8) {
    websocket,
    stdio_jsonl,
};

pub const Config = struct {
    executable: []const u8 = "codex",
    cwd: ?[]const u8 = null,
    transport: Transport = .websocket,
    websocket_url: ?[]const u8 = DEFAULT_WS_URL,
    launch_on_connect: bool = true,
};

const SharedServerState = struct {
    mutex: Mutex = .{},
    child: ?std.process.Child = null,
    owns_child: bool = false,
};

var shared_server_state: SharedServerState = .{};

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    stream: ?std.Io.net.Stream = null,
    initialized: bool = false,
    next_request_id: u64 = 1,
    loaded_threads: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, config: Config) !Client {
        var client: Client = .{
            .allocator = allocator,
            .config = config,
            .loaded_threads = std.StringHashMap(void).init(allocator),
        };
        try client.ensureConnected();
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.closeStream();
        self.freeLoadedThreads();
        self.loaded_threads.deinit();
    }

    pub fn authState(self: *Client) !provider_types.AuthState {
        try self.ensureConnected();

        const params = .{ .refreshToken = false };
        const payload = try self.callRpcForResultAlloc("account/read", params);
        defer self.allocator.free(payload);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{});
        defer parsed.deinit();

        const account = getObjectField(parsed.value, "account") orelse return .signed_out;
        return switch (account) {
            .null => .signed_out,
            .object => .signed_in,
            else => .unknown,
        };
    }

    pub fn listThreads(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ChatThreadSummary {
        try self.ensureConnected();

        var threads: std.ArrayList(provider_types.ChatThreadSummary) = .empty;
        defer threads.deinit(allocator);

        var cursor: ?[]u8 = null;
        defer if (cursor) |owned_cursor| self.allocator.free(owned_cursor);

        while (true) {
            const params = .{
                .limit = 100,
                .sortKey = "updated_at",
                .archived = false,
                .cwd = self.config.cwd,
                .cursor = cursor,
            };
            const payload = try self.callRpcForResultAlloc("thread/list", params);
            defer self.allocator.free(payload);

            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{});
            defer parsed.deinit();

            const threads_value = getObjectField(parsed.value, "data") orelse break;
            if (threads_value != .array) break;

            for (threads_value.array.items) |item| {
                if (item != .object) continue;
                const id_value = item.object.get("id") orelse continue;
                const id = stringValue(id_value) orelse continue;
                const title = getOptionalObjectString(item, "name") orelse
                    getOptionalObjectString(item, "title") orelse
                    getOptionalObjectString(item, "preview") orelse
                    id;

                try threads.append(allocator, .{
                    .id = try allocator.dupe(u8, id),
                    .title = try allocator.dupe(u8, title),
                });
            }

            if (cursor) |owned_cursor| {
                self.allocator.free(owned_cursor);
                cursor = null;
            }

            const next_cursor = getOptionalObjectString(parsed.value, "nextCursor") orelse break;
            cursor = try self.allocator.dupe(u8, next_cursor);
        }

        return threads.toOwnedSlice(allocator);
    }

    pub fn listModels(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ModelInfo {
        _ = self;
        _ = allocator;
        return error.UnsupportedOperation;
    }

    pub fn readThread(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
    ) !provider_types.ReadThreadResult {
        try self.ensureConnected();

        const params = .{
            .threadId = thread_id,
            .includeTurns = true,
        };
        const payload = try self.callRpcForResultAlloc("thread/read", params);
        defer self.allocator.free(payload);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{});
        defer parsed.deinit();

        const thread = getObjectField(parsed.value, "thread") orelse return error.MissingThreadId;
        const id = getOptionalObjectString(thread, "id") orelse return error.MissingThreadId;
        const title = getOptionalObjectString(thread, "name") orelse
            getOptionalObjectString(thread, "title") orelse
            getOptionalObjectString(thread, "preview") orelse
            id;

        var messages: std.ArrayList(provider_types.ChatMessage) = .empty;
        defer {
            for (messages.items) |message| {
                allocator.free(message.author);
                allocator.free(message.body);
            }
            messages.deinit(allocator);
        }

        const turns_value = getObjectField(thread, "turns");
        if (turns_value != null and turns_value.? == .array) {
            for (turns_value.?.array.items) |turn| {
                const items_value = getObjectField(turn, "items") orelse continue;
                if (items_value != .array) continue;
                for (items_value.array.items) |item| {
                    try appendImportedMessagesForItem(allocator, item, &messages);
                }
            }
        }

        const owned_messages = try messages.toOwnedSlice(allocator);
        messages = .empty;

        return .{
            .thread_id = try allocator.dupe(u8, id),
            .title = try allocator.dupe(u8, title),
            .updated_at = getOptionalObjectInteger(thread, "updatedAt"),
            .messages = owned_messages,
        };
    }

    pub fn sendPrompt(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.SendPromptRequest,
    ) !provider_types.SendPromptResult {
        try self.ensureConnected();

        const thread_id = if (request.thread_id) |existing|
            try allocator.dupe(u8, existing)
        else
            try self.startThread(allocator, request);
        errdefer allocator.free(thread_id);

        if (request.on_thread_id) |on_thread_id| {
            on_thread_id(request.stream_context, thread_id);
        }

        try self.ensureThreadLoaded(thread_id);

        const reply = try self.startTurnAndCollectReply(allocator, thread_id, request);
        errdefer allocator.free(reply);

        return .{
            .thread_id = thread_id,
            .reply_text = reply,
        };
    }

    pub fn interruptThread(self: *Client, request: provider_types.InterruptThreadRequest) !void {
        try self.ensureConnected();

        if (request.turn_id) |turn_id| {
            const payload = self.callRpcForResultAlloc("turn/interrupt", .{
                .threadId = request.thread_id,
                .turnId = turn_id,
            }) catch |err| switch (err) {
                error.CodexRpcFailed => blk: {
                    break :blk try self.callRpcForResultAlloc("turn/interrupt", .{
                        .threadId = request.thread_id,
                    });
                },
                else => return err,
            };
            self.allocator.free(payload);
            return;
        }

        const payload = try self.callRpcForResultAlloc("turn/interrupt", .{
            .threadId = request.thread_id,
        });
        self.allocator.free(payload);
    }

    pub fn steerThread(self: *Client, request: provider_types.SteerThreadRequest) !void {
        try self.ensureConnected();
        try self.ensureThreadLoaded(request.thread_id);

        const payload = try self.callTurnSteerForResultAlloc(request);
        defer self.allocator.free(payload);
    }

    fn ensureConnected(self: *Client) !void {
        if (self.stream == null) {
            switch (self.config.transport) {
                .websocket => try self.connectWebSocket(),
                .stdio_jsonl => return error.TransportNotImplemented,
            }
        }

        if (!self.initialized) {
            try self.initializeProtocol();
        }
    }

    fn closeStream(self: *Client) void {
        if (self.stream) |stream| {
            self.writeCloseFrame(stream) catch {};
            var threaded = std.Io.Threaded.init_single_threaded;
            stream.close(threaded.io());
            self.stream = null;
        }

        self.initialized = false;
    }

    fn connectWebSocket(self: *Client) !void {
        const raw_url = self.config.websocket_url orelse return error.MissingWebSocketUrl;
        const uri = try std.Uri.parse(raw_url);
        const host_name = try uri.getHostAlloc(self.allocator);
        const host = host_name.bytes;

        if (!std.ascii.eqlIgnoreCase(uri.scheme, "ws")) {
            return error.UnsupportedWebSocketScheme;
        }

        const port = uri.port orelse 80;
        if (try self.tryConnectWebSocket(uri, host, port)) |stream| {
            self.stream = stream;
            return;
        }

        if (!self.config.launch_on_connect) {
            return error.NotConnected;
        }

        shared_server_state.mutex.lock();
        defer shared_server_state.mutex.unlock();

        if (try self.tryConnectWebSocket(uri, host, port)) |stream| {
            self.stream = stream;
            return;
        }

        if (shared_server_state.owns_child) {
            if (try self.waitForWebSocket(uri, host, port, MAX_CONNECT_WAIT_ATTEMPTS)) |stream| {
                self.stream = stream;
                return;
            }
            stopOwnedServerLocked();
            if (try self.tryConnectWebSocket(uri, host, port)) |stream| {
                self.stream = stream;
                return;
            }
        }

        try self.spawnWebSocketServer(raw_url);

        if (try self.waitForWebSocket(uri, host, port, MAX_CONNECT_WAIT_ATTEMPTS)) |stream| {
            self.stream = stream;
            return;
        }

        stopOwnedServerLocked();
        if (try self.tryConnectWebSocket(uri, host, port)) |stream| {
            self.stream = stream;
            return;
        }

        return error.NotConnected;
    }

    fn spawnWebSocketServer(self: *Client, url: []const u8) !void {
        if (shared_server_state.child != null) return;

        var env_map = try process_env.buildAugmentedEnvMap(self.allocator);
        defer env_map.deinit();

        const executable = try process_env.resolveExecutableInEnvMapAlloc(self.allocator, &env_map, self.config.executable);
        defer self.allocator.free(executable);

        var argv = [_][]const u8{
            executable,
            "app-server",
            "--listen",
            url,
        };

        var threaded_spawn = std.Io.Threaded.init_single_threaded;
        const child = try std.process.spawn(threaded_spawn.io(), .{
            .argv = argv[0..],
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
            .cwd = if (self.config.cwd) |path| .{ .path = path } else .inherit,
            .environ_map = &env_map,
        });

        log.info("Codex app-server started pid={d} listen={s}", .{ child.id orelse -1, url });
        shared_server_state.child = child;
        shared_server_state.owns_child = true;
    }

    fn tryConnectWebSocket(
        self: *Client,
        uri: std.Uri,
        host: []const u8,
        port: u16,
    ) !?std.Io.net.Stream {
        var threaded = std.Io.Threaded.init_single_threaded;
        const address = std.Io.net.IpAddress.parse(host, port) catch
            std.Io.net.IpAddress.resolve(threaded.io(), host, port) catch return null;
        const stream = address.connect(threaded.io(), .{ .mode = .stream }) catch return null;
        errdefer stream.close(threaded.io());

        try self.performWebSocketHandshake(stream, uri, host, port);
        return stream;
    }

    fn waitForWebSocket(
        self: *Client,
        uri: std.Uri,
        host: []const u8,
        port: u16,
        attempts: usize,
    ) !?std.Io.net.Stream {
        var attempt: usize = 0;
        while (attempt < attempts) : (attempt += 1) {
            if (try self.tryConnectWebSocket(uri, host, port)) |stream| {
                return stream;
            }
            sleepMs(100);
        }
        return null;
    }

    fn performWebSocketHandshake(
        self: *Client,
        stream: std.Io.net.Stream,
        uri: std.Uri,
        host: []const u8,
        port: u16,
    ) !void {
        var nonce: [16]u8 = undefined;
        var threaded = std.Io.Threaded.init_single_threaded;
        try std.Io.randomSecure(threaded.io(), &nonce);

        const key = try encodeBase64Alloc(self.allocator, &nonce);
        defer self.allocator.free(key);

        const accept_expected = try computeAcceptKeyAlloc(self.allocator, key);
        defer self.allocator.free(accept_expected);

        const host_header = if (port == 80)
            try self.allocator.dupe(u8, host)
        else
            try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ host, port });
        defer self.allocator.free(host_header);

        const request_target = try buildRequestTargetAlloc(self.allocator, uri);
        defer self.allocator.free(request_target);

        const request = try std.fmt.allocPrint(
            self.allocator,
            "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
            .{ request_target, host_header, key },
        );
        defer self.allocator.free(request);

        try streamWriteAll(stream, request);

        const status_line = try readHttpLineAlloc(self.allocator, stream);
        defer self.allocator.free(status_line);
        if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 101")) {
            return error.WebSocketUpgradeRejected;
        }

        var accept_header: ?[]u8 = null;
        defer if (accept_header) |line| self.allocator.free(line);

        while (true) {
            const line = try readHttpLineAlloc(self.allocator, stream);
            if (line.len == 0) {
                self.allocator.free(line);
                break;
            }

            if (std.ascii.startsWithIgnoreCase(line, "sec-websocket-accept:")) {
                accept_header = line;
            } else {
                self.allocator.free(line);
            }
        }

        const accept_line = accept_header orelse return error.MissingWebSocketAccept;
        const colon_index = std.mem.indexOfScalar(u8, accept_line, ':') orelse return error.MissingWebSocketAccept;
        const accept_value = std.mem.trim(u8, accept_line[colon_index + 1 ..], " \t");
        if (!std.mem.eql(u8, accept_value, accept_expected)) {
            return error.WebSocketAcceptMismatch;
        }
    }

    fn initializeProtocol(self: *Client) !void {
        const params = .{
            .clientInfo = .{
                .name = "editorts_native",
                .title = "EditorTs Native",
                .version = "0.1.0",
            },
            .capabilities = .{
                .experimentalApi = true,
            },
        };

        const payload = try self.callRpcForResultAlloc("initialize", params);
        self.allocator.free(payload);

        try self.sendNotification("initialized", .{});
        self.initialized = true;
    }

    fn startThread(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.SendPromptRequest,
    ) ![]u8 {
        const payload = try self.callThreadStartAlloc(request);
        defer self.allocator.free(payload);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{});
        defer parsed.deinit();

        const thread = getObjectField(parsed.value, "thread") orelse return error.MissingThreadId;
        const id = getOptionalObjectString(thread, "id") orelse return error.MissingThreadId;
        try self.rememberLoadedThread(id);
        return allocator.dupe(u8, id);
    }

    fn callThreadStartAlloc(self: *Client, request: provider_types.SendPromptRequest) ![]u8 {
        const id = self.next_request_id;
        self.next_request_id += 1;

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();

        var stringify: std.json.Stringify = .{
            .writer = &writer.writer,
            .options = .{},
        };

        try stringify.beginObject();
        try stringify.objectField("method");
        try stringify.write("thread/start");
        try stringify.objectField("id");
        try stringify.write(id);
        try stringify.objectField("params");
        try stringify.beginObject();
        if (request.cwd) |working_dir| {
            try stringify.objectField("cwd");
            try stringify.write(working_dir);
        }
        if (request.model) |selected_model| {
            try stringify.objectField("model");
            try stringify.write(selected_model);
        }
        if (request.service_tier) |service_tier| {
            try stringify.objectField("serviceTier");
            try stringify.write(service_tier);
        }
        if (request.approval_policy) |approval_policy| {
            try stringify.objectField("approvalPolicy");
            try stringify.write(approvalPolicyString(approval_policy));
        }
        if (request.sandbox_mode) |sandbox_mode| {
            try stringify.objectField("sandbox");
            try stringify.write(sandboxModeString(sandbox_mode));
        }
        try stringify.objectField("experimentalRawEvents");
        try stringify.write(false);
        try stringify.objectField("persistExtendedHistory");
        try stringify.write(true);
        try stringify.endObject();
        try stringify.endObject();

        const payload = try writer.toOwnedSlice();
        defer self.allocator.free(payload);
        log.info("Codex RPC thread/start id={d} payload_len={d}", .{ id, payload.len });
        try self.writeTextMessage(payload);
        const result = try self.awaitResultPayloadAlloc(id);
        log.info("Codex RPC thread/start id={d} result_len={d}", .{ id, result.len });
        return result;
    }

    fn ensureThreadLoaded(self: *Client, thread_id: []const u8) !void {
        if (self.loaded_threads.contains(thread_id)) return;

        const params = .{
            .threadId = thread_id,
        };
        const payload = try self.callRpcForResultAlloc("thread/resume", params);
        defer self.allocator.free(payload);

        try self.rememberLoadedThread(thread_id);
    }

    fn rememberLoadedThread(self: *Client, thread_id: []const u8) !void {
        const owned = try self.allocator.dupe(u8, thread_id);
        errdefer self.allocator.free(owned);

        const gop = try self.loaded_threads.getOrPut(owned);
        if (gop.found_existing) {
            self.allocator.free(owned);
            return;
        }
        gop.value_ptr.* = {};
    }

    fn startTurnAndCollectReply(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
        request: provider_types.SendPromptRequest,
    ) ![]u8 {
        const request_id = try self.sendTurnStartRequest(thread_id, request);
        var turn_started = false;
        var started_turn_id: ?[]u8 = null;
        defer if (started_turn_id) |turn_id| allocator.free(turn_id);
        var reply: std.ArrayList(u8) = .empty;
        defer reply.deinit(allocator);

        while (true) {
            const message = try self.readTextMessageAlloc(self.allocator);
            defer self.allocator.free(message);

            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, message, .{});
            defer parsed.deinit();

            const root = parsed.value;
            if (try self.maybeHandleServerRequest(root, request)) {
                continue;
            }
            if (try self.maybeHandleMatchingResponse(root, request_id)) {
                turn_started = true;
                if (started_turn_id == null) {
                    if (extractTurnIdFromStartResponse(root)) |turn_id| {
                        started_turn_id = try allocator.dupe(u8, turn_id);
                        if (request.on_turn_id) |on_turn_id| {
                            on_turn_id(request.stream_context, turn_id);
                        }
                    }
                }
                continue;
            }

            if (!turn_started) continue;

            if (started_turn_id == null) {
                if (extractTurnIdFromStartedNotification(root, thread_id)) |turn_id| {
                    started_turn_id = try allocator.dupe(u8, turn_id);
                    if (request.on_turn_id) |on_turn_id| {
                        on_turn_id(request.stream_context, turn_id);
                    }
                }
            }

            try emitNotificationEvent(self, root, request);

            if (try appendNotificationDelta(root, allocator, &reply)) {
                if (request.on_stream_delta) |on_stream_delta| {
                    if (extractNotificationDelta(root)) |delta| {
                        on_stream_delta(request.stream_context, delta);
                    }
                }
                continue;
            }

            if (detectTurnTerminalState(root, thread_id, started_turn_id)) |terminal_state| {
                switch (terminal_state) {
                    .completed => break,
                    .failed => return error.CodexTurnFailed,
                    .interrupted => return error.CodexTurnInterrupted,
                }
            }
        }

        return reply.toOwnedSlice(allocator);
    }

    fn sendTurnStartRequest(
        self: *Client,
        thread_id: []const u8,
        request: provider_types.SendPromptRequest,
    ) !u64 {
        const id = self.next_request_id;
        self.next_request_id += 1;

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();

        var stringify: std.json.Stringify = .{
            .writer = &writer.writer,
            .options = .{},
        };

        try stringify.beginObject();
        try stringify.objectField("method");
        try stringify.write("turn/start");
        try stringify.objectField("id");
        try stringify.write(id);
        try stringify.objectField("params");
        try stringify.beginObject();
        try stringify.objectField("threadId");
        try stringify.write(thread_id);
        if (request.cwd) |working_dir| {
            try stringify.objectField("cwd");
            try stringify.write(working_dir);
        }
        if (request.model) |selected_model| {
            try stringify.objectField("model");
            try stringify.write(selected_model);
        }
        if (request.service_tier) |service_tier| {
            try stringify.objectField("serviceTier");
            try stringify.write(service_tier);
        }
        if (request.reasoning_effort) |effort| {
            try stringify.objectField("effort");
            try stringify.write(effort);
        }
        try stringify.objectField("input");
        try stringify.beginArray();
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("text");
        try stringify.objectField("text");
        try stringify.write(request.prompt);
        try stringify.endObject();
        if (request.image) |image| {
            try stringify.beginObject();
            try stringify.objectField("type");
            try stringify.write("localImage");
            try stringify.objectField("path");
            try stringify.write(image.path);
            try stringify.endObject();
        }
        try stringify.endArray();
        try stringify.endObject();
        try stringify.endObject();

        const payload = try writer.toOwnedSlice();
        defer self.allocator.free(payload);
        log.info("Codex RPC turn/start id={d} thread_id={s} payload_len={d}", .{ id, thread_id, payload.len });
        try self.writeTextMessage(payload);
        return id;
    }

    fn freeLoadedThreads(self: *Client) void {
        var it = self.loaded_threads.keyIterator();
        while (it.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
    }

    fn sendNotification(self: *Client, method: []const u8, params: anytype) !void {
        const message = .{
            .method = method,
            .params = params,
        };
        const payload = try stringifyAlloc(self.allocator, message);
        defer self.allocator.free(payload);
        try self.writeTextMessage(payload);
    }

    fn sendRequest(self: *Client, method: []const u8, params: anytype) !u64 {
        const id = self.next_request_id;
        self.next_request_id += 1;

        const message = .{
            .method = method,
            .id = id,
            .params = params,
        };

        const payload = try stringifyAlloc(self.allocator, message);
        defer self.allocator.free(payload);
        try self.writeTextMessage(payload);
        return id;
    }

    fn callTurnSteerForResultAlloc(self: *Client, request: provider_types.SteerThreadRequest) ![]u8 {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const id = try self.sendRequest("turn/steer", .{
                .threadId = request.thread_id,
                .input = .{
                    .{
                        .type = "text",
                        .text = request.prompt,
                    },
                },
                .expectedTurnId = request.turn_id,
            });
            const maybe_payload = self.awaitTurnSteerResultPayloadAlloc(id);
            if (maybe_payload) |payload| {
                return payload;
            } else |err| switch (err) {
                error.ServerOverloaded => {
                    if (attempt + 1 >= MAX_RPC_RETRIES) return err;
                    sleepMs(@min(@as(u64, 100) * (@as(u64, 1) << @intCast(attempt)), 1500));
                    continue;
                },
                else => return err,
            }
        }
    }

    fn callRpcForResultAlloc(self: *Client, method: []const u8, params: anytype) ![]u8 {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const id = try self.sendRequest(method, params);
            const maybe_payload = self.awaitResultPayloadAlloc(id);
            if (maybe_payload) |payload| {
                return payload;
            } else |err| switch (err) {
                error.ServerOverloaded => {
                    if (attempt + 1 >= MAX_RPC_RETRIES) return err;
                    sleepMs(@min(@as(u64, 100) * (@as(u64, 1) << @intCast(attempt)), 1500));
                    continue;
                },
                else => return err,
            }
        }
    }

    fn awaitResultPayloadAlloc(self: *Client, id: u64) ![]u8 {
        while (true) {
            const message = try self.readTextMessageAlloc(self.allocator);
            defer self.allocator.free(message);

            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, message, .{});
            defer parsed.deinit();

            const root = parsed.value;
            const response_id = parseMessageId(root) orelse {
                continue;
            };

            if (response_id != id) continue;

            if (getObjectField(root, "error")) |rpc_error| {
                log.warn("Codex RPC response id={d} returned error: {s}", .{ id, message });
                if (getOptionalObjectInteger(rpc_error, "code")) |code| {
                    if (code == OVERLOAD_ERROR_CODE) return error.ServerOverloaded;
                }
                return error.CodexRpcFailed;
            }

            const result = getObjectField(root, "result") orelse return error.MissingRpcResult;
            const payload = try stringifyAlloc(self.allocator, result);
            log.info("Codex RPC response id={d} message_len={d} result_len={d}", .{ id, message.len, payload.len });
            return payload;
        }
    }

    fn awaitTurnSteerResultPayloadAlloc(self: *Client, id: u64) ![]u8 {
        while (true) {
            const message = try self.readTextMessageAlloc(self.allocator);
            defer self.allocator.free(message);

            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, message, .{});
            defer parsed.deinit();

            const root = parsed.value;
            const response_id = parseMessageId(root) orelse {
                continue;
            };

            if (response_id != id) continue;

            if (getObjectField(root, "error")) |_| {
                if (std.mem.indexOf(u8, message, "activeTurnNotSteerable") != null or
                    std.mem.indexOf(u8, message, "active_turn_not_steerable") != null or
                    std.mem.indexOf(u8, message, "active turn not steerable") != null)
                {
                    return error.CodexActiveTurnNotSteerable;
                }
                if (std.mem.indexOf(u8, message, "code") != null) {
                    if (getObjectField(getObjectField(root, "error").?, "code")) |code_value| {
                        if (code_value == .integer and code_value.integer == OVERLOAD_ERROR_CODE) {
                            return error.ServerOverloaded;
                        }
                    }
                }
                return error.CodexRpcFailed;
            }

            const result = getObjectField(root, "result") orelse return error.MissingRpcResult;
            return try stringifyAlloc(self.allocator, result);
        }
    }

    fn maybeHandleMatchingResponse(self: *Client, root: std.json.Value, id: u64) !bool {
        _ = self;
        const response_id = parseMessageId(root) orelse return false;
        if (response_id != id) return false;

        if (getObjectField(root, "error")) |rpc_error| {
            if (getOptionalObjectInteger(rpc_error, "code")) |code| {
                if (code == OVERLOAD_ERROR_CODE) {
                    return error.ServerOverloaded;
                }
            }
            return error.CodexRpcFailed;
        }

        return true;
    }

    fn maybeHandleServerRequest(self: *Client, root: std.json.Value, request: provider_types.SendPromptRequest) !bool {
        const method = getOptionalObjectString(root, "method") orelse return false;
        const request_id = parseMessageId(root) orelse return false;

        if (std.mem.eql(u8, method, "item/commandExecution/requestApproval")) {
            try handleCommandApprovalRequest(self, root, request_id, request);
            return true;
        }
        if (std.mem.eql(u8, method, "item/fileChange/requestApproval")) {
            try handleFileChangeApprovalRequest(self, root, request_id, request);
            return true;
        }
        if (std.mem.eql(u8, method, "item/permissions/requestApproval")) {
            try handlePermissionsApprovalRequest(self, root, request_id, request);
            return true;
        }

        return false;
    }

    fn writeTextMessage(self: *Client, payload: []const u8) !void {
        const stream = self.stream orelse return error.NotConnected;
        try writeClientFrame(self.allocator, stream, payload, .text);
    }

    fn writeCloseFrame(self: *Client, stream: std.Io.net.Stream) !void {
        try writeClientFrame(self.allocator, stream, "", .connection_close);
    }

    fn readTextMessageAlloc(self: *Client, allocator: std.mem.Allocator) ![]u8 {
        const stream = self.stream orelse return error.NotConnected;

        while (true) {
            const frame = try readServerFrameAlloc(allocator, stream);
            errdefer allocator.free(frame.payload);

            switch (frame.opcode) {
                .pong => {
                    allocator.free(frame.payload);
                    continue;
                },
                .ping => {
                    defer allocator.free(frame.payload);
                    try writeClientFrame(self.allocator, stream, frame.payload, .pong);
                    continue;
                },
                .connection_close => {
                    allocator.free(frame.payload);
                    return error.ConnectionClosed;
                },
                .text => return frame.payload,
                else => {
                    allocator.free(frame.payload);
                    return error.UnexpectedWebSocketFrame;
                },
            }
        }
    }
};

pub fn shutdownOwnedServer() void {
    shared_server_state.mutex.lock();
    defer shared_server_state.mutex.unlock();
    stopOwnedServerLocked();
}

fn stopOwnedServerLocked() void {
    if (shared_server_state.child) |*child| {
        if (shared_server_state.owns_child) {
            log.info("stopping owned Codex app-server pid={d}", .{child.id orelse -1});
            var threaded = std.Io.Threaded.init_single_threaded;
            child.kill(threaded.io());
            _ = child.wait(threaded.io()) catch {};
        }
        shared_server_state.child = null;
        shared_server_state.owns_child = false;
    }
}

const FrameOpcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    connection_close = 8,
    ping = 9,
    pong = 10,
    _,
};

const Frame = struct {
    opcode: FrameOpcode,
    payload: []u8,
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

fn computeAcceptKeyAlloc(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var sha_input: std.ArrayList(u8) = .empty;
    defer sha_input.deinit(allocator);
    try sha_input.appendSlice(allocator, key);
    try sha_input.appendSlice(allocator, WS_GUID);

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(sha_input.items, &digest, .{});
    return encodeBase64Alloc(allocator, &digest);
}

fn buildRequestTargetAlloc(allocator: std.mem.Allocator, uri: std.Uri) ![]u8 {
    const path = switch (uri.path) {
        .raw => |raw| if (raw.len == 0) "/" else raw,
        .percent_encoded => |encoded| if (encoded.len == 0) "/" else encoded,
    };

    var target = std.ArrayList(u8).empty;
    defer target.deinit(allocator);
    try target.appendSlice(allocator, path);

    if (uri.query) |query| {
        try target.append(allocator, '?');
        switch (query) {
            .raw => |raw| try target.appendSlice(allocator, raw),
            .percent_encoded => |encoded| try target.appendSlice(allocator, encoded),
        }
    }

    return target.toOwnedSlice(allocator);
}

fn readHttpLineAlloc(allocator: std.mem.Allocator, stream: std.Io.net.Stream) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);

    while (true) {
        var byte: [1]u8 = undefined;
        const read = try streamRead(stream, &byte);
        if (read == 0) return error.EndOfStream;

        if (byte[0] == '\n') break;
        if (line.items.len >= MAX_HTTP_LINE_BYTES) return error.HttpLineTooLong;
        if (byte[0] != '\r') {
            try line.append(allocator, byte[0]);
        }
    }

    return line.toOwnedSlice(allocator);
}

fn readExact(stream: std.Io.net.Stream, buffer: []u8) !void {
    var index: usize = 0;
    while (index < buffer.len) {
        const amt = try streamRead(stream, buffer[index..]);
        if (amt == 0) return error.EndOfStream;
        index += amt;
    }
}

fn writeClientFrame(
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    payload: []const u8,
    opcode: FrameOpcode,
) !void {
    var header: [14]u8 = undefined;
    var index: usize = 0;

    header[index] = @as(u8, 0x80) | @as(u8, @intCast(@intFromEnum(opcode)));
    index += 1;

    if (payload.len <= 125) {
        header[index] = 0x80 | @as(u8, @intCast(payload.len));
        index += 1;
    } else if (payload.len <= std.math.maxInt(u16)) {
        header[index] = 0x80 | 126;
        index += 1;
        var len16: [2]u8 = undefined;
        std.mem.writeInt(u16, &len16, @intCast(payload.len), .big);
        @memcpy(header[index .. index + len16.len], &len16);
        index += 2;
    } else {
        header[index] = 0x80 | 127;
        index += 1;
        var len64: [8]u8 = undefined;
        std.mem.writeInt(u64, &len64, payload.len, .big);
        @memcpy(header[index .. index + len64.len], &len64);
        index += 8;
    }

    var mask: [4]u8 = undefined;
    var threaded = std.Io.Threaded.init_single_threaded;
    try std.Io.randomSecure(threaded.io(), &mask);
    @memcpy(header[index .. index + 4], &mask);
    index += 4;

    const masked = try allocator.alloc(u8, payload.len);
    defer allocator.free(masked);
    for (payload, 0..) |byte, i| {
        masked[i] = byte ^ mask[i % mask.len];
    }

    try streamWriteAll(stream, header[0..index]);
    try streamWriteAll(stream, masked);
}

fn streamRead(stream: std.Io.net.Stream, buffer: []u8) !usize {
    if (buffer.len == 0) return 0;

    while (true) {
        const result = std.c.recv(stream.socket.handle, buffer.ptr, buffer.len, 0);
        if (result >= 0) return @intCast(result);

        return switch (@as(std.c.E, @enumFromInt(std.c._errno().*))) {
            .INTR => continue,
            .AGAIN => error.WouldBlock,
            else => error.InputOutput,
        };
    }
}

fn streamWriteAll(stream: std.Io.net.Stream, bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        const result = std.c.send(stream.socket.handle, bytes[index..].ptr, bytes.len - index, 0);
        if (result > 0) {
            index += @intCast(result);
            continue;
        }
        if (result == 0) return error.EndOfStream;

        return switch (@as(std.c.E, @enumFromInt(std.c._errno().*))) {
            .INTR => continue,
            .AGAIN => error.WouldBlock,
            else => error.InputOutput,
        };
    }
}

fn readServerFrameAlloc(allocator: std.mem.Allocator, stream: std.Io.net.Stream) !Frame {
    var header: [2]u8 = undefined;
    try readExact(stream, &header);

    const opcode: FrameOpcode = @enumFromInt(header[0] & 0x0f);
    const masked = (header[1] & 0x80) != 0;
    const len_marker = header[1] & 0x7f;

    const payload_len: usize = switch (len_marker) {
        126 => blk: {
            var buf: [2]u8 = undefined;
            try readExact(stream, &buf);
            break :blk std.mem.readInt(u16, &buf, .big);
        },
        127 => blk: {
            var buf: [8]u8 = undefined;
            try readExact(stream, &buf);
            const long = std.mem.readInt(u64, &buf, .big);
            break :blk std.math.cast(usize, long) orelse return error.WebSocketMessageTooLarge;
        },
        else => len_marker,
    };

    if (payload_len > MAX_WS_MESSAGE_BYTES) return error.WebSocketMessageTooLarge;
    log.debug("Codex websocket frame opcode={s} masked={} payload_len={d}", .{ @tagName(opcode), masked, payload_len });

    var mask: [4]u8 = undefined;
    if (masked) {
        try readExact(stream, &mask);
    }

    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    try readExact(stream, payload);

    if (masked) {
        for (payload, 0..) |*byte, i| {
            byte.* ^= mask[i % mask.len];
        }
    }

    return .{
        .opcode = opcode,
        .payload = payload,
    };
}

fn parseMessageId(root: std.json.Value) ?u64 {
    const id_value = getObjectField(root, "id") orelse return null;
    return switch (id_value) {
        .integer => |value| if (value < 0) null else @as(u64, @intCast(value)),
        else => null,
    };
}

fn getObjectField(value: std.json.Value, field: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(field);
}

fn stringValue(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn getOptionalObjectString(value: std.json.Value, field: []const u8) ?[]const u8 {
    const field_value = getObjectField(value, field) orelse return null;
    return stringValue(field_value);
}

fn getOptionalObjectInteger(value: std.json.Value, field: []const u8) ?i64 {
    const field_value = getObjectField(value, field) orelse return null;
    return switch (field_value) {
        .integer => |number| number,
        else => null,
    };
}

fn appendImportedMessagesForItem(
    allocator: std.mem.Allocator,
    item: std.json.Value,
    messages: *std.ArrayList(provider_types.ChatMessage),
) !void {
    const item_type = getOptionalObjectString(item, "type") orelse return;

    if (std.mem.eql(u8, item_type, "userMessage")) {
        const content = getObjectField(item, "content") orelse return;
        const body = try flattenUserMessageContentAlloc(allocator, content);
        defer allocator.free(body);
        if (std.mem.trim(u8, body, &std.ascii.whitespace).len == 0) return;
        try appendImportedMessage(allocator, messages, .user, "You", body);
        return;
    }

    if (std.mem.eql(u8, item_type, "agentMessage")) {
        const text = getOptionalObjectString(item, "text") orelse return;
        if (std.mem.trim(u8, text, &std.ascii.whitespace).len == 0) return;
        try appendImportedMessage(allocator, messages, .assistant, "Codex", text);
        return;
    }

    if (std.mem.eql(u8, item_type, "commandExecution")) {
        const command = getOptionalObjectString(item, "command") orelse return;
        const status = getOptionalObjectString(item, "status") orelse "completed";
        const author: []const u8 = if (std.mem.eql(u8, status, "failed")) "Command failed" else "Ran command";
        try appendImportedMessage(allocator, messages, .system, author, command);
        return;
    }

    if (std.mem.eql(u8, item_type, "fileChange")) {
        const changes = getObjectField(item, "changes") orelse return;
        const body = try buildImportedFileChangeSummaryAlloc(allocator, changes);
        defer allocator.free(body);
        if (std.mem.trim(u8, body, &std.ascii.whitespace).len == 0) return;
        try appendImportedMessage(allocator, messages, .system, "Changed files", body);
        return;
    }

    if (std.mem.eql(u8, item_type, "webSearch")) {
        const query = getOptionalObjectString(item, "query") orelse return;
        if (std.mem.trim(u8, query, &std.ascii.whitespace).len == 0) return;
        try appendImportedMessage(allocator, messages, .system, "Web search", query);
    }
}

fn appendImportedMessage(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(provider_types.ChatMessage),
    role: provider_types.MessageRole,
    author: []const u8,
    body: []const u8,
) !void {
    try messages.append(allocator, .{
        .role = role,
        .author = try allocator.dupe(u8, author),
        .body = try allocator.dupe(u8, body),
    });
}

fn flattenUserMessageContentAlloc(allocator: std.mem.Allocator, content: std.json.Value) ![]u8 {
    if (content != .array) return allocator.dupe(u8, "");

    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(allocator);

    for (content.array.items) |entry| {
        if (entry != .object) continue;
        const content_type = getOptionalObjectString(entry, "type") orelse continue;
        var segment: ?[]const u8 = null;

        if (std.mem.eql(u8, content_type, "text")) {
            segment = getOptionalObjectString(entry, "text");
        } else if (std.mem.eql(u8, content_type, "mention")) {
            segment = getOptionalObjectString(entry, "path") orelse getOptionalObjectString(entry, "name");
        } else if (std.mem.eql(u8, content_type, "skill")) {
            segment = getOptionalObjectString(entry, "name");
        }

        if (segment) |text| {
            if (text.len == 0) continue;
            if (builder.items.len > 0) try builder.appendSlice(allocator, "\n\n");
            try builder.appendSlice(allocator, text);
            continue;
        }

        if (std.mem.eql(u8, content_type, "localImage")) {
            const path = getOptionalObjectString(entry, "path") orelse continue;
            if (builder.items.len > 0) try builder.appendSlice(allocator, "\n\n");
            const label = try std.fmt.allocPrint(allocator, "[Image: {s}]", .{path});
            defer allocator.free(label);
            try builder.appendSlice(allocator, label);
            continue;
        }

        if (std.mem.eql(u8, content_type, "image")) {
            const url = getOptionalObjectString(entry, "url") orelse continue;
            if (builder.items.len > 0) try builder.appendSlice(allocator, "\n\n");
            const label = try std.fmt.allocPrint(allocator, "[Image: {s}]", .{url});
            defer allocator.free(label);
            try builder.appendSlice(allocator, label);
        }
    }

    return builder.toOwnedSlice(allocator);
}

fn buildImportedFileChangeSummaryAlloc(allocator: std.mem.Allocator, changes: std.json.Value) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    if (changes != .array) return allocator.dupe(u8, "");

    for (changes.array.items) |change| {
        const path = getOptionalObjectString(change, "path") orelse continue;
        const additions = countDiffLines(change, '+');
        const deletions = countDiffLines(change, '-');
        if (body.items.len > 0) try body.append(allocator, '\n');
        const line = try std.fmt.allocPrint(allocator, "{s}  +{d} / -{d}", .{
            path,
            additions,
            deletions,
        });
        defer allocator.free(line);
        try body.appendSlice(allocator, line);
    }

    return body.toOwnedSlice(allocator);
}

fn appendNotificationDelta(
    root: std.json.Value,
    allocator: std.mem.Allocator,
    reply: *std.ArrayList(u8),
) !bool {
    const method = getOptionalObjectString(root, "method") orelse return false;
    if (!std.mem.eql(u8, method, "item/agentMessage/delta")) {
        return false;
    }

    const params = getObjectField(root, "params") orelse return true;

    if (findFirstStringByPath(params, &.{ "delta", "text" })) |text| {
        try reply.appendSlice(allocator, text);
        return true;
    }
    if (findFirstStringByPath(params, &.{"delta"})) |text| {
        try reply.appendSlice(allocator, text);
        return true;
    }
    if (findFirstStringByPath(params, &.{ "item", "text" })) |text| {
        try reply.appendSlice(allocator, text);
        return true;
    }
    if (findFirstStringByPath(params, &.{"text"})) |text| {
        try reply.appendSlice(allocator, text);
        return true;
    }

    return true;
}

fn extractNotificationDelta(root: std.json.Value) ?[]const u8 {
    const method = getOptionalObjectString(root, "method") orelse return null;
    if (!std.mem.eql(u8, method, "item/agentMessage/delta")) {
        return null;
    }

    const params = getObjectField(root, "params") orelse return null;

    return findFirstStringByPath(params, &.{ "delta", "text" }) orelse
        findFirstStringByPath(params, &.{"delta"}) orelse
        findFirstStringByPath(params, &.{ "item", "text" }) orelse
        findFirstStringByPath(params, &.{"text"});
}

fn emitNotificationEvent(self: *Client, root: std.json.Value, request: provider_types.SendPromptRequest) !void {
    _ = self;
    const method = getOptionalObjectString(root, "method") orelse return;

    const on_stream_event = request.on_stream_event orelse return;

    if (std.mem.eql(u8, method, "item/started") or std.mem.eql(u8, method, "item/completed")) {
        if (emitItemEvent(root, request.stream_context, on_stream_event)) {
            return;
        }
    }

    if (std.mem.eql(u8, method, "turn/diff/updated")) {
        if (buildDiffSummary(root, request.stream_context, on_stream_event)) {
            return;
        }
    }

    if (std.mem.eql(u8, method, "item/commandExecution/outputDelta")) {
        if (extractCommandSummary(root)) |command| {
            on_stream_event(request.stream_context, .{ .message = .{
                .title = "Ran command",
                .body = command,
            } });
            return;
        }
    }

    if (std.mem.eql(u8, method, "item/fileChange/outputDelta")) {
        if (buildDiffSummary(root, request.stream_context, on_stream_event)) {
            return;
        }
    }

    if (std.mem.indexOf(u8, method, "toolCall") != null or
        std.mem.indexOf(u8, method, "exec") != null or
        std.mem.eql(u8, method, "command/exec"))
    {
        if (extractCommandSummary(root)) |command| {
            on_stream_event(request.stream_context, .{ .message = .{
                .title = "Ran command",
                .body = command,
            } });
            return;
        }

        on_stream_event(request.stream_context, .{ .message = .{
            .title = "Tool call",
            .body = method,
        } });
    }
}

fn emitItemEvent(
    root: std.json.Value,
    context: ?*anyopaque,
    on_stream_event: *const fn (?*anyopaque, provider_types.StreamEvent) void,
) bool {
    const params = getObjectField(root, "params") orelse return false;
    const item = getObjectField(params, "item") orelse return false;
    const item_type = getOptionalObjectString(item, "type") orelse return false;

    if (std.mem.eql(u8, item_type, "commandExecution")) {
        const command = getOptionalObjectString(item, "command") orelse return false;
        const status = getOptionalObjectString(item, "status") orelse "completed";
        on_stream_event(context, .{ .message = .{
            .title = if (std.mem.eql(u8, status, "failed")) "Command failed" else "Ran command",
            .body = command,
        } });
        return true;
    }

    if (std.mem.eql(u8, item_type, "fileChange")) {
        if (buildFileChangeItemSummary(item, context, on_stream_event)) {
            return true;
        }
    }

    return false;
}

fn handleCommandApprovalRequest(self: *Client, root: std.json.Value, request_id: u64, request: provider_types.SendPromptRequest) !void {
    const decision = if (shouldAutoApproveRequest(request))
        .approve
    else blk: {
        const on_approval_request = request.on_approval_request orelse return;
        const body = extractCommandApprovalSummary(root) orelse "Codex requested command approval.";
        break :blk on_approval_request(request.stream_context, .{
            .call_id = "",
            .title = "Command approval",
            .body = body,
        });
    };

    try respondToServerRequest(request_id, self, .{
        .decision = approvalDecisionString(decision),
    });
}

fn handleFileChangeApprovalRequest(self: *Client, root: std.json.Value, request_id: u64, request: provider_types.SendPromptRequest) !void {
    const decision = if (shouldAutoApproveRequest(request))
        .approve
    else blk: {
        const on_approval_request = request.on_approval_request orelse return;
        const body = extractFileChangeApprovalSummary(root) orelse "Codex requested file change approval.";
        break :blk on_approval_request(request.stream_context, .{
            .call_id = "",
            .title = "File change approval",
            .body = body,
        });
    };

    try respondToServerRequest(request_id, self, .{
        .decision = approvalDecisionString(decision),
    });
}

fn handlePermissionsApprovalRequest(self: *Client, root: std.json.Value, request_id: u64, request: provider_types.SendPromptRequest) !void {
    const decision = if (shouldAutoApproveRequest(request))
        .approve
    else blk: {
        const on_approval_request = request.on_approval_request orelse return;
        const body = extractPermissionsApprovalSummary(root) orelse "Codex requested additional permissions.";
        break :blk on_approval_request(request.stream_context, .{
            .call_id = "",
            .title = "Permissions request",
            .body = body,
        });
    };

    try respondToServerRequest(request_id, self, .{
        .decision = approvalDecisionString(decision),
    });
}

fn respondToServerRequest(request_id: u64, self: *Client, result: anytype) !void {
    const payload = try stringifyAlloc(self.allocator, .{
        .id = request_id,
        .result = result,
    });
    defer self.allocator.free(payload);
    try self.writeTextMessage(payload);
}

fn respondServerError(request_id: u64, self: *Client, code: i64, message: []const u8) !void {
    const payload = try stringifyAlloc(self.allocator, .{
        .id = request_id,
        .@"error" = .{
            .code = code,
            .message = message,
        },
    });
    defer self.allocator.free(payload);
    try self.writeTextMessage(payload);
}

fn buildDiffSummary(
    root: std.json.Value,
    context: ?*anyopaque,
    on_stream_event: *const fn (?*anyopaque, provider_types.StreamEvent) void,
) bool {
    const params = getObjectField(root, "params") orelse return false;
    var files: std.ArrayList(provider_types.StreamDiffFile) = .empty;
    defer files.deinit(std.heap.page_allocator);

    if (!appendDiffFiles(params, &files)) return false;
    on_stream_event(context, .{ .diff = .{
        .files = files.items,
    } });
    return true;
}

fn buildFileChangeItemSummary(
    item: std.json.Value,
    context: ?*anyopaque,
    on_stream_event: *const fn (?*anyopaque, provider_types.StreamEvent) void,
) bool {
    const changes = getObjectField(item, "changes") orelse return false;
    var files: std.ArrayList(provider_types.StreamDiffFile) = .empty;
    defer files.deinit(std.heap.page_allocator);

    if (!appendDiffFiles(changes, &files)) return false;
    on_stream_event(context, .{ .diff = .{
        .files = files.items,
    } });
    return true;
}

fn appendDiffFiles(value: std.json.Value, files: *std.ArrayList(provider_types.StreamDiffFile)) bool {
    switch (value) {
        .object => |obj| {
            if (extractPathFromValue(value)) |path| {
                const additions = findFirstIntegerByField(value, "additions") orelse
                    findFirstIntegerByField(value, "addedLines") orelse
                    findFirstIntegerByField(value, "added") orelse
                    countDiffLines(value, '+');
                const deletions = findFirstIntegerByField(value, "deletions") orelse
                    findFirstIntegerByField(value, "removedLines") orelse
                    findFirstIntegerByField(value, "removed") orelse
                    countDiffLines(value, '-');
                const patch = findFirstStringByField(value, "diff");

                appendOrReplaceDiffFile(files, .{
                    .path = path,
                    .additions = additions,
                    .deletions = deletions,
                    .patch = patch,
                }) catch return false;
            }

            var found = false;
            var it = obj.iterator();
            while (it.next()) |entry| {
                found = appendDiffFiles(entry.value_ptr.*, files) or found;
            }
            return found or extractPathFromValue(value) != null;
        },
        .array => |arr| {
            var found = false;
            for (arr.items) |item| {
                found = appendDiffFiles(item, files) or found;
            }
            return found;
        },
        else => return false,
    }
}

fn appendOrReplaceDiffFile(
    files: *std.ArrayList(provider_types.StreamDiffFile),
    next: provider_types.StreamDiffFile,
) !void {
    for (files.items) |*existing| {
        if (!std.mem.eql(u8, existing.path, next.path)) continue;

        existing.additions = next.additions;
        existing.deletions = next.deletions;
        existing.patch = next.patch;
        return;
    }

    try files.append(std.heap.page_allocator, next);
}

fn appendChangedFiles(value: std.json.Value, lines: *std.ArrayList(u8)) bool {
    switch (value) {
        .object => |obj| {
            if (obj.get("path")) |path_value| {
                if (stringValue(path_value)) |path| {
                    appendChangedFileLine(lines, path, value);
                    return true;
                }
            }
            if (obj.get("filePath")) |path_value| {
                if (stringValue(path_value)) |path| {
                    appendChangedFileLine(lines, path, value);
                    return true;
                }
            }

            var found = false;
            var it = obj.iterator();
            while (it.next()) |entry| {
                found = appendChangedFiles(entry.value_ptr.*, lines) or found;
            }
            return found;
        },
        .array => |arr| {
            var found = false;
            for (arr.items) |item| {
                found = appendChangedFiles(item, lines) or found;
            }
            return found;
        },
        else => return false,
    }
}

fn appendChangedFileLine(lines: *std.ArrayList(u8), path: []const u8, value: std.json.Value) void {
    const additions = findFirstIntegerByField(value, "additions") orelse
        findFirstIntegerByField(value, "addedLines") orelse
        findFirstIntegerByField(value, "added") orelse
        countDiffLines(value, '+');
    const deletions = findFirstIntegerByField(value, "deletions") orelse
        findFirstIntegerByField(value, "removedLines") orelse
        findFirstIntegerByField(value, "removed") orelse
        countDiffLines(value, '-');

    if (lines.items.len > 0) {
        lines.append(std.heap.page_allocator, '\n') catch return;
    }
    const line = std.fmt.allocPrint(std.heap.page_allocator, "{s}  +{d} / -{d}", .{ path, additions, deletions }) catch return;
    defer std.heap.page_allocator.free(line);
    lines.appendSlice(std.heap.page_allocator, line) catch return;
}

fn extractPathFromValue(value: std.json.Value) ?[]const u8 {
    if (getObjectField(value, "path")) |path_value| {
        if (stringValue(path_value)) |path| return path;
    }
    if (getObjectField(value, "filePath")) |path_value| {
        if (stringValue(path_value)) |path| return path;
    }
    return null;
}

fn extractCommandSummary(root: std.json.Value) ?[]const u8 {
    const params = getObjectField(root, "params") orelse return null;
    return findFirstStringByField(params, "command") orelse
        findFirstStringByField(params, "rawInput") orelse
        findFirstStringByField(params, "cmd") orelse
        findFirstStringByField(params, "commandLine");
}

fn extractCommandApprovalSummary(root: std.json.Value) ?[]const u8 {
    const params = getObjectField(root, "params") orelse return null;
    return findFirstStringByField(params, "command") orelse
        findFirstStringByField(params, "reason") orelse
        findFirstStringByField(params, "cwd") orelse
        findFirstStringByField(params, "title") orelse
        findFirstStringByField(params, "message");
}

fn extractFileChangeApprovalSummary(root: std.json.Value) ?[]const u8 {
    const params = getObjectField(root, "params") orelse return null;
    return findFirstStringByField(params, "reason") orelse
        findFirstStringByField(params, "grantRoot") orelse
        findFirstStringByField(params, "title") orelse
        findFirstStringByField(params, "message");
}

fn extractPermissionsApprovalSummary(root: std.json.Value) ?[]const u8 {
    const params = getObjectField(root, "params") orelse return null;
    return findFirstStringByField(params, "reason") orelse
        findFirstStringByField(params, "reason") orelse
        findFirstStringByField(params, "title") orelse
        findFirstStringByField(params, "message");
}

const TurnTerminalState = enum {
    completed,
    failed,
    interrupted,
};

fn extractTurnIdFromStartResponse(root: std.json.Value) ?[]const u8 {
    const result = getObjectField(root, "result") orelse return null;
    const turn = getObjectField(result, "turn") orelse return null;
    return getOptionalObjectString(turn, "id");
}

fn extractTurnIdFromStartedNotification(root: std.json.Value, thread_id: []const u8) ?[]const u8 {
    const method = getOptionalObjectString(root, "method") orelse return null;
    if (!std.mem.eql(u8, method, "turn/started")) return null;

    const params = getObjectField(root, "params") orelse return null;
    const notification_thread_id = getOptionalObjectString(params, "threadId") orelse return null;
    if (!std.mem.eql(u8, notification_thread_id, thread_id)) return null;

    const turn = getObjectField(params, "turn") orelse return null;
    return getOptionalObjectString(turn, "id");
}

fn detectTurnTerminalState(root: std.json.Value, thread_id: []const u8, turn_id: ?[]const u8) ?TurnTerminalState {
    const method = getOptionalObjectString(root, "method") orelse return null;
    const params = getObjectField(root, "params") orelse return null;

    if (std.mem.eql(u8, method, "turn/completed")) {
        const notification_thread_id = getOptionalObjectString(params, "threadId") orelse return null;
        if (!std.mem.eql(u8, notification_thread_id, thread_id)) return null;

        const turn = getObjectField(params, "turn") orelse return null;
        if (turn_id) |expected_turn_id| {
            const completed_turn_id = getOptionalObjectString(turn, "id") orelse return null;
            if (!std.mem.eql(u8, completed_turn_id, expected_turn_id)) return null;
        }

        const status = getOptionalObjectString(turn, "status") orelse return .completed;
        if (std.mem.eql(u8, status, "completed")) return .completed;
        if (std.mem.eql(u8, status, "failed")) return .failed;
        if (std.mem.eql(u8, status, "interrupted")) return .interrupted;
        return null;
    }

    if (std.mem.eql(u8, method, "thread/status/changed")) {
        const notification_thread_id = getOptionalObjectString(params, "threadId") orelse return null;
        if (!std.mem.eql(u8, notification_thread_id, thread_id)) return null;

        const status = getObjectField(params, "status") orelse return null;
        const type_name = getOptionalObjectString(status, "type") orelse return null;
        if (std.mem.eql(u8, type_name, "idle")) return .completed;
    }

    return null;
}

fn findFirstStringByPath(value: std.json.Value, fields: []const []const u8) ?[]const u8 {
    var current = value;
    for (fields) |field| {
        current = getObjectField(current, field) orelse return null;
    }
    return stringValue(current);
}

fn findFirstStringByField(value: std.json.Value, field: []const u8) ?[]const u8 {
    switch (value) {
        .object => |obj| {
            if (obj.get(field)) |candidate| {
                if (stringValue(candidate)) |text| return text;
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (findFirstStringByField(entry.value_ptr.*, field)) |text| return text;
            }
            return null;
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (findFirstStringByField(item, field)) |text| return text;
            }
            return null;
        },
        else => return null,
    }
}

fn findFirstIntegerByField(value: std.json.Value, field: []const u8) ?i64 {
    switch (value) {
        .object => |obj| {
            if (obj.get(field)) |candidate| {
                switch (candidate) {
                    .integer => |number| return number,
                    else => {},
                }
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (findFirstIntegerByField(entry.value_ptr.*, field)) |number| return number;
            }
            return null;
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (findFirstIntegerByField(item, field)) |number| return number;
            }
            return null;
        },
        else => return null,
    }
}

fn countDiffLines(value: std.json.Value, prefix: u8) i64 {
    const diff = findFirstStringByField(value, "diff") orelse return 0;
    var count: i64 = 0;
    var it = std.mem.tokenizeScalar(u8, diff, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] != prefix) continue;
        if (line.len >= 3 and std.mem.eql(u8, line[0..3], if (prefix == '+') "+++" else "---")) continue;
        count += 1;
    }
    return count;
}

fn approvalPolicyString(value: provider_types.ApprovalPolicy) []const u8 {
    return switch (value) {
        .on_request => "on-request",
        .never => "never",
    };
}

fn shouldAutoApproveRequest(request: provider_types.SendPromptRequest) bool {
    return (request.approval_policy orelse .on_request) == .never;
}

fn sandboxModeString(value: provider_types.SandboxMode) []const u8 {
    return switch (value) {
        .workspace_write => "workspace-write",
        .danger_full_access => "danger-full-access",
    };
}

fn approvalDecisionString(value: provider_types.ApprovalDecision) []const u8 {
    return switch (value) {
        .approve => "accept",
        .deny => "decline",
    };
}

test "build request target preserves path and query" {
    const allocator = std.testing.allocator;
    const uri = try std.Uri.parse("ws://127.0.0.1:4500/rpc?client=native");
    const target = try buildRequestTargetAlloc(allocator, uri);
    defer allocator.free(target);

    try std.testing.expectEqualStrings("/rpc?client=native", target);
}

test "compute accept key matches websocket example" {
    const allocator = std.testing.allocator;
    const accept = try computeAcceptKeyAlloc(allocator, "dGhlIHNhbXBsZSBub25jZQ==");
    defer allocator.free(accept);

    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "appendImportedMessagesForItem maps transcript items into chat messages" {
    const allocator = std.testing.allocator;
    const json =
        \\[
        \\  {
        \\    "type": "userMessage",
        \\    "id": "u1",
        \\    "content": [
        \\      { "type": "text", "text": "Look at this" },
        \\      { "type": "localImage", "path": "/tmp/screenshot.png" }
        \\    ]
        \\  },
        \\  {
        \\    "type": "agentMessage",
        \\    "id": "a1",
        \\    "text": "I checked it."
        \\  },
        \\  {
        \\    "type": "commandExecution",
        \\    "id": "c1",
        \\    "command": "git status",
        \\    "status": "completed"
        \\  },
        \\  {
        \\    "type": "fileChange",
        \\    "id": "f1",
        \\    "changes": [
        \\      {
        \\        "path": "src/main.zig",
        \\        "diff": "@@ -1 +1 @@\n-old\n+new\n"
        \\      }
        \\    ]
        \\  }
        \\]
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    var messages: std.ArrayList(provider_types.ChatMessage) = .empty;
    defer {
        for (messages.items) |message| {
            allocator.free(message.author);
            allocator.free(message.body);
        }
        messages.deinit(allocator);
    }

    for (parsed.value.array.items) |item| {
        try appendImportedMessagesForItem(allocator, item, &messages);
    }

    try std.testing.expectEqual(@as(usize, 4), messages.items.len);
    try std.testing.expectEqual(provider_types.MessageRole.user, messages.items[0].role);
    try std.testing.expectEqualStrings("You", messages.items[0].author);
    try std.testing.expectEqualStrings("Look at this\n\n[Image: /tmp/screenshot.png]", messages.items[0].body);
    try std.testing.expectEqual(provider_types.MessageRole.assistant, messages.items[1].role);
    try std.testing.expectEqualStrings("Codex", messages.items[1].author);
    try std.testing.expectEqualStrings("I checked it.", messages.items[1].body);
    try std.testing.expectEqualStrings("Ran command", messages.items[2].author);
    try std.testing.expectEqualStrings("git status", messages.items[2].body);
    try std.testing.expectEqualStrings("Changed files", messages.items[3].author);
    try std.testing.expectEqualStrings("src/main.zig  +1 / -1", messages.items[3].body);
}

test "shouldAutoApproveRequest follows approval policy" {
    try std.testing.expect(shouldAutoApproveRequest(.{ .prompt = "hi", .approval_policy = .never }));
    try std.testing.expect(!shouldAutoApproveRequest(.{ .prompt = "hi", .approval_policy = .on_request }));
    try std.testing.expect(!shouldAutoApproveRequest(.{ .prompt = "hi" }));
}

test "detectTurnTerminalState recognizes thread idle fallback for the active thread" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "method": "thread/status/changed",
        \\  "params": {
        \\    "threadId": "thread-123",
        \\    "status": { "type": "idle" }
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const terminal = detectTurnTerminalState(parsed.value, "thread-123", "turn-456");
    try std.testing.expectEqual(TurnTerminalState.completed, terminal.?);
}

test "detectTurnTerminalState matches turn completion status for the started turn" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "method": "turn/completed",
        \\  "params": {
        \\    "threadId": "thread-123",
        \\    "turn": {
        \\      "id": "turn-456",
        \\      "status": "failed",
        \\      "items": [],
        \\      "error": { "message": "boom", "codexErrorInfo": null, "additionalDetails": null }
        \\    }
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const terminal = detectTurnTerminalState(parsed.value, "thread-123", "turn-456");
    try std.testing.expectEqual(TurnTerminalState.failed, terminal.?);
    try std.testing.expectEqual(@as(?TurnTerminalState, null), detectTurnTerminalState(parsed.value, "thread-123", "other-turn"));
}
