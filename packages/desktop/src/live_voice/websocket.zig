//! Minimal RFC 6455 WebSocket client over `std.crypto.tls`, for provider
//! real-time voice sockets (`wss://` only). `std.http.Client` loads the
//! system CA bundle and builds the TLS connection; this file writes the
//! upgrade, checks `Sec-WebSocket-Accept`, and frames messages (masked client
//! frames, fragmented server messages, ping/pong, close).
//!
//! Threading: one thread owns a `Client`. `std.crypto.tls.Client` rewrites
//! its write keys inside `read` on a server KeyUpdate, so reading and writing
//! from different threads would race. Callers `poll` `fd()` (plus their own
//! wake descriptor) and call `receive` only when it is readable or
//! `hasBuffered()`. Tokens and payloads are never logged.

const std = @import("std");

const log = std.log.scoped(.live_websocket);

pub const MAX_MESSAGE_BYTES: usize = 8 * 1024 * 1024;
const MAX_HEADER_BYTES: usize = 16 * 1024;
const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,

    fn control(self: Opcode) bool {
        return @intFromEnum(self) >= 8;
    }
};

pub const Frame = struct { fin: bool, opcode: Opcode, payload: []const u8 };

// ---- framing (pure) -----------------------------------------------------------

/// Encodes one masked client frame.
pub fn encodeFrameAlloc(allocator: std.mem.Allocator, opcode: Opcode, payload: []const u8, mask: [4]u8) ![]u8 {
    var header: [14]u8 = undefined;
    header[0] = 0x80 | @as(u8, @intFromEnum(opcode));
    var len: usize = 2;
    if (payload.len < 126) {
        header[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else if (payload.len <= 0xFFFF) {
        header[1] = 0x80 | 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        len = 4;
    } else {
        header[1] = 0x80 | 127;
        std.mem.writeInt(u64, header[2..10], payload.len, .big);
        len = 10;
    }
    @memcpy(header[len..][0..4], &mask);
    len += 4;
    const out = try allocator.alloc(u8, len + payload.len);
    @memcpy(out[0..len], header[0..len]);
    for (payload, 0..) |byte, i| out[len + i] = byte ^ mask[i % 4];
    return out;
}

pub const ParseError = error{ MaskedServerFrame, MessageTooLarge, ProtocolError };

/// Parses one server frame from the front of `bytes`. Returns null when
/// the frame is not complete yet.
pub fn parseFrame(bytes: []const u8) ParseError!?struct { frame: Frame, consumed: usize } {
    if (bytes.len < 2) return null;
    const fin = bytes[0] & 0x80 != 0;
    if (bytes[0] & 0x70 != 0) return error.ProtocolError; // no extensions negotiated
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(bytes[0])));
    if (bytes[1] & 0x80 != 0) return error.MaskedServerFrame;
    var len: u64 = bytes[1] & 0x7F;
    var offset: usize = 2;
    if (len == 126) {
        if (bytes.len < 4) return null;
        len = std.mem.readInt(u16, bytes[2..4], .big);
        offset = 4;
    } else if (len == 127) {
        if (bytes.len < 10) return null;
        len = std.mem.readInt(u64, bytes[2..10], .big);
        offset = 10;
    }
    if (opcode.control() and (len > 125 or !fin)) return error.ProtocolError;
    if (len > MAX_MESSAGE_BYTES) return error.MessageTooLarge;
    const total = offset + @as(usize, @intCast(len));
    if (bytes.len < total) return null;
    return .{ .frame = .{ .fin = fin, .opcode = opcode, .payload = bytes[offset..total] }, .consumed = total };
}

/// Joins fragmented data frames into whole messages.
pub const Assembler = struct {
    buffer: std.ArrayList(u8) = .empty,
    opcode: ?Opcode = null,

    pub fn deinit(self: *Assembler, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
    }

    /// Feeds a data frame; returns the complete message payload (valid until
    /// the next call) or null while fragments are outstanding.
    pub fn push(self: *Assembler, allocator: std.mem.Allocator, frame: Frame) !?struct { opcode: Opcode, payload: []const u8 } {
        switch (frame.opcode) {
            .text, .binary => {
                if (self.opcode != null) return error.ProtocolError;
                if (frame.fin) return .{ .opcode = frame.opcode, .payload = frame.payload };
                self.buffer.clearRetainingCapacity();
                try self.buffer.appendSlice(allocator, frame.payload);
                self.opcode = frame.opcode;
                return null;
            },
            .continuation => {
                const opcode = self.opcode orelse return error.ProtocolError;
                if (self.buffer.items.len + frame.payload.len > MAX_MESSAGE_BYTES) return error.MessageTooLarge;
                try self.buffer.appendSlice(allocator, frame.payload);
                if (!frame.fin) return null;
                self.opcode = null;
                return .{ .opcode = opcode, .payload = self.buffer.items };
            },
            else => return error.ProtocolError,
        }
    }
};

