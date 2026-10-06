//! Discovers HTTP servers listening on loopback so the browser's empty
//! new-tab page can offer them as one-click destinations.
//!
//! Scans run on a short-lived worker thread (never the UI thread) and only
//! while the empty state is on screen. Linux reads `/proc/net/tcp{,6}` for the
//! current user's listening sockets, maps socket inodes to processes through
//! `/proc/<pid>/fd`, and confirms each new port answers HTTP once; other
//! platforms report no servers.

const std = @import("std");
const builtin = @import("builtin");

pub const MAX_SERVERS: usize = 8;
const MAX_CANDIDATES: usize = 32;
const NAME_CAPACITY: usize = 64;
const RESCAN_INTERVAL_MS: i64 = 3_000;
/// Keeps a just-hidden empty state warm across brief tab flips.
const VISIBLE_GRACE_MS: i64 = 1_500;
const PROBE_TIMEOUT_US: i64 = 400_000;

pub const Server = struct {
    port: u16 = 0,
    name_buf: [NAME_CAPACITY]u8 = undefined,
    name_len: u8 = 0,

    pub fn name(self: *const Server) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn setName(self: *Server, value: []const u8) void {
        const len = @min(value.len, NAME_CAPACITY);
        @memcpy(self.name_buf[0..len], value[0..len]);
        self.name_len = @intCast(len);
    }

    fn eql(a: *const Server, b: *const Server) bool {
        return a.port == b.port and std.mem.eql(u8, a.name(), b.name());
    }
};

const Family = enum { v4, v6 };

const Candidate = struct {
    port: u16,
    inode: u64,
    family: Family,
};

/// Probe verdicts are cached per socket inode so a running server is
/// requested once, not on every rescan.
const ProbeEntry = struct {
    inode: u64,
    is_http: bool,
};

pub const Scanner = struct {
    servers: [MAX_SERVERS]Server = undefined,
    server_count: usize = 0,
    visible_until_ms: i64 = 0,
    next_scan_ms: i64 = 0,
    worker: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    /// Owned by the worker while `worker != null`; read by the UI thread only
    /// after joining.
    scratch: [MAX_SERVERS]Server = undefined,
    scratch_count: usize = 0,
    probe_cache: [MAX_CANDIDATES]ProbeEntry = undefined,
    probe_cache_count: usize = 0,

    pub fn deinit(self: *Scanner) void {
        if (self.worker) |worker| worker.join();
        self.worker = null;
    }

    pub fn list(self: *const Scanner) []const Server {
        return self.servers[0..self.server_count];
    }

    /// Joins a finished scan and starts the next one when due while the empty
    /// browser state is visible. Returns true when the published list changed
    /// and the UI should repaint.
    pub fn poll(self: *Scanner, now_ms: i64, empty_state_visible: bool) bool {
        if (empty_state_visible) self.visible_until_ms = now_ms + VISIBLE_GRACE_MS;
        var changed = false;
        if (self.worker) |worker| {
            if (!self.done.load(.acquire)) return false;
            worker.join();
            self.worker = null;
            changed = self.publishScratch();
        }
        if (builtin.os.tag != .linux) return changed;
        if (now_ms > self.visible_until_ms or now_ms < self.next_scan_ms) return changed;
        self.next_scan_ms = now_ms + RESCAN_INTERVAL_MS;
        self.done.store(false, .release);
        self.worker = std.Thread.spawn(.{}, workerMain, .{self}) catch null;
        return changed;
    }

    fn publishScratch(self: *Scanner) bool {
        var same = self.scratch_count == self.server_count;
        if (same) {
            for (self.scratch[0..self.scratch_count], self.servers[0..self.server_count]) |*a, *b| {
                if (!a.eql(b)) {
                    same = false;
                    break;
                }
            }
        }
        if (same) return false;
        @memcpy(self.servers[0..self.scratch_count], self.scratch[0..self.scratch_count]);
        self.server_count = self.scratch_count;
        return true;
    }

    fn workerMain(self: *Scanner) void {
        defer self.done.store(true, .release);
        self.scratch_count = 0;
        if (comptime builtin.os.tag != .linux) return;
        scanLinux(self);
    }
};

