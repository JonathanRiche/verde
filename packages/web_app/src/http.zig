//! Local HTTP + WebSocket gateway for the Solid client.

const std = @import("std");
const headless = @import("headless");

const config_mod = @import("config.zig");
const daemon_mod = @import("daemon.zig");
const mock = @import("mock.zig");
const theme_mod = @import("theme.zig");

const log = std.log.scoped(.web_http);

const CORS_HEADERS = [_]std.http.Header{
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "access-control-allow-headers", .value = "authorization, content-type, x-verde-token" },
    .{ .name = "access-control-allow-methods", .value = "GET, POST, OPTIONS" },
};

pub fn serve(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod,
    daemon: *daemon_mod.Daemon,
    env_map: *const std.process.Environ.Map,
) !void {
    const address = try std.Io.net.IpAddress.parse(config.host, config.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.debug.print("verde-web listening on http://{f}/\n", .{listener.socket.address});
    std.debug.print("  daemon socket   {s}\n", .{config.sessionizer_endpoint});
    std.debug.print("  live socket     {s}\n", .{config.live_endpoint});
    std.debug.print("  static          {s}\n", .{config.static_dir});
    std.debug.print("  source          {s}\n", .{@tagName(daemon.probe())});
    if (config.token.len > 0) {
        std.debug.print("  open            http://{s}:{d}/?token={s}\n", .{ config.host, config.port, config.token });
    }

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.Canceled => return,
            else => {
                log.err("accept failed: {s}", .{@errorName(err)});
                continue;
            },
        };
        group.concurrent(io, handleConnection, .{ allocator, io, config, daemon, env_map, stream }) catch |err| {
            log.err("unable to spawn connection: {s}", .{@errorName(err)});
            var copy = stream;
            copy.close(io);
        };
    }
}

fn handleConnection(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod,
    daemon: *daemon_mod.Daemon,
    env_map: *const std.process.Environ.Map,
    stream: std.Io.net.Stream,
) void {
    defer {
        var copy = stream;
        copy.close(io);
    }

    var send_buffer: [4096]u8 = undefined;
    var recv_buffer: [16 * 1024]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                log.err("receiveHead: {s}", .{@errorName(err)});
                return;
            },
        };
        switch (request.upgradeRequested()) {
            .websocket => |opt_key| {
                const key = opt_key orelse {
                    respondText(&request, .bad_request, "text/plain", "missing websocket key") catch {};
                    return;
                };
                if (!authorized(&request, config)) {
                    respondText(&request, .unauthorized, "text/plain", "unauthorized") catch {};
                    return;
                }
                var socket = request.respondWebSocket(.{ .key = key }) catch {
                    log.err("websocket upgrade failed", .{});
                    return;
                };
                socket.flush() catch return;
                serveWebSocket(allocator, io, daemon, &socket) catch |err| {
                    log.err("websocket session: {s}", .{@errorName(err)});
                };
                return;
            },
            .other => |name| {
                log.err("unknown upgrade: {s}", .{name});
                return;
            },
            .none => {
                handleRequest(allocator, io, config, daemon, env_map, &request) catch |err| {
                    log.err("request {s}: {s}", .{ request.head.target, @errorName(err) });
                    return;
                };
            },
        }
    }
}

fn handleRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod,
    daemon: *daemon_mod.Daemon,
    env_map: *const std.process.Environ.Map,
    request: *std.http.Server.Request,
) !void {
    const split = splitTarget(request.head.target);
    if (request.head.method == .OPTIONS) {
        try request.respond("", .{
            .status = .no_content,
            .extra_headers = &CORS_HEADERS,
        });
        return;
    }

    if (std.mem.eql(u8, split.path, "/api/theme")) {
        const resolved = try theme_mod.resolve(allocator, io, env_map);
        const body = try theme_mod.encodeJson(allocator, resolved);
        defer allocator.free(body);
        try respondJson(request, .ok, body);
        return;
    }

    if (std.mem.eql(u8, split.path, "/api/health")) {
        const source = daemon.probe();
        var buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf, "{{\"ok\":true,\"source\":\"{s}\"}}", .{@tagName(source)});
        try respondJson(request, .ok, body);
        return;
    }

    if (!authorized(request, config)) {
        try respondJson(request, .unauthorized, "{\"ok\":false,\"error\":\"unauthorized\"}");
        return;
    }

    if (std.mem.eql(u8, split.path, "/api/status")) {
        const result = try daemon.callMethod("core.status", daemon_mod.Daemon.EmptyObject{});
        defer allocator.free(result.json);
        try respondJson(request, .ok, result.json);
        return;
    }

    if (std.mem.eql(u8, split.path, "/api/snapshot")) {
        const result = try daemon.callMethod("core.snapshot", SnapshotParams{});
        defer allocator.free(result.json);
        try respondJson(request, .ok, result.json);
        return;
    }

    if (std.mem.eql(u8, split.path, "/api/rpc") and request.head.method == .POST) {
        const body_reader = try request.readerExpectContinue(&.{});
        const body = try body_reader.allocRemaining(allocator, .limited(headless.protocol.MAX_MESSAGE_BYTES));
        defer allocator.free(body);
        const result = try daemon.callRaw(std.mem.trim(u8, body, &std.ascii.whitespace));
        defer allocator.free(result.json);
        try respondJson(request, .ok, result.json);
        return;
    }

    if (request.head.method == .GET) {
        if (try serveStatic(allocator, io, config.static_dir, split.path, request)) return;
    }

    try respondJson(request, .not_found, "{\"ok\":false,\"error\":\"not_found\"}");
}

const WsSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    daemon: *daemon_mod.Daemon,
    socket: *std.http.Server.WebSocket,
    write_mutex: std.Io.Mutex = .init,
    closed: std.atomic.Value(bool) = .init(false),

    fn send(self: *WsSession, payload: []const u8) !void {
        try self.write_mutex.lock(self.io);
        defer self.write_mutex.unlock(self.io);
        try self.socket.writeMessage(payload, .text);
    }
};

fn serveWebSocket(
    allocator: std.mem.Allocator,
    io: std.Io,
    daemon: *daemon_mod.Daemon,
    socket: *std.http.Server.WebSocket,
) !void {
    var session: WsSession = .{
        .allocator = allocator,
        .io = io,
        .daemon = daemon,
        .socket = socket,
    };

    try sendHello(&session);

    var poll_task = try io.concurrent(pollChanges, .{&session});
    defer poll_task.cancel(io);

    while (!session.closed.load(.acquire)) {
        const message = socket.readSmallMessage() catch |err| switch (err) {
            error.ConnectionClose, error.EndOfStream => break,
            else => return err,
        };
        switch (message.opcode) {
            .ping => {
                try session.write_mutex.lock(io);
                defer session.write_mutex.unlock(io);
                socket.writeMessage(message.data, .pong) catch {};
            },
            .text, .binary => {
                const trimmed = std.mem.trim(u8, message.data, &std.ascii.whitespace);
                if (trimmed.len == 0) continue;
                const result = session.daemon.callRaw(trimmed) catch |err| {
                    const encoded = try headless.encodeErrorResponse(
                        allocator,
                        0,
                        "internal",
                        @errorName(err),
                    );
                    defer allocator.free(encoded);
                    session.send(encoded) catch {};
                    continue;
                };
                defer allocator.free(result.json);
                session.send(result.json) catch {};
            },
            else => {},
        }
    }
    session.closed.store(true, .release);
}

fn sendHello(session: *WsSession) !void {
    const status = try session.daemon.callMethod("core.status", daemon_mod.Daemon.EmptyObject{});
    defer session.allocator.free(status.json);

    const hello = try std.fmt.allocPrint(
        session.allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"core.hello\",\"params\":{{\"source\":\"{s}\",\"status_envelope\":{s}}}}}",
        .{ @tagName(session.daemon.probe()), status.json },
    );
    defer session.allocator.free(hello);
    try session.send(hello);

    pushSnapshot(session) catch {};
}

fn sendNotification(session: *WsSession, method: []const u8, payload: []const u8) !void {
    const note = try std.fmt.allocPrint(
        session.allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}",
        .{ method, payload },
    );
    defer session.allocator.free(note);
    try session.send(note);
}

fn pollChanges(session: *WsSession) void {
    var cursor: ?u64 = null;
    while (!session.closed.load(.acquire)) {
        const params = changesParams(cursor);
        const result = session.daemon.callMethod("core.changes", params) catch {
            sleepMs(session.io, 1_000) catch return;
            continue;
        };
        defer session.allocator.free(result.json);

        if (result.source == .mock) {
            sleepMs(session.io, 4_000) catch return;
            continue;
        }

        const note = std.fmt.allocPrint(
            session.allocator,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"core.changes\",\"params\":{s}}}",
            .{result.json},
        ) catch continue;
        defer session.allocator.free(note);
        session.send(note) catch {
            session.closed.store(true, .release);
            return;
        };

        cursor = extractNextCursor(result.json) orelse cursor;
        if (!isHeartbeat(result.json)) {
            pushSnapshot(session) catch {};
        }
    }
}

const SnapshotParams = struct {
    // The durable store snapshot exceeds the daemon's 8 MiB transport cap.
    // Detached UIs take volatile scopes here and read threads via chat.thread.*.
    scopes: [3][]const u8 = .{ "registry", "sessions", "turns" },
};