/// `Sec-WebSocket-Accept` for a request key.
pub fn acceptKey(key: []const u8) [28]u8 {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(GUID);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

pub fn upgradeRequestAlloc(allocator: std.mem.Allocator, host: []const u8, target: []const u8, key: []const u8, bearer: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.print("GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\nUser-Agent: Verde\r\n", .{ target, host, key });
    if (bearer) |token| try w.print("Authorization: Bearer {s}\r\n", .{token});
    try w.writeAll("\r\n");
    return out.toOwnedSlice();
}

pub const UpgradeError = error{ Unauthorized, UpgradeRejected, BadAccept };

/// Checks the upgrade response head (status line and headers, CRLF separated).
pub fn checkUpgradeResponse(head: []const u8, key: []const u8) UpgradeError!void {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status = lines.next() orelse return error.UpgradeRejected;
    if (std.mem.startsWith(u8, status, "HTTP/1.1 401") or std.mem.startsWith(u8, status, "HTTP/1.1 403")) return error.Unauthorized;
    if (!std.mem.startsWith(u8, status, "HTTP/1.1 101")) return error.UpgradeRejected;
    const expected = acceptKey(key);
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "sec-websocket-accept")) continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[colon + 1 ..], " \t"), &expected)) return;
        return error.BadAccept;
    }
    return error.BadAccept;
}