fn scanLinux(self: *Scanner) void {
    var candidates: [MAX_CANDIDATES]Candidate = undefined;
    var count: usize = 0;
    const uid = std.c.getuid();
    count = collectListeners("/proc/net/tcp", .v4, uid, &candidates, count);
    count = collectListeners("/proc/net/tcp6", .v6, uid, &candidates, count);
    if (count == 0) {
        self.probe_cache_count = 0;
        return;
    }

    var pids: [MAX_CANDIDATES]i32 = @splat(0);
    resolveSocketOwners(candidates[0..count], &pids);

    var next_cache: [MAX_CANDIDATES]ProbeEntry = undefined;
    var next_cache_count: usize = 0;
    const own_pid = std.c.getpid();

    for (candidates[0..count], pids[0..count]) |candidate, pid| {
        if (pid == own_pid) continue;
        const is_http = cachedProbe(self, candidate.inode) orelse probeHttp(candidate.port, candidate.family);
        next_cache[next_cache_count] = .{ .inode = candidate.inode, .is_http = is_http };
        next_cache_count += 1;
        if (!is_http or self.scratch_count >= MAX_SERVERS) continue;

        var server: Server = .{ .port = candidate.port };
        var name_buffer: [256]u8 = undefined;
        server.setName(if (pid > 0) processLabel(pid, &name_buffer) else "Local server");
        self.scratch[self.scratch_count] = server;
        self.scratch_count += 1;
    }
    @memcpy(self.probe_cache[0..next_cache_count], next_cache[0..next_cache_count]);
    self.probe_cache_count = next_cache_count;
    std.mem.sort(Server, self.scratch[0..self.scratch_count], {}, struct {
        fn lessThan(_: void, a: Server, b: Server) bool {
            return a.port < b.port;
        }
    }.lessThan);
}

fn cachedProbe(self: *const Scanner, inode: u64) ?bool {
    for (self.probe_cache[0..self.probe_cache_count]) |entry| {
        if (entry.inode == inode) return entry.is_http;
    }
    return null;
}

fn collectListeners(
    path: [*:0]const u8,
    family: Family,
    uid: std.c.uid_t,
    out: *[MAX_CANDIDATES]Candidate,
    start_count: usize,
) usize {
    var count = start_count;
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return count;
    defer _ = std.c.close(fd);

    var buffer: [64 * 1024]u8 = undefined;
    var len: usize = 0;
    while (len < buffer.len) {
        const read_raw = std.c.read(fd, buffer[len..].ptr, buffer.len - len);
        if (read_raw <= 0) break;
        len += @intCast(read_raw);
    }

    var lines = std.mem.splitScalar(u8, buffer[0..len], '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        const entry = parseListenerLine(line, family, uid) orelse continue;
        if (!isLikelyWebPort(entry.port)) continue;
        var duplicate = false;
        for (out[0..count]) |existing| {
            if (existing.port == entry.port) duplicate = true;
        }
        if (duplicate) continue;
        if (count >= out.len) break;
        out[count] = entry;
        count += 1;
    }
    return count;
}

/// Parses one `/proc/net/tcp{,6}` row, returning loopback/wildcard LISTEN
/// sockets owned by `uid`.
fn parseListenerLine(line: []const u8, family: Family, uid: std.c.uid_t) ?Candidate {
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    _ = fields.next() orelse return null; // sl
    const local = fields.next() orelse return null;
    _ = fields.next() orelse return null; // rem_address
    const state = fields.next() orelse return null;
    if (!std.mem.eql(u8, state, "0A")) return null; // TCP_LISTEN
    _ = fields.next() orelse return null; // tx_queue:rx_queue
    _ = fields.next() orelse return null; // tr:tm->when
    _ = fields.next() orelse return null; // retrnsmt
    const uid_text = fields.next() orelse return null;
    _ = fields.next() orelse return null; // timeout
    const inode_text = fields.next() orelse return null;

    const owner = std.fmt.parseInt(std.c.uid_t, uid_text, 10) catch return null;
    if (owner != uid) return null;
    const colon = std.mem.indexOfScalar(u8, local, ':') orelse return null;
    const address = local[0..colon];
    if (!isLocalListenAddress(address, family)) return null;
    const port = std.fmt.parseInt(u16, local[colon + 1 ..], 16) catch return null;
    const inode = std.fmt.parseInt(u64, inode_text, 10) catch return null;
    if (inode == 0) return null;
    return .{ .port = port, .inode = inode, .family = family };
}

/// Accepts addresses reachable as `localhost`: loopback and wildcard binds.
/// `/proc` prints each 32-bit word in host byte order.
fn isLocalListenAddress(hex: []const u8, family: Family) bool {
    return switch (family) {
        .v4 => std.mem.eql(u8, hex, "0100007F") or std.mem.eql(u8, hex, "00000000"),
        .v6 => std.mem.eql(u8, hex, "00000000000000000000000000000000") or
            std.mem.eql(u8, hex, "00000000000000000000000001000000") or
            std.mem.eql(u8, hex, "0000000000000000FFFF00000100007F"),
    };
}

/// Skips privileged ports and well-known non-HTTP services before probing.
fn isLikelyWebPort(port: u16) bool {
    if (port < 1024) return false;
    return switch (port) {
        1433, 3306, 5037, 5432, 5672, 6379, 9042, 9229, 11211, 15672, 27017 => false,
        else => true,
    };
}

