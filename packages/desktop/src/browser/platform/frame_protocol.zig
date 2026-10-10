//! Frame-socket wire format (GUI side). Byte-identical to frame_socket.h; the helper's
//! `zig build test` checks every struct against the C definitions. Pure Zig, no
//! dependencies: a GUI (palette-native example, Verde) imports this file directly.
//!
//! Transport: an AF_UNIX SOCK_SEQPACKET socketpair created by the GUI; the helper's end
//! is inherited as fd `socket_fd` and named by env `socket_env`. One message per record,
//! little-endian, fds as SCM_RIGHTS. Sequence (see LINUX_FRAME_PROTOCOL.md):
//!   GUI -> HELLO (importable formats)    helper -> MODE (shm | dmabuf)
//!   helper -> FRAME + plane fds          GUI -> RELEASE (+ sync_file) when done sampling
const std = @import("std");

pub const magic: u32 = 0x46424456; // "VDBF"
pub const version: u16 = 1;
pub const max_formats = 256;
pub const max_planes = 4;
pub const max_damage = 8;
/// `frame_slot` of the stdout JSON `frame_ready` event for a frame sent over the socket.
pub const dmabuf_frame_slot: u8 = 255;
pub const socket_env = "VERDE_BROWSER_LINUX_FRAME_SOCKET_FD";
/// Fd number the GUI places the helper's socket end at (after the shm slots 240..242).
pub const socket_fd: c_int = 243;

pub const Type = enum(u16) { hello = 1, mode = 2, frame = 3, release = 4, _ };
pub const Mode = enum(u32) { shm = 0, dmabuf = 1, _ };

pub const frame_flag_fence: u32 = 1;
pub const release_flag_fence: u32 = 1;

pub const Header = extern struct {
    magic: u32 = magic,
    version: u16 = version,
    type: Type,

    pub fn ok(self: Header, t: Type) bool {
        return self.magic == magic and self.version == version and self.type == t;
    }
};

pub const Format = extern struct {
    fourcc: u32,
    reserved: u32 = 0,
    modifier: u64,
};

pub const Hello = extern struct {
    header: Header = .{ .type = .hello },
    flags: u32 = 0,
    count: u32 = 0,
    formats: [max_formats]Format = undefined,

    /// Bytes to send for `count` formats (the array is truncated on the wire).
    pub fn wireLen(self: *const Hello) usize {
        return @offsetOf(Hello, "formats") + @as(usize, self.count) * @sizeOf(Format);
    }
};

pub const ModeMsg = extern struct {
    header: Header = .{ .type = .mode },
    mode: Mode = .shm,
    reserved: u32 = 0,
};

pub const Plane = extern struct {
    offset: u32 = 0,
    stride: u32 = 0,
};

pub const Rect = extern struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
};

pub const Frame = extern struct {
    header: Header = .{ .type = .frame },
    sequence: u64 = 0,
    /// st_ino of the dma-buf (stable per producer buffer). Informative: GUIs key imports
    /// by (st_dev, st_ino) of the received fd.
    buffer_id: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    fourcc: u32 = 0,
    plane_count: u32 = 0,
    modifier: u64 = 0,
    planes: [max_planes]Plane = @splat(.{}),
    flags: u32 = 0,
    /// 0 = the whole frame changed.
    damage_count: u32 = 0,
    damage: [max_damage]Rect = @splat(.{}),
    exported_at_ns: u64 = 0,
    sent_at_ns: u64 = 0,
};

pub const Release = extern struct {
    header: Header = .{ .type = .release },
    sequence: u64 = 0,
    flags: u32 = 0,
    reserved: u32 = 0,
};

// ---- sendmsg/recvmsg with SCM_RIGHTS --------------------------------------------------

const linux = std.os.linux;
const max_fds = 8;

const Cmsg = extern struct {
    len: usize,
    level: c_int,
    type: c_int,
    fds: [max_fds]c_int,
};

