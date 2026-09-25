//! K-14 contract suite: the real client core against a real temporary
//! `verde-daemon serve` and `verde-web`, reached through a loopback proxy that
//! supplies the trusted-proxy envelope (the role Caddy/Tailscale plays).
//!
//! Hermetic by construction: temporary state/config/home, loopback only, the
//! daemon's built-in offline chat stub (codex has no model-discovery I/O),
//! finite per-step deadlines plus a process-wide watchdog, and deterministic
//! teardown (core shutdown, worker joins, SIGTERM with a bounded grace, temp
//! tree removal). Secrets (pairing code, credentials, tokens, tickets) are
//! never printed: diagnostics only show non-secret view fields.
//!
//! Run with `mise run mobile-core-contract` (`zig build contract`), which
//! builds the daemon and gateway executables first.
const std = @import("std");
const builtin = @import("builtin");
const contract_options = @import("contract_options");
const h = @import("host.zig");
const auth = @import("auth.zig");
const wire = @import("wire.zig");
const c = std.c;
const V = std.json.Value;
const A = std.mem.Allocator;

const gpa = std.heap.smp_allocator;
const public_authority = "runtime.contract.test";
const public_origin = "https://" ++ public_authority;
const public_wss = "wss://" ++ public_authority ++ "/ws";
/// Stands in for the proxy certificate's SPKI pin; every effect must echo it.
const fake_pin = "c0ffee" ++ "0" ** 58;
/// Documentation-range client address supplied as X-Forwarded-For.
const forwarded_client = "192.0.2.7";
const workspace_id = "contract-ws";
const thread_id = "contract-thread";
const approval_prompt = "orchestration approval";
const step_timeout_ms = 30_000;
const watchdog_ms = 240_000;

// ---------------------------------------------------------------------------
// Shared cross-thread state. Workers only touch the queue, their own job, and
// the stop flag; the core is owned by the test thread.

var stop_flag = std.atomic.Value(bool).init(false);
var queue_lock: std.atomic.Mutex = .unlocked;
var queue: std.ArrayList(Item) = .empty;
var threads_lock: std.atomic.Mutex = .unlocked;
var threads: std.ArrayList(std.Thread) = .empty;
/// Children the watchdog must kill if the suite wedges.
var child_pids: [2]std.atomic.Value(c.pid_t) = .{ .init(0), .init(0) };
var suite_done = std.atomic.Value(bool).init(false);

const Item = struct { tag: []const u8, payload: []u8 };
const Failure = struct { kind: []const u8, code: []const u8 };
const Header = struct { name: []const u8, value: []const u8 };

fn lock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

fn push(tag: []const u8, payload: anytype) void {
    const bytes = std.json.Stringify.valueAlloc(gpa, payload, .{}) catch @panic("contract: out of memory");
    lock(&queue_lock);
    defer queue_lock.unlock();
    queue.append(gpa, .{ .tag = tag, .payload = bytes }) catch @panic("contract: out of memory");
}

fn spawnTracked(comptime f: anytype, args: anytype) !void {
    const thread = try std.Thread.spawn(.{}, f, args);
    lock(&threads_lock);
    defer threads_lock.unlock();
    threads.append(gpa, thread) catch {
        threads_lock.unlock();
        thread.join();
        threads_lock = .unlocked;
        return error.OutOfMemory;
    };
}

fn joinAll() void {
    while (true) {
        lock(&threads_lock);
        const next = threads.pop();
        threads_lock.unlock();
        (next orelse break).join();
    }
    threads.deinit(gpa);
    threads = .empty;
}

// ---------------------------------------------------------------------------
// Clock and socket primitives (Linux libc).

fn clockMs(id: c.clockid_t) i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(id, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}
fn monoMs() i64 {
    return clockMs(.MONOTONIC);
}
fn wallMs() i64 {
    return clockMs(.REALTIME);
}
fn sleepMs(ms: i64) void {
    var ts: c.timespec = .{ .sec = @intCast(@divTrunc(ms, 1000)), .nsec = @intCast(@rem(ms, 1000) * 1_000_000) };
    _ = c.nanosleep(&ts, null);
}

fn loopback(port: u16) c.sockaddr.in {
    return .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f00_0001) };
}

fn tcpConnect(port: u16) !c.fd_t {
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    var address = loopback(port);
    if (c.connect(fd, @ptrCast(&address), @sizeOf(c.sockaddr.in)) != 0) return error.ConnectionRefused;
    return fd;
}

fn tcpListen(port: u16) !c.fd_t {
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    var address = loopback(port);
    if (c.bind(fd, @ptrCast(&address), @sizeOf(c.sockaddr.in)) != 0) return error.BindFailed;
    if (c.listen(fd, 64) != 0) return error.ListenFailed;
    return fd;
}

fn localPort(fd: c.fd_t) !u16 {
    var address: c.sockaddr.in = undefined;
    var len: c.socklen_t = @sizeOf(c.sockaddr.in);
    if (c.getsockname(fd, @ptrCast(&address), &len) != 0) return error.GetSockNameFailed;
    return std.mem.bigToNative(u16, address.port);
}

/// verde-web rejects `--port 0`, so reserve a kernel-chosen ephemeral port and
/// hand it over; a lost race makes the gateway exit and the caller retries.
fn reservePort() !u16 {
    const fd = try tcpListen(0);
    defer _ = c.close(fd);
    return localPort(fd);
}

/// Poll in short slices so every blocking read honors a deadline, the global
/// stop flag, and an optional per-job cancel flag.
fn readSome(fd: c.fd_t, buf: []u8, deadline: i64, cancel: ?*const std.atomic.Value(bool)) !usize {
    while (true) {
        if (stop_flag.load(.acquire)) return error.Stopped;
        if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
        const left = deadline - monoMs();
        if (left <= 0) return error.Timeout;
        var fds = [1]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
        const ready = c.poll(&fds, 1, @intCast(@min(left, 100)));
        if (ready <= 0) continue;
        const n = c.read(fd, buf.ptr, buf.len);
        if (n < 0) return error.ReadFailed;
        return @intCast(n);
    }
}

fn writeAll(fd: c.fd_t, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = c.send(fd, bytes[sent..].ptr, bytes.len - sent, c.MSG.NOSIGNAL);
        if (n <= 0) return error.WriteFailed;
        sent += @intCast(n);
    }
}