/// Maps each candidate's socket inode to its owning pid (0 when unknown).
fn resolveSocketOwners(candidates: []const Candidate, pids: *[MAX_CANDIDATES]i32) void {
    const proc = std.c.opendir("/proc") orelse return;
    defer _ = std.c.closedir(proc);
    var remaining = candidates.len;
    while (remaining > 0) {
        const entry = std.c.readdir(proc) orelse break;
        const pid_name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
        const pid = std.fmt.parseInt(i32, pid_name, 10) catch continue;

        var fd_dir_path: [64]u8 = undefined;
        const fd_dir = std.fmt.bufPrintZ(&fd_dir_path, "/proc/{d}/fd", .{pid}) catch continue;
        // Other users' processes fail here; that is the expected filter.
        const dir = std.c.opendir(fd_dir.ptr) orelse continue;
        defer _ = std.c.closedir(dir);
        while (std.c.readdir(dir)) |fd_entry| {
            const fd_name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&fd_entry.name)), 0);
            if (fd_name.len == 0 or fd_name[0] == '.') continue;
            var link_path: [96]u8 = undefined;
            const link = std.fmt.bufPrintZ(&link_path, "/proc/{d}/fd/{s}", .{ pid, fd_name }) catch continue;
            var target: [64]u8 = undefined;
            const target_len = std.c.readlink(link.ptr, &target, target.len);
            if (target_len <= 0) continue;
            const inode = socketInode(target[0..@intCast(target_len)]) orelse continue;
            for (candidates, 0..) |candidate, index| {
                if (candidate.inode == inode and pids[index] == 0) {
                    pids[index] = pid;
                    remaining -= 1;
                }
            }
        }
    }
}

fn socketInode(target: []const u8) ?u64 {
    const prefix = "socket:[";
    if (!std.mem.startsWith(u8, target, prefix) or !std.mem.endsWith(u8, target, "]")) return null;
    return std.fmt.parseInt(u64, target[prefix.len .. target.len - 1], 10) catch null;
}

/// Names a server by its process name, or by its working directory (usually
/// the project) when the process is a generic language runtime.
fn processLabel(pid: i32, buffer: *[256]u8) []const u8 {
    var path_buffer: [64]u8 = undefined;
    var comm: []const u8 = "";
    if (std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/comm", .{pid})) |comm_path| {
        const fd = std.c.open(comm_path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (fd >= 0) {
            defer _ = std.c.close(fd);
            const len = std.c.read(fd, buffer[0..32].ptr, 32);
            if (len > 0) comm = std.mem.trim(u8, buffer[0..@intCast(len)], &std.ascii.whitespace);
        }
    } else |_| {}
    if (comm.len > 0 and !isGenericRuntime(comm)) return comm;

    // The cwd lands after the comm bytes so a fallback to `comm` stays intact.
    const cwd_buffer = buffer[32..];
    if (std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/cwd", .{pid})) |cwd_path| {
        const len = std.c.readlink(cwd_path.ptr, cwd_buffer.ptr, cwd_buffer.len);
        if (len > 0) {
            if (cwdLabel(cwd_buffer[0..@intCast(len)], homeDir())) |label| return label;
        }
    } else |_| {}
    return if (comm.len > 0) comm else "Local server";
}

fn isGenericRuntime(comm: []const u8) bool {
    const runtimes = [_][]const u8{
        "node", "bun",  "deno",   "python",   "python3", "ruby", "java", "php",  "perl",
        "sh",   "bash", "dotnet", "beam.smp", "npm",     "npx",  "pnpm", "yarn", "uv",
    };
    for (runtimes) |runtime| {
        if (std.mem.eql(u8, comm, runtime)) return true;
    }
    // Versioned interpreters such as `python3.12` or `node-22`.
    return std.mem.startsWith(u8, comm, "python") or std.mem.startsWith(u8, comm, "node");
}

fn homeDir() []const u8 {
    const raw = std.c.getenv("HOME") orelse return "";
    return std.mem.sliceTo(raw, 0);
}

fn cwdLabel(cwd: []const u8, home: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, cwd, "/");
    if (trimmed.len == 0) return null;
    if (home.len > 0 and std.mem.eql(u8, trimmed, std.mem.trimEnd(u8, home, "/"))) return null;
    if (std.mem.endsWith(u8, trimmed, " (deleted)")) return null;
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    const base = trimmed[slash + 1 ..];
    return if (base.len == 0) null else base;
}

