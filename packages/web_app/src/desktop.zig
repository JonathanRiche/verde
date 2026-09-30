//! Bounded binary WebSocket relay to an explicitly configured local VNC server.
//! The gateway owns authentication; this module never discovers arbitrary hosts.
const std = @import("std");
const builtin = @import("builtin");
const config_mod = @import("config.zig");
const auth_mod = @import("auth.zig");

pub const MAX_FRAME_BYTES = 1024 * 1024;
pub const MAX_SESSION_MS = 60 * 60 * 1000;

pub fn enabled(config: config_mod) bool {
    return config.desktop_socket.len != 0 or config.desktop_port != null;
}

/// Bound even a Unix socket connect whose listener has stopped accepting.
pub fn connect(io: std.Io, config: config_mod) !std.Io.net.Stream {
    const Result = union(enum) { connected: anyerror!std.Io.net.Stream, timeout: anyerror!void };
    var buffer: [2]Result = undefined;
    var tasks = std.Io.Select(Result).init(io, &buffer);
    defer while (tasks.cancel()) |remaining| {
        switch (remaining) {
            .connected => |result| if (result) |stream| stream.close(io) else |_| {},
            .timeout => {},
        }
    };
    try tasks.concurrent(.connected, connectLocal, .{ io, config });
    try tasks.concurrent(.timeout, connectDeadline, .{io});
    return switch (try tasks.await()) {
        .connected => |result| result,
        .timeout => error.DesktopConnectTimeout,
    };
}

fn connectLocal(io: std.Io, config: config_mod) anyerror!std.Io.net.Stream {
    if (config.desktop_socket.len != 0) {
        try validateSocket(io, config.desktop_socket);
        const address = try std.Io.net.UnixAddress.init(config.desktop_socket);
        return address.connect(io);
    }
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", config.desktop_port orelse return error.DesktopDisabled);
    return address.connect(io, .{ .mode = .stream });
}

// Private Unix endpoints are the no-password Omarchy boundary. A configured
// TCP backend has its own authentication and listener policy (e.g. macOS).
fn validateSocket(io: std.Io, path: []const u8) !void {
    var resolved: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPathFile(io, path, &resolved);
    if (!std.mem.eql(u8, path, resolved[0..len])) return error.UnsafeDesktopSocket;
    try validatePrivatePath(path, false);
    try validatePrivatePath(std.fs.path.dirname(path) orelse return error.UnsafeDesktopSocket, true);
}

fn validatePrivatePath(path: []const u8, directory: bool) !void {
    var buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= buffer.len) return error.UnsafeDesktopSocket;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    const terminated = buffer[0..path.len :0];
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stat: linux.Statx = undefined;
        const result = linux.statx(linux.AT.FDCWD, terminated, linux.AT.SYMLINK_NOFOLLOW, .{ .UID = true, .TYPE = true, .MODE = true }, &stat);
        if (linux.errno(result) != .SUCCESS or !stat.mask.UID or !stat.mask.TYPE or !stat.mask.MODE)
            return error.UnsafeDesktopSocket;
        if (stat.uid != linux.geteuid() or stat.mode & 0o077 != 0 or
            (if (directory) !linux.S.ISDIR(stat.mode) else !linux.S.ISSOCK(stat.mode)))
            return error.UnsafeDesktopSocket;
    } else if (comptime builtin.os.tag == .macos) {
        var stat: std.c.Stat = undefined;
        if (std.c.fstatat(std.c.AT.FDCWD, terminated, &stat, std.c.AT.SYMLINK_NOFOLLOW) != 0)
            return error.UnsafeDesktopSocket;
        if (stat.uid != std.c.geteuid() or stat.mode & 0o077 != 0 or
            (if (directory) !std.c.S.ISDIR(stat.mode) else !std.c.S.ISSOCK(stat.mode)))
            return error.UnsafeDesktopSocket;
    } else return error.UnsupportedDesktopPlatform;
}