fn headEnd(bytes: []const u8) ?usize {
    const at = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return null;
    return at + 4;
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

// ---------------------------------------------------------------------------
// Trusted-proxy stand-in: rewrite the envelope exactly as a TLS-terminating
// loopback proxy would, then splice bytes in both directions.

const Proxy = struct {
    listen_fd: c.fd_t,
    port: u16,
    upstream: u16,
    connections: std.atomic.Value(u32) = .init(0),

    fn start(upstream: u16) !*Proxy {
        const fd = try tcpListen(0);
        errdefer _ = c.close(fd);
        const proxy = try gpa.create(Proxy);
        proxy.* = .{ .listen_fd = fd, .port = try localPort(fd), .upstream = upstream };
        try spawnTracked(acceptLoop, .{proxy});
        return proxy;
    }

    fn acceptLoop(proxy: *Proxy) void {
        while (!stop_flag.load(.acquire)) {
            var fds = [1]c.pollfd{.{ .fd = proxy.listen_fd, .events = c.POLL.IN, .revents = 0 }};
            if (c.poll(&fds, 1, 100) <= 0) continue;
            const client = c.accept(proxy.listen_fd, null, null);
            if (client < 0) continue;
            _ = proxy.connections.fetchAdd(1, .monotonic);
            spawnTracked(splice, .{ client, proxy.upstream }) catch {
                _ = c.close(client);
            };
        }
    }

    fn splice(client: c.fd_t, upstream_port: u16) void {
        defer _ = c.close(client);
        var head_buf: [64 * 1024]u8 = undefined;
        var used: usize = 0;
        const end = while (true) {
            if (headEnd(head_buf[0..used])) |at| break at;
            if (used == head_buf.len) return;
            const n = readSome(client, head_buf[used..], monoMs() + 15_000, null) catch return;
            if (n == 0) return;
            used += n;
        };
        const rewritten = rewriteEnvelope(head_buf[0..end]) catch return;
        defer gpa.free(rewritten);
        const upstream = tcpConnect(upstream_port) catch return;
        defer _ = c.close(upstream);
        writeAll(upstream, rewritten) catch return;
        writeAll(upstream, head_buf[end..used]) catch return;

        var open = [2]bool{ true, true };
        var buf: [64 * 1024]u8 = undefined;
        while ((open[0] or open[1]) and !stop_flag.load(.acquire)) {
            var fds = [2]c.pollfd{
                .{ .fd = if (open[0]) client else -1, .events = c.POLL.IN, .revents = 0 },
                .{ .fd = if (open[1]) upstream else -1, .events = c.POLL.IN, .revents = 0 },
            };
            if (c.poll(&fds, 2, 100) <= 0) continue;
            for (0..2) |i| {
                if (!open[i] or fds[i].revents == 0) continue;
                const from = if (i == 0) client else upstream;
                const to = if (i == 0) upstream else client;
                const n = c.read(from, &buf, buf.len);
                if (n <= 0) {
                    open[i] = false;
                    _ = c.shutdown(to, c.SHUT.WR);
                    continue;
                }
                writeAll(to, buf[0..@intCast(n)]) catch return;
            }
        }
    }

    /// Drop every client-supplied Host/Forwarded/X-Forwarded-* value and emit
    /// the single trusted envelope verde-web accepts for the configured origin.
    fn rewriteEnvelope(head: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var lines = std.mem.splitSequence(u8, head[0 .. head.len - 4], "\r\n");
        try out.appendSlice(gpa, lines.next() orelse return error.BadRequest);
        try out.appendSlice(gpa, "\r\nHost: " ++ public_authority ++ "\r\nX-Forwarded-Proto: https\r\nX-Forwarded-Host: " ++ public_authority ++ "\r\nX-Forwarded-For: " ++ forwarded_client ++ "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            if (std.ascii.eqlIgnoreCase(name, "host") or std.ascii.eqlIgnoreCase(name, "forwarded") or
                (name.len >= 12 and std.ascii.eqlIgnoreCase(name[0..12], "x-forwarded-"))) continue;
            try out.appendSlice(gpa, line);
            try out.appendSlice(gpa, "\r\n");
        }
        try out.appendSlice(gpa, "\r\n");
        return out.toOwnedSlice(gpa);
    }
};

// ---------------------------------------------------------------------------
// HTTP adapter: one Connection: close exchange per effect, on a worker thread.

const HttpJob = struct {
    effect_id: []u8,
    generation: []u8,
    request: []u8,
    port: u16,
    timeout_ms: u32,
    max_bytes: usize,
    cancelled: std.atomic.Value(bool) = .init(false),
};

const HttpResult = union(enum) {
    response: struct { status: u16, headers: []Header, body: []u8 },
    failure: Failure,
};

fn httpExchange(a: A, port: u16, request: []const u8, timeout_ms: u32, max_bytes: usize, cancel: ?*const std.atomic.Value(bool)) !HttpResult {
    const deadline = monoMs() + timeout_ms;
    const fd = tcpConnect(port) catch return .{ .failure = .{ .kind = "network", .code = "refused" } };
    defer _ = c.close(fd);
    writeAll(fd, request) catch return .{ .failure = .{ .kind = "network", .code = "reset" } };
    var raw: std.ArrayList(u8) = .empty;
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = readSome(fd, &buf, deadline, cancel) catch |err| return switch (err) {
            error.Timeout => .{ .failure = .{ .kind = "timeout", .code = "timeout" } },
            error.Cancelled, error.Stopped => .{ .failure = .{ .kind = "cancelled", .code = "cancelled" } },
            else => .{ .failure = .{ .kind = "network", .code = "reset" } },
        };
        if (n == 0) break;
        try raw.appendSlice(a, buf[0..n]);
        if (raw.items.len > max_bytes + 64 * 1024) return .{ .failure = .{ .kind = "resource", .code = "resource" } };
    }
    const end = headEnd(raw.items) orelse return .{ .failure = .{ .kind = "network", .code = "reset" } };
    const head = raw.items[0..end];
    if (head.len < 12 or !std.mem.startsWith(u8, head, "HTTP/1.")) return .{ .failure = .{ .kind = "network", .code = "reset" } };
    const status = std.fmt.parseInt(u16, head[9..12], 10) catch return .{ .failure = .{ .kind = "network", .code = "reset" } };
    var headers: std.ArrayList(Header) = .empty;
    var lines = std.mem.splitSequence(u8, head[0 .. head.len - 4], "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        try headers.append(a, .{ .name = try std.ascii.allocLowerString(a, std.mem.trim(u8, line[0..colon], " \t")), .value = std.mem.trim(u8, line[colon + 1 ..], " \t") });
    }
    var body = raw.items[end..];
    if (headerValue(head, "transfer-encoding")) |te| if (std.ascii.eqlIgnoreCase(te, "chunked")) {
        body = dechunk(a, body) catch return .{ .failure = .{ .kind = "network", .code = "reset" } };
    };
    if (headerValue(head, "content-length")) |cl| {
        const len = std.fmt.parseInt(usize, cl, 10) catch return .{ .failure = .{ .kind = "network", .code = "reset" } };
        if (len > body.len) return .{ .failure = .{ .kind = "network", .code = "reset" } };
        body = body[0..len];
    }
    if (body.len > max_bytes) return .{ .failure = .{ .kind = "resource", .code = "resource" } };
    return .{ .response = .{ .status = status, .headers = headers.items, .body = body } };
}

fn dechunk(a: A, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = input;
    while (true) {
        const line_end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.BadChunk;
        const line = rest[0..line_end];
        const size_text = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, ';') orelse line.len], " \t");
        const size = try std.fmt.parseInt(usize, size_text, 16);
        rest = rest[line_end + 2 ..];
        if (size == 0) return out.toOwnedSlice(a);
        if (rest.len < size + 2) return error.BadChunk;
        try out.appendSlice(a, rest[0..size]);
        rest = rest[size + 2 ..];
    }
}

fn httpThread(job: *HttpJob) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const result = httpExchange(a, job.port, job.request, job.timeout_ms, job.max_bytes, &job.cancelled) catch HttpResult{ .failure = .{ .kind = "resource", .code = "resource" } };
    std.crypto.secureZero(u8, job.request);
    // A cancelled request is abandoned; the core already forgot the effect.
    if (job.cancelled.load(.acquire)) return;
    switch (result) {
        .response => |r| {
            const encoded = a.alloc(u8, std.base64.standard.Encoder.calcSize(r.body.len)) catch @panic("contract: out of memory");
            push("http_response", .{ .effect_id = job.effect_id, .generation = job.generation, .status = r.status, .headers = r.headers, .body_base64 = std.base64.standard.Encoder.encode(encoded, r.body), .@"error" = @as(?Failure, null) });
            std.crypto.secureZero(u8, r.body);
            std.crypto.secureZero(u8, encoded);
        },
        .failure => |f| push("http_response", .{ .effect_id = job.effect_id, .generation = job.generation, .status = @as(?u16, null), .headers = [_]Header{}, .body_base64 = @as(?[]const u8, null), .@"error" = f }),
    }
}

// ---------------------------------------------------------------------------
// WebSocket adapter (RFC 6455 client; text frames only, as the gateway sends).