fn pushSnapshot(session: *WsSession) !void {
    const snapshot = session.daemon.callMethod("core.snapshot", SnapshotParams{}) catch return error.DaemonUnavailable;
    defer session.allocator.free(snapshot.json);
    try sendNotification(session, "core.snapshot", snapshot.json);
}

fn isHeartbeat(json: []const u8) bool {
    return std.mem.indexOf(u8, json, "\"heartbeat\":true") != null and
        std.mem.indexOf(u8, json, "\"entries\":[]") != null;
}

const ChangesParams = struct {
    cursor: ?u64 = null,
    wait_ms: u32 = 4_000,
};

fn changesParams(cursor: ?u64) ChangesParams {
    return .{ .cursor = cursor, .wait_ms = 4_000 };
}

fn extractNextCursor(json: []const u8) ?u64 {
    const key = "\"next_cursor\":";
    const start = std.mem.indexOf(u8, json, key) orelse return null;
    const rest = json[start + key.len ..];
    var i: usize = 0;
    while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t')) : (i += 1) {}
    var end = i;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') : (end += 1) {}
    if (end == i) return null;
    return std.fmt.parseInt(u64, rest[i..end], 10) catch null;
}

fn sleepMs(io: std.Io, ms: u64) !void {
    io.sleep(std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
    };
}

fn authorized(request: *const std.http.Server.Request, config: config_mod) bool {
    if (config.token.len == 0) return true;
    const split = splitTarget(request.head.target);
    if (queryValue(split.query, "token")) |token| {
        if (std.mem.eql(u8, token, config.token)) return true;
    }
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-verde-token") and std.mem.eql(u8, header.value, config.token)) {
            return true;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
            const prefix = "Bearer ";
            if (std.mem.startsWith(u8, header.value, prefix) and
                std.mem.eql(u8, header.value[prefix.len..], config.token))
            {
                return true;
            }
        }
    }
    return false;
}

const SplitTarget = struct { path: []const u8, query: []const u8 };

fn splitTarget(target: []const u8) SplitTarget {
    if (std.mem.indexOfScalar(u8, target, '?')) |index| {
        return .{ .path = target[0..index], .query = target[index + 1 ..] };
    }
    return .{ .path = target, .query = "" };
}

fn queryValue(query: []const u8, key: []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, query, '&');
    while (iter.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
        } else if (std.mem.eql(u8, pair, key)) {
            return "";
        }
    }
    return null;
}

fn respondJson(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    var headers = CORS_HEADERS ++ [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
    };
    try request.respond(body, .{
        .status = status,
        .extra_headers = &headers,
    });
}

fn respondText(
    request: *std.http.Server.Request,
    status: std.http.Status,
    content_type: []const u8,
    body: []const u8,
) !void {
    const extra = [_]std.http.Header{
        CORS_HEADERS[0],
        CORS_HEADERS[1],
        CORS_HEADERS[2],
        .{ .name = "content-type", .value = content_type },
    };
    try request.respond(body, .{
        .status = status,
        .extra_headers = &extra,
    });
}

fn serveStatic(
    allocator: std.mem.Allocator,
    io: std.Io,
    static_dir: []const u8,
    request_path: []const u8,
    request: *std.http.Server.Request,
) !bool {
    if (static_dir.len == 0) return false;
    const rel = staticRelPath(request_path);
    if (rel == null) return false;
    const full = try std.fs.path.join(allocator, &.{ static_dir, rel.? });
    defer allocator.free(full);

    if (readFileLimited(allocator, io, full)) |bytes| {
        defer allocator.free(bytes);
        try respondText(request, .ok, mimeType(full), bytes);
        return true;
    } else |_| {}

    if (!looksLikeAsset(request_path)) {
        const index_path = try std.fs.path.join(allocator, &.{ static_dir, "index.html" });
        defer allocator.free(index_path);
        if (readFileLimited(allocator, io, index_path)) |bytes| {
            defer allocator.free(bytes);
            try respondText(request, .ok, "text/html; charset=utf-8", bytes);
            return true;
        } else |_| {}
    }
    return false;
}

fn staticRelPath(request_path: []const u8) ?[]const u8 {
    if (request_path.len == 0 or request_path[0] != '/') return null;
    if (std.mem.indexOf(u8, request_path, "..") != null) return null;
    if (std.mem.eql(u8, request_path, "/")) return "index.html";
    return request_path[1..];
}

fn looksLikeAsset(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, '.') != null;
}

fn readFileLimited(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
}

fn mimeType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".woff2")) return "font/woff2";
    if (std.mem.endsWith(u8, path, ".ttf")) return "font/ttf";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".map")) return "application/json";
    return "application/octet-stream";
}

test "target split and query" {
    const split = splitTarget("/ws?token=abc&x=1");
    try std.testing.expectEqualStrings("/ws", split.path);
    try std.testing.expectEqualStrings("abc", queryValue(split.query, "token").?);
}

test {
    _ = mock;
}
