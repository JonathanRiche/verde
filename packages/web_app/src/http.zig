//! Local HTTP + WebSocket gateway for the Solid client.

const std = @import("std");
const headless = @import("headless");

const config_mod = @import("config.zig");
const daemon_mod = @import("daemon.zig");
const mock = @import("mock.zig");
const office_preview = @import("office_preview.zig");
const theme_mod = @import("theme.zig");

const log = std.log.scoped(.web_http);

const WEB_CHAT_IMAGE_DIR = "web-chat-images";
const MAX_CHAT_IMAGE_BYTES: usize = 10 * 1024 * 1024;
// Workspace files (transcript citations) served for viewing/downloading are
// read fully into memory, so cap them well below the daemon transport limits.
const MAX_SERVED_FILE_BYTES: usize = 32 * 1024 * 1024;

const CORS_HEADERS = [_]std.http.Header{
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "access-control-allow-headers", .value = "authorization, content-type, x-verde-token" },
    .{ .name = "access-control-allow-methods", .value = "GET, POST, DELETE, OPTIONS" },
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

    if (std.mem.eql(u8, split.path, "/api/attachment") and request.head.method == .POST) {
        const mime = supportedImageMime(requestContentType(request)) orelse {
            try respondJson(request, .unsupported_media_type, "{\"ok\":false,\"error\":\"unsupported_image_type\"}");
            return;
        };
        const body_reader = try request.readerExpectContinue(&.{});
        const body = body_reader.allocRemaining(allocator, .limited(MAX_CHAT_IMAGE_BYTES)) catch {
            try respondJson(request, .payload_too_large, "{\"ok\":false,\"error\":\"image_too_large\"}");
            return;
        };
        defer allocator.free(body);
        if (!imageBytesMatchMime(mime, body)) {
            try respondJson(request, .bad_request, "{\"ok\":false,\"error\":\"invalid_image\"}");
            return;
        }

        const stored = try storeChatImage(allocator, io, config.pref_path, mime, body);
        defer stored.deinit(allocator);
        var writer: std.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        try std.json.Stringify.value(.{
            .ok = true,
            .attachment = .{
                .path = stored.path,
                .mime = mime,
                .byte_size = body.len,
                .attachment_id = stored.attachment_id,
            },
        }, .{}, &writer.writer);
        const response = try writer.toOwnedSlice();
        defer allocator.free(response);
        try respondJson(request, .created, response);
        return;
    }

    if (std.mem.eql(u8, split.path, "/api/attachment") and
        (request.head.method == .GET or request.head.method == .DELETE))
    {
        const attachment_id = queryValue(split.query, "id") orelse {
            try respondJson(request, .bad_request, "{\"ok\":false,\"error\":\"missing_attachment_id\"}");
            return;
        };
        if (!validAttachmentId(attachment_id)) {
            try respondJson(request, .bad_request, "{\"ok\":false,\"error\":\"invalid_attachment_id\"}");
            return;
        }
        const path = try std.fs.path.join(allocator, &.{ config.pref_path, WEB_CHAT_IMAGE_DIR, attachment_id });
        defer allocator.free(path);
        if (request.head.method == .DELETE) {
            std.Io.Dir.deleteFileAbsolute(io, path) catch {
                try respondJson(request, .not_found, "{\"ok\":false,\"error\":\"attachment_not_found\"}");
                return;
            };
            try respondJson(request, .ok, "{\"ok\":true}");
            return;
        }
        const bytes = readFileLimited(allocator, io, path) catch {
            try respondJson(request, .not_found, "{\"ok\":false,\"error\":\"attachment_not_found\"}");
            return;
        };
        defer allocator.free(bytes);
        try respondText(request, .ok, mimeType(path), bytes);
        return;
    }

    if (std.mem.eql(u8, split.path, "/api/file") and request.head.method == .GET) {
        // Token-authenticated file read for transcript file citations. The
        // gateway already proxies arbitrary daemon RPC for the same token, so
        // this adds no authority beyond what /api/rpc grants; validation only
        // rejects malformed paths, not locations.
        const raw_path = queryValue(split.query, "path") orelse {
            try respondJson(request, .bad_request, "{\"ok\":false,\"error\":\"missing_path\"}");
            return;
        };
        const decoded = try decodeQueryComponent(allocator, raw_path);
        defer allocator.free(decoded);
        if (!validServedFilePath(decoded)) {
            try respondJson(request, .bad_request, "{\"ok\":false,\"error\":\"invalid_path\"}");
            return;
        }
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, decoded, allocator, .limited(MAX_SERVED_FILE_BYTES)) catch |err| switch (err) {
            error.StreamTooLong => {
                try respondJson(request, .payload_too_large, "{\"ok\":false,\"error\":\"file_too_large\"}");
                return;
            },
            else => {
                try respondJson(request, .not_found, "{\"ok\":false,\"error\":\"file_not_found\"}");
                return;
            },
        };
        defer allocator.free(bytes);
        if (queryValue(split.query, "download") != null) {
            const disposition = try attachmentDisposition(allocator, decoded);
            defer allocator.free(disposition);
            try respondDownload(request, mimeType(decoded), disposition, bytes);
            return;
        }
        try respondText(request, .ok, mimeType(decoded), bytes);
        return;
    }

    if (std.mem.eql(u8, split.path, "/api/preview") and request.head.method == .GET) {
        // Office documents (pptx/docx/xlsx/…) preview as PDFs converted by
        // LibreOffice headless and cached per document state; the client
        // renders the result through the same viewer as native PDFs.
        const raw_path = queryValue(split.query, "path") orelse {
            try respondJson(request, .bad_request, "{\"ok\":false,\"error\":\"missing_path\"}");
            return;
        };
        const decoded = try decodeQueryComponent(allocator, raw_path);
        defer allocator.free(decoded);
        if (!validServedFilePath(decoded)) {
            try respondJson(request, .bad_request, "{\"ok\":false,\"error\":\"invalid_path\"}");
            return;
        }
        if (!office_preview.convertible(decoded)) {
            try respondJson(request, .bad_request, "{\"ok\":false,\"error\":\"unsupported_document_type\"}");
            return;
        }
        const pdf_path = office_preview.previewPdf(allocator, io, config.pref_path, env_map, decoded) catch |err| switch (err) {
            error.SourceNotFound => {
                try respondJson(request, .not_found, "{\"ok\":false,\"error\":\"file_not_found\"}");
                return;
            },
            error.ConverterUnavailable => {
                try respondJson(request, .not_implemented, "{\"ok\":false,\"error\":\"preview_needs_libreoffice_on_the_verde_host\"}");
                return;
            },
            error.ConversionFailed => {
                try respondJson(request, .internal_server_error, "{\"ok\":false,\"error\":\"preview_conversion_failed\"}");
                return;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer allocator.free(pdf_path);
        // Converted decks can exceed the 8 MiB static-file limit; use the
        // same ceiling as directly served workspace files.
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, pdf_path, allocator, .limited(MAX_SERVED_FILE_BYTES)) catch {
            try respondJson(request, .internal_server_error, "{\"ok\":false,\"error\":\"preview_conversion_failed\"}");
            return;
        };
        defer allocator.free(bytes);
        try respondText(request, .ok, "application/pdf", bytes);
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
    // Detached UIs take the lightweight workspaces scope (rows + persisted
    // layout, no messages) plus volatile scopes, and read threads via
    // chat.thread.*. Older daemons report "workspaces" via incomplete_scopes.
    scopes: [4][]const u8 = .{ "workspaces", "registry", "sessions", "turns" },
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

/// Decodes one query-string component: '+' means space (URLSearchParams
/// convention; a literal '+' arrives as %2B) and %XX escapes are resolved.
fn decodeQueryComponent(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const buffer = try allocator.dupe(u8, raw);
    for (buffer) |*byte| {
        if (byte.* == '+') byte.* = ' ';
    }
    const decoded = std.Uri.percentDecodeInPlace(buffer);
    if (decoded.len == buffer.len) return buffer;
    const shrunk = try allocator.dupe(u8, decoded);
    allocator.free(buffer);
    return shrunk;
}

/// Served file paths must be absolute and free of traversal segments so a
/// citation link can never be a relative escape from a logged path.
fn validServedFilePath(path: []const u8) bool {
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

/// content-disposition value advertising the file's basename; header-unsafe
/// bytes are replaced so the value never breaks out of the quoted string.
fn attachmentDisposition(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const basename = std.fs.path.basename(path);
    const name = if (basename.len == 0) "download" else basename;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("attachment; filename=\"");
    for (name) |byte| {
        const safe = byte >= 0x20 and byte != '"' and byte != '\\' and byte != 0x7f;
        try writer.writer.writeByte(if (safe) byte else '_');
    }
    try writer.writer.writeByte('"');
    return try writer.toOwnedSlice();
}

fn requestContentType(request: *const std.http.Server.Request) ?[]const u8 {
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "content-type")) continue;
        const value = if (std.mem.indexOfScalar(u8, header.value, ';')) |separator|
            header.value[0..separator]
        else
            header.value;
        return std.mem.trim(u8, value, &std.ascii.whitespace);
    }
    return null;
}