const WsConn = struct {
    socket_id: []u8,
    generation: []u8,
    protocols: []u8,
    port: u16,
    max_bytes: usize,
    fd: std.atomic.Value(c.fd_t) = .init(-1),
    closed_by_core: std.atomic.Value(bool) = .init(false),
    write_lock: std.atomic.Mutex = .unlocked,
    prng: std.Random.DefaultPrng,

    fn sendFrame(conn: *WsConn, opcode: u8, payload: []const u8) void {
        lock(&conn.write_lock);
        defer conn.write_lock.unlock();
        const fd = conn.fd.load(.acquire);
        if (fd < 0) return;
        var header: [14]u8 = undefined;
        header[0] = 0x80 | opcode;
        var len: usize = 2;
        if (payload.len < 126) {
            header[1] = 0x80 | @as(u8, @intCast(payload.len));
        } else if (payload.len <= 0xffff) {
            header[1] = 0x80 | 126;
            std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
            len = 4;
        } else {
            header[1] = 0x80 | 127;
            std.mem.writeInt(u64, header[2..10], payload.len, .big);
            len = 10;
        }
        var mask: [4]u8 = undefined;
        conn.prng.random().bytes(&mask);
        @memcpy(header[len .. len + 4], &mask);
        len += 4;
        const masked = gpa.alloc(u8, payload.len) catch return;
        defer gpa.free(masked);
        for (payload, 0..) |byte, i| masked[i] = byte ^ mask[i % 4];
        writeAll(fd, header[0..len]) catch return;
        writeAll(fd, masked) catch return;
    }

    fn closed(conn: *WsConn, code: ?u16, clean: bool, failure: ?Failure) void {
        if (conn.closed_by_core.load(.acquire)) return;
        push("ws_closed", .{ .socket_id = conn.socket_id, .generation = conn.generation, .code = code, .clean = clean, .@"error" = failure });
    }
};

fn wsThread(conn: *WsConn) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const fd = tcpConnect(conn.port) catch return conn.closed(null, false, .{ .kind = "network", .code = "refused" });
    conn.fd.store(fd, .release);
    defer {
        lock(&conn.write_lock);
        conn.fd.store(-1, .release);
        _ = c.close(fd);
        conn.write_lock.unlock();
    }
    var key_bytes: [16]u8 = undefined;
    conn.prng.random().bytes(&key_bytes);
    var key: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key, &key_bytes);
    const request = std.fmt.allocPrint(a, "GET /ws HTTP/1.1\r\nHost: " ++ public_authority ++ "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: {s}\r\n\r\n", .{ &key, conn.protocols }) catch return;
    defer std.crypto.secureZero(u8, request);
    std.crypto.secureZero(u8, conn.protocols);
    writeAll(fd, request) catch return conn.closed(null, false, .{ .kind = "network", .code = "reset" });

    var buf: std.ArrayList(u8) = .empty;
    var chunk: [64 * 1024]u8 = undefined;
    const handshake_deadline = monoMs() + 15_000;
    const end = while (true) {
        if (headEnd(buf.items)) |at| break at;
        const n = readSome(fd, &chunk, handshake_deadline, &conn.closed_by_core) catch |err| return conn.closed(null, false, if (err == error.Timeout) .{ .kind = "timeout", .code = "timeout" } else .{ .kind = "network", .code = "reset" });
        if (n == 0) return conn.closed(null, false, .{ .kind = "network", .code = "reset" });
        buf.appendSlice(a, chunk[0..n]) catch return;
    };
    const head = buf.items[0..end];
    if (!std.mem.startsWith(u8, head, "HTTP/1.1 101")) return conn.closed(null, false, .{ .kind = "network", .code = "refused" });
    push("ws_open", .{ .socket_id = conn.socket_id, .generation = conn.generation, .protocol = headerValue(head, "sec-websocket-protocol") orelse "" });

    var pending: std.ArrayList(u8) = .empty;
    pending.appendSlice(a, buf.items[end..]) catch return;
    var message: std.ArrayList(u8) = .empty;
    const forever = std.math.maxInt(i64);
    while (true) {
        // Parse as many complete frames as are buffered.
        while (pending.items.len >= 2) {
            const b0 = pending.items[0];
            const b1 = pending.items[1];
            var offset: usize = 2;
            var len: u64 = b1 & 0x7f;
            if (len == 126) {
                if (pending.items.len < 4) break;
                len = std.mem.readInt(u16, pending.items[2..4], .big);
                offset = 4;
            } else if (len == 127) {
                if (pending.items.len < 10) break;
                len = std.mem.readInt(u64, pending.items[2..10], .big);
                offset = 10;
            }
            if (b1 & 0x80 != 0) return conn.closed(1002, false, .{ .kind = "network", .code = "reset" });
            if (len > conn.max_bytes) {
                conn.sendFrame(8, &.{ 0x03, 0xf1 });
                return conn.closed(1009, false, .{ .kind = "resource", .code = "resource" });
            }
            if (pending.items.len < offset + len) break;
            const payload = pending.items[offset..][0..@intCast(len)];
            const opcode = b0 & 0x0f;
            switch (opcode) {
                0, 1 => {
                    message.appendSlice(a, payload) catch return;
                    if (message.items.len > conn.max_bytes) {
                        conn.sendFrame(8, &.{ 0x03, 0xf1 });
                        return conn.closed(1009, false, .{ .kind = "resource", .code = "resource" });
                    }
                    if (b0 & 0x80 != 0) {
                        push("ws_message", .{ .socket_id = conn.socket_id, .generation = conn.generation, .text = message.items });
                        message.clearRetainingCapacity();
                    }
                },
                8 => {
                    const code: ?u16 = if (payload.len >= 2) std.mem.readInt(u16, payload[0..2], .big) else null;
                    conn.sendFrame(8, payload[0..@min(payload.len, 2)]);
                    return conn.closed(code, true, null);
                },
                9 => conn.sendFrame(10, payload),
                10 => {},
                else => {
                    conn.sendFrame(8, &.{ 0x03, 0xea });
                    return conn.closed(1002, false, .{ .kind = "network", .code = "reset" });
                },
            }
            const consumed = offset + @as(usize, @intCast(len));
            std.mem.copyForwards(u8, pending.items, pending.items[consumed..]);
            pending.shrinkRetainingCapacity(pending.items.len - consumed);
        }
        const n = readSome(fd, &chunk, forever, &conn.closed_by_core) catch return conn.closed(null, false, .{ .kind = "network", .code = "reset" });
        if (n == 0) return conn.closed(null, false, .{ .kind = "network", .code = "reset" });
        pending.appendSlice(a, chunk[0..n]) catch return;
    }
}

// ---------------------------------------------------------------------------
// Owner-side helpers: the daemon's private Unix socket and CLI.

fn daemonCall(a: A, socket_path: []const u8, method: []const u8, params: anytype, target: ?V) !V {
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = c.close(fd);
    var address: c.sockaddr.un = .{ .path = @splat(0) };
    if (socket_path.len >= address.path.len) return error.NameTooLong;
    @memcpy(address.path[0..socket_path.len], socket_path);
    if (c.connect(fd, @ptrCast(&address), @sizeOf(c.sockaddr.un)) != 0) return error.ConnectionRefused;
    var request = try h.parse(a, try h.encode(a, .{ .id = 1, .method = method, .params = params }));
    // An empty anonymous struct encodes as `[]`; JSON-RPC params must be an object.
    if (request.object.get("params").? == .array) try request.object.put(a, "params", .{ .object = .empty });
    if (target) |t| try request.object.put(a, "target", t);
    const line = try std.fmt.allocPrint(a, "{s}\n", .{try h.encode(a, request)});
    try writeAll(fd, line);
    var raw: std.ArrayList(u8) = .empty;
    var buf: [16 * 1024]u8 = undefined;
    const deadline = monoMs() + 10_000;
    while (std.mem.indexOfScalar(u8, raw.items, '\n') == null) {
        const n = try readSome(fd, &buf, deadline, null);
        if (n == 0) return error.UnexpectedEof;
        try raw.appendSlice(a, buf[0..n]);
    }
    const response = try h.parse(a, raw.items[0..std.mem.indexOfScalar(u8, raw.items, '\n').?]);
    if (response.object.get("error")) |err| {
        std.debug.print("contract: daemon {s} failed: {s}\n", .{ method, str(err, "code") });
        return error.DaemonCallFailed;
    }
    return response.object.get("result") orelse error.DaemonCallFailed;
}

fn get(v: V, key: []const u8) V {
    if (v != .object) return .null;
    return v.object.get(key) orelse .null;
}
fn str(v: V, key: []const u8) []const u8 {
    const f = get(v, key);
    return if (f == .string) f.string else "";
}
fn items(v: V) []const V {
    return if (v == .array) v.array.items else &.{};
}