fn connectDeadline(io: std.Io) anyerror!void {
    try std.Io.sleep(io, .fromSeconds(3), .awake);
}

pub const Session = struct {
    io: std.Io,
    socket: *std.http.Server.WebSocket,
    backend: std.Io.net.Stream,
    auth: *auth_mod.Service,
    /// Owned copy: request header storage is reused after the HTTP upgrade.
    session_id: ?[auth_mod.SESSION_ID_BYTES]u8,
    write_mutex: std.Io.Mutex = .init,

    /// When either peer closes or authorization expires, cancel and join both
    /// directions before their caller closes the descriptors. No detached tasks.
    pub fn run(self: *Session) !void {
        const Result = union(enum) { upstream: anyerror!void, downstream: anyerror!void, expiry: anyerror!void };
        var buffer: [3]Result = undefined;
        var tasks = std.Io.Select(Result).init(self.io, &buffer);
        defer {
            tasks.cancelDiscard();
            if (self.session_id) |*id| std.crypto.secureZero(u8, id);
        }
        try tasks.concurrent(.upstream, fromBrowser, .{self});
        try tasks.concurrent(.downstream, toBrowser, .{self});
        try tasks.concurrent(.expiry, watchAuthorization, .{self});
        const first = try tasks.await();
        // Cancellation also interrupts blocked readers/writers, including a
        // stalled peer; sending a close frame here could itself block teardown.
        tasks.cancelDiscard();
        switch (first) {
            inline else => |result| result catch |err| switch (err) {
                error.EndOfStream, error.ConnectionClose, error.Canceled => {},
                else => return err,
            },
        }
    }

    fn valid(self: *Session) bool {
        const id = self.session_id orelse return true;
        return self.auth.verifySession(self.io, &id, auth_mod.nowMillis(self.io)) catch false;
    }

    fn send(self: *Session, bytes: []const u8, opcode: std.http.Server.WebSocket.Opcode) !void {
        try self.write_mutex.lock(self.io);
        defer self.write_mutex.unlock(self.io);
        try self.socket.writeMessage(bytes, opcode);
    }

    fn fromBrowser(self: *Session) anyerror!void {
        var writer = self.backend.writer(self.io, &.{});
        while (true) {
            const message = try self.socket.readSmallMessage();
            if (!self.valid()) return error.DesktopAuthorizationExpired;
            if (message.data.len > MAX_FRAME_BYTES) return error.MessageOversize;
            switch (message.opcode) {
                .binary => {
                    try writer.interface.writeAll(message.data);
                    try writer.interface.flush();
                },
                .ping => try self.send(message.data, .pong),
                else => return error.UnexpectedOpCode,
            }
        }
    }

    fn toBrowser(self: *Session) anyerror!void {
        var buffer: [64 * 1024]u8 = undefined;
        var reader = self.backend.reader(self.io, &buffer);
        while (true) {
            const bytes = try reader.interface.peekGreedy(1);
            if (!self.valid()) return error.DesktopAuthorizationExpired;
            try self.send(bytes, .binary);
            reader.interface.toss(bytes.len);
        }
    }

    fn watchAuthorization(self: *Session) anyerror!void {
        const start = std.Io.Clock.awake.now(self.io).toMilliseconds();
        while (true) {
            try std.Io.sleep(self.io, .fromSeconds(1), .awake);
            if (!self.valid()) return error.DesktopAuthorizationExpired;
            if (std.Io.Clock.awake.now(self.io).toMilliseconds() - start >= MAX_SESSION_MS)
                return error.DesktopSessionExpired;
        }
    }
};

test "desktop backend is opt-in" {
    try std.testing.expect(!enabled(.{}));
    try std.testing.expect(enabled(.{ .desktop_socket = "/run/user/1000/verde-desktop/vnc.sock" }));
    try std.testing.expect(enabled(.{ .desktop_port = 5900 }));
}