fn supportedImageMime(value: ?[]const u8) ?[]const u8 {
    const mime = value orelse return null;
    if (std.ascii.eqlIgnoreCase(mime, "image/png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(mime, "image/jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(mime, "image/webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(mime, "image/gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(mime, "image/bmp")) return "image/bmp";
    return null;
}

fn imageExtension(mime: []const u8) []const u8 {
    if (std.mem.eql(u8, mime, "image/png")) return "png";
    if (std.mem.eql(u8, mime, "image/jpeg")) return "jpg";
    if (std.mem.eql(u8, mime, "image/webp")) return "webp";
    if (std.mem.eql(u8, mime, "image/gif")) return "gif";
    if (std.mem.eql(u8, mime, "image/bmp")) return "bmp";
    unreachable;
}

fn imageBytesMatchMime(mime: []const u8, bytes: []const u8) bool {
    if (std.mem.eql(u8, mime, "image/png"))
        return bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n");
    if (std.mem.eql(u8, mime, "image/jpeg"))
        return bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff;
    if (std.mem.eql(u8, mime, "image/webp"))
        return bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP");
    if (std.mem.eql(u8, mime, "image/gif"))
        return bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"));
    if (std.mem.eql(u8, mime, "image/bmp"))
        return bytes.len >= 2 and bytes[0] == 'B' and bytes[1] == 'M';
    return false;
}

fn validAttachmentId(value: []const u8) bool {
    if (value.len == 0 or value.len > 96) return false;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '.') return false;
    }
    return std.mem.startsWith(u8, value, "web-");
}