fn exitDescription(status: c_int) struct { exited: bool, code: u32 } {
    const bits: u32 = @bitCast(status);
    if (bits & 0x7f == 0) return .{ .exited = true, .code = (bits >> 8) & 0xff };
    return .{ .exited = false, .code = bits & 0x7f };
}

/// SIGTERM with a bounded grace, then SIGKILL. Returns whether the exit was
/// graceful (status 0 or terminated by the SIGTERM we sent).
fn stopChild(pid: c.pid_t, name: []const u8) bool {
    if (pid <= 0) return true;
    _ = c.kill(pid, .TERM);
    const deadline = monoMs() + 10_000;
    var status: c_int = 0;
    while (monoMs() < deadline) {
        const r = c.waitpid(pid, &status, c.W.NOHANG);
        if (r == pid) {
            const d = exitDescription(status);
            const graceful = (d.exited and d.code == 0) or (!d.exited and d.code == @intFromEnum(c.SIG.TERM));
            if (!graceful) std.debug.print("contract: {s} exited {s} {d}\n", .{ name, if (d.exited) "with code" else "on signal", d.code });
            return graceful;
        }
        if (r < 0) return false;
        sleepMs(20);
    }
    std.debug.print("contract: {s} ignored SIGTERM for 10s; killing\n", .{name});
    _ = c.kill(pid, .KILL);
    _ = c.waitpid(pid, &status, 0);
    return false;
}

fn watchdog() void {
    const deadline = monoMs() + watchdog_ms;
    while (!suite_done.load(.acquire)) {
        if (monoMs() > deadline) {
            std.debug.print("contract: watchdog expired after {d} ms; killing children\n", .{watchdog_ms});
            for (&child_pids) |*pid| {
                const value = pid.load(.acquire);
                if (value > 0) _ = c.kill(value, .KILL);
            }
            std.process.exit(1);
        }
        sleepMs(100);
    }
}

fn randomHex(io: std.Io, comptime n: usize) [n * 2]u8 {
    var bytes: [n]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

// ---------------------------------------------------------------------------
// World: temporary daemon + gateway + proxy.

const World = struct {
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    data_dir: []const u8,
    socket_path: []const u8,
    daemon_pid: c.pid_t = 0,
    web_pid: c.pid_t = 0,
    web_port: u16 = 0,
    proxy: ?*Proxy = null,
    runtime_id: []const u8 = "",
    instance_id: []const u8 = "",
    daemon_env: std.process.Environ.Map,
    web_env: std.process.Environ.Map,
    torn_down: bool = false,
    watchdog: ?std.Thread = null,

    fn path(w: *World, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(w.arena.allocator(), fmt, args) catch @panic("contract: out of memory");
    }

    fn mkdir(p: []const u8) !void {
        const z = try gpa.dupeZ(u8, p);
        defer gpa.free(z);
        if (c.mkdir(z, 0o700) != 0) return error.MkdirFailed;
    }

    fn start(io: std.Io) !*World {
        const w = try gpa.create(World);
        w.* = .{ .io = io, .arena = .init(gpa), .root = "", .data_dir = "", .socket_path = "", .daemon_env = .init(gpa), .web_env = .init(gpa) };
        errdefer w.teardown() catch {};
        // Short /tmp path keeps the Unix socket under sun_path's 108 bytes.
        w.root = w.path("/tmp/verde-k14-{d}-{s}", .{ c.getpid(), &randomHex(io, 4) });
        try mkdir(w.root);
        w.data_dir = w.path("{s}/data", .{w.root});
        w.socket_path = w.path("{s}/verde-sessionizer.sock", .{w.data_dir});
        for ([_][]const u8{ "data", "home", "config", "share", "state", "cache", "run", "tmp", "bin", "static", "project" }) |sub| try mkdir(w.path("{s}/{s}", .{ w.root, sub }));

        // Fresh environments: nothing inherited, no user daemon or config, and
        // an empty PATH directory so no provider CLI can ever be launched.
        for ([_]*std.process.Environ.Map{ &w.daemon_env, &w.web_env }) |env| {
            try env.put("HOME", w.path("{s}/home", .{w.root}));
            try env.put("PATH", w.path("{s}/bin", .{w.root}));
            try env.put("XDG_CONFIG_HOME", w.path("{s}/config", .{w.root}));
            try env.put("XDG_DATA_HOME", w.path("{s}/share", .{w.root}));
            try env.put("XDG_STATE_HOME", w.path("{s}/state", .{w.root}));
            try env.put("XDG_CACHE_HOME", w.path("{s}/cache", .{w.root}));
            try env.put("XDG_RUNTIME_DIR", w.path("{s}/run", .{w.root}));
            try env.put("TMPDIR", w.path("{s}/tmp", .{w.root}));
            try env.put("LANG", "C.UTF-8");
        }
        try w.daemon_env.put("VERDE_SESSION_DAEMON_CHAT_STUB", "1");

        w.watchdog = try std.Thread.spawn(.{}, watchdog, .{});
        try w.startDaemon();
        try w.seedWorkspace();
        try w.startGateway();
        w.proxy = try Proxy.start(w.web_port);
        return w;
    }

    fn spawnLogged(w: *World, argv: []const []const u8, env: *const std.process.Environ.Map, log_name: []const u8) !c.pid_t {
        const file = try std.Io.Dir.createFileAbsolute(w.io, w.path("{s}/{s}", .{ w.root, log_name }), .{});
        defer file.close(w.io);
        const child = try std.process.spawn(w.io, .{ .argv = argv, .environ_map = env, .stdin = .ignore, .stdout = .{ .file = file }, .stderr = .{ .file = file } });
        return child.id.?;
    }

    fn exited(pid: c.pid_t) bool {
        var status: c_int = 0;
        return c.waitpid(pid, &status, c.W.NOHANG) == pid;
    }

    fn startDaemon(w: *World) !void {
        w.daemon_pid = try w.spawnLogged(&.{ contract_options.daemon_exe, "serve", "--data-dir", w.data_dir }, &w.daemon_env, "daemon.log");
        child_pids[0].store(w.daemon_pid, .release);
        const deadline = monoMs() + 20_000;
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        while (true) {
            if (exited(w.daemon_pid)) {
                w.daemon_pid = 0;
                w.dumpLog("daemon.log");
                return error.DaemonExited;
            }
            if (daemonCall(scratch.allocator(), w.socket_path, "core.status", .{}, null)) |status| {
                w.runtime_id = try w.arena.allocator().dupe(u8, str(status, "runtime_id"));
                w.instance_id = try w.arena.allocator().dupe(u8, str(status, "instance_id"));
                return;
            } else |_| {}
            if (monoMs() > deadline) {
                w.dumpLog("daemon.log");
                return error.DaemonNotReady;
            }
            sleepMs(50);
        }
    }

    /// Owner-side seeding (the desktop's role): one workspace whose project
    /// directory lives in the temporary tree.
    fn seedWorkspace(w: *World) !void {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const target = try h.parse(a, try h.encode(a, .{ .runtime_id = w.runtime_id, .instance_id = w.instance_id }));
        const client_id = str(try daemonCall(a, w.socket_path, "daemon.client.register", .{ .persistent = false }, target), "client_id");
        _ = try daemonCall(a, w.socket_path, "state.snapshot.replace", .{
            .mutation = .{ .client_id = client_id, .request_key = "k14-seed" },
            .bootstrap = true,
            .snapshot = .{ .workspaces = .{.{ .workspace_id = workspace_id, .label = "Contract", .path = w.path("{s}/project", .{w.root}), .threads = @as([]const V, &.{}) }} },
        }, target);
    }

    fn startGateway(w: *World) !void {
        const token_path = w.path("{s}/web-token", .{w.root});
        {
            const file = try std.Io.Dir.createFileAbsolute(w.io, token_path, .{});
            defer file.close(w.io);
            var token = randomHex(w.io, 32);
            defer std.crypto.secureZero(u8, &token);
            try file.writeStreamingAll(w.io, &token);
        }
        const token_z = try gpa.dupeZ(u8, token_path);
        defer gpa.free(token_z);
        if (c.chmod(token_z, 0o600) != 0) return error.ChmodFailed;

        var attempt: usize = 0;
        while (attempt < 5) : (attempt += 1) {
            const port = try reservePort();
            var port_buf: [8]u8 = undefined;
            const port_text = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
            const log_name = w.path("web-{d}.log", .{attempt});
            const pid = try w.spawnLogged(&.{ contract_options.web_exe, "--host", "127.0.0.1", "--port", port_text, "--token-file", token_path, "--sessionizer", w.socket_path, "--pref-path", w.data_dir, "--static", w.path("{s}/static", .{w.root}), "--trusted-proxy-origin", public_origin }, &w.web_env, log_name);
            child_pids[1].store(pid, .release);
            const listening = w.path("verde-web listening on http://127.0.0.1:{d}/", .{port});
            const deadline = monoMs() + 20_000;
            const ready = while (monoMs() < deadline) {
                if (exited(pid)) break false;
                if (w.logContains(log_name, listening)) {
                    var scratch = std.heap.ArenaAllocator.init(gpa);
                    defer scratch.deinit();
                    const request = w.path("GET /healthz HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{port});
                    const result = httpExchange(scratch.allocator(), port, request, 5_000, 4096, null) catch break false;
                    break result == .response and result.response.status == 200;
                }
                sleepMs(25);
            } else false;
            if (ready) {
                w.web_pid = pid;
                w.web_port = port;
                return;
            }
            _ = stopChild(pid, "verde-web (retry)");
            child_pids[1].store(0, .release);
            std.debug.print("contract: verde-web attempt {d} on reserved port failed; retrying\n", .{attempt + 1});
            w.dumpLog(log_name);
        }
        return error.GatewayNotReady;
    }

    fn logContains(w: *World, name: []const u8, needle: []const u8) bool {
        const bytes = std.Io.Dir.cwd().readFileAlloc(w.io, w.path("{s}/{s}", .{ w.root, name }), gpa, .limited(4 * 1024 * 1024)) catch return false;
        defer gpa.free(bytes);
        return std.mem.indexOf(u8, bytes, needle) != null;
    }

    /// Product logs are part of the no-secrets contract, so their tails are
    /// safe diagnostics.
    fn dumpLog(w: *World, name: []const u8) void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(w.io, w.path("{s}/{s}", .{ w.root, name }), gpa, .limited(4 * 1024 * 1024)) catch return;
        defer gpa.free(bytes);
        const start_at = if (bytes.len > 4000) bytes.len - 4000 else 0;
        std.debug.print("---- {s} (tail) ----\n{s}\n---- end {s} ----\n", .{ name, bytes[start_at..], name });
    }

    /// The pairing code is read from the CLI's stdout pipe only; it is zeroed
    /// by the caller once the core has consumed the link.
    fn createPairLink(w: *World, a: A) ![]u8 {
        const result = try std.process.run(gpa, w.io, .{ .argv = &.{ contract_options.daemon_exe, "pair", "create", "--data-dir", w.data_dir, "--label", "K-14 contract", "--json" }, .environ_map = &w.daemon_env, .stdout_limit = .limited(64 * 1024), .stderr_limit = .limited(64 * 1024) });
        defer {
            std.crypto.secureZero(u8, result.stdout);
            gpa.free(result.stdout);
            gpa.free(result.stderr);
        }
        if (result.term != .exited or result.term.exited != 0) return error.PairCreateFailed;
        const parsed = try std.json.parseFromSlice(V, gpa, result.stdout, .{});
        defer parsed.deinit();
        const grant = get(parsed.value, "result");
        if (!std.mem.eql(u8, str(grant, "runtime_id"), w.runtime_id)) return error.PairGrantRuntimeMismatch;
        const token = str(grant, "pairing_token");
        const link = try std.fmt.allocPrint(a, "https://verdeai.dev/pair?host=https%3A%2F%2F" ++ public_authority ++ "&grant_id={s}#code={s}", .{ str(grant, "grant_id"), token });
        std.crypto.secureZero(u8, @constCast(token));
        return link;
    }

    fn deviceList(w: *World, a: A) !V {
        const result = try std.process.run(gpa, w.io, .{ .argv = &.{ contract_options.daemon_exe, "device", "list", "--data-dir", w.data_dir, "--json" }, .environ_map = &w.daemon_env, .stdout_limit = .limited(256 * 1024), .stderr_limit = .limited(64 * 1024) });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) return error.DeviceListFailed;
        return get(try h.parse(a, try a.dupe(u8, result.stdout)), "result");
    }

    /// Idempotent; returns an error only for non-graceful child exits.
    fn teardown(w: *World) !void {
        if (w.torn_down) return;
        w.torn_down = true;
        stop_flag.store(true, .release);
        joinAll();
        if (w.proxy) |proxy| {
            _ = c.close(proxy.listen_fd);
            gpa.destroy(proxy);
            w.proxy = null;
        }
        const web_ok = stopChild(w.web_pid, "verde-web");
        child_pids[1].store(0, .release);
        const daemon_ok = stopChild(w.daemon_pid, "verde-daemon");
        child_pids[0].store(0, .release);
        if (!web_ok) w.dumpLog("web-0.log");
        if (!daemon_ok) w.dumpLog("daemon.log");
        suite_done.store(true, .release);
        if (w.watchdog) |thread| thread.join();
        std.Io.Dir.cwd().deleteTree(w.io, w.root) catch |err| std.debug.print("contract: temp cleanup failed: {s}\n", .{@errorName(err)});
        w.daemon_env.deinit();
        w.web_env.deinit();
        w.arena.deinit();
        gpa.destroy(w);
        if (!web_ok or !daemon_ok) return error.NonGracefulExit;
    }
};