/// Sends a minimal HEAD request and accepts any `HTTP/` status line except
/// 404/405: APIs and agent endpoints (Verde's own daemon included) answer
/// those at `/`, while browsable apps serve a page or redirect.
fn probeHttp(port: u16, family: Family) bool {
    const domain: c_uint = switch (family) {
        .v4 => std.c.AF.INET,
        .v6 => std.c.AF.INET6,
    };
    const fd = std.c.socket(domain, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC, 0);
    if (fd < 0) return false;
    defer _ = std.c.close(fd);

    const timeout: std.c.timeval = .{ .sec = 0, .usec = PROBE_TIMEOUT_US };
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, &timeout, @sizeOf(std.c.timeval));
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.SNDTIMEO, &timeout, @sizeOf(std.c.timeval));

    const connected = switch (family) {
        .v4 => blk: {
            const addr: std.c.sockaddr.in = .{
                .port = std.mem.nativeToBig(u16, port),
                .addr = std.mem.nativeToBig(u32, 0x7F000001),
            };
            break :blk std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in));
        },
        .v6 => blk: {
            var loopback: [16]u8 = @splat(0);
            loopback[15] = 1;
            const addr: std.c.sockaddr.in6 = .{
                .port = std.mem.nativeToBig(u16, port),
                .flowinfo = 0,
                .addr = loopback,
                .scope_id = 0,
            };
            break :blk std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in6));
        },
    };
    if (connected != 0) return false;

    const request = "HEAD / HTTP/1.0\r\nHost: localhost\r\nUser-Agent: Verde\r\n\r\n";
    if (std.c.send(fd, request, request.len, 0) != request.len) return false;
    var response: [16]u8 = undefined;
    var received: usize = 0;
    while (received < 12) {
        const n = std.c.recv(fd, response[received..].ptr, response.len - received, 0);
        if (n <= 0) break;
        received += @intCast(n);
    }
    return isBrowsableStatusLine(response[0..received]);
}

fn isBrowsableStatusLine(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "HTTP/")) return false;
    const space = std.mem.indexOfScalar(u8, line, ' ') orelse return false;
    if (line.len < space + 4) return false;
    const status = line[space + 1 .. space + 4];
    return !std.mem.eql(u8, status, "404") and !std.mem.eql(u8, status, "405");
}

test "proc net tcp rows keep only local listeners owned by the user" {
    const listen_v4 = "   0: 0100007F:0EBD 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 41234 1 0000000000000000 100 0 0 10 0";
    const parsed = parseListenerLine(listen_v4, .v4, 1000).?;
    try std.testing.expectEqual(@as(u16, 3773), parsed.port);
    try std.testing.expectEqual(@as(u64, 41234), parsed.inode);
    try std.testing.expect(parseListenerLine(listen_v4, .v4, 1001) == null);

    const established = "   1: 0100007F:0EBD 0100007F:A1B2 01 00000000:00000000 00:00000000 00000000  1000        0 41235 1 0000000000000000 100 0 0 10 0";
    try std.testing.expect(parseListenerLine(established, .v4, 1000) == null);

    const lan = "   2: 0A00A8C0:1A7F 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 41236 1 0000000000000000 100 0 0 10 0";
    try std.testing.expect(parseListenerLine(lan, .v4, 1000) == null);

    const loopback_v6 = "   0: 00000000000000000000000001000000:1A7F 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 51234 1 0000000000000000 100 0 0 10 0";
    try std.testing.expectEqual(@as(u16, 6783), parseListenerLine(loopback_v6, .v6, 1000).?.port);
}

test "server labels prefer the project directory over home or root" {
    try std.testing.expectEqualStrings("t3code", cwdLabel("/home/me/dev/t3code", "/home/me").?);
    try std.testing.expect(cwdLabel("/home/me", "/home/me/") == null);
    try std.testing.expect(cwdLabel("/", "/home/me") == null);
    try std.testing.expectEqual(@as(?u64, 123), socketInode("socket:[123]"));
    try std.testing.expect(socketInode("pipe:[123]") == null);
}

test "probe accepts pages and redirects but not API-only roots" {
    try std.testing.expect(isBrowsableStatusLine("HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(isBrowsableStatusLine("HTTP/1.1 302 Fou"));
    try std.testing.expect(!isBrowsableStatusLine("HTTP/1.1 404 Not"));
    try std.testing.expect(!isBrowsableStatusLine("HTTP/1.1 405 Met"));
    try std.testing.expect(!isBrowsableStatusLine("SSH-2.0-OpenSSH"));
    try std.testing.expect(isGenericRuntime("python3.12"));
    try std.testing.expect(!isGenericRuntime("t3code"));
}

test "privileged and database ports are not probed" {
    try std.testing.expect(!isLikelyWebPort(80));
    try std.testing.expect(!isLikelyWebPort(5432));
    try std.testing.expect(isLikelyWebPort(5173));
}