const StoredChatImage = struct {
    path: []u8,
    attachment_id: []u8,

    fn deinit(self: StoredChatImage, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.attachment_id);
    }
};

fn storeChatImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    pref_path: []const u8,
    mime: []const u8,
    bytes: []const u8,
) !StoredChatImage {
    const directory = try std.fs.path.join(allocator, &.{ pref_path, WEB_CHAT_IMAGE_DIR });
    defer allocator.free(directory);
    std.Io.Dir.createDirAbsolute(io, directory, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const timestamp = std.Io.Clock.real.now(io);
    const timestamp_ns: u128 = @intCast(@max(timestamp.nanoseconds, 0));
    const content_hash = std.hash.Wyhash.hash(0, bytes);
    var attempt: usize = 0;
    while (attempt < 256) : (attempt += 1) {
        const attachment_id = if (attempt == 0)
            try std.fmt.allocPrint(allocator, "web-{x}-{x}.{s}", .{ timestamp_ns, content_hash, imageExtension(mime) })
        else
            try std.fmt.allocPrint(allocator, "web-{x}-{x}-{d}.{s}", .{ timestamp_ns, content_hash, attempt, imageExtension(mime) });
        errdefer allocator.free(attachment_id);
        const path = try std.fs.path.join(allocator, &.{ directory, attachment_id });
        errdefer allocator.free(path);

        const file = std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true });
        if (file) |created| {
            defer created.close(io);
            var write_buffer: [8 * 1024]u8 = undefined;
            var writer = created.writer(io, &write_buffer);
            try writer.interface.writeAll(bytes);
            try writer.interface.flush();
            return .{ .path = path, .attachment_id = attachment_id };
        } else |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                allocator.free(attachment_id);
                continue;
            },
            else => return err,
        }
    }
    return error.PathAlreadyExists;
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