// ---------------------------------------------------------------------------
// Core adapter: owns the Host on the test thread and executes its effects.

const Timer = struct { id: []u8, generation: []u8, deadline: i64 };

const Core = struct {
    world: *World,
    host: h.Host,
    base_ms: i64,
    last_now: i64 = 0,
    scratch: std.heap.ArenaAllocator,
    timers: std.ArrayList(Timer) = .empty,
    store: std.StringHashMapUnmanaged([]u8) = .empty,
    http_jobs: std.ArrayList(*HttpJob) = .empty,
    sockets: std.ArrayList(*WsConn) = .empty,
    pin_violations: u32 = 0,
    http_requests: u32 = 0,
    ws_opens: u32 = 0,

    fn init(world: *World) !Core {
        const nonce = randomHex(world.io, 16);
        const config = try std.fmt.allocPrint(gpa, "{{\"api_version\":1,\"host_id\":\"contract\",\"label\":\"Contract\",\"https_url\":null,\"wss_url\":null,\"client_revision\":1,\"session_nonce\":\"{s}\",\"jitter_seed\":7}}", .{&nonce});
        defer gpa.free(config);
        return .{ .world = world, .host = try h.Host.init(std.testing.allocator, config), .base_ms = monoMs(), .scratch = .init(gpa) };
    }

    fn deinit(core: *Core) void {
        // Error paths reach here before World.teardown: stop and join every
        // worker before freeing the jobs they reference.
        stop_flag.store(true, .release);
        joinAll();
        core.host.deinit();
        core.scratch.deinit();
        for (core.timers.items) |t| {
            gpa.free(t.id);
            gpa.free(t.generation);
        }
        core.timers.deinit(gpa);
        var it = core.store.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            std.crypto.secureZero(u8, entry.value_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        core.store.deinit(gpa);
        // Worker threads are joined by World.teardown before this runs.
        for (core.http_jobs.items) |job| {
            gpa.free(job.effect_id);
            gpa.free(job.generation);
            gpa.free(job.request);
            gpa.destroy(job);
        }
        core.http_jobs.deinit(gpa);
        for (core.sockets.items) |conn| {
            gpa.free(conn.socket_id);
            gpa.free(conn.generation);
            gpa.free(conn.protocols);
            gpa.destroy(conn);
        }
        core.sockets.deinit(gpa);
        lock(&queue_lock);
        for (queue.items) |item| gpa.free(item.payload);
        queue.deinit(gpa);
        queue = .empty;
        queue_lock.unlock();
    }

    fn now(core: *Core) i64 {
        core.last_now = @max(core.last_now, monoMs() - core.base_ms + 1);
        return core.last_now;
    }

    /// Feed one event. `payload` is a JSON object without the envelope.
    fn feed(core: *Core, tag: []const u8, payload: []const u8) !void {
        const a = core.scratch.allocator();
        var value = try h.parse(a, payload);
        if (value == .array) value = .{ .object = .empty };
        try value.object.put(a, "api_version", .{ .integer = 1 });
        try value.object.put(a, "type", .{ .string = tag });
        try value.object.put(a, "now_ms", .{ .integer = core.now() });
        try value.object.put(a, "wall_time_ms", .{ .integer = wallMs() });
        const input = try h.encode(a, value);
        defer std.crypto.secureZero(u8, input);
        const batch = core.host.handle(input, a) catch |err| {
            std.debug.print("contract: core rejected {s} event: {s}\n", .{ tag, @errorName(err) });
            return err;
        };
        defer std.crypto.secureZero(u8, batch);
        try core.dispatch(batch);
    }

    fn intent(core: *Core, tag: []const u8, payload: anytype) !void {
        const a = core.scratch.allocator();
        try core.feed(tag, try h.encode(a, payload));
    }

    fn dispatch(core: *Core, batch: []const u8) !void {
        const a = core.scratch.allocator();
        const parsed = try h.parse(a, batch);
        for (items(get(parsed, "effects"))) |effect| {
            const kind = str(effect, "type");
            const effect_id = str(effect, "effect_id");
            const generation = str(effect, "generation");
            if (h.eq(kind, "http_request")) {
                try core.startHttp(effect);
            } else if (h.eq(kind, "http_cancel")) {
                const id = str(effect, "request_id");
                for (core.http_jobs.items) |job| if (h.eq(job.effect_id, id)) job.cancelled.store(true, .release);
            } else if (h.eq(kind, "ws_open")) {
                try core.startSocket(effect);
            } else if (h.eq(kind, "ws_send")) {
                for (core.sockets.items) |conn| if (h.eq(conn.socket_id, str(effect, "socket_id"))) conn.sendFrame(1, str(effect, "text"));
            } else if (h.eq(kind, "ws_close")) {
                for (core.sockets.items) |conn| if (h.eq(conn.socket_id, str(effect, "socket_id"))) {
                    conn.closed_by_core.store(true, .release);
                    var code: [2]u8 = undefined;
                    std.mem.writeInt(u16, &code, @intCast(get(effect, "code").integer), .big);
                    conn.sendFrame(8, &code);
                };
            } else if (h.eq(kind, "set_timer")) {
                const delay = get(effect, "delay_ms").integer;
                try core.timers.append(gpa, .{ .id = try gpa.dupe(u8, str(effect, "timer_id")), .generation = try gpa.dupe(u8, generation), .deadline = core.now() + delay });
            } else if (h.eq(kind, "cancel_timer")) {
                const id = str(effect, "timer_id");
                var i: usize = 0;
                while (i < core.timers.items.len) {
                    if (h.eq(core.timers.items[i].id, id)) {
                        const t = core.timers.orderedRemove(i);
                        gpa.free(t.id);
                        gpa.free(t.generation);
                    } else i += 1;
                }
            } else if (h.eq(kind, "secure_store_get")) {
                const key = str(effect, "key");
                push("secure_store_value", .{ .effect_id = effect_id, .generation = generation, .key = key, .value_base64 = core.store.get(key), .@"error" = @as(?Failure, null) });
            } else if (h.eq(kind, "secure_store_put")) {
                const key = str(effect, "key");
                const value = try gpa.dupe(u8, str(effect, "value_base64"));
                if (try core.store.fetchPut(gpa, key, value)) |old| {
                    std.crypto.secureZero(u8, old.value);
                    gpa.free(old.value);
                } else {
                    // Key ownership moves into the map on first insert.
                    const owned = try gpa.dupe(u8, key);
                    core.store.getKeyPtr(key).?.* = owned;
                }
                push("secure_store_done", .{ .effect_id = effect_id, .generation = generation, .key = key, .@"error" = @as(?Failure, null) });
            } else if (h.eq(kind, "secure_store_delete")) {
                const key = str(effect, "key");
                if (core.store.fetchRemove(key)) |old| {
                    gpa.free(old.key);
                    std.crypto.secureZero(u8, old.value);
                    gpa.free(old.value);
                }
                push("secure_store_done", .{ .effect_id = effect_id, .generation = generation, .key = key, .@"error" = @as(?Failure, null) });
            } else if (h.eq(kind, "tls_probe")) {
                // The proxy terminates TLS for the public origin; report its pin.
                if (!h.eq(str(effect, "origin"), public_origin)) return error.UnexpectedTlsOrigin;
                push("tls_peer", .{ .effect_id = effect_id, .generation = generation, .origin = public_origin, .spki_sha256 = fake_pin, .system_trusted = true });
            } else if (h.eq(kind, "terminal_output")) {
                return error.UnexpectedTerminalOutput;
            } else if (h.eq(kind, "state_changed") or h.eq(kind, "log") or h.eq(kind, "notify")) {} else {
                std.debug.print("contract: unknown effect {s}\n", .{kind});
                return error.UnknownEffect;
            }
        }
    }

    fn checkTls(core: *Core, effect: V) bool {
        const tls = get(effect, "tls");
        const ok = h.eq(str(tls, "origin"), public_origin) and h.eq(str(tls, "spki_sha256"), fake_pin);
        if (!ok) core.pin_violations += 1;
        return ok;
    }

    fn startHttp(core: *Core, effect: V) !void {
        const url = str(effect, "url");
        if (!core.checkTls(effect) or !std.mem.startsWith(u8, url, public_origin ++ "/")) return error.UnpinnedRequest;
        const a = core.scratch.allocator();
        var request: std.ArrayList(u8) = .empty;
        try request.print(a, "{s} {s} HTTP/1.1\r\nHost: " ++ public_authority ++ "\r\nConnection: close\r\n", .{ str(effect, "method"), url[public_origin.len..] });
        for (items(get(effect, "headers"))) |header| {
            const name = str(header, "name");
            const value = str(header, "value");
            if (std.mem.indexOfAny(u8, name, "\r\n:") != null or std.mem.indexOfAny(u8, value, "\r\n") != null) return error.HeaderInjection;
            try request.print(a, "{s}: {s}\r\n", .{ name, value });
        }
        var body: []u8 = &.{};
        if (get(effect, "body_base64") == .string) {
            const encoded = str(effect, "body_base64");
            body = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
            try std.base64.standard.Decoder.decode(body, encoded);
            try request.print(a, "Content-Length: {d}\r\n", .{body.len});
        }
        try request.appendSlice(a, "\r\n");
        try request.appendSlice(a, body);
        std.crypto.secureZero(u8, body);
        const job = try gpa.create(HttpJob);
        job.* = .{
            .effect_id = try gpa.dupe(u8, str(effect, "effect_id")),
            .generation = try gpa.dupe(u8, str(effect, "generation")),
            .request = try gpa.dupe(u8, request.items),
            .port = core.world.proxy.?.port,
            .timeout_ms = @intCast(get(effect, "timeout_ms").integer),
            .max_bytes = @intCast(get(effect, "max_response_bytes").integer),
        };
        std.crypto.secureZero(u8, request.items);
        try core.http_jobs.append(gpa, job);
        core.http_requests += 1;
        try spawnTracked(httpThread, .{job});
    }

    fn startSocket(core: *Core, effect: V) !void {
        if (!core.checkTls(effect) or !h.eq(str(effect, "url"), public_wss)) return error.UnpinnedSocket;
        const a = core.scratch.allocator();
        var protocols: std.ArrayList(u8) = .empty;
        for (items(get(effect, "protocols")), 0..) |p, i| {
            if (i > 0) try protocols.appendSlice(a, ", ");
            try protocols.appendSlice(a, p.string);
        }
        const conn = try gpa.create(WsConn);
        conn.* = .{
            .socket_id = try gpa.dupe(u8, str(effect, "effect_id")),
            .generation = try gpa.dupe(u8, str(effect, "generation")),
            .protocols = try gpa.dupe(u8, protocols.items),
            .port = core.world.proxy.?.port,
            .max_bytes = @intCast(get(effect, "max_message_bytes").integer),
            .prng = .init(@bitCast(monoMs())),
        };
        std.crypto.secureZero(u8, protocols.items);
        try core.sockets.append(gpa, conn);
        core.ws_opens += 1;
        try spawnTracked(wsThread, .{conn});
    }

    /// Deliver queued completions and due timers.
    fn pump(core: *Core) !void {
        _ = core.scratch.reset(.retain_capacity);
        lock(&queue_lock);
        const batch = queue.toOwnedSlice(gpa) catch @panic("contract: out of memory");
        queue_lock.unlock();
        defer gpa.free(batch);
        var failed: ?anyerror = null;
        for (batch) |item| {
            if (failed == null) core.feed(item.tag, item.payload) catch |err| {
                failed = err;
            };
            std.crypto.secureZero(u8, item.payload);
            gpa.free(item.payload);
        }
        if (failed) |err| return err;
        const t = core.now();
        var i: usize = 0;
        while (i < core.timers.items.len) {
            if (core.timers.items[i].deadline <= t) {
                const timer = core.timers.orderedRemove(i);
                defer gpa.free(timer.id);
                defer gpa.free(timer.generation);
                try core.intent("timer_fired", .{ .timer_id = timer.id, .generation = timer.generation });
            } else i += 1;
        }
    }

    fn waitFor(core: *Core, what: []const u8, timeout_ms: i64, ctx: anytype, comptime pred: fn (*Core, @TypeOf(ctx)) anyerror!bool) !void {
        const deadline = monoMs() + timeout_ms;
        while (true) {
            try core.pump();
            if (try pred(core, ctx)) return;
            if (monoMs() > deadline) {
                std.debug.print("contract: timed out after {d} ms waiting for {s}\n", .{ timeout_ms, what });
                core.diagnose();
                return error.ContractTimeout;
            }
            sleepMs(5);
        }
    }

    fn query(core: *Core, selector: []const u8) !V {
        const a = core.scratch.allocator();
        const bytes = try core.host.query(selector, a);
        return get(try h.parse(a, bytes), "data");
    }

    fn hostView(core: *Core) !wire.HostView {
        const a = core.scratch.allocator();
        const bytes = try core.host.query("hosts", a);
        const typed = try std.json.parseFromSliceLeaky(wire.Query(wire.HostsView), a, bytes, .{});
        return typed.data.?.items[0];
    }

    fn operationState(core: *Core, intent_id: []const u8) []const u8 {
        for (core.host.state.receipts) |r| if (h.eq(r.operation.intent_id, intent_id)) return r.operation.state;
        return "";
    }

    fn requireNotFailed(core: *Core, intent_id: []const u8) !void {
        const state = core.operationState(intent_id);
        if (h.eq(state, "failed") or h.eq(state, "uncertain")) {
            std.debug.print("contract: intent {s} ended {s}\n", .{ intent_id, state });
            core.diagnose();
            return error.IntentFailed;
        }
    }

    /// Non-secret state only.
    fn diagnose(core: *Core) void {
        const view = core.hostView() catch return;
        std.debug.print("contract: host auth_state={s} phase={s} sync_state={s} error={s} http_requests={d} ws_opens={d}\n", .{ view.auth_state, view.phase, view.sync_state, if (view.@"error") |e| e.code else "none", core.http_requests, core.ws_opens });
        const thread_view = core.query(h.chat.selectorFor(core.scratch.allocator(), "thread", workspace_id, thread_id) catch return) catch return;
        if (thread_view == .null) return;
        const turn = get(thread_view, "turn");
        std.debug.print("contract: thread turn_status={s} rows={d} approval={s} error={s}\n", .{ str(turn, "status"), items(get(thread_view, "rows")).len, str(get(thread_view, "approval"), "call_id"), str(get(thread_view, "error"), "code") });
        for (items(get(thread_view, "rows"))) |row| std.debug.print("contract:   row role={s} delivery={s} body_len={d}\n", .{ str(row, "role"), str(row, "delivery"), str(row, "body").len });
    }

    /// Issue a request through the core's own authenticated RPC path (the
    /// same transport, bearer, target and retry policy chat/sync use).
    fn rpcCall(core: *Core, method: []const u8, params: anytype, mutation: bool) !V {
        var tx = try h.Transaction.init(&core.host);
        defer tx.deinit();
        const id = try h.rpc.request(&tx, method, params, .{ .mutation = mutation });
        const batch = try tx.commit(&core.host, core.scratch.allocator());
        try core.dispatch(batch);
        const Ctx = struct { id: u64 };
        try core.waitFor(method, step_timeout_ms, Ctx{ .id = id }, struct {
            fn pred(k: *Core, ctx: Ctx) !bool {
                for (k.host.state.rpc.results) |r| if (r.id == ctx.id) return true;
                return false;
            }
        }.pred);
        for (core.host.state.rpc.results) |r| if (r.id == id) {
            if (r.@"error") |e| {
                std.debug.print("contract: {s} failed: {s} rpc_code={s}\n", .{ method, e.code, e.rpc_code orelse "none" });
                return error.RpcFailed;
            }
            const a = core.scratch.allocator();
            // Copy out of host state; the next event replaces its arena.
            return h.parse(a, try h.encode(a, r.value orelse .null));
        };
        unreachable;
    }

    fn containsSecret(core: *Core, secret: []const u8) !bool {
        const a = core.scratch.allocator();
        for ([_][]const u8{ "hosts", "home", "workspaces", try h.chat.selectorFor(a, "thread", workspace_id, thread_id), try h.chat.selectorFor(a, "composer", workspace_id, thread_id) }) |selector| {
            if (std.mem.indexOf(u8, try core.host.query(selector, a), secret) != null) return true;
        }
        var it = core.store.iterator();
        while (it.next()) |entry| {
            const decoded = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(entry.value_ptr.*));
            try std.base64.standard.Decoder.decode(decoded, entry.value_ptr.*);
            if (std.mem.indexOf(u8, decoded, secret) != null) return true;
        }
        return false;
    }
};