/// Host and request target of a `wss://` URL.
pub fn splitUrl(url: []const u8) ?struct { host: []const u8, target: []const u8 } {
    const prefix = "wss://";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    const rest = url[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host = rest[0..slash];
    if (host.len == 0 or std.mem.indexOfScalar(u8, host, ':') != null or std.mem.indexOfScalar(u8, host, '@') != null) return null;
    return .{ .host = host, .target = if (slash == rest.len) "/" else rest[slash..] };
}

// ---- client --------------------------------------------------------------------

pub const Message = struct { opcode: Opcode, payload: []const u8 };

pub const Client = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    http: std.http.Client,
    connection: *std.http.Client.Connection,
    inbox: std.ArrayList(u8) = .empty,
    assembler: Assembler = .{},
    closed: bool = false,

    /// Connects, upgrades, and returns an owned client. Blocking.
    pub fn connect(allocator: std.mem.Allocator, url: []const u8, bearer: ?[]const u8) !*Client {
        const parts = splitUrl(url) orelse return error.InvalidUrl;
        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .threaded = .init(allocator, .{}),
            .http = undefined,
            .connection = undefined,
        };
        errdefer self.threaded.deinit();
        const io = self.threaded.io();
        self.http = .{ .allocator = allocator, .io = io, .read_buffer_size = 64 * 1024, .write_buffer_size = 16 * 1024 };
        errdefer self.http.deinit();
        {
            const now = std.Io.Clock.real.now(io);
            var bundle: std.crypto.Certificate.Bundle = .empty;
            bundle.rescan(allocator, io, now) catch return error.CertificateBundleLoadFailure;
            self.http.ca_bundle = bundle;
            self.http.now = now;
        }
        const host = try std.Io.net.HostName.init(parts.host);
        self.connection = try self.http.connectTcp(host, 443, .tls);
        errdefer self.releaseConnection();

        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &nonce);
        const request = try upgradeRequestAlloc(allocator, parts.host, parts.target, &key, bearer);
        defer {
            std.crypto.secureZero(u8, request);
            allocator.free(request);
        }
        try self.connection.writer().writeAll(request);
        try self.connection.flush();

        const reader = self.connection.reader();
        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(allocator);
        while (true) {
            if (std.mem.indexOf(u8, head.items, "\r\n\r\n")) |end| {
                try checkUpgradeResponse(head.items[0..end], &key);
                try self.inbox.appendSlice(allocator, head.items[end + 4 ..]);
                break;
            }
            if (head.items.len > MAX_HEADER_BYTES) return error.UpgradeRejected;
            reader.fillMore() catch return error.UpgradeRejected;
            try head.appendSlice(allocator, reader.buffered());
            reader.tossBuffered();
        }
        return self;
    }

    pub fn destroy(self: *Client) void {
        const allocator = self.allocator;
        self.inbox.deinit(allocator);
        self.assembler.deinit(allocator);
        self.releaseConnection();
        self.http.deinit();
        self.threaded.deinit();
        allocator.destroy(self);
    }

    /// Hands the socket back to the pool marked closing, which closes it.
    fn releaseConnection(self: *Client) void {
        self.connection.closing = true;
        self.http.connection_pool.release(self.connection, self.threaded.io());
    }

    /// The socket to poll for readability.
    pub fn fd(self: *Client) std.posix.fd_t {
        return self.connection.stream_reader.stream.socket.handle;
    }

    /// Decrypted or raw bytes are already buffered, so `receive` won't block on the socket.
    pub fn hasBuffered(self: *Client) bool {
        return self.connection.reader().bufferedLen() > 0 or self.connection.stream_reader.interface.bufferedLen() > 0;
    }

    pub fn sendText(self: *Client, payload: []const u8) !void {
        try self.sendFrame(.text, payload);
    }

    fn sendFrame(self: *Client, opcode: Opcode, payload: []const u8) !void {
        if (self.closed) return error.Closed;
        var mask: [4]u8 = undefined;
        self.threaded.io().random(&mask);
        const frame = try encodeFrameAlloc(self.allocator, opcode, payload, mask);
        defer self.allocator.free(frame);
        try self.connection.writer().writeAll(frame);
        try self.connection.flush();
    }

    /// Reads at least one more TLS record, then delivers every complete data
    /// message to `handler.onMessage(payload)`. Answers pings; a close frame
    /// (or EOF) returns `error.Closed`.
    pub fn receive(self: *Client, handler: anytype) !void {
        const reader = self.connection.reader();
        if (reader.bufferedLen() == 0) reader.fillMore() catch return error.Closed;
        try self.inbox.appendSlice(self.allocator, reader.buffered());
        reader.tossBuffered();
        var consumed: usize = 0;
        defer {
            const rest = self.inbox.items.len - consumed;
            std.mem.copyForwards(u8, self.inbox.items[0..rest], self.inbox.items[consumed..]);
            self.inbox.shrinkRetainingCapacity(rest);
        }
        while (try parseFrame(self.inbox.items[consumed..])) |parsed| {
            consumed += parsed.consumed;
            const frame = parsed.frame;
            switch (frame.opcode) {
                .ping => try self.sendFrame(.pong, frame.payload),
                .pong => {},
                .close => {
                    self.sendFrame(.close, &.{}) catch {};
                    self.closed = true;
                    return error.Closed;
                },
                else => if (try self.assembler.push(self.allocator, frame)) |message| {
                    try handler.onMessage(message.payload);
                },
            }
        }
    }

    /// Best-effort close handshake start; the caller then destroys.
    pub fn close(self: *Client) void {
        if (self.closed) return;
        self.sendFrame(.close, &.{ 0x03, 0xE8 }) catch {};
        self.closed = true;
    }
};

// ---- tests ---------------------------------------------------------------------

const testing = std.testing;