const sol_socket: c_int = 1;
const scm_rights: c_int = 1;
const msg_cmsg_cloexec: u32 = 0x40000000;
const msg_dontwait: u32 = 0x40;
const msg_nosignal: u32 = 0x4000;

pub fn send(fd: c_int, bytes: []const u8, fds: []const c_int) !void {
    std.debug.assert(fds.len <= max_fds);
    var iov = [_]std.posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    var cmsg: Cmsg = .{ .len = 16 + 4 * fds.len, .level = sol_socket, .type = scm_rights, .fds = undefined };
    @memcpy(cmsg.fds[0..fds.len], fds);
    const msg: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = if (fds.len > 0) &cmsg else null,
        .controllen = if (fds.len > 0) std.mem.alignForward(usize, cmsg.len, 8) else 0,
        .flags = 0,
    };
    while (true) {
        const rc = linux.sendmsg(fd, &msg, msg_nosignal);
        switch (linux.errno(rc)) {
            .SUCCESS => return if (rc == bytes.len) {} else error.ShortWrite,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => return error.SendFailed,
        }
    }
}

pub const Received = struct {
    len: usize,
    fds: [max_fds]c_int = @splat(-1),
    fd_count: usize = 0,

    pub fn closeFds(self: *Received) void {
        for (self.fds[0..self.fd_count]) |f| _ = linux.close(f);
        self.fd_count = 0;
    }
};

/// Non-blocking receive of one record. null = nothing pending; error.Closed = peer gone.
pub fn recv(fd: c_int, buf: []u8) !?Received {
    var iov = [_]std.posix.iovec{.{ .base = buf.ptr, .len = buf.len }};
    var cmsg: Cmsg = undefined;
    var msg: linux.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &cmsg,
        .controllen = @sizeOf(Cmsg),
        .flags = 0,
    };
    while (true) {
        const rc = linux.recvmsg(fd, &msg, msg_cmsg_cloexec | msg_dontwait);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.Closed;
                var out: Received = .{ .len = rc };
                if (msg.controllen >= 16 and cmsg.level == sol_socket and cmsg.type == scm_rights) {
                    out.fd_count = @min((cmsg.len - 16) / 4, max_fds);
                    @memcpy(out.fds[0..out.fd_count], cmsg.fds[0..out.fd_count]);
                }
                return out;
            },
            .INTR => continue,
            .AGAIN => return null,
            else => return error.RecvFailed,
        }
    }
}

/// Reinterprets a received record as `T` when it is long enough and carries the right
/// header.
pub fn as(comptime T: type, buf: []const u8, len: usize) ?*align(1) const T {
    const t: Type = switch (T) {
        Hello => .hello,
        ModeMsg => .mode,
        Frame => .frame,
        Release => .release,
        else => @compileError("not a protocol message"),
    };
    const min = if (T == Hello) @offsetOf(Hello, "formats") else @sizeOf(T);
    if (len < min) return null;
    const h: *align(1) const Header = @ptrCast(buf.ptr);
    if (!h.ok(t)) return null;
    return @ptrCast(buf.ptr);
}

test "round trip with fds over a seqpacket socketpair" {
    var sv: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC, 0, &sv));
    defer _ = linux.close(sv[0]);
    defer _ = linux.close(sv[1]);
    var frame: Frame = .{ .sequence = 42, .width = 64, .height = 32, .plane_count = 1 };
    frame.planes[0].stride = 256;
    try send(sv[0], std.mem.asBytes(&frame), &.{ sv[0], 0 });
    var buf: [@sizeOf(Frame)]u8 align(8) = undefined;
    var got = (try recv(sv[1], &buf)).?;
    defer got.closeFds();
    try std.testing.expectEqual(@as(usize, 2), got.fd_count);
    const f = as(Frame, &buf, got.len).?;
    try std.testing.expectEqual(@as(u64, 42), f.sequence);
    try std.testing.expectEqual(@as(u32, 256), f.planes[0].stride);
    try std.testing.expect(as(Release, &buf, got.len) == null);
    try std.testing.expect((try recv(sv[1], &buf)) == null);
}