fn threadVisible(core: *Core, _: void) !bool {
    for (items(get(try core.query("workspaces"), "items"))) |ws| {
        if (!h.eq(str(ws, "workspace_id"), workspace_id)) continue;
        for (items(get(ws, "threads"))) |t| if (h.eq(str(t, "thread_id"), thread_id)) return true;
    }
    return false;
}

fn threadSelector(core: *Core) ![]const u8 {
    return h.chat.selectorFor(core.scratch.allocator(), "thread", workspace_id, thread_id);
}
fn composerSelector(core: *Core) ![]const u8 {
    return h.chat.selectorFor(core.scratch.allocator(), "composer", workspace_id, thread_id);
}

/// `delivery == null` accepts any delivery state.
fn hasRow(view: V, role: []const u8, body: []const u8, delivery: ?[]const u8) bool {
    for (items(get(view, "rows"))) |row| {
        if (h.eq(str(row, "role"), role) and std.mem.indexOf(u8, str(row, "body"), body) != null and (delivery == null or h.eq(str(row, "delivery"), delivery.?))) return true;
    }
    return false;
}

test "K-14 contract: real core pairs, syncs, runs an approval turn, and signs out (self-revoke) via a temporary daemon and verde-web" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    stop_flag.store(false, .release);
    suite_done.store(false, .release);

    const world = try World.start(io);
    var world_live = true;
    defer if (world_live) world.teardown() catch {};
    var core = try Core.init(world);
    defer core.deinit();

    // Cold start: empty secure store means unpaired.
    try core.intent("start", .{ .foreground = true, .network_available = true });
    try core.waitFor("unpaired", 5_000, {}, struct {
        fn pred(k: *Core, _: void) !bool {
            return h.eq((try k.hostView()).auth_state, "unpaired");
        }
    }.pred);

    // Pair: tls_probe -> pinned discovery -> trust proposal.
    {
        const link = try world.createPairLink(gpa);
        defer {
            std.crypto.secureZero(u8, link);
            gpa.free(link);
        }
        const code = link[std.mem.indexOf(u8, link, "#code=").? + 6 ..];
        const code_copy = try gpa.dupe(u8, code);
        defer {
            std.crypto.secureZero(u8, code_copy);
            gpa.free(code_copy);
        }
        try core.intent("pair", .{ .intent_id = "k14-pair", .link = link, .device_label = "K-14 contract", .client_nonce = &randomHex(io, 16) });
        try core.waitFor("trust proposal", step_timeout_ms, {}, struct {
            fn pred(k: *Core, _: void) !bool {
                try k.requireNotFailed("k14-pair");
                return (try k.hostView()).trust_proposal != null;
            }
        }.pred);
        const proposal = (try core.hostView()).trust_proposal.?;
        try std.testing.expectEqualStrings(public_origin, proposal.origin);
        try std.testing.expectEqualStrings(fake_pin, proposal.spki_sha256);
        try std.testing.expectEqualStrings(world.runtime_id, proposal.runtime_id orelse "");
        try core.intent("trust_decision", .{ .intent_id = "k14-trust", .proposal_id = try core.scratch.allocator().dupe(u8, proposal.id), .accept = true });

        // Exchange -> credential -> access token -> ticket -> WS -> status,
        // capabilities, snapshot, catalog.
        try core.waitFor("paired, ready and synced", step_timeout_ms, {}, struct {
            fn pred(k: *Core, _: void) !bool {
                try k.requireNotFailed("k14-pair");
                const view = try k.hostView();
                if (view.@"error") |e| if (!e.retryable) {
                    std.debug.print("contract: host error {s}\n", .{e.code});
                    return error.HostError;
                };
                if (!h.eq(view.auth_state, "paired") or !h.eq(view.phase, "ready") or !h.eq(view.sync_state, "ready")) return false;
                for (items(get(try k.query("workspaces"), "items"))) |ws| if (h.eq(str(ws, "workspace_id"), workspace_id)) return true;
                return false;
            }
        }.pred);
        try std.testing.expect(!try core.containsSecret(code_copy));
    }
    const paired = try core.hostView();
    try std.testing.expectEqualStrings(world.runtime_id, paired.runtime_id orelse "");
    try std.testing.expect(core.ws_opens >= 1);
    try std.testing.expect(world.proxy.?.connections.load(.monotonic) >= 5);

    // Create the thread through the core's authenticated RPC path (the core
    // has no create-thread intent yet), then wait for the sync pipeline
    // (WS change notification, snapshot/catalog refresh) to project it.
    {
        const registered = try core.rpcCall("daemon.client.register", .{ .persistent = false }, true);
        const client_id = try gpa.dupe(u8, str(registered, "client_id"));
        defer gpa.free(client_id);
        try std.testing.expect(client_id.len > 0);
        _ = try core.rpcCall("chat.thread.upsert", .{
            .workspace_id = workspace_id,
            .thread = .{ .local_thread_id = thread_id, .title = "K-14 contract", .provider = "codex" },
            .mutation = .{ .client_id = client_id, .request_key = "k14-thread" },
        }, true);
        try core.waitFor("created thread in the workspaces projection", step_timeout_ms, {}, threadVisible);
    }

    // Open, draft, send.
    try core.intent("thread_open", .{ .intent_id = "k14-open", .workspace_id = workspace_id, .thread_id = thread_id });
    try core.waitFor("composer ready", step_timeout_ms, {}, struct {
        fn pred(k: *Core, _: void) !bool {
            try k.requireNotFailed("k14-open");
            const view = try k.query(try composerSelector(k));
            return get(view, "can_send") == .bool and get(view, "can_send").bool;
        }
    }.pred);
    try core.intent("draft_set", .{ .intent_id = "k14-draft", .workspace_id = workspace_id, .thread_id = thread_id, .text = approval_prompt, .attachments = @as([]const V, &.{}) });
    try core.waitFor("draft saved", step_timeout_ms, {}, struct {
        fn pred(k: *Core, _: void) !bool {
            try k.requireNotFailed("k14-draft");
            return h.eq(str(get(try k.query(try composerSelector(k)), "draft"), "text"), approval_prompt);
        }
    }.pred);
    const revision = try gpa.dupe(u8, str(get(try core.query(try composerSelector(&core)), "draft"), "revision"));
    defer gpa.free(revision);
    try core.intent("send", .{ .intent_id = "k14-send", .workspace_id = workspace_id, .thread_id = thread_id, .draft_revision = revision });

    // Tail until the stub parks on its approval request.
    try core.waitFor("approval request", step_timeout_ms, {}, struct {
        fn pred(k: *Core, _: void) !bool {
            try k.requireNotFailed("k14-send");
            const approval = get(try k.query(try threadSelector(k)), "approval");
            return h.eq(str(approval, "call_id"), "orch-approval");
        }
    }.pred);
    const approval = get(try core.query(try threadSelector(&core)), "approval");
    try std.testing.expectEqualStrings("Approval needed", str(approval, "title"));
    try std.testing.expectEqualStrings("Allow the isolated test operation?", str(approval, "body"));
    try std.testing.expectEqualStrings("idle", str(approval, "resolution"));
    const turn_id = try gpa.dupe(u8, str(approval, "turn_id"));
    defer gpa.free(turn_id);
    try std.testing.expect(hasRow(try core.query(try threadSelector(&core)), "user", approval_prompt, null));

    // Approve; the turn completes and the durable transcript reconciles.
    try core.intent("approval_decide", .{ .intent_id = "k14-approve", .workspace_id = workspace_id, .thread_id = thread_id, .turn_id = turn_id, .call_id = "orch-approval", .decision = "approve" });
    try core.waitFor("completed turn with committed transcript", step_timeout_ms, {}, struct {
        fn pred(k: *Core, _: void) !bool {
            try k.requireNotFailed("k14-approve");
            try k.requireNotFailed("k14-send");
            const view = try k.query(try threadSelector(k));
            if (!h.eq(str(get(view, "turn"), "status"), "completed")) return false;
            return hasRow(view, "user", approval_prompt, "committed") and hasRow(view, "assistant", "stub-ok", "committed");
        }
    }.pred);
    try std.testing.expectEqualStrings("succeeded", core.operationState("k14-send"));
    try std.testing.expectEqualStrings("succeeded", core.operationState("k14-approve"));
    try std.testing.expect(get(try core.query(try threadSelector(&core)), "approval") == .null);

    // D-04 sign_out: the core revokes this device with targeted
    // device.self.revoke over its authenticated RPC, then wipes the
    // credential and pin with acknowledged secure-store deletes.
    try core.intent("sign_out", .{ .intent_id = "k14-sign-out", .host_id = "contract" });
    try core.waitFor("signed_out after revoke", step_timeout_ms, {}, struct {
        fn pred(k: *Core, _: void) !bool {
            try k.requireNotFailed("k14-sign-out");
            return h.eq((try k.hostView()).auth_state, "signed_out") and h.eq(k.operationState("k14-sign-out"), "succeeded");
        }
    }.pred);
    try std.testing.expect(core.store.get("vc/1/contract/credential") == null);
    try std.testing.expect(core.store.get("vc/1/contract/profile") == null);
    {
        const devices = items(get(try world.deviceList(core.scratch.allocator()), "devices"));
        try std.testing.expectEqual(@as(usize, 1), devices.len);
        try std.testing.expect(get(devices[0], "revoked_at_ms") == .integer);
    }
    try std.testing.expectEqual(@as(u32, 0), core.pin_violations);

    // Deterministic teardown: core first (closes its transports), then the
    // world, which must observe graceful child exits.
    try core.intent("shutdown", .{});
    world_live = false;
    try world.teardown();
}