test "accept key matches the RFC 6455 example" {
    const accept = acceptKey("dGhlIHNhbXBsZSBub25jZQ==");
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
    try checkUpgradeResponse("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSEC-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "dGhlIHNhbXBsZSBub25jZQ==");
    try testing.expectError(error.Unauthorized, checkUpgradeResponse("HTTP/1.1 401 Unauthorized\r\n", "k"));
    try testing.expectError(error.UpgradeRejected, checkUpgradeResponse("HTTP/1.1 200 OK\r\n", "k"));
    try testing.expectError(error.BadAccept, checkUpgradeResponse("HTTP/1.1 101 Switching\r\nSec-WebSocket-Accept: nope", "dGhlIHNhbXBsZSBub25jZQ=="));
}

test "upgrade request carries the key and optional bearer" {
    const request = try upgradeRequestAlloc(testing.allocator, "api.x.ai", "/v1/realtime?model=m", "KEY", "tok");
    defer testing.allocator.free(request);
    try testing.expect(std.mem.startsWith(u8, request, "GET /v1/realtime?model=m HTTP/1.1\r\nHost: api.x.ai\r\n"));
    try testing.expect(std.mem.indexOf(u8, request, "Sec-WebSocket-Key: KEY\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, request, "Authorization: Bearer tok\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, request, "\r\n\r\n"));
}

test "urls split into host and target; only plain wss hosts" {
    const parts = splitUrl("wss://generativelanguage.googleapis.com/ws/x?access_token=a%2Fb").?;
    try testing.expectEqualStrings("generativelanguage.googleapis.com", parts.host);
    try testing.expectEqualStrings("/ws/x?access_token=a%2Fb", parts.target);
    try testing.expectEqualStrings("/", splitUrl("wss://api.x.ai").?.target);
    try testing.expect(splitUrl("ws://api.x.ai/") == null);
    try testing.expect(splitUrl("wss://user@host/") == null);
}

test "client frames are masked with the right length encoding" {
    const allocator = testing.allocator;
    const mask = [4]u8{ 1, 2, 3, 4 };
    const small = try encodeFrameAlloc(allocator, .text, "Hi", mask);
    defer allocator.free(small);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x82, 1, 2, 3, 4, 'H' ^ 1, 'i' ^ 2 }, small);
    const medium_payload = try allocator.alloc(u8, 300);
    defer allocator.free(medium_payload);
    @memset(medium_payload, 'a');
    const medium = try encodeFrameAlloc(allocator, .text, medium_payload, mask);
    defer allocator.free(medium);
    try testing.expectEqual(@as(u8, 0x80 | 126), medium[1]);
    try testing.expectEqual(@as(u16, 300), std.mem.readInt(u16, medium[2..4], .big));
    try testing.expectEqual(@as(usize, 4 + 4 + 300), medium.len);
    const large_payload = try allocator.alloc(u8, 70_000);
    defer allocator.free(large_payload);
    @memset(large_payload, 0);
    const large = try encodeFrameAlloc(allocator, .binary, large_payload, mask);
    defer allocator.free(large);
    try testing.expectEqual(@as(u8, 0x80 | 127), large[1]);
    try testing.expectEqual(@as(u64, 70_000), std.mem.readInt(u64, large[2..10], .big));
}

test "server frames parse incrementally and fragments assemble" {
    const allocator = testing.allocator;
    try testing.expect((try parseFrame(&.{0x81})) == null);
    try testing.expect((try parseFrame(&.{ 0x81, 0x05, 'h' })) == null);
    const whole = (try parseFrame(&.{ 0x81, 0x02, 'h', 'i', 0x89 })).?;
    try testing.expectEqual(@as(usize, 4), whole.consumed);
    try testing.expectEqualStrings("hi", whole.frame.payload);
    try testing.expectError(error.MaskedServerFrame, parseFrame(&.{ 0x81, 0x82, 0, 0, 0, 0, 0, 0 }));
    try testing.expectError(error.ProtocolError, parseFrame(&.{ 0x09, 0x00 }));

    var extended: [4 + 200]u8 = undefined;
    extended[0] = 0x81;
    extended[1] = 126;
    std.mem.writeInt(u16, extended[2..4], 200, .big);
    @memset(extended[4..], 'z');
    try testing.expectEqual(@as(usize, 200), (try parseFrame(&extended)).?.frame.payload.len);

    var assembler: Assembler = .{};
    defer assembler.deinit(allocator);
    try testing.expect((try assembler.push(allocator, .{ .fin = false, .opcode = .text, .payload = "hel" })) == null);
    const message = (try assembler.push(allocator, .{ .fin = true, .opcode = .continuation, .payload = "lo" })).?;
    try testing.expectEqualStrings("hello", message.payload);
    try testing.expectError(error.ProtocolError, assembler.push(allocator, .{ .fin = true, .opcode = .continuation, .payload = "x" }));
}

test "client compiles against std's TLS connection" {
    const Handler = struct {
        fn onMessage(_: @This(), _: []const u8) !void {}
    };
    _ = &Client.connect;
    _ = &Client.destroy;
    _ = &Client.sendText;
    _ = &Client.close;
    _ = &Client.fd;
    _ = &Client.hasBuffered;
    var run = false;
    _ = &run;
    if (run) try Client.receive(@as(*Client, undefined), Handler{});
}