fn respondDownload(
    request: *std.http.Server.Request,
    content_type: []const u8,
    disposition: []const u8,
    body: []const u8,
) !void {
    const extra = [_]std.http.Header{
        CORS_HEADERS[0],
        CORS_HEADERS[1],
        CORS_HEADERS[2],
        .{ .name = "content-type", .value = content_type },
        .{ .name = "content-disposition", .value = disposition },
    };
    try request.respond(body, .{
        .status = .ok,
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
    if (std.mem.endsWith(u8, path, ".pdf")) return "application/pdf";
    if (std.mem.endsWith(u8, path, ".pptx")) return "application/vnd.openxmlformats-officedocument.presentationml.presentation";
    if (std.mem.endsWith(u8, path, ".docx")) return "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
    if (std.mem.endsWith(u8, path, ".xlsx")) return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
    if (std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".markdown")) return "text/markdown; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".txt") or std.mem.endsWith(u8, path, ".log")) return "text/plain; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".csv")) return "text/csv; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    if (std.mem.endsWith(u8, path, ".bmp")) return "image/bmp";
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

test "web chat image upload validation accepts supported signatures only" {
    try std.testing.expectEqualStrings("image/jpeg", supportedImageMime("IMAGE/JPEG").?);
    try std.testing.expect(supportedImageMime("application/pdf") == null);
    try std.testing.expect(imageBytesMatchMime("image/png", "\x89PNG\r\n\x1a\nrest"));
    try std.testing.expect(imageBytesMatchMime("image/webp", "RIFF1234WEBPrest"));
    try std.testing.expect(!imageBytesMatchMime("image/png", "not an image"));
    try std.testing.expect(validAttachmentId("web-abc-123.png"));
    try std.testing.expect(!validAttachmentId("../state.sqlite"));
    try std.testing.expect(!validAttachmentId("web-a/b.png"));
}

test "served file path validation rejects traversal and relative paths" {
    try std.testing.expect(validServedFilePath("/home/user/deliverables/report.pdf"));
    try std.testing.expect(!validServedFilePath("deliverables/report.pdf"));
    try std.testing.expect(!validServedFilePath("/home/user/../../etc/passwd"));
    try std.testing.expect(!validServedFilePath(""));
}

test "query component decoding resolves percent escapes and plus" {
    const decoded = try decodeQueryComponent(std.testing.allocator, "/home/rtg/My%20Files/a%2Bb.pdf");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("/home/rtg/My Files/a+b.pdf", decoded);

    const plus = try decodeQueryComponent(std.testing.allocator, "/tmp/a+b.txt");
    defer std.testing.allocator.free(plus);
    try std.testing.expectEqualStrings("/tmp/a b.txt", plus);
}

test "attachment disposition quotes and sanitizes the basename" {
    const disposition = try attachmentDisposition(std.testing.allocator, "/tmp/Report \"final\".pdf");
    defer std.testing.allocator.free(disposition);
    try std.testing.expectEqualStrings("attachment; filename=\"Report _final_.pdf\"", disposition);
}

test {
    _ = mock;
    _ = office_preview;
}
